import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/launch_options.dart';
import '../models/sftp_account.dart';
import '../models/deploy_result.dart';
import '../models/download_result.dart';
import '../models/mod_entry.dart';
import '../models/remote_mod_entry.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'merge_service.dart';
import 'mod_registry_client.dart';
import 'reclaim_isolate.dart';
import 'ue4ss_framework_service.dart';
import 'ue4ss_mods_txt.dart';
import 'ue4ss_service.dart';

/// PAK 模组管理核心服务。
///
/// 工作流（v2.4+）：
/// 1. 启动时 [scanMods] 先 rescue（复制游戏 ~mods PAK 到本地并覆盖）
/// 2. 然后 reclaim（清空游戏 ~mods）
/// 3. 最后只扫本地 ~mods/（单源真值）
/// 4. 用户点击启动时 [deployMods]：将启用的 PAK 复制到游戏 ~mods
/// 5. 游戏退出后 [reclaimMods]：删除游戏 ~mods 中的 PAK
class ModService extends ChangeNotifier {
  ModService() {
    _migrateLegacyModsDir();
    // 旧版独立 cloud_sources.json 迁入 config.json 后删除（一次性迁移，
    // 须在填充默认之前执行，否则用户定制会被出厂默认挤掉）。
    RegistryClient.migrateLegacySourcesFile();
    // 云上 mod 获取地址统一收进 config.json 的 cloud_sources 节点
    // （不再有独立 cloud_sources.json；URL 已有内容不覆盖，打包者
    //  强覆盖指令 REGISTRY_FORCE_OVERRIDE 例外，见 RegistryClient）。
    RegistryClient.ensureCloudSourceConfigured(this);
  }

  void _migrateLegacyModsDir() {
    try {
      final legacy = Directory(p.join(_exeDir, 'mods'));
      if (!legacy.existsSync()) return;
      legacy.deleteSync(recursive: true);
      AppLogger.instance.info('删除旧版 mods 目录', {'path': legacy.path});
    } catch (e) {
      AppLogger.instance.warning('删除旧版 mods 目录失败', {
        'path': p.join(_exeDir, 'mods'),
        'error': e.toString(),
      });
    }
  }

  String _scumInstallPath = '';
  String _serverInstallPath = '';

  String get _localModsPath {
    final path = p.join(_exeDir, '~mods');
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return path;
  }

  String get _clientModsPath {
    if (_scumInstallPath.isEmpty) return '';
    return p.join(_scumInstallPath, 'SCUM', 'Content', 'Paks', '~mods');
  }

  String get _serverModsPath {
    if (_serverInstallPath.isEmpty) return '';
    return p.join(_serverInstallPath, 'SCUM', 'Content', 'Paks', '~mods');
  }

  String get _exeDir => AppPaths.instance.root;

  /// 本地 UE4SS mod 根目录（`~mods/ue4ss/`）。
  String get _localUe4ssRoot => Ue4ssService.localRoot(_exeDir);

  String? get scumExePath {
    if (_scumInstallPath.isEmpty) return null;
    const candidates = [
      'SCUM/Binaries/Win64/SCUM.exe',
      'SCUM.exe',
      'Binaries/Win64/SCUM.exe',
    ];
    for (final rel in candidates) {
      final full = p.join(_scumInstallPath, rel);
      if (File(full).existsSync()) return full;
    }
    return null;
  }

  String? get serverExePath {
    if (_serverInstallPath.isEmpty) return null;
    const candidates = [
      'SCUM/Binaries/Win64/SCUMServer.exe',
      'SCUMServer.exe',
      'Binaries/Win64/SCUMServer.exe',
    ];
    for (final rel in candidates) {
      final full = p.join(_serverInstallPath, rel);
      if (File(full).existsSync()) return full;
    }
    return null;
  }

  String get scumInstallPath => _scumInstallPath;
  String get serverInstallPath => _serverInstallPath;
  String get localModsPath => _localModsPath;
  String get clientModsPath => _clientModsPath;
  String get serverModsPath => _serverModsPath;

  /// 本地 UE4SS mod 根目录（`~mods/ue4ss/`）。
  String get localUe4ssRoot => _localUe4ssRoot;

  /// UE4SS 框架来源说明：
  ///
  /// UE4SS 框架**内嵌在管理器 exe 内**——由 [Ue4ssFrameworkService] 把
  /// `assets/ue4ss_framework.zip` 解压到 `{exe_dir}/ue4ss_runtime/`。
  /// `ue4ssFrameworkPath` 直接返回这个运行时目录路径。
  ///
  /// 向后兼容：若 `config.json` 里有 `ue4ss_framework_path` 显式覆盖，
  /// 仍优先用配置路径（主人之前的硬编码路径会继续生效，
  /// 直到配置文件被清理或用 [setUe4ssFrameworkPath] 重置）。

  /// 当前生效的 UE4SS 框架路径：
  /// - 优先读 config.json 的 `ue4ss_framework_path`（向后兼容）；
  /// - 否则用内置运行时目录 `{exe_dir}/ue4ss_runtime/`。
  ///
  /// 返回空字符串表示路径不存在——deployMods 会跳过注入（不让游戏启动失败）。
  String get ue4ssFrameworkPath {
    final raw = _loadConfigRaw();
    final configured = (raw['ue4ss_framework_path'] as String?)?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    return Ue4ssFrameworkService.frameworkPath();
  }

  /// 写 UE4SS 框架路径到 config.json（持久化）。
  /// 传空字符串 = 清除覆盖，回到内置运行时目录。
  void setUe4ssFrameworkPath(String path) {
    final raw = _loadConfigRaw();
    raw['ue4ss_framework_path'] = path;
    _saveConfigRaw(raw);
  }

