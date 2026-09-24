import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/app_signals.dart';
import '../theme/scum_colors.dart';
import '../theme/scum_theme.dart';

/// 标题栏暗亮主题切换滑块 —— 36px 高的紧凑滑块。
///
/// 设计要点：
/// - **两态**（不是三态）：只支持暗色 ↔ 亮色。主人明确要求"滑块控件"，
///   不放"跟随系统"选项（那应该在系统设置里改）。
/// - **滑块 + 点击 toggle**：拖动滑块手柄平滑切换（松手吸附到端点），
///   任意点击槽体也可直接翻转当前状态。
/// - **零内联颜色**：暗端用 [colors.bgDark]，亮端用 [ScumTheme.bgDarkLight]，
///   跟随主题保持自身对比度。
/// - **滚动条铁律**：本 widget 不引入任何滚动条。
class ThemeToggleSlider extends StatefulWidget {
  const ThemeToggleSlider({super.key});

  @override
  State<ThemeToggleSlider> createState() => _ThemeToggleSliderState();
}

class _ThemeToggleSliderState extends State<ThemeToggleSlider> {
  /// 滑块进度：0 = 暗色，1 = 亮色。
  double _progress = 0;

  static const double _width = 48;
  static const double _height = 20;
  static const double _knobSize = 14;
  static const double _padding = 3;

  @override
  void initState() {
    super.initState();
    // 同步 AppSignals.themeMode 初始值（默认 dark → 0）。
    _progress = AppSignals.themeMode.value == ThemeMode.light ? 1 : 0;
    // 监听外部变化（如果别的 widget 改了 themeMode）。
    AppSignals.themeMode.addListener(_onExternalChange);
  }

  @override
  void dispose() {
    AppSignals.themeMode.removeListener(_onExternalChange);
    super.dispose();
  }

  void _onExternalChange() {
    final target = AppSignals.themeMode.value == ThemeMode.light ? 1.0 : 0.0;
    if ((_progress - target).abs() > 0.01) {
      setState(() => _progress = target);
    }
  }

  void _commitProgress(double p) {
    setState(() => _progress = p);
    final mode = p > 0.5 ? ThemeMode.light : ThemeMode.dark;
    if (AppSignals.themeMode.value != mode) {
      AppSignals.themeMode.value = mode;
      AppLogger.instance.ui(
        '外观主题',
        action: '滑块切换',
        details: {'mode': mode.name},
      );
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final dx = d.delta.dx / (_width - _knobSize - 2 * _padding);
    setState(() => _progress = (_progress + dx).clamp(0.0, 1.0));
  }

  void _onPanEnd(DragEndDetails _) {
    // 吸附到最近的端点。
    final snapped = _progress < 0.5 ? 0.0 : 1.0;
    _commitProgress(snapped);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final isDark = _progress < 0.5;
    final knobX = _padding + (_progress * (_width - _knobSize - 2 * _padding));

    // 两端图标始终同显（暗端=月亮，亮端=太阳），提供"这里能切换光暗"的
    // 永久视觉标识。当前激活端用 accent 高亮，非激活端用 textDim 弱化——
    // 手柄滑到哪一端，哪一端就被遮住，反而形成"已选择"的天然反馈。
    final leftColor = isDark ? colors.accent : colors.textDim;
    final rightColor = !isDark ? colors.accent : colors.textDim;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 任意点击 → 翻转当前主题（toggle）。点哪都一样，不必瞄准。
        onTapUp: (_) {
          final next = _progress < 0.5 ? 1.0 : 0.0;
          _commitProgress(next);
        },
        // 拖动手柄。
        onHorizontalDragUpdate: _onPanUpdate,
        onHorizontalDragEnd: _onPanEnd,
        child: Container(
          width: _width,
          height: _height,
          decoration: BoxDecoration(
            color: colors.bgCard,
            borderRadius: BorderRadius.circular(_height / 2),
            border: Border.all(color: colors.border, width: 1),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 暗端月亮（左）—— 始终可见，激活时高亮。
              Positioned(
                left: 3,
                top: 3,
                bottom: 3,
                width: _knobSize,
                child: Icon(
                  Icons.dark_mode_rounded,
                  size: 10,
                  color: leftColor,
                ),
              ),
              // 亮端太阳（右）—— 始终可见，激活时高亮。
              Positioned(
                right: 3,
                top: 3,
                bottom: 3,
                width: _knobSize,
                child: Icon(
                  Icons.light_mode_rounded,
                  size: 10,
                  color: rightColor,
                ),
              ),
              // 滑块手柄。
              Positioned(
                left: knobX,
                top: _padding,
                bottom: _padding,
                width: _knobSize,
                child: Container(
                  decoration: BoxDecoration(
                    // 滑块颜色：暗主题用 accent 提亮，亮主题用 accentShadow 压暗，
                    // 让两个主题下手柄都显眼但风格统一。
                    color: isDark ? colors.accent : colors.accentShadow,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: colors.bgDark.withValues(alpha: 0.5),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
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
