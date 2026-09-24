import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 拖拽区域使用的虚线圆角矩形 + 四角 L 形括号动画 painter。
///
/// 抽出来独立成文件：
/// - 这是一个 pure painter，未来如果要给其他 overlay（如 ServerPicker）
///   复用同款动效，只需直接 import 这一个文件。
/// - painter 的算法（路径测量 + 虚线步进 + 角括号 arms）跟调用方解耦，
///   改 painter 不会污染 drop zone overlay 的状态管理/事件处理代码。
class DashedBorderPainter extends CustomPainter {
  /// 0.0 ~ 1.0，0 = 完全淡出，1 = 完全显示。
  final double progress;
  final Color color;

  DashedBorderPainter({required this.progress, required this.color});

  // 视觉参数集中管理。
  static const double _strokeWidth = 2.5;
  static const double _dashLength = 12.0;
  static const double _dashGap = 6.0;
  static const double _cornerStrokeWidth = 3.5;
  static const double _cornerArmLength = 28.0;
  static const double _cornerInset = 12.0;
  static const double _cornerRadius = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9 * progress)
      ..strokeWidth = _strokeWidth
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_cornerRadius),
    );
    final path = Path()..addRRect(rrect);

    _drawDashed(canvas, path, paint, _dashLength, _dashGap);

    // 四角 L 形括号 —— 随 progress 画出长度。
    final cornerPaint = Paint()
      ..color = color
      ..strokeWidth = _cornerStrokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final t = progress;
    final inset = _cornerInset;

    void corner(Offset o, Offset dx, Offset dy) {
      canvas.drawLine(o, o + dx * (_cornerArmLength * t), cornerPaint);
      canvas.drawLine(o, o + dy * (_cornerArmLength * t), cornerPaint);
    }

    // 左上
    corner(Offset(inset, inset), const Offset(1, 0), const Offset(0, 1));
    // 右上
    corner(
      Offset(size.width - inset, inset),
      const Offset(-1, 0),
      const Offset(0, 1),
    );
    // 左下
    corner(
      Offset(inset, size.height - inset),
      const Offset(1, 0),
      const Offset(0, -1),
    );
    // 右下
    corner(
      Offset(size.width - inset, size.height - inset),
      const Offset(-1, 0),
      const Offset(0, -1),
    );
  }

  void _drawDashed(
    Canvas canvas,
    Path path,
    Paint paint,
    double dash,
    double gap,
  ) {
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      double dist = 0.0;
      while (dist < m.length) {
        final next = math.min<double>(dist + dash, m.length);
        canvas.drawPath(m.extractPath(dist, next), paint);
        dist = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedBorderPainter old) =>
      old.progress != progress || old.color != color;
}
