/// 自绘滚动条 —— 替代 Material 默认 Scrollbar，保持项目「全自绘」约束。
///
/// 用法：
/// ```dart
/// ScumScrollbar(
///   controller: _scrollCtrl,
///   child: ListView.builder(
///     controller: _scrollCtrl,
///     itemCount: ...,
///     itemBuilder: ...,
///   ),
/// )
/// ```
///
/// 行为：
/// - 滚动条**固定右侧**（右对齐，距右边缘 [rightPadding]）。
/// - **固定宽度** [_kScrollbarThumbWidth]（4px），hover/拖拽不变宽，
///   仅拇指颜色变化（默认浅灰 → hover accent 金）。
/// - **可交互**：拖拽 thumb 滚动、点击轨道上下翻页（80% 视口）。
/// - 内容未溢出（maxScrollExtent <= 0）时整条不绘制。
library;

import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// 滚动条交互热区宽度（逻辑 px）。
///
/// 云 mod 卡片 margin 为 horizontal 12 —— 卡片右缘距容器右 12px。
/// 热区必须 < 12px，否则会压在卡片右缘、挡住下载按钮点击。
/// 取 8px：thumb(固定 4px) + 边距，覆盖卡片 margin 空隙，不碰卡片本身。
const double _kScrollbarHitArea = 8.0;

/// 滚动条拇指固定宽度（逻辑 px）—— hover/拖拽不变宽。
const double _kScrollbarThumbWidth = 4.0;

/// 自绘垂直滚动条。
///
/// 用 [controller] 关联到具体 [ListView] / [ListView.builder] / [ReorderableListView]，
/// 滚动时实时同步拇指位置；拖拽 thumb 直接 jumpTo 控制滚动。
class ScumScrollbar extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  /// 滚动条距右边缘的内边距（像素）。
  final double rightPadding;

  const ScumScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.rightPadding = 2,
  });

  @override
  State<ScumScrollbar> createState() => _ScumScrollbarState();
}

class _ScumScrollbarState extends State<ScumScrollbar> {
  bool _hovered = false;
  bool _dragging = false;

  /// 拖拽起点（p.pixels 在 onVerticalDragStart 时快照）——
  /// 保留作 debug / 未来扩展用，update 时不再累加（避免边界锁死）。
  double _dragStartOffset = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        // ListView 显式铺满 —— tight 约束保证有界高度
        Positioned.fill(child: widget.child),

        // 右侧滚动条热区（可交互）
        Positioned(
          top: 0,
          bottom: 0,
          right: widget.rightPadding,
          width: _kScrollbarHitArea,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 安全取位：排序等场景下列表可能在 Reorderable↔ListView 间切换，
              // 切换帧里新旧两个滚动体可能同时绑定同一 controller（positions
              // 短暂为 2），直接用 .position（内部 positions.single）会抛
              // "Bad state: Too many elements" 导致自绘滚动条整帧渲染失败。
              // 这里用 positions.first 并加空守卫，让切换帧平滑过渡。
              if (!widget.controller.hasClients) return const SizedBox.shrink();
              final positions = widget.controller.positions;
              if (positions.isEmpty) return const SizedBox.shrink();
              final pos = positions.first;
              if (pos.maxScrollExtent <= 0) return const SizedBox.shrink();

              final viewportH = constraints.maxHeight;
              final contentH = viewportH + pos.maxScrollExtent;
              var thumbH = (viewportH * viewportH / contentH).clamp(24.0, viewportH);
              // 固定宽度：hover/拖拽只变颜色，不变宽
              final thumbW = _kScrollbarThumbWidth;
              final scrollableH = (viewportH - thumbH).clamp(0.0, viewportH);
              final thumbTop = pos.maxScrollExtent == 0
                  ? 0.0
                  : (pos.pixels / pos.maxScrollExtent) * scrollableH;

              return MouseRegion(
                cursor: SystemMouseCursors.basic,
                onEnter: (_) {
                  if (mounted) setState(() => _hovered = true);
                },
                onExit: (_) {
                  if (mounted) setState(() => _hovered = false);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (d) {
                    setState(() => _dragging = true);
                    _dragStartOffset = pos.pixels;
                  },
                  onVerticalDragUpdate: (d) {
                    if (!widget.controller.hasClients) return;
                    final p = widget.controller.position;
                    // 用「当前真实位置 + 本次增量」而不是「drag 起点 + 累计增量」——
                    // 旧版把累加结果 clamp 回 _dragStartOffset 后会锁死边界：
                    // 拖到顶部时 _dragStartOffset 锁 0，后续 ratio * maxScrollExtent
                    // 仍可能 ≤ 0，thumb 卡住不动。用户必须松手重新点才能继续拖。
                    // 新版每帧基于 p.pixels 当前值算 target，自然 clamp 不锁死。
                    final ratio = d.delta.dy / scrollableH;
                    final target = (p.pixels + ratio * p.maxScrollExtent)
                        .clamp(0.0, p.maxScrollExtent);
                    _dragStartOffset = target;
                    p.jumpTo(target);
                  },
                  onVerticalDragEnd: (_) {
                    if (mounted) setState(() => _dragging = false);
                  },
                  onVerticalDragCancel: () {
                    if (mounted) setState(() => _dragging = false);
                  },
                  onTapDown: (d) {
                    if (!widget.controller.hasClients) return;
                    final p = widget.controller.position;
                    if (d.localPosition.dy < thumbTop) {
                      p.jumpTo((p.pixels - viewportH * 0.8).clamp(0.0, p.maxScrollExtent));
                    } else if (d.localPosition.dy > thumbTop + thumbH) {
                      p.jumpTo((p.pixels + viewportH * 0.8).clamp(0.0, p.maxScrollExtent));
                    }
                  },
                  child: CustomPaint(
                    painter: _ScrollbarPainter(
                      thumbColor: _hovered || _dragging
                          ? colors.accent.withValues(alpha: 0.85)
                          : colors.textDim.withValues(alpha: 0.80),
                      trackColor: colors.border.withValues(alpha: 0.45),
                      thumbTop: thumbTop,
                      thumbHeight: thumbH,
                      width: thumbW,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 滚动条 painter —— 画一条细轨道 + 一个拇指，右对齐。
class _ScrollbarPainter extends CustomPainter {
  final Color thumbColor;
  final Color trackColor;
  final double thumbTop;
  final double thumbHeight;
  final double width;

  _ScrollbarPainter({
    required this.thumbColor,
    required this.trackColor,
    required this.thumbTop,
    required this.thumbHeight,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 右对齐：轨道贴 painter 的右边缘
    final trackLeft = size.width - width;
    final trackRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(trackLeft, 0, width, size.height),
      Radius.circular(width / 2),
    );
    canvas.drawRRect(trackRRect, Paint()..color = trackColor);

    final thumbRect = Rect.fromLTWH(trackLeft, thumbTop, width, thumbHeight);
    final thumbRRect = RRect.fromRectAndRadius(
      thumbRect,
      Radius.circular(width / 2),
    );
    canvas.drawRRect(thumbRRect, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _ScrollbarPainter old) {
    return old.thumbColor != thumbColor ||
        old.trackColor != trackColor ||
        old.thumbTop != thumbTop ||
        old.thumbHeight != thumbHeight ||
        old.width != width;
  }
}