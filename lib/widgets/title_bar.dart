import 'package:flutter/material.dart';

import '../services/app_signals.dart';
import '../services/update_service.dart';
import '../theme/scum_colors.dart';
import '../theme/scum_theme.dart';
import 'scum_logo.dart';
import 'theme_toggle_slider.dart';
import 'update_button.dart';
import 'window_buttons.dart';

/// 自绘标题栏（原生 HTCAPTION 拖拽，零闪烁）。
///
/// 高度固定 36px；左 Logo + 标题 + 版本号，右窗口按钮。
/// 拖拽逻辑完全交给原生（C++ win32_window 把整块当 caption 区），
/// Flutter 这边不挂任何 [GestureDetector]，避免和原生手势竞争。
///
/// 拆分要点：标题栏只负责组装 Logo + ThemeToggleSlider + WindowButtons；
/// Logo 自身放在 [scum_logo.dart]，未来改 logo 形态不影响标题栏其他布局。
class TitleBar extends StatelessWidget {
  final String version;

  const TitleBar({super.key, this.version = 'v1.0'});

  static const double height = 36;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
              // 半透明让自定义背景图透过
              color: colors.bgDark.withValues(alpha: 0.82),
              // 顶角圆角：与窗口外层 ClipRRect 对齐，避免窗口圆角后顶角"破"出直角黑边。
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(ScumTheme.windowCornerRadius),
          topRight: Radius.circular(ScumTheme.windowCornerRadius),
        ),
      ),
      child: Row(
        children: [
          // Logo
          SizedBox(
            width: height,
            height: height,
            child: Center(child: ScumLogo(size: 18)),
          ),
          const SizedBox(width: 8),

          // 标题 + 版本号（原生 HTCAPTION 拖拽区）
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            'SCUM MOD MANAGER',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 3.0,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'v${UpdateService.currentVersion}',
                            style: TextStyle(
                              color: colors.textDim,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 在线更新按钮：仅在检测到新版本时渲染（默认隐藏）。
                    // 位置：主题切换按钮左边（主人定稿 E）。
                    ValueListenableBuilder<bool?>(
                      valueListenable: AppSignals.updateAvailable,
                      builder: (_, available, _) {
                        if (available != true) {
                          // 彻底不渲染 → 不占任何布局空间
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: const UpdateButton(),
                        );
                      },
                    ),

                    // 主题切换滑块（暗 ↔ 亮）。放在 WindowButtons 之前——
                    // 主人明确要求"放到最小化按钮前"。
                    const ThemeToggleSlider(),
                    const SizedBox(width: 4),

          // 窗口按钮（最小化 / 最大化 / 关闭）
          const WindowButtons(),
        ],
      ),
    );
  }
}
