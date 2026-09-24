import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 日志严重级别。
enum LogLevel { debug, info, warning, error, ui }

/// 日志严重级别扩展（解析 + 显示）。
extension LogLevelX on LogLevel {
  String get tag {
    switch (this) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
      case LogLevel.ui:
        return 'UI';
    }
  }

  static LogLevel? fromTag(String tag) {
    switch (tag) {
      case 'DEBUG':
        return LogLevel.debug;
      case 'INFO':
        return LogLevel.info;
      case 'WARN':
        return LogLevel.warning;
      case 'ERROR':
        return LogLevel.error;
      case 'UI':
        return LogLevel.ui;
    }
    return null;
  }
}

/// 解析后的单行日志条目。
class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.details,
    this.raw = '',
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final Map<String, Object?> details;
  final String raw;

  String get timestampText =>
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}.'
      '${timestamp.millisecond.toString().padLeft(3, '0')}';
}

/// 应用统一日志服务。
///
/// 默认关闭日志写入。用户需在「运行日志」页手动勾选「启用日志」后，
/// 才以程序启动时间命名日志文件并开始写入。
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  /// 程序启动时间（单例构造时定格，用于日志文件名）。
  final DateTime _startupTime = DateTime.now();

  static const int _maxLogBytes = 5 * 1024 * 1024;
  bool _initialized = false;
  bool _writingFailure = false;
  bool _enabled = false;

  String get logDirectoryPath =>
      p.join(AppPaths.instance.root, 'logs');

  /// 日志文件名 = 程序启动时间，如 `2026-08-09_15-30-07.log`。
  String get logFilePath => p.join(
        logDirectoryPath,
        '${_startupTime.year.toString().padLeft(4, '0')}-'
        '${_startupTime.month.toString().padLeft(2, '0')}-'
        '${_startupTime.day.toString().padLeft(2, '0')}_'
        '${_startupTime.hour.toString().padLeft(2, '0')}-'
        '${_startupTime.minute.toString().padLeft(2, '0')}-'
        '${_startupTime.second.toString().padLeft(2, '0')}.log',
      );

  /// 日志是否已启用写入。
  bool get enabled => _enabled;

  /// 启用/禁用日志写入。
  ///
  /// 启用时自动创建日志目录并写入启用的标记行。
  /// 禁用时停止所有文件写入（已有日志文件保留）。
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (_enabled) {
      _ensureDir();
      _record('INFO', '日志记录已启用', {
        'startup_time': _startupTime.toIso8601String(),
      });
    }
  }

  /// 确保日志目录存在。
  void _ensureDir() {
    if (_initialized) return;
    try {
      Directory(logDirectoryPath).createSync(recursive: true);
      _initialized = true;
    } catch (_) {}
  }

  void debug(String event, [Map<String, Object?> details = const {}]) {
    _record('DEBUG', event, details);
  }

  void info(String event, [Map<String, Object?> details = const {}]) {
    _record('INFO', event, details);
  }

  void warning(String event, [Map<String, Object?> details = const {}]) {
    _record('WARN', event, details);
  }

  void error(String event, [Map<String, Object?> details = const {}]) {
    _record('ERROR', event, details);
  }

  /// 记录用户点击或输入等 UI 行为。
  void ui(
    String control, {
    String action = '点击',
    Map<String, Object?> details = const {},
  }) {
    _record('UI', control, {'action': action, ...details});
  }

  /// 读取日志文件末尾内容（原始字符串），供轻量级 peek。
  String readRecent({int maxLines = 1600}) {
    _ensureDir();
    try {
      final file = File(logFilePath);
      if (!file.existsSync()) return '';
      final lines = file.readAsLinesSync();
      final start = lines.length > maxLines ? lines.length - maxLines : 0;
      return lines.sublist(start).join('\n');
    } catch (e, stack) {
      return '读取日志失败：$e\n$stack';
    }
  }

  /// 读取并解析日志为结构化条目，供 UI 高亮/筛选使用。
  ///
  /// 行格式：`[ISO时间] [LEVEL] event {json}`。
  List<LogEntry> readEntries({int maxLines = 2000}) {
    _ensureDir();
    final result = <LogEntry>[];
    try {
      final file = File(logFilePath);
      if (!file.existsSync()) return result;
      final lines = file.readAsLinesSync();
      final start = lines.length > maxLines ? lines.length - maxLines : 0;
      for (var i = start; i < lines.length; i++) {
        final parsed = _parseLine(lines[i]);
        if (parsed != null) result.add(parsed);
      }
    } catch (_) {
      // 静默吞掉解析异常；UI 仍能展示原始 readRecent()。
    }
    return result;
  }

  /// 解析单行日志；解析失败返回 null（保留原始内容但不入条目流）。
  static LogEntry? _parseLine(String line) {
    if (line.isEmpty) return null;
    // 期望：[2026-08-08T11:21:00.000] [INFO] event {json}
    final match = RegExp(
      r'^\[(?<ts>[^\]]+)\]\s+\[(?<level>[A-Z]+)\]\s+(?<rest>.*)$',
    ).firstMatch(line);
    if (match == null) return null;
    final tsText = match.namedGroup('ts');
    final levelTag = match.namedGroup('level');
    final rest = match.namedGroup('rest') ?? '';
    if (tsText == null || levelTag == null) return null;
    final level = LogLevelX.fromTag(levelTag);
    if (level == null) return null;
    final ts = DateTime.tryParse(tsText) ?? DateTime.now();

    var message = rest;
    var details = <String, Object?>{};
    final jsonStart = rest.indexOf('{');
    if (jsonStart >= 0 && rest.endsWith('}')) {
      final candidate = rest.substring(jsonStart);
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          details = decoded.map<String, Object?>(
            (k, v) => MapEntry(k.toString(), v as Object?),
          );
          message = rest.substring(0, jsonStart).trimRight();
        }
      } catch (_) {
        /* fall through as plain message */
      }
    }

    return LogEntry(
      timestamp: ts,
      level: level,
      message: message,
      details: details,
      raw: line,
    );
  }

  /// 清空当前日志文件，并保留一条清空记录。
  void clear() {
    // 仅当日志启用时清空才有意义
    if (!_enabled) return;
    _ensureDir();
    try {
      File(logFilePath).writeAsStringSync('');
      _record('INFO', '用户清空日志', const {});
    } catch (e) {
      _record('ERROR', '清空日志失败', {'error': e.toString()});
    }
  }

  void _record(String level, String event, Map<String, Object?> details) {
    if (!_enabled) return;
    if (!_initialized) _ensureDir();
    if (!_initialized || _writingFailure) return;

    try {
      final file = File(logFilePath);
      if (file.existsSync() && file.lengthSync() >= _maxLogBytes) {
        final archive = File('$logFilePath.1');
        if (archive.existsSync()) archive.deleteSync();
        file.renameSync(archive.path);
      }

      final timestamp = DateTime.now().toIso8601String();
      final suffix = details.isEmpty ? '' : ' ${_encodeDetails(details)}';
      file.writeAsStringSync(
        '[$timestamp] [$level] $event$suffix\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 防止日志异常递归写日志。
      _writingFailure = true;
    }
  }

  String _encodeDetails(Map<String, Object?> details) {
    try {
      return jsonEncode(details);
    } catch (_) {
      return jsonEncode(
        details.map((key, value) => MapEntry(key, value.toString())),
      );
    }
  }
}