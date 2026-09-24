import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 3c：自定义背景图服务 —— 读写 [config.json] 里的 `background_image_path`，
/// 并把用户选的图片**复制**到 `{exe_dir}/assets/background/current.{ext}`
/// （保证 exe 目录移动后图片仍可用）。
///
/// 设计决策：
/// - **复制而非引用**：用户可能选 `D:\Photos\foo.png` 这种临时路径，
///   复制到 exe 旁保证应用启动就能找到背景图，不依赖外部文件。
/// - **只保留一张**：用户每次选新图就覆盖 `current.{ext}`，避免
///   assets/background 目录堆积旧图。
/// - **扩展名保留**：保持原扩展名，让 `Image.file` 的类型推导正确。
class BackgroundService {
  static const String _configKey = 'background_image_path';
  static const String _subDir = 'assets/background';
  static const String _currentBaseName = 'current';

  /// exe 所在目录（绝对路径）。
  /// 走 AppPaths（v3：引导器注入 SCUM_MM_ROOT 定位安装根），不依赖 ModService。
  String get _exeDir => AppPaths.instance.root;

  /// 当前背景图的绝对路径（如果用户没选过或文件被删，返回 null）。
  ///
  /// 使用 [jsonDecode] 解析 config.json，与 ModService 的读写方式一致，
  /// 避免因正则操作产生非标准 JSON（未转义反斜杠等）导致 jsonDecode 失败。
  String? get currentBackgroundPath {
    final raw = _readConfigJson();
    final stored = raw[_configKey] as String?;
    if (stored == null || stored.isEmpty) return null;
    final file = File(stored);
    return file.existsSync() ? stored : null;
  }

  /// 把用户选的图片从 [sourcePath] 复制到 exe 目录旁，更新 config.json。
  /// 返回**新路径**（绝对路径）；失败返回 null。
  Future<String?> setBackground(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync()) return null;

      final assetsDir = Directory(p.join(_exeDir, _subDir));
      if (!assetsDir.existsSync()) assetsDir.createSync(recursive: true);

      final ext = p.extension(sourcePath).toLowerCase();
      final destPath = p.join(_exeDir, _subDir, '$_currentBaseName$ext');
      await src.copy(destPath);

      _writeConfigPath(destPath);
      return destPath;
    } catch (_) {
      return null;
    }
  }

  /// 清除背景图（删除复制文件 + 清空 config.json 中的字段）。
  Future<void> clearBackground() async {
    try {
      final assetsDir = Directory(p.join(_exeDir, _subDir));
      if (assetsDir.existsSync()) {
        for (final f in assetsDir.listSync()) {
          if (f is File &&
              p.basenameWithoutExtension(f.path) == _currentBaseName) {
            f.deleteSync();
          }
        }
      }
      _writeConfigPath('');
    } catch (_) {
      // best-effort
    }
  }

  /// 纯计算用：暴露给 UI 层（仅 debug 模式）方便看背景图落盘位置。
  @visibleForTesting
  String get debugExeDir => _exeDir;

  /// 用 [jsonDecode]/[jsonEncode] 读写 config.json，确保 JSON 格式正确。
  /// 避免之前正则操作产生的未转义反斜杠导致 ModService 的 jsonDecode 失败。
  void _writeConfigPath(String value) {
    final raw = _readConfigJson();
    raw[_configKey] = value;
    _writeConfigJson(raw);
  }

  /// 读取 config.json 并用 [jsonDecode] 解析，失败返回空 Map。
  Map<String, dynamic> _readConfigJson() {
    final f = File(p.join(_exeDir, 'config.json'));
    if (!f.existsSync()) return {};
    try {
      final data = jsonDecode(f.readAsStringSync());
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    return {};
  }

    /// 用带缩进的 JSON 序列化并写入 config.json（与 ModService 端保持一致）。
  void _writeConfigJson(Map<String, dynamic> data) {
    try {
      File(p.join(_exeDir, 'config.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    } catch (_) {}
  }
}