  /// 推断游戏目录下的 `Binaries/Win64` 路径（注入 UE4SS 框架的目标）。
  ///
  /// - 客户端：`<scumInstall>/SCUM/Binaries/Win64`
  /// - 服务端：`<serverInstall>/SCUM/Binaries/Win64` 或 `<serverInstall>/Binaries/Win64`
  ///   （找不到 SCUM 子目录时退回到直接路径）
  String? gameBinariesWin64Dir({required bool isServer}) {
    final base = isServer ? _serverInstallPath : _scumInstallPath;
    if (base.isEmpty) return null;
    final candidates = <String>[
      p.join(base, 'SCUM', 'Binaries', 'Win64'),
      p.join(base, 'Binaries', 'Win64'),
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return candidates.first;
  }

  /// 游戏目录中的 UE4SS mod 部署根目录（`ue4ss/Mods/`）。
  ///
  /// 客户端/服务端使用同一个 UE4SS 目录——SCUM UE4SS 装在 `<install>/SCUM/Binaries/Win64/ue4ss/`。
  /// 服务端的 UE4SS 路径由 `_scumInstallPath` 推断（即服务端安装根下找 `ue4ss/Mods`）。
  String? gameUe4ssModsRoot({required bool isServer}) {
    final base = isServer ? _serverInstallPath : _scumInstallPath;
    return Ue4ssService.gameModsRoot(base);
  }

  final List<ModEntry> _mods = [];
  List<ModEntry> get mods => List.unmodifiable(_mods);

  /// 云上 mod 列表（从远端 registry 获取）。
  List<RemoteModEntry> _cloudMods = [];
  List<RemoteModEntry> get cloudMods => List.unmodifiable(_cloudMods);

  /// 已下载的云上 mod 本机 ID 集合。
  final Set<String> _downloadedCloudIds = {};

  /// 正在下载中的云上 mod remote id 集合（跨 tab 持久：切走再回不丢状态）。
  final Set<String> cloudDownloadingIds = <String>{};

  /// 下载进度（remote id → 0.0~1.0；下载中实时刷新，供任意界面读取）。
  final Map<String, double> cloudDownloadProgress = <String, double>{};

  /// 进度通知节流：每跨过 1% 才广播一次（避免高频 setState 卡 UI）。
  final Map<String, int> _progressNotifyPct = <String, int>{};

  /// remote_id 到本地 mod ID 的映射桥。
  final Map<String, String> _cloudRemoteIdMap = {};

  bool get hasEnabledMods => _mods.any((m) => m.enabled);

  void setPaths({
    required String scumInstallPath,
    required String serverInstallPath,
  }) {
    _scumInstallPath = scumInstallPath;
    _serverInstallPath = serverInstallPath;
    AppLogger.instance.info('更新游戏路径配置', {
      'client_path': scumInstallPath,
      'server_path': serverInstallPath,
    });
    // 路径变化会让派生字段（clientModsPath/serverModsPath/clientModsPath）
    // 和后续 scanMods 结果都变 —— UI 需要重建。
    notifyListeners();
  }

  // ===== 部署 / 回收 =====

  // ───────────────────────── config.txt 热同步 ─────────────────────────
  // 游戏运行期间，把 ue4ss_runtime 源的 UE4SS mod config.txt 变更实时复制到游戏目录部署副本，
  // 让玩家改「管理器里的 config.txt」→ ~2 秒内同步 → DLL 每 0.5 秒重读即生效（无需重启游戏）。
  // 只同步 config.txt（main.dll 运行中已在进程内，同步无意义；config 是唯一运行时可调入口）。
  Timer? _cfgSyncTimer;
  final Map<String, DateTime> _cfgSyncStamp = {};

  void startConfigSync() {
    _cfgSyncTimer?.cancel();
    _cfgSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) => _syncModConfigs());
  }

  void stopConfigSync() {
    _cfgSyncTimer?.cancel();
    _cfgSyncTimer = null;
  }

  void _syncModConfigs() {
    final gameRoot = Ue4ssService.gameModsRoot(_scumInstallPath);
    if (gameRoot == null) return;
    for (final m in _mods.where((m) => m.enabled && m.isUe4ssMod)) {
      final srcCfg = p.join(m.ue4ssRoot, 'dlls', 'config.txt');
      final dstCfg = p.join(gameRoot, m.name, 'dlls', 'config.txt');
      try {
        if (!File(srcCfg).existsSync()) continue;
        final srcT = File(srcCfg).lastModifiedSync();
        final last = _cfgSyncStamp[m.name];
        if (last != null && srcT.isAfter(last)) {
          File(dstCfg).parent.createSync(recursive: true);
          File(srcCfg).copySync(dstCfg);
          AppLogger.instance.info('config.txt 热同步到游戏目录', {'mod': m.name});
        }
        _cfgSyncStamp[m.name] = srcT;
      } catch (_) {
        // 游戏目录可能正被回收/重建，忽略本次
      }
    }
  }

  /// 将本地 ~mods/ 中已启用的 PAK 复制到游戏目录 ~mods。
  ///
  /// 同时部署 UE4SS mod：把本地 `~mods/ue4ss/<name>/` 复制到游戏的 `ue4ss/Mods/<name>/`。
  ///
  /// 异步实现：每个文件复制之间插入 [Future.delayed(Duration.zero)]，
  /// 让出事件循环跑一帧。这样不会阻塞 UI 线程——尤其是大量模组（几十个 PAK）
  /// 同步复制时会把启动按钮"按下去没反应"卡顿几秒。
  Future<DeployResult> deployMods({required bool isServer}) async {
    final targetPath = isServer ? _serverModsPath : _clientModsPath;
    AppLogger.instance.info('开始部署已启用模组', {
      'target': isServer ? 'server' : 'client',
      'target_path': targetPath,
      'enabled_count': _mods.where((m) => m.enabled).length,
    });
    if (targetPath.isEmpty) {
      AppLogger.instance.warning('部署跳过：目标路径为空', {
        'target': isServer ? 'server' : 'client',
      });
      return const DeployResult(ok: false, failed: ['目标路径为空']);
    }

    // ── UE4SS 框架注入（dwmapi.dll + ue4ss/ 整个文件夹）──
    // 启动游戏前必须完成，否则游戏进程不会加载 UE4SS，mod 自然不生效。
    // 注：放在 PAK 部署前——先准备好框架再放 mod 文件，避免启动后才有 Mods/。
    // 只注入当前启动的那一端（避免启动客户端时污染服务端目录）。
    final binDir = gameBinariesWin64Dir(isServer: isServer);
    if (binDir != null) {
      await Ue4ssService.injectFrameworkToGame(
        frameworkPath: ue4ssFrameworkPath,
        gameBinariesDir: binDir,
      );
    }

    final dir = Directory(targetPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      AppLogger.instance.info('创建模组部署目录', {'path': targetPath});
    }

    // ── 冲突合并：有冲突闭包时先确保合并包就绪 ──
    // 参与合并的 PAK 不再单独复制（其文件已并入合并包），改复制合并包。
    // 无冲突 / 合并失败 → merge 为 null，部署回退原逻辑（按挂载序胜负）。
    final merge = await MergeService.shared.ensureReady();
    final skipped = merge?.skippedModIds ?? const <String>{};
    if (merge != null) {
      AppLogger.instance.info('冲突合并包已就绪', {
        'merged': merge.mergedName,
        'merged_mods': merge.mergedModNames,
      });
    }

    for (final mod in _mods.where((m) => m.enabled)) {
      // 让出事件循环：每个文件复制后跑一帧，避免大批量 PAK 部署卡住 UI。
      await Future<void>.delayed(Duration.zero);
      if (mod.isUe4ssMod) {
        await _deployUe4ssMod(mod, isServer: isServer);
        continue;
      }
      if (skipped.contains(mod.id)) {
        AppLogger.instance.info('部署跳过（已并入冲突合并包）', {'mod': mod.name});
        continue;
      }
      // 硬性护栏：PAK 通道只允许 `.pak` 落进游戏 `~mod/`。zip 之类一旦被复制
      // 过去，引擎既不加载也不报错，纯属污染游戏目录。
      if (!mod.fileName.toLowerCase().endsWith('.pak')) {
        AppLogger.instance.warning('部署跳过：非 .pak 文件不得走 PAK 通道', {
          'mod': mod.name,
          'file': mod.fileName,
        });
        continue;
      }
      final src = File(mod.filePath);
      if (!src.existsSync()) {
        AppLogger.instance.warning('部署跳过：源文件不存在', {'file': mod.filePath});
        continue;
      }
      final dest = p.join(targetPath, mod.fileName);
      if (!File(dest).existsSync()) {
        try {
          src.copySync(dest);
          AppLogger.instance.info('复制模组文件', {
            'source': src.path,
            'destination': dest,
            'size': src.lengthSync(),
          });
        } catch (e) {
          AppLogger.instance.error('复制模组文件失败', {
            'source': src.path,
            'destination': dest,
            'error': e.toString(),
          });
        }
      } else {
        AppLogger.instance.debug('部署跳过：目标文件已存在', {'path': dest});
      }
    }

    // ── 复制冲突合并包（如存在）到目标目录 ──
    if (merge != null) {
      final src = File(merge.mergedPakPath);
      final dest = p.join(targetPath, merge.mergedName);
      if (src.existsSync()) {
        if (!File(dest).existsSync()) {
          src.copySync(dest);
          AppLogger.instance.info('复制冲突合并包', {
            'source': src.path,
            'destination': dest,
            'size': src.lengthSync(),
          });
        } else {
          AppLogger.instance.debug('部署跳过：合并包已存在', {'path': dest});
        }
      } else {
        AppLogger.instance.error('冲突合并包缺失，无法部署', {
          'path': merge.mergedPakPath,
        });
      }
    }

    // ── 部署后统一验证（v2.6+）：确保每个启用 mod 的文件都真正复制过去，
    //    防「部分 mod 缺失导致启动后加载失败」。验证不过则不启动游戏。──
    final failed = <String>[];
    for (final mod in _mods.where((m) => m.enabled)) {
      if (mod.isUe4ssMod) {
        final gameRoot = Ue4ssService.gameModsRoot(
          isServer ? _serverInstallPath : _scumInstallPath,
        );
        if (gameRoot == null) {
          failed.add(mod.name);
          continue;
        }
        final srcStats = _dirStats(mod.ue4ssRoot);
        final destStats = _dirStats(p.join(gameRoot, mod.name));
        if (srcStats.files == 0 ||
            destStats.files != srcStats.files ||
            destStats.bytes != srcStats.bytes) {
          failed.add(mod.name);
        }
      } else {
        if (skipped.contains(mod.id)) continue; // 已并入合并包，合并包单独验证
        final src = File(mod.filePath);
        if (!src.existsSync()) {
          failed.add(mod.name);
          continue;
        }
        final dest = File(p.join(targetPath, mod.fileName));
        if (!dest.existsSync() || dest.lengthSync() != src.lengthSync()) {
          failed.add(mod.name);
        }
      }
    }
    // 合并包本身也纳入验证（源缺失 / 未复制 / 大小不符 → 启动失败）。
    if (merge != null) {
      final src = File(merge.mergedPakPath);
      final dest = File(p.join(targetPath, merge.mergedName));
      if (!src.existsSync() || !dest.existsSync() ||
          dest.lengthSync() != src.lengthSync()) {
        failed.add(merge.mergedName);
      }
    }
    if (failed.isEmpty) {
      AppLogger.instance.info('部署验证通过，可安全启动游戏', {
        'target': isServer ? 'server' : 'client',
        'enabled_count': _mods.where((m) => m.enabled).length,
      });
      return DeployResult.success;
    }
    AppLogger.instance.warning('部署验证未通过（不启动游戏，回收已部署）', {
      'target': isServer ? 'server' : 'client',
      'failed_mods': failed,
    });
    return DeployResult(ok: false, failed: failed);
  }

  /// 目录统计（文件数 + 总字节数），部署验证用；读取失败返回零值。
  static ({int files, int bytes}) _dirStats(String dir) {
    var files = 0;
    var bytes = 0;
    try {
      for (final e in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          files++;
          bytes += e.lengthSync();
        }
      }
    } catch (_) {}
    return (files: files, bytes: bytes);
  }

  /// 部署单个 UE4SS mod 到游戏目录。
  ///
  /// 目标路径：`<gameRoot>/Binaries/Win64/ue4ss/Mods/<modName>/`。
  /// 如果游戏目录里还没有 `ue4ss/Mods/`，跳过部署（避免污染游戏目录）。
  Future<void> _deployUe4ssMod(ModEntry mod, {required bool isServer}) async {
    final gameRoot = Ue4ssService.gameModsRoot(
      isServer ? _serverInstallPath : _scumInstallPath,
    );
    if (gameRoot == null) {
      AppLogger.instance.warning('UE4SS 部署跳过：游戏 ue4ss/Mods 目录不存在', {
        'mod_name': mod.name,
        'is_server': isServer,
      });
      return;
    }
    final srcDir = mod.ue4ssRoot;
    if (srcDir.isEmpty || !Directory(srcDir).existsSync()) {
      AppLogger.instance.warning('UE4SS 部署跳过：源目录不存在', {
        'mod_name': mod.name,
        'source': srcDir,
      });
      return;
    }
    final destDir = p.join(gameRoot, mod.name);
    try {
      // 让出事件循环：避免大批量文件复制阻塞 UI。
      await Future<void>.delayed(Duration.zero);
      await Ue4ssService.deployToGame(sourceDir: srcDir, destDir: destDir);
      AppLogger.instance.info('部署 UE4SS mod', {
        'mod_name': mod.name,
        'source': srcDir,
        'destination': destDir,
      });
    } catch (e) {
      AppLogger.instance.error('UE4SS 部署失败', {
        'mod_name': mod.name,
        'error': e.toString(),
      });
    }
  }

  /// 删除游戏目录 ~mods 中的所有 PAK（游戏退出后回收）。
  ///
  /// 同时回收 UE4SS mod（精准删除本管理器启用过的 mod 子目录）和 UE4SS 框架
  /// （dwmapi.dll + 整个 `ue4ss/` 文件夹）。**整个流程在独立 isolate 跑**——
  /// 所有 `Directory.listSync()` / `File.delete()` / `Directory.delete()` 同步 IO
  /// 都跑在 worker 上，主 isolate 完全不阻塞，UI 一直响应。
  ///
  /// **重要**：worker isolate 是按需 spawn（`compute` 默认行为）。每次 reclaim
  /// 约 10-50ms 额外延迟——但比同步 IO hang 死 UI 强多了。如果将来频繁回收
  /// 可改成长连接 isolate（见 [reclaimIsolateEntry] 注释）。
  ///
  /// 返回 [ReclaimResult] 让调用方能判断清理是否真正成功（frameworkLeft > 0
  /// 表示 UE4SS 框架文件因被锁未能清除）。
  Future<ReclaimResult> reclaimMods() async {
    AppLogger.instance.info('开始回收游戏目录模组（worker isolate）', {
      'client_path': _clientModsPath,
      'server_path': _serverModsPath,
    });

    // ── 构造请求参数（必须可序列化）──
    final enabledUe4ssNames = <String>[
      for (final m in _mods.where((m) => m.enabled && m.isUe4ssMod)) m.name,
    ];
    final request = ReclaimRequest(
      clientModsPath: _clientModsPath,
      serverModsPath: _serverModsPath,
      enabledUe4ssModNames: enabledUe4ssNames,
      clientBinariesWin64: gameBinariesWin64Dir(isServer: false) ?? '',
      serverBinariesWin64: gameBinariesWin64Dir(isServer: true) ?? '',
      deleteModsDir: true, // 主人要求：回收时连带 ~mods/ 整个目录
    );

    // ── 在 worker isolate 跑 reclaim ──
    final ReclaimResult result;
    try {
      result = await compute(runReclaimInIsolate, request);
    } catch (e, st) {
      AppLogger.instance.error('reclaim worker isolate 异常', {
        'error': e.toString(),
        'stack': st.toString().split('\n').take(5).join(' | '),
      });
      return ReclaimResult(
        pakDeleted: 0,
        pakSkipped: 0,
        ue4ssModDeleted: 0,
        frameworkDeleted: 0,
        frameworkLeft: 2, // 两个端都未知 → 标记残留
        modsDirDeleted: false,
        logLines: [],
      );
    }

    // ── 主 isolate 把 worker 产生的日志统一输出 ──
    for (final line in result.logLines) {
      final spaceIdx = line.indexOf(' ');
      if (spaceIdx == -1) continue;
      final level = line.substring(0, spaceIdx);
      final rest = line.substring(spaceIdx + 1);
      final braceIdx = rest.lastIndexOf('{');
      String message = rest;
      Map<String, Object?>? ctx;
      if (braceIdx > 0 && rest.endsWith('}')) {
        message = rest.substring(0, braceIdx).trimRight();
        final jsonStr = rest.substring(braceIdx);
        try {
          ctx = (jsonDecode(jsonStr) as Map).cast<String, Object?>();
        } catch (_) {
          ctx = null;
        }
      }
      switch (level) {
        case 'WARN':
          AppLogger.instance.warning(message, ctx ?? const {});
          break;
        case 'ERROR':
          AppLogger.instance.error(message, ctx ?? const {});
          break;
        default:
          AppLogger.instance.info(message, ctx ?? const {});
      }
    }

    AppLogger.instance.info('reclaim 完成', {
      'pak_deleted': result.pakDeleted,
      'pak_skipped': result.pakSkipped,
      'ue4ss_mod_deleted': result.ue4ssModDeleted,
      'framework_deleted': result.frameworkDeleted,
      'framework_left': result.frameworkLeft,
      'mods_dir_deleted': result.modsDirDeleted,
    });
    return result;
  }

  /// 回收游戏目录的 UE4SS mod：删除本管理器部署过的所有 UE4SS mod 子目录。
  ///
  // ===== 扫描 =====

  /// 扫描本地 ~mods/ 目录作为唯一真值源。
  ///
  /// 流程：
  /// 1. [_rescueModsFromGame] — 将游戏 ~mod 中的 PAK 复制到本地（覆盖同名）
  /// 2. [reclaimMods] — 清空游戏 ~mod（**必须 await 完成**：旧版 fire-and-forget
  ///    下回收重试窗口最长 ~24s，期间用户点启动会与新部署的 PAK 竞态，
  ///    可能把刚部署的文件删掉）
  /// 3. 只扫本地 ~mods/ + ~mods/ue4ss/
  Future<void> scanMods() async {
    AppLogger.instance.info('开始扫描模组', {
      'local_path': _localModsPath,
      'local_ue4ss_path': _localUe4ssRoot,
      'client_path': _clientModsPath,
      'server_path': _serverModsPath,
    });
    // 将游戏 ~mods 的 PAK 复制到本地（覆盖同名），确保不丢失手动放入的 PAK
    _rescueModsFromGame();
    // 清空游戏 ~mods —— await 完成后再扫描，避免回收与后续部署竞态
    await reclaimMods();
    // 先把误落 ~mods/ 的 zip 收编为 UE4SS mod（旧版云管线遗留 / 手工误放），
    // 再扫描 —— 收编产物会被随后的 _scanUe4ssDirectory 自然纳入，无需二次扫描。
    await _adoptStrayZips();
    // 只扫本地
    _mods.clear();
    final Set<String> seen = {};

    _scanDirectory(
      _localModsPath,
      ModType.clientPak,
      seen,
      sourceDir: _localModsPath,
    );

    // 扫描本地 UE4SS mod 根目录
    _scanUe4ssDirectory(_localUe4ssRoot, seen);

    _mods.sort((a, b) => a.name.compareTo(b.name));
    for (int i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }

    _applyModsMeta(_loadModsMeta());
    // 重建已下载的云 mod ID 集合
    _rebuildDownloadedCloudIds();
    AppLogger.instance.info('模组扫描完成', {
      'mod_count': _mods.length,
      'enabled_count': _mods.where((m) => m.enabled).length,
      'cloud_downloaded_count': _downloadedCloudIds.length,
    });
    notifyListeners();
  }

  /// 收编误落 `~mods/` 的 zip（见 `Ue4ssService.adoptStrayZip`）。
  ///
  /// 存在的理由：云上 UE4SS mod 的本体是 zip，而 `~mods/` 是 PAK 地盘 ——
  /// 只要有一支 zip 落到那里（旧版管线、手工误放、下载中断），它既不会被
  /// UE4SS 加载、也不会被引擎当 PAK 使用。就地转正比报错让用户自己猜要好。
  Future<void> _adoptStrayZips() async {
    final dir = Directory(_localModsPath);
    if (!dir.existsSync()) return;
    final zips = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList();
    for (final f in zips) {
      final adopted = await Ue4ssService.adoptStrayZip(
        zipPath: f.path,
        localRoot: _localUe4ssRoot,
      );
      AppLogger.instance.info(
        adopted == null ? '~mods/ 中的 zip 收编失败（保持原样）' : '~mods/ 中的 zip 已收编为 UE4SS mod',
        {'zip': f.path, 'mod_dir': adopted ?? ''},
      );
    }
  }

  /// 扫描本地 UE4SS mod 目录，把合规子目录作为 UE4SS mod 加入列表。
  void _scanUe4ssDirectory(String root, Set<String> seen) {
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final probe = Ue4ssService.probe(entity.path);
      if (probe != Ue4ssProbe.valid) {
        AppLogger.instance.warning('UE4SS 扫描跳过：不合规的子目录', {'path': entity.path});
        continue;
      }
      final modName = p.basename(entity.path);
      final key = '$root|$modName';
      if (seen.contains(key)) continue;
      seen.add(key);
      final stat = entity.statSync();
      final size = Ue4ssService.dirSize(entity.path);
      final subDirs = Ue4ssService.detectSubDirs(entity.path);
      _mods.add(
        ModEntry(
          id: _stableId(root, modName),
          name: modName,
          fileName: '',
          filePath: entity.path,
          fileSize: size,
          lastModified: stat.modified,
          enabled: true,
          type: ModType.ue4ssMod,
          description: 'UE4SS mod · ${subDirs.join(", ")}',
          sourceDir: root,
          // 云端下载的 UE4SS mod 带 `<mod 目录>.source` 侧边标记 →
          // 扫描后仍能认出「来源=云端」，否则重启管理器就丢「已下载」状态。
          originSource: _readCloudSourceFile(entity.path),
          tags: const [],
          notes: '',
          ue4ssRoot: entity.path,
          ue4ssSubDirs: subDirs,
        ),
      );
    }
  }

  /// 将游戏 ~mods 目录中的 PAK 复制到本地 ~mods/，同名文件直接覆盖。
  void _rescueModsFromGame() {
    for (final dirPath in [_clientModsPath, _serverModsPath]) {
      if (dirPath.isEmpty) continue;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().where(
        (e) => e is File && e.path.toLowerCase().endsWith('.pak'),
      )) {
        final file = f as File;
        final name = file.uri.pathSegments.last;
        final dest = p.join(_localModsPath, name);
        try {
          file.copySync(dest); // copySync 默认覆盖目标
          AppLogger.instance.info('救援游戏目录模组文件', {
            'source': file.path,
            'destination': dest,
            'size': file.lengthSync(),
          });
        } catch (e) {
          AppLogger.instance.error('救援模组文件失败', {
            'source': file.path,
            'destination': dest,
            'error': e.toString(),
          });
        }
      }
    }
  }

  void _scanDirectory(
    String dirPath,
    ModType type,
    Set<String> seen, {
    String sourceDir = '',
  }) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    final files = dir.listSync().where(
      (e) => e is File && e.path.toLowerCase().endsWith('.pak'),
    );

    for (final entity in files) {
      final file = entity as File;
      final stat = file.statSync();
      final name = file.uri.pathSegments.last;
      final key = '$sourceDir|$name';
      if (seen.contains(key)) continue;
      seen.add(key);

      final source = _readCloudSourceFile(file.path);
      List<String> cloudTags = [];
      String cloudNotes = '';
      if (source == "cloud") {
        final manifest = _readCloudManifest(file.path);
        if (manifest != null) {
          final t = manifest["tags"];
          if (t is List) cloudTags = t.cast<String>();
          cloudNotes = (manifest["notes"] as String?) ?? '';
        }
      }
      _mods.add(
        ModEntry(
          id: _stableId(sourceDir, name),
          name: name.replaceAll(RegExp(r'\.(pak|ini)$'), ''),
          fileName: name,
          filePath: file.path,
          fileSize: stat.size,
          lastModified: stat.modified,
          enabled: true,
          type: type,
          description: _inferDescription(name, type),
          sourceDir: sourceDir,
          originSource: source,
          tags: cloudTags,
          notes: cloudNotes,
          deployed: false,
        ),
      );
    }
  }

  /// 生成 mod 稳定 ID（唯一真值键，用于 mods_meta.json 关联）。
  ///
  /// 升级说明：v2.5 起改用 sha256 前 16 位十六进制（旧版 32-bit 手写哈希
  /// 理论碰撞概率虽低但非零）。算法变更不会丢用户数据——[_applyModsMeta]
  /// 会对旧 ID 做兼容查找并自动把 meta 键迁移到新 ID。
  static String _stableId(String dir, String name) {
    final raw = '$dir|$name';
    return sha256.convert(utf8.encode(raw)).toString().substring(0, 16);
  }

  /// 旧版 32-bit 哈希 ID（v2.4 及更早），仅用于 [_applyModsMeta] 的旧数据兼容。
  static String _legacyStableId(String dir, String name) {
    final raw = '$dir|$name';
    var h = 0;
    for (final c in raw.codeUnits) {
      h = (h * 31 + c) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  String _inferDescription(String fileName, ModType type) {
    final l = fileName.toLowerCase();
    if (l.contains('dirtyslower')) return 'Dirtyslower dekita mod';
    if (l.contains('food')) return 'Food system mod';
    if (l.contains('ammo')) return 'Ammo multiplier mod';
    if (l.contains('spawn')) return 'Spawn density mod';
    if (type == ModType.serverPak) return 'Server PAK';
    if (type == ModType.clientPak) return 'Client PAK';
    return '';
  }

  /// 把当前所有 UE4SS mod 的启用状态同步到本地运行时 mods.txt。
  ///
  /// 在以下时机调用：
  /// - 单个 mod 启用/禁用切换（[toggleMod]）
  /// - 全选/全反选（[toggleAll] / [invertAll]）
  /// - mod 删除（[removeMod]）—— 删完后再同步（行就消失了）
  /// - UE4SS mod 导入（home_screen 的 _importUe4ssFrom*）—— 导入即启用
  ///
  /// 失败仅记日志，不抛异常（不让主流程崩）。
  Future<void> _syncUe4ssModsTxt() async {
    final snapshot = <({String name, bool enabled})>[
      for (final m in _mods.where((m) => m.isUe4ssMod))
        (name: m.name, enabled: m.enabled),
    ];
    try {
      await Ue4ssModsTxt.sync(snapshot);
    } catch (e) {
      AppLogger.instance.error('同步 UE4SS mods.txt 失败', {'error': e.toString()});
    }
  }

  /// 公开包装：供外部（导入流程）显式触发 mods.txt 同步。
  /// 比如 home_screen 在导入完一个新 UE4SS mod 后调一次。
  Future<void> syncUe4ssModsTxt() => _syncUe4ssModsTxt();

  bool toggleMod(String id) {
    final idx = _mods.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    _mods[idx].enabled = !_mods[idx].enabled;
    AppLogger.instance.ui(
      '模组启用开关',
      action: '切换',
      details: {
        'mod_id': id,
        'mod_name': _mods[idx].name,
        'enabled': _mods[idx].enabled,
      },
    );
    // 关键修复（v2.7+）：切换启用状态时持久化到 mods_meta.json。
    // 否则下次打开程序所有 mod 都默认启用（主人反馈的问题）。
    _saveModsMeta();
    notifyListeners();
    // 同步 UE4SS mods.txt（仅当切换的是 UE4SS mod 才有效；非 UE4SS 时 sync 内部空集合也无副作用）
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
    return _mods[idx].enabled;
  }

  bool removeMod(String id) {
    final idx = _mods.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    final m = _mods[idx];
    try {
      if (m.isUe4ssMod) {
        // UE4SS mod：删除整个文件夹
        final dir = Directory(
          m.ue4ssRoot.isNotEmpty ? m.ue4ssRoot : m.filePath,
        );
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
        AppLogger.instance.info('删除 UE4SS mod 目录', {
          'mod_id': id,
          'mod_name': m.name,
          'path': dir.path,
        });
      } else {
        final file = File(m.filePath);
        final size = file.existsSync() ? file.lengthSync() : 0;
        file.deleteSync();
        // 同步删除云端来源侧边标记文件（`<pakPath>.source`）。
        // 不删会在 `~mods/` 里残留孤儿 .source，下次扫描时虽然没被
        // 任何 mod 引用，但依然占着文件系统——主人反馈的问题。
        final sourceFile = File('${m.filePath}.source');
        if (sourceFile.existsSync()) {
          sourceFile.deleteSync();
        }
        AppLogger.instance.info('删除模组文件', {
          'mod_id': id,
          'mod_name': m.name,
          'path': m.filePath,
          'size': size,
        });
      }
    } catch (e) {
      AppLogger.instance.error('删除模组失败', {
        'mod_id': id,
        'mod_name': m.name,
        'path': m.filePath,
        'error': e.toString(),
      });
    }
    _mods.removeAt(idx);
    for (int i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }
    // 本地删除后立刻重建「已下载云 mod」映射——云上面板无需手动刷新即会
    // 重新出现下载按钮（remote_id 失联 → 不再视为已下载，状态实时联动）。
    _rebuildDownloadedCloudIds();
    notifyListeners();
    // 同步 UE4SS mods.txt（删除后该 mod 行自动消失）
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
    return true;
  }

  void moveLoadOrder(int from, int to) {
    if (from < 0 || from >= _mods.length || to < 0 || to >= _mods.length) {
      return;
    }
    if (from == to) return;
    final modName = _mods[from].name;
    _mods.insert(to, _mods.removeAt(from));
    for (int i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }
    AppLogger.instance.ui(
      '模组加载顺序',
      action: '拖动重排',
      details: {'mod_name': modName, 'from': from, 'to': to},
    );
    notifyListeners();
  }

  void reindex() {
    for (int i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }
  }

  // ===== 云上 mod 管理 =====

  /// 云端目录最近一次拉取时间（新鲜度判断用）。
  DateTime? _cloudCatalogFetchedAt;

  /// 从远端 registry 刷新云上 mod 列表。
  Future<void> refreshCloudCatalog() async {
    AppLogger.instance.info('开始刷新云上 mod 目录');
    final list = await RegistryClient.fetchModList();
    _cloudMods = list;
    _cloudCatalogFetchedAt = DateTime.now();
    // 扫描本地 ~mods/ 已下载情况
    _rebuildDownloadedCloudIds();
    AppLogger.instance.info('云上 mod 目录刷新完成', {'count': list.length});
    notifyListeners();
  }

  /// 本地表状态列构建时调用：云端目录陈旧（>5 分钟）则后台静默刷新一次，
  /// 云端有新版本时模组管理自动显示「有更新」（无需手动刷新云上页面）。
  void ensureCloudCatalogFresh() {
    final now = DateTime.now();
    if (_cloudCatalogFetchedAt != null &&
        now.difference(_cloudCatalogFetchedAt!) < const Duration(minutes: 5)) {
      return;
    }
    _cloudCatalogFetchedAt = now; // 刷新期间防抖，不重复触发
    // ignore: discarded_futures
    refreshCloudCatalog();
  }

  /// 直接设置云 mod 目录（用于后台静默加载不触发全量刷新）。
  void setCloudModCatalog(List<RemoteModEntry> list) {
    _cloudMods = list;
    _cloudCatalogFetchedAt = DateTime.now();
    // 后台静默加载路径必须重建一次已下载映射，否则 UI 看不到已下载标记
    // （refreshCloudCatalog 走的是 fetchModList + _rebuildDownloadedCloudIds，
    // setCloudModCatalog 直接给列表时也得重建，否则状态错位）。
    _rebuildDownloadedCloudIds();
    notifyListeners();
  }

  /// 重新扫描本地 ~mods/，重建已下载的云 mod ID 集合。
  void _rebuildDownloadedCloudIds() {
    _downloadedCloudIds.clear();
    _cloudRemoteIdMap.clear();
    for (final mod in _mods) {
      if (mod.originSource != "cloud") continue;
      _downloadedCloudIds.add(mod.id);
      // 从侧边文件读取 remote_id
      final manifest = _readCloudManifest(mod.filePath);
      if (manifest != null && manifest.containsKey("remote_id")) {
        _cloudRemoteIdMap[manifest["remote_id"] as String] = mod.id;
      }
    }
  }

  /// 判断指定的云上 mod 是否已在本地下载。
  bool isCloudModDownloaded(String remoteId) {
    return _cloudRemoteIdMap.containsKey(remoteId);
  }

  // ===== 云上更新检测（本地 ↔ 云端「同名核心」比对） =====

  /// 去后缀、去版本段的「同名核心」（小写）。
  /// 例：`Backpack_Nesting_v1.2.pak` → `backpack_nesting`；`xxx_1_0.pak` → `xxx`。
  static String _cloudNameCore(String name) {
    var s = name.toLowerCase().trim();
    if (s.endsWith('.pak')) s = s.substring(0, s.length - 4);
    if (s.endsWith('.zip')) s = s.substring(0, s.length - 4);
    final m = RegExp(r'[._\-]?v?\d+(\.\d+)*([\-+]\w+)?$').firstMatch(s);
    if (m != null) s = s.substring(0, m.start);
    return s.trim();
  }

  /// 本地 mod 名里能解析出的版本号（`v1.2` / `1.2.3` / `1_0` 等段），解析不到返回 null。
  static String? _localVersionOf(String name) {
    final m = RegExp(r'[._\-]?v?(\d+(\.\d+)+)').firstMatch(name.toLowerCase());
    return m?.group(1);
  }

  /// 云端是否存在与某本地 mod 对应的条目（用于更新检测 / 状态列）。
  /// 优先按下载来源 remote_id 关联（.source 侧边文件——云端改名如
  /// `_NoShoes` 后缀后 core 失配，仍能靠 remote_id 对上）；其次同名核心。
  RemoteModEntry? cloudCounterpartFor(ModEntry local) {
    if (local.isUe4ssMod) {
      // UE4SS mod：仅当带云端来源标记（`.source` 的 remote_id）时才参与云上
      // 更新检测 —— 避免本地手装的 UE4SS mod 被同名 PAK mod 误判为同一 mod。
      final m = _readCloudManifest(local.filePath);
      final rid = m?['remote_id'];
      if (rid is! String || rid.isEmpty) return null;
      for (final c in _cloudMods) {
        if (c.id == rid) return c;
      }
      return null;
    }
    // 1) 下载来源关联：.source 里的 remote_id → 云端条目（最可靠）。
    final manifest = _readCloudManifest(local.filePath);
    if (manifest != null) {
      final rid = manifest['remote_id'];
      if (rid is String && rid.isNotEmpty) {
        for (final c in _cloudMods) {
          if (c.id == rid) return c;
        }
      }
    }
    // 2) 兜底：按同名核心匹配（本地手动放入、无 .source 的 mod）。
    final core = _cloudNameCore(local.name);
    if (core.isEmpty) return null;
    for (final c in _cloudMods) {
      if (c.isUe4ssMod != local.isUe4ssMod) continue;
      if (_cloudNameCore(c.filename) == core) return c;
    }
    return null;
  }

  /// 某云端 mod 对应的本地条目：优先按 source remote_id，其次按同名核心。
  ModEntry? _cloudLocalFor(RemoteModEntry cloud) {
    final byId = _cloudRemoteIdMap[cloud.id];
    if (byId != null) {
      final m = _mods.where((m) => m.id == byId).firstOrNull;
      if (m != null) return m;
    }
    final core = _cloudNameCore(cloud.filename);
    for (final m in _mods) {
      if (m.isUe4ssMod != cloud.isUe4ssMod) continue;
      if (_cloudNameCore(m.name) == core) return m;
    }
    return null;
  }

  /// 本地 mod 是否有「云上同名新版本」（版本号落后 / sha256 不一致 / 大小不一致）。
  bool hasCloudUpdate(ModEntry local) {
    final cloud = cloudCounterpartFor(local);
    if (cloud == null) return false;
    return _isCloudNewer(local, cloud);
  }

  /// 云端相对本地是否更新（比较优先级：版本号 → sha256 → 文件大小兜底）。
  static bool _isCloudNewer(ModEntry local, RemoteModEntry cloud) {
    // 本地版本优先读 .source 记录（下载时云端版本，本地文件名通常无版本段），
    // 文件名解析兜底 —— 与 localVersionForCloud 同源，保证列显示与判定一致。
    final manifest = _readCloudManifest(local.filePath);
    final v = manifest?['version'];
    final localVer = (v is String && v.isNotEmpty) ? v : _localVersionOf(local.name);
    if (localVer != null &&
        cloud.version.isNotEmpty &&
        RemoteModEntry.compare(localVer, cloud.version) < 0) {
      return true;
    }
    // UE4SS mod 的本地形态是「解压后的目录」：目录大小 / 目录哈希与云端 zip
    // 天然不可比，硬比只会永远显示「有更新」。版本号才是唯一可靠判据。
    if (local.isUe4ssMod) return false;
    final sha = cloud.sha256;
    if (sha != null && sha.isNotEmpty && local.sha256.isNotEmpty) {
      return local.sha256.toLowerCase() != sha.toLowerCase();
    }
    return cloud.sizeBytes > 0 &&
        local.fileSize > 0 &&
        cloud.sizeBytes != local.fileSize;
  }

  /// 云上 mod 是否已被本地「旧版本」占用（此时应显示「更新」、点击需覆盖旧文件）。
  ///
  /// 不依赖 .source 云端来源标记（`isCloudModDownloaded`）：本地存在同名核心 /
  /// remote_id 关联的 mod 且内容或版本落后于云端即视为旧版本 —— 避免「本地有
  /// 相同文件就没办法下载 / 更新」（同名文件无云端来源标记时也必须能覆盖）。
  bool isCloudOutdated(RemoteModEntry cloud) {
    final local = _cloudLocalFor(cloud);
    if (local == null) return false;
    return _isCloudNewer(local, cloud);
  }

  /// 云端 mod 对应的本地版本号。
  ///
  /// 优先读 `.source` 侧边文件里记录的下载版本（下载时的云端版本——本地文件名
  /// 取自云端 filename 通常不含版本段，文件名解析会失败）；无记录时回退从本地
  /// 文件名解析（如 `v1.2` → `1.2`，手动导入的带版本段文件可命中）。
  /// 无对应本地条目 / 两处都取不到时返回 null（UI 显示「—」）。
  String? localVersionForCloud(RemoteModEntry cloud) {
    final local = _cloudLocalFor(cloud);
    if (local == null) return null;
    final manifest = _readCloudManifest(local.filePath);
    final v = manifest?['version'];
    if (v is String && v.isNotEmpty) return v;
    return _localVersionOf(local.name);
  }

  /// 下载云上 mod 到本地 ~mods/（v2.6+：跨页进度 + 即时入列表 + 失败自动抛弃）。
  ///
  /// - 下载状态（进行中 / 进度）存于 [cloudDownloadingIds] /
  ///   [cloudDownloadProgress]，**跨 tab 持久**——切走再回不丢。
  /// - 成功即登记映射 + 增量加入本地列表，模组管理立即可见（无需全盘 scanMods）。
  /// - 失败（含大小 / SHA-256 校验不过）自动删除残缺文件，随时可重下。
  /// - [force] = true 时**强制重新下载**：即使本地文件与云端内容一致也删除重下
  ///   （跳过「内容一致即跳过」判定），并清理关联的旧本地条目避免残留双份。
  Future<DownloadResult> downloadCloudMod(
    RemoteModEntry remote, {
    bool force = false,
  }) async {
    // ── UE4SS 类型分流 ──
    // 云端 UE4SS mod 的落地形态是「解压后的目录」（`ue4ss/Mods/<名>/`），
    // 不是 `~mods/` 里的 pak 文件 —— 必须走独立管线，否则 zip 会被当成
    // PAK 部署进游戏 `~mod/`，游戏既不会加载也不会报错（静默失效）。
    if (remote.isUe4ssMod) {
      return downloadCloudUe4ssMod(remote, force: force);
    }
    final destPath = p.join(_localModsPath, remote.filename);
    final remoteId = remote.id;
    AppLogger.instance.info('开始下载云上 mod', {
      'remote_id': remoteId,
      'name': remote.name,
      'filename': remote.filename,
      'destination': destPath,
      'force': force,
    });
    cloudDownloadingIds.add(remoteId);
    cloudDownloadProgress[remoteId] = 0;
    notifyListeners();
    try {
      // ── 覆盖更新前置清理 ──
      // 本地存在「同名核心 / remote_id 关联」的 mod 且内容落后（sha 不同 / 版本旧 /
      // 大小不同）→ 先删旧文件与 .source 标记再下载。不再依赖 isCloudModDownloaded
      // （.source 来源标记）：本地同名文件即使没有云端来源标记也能被覆盖更新。
      final old = _cloudLocalFor(remote);
      if (force) {
        // 强制重新下载：删除本地任何关联旧条目（即使内容一致），避免下载后
        // 旧文件名与云端新文件并存造成双份残留。
        if (old != null) {
          _deleteLocalModFiles(old);
          _rebuildDownloadedCloudIds();
          AppLogger.instance.info('云上 mod 强制重下：已移除本地旧条目', {
            'remote_id': remoteId,
            'old_mod': old.name,
          });
        }
      } else if (old != null && _isCloudNewer(old, remote)) {
        _deleteLocalModFiles(old);
        _rebuildDownloadedCloudIds();
        AppLogger.instance.info('云上 mod 覆盖更新：已移除本地旧版本', {
          'remote_id': remoteId,
          'old_mod': old.name,
        });
      }

      // ── 目标路径已存在文件的内容级判定（不再凭「存在 + 大小一致」就跳过）──
      // 云端提供 sha256 → 本地哈希一致才是真「已下载」（并补写云端来源标记），
      // 否则删除重下；云端无 sha256 → 无法证明一致性，一律删除重下
      // （宁重下，保证点「下载」就能下载，修复旧版 sizeBytes<=0 直接跳过的漏洞）。
      // force = true 时跳过此判定：无论内容是否一致都删除重下。
      if (!force && File(destPath).existsSync()) {
        final sha = remote.sha256?.trim();
        final localSha = await _sha256OfFile(destPath);
        if (sha != null &&
            sha.isNotEmpty &&
            localSha.isNotEmpty &&
            localSha.toLowerCase() == sha.toLowerCase()) {
          // 内容与云端完全一致 → 视为已下载：补写云端来源标记 + 登记映射，
          // 让按钮正确落到「已下载」态（本地同名无标记文件也确认归属）。
          final localId = _stableId(_localModsPath, remote.filename);
          _writeCloudSourceFile(
            destPath,
            remoteId: remoteId,
            displayName: remote.name,
            tags: remote.tags.isNotEmpty ? remote.tags : null,
            description: remote.description,
            version: remote.version,
          );
          _cloudRemoteIdMap[remoteId] = localId;
          _downloadedCloudIds.add(localId);
          AppLogger.instance.info('云上 mod 下载跳过：本地文件与云端内容一致', {
            'remote_id': remoteId,
            'path': destPath,
          });
          notifyListeners();
          return const DownloadResult.success();
        }
        _tryDeleteFile(destPath);
        AppLogger.instance.warning('本地同名文件与云端不一致，删除后重新下载', {
          'remote_id': remoteId,
          'path': destPath,
          'cloud_sha256': sha ?? '',
          'local_sha256': localSha,
        });
      }

      final result = await RegistryClient.downloadMod(
        remote,
        destPath,
        onProgress: (received, total) {
          if (total <= 0) return;
          cloudDownloadProgress[remoteId] = received / total;
          final pct = (received / total * 100).floor();
          if (_progressNotifyPct[remoteId] != pct) {
            _progressNotifyPct[remoteId] = pct;
            notifyListeners();
          }
        },
      );
      if (!result.ok) {
        // 失败自动抛弃：不留残缺文件（否则下次扫描会当成「本地 mod」）。
        _tryDeleteFile(destPath);
        AppLogger.instance.error('云上 mod 下载失败，已自动删除残缺文件', {
          'remote_id': remoteId,
          'error': result.error,
        });
        return result;
      }

      // 下载后校验 SHA-256（云端提供时）——防止损坏包入库。
      if (remote.sha256 != null && remote.sha256!.trim().isNotEmpty) {
        final hex = await _sha256OfFile(destPath);
        if (hex.isEmpty || hex.toLowerCase() != remote.sha256!.toLowerCase()) {
          _tryDeleteFile(destPath);
          AppLogger.instance.error('云上 mod SHA-256 校验失败，已自动删除', {
            'remote_id': remoteId,
          });
          return const DownloadResult(
            ok: false,
            error: 'SHA-256 校验失败（文件损坏，已自动删除）',
          );
        }
      }

      // 写入侧边文件标记来源（含云端元数据 + 版本号：供「本地版本」列读取，
      // 因为本地文件名取自云端 filename，通常不含版本段）。
      _writeCloudSourceFile(
        destPath,
        remoteId: remoteId,
        displayName: remote.name,
        tags: remote.tags.isNotEmpty ? remote.tags : null,
        description: remote.description,
        version: remote.version,
      );
      // 即时登记映射 + 增量加入本地列表——模组管理立即可见，无需 scanMods。
      final localId = _stableId(_localModsPath, remote.filename);
      _cloudRemoteIdMap[remoteId] = localId;
      _downloadedCloudIds.add(localId);
      _addDownloadedModToLocal(remote, destPath, localId);
      AppLogger.instance.info('云上 mod 下载完成', {
        'remote_id': remoteId,
        'path': destPath,
        'size': File(destPath).existsSync() ? File(destPath).lengthSync() : 0,
      });
      return result;
    } finally {
      cloudDownloadingIds.remove(remoteId);
      cloudDownloadProgress.remove(remoteId);
      _progressNotifyPct.remove(remoteId);
      notifyListeners();
    }
  }

  // ===== 云端 UE4SS mod（zip 包）下载与安装 =====

  /// zip 包名 → UE4SS mod 目录名（去尾 `.zip`）。
  ///
  /// 与拖拽导入同一规则（`home_screen._importUe4ssFromZip`：文件名去尾 4 字符），
  /// 保证「云端下载」与「手工拖拽同一个 zip」落到同一个目录、互相覆盖更新。
  static String cloudUe4ssModName(String filename) {
    final base = p.basename(filename);
    if (base.toLowerCase().endsWith('.zip')) {
      return base.substring(0, base.length - 4);
    }
    return p.basenameWithoutExtension(base);
  }

  /// 下载并安装云端 UE4SS mod（zip 包）。
  ///
  /// 与 PAK 路径的差别（三处，缺一不可）：
  /// 1. **下载到系统临时目录**，不落 `~mods/` —— UE4SS mod 的落地形态是解压后
  ///    的目录，zip 留在 `~mods/` 会被 PAK 管线当成 mod 文件误处理；
  /// 2. **sha256 校验通过后解压**到 `ue4ss_runtime/ue4ss/Mods/<ModName>/`
  ///    （ModName 规则见 [cloudUe4ssModName]）；
  /// 3. **写云端来源标记** `<Mods>/<ModName>.source`（remote_id / 版本 / 备注），
  ///    让「已下载 / 有更新 / 本地版本」三处状态对 UE4SS mod 同样生效 ——
  ///    否则每次重启都被当成手装的本地 mod。
  Future<DownloadResult> downloadCloudUe4ssMod(
    RemoteModEntry remote, {
    bool force = false,
  }) async {
    final remoteId = remote.id;
    final modName = Ue4ssService.modNameFromZip(remote.filename);
    final targetDir = p.join(_localUe4ssRoot, modName);
    final target = Directory(targetDir);
    AppLogger.instance.info('开始下载云上 UE4SS mod', {
      'remote_id': remoteId,
      'name': remote.name,
      'filename': remote.filename,
      'mod_name': modName,
      'destination': targetDir,
      'force': force,
    });
    cloudDownloadingIds.add(remoteId);
    cloudDownloadProgress[remoteId] = 0;
    notifyListeners();

    String? tmpPath;
    try {
      // ── 已安装且版本不落后 → 视为已下载（补写来源标记），除非 force ──
      final installed = _readCloudManifest(targetDir);
      final sameOrigin = installed?['remote_id'] == remoteId;
      final installedVer = installed?['version'] as String?;
      if (!force && target.existsSync() && sameOrigin) {
        if (installedVer == null ||
            installedVer.isEmpty ||
            RemoteModEntry.compare(installedVer, remote.version) >= 0) {
          _registerDownloadedUe4ssMod(remote, modName, targetDir);
          AppLogger.instance.info('云上 UE4SS mod 下载跳过：本地已安装且版本不落后', {
            'remote_id': remoteId,
            'installed_version': installedVer ?? '',
            'cloud_version': remote.version,
          });
          return const DownloadResult.success();
        }
      }

      // ── 下载到临时文件 ──
      tmpPath = p.join(
        Directory.systemTemp.path,
        'scum_mm_ue4ss_${remoteId}_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final result = await RegistryClient.downloadMod(
        remote,
        tmpPath,
        onProgress: (received, total) {
          if (total <= 0) return;
          cloudDownloadProgress[remoteId] = received / total;
          final pct = (received / total * 100).floor();
          if (_progressNotifyPct[remoteId] != pct) {
            _progressNotifyPct[remoteId] = pct;
            notifyListeners();
          }
        },
      );
      if (!result.ok) {
        AppLogger.instance.error('云上 UE4SS mod 下载失败', {
          'remote_id': remoteId,
          'error': result.error,
        });
        return result;
      }

      // ── sha256 校验：损坏包不入库 ──
      final sha = remote.sha256?.trim();
      if (sha != null && sha.isNotEmpty) {
        final hex = await _sha256OfFile(tmpPath);
        if (hex.isEmpty || hex.toLowerCase() != sha.toLowerCase()) {
          AppLogger.instance.error('云上 UE4SS mod SHA-256 校验失败', {
            'remote_id': remoteId,
            'cloud_sha256': sha,
            'local_sha256': hex,
          });
          return const DownloadResult(
            ok: false,
            error: 'SHA-256 校验失败（文件损坏，已自动丢弃）',
          );
        }
      }

      // ── 解压安装（覆盖 + 合规复核，见 Ue4ssService.installFromZip）──
      final extracted = await Ue4ssService.installFromZip(
        zipPath: tmpPath,
        localRoot: _localUe4ssRoot,
        modName: modName,
        force: true,
      );
      if (extracted == null) {
        AppLogger.instance.error('云上 UE4SS mod 安装失败（包结构不合规或解压失败）', {
          'remote_id': remoteId,
          'mod_name': modName,
        });
        return const DownloadResult(
          ok: false,
          error: '安装失败：包内未通过 UE4SS mod 合规检查（缺 dlls/ 等目录）',
        );
      }

      // ── 来源标记 + 即时入列表 ──
      _writeCloudSourceFile(
        targetDir,
        remoteId: remoteId,
        displayName: remote.name,
        tags: remote.tags.isNotEmpty ? remote.tags : null,
        description: remote.description,
        version: remote.version,
      );
      _registerDownloadedUe4ssMod(remote, modName, targetDir);
      AppLogger.instance.info('云上 UE4SS mod 安装完成', {
        'remote_id': remoteId,
        'mod_name': modName,
        'path': targetDir,
        'size': Ue4ssService.dirSize(targetDir),
      });
      return result;
    } finally {
      // 临时 zip 一律清除（不论成败）—— 它只是安装介质，不是 mod 本体。
      if (tmpPath != null) _tryDeleteFile(tmpPath);
      cloudDownloadingIds.remove(remoteId);
      cloudDownloadProgress.remove(remoteId);
      _progressNotifyPct.remove(remoteId);
      notifyListeners();
    }
  }

  /// 登记「云端 UE4SS mod → 本地条目」映射，并把条目增量加入本地列表。
  ///
  /// 与 [_addDownloadedModToLocal]（PAK 版）对位：PAK 的 id 由文件路径派生，
  /// UE4SS mod 的 id 由「Mods 根 + 目录名」派生 —— 与 [_scanUe4ssDirectory]
  /// 完全一致，保证增量条目与全盘重扫得到的 id 相同（不会出现双份）。
  void _registerDownloadedUe4ssMod(
    RemoteModEntry remote,
    String modName,
    String targetDir,
  ) {
    final localId = _stableId(_localUe4ssRoot, modName);
    _cloudRemoteIdMap[remote.id] = localId;
    _downloadedCloudIds.add(localId);

    final subDirs = Ue4ssService.detectSubDirs(targetDir);
    final size = Ue4ssService.dirSize(targetDir);
    final dirObj = Directory(targetDir);
    final modified = dirObj.existsSync()
        ? dirObj.statSync().modified
        : DateTime.now();
    final idx = _mods.indexWhere((m) => m.id == localId);
    if (idx >= 0) {
      final old = _mods[idx];
      _mods[idx] = ModEntry(
        id: localId,
        name: modName,
        fileName: '',
        filePath: targetDir,
        fileSize: size,
        lastModified: modified,
        enabled: old.enabled,
        type: ModType.ue4ssMod,
        description: old.description.isNotEmpty
            ? old.description
            : (remote.description ?? ''),
        sourceDir: _localUe4ssRoot,
        originSource: 'cloud',
        tags: old.tags.isNotEmpty ? old.tags : List<String>.from(remote.tags),
        notes: old.notes.isNotEmpty ? old.notes : (remote.description ?? ''),
        deployed: old.deployed,
        ue4ssRoot: targetDir,
        ue4ssSubDirs: subDirs,
      );
    } else {
      _mods.add(
        ModEntry(
          id: localId,
          name: modName,
          fileName: '',
          filePath: targetDir,
          fileSize: size,
          lastModified: modified,
          enabled: true,
          type: ModType.ue4ssMod,
          description: remote.description ?? 'UE4SS mod · ${subDirs.join(", ")}',
          sourceDir: _localUe4ssRoot,
          originSource: 'cloud',
          tags: List<String>.from(remote.tags),
          notes: remote.description ?? '',
          deployed: false,
          ue4ssRoot: targetDir,
          ue4ssSubDirs: subDirs,
        ),
      );
    }
    for (var i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }
    notifyListeners();
  }

  /// 安全删除文件（不存在 / 失败都静默）。
  void _tryDeleteFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 计算文件 SHA-256（失败返回空串）。
  Future<String> _sha256OfFile(String path) async {
    try {
      return (await sha256.bind(File(path).openRead()).last).toString();
    } catch (_) {
      return '';
    }
  }

  /// 下载成功后把新 PAK 增量加入本地列表（无需全盘 scanMods 即可在
  /// 模组管理看到）；覆盖更新（同 id 条目已存在）则替换为新条目并保留
  /// 用户启用/标签/备注等状态，避免状态列残留「有更新」误判。
  void _addDownloadedModToLocal(
    RemoteModEntry remote,
    String destPath,
    String localId,
  ) {
    final file = File(destPath);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final idx = _mods.indexWhere((m) => m.id == localId);
    if (idx >= 0) {
      final old = _mods[idx];
      _mods[idx] = ModEntry(
        id: localId,
        name: remote.filename.replaceAll(RegExp(r'\.(pak|ini)$'), ''),
        fileName: remote.filename,
        filePath: destPath,
        fileSize: size,
        lastModified: file.existsSync()
            ? file.lastModifiedSync()
            : DateTime.now(),
        enabled: old.enabled,
        type: old.type,
        description: remote.description ?? '',
        loadOrder: old.loadOrder,
        sourceDir: _localModsPath,
        originSource: 'cloud',
        tags: old.tags.isNotEmpty ? old.tags : List<String>.from(remote.tags),
        notes: old.notes.isNotEmpty ? old.notes : (remote.description ?? ''),
        deployed: old.deployed,
      );
      notifyListeners();
      return;
    }
    _mods.add(
      ModEntry(
        id: localId,
        name: remote.filename.replaceAll(RegExp(r'\.(pak|ini)$'), ''),
        fileName: remote.filename,
        filePath: destPath,
        fileSize: size,
        lastModified: file.existsSync()
            ? file.lastModifiedSync()
            : DateTime.now(),
        enabled: true,
        type: ModType.clientPak,
        description: remote.description ?? '',
        sourceDir: _localModsPath,
        originSource: 'cloud',
        tags: List<String>.from(remote.tags),
        notes: remote.description ?? '',
        deployed: false,
      ),
    );
    for (var i = 0; i < _mods.length; i++) {
      _mods[i].loadOrder = i;
    }
    notifyListeners();
  }

  /// 删除本地 mod 的文件 + 来源侧边标记（覆盖更新用）。
  void _deleteLocalModFiles(ModEntry m) {
    try {
      if (m.isUe4ssMod) {
        final dir = Directory(
          m.ue4ssRoot.isNotEmpty ? m.ue4ssRoot : m.filePath,
        );
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        // 与 mod 目录同级的云端来源标记（`<目录>.source`）
        final usf = File('${dir.path}.source');
        if (usf.existsSync()) usf.deleteSync();
      } else {
        final f = File(m.filePath);
        if (f.existsSync()) f.deleteSync();
        final sf = File('${m.filePath}.source');
        if (sf.existsSync()) sf.deleteSync();
      }
    } catch (_) {}
  }

  /// 为已下载的云 mod 写入 .mod.source 标记文件（JSON 格式含元数据）。
  static void _writeCloudSourceFile(
    String pakPath, {
    String? remoteId,
    String? displayName,
    List<String>? tags,
    String? description,
    String? version,
  }) {
    // 实现下沉到 Ue4ssService（纯 Dart、可脱 GUI 直测）；键名与 UE4SS 路径共用。
    Ue4ssService.writeCloudSourceMarker(
      pakPath,
      remoteId: remoteId,
      displayName: displayName,
      tags: tags,
      description: description,
      version: version,
    );
  }

  /// 读取 PAK 文件的来源标记。
  /// 不存在侧边文件时默认为 "local"。
  /// 兼容旧版纯文本 "cloud" 和新版 JSON。
  static String _readCloudSourceFile(String pakPath) {
    try {
      final sourceFile = File("$pakPath.source");
      if (!sourceFile.existsSync()) return "local";
      final raw = sourceFile.readAsStringSync().trim();
      // 兼容旧版纯文本 "cloud"
      if (raw == "cloud") return "cloud";
      // 新版 JSON
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return (decoded["source"] as String?) ?? "local";
      }
      return raw;
    } catch (_) {}
    return "local";
  }

  /// 读取 PAK 文件的完整云 metadata（JSON 侧边文件）。
  /// 返回 null 表示该文件不是云下载或侧边文件不可用。
  static Map<String, dynamic>? _readCloudManifest(String pakPath) {
    try {
      final sourceFile = File("$pakPath.source");
      if (!sourceFile.existsSync()) return null;
      final raw = sourceFile.readAsStringSync().trim();
      if (raw == "cloud") return {"source": "cloud"}; // 旧版兼容
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  // ===== Metadata persistence (tags/notes) ====

  static const _modsMetaFile = 'mods_meta.json';
  String get _modsMetaPath => p.join(_exeDir, _modsMetaFile);

  Map<String, Map<String, dynamic>> _loadModsMeta() {
    final file = File(_modsMetaPath);
    if (!file.existsSync()) return {};
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) {
        return raw.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
      }
    } catch (_) {}
    return {};
  }

  void _saveModsMeta() {
    final meta = <String, Map<String, dynamic>>{};
    for (final mod in _mods) {
      // 只在有非默认值时存 tags/notes/disabled。
      // enabled 默认 true —— 不存；只有 disabled=true 才存 'enabled': false。
      final hasTags = mod.tags.isNotEmpty;
      final hasNotes = mod.notes.isNotEmpty;
      final isDisabled = !mod.enabled;
      final hasSha = mod.sha256.isNotEmpty;
      final hasPakEntries = !mod.isUe4ssMod && mod.pakEntries.isNotEmpty;
      if (!hasTags && !hasNotes && !isDisabled && !hasSha && !hasPakEntries) {
        continue;
      }
      meta[mod.id] = {
        if (hasTags) 'tags': List<String>.from(mod.tags),
        if (hasNotes) 'notes': mod.notes,
        if (isDisabled) 'enabled': false,
        if (hasSha) 'sha256': mod.sha256,
        if (hasPakEntries) 'pak_entries': List<String>.from(mod.pakEntries),
      };
    }
    try {
      // 缩进 JSON 便于用户直接查看标签/备注/启用状态。
      File(
        _modsMetaPath,
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));
    } catch (_) {}
  }

  void _applyModsMeta(Map<String, Map<String, dynamic>> meta) {
    // 旧版（v2.4-）meta 键是 32-bit 哈希 ID，新版是 sha256 前 16 位。
    // 命中旧键时顺手迁移到新键（重写 meta 文件），保证标签/备注不丢。
    bool migrated = false;
    for (final mod in _mods) {
      var entry = meta[mod.id];
      if (entry == null) {
        entry = meta[_legacyStableId(mod.sourceDir, mod.fileName)];
        if (entry != null) migrated = true;
      }
      if (entry == null) continue;
      final t = entry['tags'];
      if (t is List) mod.tags = t.cast<String>();
      mod.notes = (entry['notes'] as String?) ?? '';
      // 关键修复（v2.7+）：恢复 enabled 状态。
      // 默认 mod.enabled=true（扫描时设置），只有 meta 里有 'enabled': false 才覆盖。
      // 否则下次打开程序所有 mod 都默认启用（主人反馈的问题）。
      final e = entry['enabled'];
      if (e is bool) {
        mod.enabled = e;
      }
      // 恢复已缓存的 SHA-256（懒计算后写回；未算过为空串）。
      mod.sha256 = (entry['sha256'] as String?) ?? '';
      // 恢复已缓存的 PAK 内部清单（冲突扫描懒加载后写回；未扫过为空列表）。
      final pe = entry['pak_entries'];
      if (pe is List) mod.pakEntries = pe.cast<String>();
    }
    // 关键修复（v2.7+）：扫描完后立即把当前 enabled 状态写一次 meta。
    // 即使这次启动没读出任何 enabled（meta 不存在或为空），也要为下次启动
    // 准备好数据。这样重启程序或拖拽新 mod 后 scanMods 都能恢复 enabled。
    _saveModsMeta();
    // 注意：上面这一行涵盖了"迁移"场景（如果 migrated 会同时迁移键），
    // 所以原 `if (migrated) _saveModsMeta()` 逻辑可省略 —— 现在无条件写一次。
  }

  /// 立即落盘 mods_meta.json（外部服务如 ConflictService 写入 PAK 清单后调用）。
  void flushModsMeta() => _saveModsMeta();

  // ===== SHA-256 懒计算缓存 =====

  /// 正在计算的 mod id 集合（防重入 —— 行组件逐个触发时避免并发重复读盘）。
  final Set<String> _shaComputing = <String>{};

  /// 取某 mod 的 SHA-256：已缓存直接返回，否则懒计算并缓存到 mods_meta.json。
  ///
  /// 只对 PAK 文件计算（UE4SS mod 为文件夹，无单文件哈希 → 返回空串）。
  /// 计算完成后通过 notifyListeners() 刷新 UI（表格行重建即显示哈希）。
  Future<String> ensureSha256(ModEntry mod) async {
    if (mod.sha256.isNotEmpty) return mod.sha256;
    if (mod.isUe4ssMod) return '';
    if (_shaComputing.contains(mod.id)) return '';
    final file = File(mod.filePath);
    if (!file.existsSync()) return '';
    _shaComputing.add(mod.id);
    try {
      // sha256.bind() 为每个数据事件产出一个中间 digest，取 .last 才是
      // 最终完整哈希（.first 只是首个 chunk 后的中间值，不可用）。
      final digest = await sha256.bind(file.openRead()).last;
      final hex = digest.toString();
      _shaComputing.remove(mod.id);
      mod.sha256 = hex;
      _saveModsMeta();
      notifyListeners();
      return hex;
    } catch (e) {
      _shaComputing.remove(mod.id);
      AppLogger.instance.warning('SHA-256 计算失败', {
        'mod_id': mod.id,
        'error': e.toString(),
      });
      return '';
    }
  }

  void updateModTags(String id, List<String> tags) {
    final i = _mods.indexWhere((m) => m.id == id);
    if (i == -1) return;
    _mods[i].tags = tags;
    _saveModsMeta();
    notifyListeners();
  }

  void updateModNotes(String id, String notes) {
    final i = _mods.indexWhere((m) => m.id == id);
    if (i == -1) return;
    _mods[i].notes = notes;
    _saveModsMeta();
    notifyListeners();
  }

  Set<String> get allTags {
    final s = <String>{};
    for (final m in _mods) {
      s.addAll(m.tags);
    }
    return s;
  }

  void toggleAll(bool enabled) {
    for (final m in _mods) {
      m.enabled = enabled;
    }
    // 关键修复（v2.7+）：全选/全反选后持久化所有 mod 的 enabled 状态。
    _saveModsMeta();
    notifyListeners();
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
  }

  void invertAll() {
    for (final m in _mods) {
      m.enabled = !m.enabled;
    }
    _saveModsMeta();
    notifyListeners();
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
  }

  /// 按 id 集合批量启用/禁用（全选按「当前筛选显示的 mod」；范围外的 mod 不动）。
  void setManyEnabled(Iterable<String> ids, bool enabled) {
    var changed = false;
    final idSet = ids.toSet();
    for (final m in _mods) {
      if (idSet.contains(m.id) && m.enabled != enabled) {
        m.enabled = enabled;
        changed = true;
      }
    }
    if (!changed) return;
    _saveModsMeta();
    notifyListeners();
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
  }

  /// 反选指定 id 集合（反选按「当前筛选显示的 mod」；范围外的 mod 不动）。
  void invertIds(Iterable<String> ids) {
    var changed = false;
    final idSet = ids.toSet();
    for (final m in _mods) {
      if (idSet.contains(m.id)) {
        m.enabled = !m.enabled;
        changed = true;
      }
    }
    if (!changed) return;
    _saveModsMeta();
    notifyListeners();
    // ignore: discarded_futures
    _syncUe4ssModsTxt();
  }

  void deleteBatch(List<String> ids) {
    for (final id in ids) {
      removeMod(id);
    }
  }

  // ===== Config persistence (paths + launch options) =====

  Map<String, dynamic> _loadConfigRaw() {
    final f = File(p.join(_exeDir, 'config.json'));
    if (!f.existsSync()) return {};
    try {
      final data = jsonDecode(f.readAsStringSync());
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    return {};
  }

  void _saveConfigRaw(Map<String, dynamic> data) {
    try {
      // 缩进 JSON（2 空格），便于用户直接查看/编辑 config.json。
      // 旧版单行 jsonEncode 在人工排查时费眼，主人要求改为缩进格式。
      final json = const JsonEncoder.withIndent('  ').convert(data);
      File(p.join(_exeDir, 'config.json')).writeAsStringSync(json);
    } catch (_) {}
  }

  /// 读 config.json 中某键的原始值（用于嵌套结构，如 `mod_table_columns`）。
  /// 不存在时返回 null。
  Object? loadConfigKey(String key) => _loadConfigRaw()[key];

  /// 写 config.json 某键（整体覆盖该键，保留其他键）。
  void saveConfigKey(String key, Object? value) {
    final raw = _loadConfigRaw();
    raw[key] = value;
    _saveConfigRaw(raw);
  }

  Map<String, String> loadConfig() {
    final raw = _loadConfigRaw();
    return {
      'scum_install_path': (raw['scum_install_path'] as String?) ?? '',
      'server_install_path': (raw['server_install_path'] as String?) ?? '',
      // Mica/亚克力开关。缺省 = false（让首帧走亚克力 fallback，等
      // WindowService.enableMica 探测完成后再决定是否翻成 true）。
      'mica_enabled': (raw['mica_enabled'] as String?) ?? 'false',
    };
  }

  void saveConfig(Map<String, String> config) {
    final raw = _loadConfigRaw();
    // 先把两个核心路径键写回（保持向后兼容）。
    raw['scum_install_path'] = config['scum_install_path'] ?? '';
    raw['server_install_path'] = config['server_install_path'] ?? '';
    // 透传其他键（Mica 开关等），让设置页能往 config.json 里写自定义字段。
    for (final entry in config.entries) {
      if (entry.key == 'scum_install_path' ||
          entry.key == 'server_install_path') {
        continue; // 上面已经处理
      }
      raw[entry.key] = entry.value;
    }
    _saveConfigRaw(raw);
  }

  // ── Mica 持久化快捷接口（设置页 Mica toggle 直接走这里，不触发 scanMods）──

  /// Mica/亚克力开关（读 config.json）。缺省 false。
  bool get micaEnabled => loadConfig()['mica_enabled'] == 'true';

  /// 写 Mica 开关到 config.json —— 同步生效，**不触发 scanMods**。
  void setMicaEnabled(bool enabled) {
    final raw = _loadConfigRaw();
    raw['mica_enabled'] = enabled ? 'true' : 'false';
    _saveConfigRaw(raw);
  }

  // ── SFTP 服务器连接配置（管理器使用者连接**他们自己的服务器**）──

  /// 读取 SFTP 连接配置。
  ///
  /// 返回 Map 含以下键（缺省值已填充）：
  /// - `sftp_host` / `sftp_port` / `sftp_username` / `sftp_password`
  /// - `sftp_mods_path`（远端 ~mods 绝对路径，留空 = 未定位）
  Map<String, String> loadSftpConfig() {
    final raw = _loadConfigRaw();
    return {
      'sftp_host': (raw['sftp_host'] as String?) ?? '',
      'sftp_port': (raw['sftp_port'] as String?) ?? '22',
      'sftp_username': (raw['sftp_username'] as String?) ?? '',
      'sftp_password': (raw['sftp_password'] as String?) ?? '',
      'sftp_mods_path': (raw['sftp_mods_path'] as String?) ?? '',
    };
  }

  /// 写 SFTP 连接配置到 config.json（键以 `sftp_` 为前缀，统一收口）。
  void saveSftpConfig(Map<String, String> config) {
    final raw = _loadConfigRaw();
    for (final key in const [
      'sftp_host',
      'sftp_port',
      'sftp_username',
      'sftp_password',
      'sftp_mods_path',
    ]) {
      raw[key] = config[key] ?? '';
    }
    _saveConfigRaw(raw);
  }

  // ── SFTP 多账户管理（远程服务器界面可快速切换不同服务器）──

  /// 读取全部 SFTP 账户列表（config.json `sftp_accounts` 数组）。
  ///
  /// 兼容旧版单账户：若数组为空但旧 `sftp_host` 等键存在，自动迁移为一条账户。
  List<SftpAccount> loadSftpAccounts() {
    final raw = _loadConfigRaw();
    final list = raw['sftp_accounts'];
    final accounts = <SftpAccount>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          accounts.add(SftpAccount.fromJson(item));
        }
      }
    }
    // 旧版单账户迁移（host 有值且账户列表为空时）
    if (accounts.isEmpty) {
      final host = (raw['sftp_host'] as String?) ?? '';
      final username = (raw['sftp_username'] as String?) ?? '';
      if (host.isNotEmpty && username.isNotEmpty) {
        accounts.add(
          SftpAccount(
            name: host,
            host: host,
            port: int.tryParse((raw['sftp_port'] as String?) ?? '22') ?? 22,
            username: username,
            password: (raw['sftp_password'] as String?) ?? '',
            modsPath: (raw['sftp_mods_path'] as String?) ?? '',
          ),
        );
      }
    }
    return accounts;
  }

  /// 当前激活账户（config.json `sftp_active` 存账户名）。缺省 = 第一个账户名。
  String? get activeSftpAccountName {
    final raw = _loadConfigRaw();
    final active = raw['sftp_active'] as String?;
    if (active != null && active.isNotEmpty) return active;
    final accounts = loadSftpAccounts();
    return accounts.isEmpty ? null : accounts.first.name;
  }

  /// 获取当前激活账户对象；无账户返回 null。
  SftpAccount? get activeSftpAccount {
    final accounts = loadSftpAccounts();
    final activeName = activeSftpAccountName;
    if (accounts.isEmpty) return null;
    return accounts.firstWhere(
      (a) => a.name == activeName,
      orElse: () => accounts.first,
    );
  }

  /// 设置当前激活账户（不存在的名字 → 忽略）。
  void setActiveSftpAccount(String name) {
    final raw = _loadConfigRaw();
    raw['sftp_active'] = name;
    _saveConfigRaw(raw);
  }

  /// 写入 SFTP 账户列表（整体覆写，保留 `sftp_active` 指向）。
  void saveSftpAccounts(List<SftpAccount> accounts) {
    final raw = _loadConfigRaw();
    raw['sftp_accounts'] = accounts.map((a) => a.toJson()).toList();
    _saveConfigRaw(raw);
  }

  /// 新增/更新账户（同名覆盖）。默认设为激活账户。
  void upsertSftpAccount(SftpAccount account) {
    final accounts = loadSftpAccounts();
    final idx = accounts.indexWhere((a) => a.name == account.name);
    if (idx >= 0) {
      accounts[idx] = account;
    } else {
      accounts.add(account);
    }
    saveSftpAccounts(accounts);
    setActiveSftpAccount(account.name);
  }

  /// 删除账户（按名字）。删除的是激活账户时，激活切到第一个剩余账户。
  void removeSftpAccount(String name) {
    final accounts = loadSftpAccounts();
    accounts.removeWhere((a) => a.name == name);
    saveSftpAccounts(accounts);
    if (activeSftpAccountName == name) {
      final raw = _loadConfigRaw();
      if (accounts.isEmpty) {
        raw.remove('sftp_active');
      } else {
        raw['sftp_active'] = accounts.first.name;
      }
      _saveConfigRaw(raw);
    }
  }

  LaunchOptions loadLaunchOptions() {
    final raw = _loadConfigRaw();
    final opts = raw['launch_options'];
    if (opts is Map<String, dynamic>) {
      return LaunchOptions.fromJson(opts);
    }
    return LaunchOptions();
  }

  void saveLaunchOptions(LaunchOptions options) {
    final raw = _loadConfigRaw();
    raw['launch_options'] = options.toJson();
    _saveConfigRaw(raw);
  }

  // ====== Auto-detect paths ======

  Future<void> autoDetectPathsAndApply() async {
    final cfg = loadConfig();
    var scum = cfg['scum_install_path'] ?? '';
    var server = cfg['server_install_path'] ?? '';
    if (scum.isEmpty) scum = autoDetectScumPath() ?? '';
    if (server.isEmpty) server = autoDetectServerPath() ?? '';
    saveConfig({'scum_install_path': scum, 'server_install_path': server});
    setPaths(scumInstallPath: scum, serverInstallPath: server);
    await scanMods();
  }

  String? autoDetectScumPath() {
    final steam = _readSteamRegistryPath();
    if (steam == null) return null;
    final defPath = p.join(steam, 'steamapps', 'common', 'SCUM');
    if (Directory(defPath).existsSync()) return defPath;
    for (final lib in _parseLibraryFolders(steam)) {
      final c = p.join(lib, 'steamapps', 'common', 'SCUM');
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }

  String? autoDetectServerPath() {
    final steam = _readSteamRegistryPath();
    if (steam != null) {
      final defPath = p.join(steam, 'steamapps', 'common', 'SCUM Server');
      if (Directory(defPath).existsSync()) return defPath;
      for (final lib in _parseLibraryFolders(steam)) {
        final c = p.join(lib, 'steamapps', 'common', 'SCUM Server');
        if (Directory(c).existsSync()) return c;
      }
    }
    for (final drive in _getAvailableDrives()) {
      final candidate = p.join(drive, 'SCUM', 'SCUMServer');
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? _readSteamRegistryPath() {
    try {
      var r = Process.runSync('reg', [
        'query',
        r'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam',
        '/v',
        'InstallPath',
      ]);
      if (r.exitCode == 0) return _parseRegValue(r.stdout as String);
      r = Process.runSync('reg', [
        'query',
        r'HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam',
        '/v',
        'InstallPath',
      ]);
      if (r.exitCode == 0) return _parseRegValue(r.stdout as String);
    } catch (_) {}
    return null;
  }

  static String? _parseRegValue(String output) {
    for (final line in output.split('\n')) {
      final t = line.trim();
      if (!t.contains('REG_SZ') && !t.contains('REG_EXPAND_SZ')) continue;
      final parts = t.split(RegExp(r'\s{2,}'));
      if (parts.length >= 3) return parts[2].trim();
    }
    return null;
  }

  static List<String> _parseLibraryFolders(String steamPath) {
    final result = <String>[];
    final vdf = File(p.join(steamPath, 'steamapps', 'libraryfolders.vdf'));
    if (!vdf.existsSync()) return result;
    try {
      final content = vdf.readAsStringSync();
      final regex = RegExp(r'"path"\s+"([^"]+)"');
      for (final m in regex.allMatches(content)) {
        final raw = m.group(1)!;
        result.add(raw.replaceAll('\\\\', '\\'));
      }
    } catch (_) {}
    return result;
  }

  static List<String> _getAvailableDrives() {
    final drives = <String>[];
    for (int i = 65; i <= 90; i++) {
      final letter = String.fromCharCode(i);
      try {
        if (Directory("$letter:\\").existsSync()) drives.add("$letter:\\");
      } catch (_) {}
    }
    return drives;
  }
}
