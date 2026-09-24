/// 冲突 PAK 自动合并服务 —— 把参与冲突的已启用 PAK 按加载顺序合并为一个新 PAK。
///
/// 管线（repak 是独立进程、文件复制走异步 IO，UI isolate 全程不碰重活）：
/// 1. 读 [ConflictService] 的冲突报告，取**冲突闭包**（至少参与一个冲突组
///    的已启用 PAK 集合）——闭包之外的 PAK 与闭包无任何路径交集，
///    合并包可安全与它们共存部署；
/// 2. 闭包内每个 PAK `repak unpack` 解包到独立临时目录（源文件永不改动）；
/// 3. 按 loadOrder **从高到低** 把文件复制进统一 staging：高优先级先占位，
///    低优先级只补自己独有的路径 → 冲突路径由最高优先级者胜出、非冲突
///    路径全部保留（同一路径天然只复制一次，还顺带去重）；
/// 4. `repak pack --version V11 --compression Zlib --mount-point ../../../`
///    打成一个新 PAK 存入 `{exe_dir}/~merged/merge_<key16>.pak`；
/// 5. 缓存键 = 参与者 `(id|sha256|loadOrder)` 串的 sha256 前 16 位 ——
///    源包未变直接复用已存在产物（零解包零重打包）；源包更新自动重建；
/// 6. 部署时（ModService.deployMods）跳过参与者原包、改复制合并包。
///
/// 失败策略：任一参与者解包失败 / 打包失败 / 校验不过 → 整个合并中止并
/// 返回 null，部署回退为「原样复制所有 PAK」——宁可回到游戏挂载序胜负，
/// 也不产出残缺合并包（残缺包会静默丢文件，比冲突更危险）。
///
/// 自动触发：attach 后监听 [ConflictService]（其扫描结果变化 = 权威信号），
/// 400ms 防抖后后台重建；deployMods 则显式 await [ensureReady] 保证就绪。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/mod_entry.dart';
import '../models/pak_conflict.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'conflict_service.dart';
import 'mod_service.dart';

/// 一次合并的产物描述（deployMods 消费）。
class MergeOutcome {
  /// 合并产物文件名（如 `merge_ab12cd34ef567890.pak`）。
  final String mergedName;

  /// 合并产物绝对路径。
  final String mergedPakPath;

  /// 参与合并（已并入合并包）的 mod id 集合 —— 部署时跳过单独复制。
  final Set<String> skippedModIds;

  /// 参与合并的 mod 显示名（日志 / UI 展示）。
  final List<String> mergedModNames;

  const MergeOutcome({
    required this.mergedName,
    required this.mergedPakPath,
    required this.skippedModIds,
    required this.mergedModNames,
  });
}

/// 合并构建失败（含原因），由调用方吞掉并回退原部署。
class MergeBuildException implements Exception {
  final String message;
  const MergeBuildException(this.message);

  @override
  String toString() => 'MergeBuildException: $message';
}

/// 冲突合并服务单例（项目无 DI，遵循 static singleton 惯例）。
class MergeService extends ChangeNotifier {
  MergeService._();

  /// 全局单例。
  static final MergeService shared = MergeService._();

  ModService? _attachedSvc;
  Timer? _debounce;
  Future<MergeOutcome?>? _buildLock;

  bool _merging = false;
  bool _unavailable = false;
  String _progress = '';
  String? _lastError;
  MergeOutcome? _current;

  /// 是否正在重建合并包。
  bool get merging => _merging;

  /// repak 未找到（合并不可用）。
  bool get unavailable => _unavailable;

  /// 当前进度文本（解包 / 按优先级合并 / 打包阶段）。
  String get progress => _progress;

  /// 最近一次构建失败原因（null = 无失败）。
  String? get lastError => _lastError;

  /// 最近一次成功（或缓存命中）的合并产物；null = 当前无冲突无需合并。
  MergeOutcome? get current => _current;

  /// 绑定 [ModService] + 监听 [ConflictService]：冲突报告变化 → 防抖自动重建。
  void attach(ModService svc) {
    if (identical(_attachedSvc, svc)) return;
    detach();
    _attachedSvc = svc;
    ConflictService.shared.addListener(_onAnyChange);
  }

  /// 解除绑定（HomeScreen dispose 调用）。
  void detach() {
    ConflictService.shared.removeListener(_onAnyChange);
    _debounce?.cancel();
    _debounce = null;
    _attachedSvc = null;
  }

