import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// SCUM 风格简约 Logo —— 抽象字母"S"的简化形态。
///
/// 从 [TitleBar] 拆出独立文件：Logo 形态/颜色未来可能独立调整，
/// 单独存放避免改 logo 时误伤标题栏其他视觉（图标尺寸、标题文本、窗口按钮）。
///
/// [color] 默认走 [ScumColors.brandLogo]（两态一致的中性灰）—— 品牌色，
/// 跟主题无关，亮/暗态保持一致。调用方可显式传入自定义颜色（如 splash
/// 用 `colors.accent` 提亮）。
class ScumLogo extends StatelessWidget {
  final double size;
  final Color? color;

  const ScumLogo({
    super.key,
    required this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final stroke = color ?? ScumColors.of(context).brandLogo;
    return CustomPaint(
      size: Size(size, size),
      painter: _ScumLogoPainter(strokeColor: stroke),
    );
  }
}

class _ScumLogoPainter extends CustomPainter {
  final Color strokeColor;

  _ScumLogoPainter({required this.strokeColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 2;

    canvas.drawCircle(center, r, paint);

    final path = Path()
      ..moveTo(center.dx - r * 0.4, center.dy - r * 0.5)
      ..lineTo(center.dx + r * 0.3, center.dy - r * 0.5)
      ..lineTo(center.dx + r * 0.4, center.dy)
      ..lineTo(center.dx - r * 0.4, center.dy)
      ..lineTo(center.dx - r * 0.3, center.dy + r * 0.5)
      ..lineTo(center.dx + r * 0.4, center.dy + r * 0.5);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ScumLogoPainter oldDelegate) =>
      oldDelegate.strokeColor != strokeColor;
}
