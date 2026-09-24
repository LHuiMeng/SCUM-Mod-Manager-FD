import 'package:flutter/material.dart';

import '../services/app_signals.dart';
import '../theme/scum_colors.dart';

/// 应用退出覆盖层 —— 黑色全屏遮罩 + 三步流程动画。
///
/// 用户点窗口 X 时由 [home_screen._onAppExitRequest] 触发：
/// 1. `AppSignals.exitOverlayStep.value = killingGame` → 显示遮罩
/// 2. kill 完成 → `reclaimingEnv`
/// 3. reclaim 完成 → `exitingApp`
/// 4. `confirmAppExit()` → C++ DestroyWindow → 进程退出
///
/// 视觉：
/// - 全屏 [colors.bgDark] 黑底 + 0.92 alpha（仍能看到一点点主界面残留感）
/// - 中央一个 SCUM logo（淡金色）+ 标题「正在关闭 SCUM MOD MANAGER」
/// - 三步进度列表：每步左侧 spinner/checkmark + 中间文案
///   - 未到达：灰底圆圈
///   - 进行中：旋转 spinner
///   - 已完成：金色对勾
/// - 当前步骤文字大号强调 + 副标题说明
///
/// 退出流程（v2.7+）：
/// 旧版用户点 X → Dart 在后台静默 kill+reclaim → 没有视觉反馈，
/// 玩家可能误以为卡住。新版：黑色遮罩 + 实时动画反馈，让用户清楚流程。
class ExitOverlay extends StatelessWidget {
  const ExitOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return ValueListenableBuilder<ExitOverlayStep?>(
      valueListenable: AppSignals.exitOverlayStep,
      builder: (context, step, _) {
        // null = 退出流程未启动 —— 完全不渲染（不占渲染树、不拦截事件）。
        if (step == null) return const SizedBox.shrink();

        // 同时监听 exitOverlayHasKillGame —— 决定走简化版还是完整版。
        return ValueListenableBuilder<bool?>(
          valueListenable: AppSignals.exitOverlayHasKillGame,
          builder: (context, hasKillGame, _) {
            // 整体黑色遮罩。IgnorePointer 防止用户点穿到底层 widget。
            return Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: colors.bgDark.withValues(alpha: 0.92),
                  child: Center(
                    child: _ExitCard(step: step!, hasKillGame: hasKillGame),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 遮罩中央的卡片 —— logo + 标题 + 三步进度（或简化版单 spinner）。
class _ExitCard extends StatelessWidget {
  final ExitOverlayStep step;

  /// 是否要 kill/reclaim（由 _onAppExitRequest 检测 isGameRunning 后设置）。
  /// null = 还没检测完（initializing）→ 简化模式；
  /// true = 游戏在跑 → 完整三步；
  /// false = 没游戏 → 简化模式（直接 exitingApp）。
  final bool? hasKillGame;

  const _ExitCard({required this.step, required this.hasKillGame});

  /// 是否走"完整三步"模式：必须检测完且 hasKillGame=true。
  bool get _useFullLayout => hasKillGame == true;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      width: _useFullLayout ? 360 : 300,
      padding: EdgeInsets.symmetric(
        horizontal: 32,
        vertical: _useFullLayout ? 36 : 32,
      ),
      decoration: BoxDecoration(
        color: colors.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border, width: 1),
        boxShadow: [
          BoxShadow(
            color: colors.shadowMd,
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 标题 ──
          Text(
            '正在关闭',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.0,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'SCUM MOD MANAGER',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              letterSpacing: 3.0,
              decoration: TextDecoration.none,
            ),
          ),

          if (_useFullLayout) ...[
            const SizedBox(height: 28),

            // ── 三步进度 ──
            _StepRow(
              state: _stepState(ExitOverlayStep.killingGame),
              label: '正在关闭游戏',
              sublabel: '向游戏进程发送退出信号',
              accentColor: colors.danger,
            ),
            _StepDivider(),
            _StepRow(
              state: _stepState(ExitOverlayStep.reclaimingEnv),
              label: '正在恢复游戏环境',
              sublabel: '清理已部署的模组文件',
              accentColor: colors.accent,
            ),
            _StepDivider(),
            _StepRow(
              state: _stepState(ExitOverlayStep.exitingApp),
              label: '正在退出程序',
              sublabel: '关闭主窗口并退出',
              accentColor: colors.success,
            ),

            const SizedBox(height: 24),

            // ── 当前步骤高亮 ──
            _CurrentStepHighlight(step: step),
          ] else ...[
            // ── 简化模式：initializing 或没游戏在跑 ──
            const SizedBox(height: 28),
            _SimpleSpinner(color: colors.accent),
            const SizedBox(height: 16),
            Text(
              _simpleMessage(),
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  /// 简化模式下的提示文字。
  String _simpleMessage() {
    if (step == ExitOverlayStep.exitingApp) {
      return '正在退出程序…';
    }
    if (step == ExitOverlayStep.killingGame ||
        step == ExitOverlayStep.reclaimingEnv) {
      // hasKillGame=true 时不可能走这里，留兜底。
      return '正在准备退出…';
    }
    // initializing 或 hasKillGame 还没确定
    return '正在准备退出…';
  }

  /// 返回每步的状态：未到、进行中、已完成。
  _StepVisualState _stepState(ExitOverlayStep s) {
    const order = [
      ExitOverlayStep.killingGame,
      ExitOverlayStep.reclaimingEnv,
      ExitOverlayStep.exitingApp,
    ];
    final cur = order.indexOf(step);
    final idx = order.indexOf(s);
    if (cur < 0) return _StepVisualState.idle;
    if (idx < cur) return _StepVisualState.done;
    if (idx == cur) return _StepVisualState.active;
    return _StepVisualState.idle;
  }
}

/// 简化模式下的旋转 spinner。
class _SimpleSpinner extends StatefulWidget {
  final Color color;
  const _SimpleSpinner({required this.color});

  @override
  State<_SimpleSpinner> createState() => _SimpleSpinnerState();
}

class _SimpleSpinnerState extends State<_SimpleSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _spin,
      builder: (context, _) => Transform.rotate(
        angle: _spin.value * 2 * 3.1415926,
        child: Icon(
          Icons.autorenew_rounded,
          size: 32,
          color: widget.color,
        ),
      ),
    );
  }
}

enum _StepVisualState { idle, active, done }

/// 单步进度行 —— 左侧状态指示 + 右侧文字。
class _StepRow extends StatelessWidget {
  final _StepVisualState state;
  final String label;
  final String sublabel;
  final Color accentColor;

  const _StepRow({
    required this.state,
    required this.label,
    required this.sublabel,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final isActive = state == _StepVisualState.active;
    final isDone = state == _StepVisualState.done;

    final indicatorColor = isDone
        ? colors.accent  // 完成：金黄色对勾
        : isActive
            ? accentColor  // 进行中：当前步骤强调色
            : colors.border; // 未开始：灰

    final textColor = (isActive || isDone)
        ? colors.textPrimary
        : colors.textDim;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 左侧状态指示：圆圈/spinner/对勾
        SizedBox(
          width: 28,
          height: 28,
          child: Center(child: _StepIndicator(
            color: indicatorColor,
            isActive: isActive,
            isDone: isDone,
          )),
        ),
        const SizedBox(width: 14),
        // 右侧文字
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sublabel,
                style: TextStyle(
                  color: isActive
                      ? colors.textSecondary
                      : colors.textDim.withValues(alpha: 0.7),
                  fontSize: 10,
                  letterSpacing: 0.3,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单步左侧的视觉指示 —— 根据状态切换圆圈 / spinner / 对勾。
class _StepIndicator extends StatefulWidget {
  final Color color;
  final bool isActive;
  final bool isDone;

  const _StepIndicator({
    required this.color,
    required this.isActive,
    required this.isDone,
  });

  @override
  State<_StepIndicator> createState() => _StepIndicatorState();
}

class _StepIndicatorState extends State<_StepIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.isActive) _spin.repeat();
  }

  @override
  void didUpdateWidget(_StepIndicator old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.isActive && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isDone) {
      // 金色对勾
      return Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.15),
          border: Border.all(color: widget.color, width: 1.5),
        ),
        child: Icon(
          Icons.check_rounded,
          size: 14,
          color: widget.color,
        ),
      );
    }
    if (widget.isActive) {
      // 旋转 spinner —— 强调当前进行中
      return ListenableBuilder(
        listenable: _spin,
        builder: (context, _) => Transform.rotate(
          angle: _spin.value * 2 * 3.1415926,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.25),
                width: 2,
              ),
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: 2,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // idle 灰底圆圈
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: widget.color, width: 1.5),
      ),
    );
  }
}

/// 步骤之间的虚线分隔。
class _StepDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 13, top: 4, bottom: 4),
      child: Container(
        width: 1.5,
        height: 14,
        decoration: BoxDecoration(
          color: colors.border.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

/// 底部当前步骤的高亮提示 —— 大字 + 进度提示。
class _CurrentStepHighlight extends StatelessWidget {
  final ExitOverlayStep step;

  const _CurrentStepHighlight({required this.step});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final (label, hint, color) = switch (step) {
      ExitOverlayStep.initializing => (
        '正在准备退出',
        '正在检查游戏进程状态',
        colors.accent,
      ),
      ExitOverlayStep.killingGame => (
        '正在关闭游戏',
        '请稍候，正在通知游戏进程退出',
        colors.danger,
      ),
      ExitOverlayStep.reclaimingEnv => (
        '正在恢复游戏环境',
        '正在删除临时部署的模组文件',
        colors.accent,
      ),
      ExitOverlayStep.exitingApp => (
        '正在退出程序',
        '即将关闭主窗口',
        colors.success,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  hint,
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: 10,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}