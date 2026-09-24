import 'package:flutter/material.dart';

import '../theme/scum_theme.dart';

/// 自绘卡片行内紧凑型操作按钮（删除、设置等）。
/// 无 InkWell/Material/Tooltip，全部自绘。
///
/// A4 微动效：hover 时 scale 到 1.06（用 AnimatedScale 平滑过渡）；
/// 同时背景色 alpha 微增，让按钮"抬"出来。
class CardActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final Color? hoverColor;
  final VoidCallback onTap;

  const CardActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.hoverColor,
  });

  @override
  State<CardActionButton> createState() => _CardActionButtonState();
}

class _CardActionButtonState extends State<CardActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final displayColor = _hovered
        ? (widget.hoverColor ?? widget.color)
        : widget.color;
    // A4：hover alpha 比普通态高 0.08，配合 scale 1.06 让按钮"弹"出来。
    final bgAlpha = _hovered ? (0.12 + ScumTheme.hoverAlphaBoost) : 0.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            // 120ms 过渡，比 Material 默认的快，避免拖拽重排时"粘"。
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            scale: _hovered ? ScumTheme.hoverScale : 1.0,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: displayColor.withValues(alpha: bgAlpha),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Icon(widget.icon, size: 16, color: displayColor),
            ),
          ),
        ),
      ),
    );
  }
}
