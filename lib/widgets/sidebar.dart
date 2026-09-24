import 'package:flutter/material.dart';

import '../theme/scum_theme.dart';
import '../theme/scum_colors.dart';

/// 可折叠侧边导航栏。
///
/// 折叠时只显示图标（56px 宽）；
/// 展开时显示图标 + 文字标签（180px 宽）。
/// 切换状态由 [_expanded] 控制，动画用 [AnimatedSize]。
///
/// 锚定：左侧固定，向右展开、从右向左收缩（[Alignment.centerLeft]）。
/// 选中状态：[selected] 是当前激活 tab 的 id。
/// 点击条目触发 [onSelected]，让上层切换页面。
class Sidebar extends StatefulWidget {
  final bool initiallyExpanded;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback? onSettingsSelected;
  final VoidCallback? onModsSelected;
  final VoidCallback? onLogsSelected;

  const Sidebar({
    super.key,
    this.initiallyExpanded = true,
    required this.selected,
    required this.onSelected,
    this.onSettingsSelected,
    this.onModsSelected,
    this.onLogsSelected,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> with SingleTickerProviderStateMixin {
  late bool _expanded;
  late AnimationController _widthCtrl;
  static const double _widthCollapsed = 56;
  static const double _widthExpanded = 180;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    // AnimationController 只在 _toggle 主动改 _expanded 时跑动画；窗口
    // resize 时（父级 Row reflow）不触发这里 —— 侧边栏宽度直接同步到
    // 当前 _expanded 对应的 _widthCollapsed / _widthExpanded，无动画。
    _widthCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _widthCtrl.value = _expanded ? 1.0 : 0.0;
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _widthCtrl.forward();
    } else {
      _widthCtrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return AnimatedBuilder(
      animation: _widthCtrl,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_widthCtrl.value);
        final width = _widthCollapsed + (_widthExpanded - _widthCollapsed) * t;
        return Container(
          width: width,
          decoration: BoxDecoration(
            // 半透明让自定义背景图透过
            color: colors.bgDark.withValues(alpha: 0.82),
            // 左侧两角圆角：与窗口外层 ClipRRect 对齐。
            // 折叠时只需要 topLeft（顶部和 TitleBar 相接处），展开后 topLeft+bottomLeft
            // 都圆——保持视觉一致。
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(ScumTheme.windowCornerRadius),
              bottomLeft: Radius.circular(ScumTheme.windowCornerRadius),
            ),
          ),
          child: Column(
            children: [
              // 折叠/展开按钮（永远在最顶端）。
              _SidebarToggleButton(expanded: _expanded, onTap: _toggle),

              const SizedBox(height: 8),

              // 主要条目。
              _SidebarItem(
                icon: Icons.inventory_2_outlined,
                selectedIcon: Icons.inventory_2_rounded,
                label: '模组管理',
                selected: widget.selected == 'mods',
                expanded: _expanded,
                onTap: () {
                  widget.onSelected('mods');
                  widget.onModsSelected?.call();
                },
              ),

              _SidebarItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: '设置',
                selected: widget.selected == 'settings',
                expanded: _expanded,
                onTap: () {
                  widget.onSelected('settings');
                  widget.onSettingsSelected?.call();
                },
              ),

              _SidebarItem(
                icon: Icons.cloud_outlined,
                selectedIcon: Icons.cloud_rounded,
                label: '云上mod',
                selected: widget.selected == 'cloud_mods',
                expanded: _expanded,
                onTap: () {
                  widget.onSelected('cloud_mods');
                },
              ),

              _SidebarItem(
                icon: Icons.dns_outlined,
                selectedIcon: Icons.dns_rounded,
                label: '远程服务器',
                selected: widget.selected == 'server_mods',
                expanded: _expanded,
                onTap: () {
                  widget.onSelected('server_mods');
                },
              ),

              _SidebarItem(
                icon: Icons.receipt_long_outlined,
                selectedIcon: Icons.receipt_long_rounded,
                label: '运行日志',
                selected: widget.selected == 'logs',
                expanded: _expanded,
                onTap: () {
                  widget.onSelected('logs');
                  widget.onLogsSelected?.call();
                },
              ),

              const Spacer(),
            ],
          ),
        );
      },
    );
  }
}

/// 折叠/展开按钮（顶部，独立样式）。
class _SidebarToggleButton extends StatefulWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _SidebarToggleButton({required this.expanded, required this.onTap});

  @override
  State<_SidebarToggleButton> createState() => _SidebarToggleButtonState();
}

class _SidebarToggleButtonState extends State<_SidebarToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: _hovered ? colors.bgHover : Colors.transparent,
            ),
            child: SizedBox(
              height: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // chevron 在折叠/展开时旋转 180° —— 让方向变化更明显。
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeInOutCubic,
                    turns: widget.expanded
                        ? 0
                        : 0.5, // 0 = 左箭头 (展开态), 0.5 = 右箭头 (折叠态)
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                  ),
                  // "折叠" 文字用 AnimatedSwitcher —— 展开时淡入、折叠时淡出。
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: widget.expanded
                        ? Padding(
                            key: ValueKey('collapse-label'),
                            padding: EdgeInsets.only(left: 6),
                            child: Text(
                              '折叠',
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 12,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('collapse-empty'),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边栏条目选中态 —— 鼠标悬停时背景加亮。
class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final selected = widget.selected;
    final expanded = widget.expanded;
    final color = selected ? colors.accent : colors.textSecondary;
    // 背景优先级：选中 > hover > 透明。
    final Color bgColor = selected
        ? colors.accent.withValues(alpha: 0.12)
        : (_hovered ? colors.bgHover : Colors.transparent);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
              border: Border(
                left: BorderSide(
                  color: selected ? colors.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? widget.selectedIcon : widget.icon,
                  size: 18,
                  color: color,
                ),
                // 文字标签跟着 AnimatedSize 平滑出现 —— 用 AnimatedSwitcher
                // 而不是直接 if-else，让 label 淡入淡出。
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: expanded
                      ? Padding(
                          key: ValueKey(
                            '${widget.label}-${selected ? 'on' : 'off'}',
                          ),
                          padding: const EdgeInsets.only(left: 10),
                          child: Text(
                            widget.label,
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              letterSpacing: 0.5,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('label-empty')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
