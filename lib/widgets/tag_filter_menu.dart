/// 共享标签组件包 —— 两个三面板复用的自绘组件：
///
/// 1. [ScumTagFilterMenu]：工具栏「标签筛选」下拉菜单（Overlay LayerLink 定位）。
///    - 内置搜索框：按原文 / 拼音 / 首字母实时过滤（复用 PinyinSearch）；
///    - 标签列表可滚动：内容超过菜单最大高度时内部滚动，不再撑爆窗口；
///    - 顶部工具行：已选计数 + 全选（当前过滤结果）+ 清空；
///    - 固定宽度 + 最大高度约束：长标签裁剪不撑宽，宽高问题一并修正。
///
/// 2. [ScumTagsRow]：表格行内标签条（宽度自适应 + 更多/更少）。
///    - 按可用宽度自动排布：能放下几个显示几个，放不下的自动折叠隐藏；
///    - 折叠时右侧显示「+N」溢出胶囊，点击展开显示全部标签，再点「更少」收起；
///    - 展开后仍超出列宽的部分由外层列宽裁剪（不撑破行布局）。
library;

import 'package:flutter/material.dart';

import '../services/pinyin_search.dart';
import '../theme/scum_colors.dart';

// =====================================================================
//  行内标签条（宽度自适应 + 更多/更少）
// =====================================================================

/// 行内标签横条。三个面板（本地/云上/远程）的行「标签」列统一使用。
class ScumTagsRow extends StatefulWidget {
  final List<String> tags;

  /// 是否启用（禁用态下芯片颜色减淡，与整行禁用视觉一致）。
  final bool enabled;

  /// 由父级传入（行内已取过一次，避免重复 of(context)）。
  final ScumColors colors;

  const ScumTagsRow({
    super.key,
    required this.tags,
    required this.colors,
    this.enabled = true,
  });

  @override
  State<ScumTagsRow> createState() => _ScumTagsRowState();
}

class _ScumTagsRowState extends State<ScumTagsRow> {
  bool _expanded = false;

  static const double _chipHPad = 8; // 芯片横向 padding（4+4）
  static const double _chipHSpace = 3; // 芯片间距
  static const double _overflowChipW = 36; // 「+N」/「更少」胶囊宽度
  static const TextStyle _chipStyle = TextStyle(
    fontSize: 9,
    decoration: TextDecoration.none,
  );

  /// 测量单个标签芯片的宽度（文本 + 两侧 padding）。
  double _chipWidth(String tag) {
    final painter = TextPainter(
      text: TextSpan(text: tag, style: _chipStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width + _chipHPad;
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.tags;
    final colors = widget.colors;
    final enabled = widget.enabled;

    if (tags.isEmpty) {
      return Text(
        '—',
        style: TextStyle(
          color: colors.textDim,
          fontSize: 11,
          decoration: TextDecoration.none,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;

        // 折叠模式：按顺序放入「能放下的标签」，放不下即隐藏，溢出数由
        // 「+N」胶囊表达。空宽（约束异常）时退化为显示前 2 个。
        final shown = <String>[];
        if (maxW > 0) {
          var used = 0.0;
          for (final t in tags) {
            final w = _chipWidth(t);
            final need = shown.isEmpty ? w : _chipHSpace + w;
            // 保留溢出胶囊的位置 —— 放不下就走折叠。
            if (used + need + _overflowChipW + _chipHSpace > maxW) break;
            used += need;
            shown.add(t);
          }
        } else {
          shown.addAll(tags.take(2));
        }
        final hidden = tags.length - shown.length;

        // 展开模式：全部标签 + 「更少」收起胶囊（超宽部分由外层列宽裁剪）。
        final list = _expanded ? tags : shown;
        final showOverflowChip = !_expanded && hidden > 0;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in list) ...[
              _chip(t, colors, enabled),
              if (t != list.last) SizedBox(width: _chipHSpace),
            ],
            if (showOverflowChip) ...[
              const SizedBox(width: _chipHSpace),
              _overflowChip('+$hidden', colors, expanded: true),
            ] else if (_expanded) ...[
              const SizedBox(width: _chipHSpace),
              _overflowChip('更少', colors, expanded: false),
            ],
          ],
        );
      },
    );
  }

