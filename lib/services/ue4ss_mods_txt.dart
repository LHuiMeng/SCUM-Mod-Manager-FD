import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'ue4ss_framework_service.dart';

/// UE4SS `mods.txt` 同步服务（单文件模块）。
///
/// 用途：把 [ModService] 中所有 UE4SS mod 的启用状态一次性同步到本地运行时
/// `ue4ss_runtime/ue4ss/Mods/mods.txt`，启动游戏时它会被复制到游戏目录。
///
/// 文件格式：
/// ```
/// CheatManagerEnablerMod : 1
/// ActorDumperMod : 0
/// ...
/// ; Built-in keybinds, do not move up!
/// Keybinds : 1
/// ```
/// 每行 `<ModName> : <0|1>`。
///
/// 设计要点：
/// - **只动我们管理的 mod 行**——Keybinds 等框架内置 mod 行由 UE4SS 自己
///   首次启动时写入，本服务不触碰。
/// - **如何识别"哪些行是我们管的"**：用一个隐藏的标记文件
///   `.scum_mm_managed.txt`，逐行存本管理器写过的 mod 名字。每次 sync 时：
///   1. 读旧标记文件 → 知道"哪些旧 mod 行是我们管的"（可能含已删除 mod）
///   2. 过滤掉那些旧行（连同它们）→ 重写 mods.txt
///   3. 把新 mod 名字列表写进标记文件
/// - **用户行追加位置**：先尝试插入到 `Keybinds : 1` 行**之前**——遵循 UE4SS
///   "mod 行必须早于 Keybinds 才能正确加载" 的规则（见 mem:582bf518）。
///   若 Keybinds 行不存在，则追加到文件末尾。
/// - **错误兜底**：写文件失败 → 只记日志不抛异常，不影响 mod 启停/删除主流程。
class Ue4ssModsTxt {
  Ue4ssModsTxt._();

  /// 行格式：`Name : 0|1`（首尾空白允许）。
  static final RegExp _lineRe = RegExp(r'^\s*(\S+)\s*:\s*([01])\s*$');

  /// `Keybinds : 1` 这一行的特征（UE4SS 在首次启动时会写入）。
  static const String _keybindsMarker = 'Keybinds';

  /// 隐藏标记文件名：跟踪本管理器管过的 mod 名字（用于 sync 时清旧行）。
  static const String _managedNamesFile = '.scum_mm_managed.txt';

  /// `mods.txt` 绝对路径（本地运行时）。
  static String get filePath =>
      p.join(Ue4ssFrameworkService.frameworkPath(), 'ue4ss', 'Mods', 'mods.txt');

  /// 标记文件绝对路径。
  static String get _managedNamesPath =>
      p.join(Ue4ssFrameworkService.frameworkPath(), 'ue4ss', 'Mods', _managedNamesFile);

  /// 把传入的 mod 列表（按 [name] + [enabled] 同步）写入 mods.txt。
  ///
  /// [mods] 应是当前所有 UE4SS mod 的快照（任意顺序）。
  /// - 每个 mod 写一行 `Name : 1`（启用）或 `Name : 0`（禁用）
  /// - 我们之前管理的旧行（标记文件里）→ 全部删除（包括已删除 mod 的行）
  /// - 其他行（包括 Keybinds、注释、空行）保留原位
  /// - 用户行优先插到 `Keybinds : 1` 行之前，没有 Keybinds 行则追加到末尾
  static Future<void> sync(List<({String name, bool enabled})> mods) async {
    final file = File(filePath);
    final ourLines = <String>[
      for (final m in mods) '${m.name} : ${m.enabled ? 1 : 0}',
    ];
    final currentNames = {for (final m in mods) m.name};

    // 1. 读旧标记文件 → 知道哪些旧行是我们管的
    final previouslyManaged = await _readManagedNames();

    // 2. 读 mods.txt 现有内容（不存在则当空文件处理）
    List<String> existing = const [];
    if (await file.exists()) {
      try {
        existing = await file.readAsLines();
      } catch (e) {
        AppLogger.instance.warning('UE4SS mods.txt 读取失败，将覆盖写入', {
          'path': file.path,
          'error': e.toString(),
        });
        existing = const [];
      }
    }

    // 3. 过滤旧行：
    //   - 是 mod 行（匹配 `_lineRe`）且名字在 previouslyManaged → 跳过（删/替换）
    //   - 其他行（Keybinds、注释、空行、不在我们旧集合的 mod 行）→ 保留
    final kept = <String>[];
    for (final line in existing) {
      final m = _lineRe.firstMatch(line);
      if (m != null && previouslyManaged.contains(m.group(1))) {
        continue;
      }
      kept.add(line);
    }

    // 4. 把我们的行插入到 Keybinds 行之前；若没有 Keybinds 行则追加到末尾
    int insertIdx = kept.length;
    for (int i = 0; i < kept.length; i++) {
      final line = kept[i];
      if (line.toLowerCase().contains(_keybindsMarker.toLowerCase()) &&
          _lineRe.hasMatch(line)) {
        insertIdx = i;
        break;
      }
    }
    final newContent = <String>[
      ...kept.sublist(0, insertIdx),
      ...ourLines,
      ...kept.sublist(insertIdx),
    ];

    // 5. 写 mods.txt
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(_joinLines(newContent));
    } catch (e) {
      AppLogger.instance.error('UE4SS mods.txt 写入失败', {
        'path': file.path,
        'error': e.toString(),
      });
      return;
    }

    // 6. 更新标记文件：本次 mod 名字列表（base64 编码后每行一个）。
    // 用 base64 而不是 join('\n')：旧版 join('\n') 在 mod 名带换行时会被
    // 截断成两个假名字，下次 sync 时 `_readManagedNames` 误读为两个 mod，
    // 误删无辜的 mods.txt 行。base64 是单行 ASCII 安全字符，杜绝歧义。
    try {
      final encoded = currentNames.map((n) => base64Encode(utf8.encode(n)));
      await File(_managedNamesPath).writeAsString(encoded.join('\n'));
    } catch (e) {
      AppLogger.instance.warning('UE4SS 标记文件写入失败（不影响 mods.txt）', {
        'path': _managedNamesPath,
        'error': e.toString(),
      });
    }

    AppLogger.instance.info('UE4SS mods.txt 已同步', {
      'path': file.path,
      'user_mod_count': ourLines.length,
      'preserved_lines': kept.length,
    });
  }

  /// 读取标记文件中的旧 mod 名字集合。
  ///
  /// 文件中每行是 base64(mod_name) —— 读时先 base64 解码还原 mod 名。
  /// 兼容旧版 join('\n') 格式：解码失败时按原字符串回退（不抛错）。
  static Future<Set<String>> _readManagedNames() async {
    final f = File(_managedNamesPath);
    if (!await f.exists()) return <String>{};
    try {
      final lines = await f.readAsLines();
      final names = <String>{};
      for (final l in lines) {
        final trimmed = l.trim();
        if (trimmed.isEmpty) continue;
        try {
          names.add(utf8.decode(base64Decode(trimmed)));
        } catch (_) {
          // 旧版（直接写名字，无 base64 编码）—— 原样作为 mod 名加入。
          names.add(trimmed);
        }
      }
      return names;
    } catch (_) {
      return <String>{};
    }
  }

  /// 拼接为文件内容（末尾保留一个换行符——UE4SS 解析器要求）。
  static String _joinLines(List<String> lines) {
    if (lines.isEmpty) return '';
    return '${lines.join('\n')}\n';
  }
}