import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Reclaim 流程的请求参数（worker isolate 入口）。
///
/// 所有字段必须是可序列化基本类型（isolate 通过 `SendPort` 传输）。
class ReclaimRequest {
  /// 游戏客户端 ~mods/ 路径（绝对路径，空字符串表示跳过客户端）。
  final String clientModsPath;

  /// 游戏服务端 ~mods/ 路径（绝对路径，空字符串表示跳过后端）。
  final String serverModsPath;

  /// 本地启用的 UE4SS mod 名字列表（用于精准删除游戏目录中这些子目录）。
  final List<String> enabledUe4ssModNames;

  /// 客户端游戏 Binaries/Win64 路径（用于回收 dwmapi.dll + ue4ss/）。
  final String clientBinariesWin64;

  /// 服务端游戏 Binaries/Win64 路径（用于回收 dwmapi.dll + ue4ss/）。
  final String serverBinariesWin64;

  /// 是否删除整个 ~mods/ 目录本身（不只是里面的文件）。
  final bool deleteModsDir;

  const ReclaimRequest({
    required this.clientModsPath,
    required this.serverModsPath,
    required this.enabledUe4ssModNames,
    required this.clientBinariesWin64,
    required this.serverBinariesWin64,
    this.deleteModsDir = true,
  });
}

/// Reclaim 流程的结果。
///
/// [logLines] 是 worker isolate 在执行过程中产生的日志文本（每行一条），
/// 由主 isolate 在收到结果后统一调用 `AppLogger.instance.info/warning/error`
/// 输出——避免 isolate 间单例不共享、日志文件句柄不一致的问题。
class ReclaimResult {
  /// 删除的 PAK 文件数（两个端合计）。
  final int pakDeleted;

  /// 跳过的 PAK 文件数（文件被锁 / 不存在 / 删失败）。
  final int pakSkipped;

  /// 删除的 UE4SS mod 子目录数。
  final int ue4ssModDeleted;

  /// 删除的 UE4SS 框架（dwmapi.dll + ue4ss/）次数（每个端算一次）。
  final int frameworkDeleted;

  /// UE4SS 框架残留端数（重试耗尽仍未删除的平台数）。
  final int frameworkLeft;

  /// 是否整体删除了 `~mods/` 目录（成功 = true；目录本来就不存在也算 false）。
  final bool modsDirDeleted;

  /// worker 产生的日志行（每行一条；日志级别用 'INFO' / 'WARN' / 'ERROR' 前缀）。
  final List<String> logLines;

  const ReclaimResult({
    required this.pakDeleted,
    required this.pakSkipped,
    required this.ue4ssModDeleted,
    required this.frameworkDeleted,
    required this.frameworkLeft,
    required this.modsDirDeleted,
    required this.logLines,
  });
}

/// 删除单个文件/目录，带指数退避重试（最长 ~62s 重试周期）。
///
/// 重试策略：
///   1 → 500ms → 2 → 1s → 3 → 2s → 4 → 4s → 5 → 8s
///   → 6 → 8s → 7 → 8s → 8 → 8s → 9 → 8s → 10 → 8s（封顶）
///   共 10 次尝试，约 62s 最后放弃。
Future<bool> _deleteWithRetry(
  String label,
  Future<bool> Function() tryDelete, {
  int maxAttempts = 10,
}) async {
  for (int attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      final ok = await tryDelete();
      if (ok) return true;
    } catch (_) {
      // 锁住了 → 重试
    }
    if (attempt < maxAttempts - 1) {
      // 指数退避，封顶 8s
      final delay = Duration(
        milliseconds: 500 * (1 << attempt.clamp(0, 4)),
      );
      await Future.delayed(delay);
    }
  }
  return false;
}

