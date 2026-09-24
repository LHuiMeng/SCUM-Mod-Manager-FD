import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../theme/scum_colors.dart';
import '../widgets/scrollbar_painter.dart';

/// 日志查看页。
///
/// 日志同时持续写入 exe 同级 `logs/scum_mod_manager.log`，此页面负责：
/// - 自动刷新（每秒一次）
/// - 级别筛选（DEBUG / INFO / WARN / ERROR / UI 五档多选）
/// - 着色高亮（每档级别一个主题色；时间戳、JSON 详情分别配色）
/// - 手动刷新 / 清空
///
/// 面板布局：
///   ┌────────────────────────────────────────────┐
///   │ 顶部工具栏：标题 + 路径 + 筛选chips + 按钮 │
///   ├────────────────────────────────────────────┤
///   │ 日志条目区（占满剩余高度，逐行 RichText）  │
///   └────────────────────────────────────────────┘
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  Timer? _refreshTimer;
  final ScrollController _scrollController = ScrollController();

  /// 当前显示的级别集合；空集合 = 显示全部。
  final Set<LogLevel> _selectedLevels = <LogLevel>{};

  /// 最近一次解析的日志条目（按时间正序）。
  List<LogEntry> _entries = const [];

  /// 日志写入开关状态（与 AppLogger 同步）。
  bool _loggingEnabled = false;

  @override
  void initState() {
    super.initState();
    _loggingEnabled = AppLogger.instance.enabled;
    _reload();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _reload() {
    final entries = AppLogger.instance.readEntries();
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  void _toggleLogging() {
    final newVal = !_loggingEnabled;
    AppLogger.instance.setEnabled(newVal);
    setState(() {
      _loggingEnabled = newVal;
    });
    // 切换后立即重载一次，让 UI 反映变化
    _reload();
  }

  void _clear() {
    AppLogger.instance.ui('日志页：清空日志', action: '点击');
    AppLogger.instance.clear();
    _reload();
  }

  void _toggleLevel(LogLevel level) {
    AppLogger.instance.ui(
      '日志筛选',
      action: '切换',
      details: {
        'level': level.tag,
        'enabled': !_selectedLevels.contains(level),
      },
    );
    setState(() {
      if (_selectedLevels.contains(level)) {
        _selectedLevels.remove(level);
      } else {
        _selectedLevels.add(level);
      }
    });
  }

  /// 当前过滤生效后的可见条目集合。
  List<LogEntry> get _visibleEntries {
    if (_selectedLevels.isEmpty) return _entries;
    return _entries.where((e) => _selectedLevels.contains(e.level)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(colors),
        Expanded(child: _buildBody(colors)),
      ],
    );
  }

  Widget _buildToolbar(ScumColors colors) {
    return Container(
      height: 56,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
              // 半透明让自定义背景图透过
              color: colors.bgDark.withValues(alpha: 0.82),
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.receipt_long_rounded, size: 17, color: colors.accent),
          const SizedBox(width: 8),
          Text(
            '运行日志',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 12),
          // ── 级别筛选 chips ──
          for (final level in LogLevel.values) ...[
            _LevelChip(
              level: level,
              active: _selectedLevels.contains(level),
              onTap: () => _toggleLevel(level),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 6),
          // ── 日志启用/禁用 ──
          _LogToggleButton(
            active: _loggingEnabled,
            onTap: _toggleLogging,
          ),
          const SizedBox(width: 6),
          const Spacer(),
          _LogIconButton(
            icon: Icons.refresh_rounded,
            label: '刷新日志',
            onTap: () {
              AppLogger.instance.ui('日志页：刷新日志', action: '点击');
              _reload();
            },
          ),
          const SizedBox(width: 6),
          _LogIconButton(
            icon: Icons.delete_sweep_outlined,
            label: '清空日志',
            onTap: _clear,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ScumColors colors) {
    final entries = _visibleEntries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPathBar(colors, visibleCount: entries.length),
        Expanded(child: _buildLogArea(colors, entries)),
      ],
    );
  }

  /// 文件路径条 —— 不再被"框中框"挤压，单行 strip 在工具栏下方。
  Widget _buildPathBar(ScumColors colors, {required int visibleCount}) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
              // 半透明让自定义背景图透过
              color: colors.bgDark.withValues(alpha: 0.82),
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.description_outlined, size: 12, color: colors.textDim),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _loggingEnabled
                  ? AppLogger.instance.logFilePath
                  : '日志未启用',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textDim,
                fontSize: 10,
                fontFamily: 'Consolas',
                decoration: TextDecoration.none,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$visibleCount / ${_entries.length} 条',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 10,
              fontFamily: 'Consolas',
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogArea(ScumColors colors, List<LogEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _entries.isEmpty ? '暂无日志' : '当前筛选下没有匹配的日志条目',
          style: TextStyle(
            color: colors.textDim,
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      );
    }
    return Container(
          // 半透明让自定义背景图透过
          color: colors.bgDark.withValues(alpha: 0.82),
          child: ScumScrollbar(
            controller: _scrollController,
            child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: entries.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemBuilder: (context, index) => RepaintBoundary(
          child: _LogEntryRow(entry: entries[index]),
        ),
      ),
          ),
    );
  }
}

