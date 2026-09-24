import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_paths.dart';

/// UE4SS 框架运行时服务（单文件模块）。
///
/// 职责：
/// - 把内置资源 `assets/ue4ss_framework.zip`（dwmapi.dll + ue4ss/ 整个文件夹）
///   首次启动时解压到 `{exe_dir}/ue4ss_runtime/`。
/// - 提供稳定路径给 [ModService.ue4ssFrameworkPath]。
///
/// 设计要点：
/// - **资源来自 rootBundle**：zip 嵌入到 flutter_assets 里，发布后 exe 自带，
///   无需外部 `C:\...\SCUMUE4SS` 路径依赖。
/// - **解压目标 = exe 旁固定目录**：与 [BackgroundService] 模式一致，让 exe 移动
///   后仍能正常启动（assets bundle 永远能重新解压覆盖）。
/// - **解压幂等**：每次启动比对 zip + 已存在目录的"完整性标记"，未变就跳过解压，
///   改了 zip（如用户更新管理器自带的新版 UE4SS）才会重新覆盖。
/// - **错误兜底**：解压失败时记录日志，不阻塞 App 启动。运行时 [frameworkPath]
///   返回已存在目录（部分解压也行）或触发整体跳过注入。
class Ue4ssFrameworkService {
  Ue4ssFrameworkService._();

  /// 内置 zip 资源 key（pubspec.yaml 中声明的路径）。
  static const String _assetKey = 'assets/ue4ss_framework.zip';

  /// exe 旁的运行时目录（与 ModService._exeDir 同根，注入流程会从此读）。
  static const String _runtimeSubDir = 'ue4ss_runtime';

  /// 完整性标记文件名（写入解压根目录，存 zip 的字节大小 hash）。
  static const String _stampFileName = '.ue4ss_framework.stamp';

  /// 启动时尝试解压 UI4SS 框架到 exe 旁。
  ///
  /// - **不 await**：作为 fire-and-forget 在 main() 启动时跑。
  /// - 重复调用幂等：未变化的 zip 不会重复解压（用 zip 字节大小做 stamp 比对）。
  static Future<void> ensureExtracted() async {
    final exeDir = AppPaths.instance.root;
    final runtimeDir = Directory(p.join(exeDir, _runtimeSubDir));
    final stampPath = p.join(runtimeDir.path, _stampFileName);

    try {
      // 1. 从资源读 zip 字节
      final ByteData data = await rootBundle.load(_assetKey);
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final stamp = bytes.length;

      // 2. 检查是否已解压（stamp 文件存在且匹配）
      if (await File(stampPath).exists()) {
        try {
          final prev = int.parse(await File(stampPath).readAsString());
          if (prev == stamp && await _isRuntimeValid(runtimeDir)) {
            AppLogger.instance.info('UE4SS 框架已解压，跳过', {
              'runtime_dir': runtimeDir.path,
            });
            return;
          }
        } catch (_) {
          // stamp 损坏 → 重新解压
        }
      }

      // 3. 解压
      await _extractZip(bytes, runtimeDir);
      // 4. 写 stamp（让下次启动比对）
      await File(stampPath).writeAsString(stamp.toString());
      AppLogger.instance.info('UE4SS 框架已解压到 exe 旁', {
        'runtime_dir': runtimeDir.path,
        'zip_bytes': stamp,
      });
    } catch (e) {
      AppLogger.instance.error('UE4SS 框架解压失败', {
        'error': e.toString(),
      });
    }
  }

  /// 验证运行时目录是否完整（至少有 dwmapi.dll + ue4ss/UE4SS.dll）。
  static Future<bool> _isRuntimeValid(Directory dir) async {
    if (!await dir.exists()) return false;
    final dwmapi = File(p.join(dir.path, 'dwmapi.dll'));
    if (!await dwmapi.exists()) return false;
    final ue4ssDll = File(p.join(dir.path, 'ue4ss', 'UE4SS.dll'));
    if (!await ue4ssDll.exists()) return false;
    return true;
  }

  /// 把 zip 字节流解压到目标目录。
  ///
  /// 保留 [dest] 下 `ue4ss/Mods/` 下的用户 mod（如果之前已经导入过）——
  /// zip 解压只覆盖框架文件（dwmapi.dll + ue4ss.dll + .ini + LICENSE + 空 Mods/）。
  static Future<void> _extractZip(List<int> bytes, Directory dest) async {
    await dest.create(recursive: true);

    // 仅清空框架文件所在目录：dwmapi.dll（顶层）和 ue4ss/（顶层）。
    // **不**碰 ue4ss/Mods/ 下用户导入的 mod 子目录。
    final oldDll = File(p.join(dest.path, 'dwmapi.dll'));
    if (await oldDll.exists()) {
      try {
        await oldDll.delete();
      } catch (_) {}
    }
    final oldUe4ss = Directory(p.join(dest.path, 'ue4ss'));
    if (await oldUe4ss.exists()) {
      // 清空顶层文件（UE4SS.dll / LICENSE / *.ini），保留 Mods/ 下 mod 子目录
      for (final entity in oldUe4ss.listSync(followLinks: false)) {
        final name = p.basename(entity.path).toLowerCase();
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        } else if (entity is Directory) {
          if (name != 'mods') {
            // 非 Mods 的顶层目录（理论上不存在）：删
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }
          // Mods/：保留用户 mod 子目录，但清空模板文件 mods.json / mods.txt
          else {
            for (final child in entity.listSync(followLinks: false)) {
              if (child is! File) continue;
              final cname = p.basename(child.path).toLowerCase();
              if (cname == 'mods.json' || cname == 'mods.txt') {
                try {
                  await child.delete();
                } catch (_) {}
              }
            }
          }
        }
      }
    }

    // 把 zip 内容写到 dest（注意 Mods/ 已存在的话不会重复创建目录）
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      // 跳过 zip 元数据目录（macOS __MACOSX 等）
      if (file.name.contains('__MACOSX/')) continue;
      // 跳过 Mods/ 下的 mod 子目录（保留用户 mod；但 mods.json/mods.txt 在 _extractZip
      // 之外由上面删除逻辑处理后会重新写）
      final firstSeg = file.name.split('/').first.toLowerCase();
      if (firstSeg == 'mods' && file.isFile) {
        // 只允许覆盖 mods.json / mods.txt；其他 mod 子目录下的文件都跳过
        final lastSeg = file.name.split('/').last.toLowerCase();
        if (lastSeg != 'mods.json' && lastSeg != 'mods.txt') continue;
      }
      final outPath = p.join(dest.path, file.name);
      if (!file.isFile) {
        await Directory(outPath).create(recursive: true);
        continue;
      }
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    }
  }

  /// 返回 UE4SS 框架运行时目录绝对路径。
  ///
  /// - 若解压已成功（ensureExtracted 跑过且未失败），返回该目录路径。
  /// - 若解压失败或尚未跑，目录可能不存在；调用方（deployMods）做兜底跳过。
  static String frameworkPath() {
    final exeDir = AppPaths.instance.root;
    return p.join(exeDir, _runtimeSubDir);
  }
}