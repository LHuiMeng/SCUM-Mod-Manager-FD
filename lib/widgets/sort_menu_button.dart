/// 自绘排序菜单按钮 —— 三处列表（模组管理 / 远程服务器 / 云上 mod）统一复用。
///
/// 点击弹出下拉单选菜单（LayerLink 跟随按钮定位，点外部 dismiss），
/// 选中项高亮 accent，点击即生效并关闭。全部自绘，无 Material 控件。
library;

import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// 单个排序选项。
class SortMenuItem {
  /// 排序模式标识（如 'default' / 'nameAsc' / 'sizeDesc' / 'timeDesc'）。
  final String value;

  /// 菜单显示的文案（如「名称 A→Z」「大小 大→小」）。
  final String label;

  /// 是否当前选中。
  final bool selected;

  /// 点击回调（由调用方 setState 切换排序并关闭菜单）。
  final VoidCallback onTap;

  const SortMenuItem({
    required this.value,
    required this.label,
    required this.selected,
    required this.onTap,
  });
}

/// 排序按钮本身（按钮文案 = 当前选中项 label）。
class SortMenuButton extends StatefulWidget {
  /// 当前选中排序的文案（如「名称 A→Z」）。
  final String label;

  /// 排序选项列表。
  final List<SortMenuItem> items;

  /// 提示文案（hover tooltip）。
  final String tooltip;

  const SortMenuButton({
    super.key,
    required this.label,
    required this.items,
    this.tooltip = '排序',
  });

  @override
  State<SortMenuButton> createState() => _SortMenuButtonState();
}

class _SortMenuButtonState extends State<SortMenuButton> {
  bool _hovered = false;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  void _toggleMenu() {
    if (_overlayEntry != null) {
      try {
        _overlayEntry!.remove();
      } catch (_) {}
      _overlayEntry = null;
    } else {
      _overlayEntry = _buildOverlay();
      Overlay.of(context).insert(_overlayEntry!);
    }
  }

  OverlayEntry _buildOverlay() {
    return OverlayEntry(
      builder: (context) => _SortMenu(
        layerLink: _layerLink,
        items: widget.items,
        onDismiss: () {
          try {
            _overlayEntry?.remove();
          } catch (_) {}
          _overlayEntry = null;
        },
      ),
    );
  }

  @override
  void dispose() {
    try {
      _overlayEntry?.remove();
    } catch (_) {}
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
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
                Icon(Icons.sort_rounded, size: 14, color: colors.accent),
                const SizedBox(width: 4),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
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

/// 排序下拉菜单本体（单选，点选项即生效并关闭）。
class _SortMenu extends StatelessWidget {
  final LayerLink layerLink;
  final List<SortMenuItem> items;
  final VoidCallback onDismiss;

  const _SortMenu({
    required this.layerLink,
    required this.items,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onDismiss,
      child: CompositedTransformFollower(
        link: layerLink,
        offset: const Offset(0, 32),
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.topLeft,
        child: UnconstrainedBox(
          alignment: Alignment.topLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
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
                for (final item in items)
                  _SortOption(
                    label: item.label,
                    selected: item.selected,
                    onTap: () {
                      item.onTap();
                      onDismiss();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单行排序选项（选中项左侧 accent 条 + 高亮）。
class _SortOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SortOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 200,
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
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
              selected ? Icons.check_rounded : Icons.swap_vert_rounded,
              size: 14,
              color: selected ? colors.accent : colors.textDim,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? colors.accent : colors.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
