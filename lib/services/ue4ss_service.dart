import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// UE4SS mod 解析与部署服务（纯静态方法，单文件模块）。
///
/// 设计要点：
/// - UE4SS mod 通常以"文件夹形式"分发（包含 `dlls/`、`LogicMods/`、`Scripts/` 等
///   子目录，以及可能的 `version.dll` / `dllmod.txt`），也常被打包成 zip 后分发。
/// - 本服务负责：
///   1. **检测**一个路径（文件/文件夹）是否是 UE4SS mod —— 通过特征目录判定。
///   2. **解压** zip 到本地 `ue4ss_runtime/ue4ss/Mods/<name>/` 目录。
///   3. **复制**已解压的 UE4SS mod 文件夹到游戏目录（部署）。
///   4. **回收**游戏目录中由本管理器部署过的 UE4SS mod 文件夹。
///   5. **删除**本地 UE4SS mod 文件夹。
///
/// "标准 SCUM UE4SS mod" 的判定条件（命中任一即认为合规）：
/// - 含 `dlls/` 子目录（dll 注入式 UE4SS mod）；
/// - 含 `LogicMods/` 子目录（Lua 脚本式 mod）；
/// - 含 `Scripts/` 子目录（UE4SS 启动脚本）；
/// - 含 `version.dll`（dll 改名注入）；
/// - 含 `dllmod.txt`（dllmod.txt 入口声明）。
///
/// 检测不通过 → 返回 null，调用方按 PAK / 其他文件处理。
class Ue4ssService {
  Ue4ssService._();

  /// 本地 UE4SS mod 根目录（`ue4ss_runtime/ue4ss/Mods/`）。
  ///
  /// 与 UE4SS 框架**同根**——UE4SS 框架源在 `{exe_dir}/ue4ss_runtime/ue4ss/`
  /// （含 dwmapi.dll/UE4SS.dll/配置/Mods/），mod 直接嵌套在 `Mods/` 下：
  ///
  /// ```
  /// {exe_dir}/ue4ss_runtime/
  /// ├── dwmapi.dll          ← 注入到游戏 Binaries/Win64（UE4SS 框架）
  /// └── ue4ss/
  ///     ├── UE4SS.dll       ← 注入到游戏 Binaries/Win64/ue4ss/
  ///     ├── *.ini
  ///     └── Mods/
  ///         ├── mods.json   ← 注入到游戏 Binaries/Win64/ue4ss/Mods/
  ///         ├── mods.txt
  ///         └── <user_mod>/ ← 本地 UE4SS mod 存储
  /// ```
  ///
  /// 启动游戏时框架注入**只复制 `ue4ss/` 下的框架文件 + 空 Mods/**，
  /// 用户 mod 由 deployMods 单独复制到游戏 `ue4ss/Mods/<name>/`。
  static String localRoot(String exeDir) =>
      p.join(exeDir, 'ue4ss_runtime', 'ue4ss', 'Mods');

