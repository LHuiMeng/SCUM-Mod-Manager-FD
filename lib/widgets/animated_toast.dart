import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// 灵活动画悬浮提示 —— 居中 + 自适应内容宽度。
///
/// 静态调用 `AutoDetectToast.show(context, message: '...')`，4 秒后自动消失。
/// 多次调用会替换前一条（不会有堆叠）。
///
/// 抽离要点：
/// - 把 `_entry` 缓存到类静态字段，避免多个 widget 各自创建不同的 OverlayEntry；
/// - `_AnimatedToastWidget` 仅负责视觉/动画，逻辑分离。
///
/// 颜色策略：[backgroundColor] 缺省时使用当前主题的 `success` token，
/// 这样亮色/暗色主题切换时 toast 颜色会跟着切。
class AutoDetectToast {
  AutoDetectToast._();

  static OverlayEntry? _entry;

  static void show(
      BuildContext context, {
      required String message,
      Color? backgroundColor,
      IconData icon = Icons.check_circle_rounded,
      Duration duration = const Duration(seconds: 4),
    }) {
      _entry?.remove();
      _entry = OverlayEntry(
        builder: (_) => _AnimatedToastWidget(
          message: message,
          backgroundColor: backgroundColor,
          icon: icon,
        ),
      );
      Overlay.of(context).insert(_entry!);

      Future.delayed(duration, () {
        _entry?.remove();
        _entry = null;
      });
    }
}

/// 实际渲染的 toast widget（透明度+平移进场动画）。
class _AnimatedToastWidget extends StatelessWidget {
  final String message;
  final Color? backgroundColor;
  final IconData icon;

  const _AnimatedToastWidget({
    required this.message,
    required this.backgroundColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final Color bgColor = backgroundColor ?? colors.success;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 30 * (1 - value)),
                child: child,
              ),
            ),
            child: IntrinsicWidth(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadowSm,
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