/// Worker isolate 入口函数（必须 top-level / static，不能是闭包）。
///
/// 在独立 isolate 中跑，**所有文件 IO 都在这里**，主 isolate 不阻塞。
/// 主 isolate 通过 `compute(runReclaimInIsolate, request)` 调用。
Future<ReclaimResult> runReclaimInIsolate(ReclaimRequest req) async {
  final logLines = <String>[];
  int pakDeleted = 0;
  int pakSkipped = 0;
  int ue4ssModDeleted = 0;
  int frameworkDeleted = 0;
  int frameworkLeft = 0;
  bool modsDirDeleted = false;

  void log(String level, String msg, [Map<String, Object?>? ctx]) {
    // 简化日志格式：LEVEL msg {ctx_json}——主 isolate 解析时能识别
    // ctx 用 jsonEncode 序列化，避免手工拼装被 value 中的 " / } / 换行破坏。
    final ctxStr = ctx == null || ctx.isEmpty
        ? ''
        : ' ${jsonEncode(ctx)}';
    logLines.add('$level$msg$ctxStr');
  }

  // ── 阶段 1：PAK 文件回收（异步 IO）──
  for (final dirPath in [req.clientModsPath, req.serverModsPath]) {
    if (dirPath.isEmpty) continue;
    final dir = Directory(dirPath);
    if (!await dir.exists()) continue;
    // listSync() 是同步 IO，但只是元数据列表，被锁概率低；
    // 真正可能阻塞的是后续的 File.delete()。这里保留 listSync 因为
    // Directory.list() 异步 API 在某些 Dart 版本不稳定。
    final List<File> pakFiles;
    try {
      pakFiles = dir
          .listSync()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.pak'))
          .cast<File>()
          .toList();
    } catch (e) {
      log('WARN', '扫描 ~mods/ 失败（目录被锁？）', {
        'path': dirPath,
        'error': e.toString(),
      });
      continue;
    }
    for (final file in pakFiles) {
      final ok = await _deleteWithRetry(
        'PAK 文件: ${file.path}',
        () async {
          await file.delete();
          return true;
        },
        maxAttempts: 5, // PAK 文件没必要重试那么久
      );
      if (ok) {
        pakDeleted++;
        log('INFO', 'PAK 已删除', {'path': file.path});
      } else {
        pakSkipped++;
        log('WARN', 'PAK 跳过（重试耗尽，文件被锁）', {
          'path': file.path,
        });
      }
    }
    // ── 阶段 1.5：删整个 ~mods/ 目录本身（如果配置要求）──
    if (req.deleteModsDir) {
      try {
        await dir.delete(recursive: true);
        modsDirDeleted = true;
        log('INFO', '~mods/ 目录已删除', {'path': dirPath});
      } catch (e) {
        log('WARN', '~mods/ 目录删除失败（可能非空或被锁）', {
          'path': dirPath,
          'error': e.toString(),
        });
      }
    }
  }

  // ── 阶段 2：UE4SS mod 子目录回收（精准删除本管理器启用过的）──
  for (final modName in req.enabledUe4ssModNames) {
    // UE4SS mod 子目录在两个端的 Binaries/Win64/ue4ss/Mods/<name>/
    for (final binDir in [req.clientBinariesWin64, req.serverBinariesWin64]) {
      if (binDir.isEmpty) continue;
      final deployedDir = Directory(p.join(binDir, 'ue4ss', 'Mods', modName));
      if (!await deployedDir.exists()) continue;
      final ok = await _deleteWithRetry(
        'UE4SS mod: $modName',
        () async {
          await deployedDir.delete(recursive: true);
          return true;
        },
      );
      if (ok) {
        ue4ssModDeleted++;
        log('INFO', 'UE4SS mod 已删除', {
          'mod_name': modName,
          'path': deployedDir.path,
        });
      } else {
        log('WARN', 'UE4SS mod 删除失败（重试耗尽）', {
          'mod_name': modName,
          'path': deployedDir.path,
        });
      }
    }
  }

  // ── 阶段 3：UE4SS 框架回收（dwmapi.dll + ue4ss/ 整个文件夹）──
  // 每个端独立重试，最长 ~62s。文件刚被游戏释放时可能被 AV/索引器短暂锁住。
  for (final binDir in [req.clientBinariesWin64, req.serverBinariesWin64]) {
    if (binDir.isEmpty) continue;
    final bin = Directory(binDir);
    if (!await bin.exists()) continue;

    // 删 ue4ss/ 整个文件夹（重试）
    final ue4ssDeleted = await _deleteWithRetry(
      'UE4SS 框架目录: ${p.join(binDir, 'ue4ss')}',
      () async {
        final dir = Directory(p.join(binDir, 'ue4ss'));
        if (!await dir.exists()) return true; // 已不在了 = 成功
        await dir.delete(recursive: true);
        return true;
      },
    );

    // 删宿主 dll（dwmapi.dll）（重试）
    final dllDeleted = await _deleteWithRetry(
      'UE4SS 宿主 dll: ${p.join(binDir, 'dwmapi.dll')}',
      () async {
        final file = File(p.join(binDir, 'dwmapi.dll'));
        if (!await file.exists()) return true; // 已不在了 = 成功
        await file.delete();
        return true;
      },
    );

    if (ue4ssDeleted && dllDeleted) {
      frameworkDeleted++;
      log('INFO', 'UE4SS 框架已完全清理', {'path': binDir});
    } else {
      frameworkLeft++;
      log('WARN', 'UE4SS 框架清理未完全', {
        'path': binDir,
        'ue4ss_ok': ue4ssDeleted,
        'dll_ok': dllDeleted,
      });
    }
  }

  return ReclaimResult(
    pakDeleted: pakDeleted,
    pakSkipped: pakSkipped,
    ue4ssModDeleted: ue4ssModDeleted,
    frameworkDeleted: frameworkDeleted,
    frameworkLeft: frameworkLeft,
    modsDirDeleted: modsDirDeleted,
    logLines: logLines,
  );
}

/// ReceivePort 入口（备用，目前使用 `compute` 包装就够了）。
///
/// 这里保留以便将来切换到长连接 isolate：
/// 启动时 spawn 一个 isolate，把 SendPort 缓存到全局变量，
/// 主 isolate 通过 SendPort.send() 发请求，worker isolate 持续处理。
/// 目前用 `compute` 每次重新 spawn，简化实现。
void reclaimIsolateEntry(SendPort mainPort) {
  // reserved for future long-lived isolate
}