  /// 游戏目录中的 UE4SS mod 部署目录。
  ///
  /// SCUM UE4SS 通常安装到 `{SCUM}/Binaries/Win64/ue4ss/Mods/`（老版）或
  /// `{SCUM}/SCUM/Binaries/Win64/ue4ss/Mods/`（新版 Steam 路径）。
  /// 我们把 mod 统一部署到 `<游戏根>/Binaries/Win64/ue4ss/Mods/<name>/`。
  static String? gameModsRoot(String? scumInstall) {
    if (scumInstall == null || scumInstall.isEmpty) return null;
    // 兼容两种游戏根路径：
    // - 客户端:  <SteamPath>/steamapps/common/SCUM
    //   → ue4ss 在 <SCUM>/SCUM/Binaries/Win64/ue4ss/Mods
    // - 直接装在根: <SCUM>
    //   → ue4ss 在 <SCUM>/Binaries/Win64/ue4ss/Mods
    final candidates = <String>[
      p.join(scumInstall, 'SCUM', 'Binaries', 'Win64', 'ue4ss', 'Mods'),
      p.join(scumInstall, 'Binaries', 'Win64', 'ue4ss', 'Mods'),
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    // 都不存在 → 默认采用第一种（绝大多数 Steam 安装走这条）
    return candidates.first;
  }

  /// UE4SS mod 标致性子目录 / 文件（命中任一即为合规 UE4SS mod）。
  /// 注意：这里必须全部小写——probe 逻辑对文件名做了 `toLowerCase()`，
  /// 大写 marker 会导致 probe 永远命中不了，玩家原汁原味的 UE4SS mod
  /// 目录名通常是 `Scripts`（首字母大写），toLowerCase 后才是 'scripts'。
  static const List<String> _markerDirs = ['dlls', 'logicmods', 'scripts'];
  static const List<String> _markerFiles = ['version.dll', 'dllmod.txt'];

  /// 判定一个路径是否为合规的 UE4SS mod（已解压的文件夹形态）。
  ///
  /// 输入可以是：
  /// - 一个目录路径（已解压的 UE4SS mod）；
  /// - 一个 `.zip` 文件路径（待解压的压缩包）。
  ///
  /// 返回值：
  /// - `Ue4ssProbe.valid` → 合规；
  /// - `Ue4ssProbe.invalid` → 不是 UE4SS mod（调用方应按其他类型处理）；
  /// - `Ue4ssProbe.zipInvalid` → 是 zip 但内部结构不是 UE4SS mod。
  static Ue4ssProbe probe(String path) {
    final entity = FileSystemEntity.typeSync(path);
    if (entity == FileSystemEntityType.directory) {
      return _probeDirectory(Directory(path));
    } else if (entity == FileSystemEntityType.file) {
      if (path.toLowerCase().endsWith('.zip')) {
        return _probeZip(path);
      }
      return Ue4ssProbe.invalid;
    }
    return Ue4ssProbe.invalid;
  }

  /// 检测已解压目录。
  static Ue4ssProbe _probeDirectory(Directory dir) {
    try {
      final entries = dir.listSync(followLinks: false);
      for (final entry in entries) {
        final name = p.basename(entry.path).toLowerCase();
        if (entry is Directory && _markerDirs.contains(name)) {
          return Ue4ssProbe.valid;
        }
        if (entry is File && _markerFiles.contains(name)) {
          return Ue4ssProbe.valid;
        }
      }
    } catch (_) {}
    return Ue4ssProbe.invalid;
  }

  /// 检测 zip 内部结构（不解压）。
  static Ue4ssProbe _probeZip(String zipPath) {
    try {
      final bytes = File(zipPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive.files) {
        // 路径分隔符在 archive 里统一用 '/'，跳过目录条目。
        if (!file.isFile) continue;
        final segs = file.name.split('/');
        if (segs.length < 2) continue;
        // 取第一层目录名 + 直接文件名两种情况。
        final top = segs.first.toLowerCase();
        final last = segs.last.toLowerCase();
        if (_markerDirs.contains(top)) return Ue4ssProbe.valid;
        if (_markerFiles.contains(last)) return Ue4ssProbe.valid;
      }
      return Ue4ssProbe.zipInvalid;
    } catch (_) {
      return Ue4ssProbe.zipInvalid;
    }
  }

  /// 把 zip 解压到 `<localRoot>/<modName>/`，返回解压后的根目录路径。
  ///
  /// [force] = true → 目标目录已存在时**先删后解压**（覆盖用，由 OverwriteDialog
  ///   在用户确认"覆盖"后才传入 true）。默认 false 与旧行为一致。
  ///
  /// 返回值：
  /// - 非 null = 解压成功，目标目录路径；
  /// - null = 解压失败（不含"目标已存在"——那是 force=false 时的预期，由调用方处理）。
  ///
  /// 安全：**zip slip 防护** —— 任何 zip 条目的路径（含 `..`）会被拒绝。
  /// 旧版直接 `p.join(target.path, file.name)` 拼路径：恶意 zip 可构造
  /// 形如 `../../SCUM/Content/Paks/~mod/evil.pak` 的条目，文件写到 target 之外。
  /// 新版用 `p.normalize` + `p.isWithin` 检查，命中即抛异常。
  static Future<String?> extractZip({
    required String zipPath,
    required String localRoot,
    required String modName,
    bool force = false,
  }) async {
    final target = Directory(p.join(localRoot, modName));
    if (target.existsSync() && !force) {
      return null;
    }
    // 用 normalize 把 target 解析成绝对路径，后续 isWithin 比较时一致。
    final targetAbs = p.normalize(p.absolute(target.path));
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      // 解压前先清空目标（覆盖场景）或创建（首次）
      if (target.existsSync()) {
        await target.delete(recursive: true);
      }
      await target.create(recursive: true);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        // 跳过 zip 内 macOS __MACOSX 等元数据目录。
        if (file.name.contains('__MACOSX/')) continue;
        final outPath = p.normalize(p.absolute(p.join(target.path, file.name)));
        // zip slip 防护：outPath 必须仍在 targetAbs 下。
        if (!p.isWithin(targetAbs, outPath)) {
          AppLogger.instance.error('UE4SS zip 解压拒绝 zip slip 条目', {
            'entry': file.name,
            'resolved': outPath,
            'target': targetAbs,
          });
          throw const FormatException('zip slip detected');
        }
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      }
      return target.path;
    } catch (e) {
      // 失败清理残留
      if (target.existsSync()) {
        try {
          target.deleteSync(recursive: true);
        } catch (_) {}
      }
      AppLogger.instance.warning('UE4SS zip 解压失败', {
        'zip': zipPath,
        'mod': modName,
        'error': e.toString(),
      });
      return null;
    }
  }

  /// zip 包名 → UE4SS mod 目录名（去尾 `.zip`；非 zip 名回退去扩展名）。
  ///
  /// 与拖拽导入同一规则（`home_screen._importUe4ssFromZip`：文件名去尾 4 字符），
  /// 保证「云端下载」与「手工拖拽同一个 zip」落到同一个目录、互相覆盖更新 ——
  /// 否则同一个 mod 会出现两份，UE4SS 会把两个 DLL 都加载。
  static String modNameFromZip(String filename) {
    final base = p.basename(filename);
    if (base.toLowerCase().endsWith('.zip')) {
      return base.substring(0, base.length - 4);
    }
    return p.basenameWithoutExtension(base);
  }

  /// 写「云端来源标记」侧边文件 `<path>.source`（JSON）。
  ///
  /// [path] 既可以是 PAK 文件路径，也可以是 UE4SS mod 目录路径 —— 标记恒写在
  /// 该路径**同级**。字段与 PAK 路径共用同一套键名（`source`/`remote_id`/
  /// `name`/`version`/`tags`/`notes`），因此 ModService 的「已下载 / 有更新 /
  /// 本地版本」三处判定对 PAK 与 UE4SS 两种类型同源生效。
  static void writeCloudSourceMarker(
    String path, {
    String? remoteId,
    String? displayName,
    List<String>? tags,
    String? description,
    String? version,
  }) {
    try {
      final marker = <String, dynamic>{"source": "cloud"};
      if (remoteId != null) marker["remote_id"] = remoteId;
      if (displayName != null) marker["name"] = displayName;
      if (version != null && version.isNotEmpty) marker["version"] = version;
      if (tags != null && tags.isNotEmpty) marker["tags"] = tags;
      if (description != null && description.isNotEmpty) {
        marker["notes"] = description;
      }
      File("$path.source").writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(marker),
      );
    } catch (e) {
      AppLogger.instance.warning('云端来源标记写入失败', {
        'path': path,
        'error': e.toString(),
      });
    }
  }

  /// 把误落 `~mods/`（PAK 地盘）里的 zip 就地「收编」为 UE4SS mod。
  ///
  /// 旧版云下载管线会把云上 zip 当 PAK 落进 `~mods/` —— 那种状态两头不靠：
  /// 不是 mod 目录（UE4SS 不加载），也不是 `.pak`（引擎不认），纯属死文件。
  /// 处理次序：解压安装 → 把 `<zip>.source` 来源标记挪到 `<mod 目录>.source`
  /// → 删掉 zip。返回 mod 目录；失败返回 null 且**不动原 zip**（宁可留着，
  /// 也不能在没装成的情况下把用户的文件删了）。
  static Future<String?> adoptStrayZip({
    required String zipPath,
    required String localRoot,
  }) async {
    final installed = await installFromZip(
      zipPath: zipPath,
      localRoot: localRoot,
      modName: modNameFromZip(zipPath),
    );
    if (installed == null) return null;
    try {
      final src = File('$zipPath.source');
      if (src.existsSync()) {
        src.copySync('$installed.source');
        src.deleteSync();
      }
      File(zipPath).deleteSync();
    } catch (e) {
      AppLogger.instance.warning('收编 zip 后清理原文件失败', {
        'zip': zipPath,
        'error': e.toString(),
      });
    }
    return installed;
  }

  /// 从本地 zip 安装 UE4SS mod 到 [localRoot]（返回 mod 目录；失败返回 null）。
  ///
  /// 比裸 [extractZip] 多做一件关键事：**解压后用 [probe] 复核合规性** ——
  /// 解压出一堆文件但缺少 `dlls/` 等标记目录（游戏根本不会加载）这种静默失败，
  /// 必须在这里拦掉并清掉残留，否则用户会看到「下载成功但没效果」。
  ///
  /// [force] = true（默认）时覆盖已存在的同名目录：重建目录，清掉旧版本
  /// 残留文件（例如上个版本带、这个版本已删的脚本）。
  static Future<String?> installFromZip({
    required String zipPath,
    required String localRoot,
    required String modName,
    bool force = true,
  }) async {
    final extracted = await extractZip(
      zipPath: zipPath,
      localRoot: localRoot,
      modName: modName,
      force: force,
    );
    if (extracted == null) return null;
    if (probe(extracted) != Ue4ssProbe.valid) {
      AppLogger.instance.error('UE4SS mod 安装被拒：解压结果不合规', {
        'path': extracted,
        'zip': zipPath,
      });
      try {
        Directory(extracted).deleteSync(recursive: true);
      } catch (_) {}
      return null;
    }
    return extracted;
  }

  /// 复制已存在的 UE4SS mod 文件夹到目标目录（部署到游戏）。
  ///
  /// [dest] 目标目录路径（不存在会被创建）。
  /// 返回最终的目标目录路径。
  static Future<String> deployToGame({
    required String sourceDir,
    required String destDir,
  }) async {
    final dest = Directory(destDir);
    if (!dest.existsSync()) {
      await dest.create(recursive: true);
    }
    // Windows 上用 robocopy 行为更接近增量同步，
    // 这里用 Dart 同步实现：先清空 dest 内的旧内容再整体拷贝。
    await _clearDir(dest);
    await _copyDir(Directory(sourceDir), dest);
    return dest.path;
  }

  static Future<void> _clearDir(Directory dir) async {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  static Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyDir(entity, Directory(p.join(dest.path, name)));
      } else if (entity is File) {
        await entity.copy(p.join(dest.path, name));
      }
    }
  }

  /// 清空 ue4ss/ 目录下的"框架文件"（保留 Mods/ 下的用户 mod 子目录）。
  ///
  /// 清空对象：
  /// - 顶层文件：UE4SS.dll / LICENSE / *.ini
  /// - Mods/mods.json、Mods/mods.txt（模板文件，每次启动覆盖刷新）
  ///
  /// 保留：Mods/<user_mod>/（由 deployMods 流程单独管理）
  static Future<void> _clearFrameworkFilesOnly(Directory ue4ssDir) async {
    for (final entity in ue4ssDir.listSync(followLinks: false)) {
      final name = p.basename(entity.path).toLowerCase();
      if (entity is File) {
        // 顶层文件：直接删
        try {
          await entity.delete();
        } catch (_) {}
        continue;
      }
      if (entity is Directory) {
        if (name == 'mods') {
          // Mods/ 下：只删模板文件（mods.json / mods.txt），保留 mod 子目录
          for (final child in entity.listSync(followLinks: false)) {
            if (child is! File) continue;
            final cname = p.basename(child.path).toLowerCase();
            if (cname == 'mods.json' || cname == 'mods.txt') {
              try {
                await child.delete();
              } catch (_) {}
            }
          }
        } else {
          // 其他顶层目录（理论上不应存在）：直接删
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
  }

  /// 把源 ue4ss/ 下的"框架文件"复制到目标（保留 Mods/ 下用户 mod 子目录）。
  ///
  /// 复制对象：
  /// - 顶层文件：UE4SS.dll / LICENSE / *.ini
  /// - Mods/mods.json、Mods/mods.txt（模板文件）
  /// - 创建空的 Mods/ 目录（让 UE4SS 启动时知道 mod 注册表位置）
  ///
  /// 跳过：Mods/<user_mod>/（已在注入前由 deployMods 流程单独管理）
  static Future<void> _copyFrameworkFiles(
    Directory src,
    Directory dest,
  ) async {
    await dest.create(recursive: true);
    for (final entity in src.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final lowerName = name.toLowerCase();
      if (entity is File) {
        // 顶层文件：直接拷
        await entity.copy(p.join(dest.path, name));
        continue;
      }
      if (entity is Directory) {
        if (lowerName == 'mods') {
          // Mods/：创建空目录，拷模板文件，但**不**递归拷 mod 子目录
          final destMods = Directory(p.join(dest.path, 'Mods'));
          await destMods.create(recursive: true);
          for (final child in entity.listSync(followLinks: false)) {
            if (child is! File) continue;
            final cname = p.basename(child.path);
            final clname = cname.toLowerCase();
            if (clname == 'mods.json' || clname == 'mods.txt') {
              await child.copy(p.join(destMods.path, cname));
            }
            // mod 子目录跳过（由 deployMods 流程管理）
          }
        } else {
          // 顶层非 Mods 目录（理论上不存在）：递归拷
          await _copyDir(entity, Directory(p.join(dest.path, name)));
        }
      }
    }
  }

  /// 删除本地 UE4SS mod 文件夹。
  static Future<void> deleteLocal(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 删除游戏目录中部署过的 UE4SS mod 文件夹。
  ///
  /// 全异步 IO（exists / delete 都不阻塞 isolate），失败仅吞掉——被锁文件留到下次。
  static Future<void> reclaimFromGame(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 被锁或不存在——忽略，下次扫描 rescue 会恢复
    }
  }

  /// 扫描本地 `ue4ss_runtime/ue4ss/Mods/` 下的所有 mod 子目录，返回 (目录名, 绝对路径) 列表。
  static List<({String name, String path})> scanLocal(String exeDir) {
    final root = Directory(localRoot(exeDir));
    if (!root.existsSync()) return const [];
    final out = <({String name, String path})>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final probe = _probeDirectory(entity);
      if (probe != Ue4ssProbe.valid) continue;
      out.add((name: p.basename(entity.path), path: entity.path));
    }
    return out;
  }

  /// 计算一个 UE4SS mod 文件夹的总字节数（UI 显示用）。
  static int dirSize(String dirPath) {
    var total = 0;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// 提取 UE4SS mod 文件夹下的"特征子目录"列表（用于 UI 副标题展示）。
  static List<String> detectSubDirs(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final found = <String>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        final n = p.basename(entity.path);
        if (_markerDirs.contains(n.toLowerCase())) found.add(n);
      } else if (entity is File) {
        final n = p.basename(entity.path);
        if (_markerFiles.contains(n.toLowerCase())) found.add(n);
      }
    }
    found.sort();
    return found;
  }

  // ===== UE4SS 框架注入/回收（启动游戏时把宿主 dll + 框架文件复制进游戏） =====

  /// 默认 UE4SS 宿主 dll 文件名（dwmapi.dll 改名注入是 UE4SS 主流加载方式）。
  static const String _frameworkDllName = 'dwmapi.dll';

  /// 把 UE4SS 框架（`frameworkPath` 下整个内容）复制到游戏 `Binaries/Win64/`。
  ///
  /// 框架源结构（典型）：
  /// ```
  /// <frameworkPath>/
  ///   dwmapi.dll          ← 注入到游戏 Win64 根
  ///   ue4ss/              ← 整个文件夹复制到 Win64/
  ///     UE4SS.dll
  ///     UE4SS-settings.ini
  ///     Mods/ ...
  /// ```
  ///
  /// 目标：游戏目录的 `Binaries/Win64/`。
  ///
  /// 行为：
  /// - 复制 `dwmapi.dll` → `<gameBinaries>/dwmapi.dll`
  /// - 复制 `ue4ss/` 整个文件夹 → `<gameBinaries>/ue4ss/`
  ///   （覆盖式：先清空目标 `ue4ss/`，再整目录递归拷贝，避免 stale 文件残留）
  ///
  /// 注意事项：
  /// - **目标已存在的 `ue4ss/Mods/<玩家手动部署的 mod>` 会被清空**——
  ///   主人确认接受该权衡（整体被本管理器接管）。
  /// - 注入失败不会抛异常，只记日志（让游戏启动流程继续）。
  static Future<void> injectFrameworkToGame({
    required String frameworkPath,
    required String gameBinariesDir,
  }) async {
    final srcRoot = Directory(frameworkPath);
    if (!srcRoot.existsSync()) {
      AppLogger.instance.warning('UE4SS 框架注入跳过：源路径不存在', {
        'framework_path': frameworkPath,
      });
      return;
    }
    final dstRoot = Directory(gameBinariesDir);
    if (!dstRoot.existsSync()) {
      AppLogger.instance.warning('UE4SS 框架注入跳过：游戏 Binaries 目录不存在', {
        'game_binaries_dir': gameBinariesDir,
      });
      return;
    }

    // 复制 dwmapi.dll（宿主 dll 改名注入）
    final srcDll = File(p.join(frameworkPath, _frameworkDllName));
    if (srcDll.existsSync()) {
      try {
        await srcDll.copy(p.join(gameBinariesDir, _frameworkDllName));
        AppLogger.instance.info('UE4SS 框架：复制宿主 dll', {
          'source': srcDll.path,
          'destination': p.join(gameBinariesDir, _frameworkDllName),
        });
      } catch (e) {
        AppLogger.instance.error('UE4SS 框架：复制宿主 dll 失败', {
          'source': srcDll.path,
          'error': e.toString(),
        });
      }
    } else {
      AppLogger.instance.info('UE4SS 框架：源目录无 dwmapi.dll，跳过宿主 dll 注入', {
        'framework_path': frameworkPath,
      });
    }

    // 复制 ue4ss/ 整个文件夹（但跳过 Mods/ 下的用户 mod 子目录）
    //
    // 部署流程：
    // 1. 框架注入阶段：复制 UE4SS.dll / LICENSE / *.ini / Mods/mods.json / Mods/mods.txt
    //    → 把 UE4SS 框架准备好。
    // 2. mod 部署阶段（紧随其后，由 deployMods 循环里的 _deployUe4ssMod 触发）：
    //    单独复制本地 `Mods/<user_mod>/` 到游戏 `ue4ss/Mods/<user_mod>/`。
    //
    // 因此框架注入只覆盖**框架文件 + 空 Mods/**，不碰 Mods/ 下用户 mod 子目录
    // ——避免和后续 mod 部署时序竞态，也避免注入阶段把刚部署的 mod 又清掉。
    final srcUe4ss = Directory(p.join(frameworkPath, 'ue4ss'));
    if (!srcUe4ss.existsSync()) {
      AppLogger.instance.warning('UE4SS 框架注入跳过：源目录无 ue4ss/ 子目录', {
        'framework_path': frameworkPath,
      });
      return;
    }
    final dstUe4ss = Directory(p.join(gameBinariesDir, 'ue4ss'));
    try {
      // 先清空目标的"框架文件"部分（UE4SS.dll / LICENSE / *.ini），不动 Mods/
      // 下的用户 mod 子目录——让 mod 部署阶段独立处理。
      if (dstUe4ss.existsSync()) {
        await _clearFrameworkFilesOnly(dstUe4ss);
      }
      // 再逐项拷贝（顶层文件 + 非 Mods 的目录 + Mods/ 下的模板文件）
      await _copyFrameworkFiles(srcUe4ss, dstUe4ss);
      AppLogger.instance.info('UE4SS 框架：复制 ue4ss/（跳过用户 mod 子目录）到游戏目录', {
        'source': srcUe4ss.path,
        'destination': dstUe4ss.path,
      });
    } catch (e) {
      AppLogger.instance.error('UE4SS 框架：复制 ue4ss/ 失败', {
        'source': srcUe4ss.path,
        'destination': dstUe4ss.path,
        'error': e.toString(),
      });
    }
  }

  /// 从游戏 `Binaries/Win64/` 删掉本管理器注入的 UE4SS 框架。
  ///
  /// 删除对象：
  /// - `<gameBinaries>/dwmapi.dll`（如存在）
  /// - `<gameBinaries>/ue4ss/`（整个目录，如存在）
  ///
  /// **全异步 IO**：exists / delete 都 await，避免被 OS 文件锁阻塞 isolate
  /// 导致 UI 卡顿。
  static Future<void> reclaimFrameworkFromGame({
    required String gameBinariesDir,
  }) async {
    final binDir = Directory(gameBinariesDir);
    if (!await binDir.exists()) return;

    // 删 ue4ss/ 整个文件夹
    final ue4ssDir = Directory(p.join(gameBinariesDir, 'ue4ss'));
    if (await ue4ssDir.exists()) {
      try {
        await ue4ssDir.delete(recursive: true);
        AppLogger.instance.info('UE4SS 框架回收：删除 ue4ss/', {
          'path': ue4ssDir.path,
        });
      } catch (e) {
        AppLogger.instance.error('UE4SS 框架回收失败', {
          'path': ue4ssDir.path,
          'error': e.toString(),
        });
      }
    }

    // 删宿主 dll（dwmapi.dll）
    final dllFile = File(p.join(gameBinariesDir, _frameworkDllName));
    if (await dllFile.exists()) {
      try {
        await dllFile.delete();
        AppLogger.instance.info('UE4SS 框架回收：删除宿主 dll', {
          'path': dllFile.path,
        });
      } catch (e) {
        AppLogger.instance.error('UE4SS 框架回收：删除宿主 dll 失败', {
          'path': dllFile.path,
          'error': e.toString(),
        });
      }
    }
  }
}

/// UE4SS 探测结果。
enum Ue4ssProbe {
  /// 合规的 UE4SS mod（目录或 zip）。
  valid,

  /// 不是 UE4SS mod（路径根本不是 mod，或者是其他文件类型）。
  invalid,

  /// 是 zip，但内部结构不是 UE4SS mod。
  /// 调用方应按"解压失败 / 非 UE4SS zip"处理。
  zipInvalid,
}