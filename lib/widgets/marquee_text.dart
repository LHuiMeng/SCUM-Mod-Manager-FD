/// 横向滚动文本（marquee）—— 文本超出可用宽度时自动横向滚动显示全文。
///
/// 用法：放进有界宽度内（SizedBox / Expanded / Row 的 Expanded），
/// 自身撑满可用宽度；文本放得下时静态左对齐显示、不启动动画（零开销）。
///
/// 行为：
/// - **文本放得下**：静态左对齐（不做任何居中），不启动动画。
/// - **文本超宽**：滚动动画 —— 起点停留 → 滚到末尾 → 末尾停留 → 滚回起点，
///   循环往复，全程保持左对齐。
/// - 超宽判定用 [TextPainter] 测量单行文本宽度，与可用宽度比较。
library;

import 'package:flutter/material.dart';

/// 横向滚动文本。
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// 超宽时一次完整循环的总时长（默认按滚动距离自动缩放）。
  final Duration? duration;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.duration,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

/// 滚动曲线：一个循环 = 起点停留 → 滚到末尾 → 末尾停留 → 滚回起点 → 起点停留。
class _MarqueeCurve extends Curve {
  const _MarqueeCurve();

  @override
  double transformInternal(double t) {
    if (t < 0.10) return 0.0; // 起点停留
    if (t < 0.55) return (t - 0.10) / 0.45; // 滚到末尾
    if (t < 0.70) return 1.0; // 末尾停留
    if (t < 0.90) return 1.0 - (t - 0.70) / 0.20; // 滚回起点
    return 0.0; // 起点停留
  }
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _textWidth = 0;
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this);
    _measure();
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _measure();
      // 文本变化：停掉旧动画，交给 build 重新评估是否超宽
      _ctrl
        ..stop()
        ..value = 0;
      _overflow = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 用 TextPainter 量出单行文本宽度（maxLines:1 + softWrap:false）。
  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;
  }

  /// 超宽状态变化时启动/停止滚动动画。
  void _syncAnimation(double available) {
    final overflow = _textWidth > available;
    if (overflow == _overflow) return;
    _overflow = overflow;
    if (overflow) {
      final dist = _textWidth - available;
      _ctrl
        ..duration =
            widget.duration ??
            Duration(
              milliseconds: (1500 + dist * 1.5).round().clamp(2500, 12000),
            )
        ..repeat();
    } else {
      _ctrl
        ..stop()
        ..value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        _syncAnimation(available);

        final text = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: widget.style,
        );

        return ClipRect(
          child: Align(
            // 始终左对齐，不做居中
            alignment: Alignment.centerLeft,
            heightFactor: 1.0,
            child: _overflow
                ? AnimatedBuilder(
                    animation: _ctrl,
                    child: text,
                    builder: (context, child) {
                      final t = const _MarqueeCurve().transform(_ctrl.value);
                      return Transform.translate(
                        offset: Offset(-(_textWidth - available) * t, 0),
                        child: child,
                      );
                    },
                  )
                : text,
          ),
        );
      },
    );
  }
}
