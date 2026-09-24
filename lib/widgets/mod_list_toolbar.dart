/// 自绘 PAK 列表工具栏：搜索、多标签筛选、冲突扫描、全选、反选。
///
/// 排序能力已移到列表表头：点击列头按该列排序，此处不再放置排序菜单。
///
/// 全部使用 [CustomPaint] / [Container] 自绘，无 Material 控件
library;

import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';
import 'tag_filter_menu.dart';

/// 工具栏高度常量。
///
/// A2 微调：44→48 —— 让按钮 hover 区更舒适、字号 12 时不挤。
const double _toolbarHeight = 48.0;

/// PAK 列表正上方的自绘操作栏。
class ModListToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final Set<String> allTags;

  /// 当前选中的标签集合（多选）。
  final Set<String> selectedTags;

  final ValueChanged<String> onSearchChanged;

  /// 标签筛选变化回调，参数为最新选中标签集合。
  final ValueChanged<Set<String>> onTagsChanged;

  final VoidCallback onSelectAll;
  final VoidCallback onInvertSelection;
  final int modCount;
  final int enabledCount;

  /// 是否显示 PAK 类型 mod（客户端 PAK + 服务端 PAK）。
  final bool showPak;

  /// 是否显示 UE4SS 类型 mod。
  final bool showUe4ss;

  /// PAK 显示切换回调。
  final VoidCallback? onShowPakChanged;

  /// UE4SS 显示切换回调。
  final VoidCallback? onShowUe4ssChanged;

  // ===== 冲突扫描 =====

  /// 冲突路径总数（0 = 无冲突；仅扫描报告存在时有意义）。
  final int conflictCount;

  /// 参与冲突的 mod 数量（按钮徽标显示用）。
  final int conflictedModCount;

  /// 是否正在扫描（按钮显示「扫描中」）。
  final bool conflictScanning;

  /// repak 不可用（按钮显示「未检测」）。
  final bool conflictUnavailable;

  /// 「只看冲突」筛选是否激活（按钮高亮）。
  final bool conflictsOnly;

  /// 点击冲突按钮回调（打开详情面板）。
  final VoidCallback? onConflictTap;

  const ModListToolbar({
    super.key,
    required this.searchController,
    required this.allTags,
    required this.selectedTags,
    required this.onSearchChanged,
    required this.onTagsChanged,
    required this.onSelectAll,
    required this.onInvertSelection,
    required this.modCount,
    required this.enabledCount,
    this.showPak = true,
    this.showUe4ss = true,
    this.onShowPakChanged,
    this.onShowUe4ssChanged,
    this.conflictCount = 0,
    this.conflictedModCount = 0,
    this.conflictScanning = false,
    this.conflictUnavailable = false,
    this.conflictsOnly = false,
    this.onConflictTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      height: _toolbarHeight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        decoration: BoxDecoration(
          // 半透明让自定义背景图透过
          color: colors.bgDark.withValues(alpha: 0.82),
        ),
        child: Row(
          children: [
            // ── 自绘搜索框
            _SearchField(
              controller: searchController,
              onChanged: onSearchChanged,
            ),
            const SizedBox(width: 8),

            // ── PAK / UE4SS 类型显示切换 ──
            _TypeToggleButton(
              label: 'PAK',
              icon: Icons.inventory_2_rounded,
              active: showPak,
              onTap: onShowPakChanged,
            ),
            const SizedBox(width: 6),
            _TypeToggleButton(
              label: 'UE4SS',
              icon: Icons.memory_rounded,
              active: showUe4ss,
              onTap: onShowUe4ssChanged,
            ),
            const SizedBox(width: 12),

            // ── 自绘多标签筛选 ──
            if (allTags.isNotEmpty) ...[
              _TagFilterButton(
                allTags: allTags,
                selectedTags: selectedTags,
                onTagsChanged: onTagsChanged,
              ),
              const SizedBox(width: 8),
            ],

            // ── 冲突扫描按钮 ──
            _ConflictButton(
              count: conflictedModCount,
              scanning: conflictScanning,
              unavailable: conflictUnavailable,
              activeFilter: conflictsOnly,
              onTap: onConflictTap,
            ),
            const SizedBox(width: 8),

            // ── 全选/不全选 ──
            _ToolbarIconButton(
              icon: enabledCount == modCount
                  ? Icons.deselect_rounded
                  : Icons.select_all_rounded,
              tooltip: enabledCount == modCount ? '不全选' : '全选',
              onTap: onSelectAll,
            ),
            const SizedBox(width: 4),

            // ── 反选 ──
            _ToolbarIconButton(
              icon: Icons.swap_horiz_rounded,
              tooltip: '反选',
              onTap: onInvertSelection,
            ),

            const Spacer(),

            // ── 启用计数 ──
            Text(
              '$enabledCount / $modCount',
              style: TextStyle(
                color: colors.textDim,
                fontSize: 12,
                fontFamily: 'Consolas',
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  自绘类型显示切换按钮
// =====================================================================

/// PAK / UE4SS 显示切换 —— active=true 高亮（accent），false 灰。
class _TypeToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  const _TypeToggleButton({
    required this.label,
    required this.icon,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? colors.accent.withValues(alpha: 0.15)
                : colors.bgCard,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active
                  ? colors.accent.withValues(alpha: 0.6)
                  : colors.border,
              width: active ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? colors.accent : colors.textDim,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: active ? colors.accent : colors.textSecondary,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
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
//  自绘搜索输入框
// =====================================================================

/// 自绘搜索输入框 —— 用 [EditableText] + 自绘背景/边框，无 Material 样式。
class _SearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
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
    final borderColor = _focused ? colors.borderAccent : colors.border;

    return SizedBox(
      width: 200,
      height: 28,
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: Container(
          decoration: BoxDecoration(
            color: colors.bgCard,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: borderColor, width: _focused ? 1.5 : 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              // 搜索图标
              Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.search_rounded,
                  size: 16,
                  color: colors.textDim,
                ),
              ),

              // 自绘文本输入
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

              // 清除按钮（输入不为空时显示）
              if (widget.controller.text.isNotEmpty)
                GestureDetector(
                  onTap: _clear,
                  child: Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: colors.textDim,
                    ),
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
//  自绘多标签筛选下拉按钮
// =====================================================================

/// 自绘多标签筛选按钮 —— 点击弹出多选菜单，无 Material DropdownButton。
class _TagFilterButton extends StatefulWidget {
  final Set<String> allTags;
  final Set<String> selectedTags;
  final ValueChanged<Set<String>> onTagsChanged;

  const _TagFilterButton({
    required this.allTags,
    required this.selectedTags,
    required this.onTagsChanged,
  });

  @override
  State<_TagFilterButton> createState() => _TagFilterButtonState();
}

class _TagFilterButtonState extends State<_TagFilterButton> {
  bool _hovered = false;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  void _toggleMenu() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    } else {
      _overlayEntry = _buildOverlay();
      Overlay.of(context).insert(_overlayEntry!);
    }
  }

  OverlayEntry _buildOverlay() {
    final sorted = widget.allTags.toList()..sort();
    return OverlayEntry(
      builder: (context) => ScumTagFilterMenu(
        layerLink: _layerLink,
        sortedTags: sorted,
        selectedTags: widget.selectedTags,
        onTagsChanged: (updated) {
          widget.onTagsChanged(updated);
          // 不关闭菜单，让用户继续选择
        },
        onDismiss: () {
          _overlayEntry?.remove();
          _overlayEntry = null;
        },
      ),
    );
  }

  @override
  void dispose() {
    // OverlayEntry.remove() 可能在 _overlay 已被框架置空时抛 — try-catch
    // 兜底（项目约定：所有 _entry?.remove() 必须包 try-catch）。
    try {
      _overlayEntry?.remove();
    } catch (_) {}
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final count = widget.selectedTags.length;
    final label = count > 0 ? '标签 ($count)' : '标签筛选';
    final hasSelection = count > 0;

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: _toggleMenu,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered ? colors.bgHover : colors.bgCard,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.label_rounded,
                  size: 14,
                  color: hasSelection ? colors.accent : colors.textDim,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: hasSelection ? colors.accent : colors.textDim,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 16,
                  color: colors.textDim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  自绘冲突扫描按钮
// =====================================================================

/// 冲突扫描状态按钮 —— 点击打开冲突详情面板。
///
/// 视觉状态：有冲突 → 红色计数；无冲突 → 绿色「无冲突」；
/// 扫描中 → 灰色「扫描中」；repak 缺失 → 灰色「未检测」；只看冲突筛选
/// 激活 → 金色描边高亮。
class _ConflictButton extends StatefulWidget {
  /// 参与冲突的 mod 数量（0 = 无冲突）。
  final int count;

  /// 是否正在扫描。
  final bool scanning;

  /// repak 工具缺失。
  final bool unavailable;

  /// 「只看冲突」筛选激活（金色高亮）。
  final bool activeFilter;

  final VoidCallback? onTap;

  const _ConflictButton({
    required this.count,
    required this.scanning,
    required this.unavailable,
    required this.activeFilter,
    required this.onTap,
  });

  @override
  State<_ConflictButton> createState() => _ConflictButtonState();
}

class _ConflictButtonState extends State<_ConflictButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final count = widget.count;
    final hasConflict = count > 0;
    // 主色：冲突红 / 无冲突绿 / 其他灰
    final Color main;
    String label;
    String tooltip;
    if (widget.unavailable) {
      main = colors.textDim;
      label = '未检测';
      tooltip = '未找到 repak.exe，无法扫描冲突';
    } else if (widget.scanning) {
      main = colors.textDim;
      label = '扫描中';
      tooltip = '正在读取已启用 PAK 的内部资源清单';
    } else if (!hasConflict) {
      main = colors.success;
      label = '无冲突';
      tooltip = '已启用 PAK 资源路径互不重叠，点击查看详情';
    } else {
      main = colors.dangerLight;
      label = '冲突 $count';
      tooltip = '$count 个已启用 mod 存在资源冲突，点击查看详情';
    }

    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: hasConflict
                  ? colors.dangerLight.withValues(alpha: 0.12)
                  : _hovered
                      ? colors.bgHover
                      : colors.bgCard,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: widget.activeFilter
                    ? colors.accent
                    : hasConflict
                        ? colors.dangerLight.withValues(alpha: 0.5)
                        : colors.border,
                width: widget.activeFilter ? 1.2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hasConflict
                      ? Icons.warning_amber_rounded
                      : widget.scanning
                          ? Icons.sync_rounded
                          : Icons.check_circle_outline_rounded,
                  size: 14,
                  color: main,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: main,
                    fontSize: 11,
                    fontWeight:
                        hasConflict || widget.activeFilter
                            ? FontWeight.w700
                            : FontWeight.w400,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  自绘工具栏图标按钮
// =====================================================================

/// 自绘图标按钮 —— 无 InkWell/Material，纯手绘 hover 态。
class _ToolbarIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ToolbarIconButton> createState() => _ToolbarIconButtonState();
}

class _ToolbarIconButtonState extends State<_ToolbarIconButton> {
  bool _hovered = false;
  bool _showTooltip = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() {
        _hovered = true;
        _showTooltip = true;
      }),
      onExit: (_) => setState(() {
        _hovered = false;
        _showTooltip = false;
      }),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 自绘背景
              Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _hovered
                        ? colors.accent.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: _hovered ? colors.accent : colors.textSecondary,
                  ),
                ),
              ),
              // 自绘 tooltip
              if (_showTooltip)
                Positioned(
                  top: -28,
                  left: 0,
                  right: 0,
                  child: UnconstrainedBox(
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.border,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        widget.tooltip,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 10,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}