// =====================================================================
//  级别筛选 chip
// =====================================================================

class _LevelChip extends StatefulWidget {
  final LogLevel level;
  final bool active;
  final VoidCallback onTap;

  const _LevelChip({
    required this.level,
    required this.active,
    required this.onTap,
  });

  @override
  State<_LevelChip> createState() => _LevelChipState();
}

class _LevelChipState extends State<_LevelChip> {
  bool _hovered = false;

  Color get _levelColor {
    final colors = ScumColors.of(context);
    switch (widget.level) {
      case LogLevel.debug:
        return colors.logDebug;
      case LogLevel.info:
        return colors.textPrimary;
      case LogLevel.warning:
        return colors.accent;
      case LogLevel.error:
        return colors.danger;
      case LogLevel.ui:
        return colors.logUi;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final base = _levelColor;
    final dim = _hovered
        ? base
        : base.withValues(alpha: widget.active ? 1.0 : 0.55);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: widget.active
                ? dim.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: widget.active ? dim : colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: dim, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                widget.level.tag,
                style: TextStyle(
                  color: dim,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Consolas',
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  日志条目行（RichText 多色）
// =====================================================================

class _LogEntryRow extends StatelessWidget {
  final LogEntry entry;

  const _LogEntryRow({required this.entry});

  Color _levelColor(ScumColors colors) {
    switch (entry.level) {
      case LogLevel.debug:
        return colors.logDebug;
      case LogLevel.info:
        return colors.textPrimary;
      case LogLevel.warning:
        return colors.accent;
      case LogLevel.error:
        return colors.danger;
      case LogLevel.ui:
        return colors.logUi;
    }
  }

  String get _levelLabel {
    final tag = entry.level.tag;
    return tag.padRight(5); // 等宽对齐：DEBUG 5 / INFO 4+WARN 4+ERROR 5
  }

  String _formatDetails() {
    if (entry.details.isEmpty) return '';
    final parts = <String>[];
    entry.details.forEach((k, v) {
      parts.add('"$k":${_valueToString(v)}');
    });
    return '{${parts.join(', ')}}';
  }

  String _valueToString(Object? v) {
    if (v == null) return 'null';
    if (v is String) return '"$v"';
    if (v is num || v is bool) return v.toString();
    if (v is List) return '[${v.map(_valueToString).join(', ')}]';
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final levelColor = _levelColor(colors);
    final spans = <TextSpan>[
      // 时间戳
      TextSpan(
        text: entry.timestampText,
        style: TextStyle(
          color: colors.logTimestamp,
          fontFamily: 'Consolas',
          fontSize: 11,
        ),
      ),
      const TextSpan(text: '  '),
      // 级别标签（带方括号 + 等宽宽度）
      TextSpan(
        text: '[$_levelLabel]',
        style: TextStyle(
          color: levelColor,
          fontFamily: 'Consolas',
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      const TextSpan(text: '  '),
      // 消息主体
      TextSpan(
        text: entry.message,
        style: TextStyle(
          color: levelColor == colors.textPrimary
              ? colors.textPrimary
              : levelColor.withValues(alpha: 0.92),
          fontFamily: 'Consolas',
          fontSize: 11,
          fontWeight: entry.level == LogLevel.error
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
    ];
    final details = _formatDetails();
    if (details.isNotEmpty) {
      spans.addAll([
        const TextSpan(text: '  '),
        TextSpan(
          text: details,
          style: TextStyle(
            color: colors.textSecondary,
            fontFamily: 'Consolas',
            fontSize: 11,
          ),
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText.rich(
        TextSpan(children: spans),
        style: TextStyle(
          color: colors.textPrimary,
          fontFamily: 'Consolas',
          fontSize: 11,
          height: 1.4,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

// =====================================================================
//  工具栏图标按钮
// =====================================================================

class _LogIconButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LogIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_LogIconButton> createState() => _LogIconButtonState();
}

class _LogIconButtonState extends State<_LogIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _hovered
                ? colors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: _hovered ? colors.accent : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  自绘日志启用/禁用开关按钮
// =====================================================================

/// 日志写入开关按钮 —— 自绘 hover 态，无 Material 控件。
class _LogToggleButton extends StatefulWidget {
  final bool active;
  final VoidCallback onTap;

  const _LogToggleButton({
    required this.active,
    required this.onTap,
  });

  @override
  State<_LogToggleButton> createState() => _LogToggleButtonState();
}

class _LogToggleButtonState extends State<_LogToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final dim = _hovered
        ? colors.accent
        : widget.active
            ? colors.accent.withValues(alpha: 0.88)
            : colors.textDim.withValues(alpha: 0.55);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? colors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: widget.active
                  ? (dim)
                  : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.active ? dim : colors.textDim.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '日志',
                style: TextStyle(
                  color: dim,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Consolas',
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
