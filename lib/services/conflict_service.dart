/// 模组冲突扫描服务 —— 自动检测已启用 PAK 之间的资源路径冲突。
///
/// 原理：用 repak.exe 列出每个已启用 PAK 的内部文件清单（仅读索引，快），
/// 归一化路径（小写 + 去 `../../../` 前缀）后求交集 —— 同一路径出现在
/// ≥2 个 PAK 即冲突（部署到游戏 `~mods` 后加载序靠后的 PAK 覆盖靠前的）。
///
/// ## 清单归档（并入 mods_meta.json，不再有独立 pak_entries_cache.json）
///
/// 每个 mod 的 PAK 内部清单以 `pak_entries` 字段存于其 mods_meta.json 条目下
/// （与标签/备注/SHA-256 同册）。扫描流程：
/// 1. 取 mod 的 sha256（懒算，结果缓存于 mods_meta.json，未变不重读文件）；
/// 2. 查该 mod 的 pak_entries：已有清单 → 直接用，不重复调 repak；
/// 3. 无清单 → repak list 一次并写入 mod.pakEntries + 立即落盘 meta。
///
/// ## 自动清理
///
/// [attach] 绑定 [ModService] 后，扫描 / 导入 / 删除 / 启用切换都会 400ms
/// 防抖自动重扫：新 mod 出现 → 自动入档；mod 被删除 → 其条目随
/// mods_meta.json 整体重写自动剪除（_saveModsMeta 只遍历当前列表），
/// 既释放空间也免维护独立缓存文件。
///
/// repak 定位顺序：config.json `repak_path` → exe 目录 → PATH → ~/.cargo/bin。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/mod_entry.dart';
import '../models/pak_conflict.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'mod_service.dart';

/// 冲突扫描服务单例（项目无 DI，遵循 static singleton 惯例）。
class ConflictService extends ChangeNotifier {
  ConflictService._();

  /// 全局单例。
  static final ConflictService shared = ConflictService._();

  ModService? _attachedSvc;
  Timer? _debounce;

  bool _scanning = false;
  bool _scanStarted = false;
  bool _unavailable = false;
  String? _repakPath;
  ConflictReport? _report;

  /// 是否正在扫描。
  bool get scanning => _scanning;

  /// repak 未找到（扫描不可用）。
  bool get unavailable => _unavailable;

  /// 最近一次扫描报告（null = 尚未扫描成功）。
  ConflictReport? get report => _report;

  /// 依附的 [ModService]。
  ModService? get attachedSvc => _attachedSvc;

  /// 绑定 [ModService]：任何变化自动触发重扫（幂等，重复 attach 安全）。
  void attach(ModService svc) {
    if (identical(_attachedSvc, svc)) return;
    if (_attachedSvc != null) _attachedSvc!.removeListener(_onSvcChanged);
    _attachedSvc = svc;
    svc.addListener(_onSvcChanged);
  }