  /// 冲突扫描结果 / 状态变化：防抖 400ms 后后台自动重建（尽力而为）。
  void _onAnyChange() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (_merging) {
        // 合并进行中：顺延 —— 扫描结束的通知会再次触发，幂等无害。
        _debounce = Timer(const Duration(milliseconds: 400), _onAnyChange);
        return;
      }
      // ignore: discarded_futures
      _autoMerge();
    });
  }

  /// 后台自动重建：失败只记日志，不打断任何主流程。
  Future<void> _autoMerge() async {
    try {
      await ensureReady();
    } catch (e, st) {
      AppLogger.instance.error('冲突自动合并异常', {
        'error': e.toString(),
        'stack': st.toString().split('\n').take(4).join(' | '),
      });
    }
  }

  /// 确保合并包就绪（deployMods 调用）：
  /// - 无冲突 → 返回 null（部署走原逻辑）；
  /// - 有冲突且缓存命中 → 毫秒级返回；
  /// - 有冲突且缓存未命中 → 后台重建后返回；失败返回 null（回退原部署）。
  Future<MergeOutcome?> ensureReady() async {
    final svc = _attachedSvc;
    if (svc == null) return null;
    if (_unavailable) return null;

    final report = await ConflictService.shared.waitScan();
    if (report == null || report.groups.isEmpty) {
      _current = null;
      notifyListeners();
      return null;
    }

    final outcome = _computeOutcome(svc, report);
    if (outcome == null) return null;

    final pak = File(outcome.mergedPakPath);
    if (pak.existsSync() && pak.lengthSync() > 0) {
      _current = outcome;
      notifyListeners();
      return outcome;
    }

    // 并发保护：同一时刻只允许一次构建；构建中再次调用直接复用同一 Future。
    return _buildLock ??=
        _build(outcome).whenComplete(() => _buildLock = null);
  }

  // ===== 合并执行 =====

  /// 冲突闭包 → 产物描述（纯内存，不动磁盘）。
  MergeOutcome? _computeOutcome(ModService svc, ConflictReport report) {
    final byId = {for (final m in svc.mods) m.id: m};
    final participants = <ModEntry>[];
    for (final id in report.conflictedModIds) {
      final m = byId[id];
      if (m != null && m.enabled && _isPak(m)) participants.add(m);
    }
    participants.sort((a, b) => a.loadOrder.compareTo(b.loadOrder));
    if (participants.isEmpty) return null;
    // 清单缺失无法保证闭包正确性 → 不合并（部署回退原逻辑）。
    for (final m in participants) {
      if (m.pakEntries.isEmpty) return null;
    }

    final key = _cacheKey(participants);
    final name = 'merge_$key.pak';
    return MergeOutcome(
      mergedName: name,
      mergedPakPath: p.join(_mergedDir(), name),
      skippedModIds: {for (final m in participants) m.id},
      mergedModNames: [for (final m in participants) m.name],
    );
  }

  /// 缓存键：参与者 (id|sha256|loadOrder) 串的 sha256 前 16 位。
  /// sha256 由 ModService 懒算并缓存于 mods_meta.json —— 源包未变键不变。
  String _cacheKey(List<ModEntry> participants) {
    final sb = StringBuffer();
    for (final m in participants) {
      sb
        ..write(m.id)
        ..write('|')
        ..write(m.sha256)
        ..write('|')
        ..write(m.loadOrder)
        ..write('\n');
    }
    return sha256
        .convert(utf8.encode(sb.toString()))
        .toString()
        .substring(0, 16);
  }

  /// 合并产物根目录 `{exe_dir}/~merged/`（scanMods 只扫 `~mods/`，不会被当 mod）。
  String _mergedDir() {
    final dir = p.join(AppPaths.instance.root, '~merged');
    if (!Directory(dir).existsSync()) Directory(dir).createSync(recursive: true);
    return dir;
  }

  /// 真正执行：解包 → 覆盖 → 打包 → 校验 → 清理。任何失败返回 null 并记日志。
  Future<MergeOutcome?> _build(MergeOutcome outcome) async {
    final svc = _attachedSvc;
    if (svc == null) return null;

    final repak = await ConflictService.shared.resolveRepak();
    if (repak == null) {
      _unavailable = true;
      _lastError = '未找到 repak.exe';
      notifyListeners();
      return null;
    }
    _unavailable = false;

    final mergedDir = _mergedDir();
    final work = p.join(mergedDir, '.work');
    if (Directory(work).existsSync()) {
      try {
        Directory(work).deleteSync(recursive: true);
      } catch (_) {}
    }
    Directory(work).createSync(recursive: true);

    _merging = true;
    _lastError = null;
    notifyListeners();
    try {
      // 参与者按 loadOrder 升序（0 = 最低优先级，覆盖时后者胜出）。
      final byId = {for (final m in svc.mods) m.id: m};
      final participants = <ModEntry>[
        for (final id in outcome.skippedModIds) byId[id]!,
      ]..sort((a, b) => a.loadOrder.compareTo(b.loadOrder));

      // 1) 逐个解包到独立临时目录（repak 独立进程，不占 UI isolate）。
      final unpackDirs = <String>[];
      for (var i = 0; i < participants.length; i++) {
        final m = participants[i];
        _progress = '解包 ${i + 1}/${participants.length}「${m.name}」';
        notifyListeners();
        final dir = p.join(work, 'in_$i');
        final r = await Process.run(
          repak,
          ['unpack', '-o', dir, '-f', m.filePath],
        );
        if (r.exitCode != 0) {
          throw MergeBuildException(
            '解包失败「${m.name}」：${_errText(r.stderr)}',
          );
        }
        unpackDirs.add(dir);
      }

      // 2) 覆盖：从高优先级到低优先级复制进 staging。
      //    高优先级先占位（claimed），低优先级只补自己独有的路径。
      final staging = p.join(work, 'staging');
      Directory(staging).createSync(recursive: true);
      final claimed = <String>{};
      for (var i = participants.length - 1; i >= 0; i--) {
        final m = participants[i];
        _progress = '按优先级合并「${m.name}」';
        notifyListeners();
        await _overlayInto(unpackDirs[i], staging, claimed);
      }

      // 3) 打包（参数经往返实证：清单逐条一致，SCUM/Content 前缀保留）。
      _progress = '打包合并包…';
      notifyListeners();
      final outPak = outcome.mergedPakPath;
      final r2 = await Process.run(repak, [
        'pack',
        '--version',
        'V11',
        '--compression',
        'Zlib',
        '--mount-point',
        '../../../',
        staging,
        outPak,
      ]);
      if (r2.exitCode != 0) {
        throw MergeBuildException('打包失败：${_errText(r2.stderr)}');
      }

      // 4) 校验：产物存在 + 条目数与 staging 文件数一致（防静默丢文件）。
      final pak = File(outPak);
      if (!pak.existsSync() || pak.lengthSync() == 0) {
        throw const MergeBuildException('打包产物缺失或为空');
      }
      final listR = await Process.run(repak, ['list', outPak]);
      final listed = <String>{};
      for (final raw in ((listR.stdout as String?) ?? '').split('\n')) {
        final line = _stripPakPrefix(raw.trim());
        if (line.isEmpty) continue;
        listed.add(line.toLowerCase());
      }
      if (listed.length != claimed.length) {
        throw MergeBuildException(
          '校验失败：合并包条目 ${listed.length} ≠ 预期 ${claimed.length}',
        );
      }

      // 5) 清理：临时工作区 + 旧合并产物（保留当前，释放磁盘）。
      if (Directory(work).existsSync()) {
        try {
          Directory(work).deleteSync(recursive: true);
        } catch (_) {}
      }
      for (final f in Directory(mergedDir).listSync()) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (name != outcome.mergedName &&
            name.startsWith('merge_') &&
            name.endsWith('.pak')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }

      _current = outcome;
      AppLogger.instance.info('冲突合并完成', {
        'merged': outcome.mergedName,
        'size': pak.lengthSync(),
        'entries': listed.length,
        'merged_mods': outcome.mergedModNames,
      });
      return outcome;
    } on MergeBuildException catch (e) {
      _lastError = e.message;
      if (Directory(work).existsSync()) {
        try {
          Directory(work).deleteSync(recursive: true);
        } catch (_) {}
      }
      AppLogger.instance.warning('冲突合并中止（回退原部署）', {
        'error': e.message,
      });
      return null;
    } catch (e, st) {
      _lastError = e.toString();
      if (Directory(work).existsSync()) {
        try {
          Directory(work).deleteSync(recursive: true);
        } catch (_) {}
      }
      AppLogger.instance.error('冲突合并异常（回退原部署）', {
        'error': e.toString(),
        'stack': st.toString().split('\n').take(4).join(' | '),
      });
      return null;
    } finally {
      _merging = false;
      _progress = '';
      notifyListeners();
    }
  }

  /// 把一个解包目录的文件复制进 staging，跳过已被更高优先级占用的路径。
  Future<void> _overlayInto(
    String srcRoot,
    String staging,
    Set<String> claimed,
  ) async {
    await for (final f
        in Directory(srcRoot).list(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      final rel = p.relative(f.path, from: srcRoot).replaceAll('\\', '/');
      final key = rel.toLowerCase();
      if (claimed.contains(key)) continue;
      claimed.add(key);
      final dest = p.join(staging, rel);
      await Directory(p.dirname(dest)).create(recursive: true);
      await f.copy(dest);
    }
  }

  static bool _isPak(ModEntry m) =>
      m.fileName.isNotEmpty && m.fileName.toLowerCase().endsWith('.pak');

  /// 去 `../../../` 前缀（repak 默认 strip，不同版本输出可能有差异，兜底再剥）。
  static String _stripPakPrefix(String line) {
    var s = line;
    while (s.startsWith('../')) {
      s = s.substring(3);
    }
    return s;
  }

  static String _errText(Object? err) {
    final s = (err as String?)?.trim() ?? '';
    return s.isEmpty ? '无输出' : s.split('\n').take(3).join(' | ');
  }
}