  Widget _chip(String tag, ScumColors colors, bool enabled) {
    final accent = colors.accent;
    final chipColors =
        enabled ? accent.withValues(alpha: 0.12) : accent.withValues(alpha: 0.06);
    final textColors =
        enabled ? accent : accent.withValues(alpha: 0.45);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: chipColors,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: accent.withValues(alpha: enabled ? 0.25 : 0.12),
        ),
      ),
      child: Text(
        tag,
        style: TextStyle(
          color: textColors,
          fontSize: 9,
          decoration: TextDecoration.none,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 「+N / 更少」胶囊：accent 实底，点击切换展开态。
  Widget _overflowChip(String label, ScumColors colors,
      {required bool expanded}) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = expanded),
      child: Container(
        width: _overflowChipW,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colors.accent,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  工具栏「标签筛选」下拉菜单（搜索 + 滚动 + 多选）
// =====================================================================

/// 标签筛选菜单本体（LayerLink 悬挂定位）。checkbox 多选，不自动关闭，
/// 点菜单外部 dismiss。
class ScumTagFilterMenu extends StatefulWidget {
  final LayerLink layerLink;
  final List<String> sortedTags;
  final Set<String> selectedTags;
  final ValueChanged<Set<String>> onTagsChanged;
  final VoidCallback onDismiss;

  /// 菜单最大高度（内容超出时标签列表区内部滚动）。
  final double maxHeight;

  const ScumTagFilterMenu({
    super.key,
    required this.layerLink,
    required this.sortedTags,
    required this.selectedTags,
    required this.onTagsChanged,
    required this.onDismiss,
    this.maxHeight = 360,
  });

  @override
  State<ScumTagFilterMenu> createState() => _ScumTagFilterMenuState();
}

class _ScumTagFilterMenuState extends State<ScumTagFilterMenu> {
  late Set<String> _selected;
  final TextEditingController _queryCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selectedTags);
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 按搜索词过滤（原文 / 拼音 / 首字母）。
  List<String> get _filteredTags {
    final q = _query.trim();
    if (q.isEmpty) return widget.sortedTags;
    return widget.sortedTags
        .where((t) => PinyinSearch.matches(t, q))
        .toList();
  }

  void _toggle(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else {
        _selected.add(tag);
      }
    });
    widget.onTagsChanged(Set<String>.from(_selected));
  }

  void _selectAll() {
    final t = _filteredTags;
    if (t.isEmpty) return;
    setState(() => _selected.addAll(t));
    widget.onTagsChanged(Set<String>.from(_selected));
  }

  void _clearAll() {
    setState(() => _selected.clear());
    widget.onTagsChanged({});
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final filtered = _filteredTags;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onDismiss,
      child: CompositedTransformFollower(
        link: widget.layerLink,
        offset: const Offset(0, 32),
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.topLeft,
        child: UnconstrainedBox(
          alignment: Alignment.topLeft,
          child: Container(
            width: 220,
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: colors.bgCard,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.borderStrong),
              boxShadow: [
                BoxShadow(
                  color: colors.shadowSm,
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── 菜单内搜索框（支持原文 / 拼音 / 首字母）──
                _TagSearchInput(
                  controller: _queryCtrl,
                  onChanged: (v) => setState(() => _query = v),
                ),
                Container(height: 1, color: colors.border),
                // ── 工具行：已选计数 + 全选（当前过滤结果）+ 清空 ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '已选 ${_selected.length}',
                        style: TextStyle(
                          color: colors.textDim,
                          fontSize: 10,
                          fontFamily: 'Consolas',
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const Spacer(),
                      _toolButton('全选', colors, onTap: _selectAll),
                      const SizedBox(width: 4),
                      _toolButton('清空', colors, onTap: _clearAll),
                    ],
                  ),
                ),
                Container(height: 1, color: colors.border),
                // ── 标签列表（内容超出时内部滚动）──
                Flexible(
                  child: filtered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _query.trim().isEmpty
                                ? '暂无标签'
                                : '未找到「${_query.trim()}」',
                            style: TextStyle(
                              color: colors.textDim,
                              fontSize: 11,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(bottom: 4),
                          itemCount: filtered.length,
                          itemBuilder: (context, i) => _TagOption(
                            label: filtered[i],
                            selected: _selected.contains(filtered[i]),
                            onTap: () => _toggle(filtered[i]),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolButton(String label, ScumColors colors, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: colors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 10,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// 菜单内自绘搜索输入框（EditableText，与工具栏搜索框视觉一致）。
class _TagSearchInput extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _TagSearchInput({required this.controller, required this.onChanged});

  @override
  State<_TagSearchInput> createState() => _TagSearchInputState();
}

class _TagSearchInputState extends State<_TagSearchInput> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onChanged(widget.controller.text);
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
      color: colors.bgDark.withValues(alpha: 0.35),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 14, color: colors.textDim),
          const SizedBox(width: 6),
          Expanded(
            child: EditableText(
              controller: widget.controller,
              focusNode: _focusNode,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 12,
                decoration: TextDecoration.none,
                fontFamily: 'sans-serif',
              ),
              cursorColor: colors.accent,
              backgroundCursorColor: colors.textDim,
              selectionColor: colors.accent.withValues(alpha: 0.3),
            ),
          ),
          if (widget.controller.text.isNotEmpty)
            GestureDetector(
              onTap: _clear,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: _focused ? colors.accent : colors.textDim,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 标签菜单单行选项（checkbox + 标签名，选中态 accent 高亮 + 左条）。
class _TagOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TagOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final color = selected ? colors.accent : colors.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.20)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}