  /// mod 变化防抖：合并高频通知，静默 400ms 后自动重扫一次。
  void _onSvcChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (_scanning) {
        // 扫描进行中：顺延重查，扫描结束后再补扫一遍（状态可能又变了）。
        _debounce = Timer(const Duration(milliseconds: 400), _onSvcChanged);
        return;
      }
      // ignore: discarded_futures
      refresh();
    });
  }

  /// 惰性首次就绪：列表「状态」列可见时调用（保持行懒加载模式）。
  /// 已扫过 / 正在扫则直接忽略。
  Future<void> ensureReady() {
    if (_scanStarted || _scanning) return Future.value();
    _scanStarted = true;
    return refresh();
  }

  /// 立即重扫（工具栏按钮 / 面板「重新扫描」调用）。
  Future<void> refresh() async {
    final svc = _attachedSvc;
    if (svc == null) return;
    if (_scanning) return; // 并发保护：进行中的扫描完成后结果即最新

    final repak = await resolveRepak();
    if (repak == null) {
      _unavailable = true;
      _report = null;
      AppLogger.instance.warning('冲突扫描不可用：未找到 repak.exe', {});
      notifyListeners();
      return;
    }
    _unavailable = false;

    _scanning = true;
    notifyListeners();
    try {
      // 参与扫描：全部已启用的 PAK（客户端/服务端统一定义 ——
      // deployMods 会把所有启用 PAK 复制到同一游戏目录，两端类型无差别）。
      final paks = [
        for (final m in svc.mods)
          if (m.enabled && _isPak(m)) m,
      ]..sort((a, b) => a.loadOrder.compareTo(b.loadOrder));

      AppLogger.instance.info('冲突扫描开始', {'pak_count': paks.length});

      bool metaDirty = false;
      for (final mod in paks) {
        await Future<void>.delayed(Duration.zero); // 让出事件循环，不卡 UI
        // 清单已在内存（本进程扫过或启动时从 meta 恢复）→ 直接跳过 repak。
        if (mod.pakEntries.isNotEmpty) continue;
        // 取 sha256（懒算；结果缓存于 mods_meta.json，内容未变不重读文件）。
        await svc.ensureSha256(mod);
        if (mod.sha256.isEmpty) continue; // UE4SS / 计算失败 → 跳过
        await _listPak(svc, mod);
        metaDirty = true; // 空清单也应入档防重试（记录已尝试）
      }

      // 清单有变化 → 立即落盘 mods_meta.json（删除的 mod 随重写自动剪枝）。
      if (metaDirty) svc.flushModsMeta();

      // 路径 → 包含它的 mod id 列表（按加载序）
      final pathMap = <String, List<String>>{};
      for (final mod in paks) {
        final entries = mod.pakEntries;
        if (entries.isEmpty) continue;
        for (final e in entries) {
          (pathMap[e] ??= []).add(mod.id);
        }
      }

      final groups = <PakConflictGroup>[
        for (final e in pathMap.entries)
          if (e.value.length >= 2)
            PakConflictGroup(path: e.key, modIds: List.unmodifiable(e.value)),
      ]..sort((a, b) => a.path.compareTo(b.path));

      _report = ConflictReport(groups: groups, scannedModCount: paks.length);
      AppLogger.instance.info('冲突扫描完成', {
        'conflict_paths': groups.length,
        'conflicted_mods': _report!.conflictedModIds.length,
        'scanned_paks': paks.length,
      });
    } catch (e, st) {
      AppLogger.instance.error('冲突扫描失败', {
        'error': e.toString(),
        'stack': st.toString().split('\n').take(4).join(' | '),
      });
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// 确保至少完成一次冲突扫描并返回最新报告（MergeService / 部署前调用）：
  /// - 已就绪 → 毫秒级立即返回；
  /// - 未开始 → 触发扫描并等待完成；
  /// - 扫描中 → 等待当前扫描结束（其结果即最新）。
  Future<ConflictReport?> waitScan() {
    if (_report != null && !_scanning) return Future.value(_report);
    if (!_scanStarted && !_scanning) {
      return refresh().then((_) => _report);
    }
    // 扫描进行中：等完成通知（扫描结束 notifyListeners 时 _scanning 已置 false）。
    final completer = Completer<ConflictReport?>();
    void onScanDone() {
      if (_scanning) return;
      removeListener(onScanDone);
      completer.complete(_report);
    }

    addListener(onScanDone);
    return completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        removeListener(onScanDone);
        return _report;
      },
    );
  }

  // ===== repak 定位 =====

  /// 定位 repak：config 覆盖 → exe 目录 → PATH → ~/.cargo/bin（Rust 默认安装位）。
  /// 公开供 MergeService 复用（含缓存）。
  Future<String?> resolveRepak() async {
    if (_repakPath != null && File(_repakPath!).existsSync()) return _repakPath;
    final svc = _attachedSvc;
    // 1) config.json repak_path 覆盖
    if (svc != null) {
      final cfg = svc.loadConfigKey('repak_path');
      if (cfg is String) {
        final t = cfg.trim();
        if (t.isNotEmpty && File(t).existsSync()) return _repakPath = t;
      }
    }
    // 2) exe 目录（随身携带形态）
    final exeDir = AppPaths.instance.root;
    for (final cand in [
      p.join(exeDir, 'repak.exe'),
      p.join(exeDir, 'bin', 'repak.exe'),
    ]) {
      if (File(cand).existsSync()) return _repakPath = cand;
    }
    // 3) PATH
    try {
      final r = await Process.run('repak', const ['--version']);
      if (r.exitCode == 0) return _repakPath = 'repak';
    } catch (_) {}
    // 4) ~/.cargo/bin
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isNotEmpty) {
      final cargo = p.join(home, '.cargo', 'bin', 'repak.exe');
      if (File(cargo).existsSync()) return _repakPath = cargo;
    }
    _repakPath = null;
    return null;
  }

  // ===== PAK 内部清单 =====

  static bool _isPak(ModEntry m) =>
      m.fileName.isNotEmpty && m.fileName.toLowerCase().endsWith('.pak');

  /// 去 `../../../` 前缀（repak 默认 strip，不同版本输出可能有差异，兜底再剥）。
  String _stripPakPrefix(String line) {
    var s = line;
    while (s.startsWith('../')) {
      s = s.substring(3);
    }
    return s;
  }

  /// 单个 PAK 入档：repak list 读取内部清单，写入 mod.pakEntries
  /// （由 ModService 统一落盘到 mods_meta.json 该 mod 条目）。
  /// 读取失败（加密 PAK / 损坏 / repak 报错）记空清单，避免反复重试。
  Future<void> _listPak(ModService svc, ModEntry mod) async {
    final repak = _repakPath;
    if (repak == null) return;
    try {
      final r = await Process.run(repak, ['list', mod.filePath]);
      if (r.exitCode != 0) {
        AppLogger.instance.warning('repak list 失败（跳过该 PAK）', {
          'pak': mod.name,
          'stderr': ((r.stderr as String?) ?? '')
              .trim()
              .split('\n')
              .take(3)
              .join(' | '),
        });
        mod.pakEntries = const [];
      } else {
        final set = <String>{};
        for (final raw in ((r.stdout as String?) ?? '').split('\n')) {
          final line = _stripPakPrefix(raw.trim());
          if (line.isEmpty) continue;
          set.add(line.toLowerCase());
        }
        mod.pakEntries = set.toList()..sort();
      }
      AppLogger.instance.debug('PAK 清单已入档', {
        'pak': mod.name,
        'entries': mod.pakEntries.length,
      });
    } catch (e) {
      AppLogger.instance.error('读取 PAK 内部清单失败（跳过该 PAK）', {
        'pak': mod.filePath,
        'error': e.toString(),
      });
      mod.pakEntries = const [];
    }
  }
}
