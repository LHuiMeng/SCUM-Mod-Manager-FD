import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';
import 'launch_button_states.dart';

/// 启动按钮 —— 多态：
/// 1. **未配置路径**：[LaunchButtonDisabled]（灰底提示）
/// 2. **未运行**：客户端主按钮 + 右侧 36px 服务器触发区（hover 覆盖展开）
/// 3. **运行中**：[LaunchButtonRunning]（红底，点击关闭游戏）
/// 4. **关闭中（用户主动）**：[LaunchButtonClosing]（橙色 spinner）
/// 5. **异常退出（被动检测）**：[LaunchButtonCrashed]（红橙警示脉动）
/// 6. **清理中（已退出但回收中）**：[LaunchButtonReclaiming]（灰底 spinner）
///
/// 视觉拆解要点：
/// - 态 2 的"客户端视觉层 + 服务器覆盖层 + 右侧触发区"全部保留在主文件，
///   因为这三层是 Stack 叠加紧密耦合的视觉单元；
/// - 态 1 / 态 3-6 抽出到 [launch_button_states.dart]，
///   因为它们是相对独立的"另一种视觉"，将来要给这些态追加 widget
///   （如运行中显示时长、未配置时显示具体错误）时不会影响态 2 的 hover 动画。
class LaunchButton extends StatefulWidget {
  final VoidCallback onLaunchClient;
  final VoidCallback onLaunchServer;
  final VoidCallback onKill;
  final bool isRunning;
  final bool isReclaiming;

  /// 关闭原因（决定走 Closing 还是 Crashed 态）。
  /// - null: 不在关闭/退出流程中（正常态）
  /// - [CloseReason.userKill]: 用户主动点关闭 → 橙色 Closing
  /// - [CloseReason.processExit]: 进程异常退出 → 红色 Crashed
  final CloseReason? closeReason;

  final String? reclaimingLabel;  // 自定义 reclaim 文案（默认"恢复游戏环境…"）

  final bool canLaunchClient;
  final bool canLaunchServer;

  const LaunchButton({
    super.key,
    required this.onLaunchClient,
    required this.onLaunchServer,
    required this.onKill,
    this.isRunning = false,
    this.isReclaiming = false,
    this.closeReason,
    this.reclaimingLabel,
    this.canLaunchClient = false,
    this.canLaunchServer = false,
  });

  @override
  State<LaunchButton> createState() => _LaunchButtonState();
}

/// 关闭原因枚举 —— 决定按钮走 Closing（用户主动）还是 Crashed（被动退出）态。
enum CloseReason {
  /// 用户主动点击关闭按钮
  userKill,

  /// 进程异常退出（isGameRunning 轮询检测到不在了）
  processExit,
}

