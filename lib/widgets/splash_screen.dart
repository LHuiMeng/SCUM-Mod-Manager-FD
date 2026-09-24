import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';
import 'scum_logo.dart';

/// 启动屏 —— 应用启动时短暂展示，淡入后再淡出到主界面。
///
/// 视觉：
/// - 全屏深色背景（bgDark，与主界面无缝衔接）
/// - 中心：黄铜色 SCUM Logo + 标题 + 副标题（"Mod Manager v2"）
/// - 底部：小进度条（用 LinearProgressIndicator 替换为自绘，避免 Material）
/// - 整体 300ms 进场 + 600ms 停留 + 250ms 出场
///
/// 控制：通过 [splashController] 传入的 [AnimationController] 决定 opacity。
/// 默认 [opacity=1.0]（全显），由父级 [SplashGate] 调 `controller.reverse()`
/// 触发淡出。淡出完成后通过 `onFadedOut` 回调通知父级卸载 Splash。
class SplashScreen extends StatelessWidget {
  final AnimationController controller;
  final VoidCallback onFadedOut;

  const SplashScreen({
    super.key,
    required this.controller,
    required this.onFadedOut,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // t: 1.0=全显, 0.0=完全透明。
        final t = controller.value;
        // Logo 缩放：进场时 0.85→1.0（"入场"感），出场时保持 1.0（不让 logo
        // 缩小消失——视觉上 splash 是"褪去"而不是"被吸入"）。
        // 通过判断 controller 状态区分进场/出场。
        final scale = controller.status == AnimationStatus.reverse
            ? 1.0
            : 0.85 + 0.15 * t;
        return Opacity(
          opacity: t,
          child: Container(
            color: colors.bgDark,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.scale(
                    scale: scale,
                    child: ScumLogo(size: 96, color: colors.accent),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'SCUM MOD MANAGER',
                    style: TextStyle(
                      color: colors.textPrimary.withValues(
                        alpha: 0.6 + 0.4 * t,
                      ),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 4.0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'v2 · Military Theme',
                    style: TextStyle(
                      color: colors.textDim.withValues(alpha: t),
                      fontSize: 11,
                      letterSpacing: 2.0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // 底部进度条：自绘，避免引入 Material LinearProgressIndicator。
                  // 宽度固定 200px，bar 进度从 0→100 跟随 t。
                  SizedBox(
                    width: 200,
                    height: 2,
                    child: Stack(
                      children: [
                        Container(color: colors.border),
                        // 进度：从中心向两侧展开的"扫描"效果。
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: t,
                            child: Container(
                              decoration: BoxDecoration(
                                color: colors.accent.withValues(alpha: 0.8),
                                boxShadow: [
                                  BoxShadow(
                                    color: colors.accentGlow,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Splash 包裹器 —— 决定何时显示 Splash、何时切换到主界面。
///
/// 流程：
/// 1. 显示 Splash，进场动画 300ms（forward 到 1.0）
/// 2. 保持全显 600ms（hold）
/// 3. 出场动画 250ms（reverse 到 0.0）
/// 4. reverse 完成后调 onFadedOut 通知父级切换到主界面。
///
/// 总时长 300 + 600 + 250 = 1150ms。
///
/// 监听 [ready] 信号——当主应用初始化完成后才开始出场。
/// [ready] 默认 true（立即开始出场），通常由父级在 widget 树挂载后
/// 通过 `setState` 切到 true 来推迟出场（等 Flutter 首帧 / IO 完成）。
class SplashGate extends StatefulWidget {
  final Widget app;
  final bool ready;

  const SplashGate({super.key, required this.app, this.ready = true});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const Duration _fadeIn = Duration(milliseconds: 300);
  static const Duration _hold = Duration(milliseconds: 600);
  static const Duration _fadeOut = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    // 进场用 300ms（从容），出场用 250ms（让位更快，因为主界面已经准备好了）。
    _ctrl = AnimationController(
      vsync: this,
      duration: _fadeIn,
      reverseDuration: _fadeOut,
    );
    _ctrl.forward(); // 立即开始进场
  }

  @override
  void didUpdateWidget(SplashGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 主应用 ready 后开始 hold→out。
    if (widget.ready && !oldWidget.ready) {
      _startExitSequence();
    }
  }

  Future<void> _startExitSequence() async {
    await Future<void>.delayed(_hold);
    if (!mounted) return;
    await _ctrl.reverse();
    if (!mounted) return;
    setState(() {}); // 触发 SplashGate 卸载 Splash，显示 app
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Splash 完全淡出后（value == 0 且 fadeOut 完成）才显示 app。
    final splashed = _ctrl.status == AnimationStatus.dismissed;
    return Stack(
      children: [
        widget.app,
        if (!splashed) SplashScreen(controller: _ctrl, onFadedOut: () {}),
      ],
    );
  }
}