class _LaunchButtonState extends State<LaunchButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _coverAnim;
  double _totalW = LaunchButtonRunning.width;
  static const double _indicatorW = 36;
  static const Duration _animDuration = Duration(milliseconds: 350);

  // A5：hover 状态——光标进入按钮区时整体上抬、加深阴影、强化高光。
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _animDuration);
    _coverAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _overlayW(double t) => _indicatorW + (_totalW - _indicatorW) * t;

  /// 覆盖度 > 0.5 → 全按钮视为服务器区。
  bool get _isServerDominant => _coverAnim.value > 0.5;

  void _handleTap() {
    // 守卫：closing / reclaiming 时按钮不响应点击。
    // 即使 widget tree 把按钮画成「启动游戏」态（极端 race 防御），
    // 这里也兜底不让用户触发新 launch —— 防止 R"游戏被关了又被启了又被关"
    // 死循环。
    if (widget.isReclaiming || widget.closeReason != null) {
      return;
    }
    if (widget.isRunning) {
      widget.onKill();
      return;
    }
    if (_isServerDominant && widget.canLaunchServer) {
      widget.onLaunchServer();
    } else {
      widget.onLaunchClient();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 优先级：
    //   清理中（isReclaiming） > 关闭中/异常退出（closeReason） > 运行中 > 未配置 > 默认启动态
    //
    // 设计：
    // - reclaim 优先级最高：游戏已退出 + 清理中 → 灰底 "恢复游戏环境…"
    //   用户已经看到"游戏退了"，不需要再被警示色干扰。
    // - closeReason 走 Closing/Crashed：
    //     userKill → 橙色 Closing（用户主动，系统响应中）
    //     processExit → 红色 Crashed（用户没动，异常退出警示）
    // - isRunning 走 Running（游戏在跑，可点关闭）。
    if (widget.isReclaiming) {
      return LaunchButtonReclaiming(
        label: widget.reclaimingLabel ?? '恢复游戏环境…',
      );
    }
    if (widget.closeReason == CloseReason.processExit) {
      return const LaunchButtonCrashed();
    }
    if (widget.closeReason == CloseReason.userKill) {
      return LaunchButtonClosing(onTap: widget.onKill);
    }
    if (widget.isRunning) return LaunchButtonRunning(onKill: widget.onKill);
    if (!widget.canLaunchClient && !widget.canLaunchServer) {
      return const LaunchButtonDisabled();
    }
    return SizedBox(
      width: LaunchButtonRunning.width,
      height: LaunchButtonRunning.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _totalW = constraints.maxWidth;
          return _buildAnimated();
        },
      ),
    );
  }

  Widget _buildAnimated() {
    final colors = ScumColors.of(context);
    final canServer = widget.canLaunchServer;
    // A5：hover 时阴影更深、blur 更大、translate 上抬 2px。
    // 用 AnimatedContainer + AnimatedPadding 在两个状态间平滑过渡。
    //
    // 关键：外层 MouseRegion 只控制 hover 视觉（阴影/上抬），不驱动覆盖层动画。
    // 覆盖层动画由"右侧 36px 服务器触发区"的独立 MouseRegion 控制——
    // 否则光标在客户端区任意位置都会触发覆盖层 forward，导致服务器色块侵噬。
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _handleTap,
        child: AnimatedPadding(
          // hover 时按钮"上抬"——实际是减少顶部 padding 让按钮视觉上移。
          // 配合 AnimatedContainer 的阴影变化营造立体感。
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            top: _hovered ? 0 : 2,
            bottom: _hovered ? 4 : 2,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              // hover 时阴影加深 + blur 加大 + 向下偏移缩小。
              boxShadow: [
                BoxShadow(
                  color: _hovered
                      ? colors.launchShadow
                      : colors.launchShadowIdle,
                  blurRadius: _hovered ? 14 : 8,
                  offset: Offset(0, _hovered ? 5 : 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
              children: <Widget>[
                // 1. 客户端视觉层（A5 金属感：纵向渐变 + 顶部高光边）
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // 上亮下暗 → 黄铜"光从上方打下来"的金属感。
                        colors: _hovered
                            ? [colors.accentHighlight, colors.accent]
                            : [colors.accent, colors.accentShadow],
                      ),
                      borderRadius: BorderRadius.circular(6),
                      // 顶部 1px 高光边 + 底部 1px 暗边，模拟立体倒角。
                      border: Border(
                        top: BorderSide(
                          color: colors.accentHighlight.withValues(alpha: 0.6),
                          width: 1,
                        ),
                        bottom: BorderSide(
                          color: colors.accentDeepShadow.withValues(alpha: 0.7),
                          width: 1,
                        ),
                        left: BorderSide(
                          color: colors.accentDeepShadow.withValues(alpha: 0.4),
                          width: 0.5,
                        ),
                        right: BorderSide(
                          color: colors.accentDeepShadow.withValues(alpha: 0.4),
                          width: 0.5,
                        ),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: ListenableBuilder(
                      listenable: _coverAnim,
                      builder: (context, child) => AnimatedOpacity(
                        opacity: _coverAnim.value < 0.6 ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 120),
                        child: Text(
                          '启动游戏',
                          style: TextStyle(
                            color: colors.bgDark,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 2. 服务器覆盖层（A5 同样金属感：军绿渐变）
                if (canServer)
                  ListenableBuilder(
                    listenable: _coverAnim,
                    builder: (context, child) {
                      final w = _overlayW(_coverAnim.value);
                      return Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        width: w,
                        child: ClipRect(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: _hovered
                                    ? [colors.successHighlight, colors.success]
                                    : [colors.success, colors.successShadow],
                              ),
                              borderRadius: BorderRadius.circular(6),
                              border: Border(
                                top: BorderSide(
                                  color: colors.successHighlight.withValues(
                                    alpha: 0.6,
                                  ),
                                  width: 1,
                                ),
                                bottom: BorderSide(
                                  color: colors.launchShadowIdle,
                                  width: 1,
                                ),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: _coverAnim.value < 0.2
                                ? null
                                : AnimatedOpacity(
                                    opacity: _coverAnim.value > 0.3 ? 1.0 : 0.0,
                                    duration: const Duration(milliseconds: 150),
                                    child: const Text(
                                      '启动服务器',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.5,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),

                // 3. 右侧服务器触发区（36px 透明）—— 独立 MouseRegion 控制覆盖层动画。
                //    关键：覆盖层动画 forward()/reverse() 由这个独立 MouseRegion 驱动，
                //    而不是由外层 hover MouseRegion 驱动。否则光标在客户端区任意位置
                //    都会让服务器覆盖层 forward → 服务器色块侵噬客户端区。
                //    同时这个独立 MouseRegion 阻止事件冒泡到外层（虽然外层不再驱动动画，
                //    但语义上保持职责清晰：客户端区 = 不展开覆盖层）。
                if (canServer)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: _indicatorW,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => _ctrl.forward(),
                      onExit: (_) => _ctrl.reverse(),
                      child: Container(color: Colors.transparent),
                    ),
                  ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}
