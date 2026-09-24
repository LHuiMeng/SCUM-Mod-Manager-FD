import 'package:flutter/material.dart';

import '../theme/scum_theme.dart';
import '../theme/scum_colors.dart';

/// 启动按钮"运行中"态 —— 红底 + 关闭图标，点击触发 [onKill]。
///
/// 独立文件：从 [LaunchButton] 拆出，因为：
/// - 运行态视觉（danger 红底、stop 图标）与未运行态视觉（accent 边、悬停覆盖）
///   是两套独立的视觉系统；
/// - 运行态未来可能加"剩余运行时长"等额外 widget，独立文件方便追加。
///
/// A5 视觉升级：
/// - 红底换金属感纵向渐变（顶亮 → 底暗），与主按钮呼应；
/// - 加 pulse 呼吸动画：alpha 在 [0.85, 1.0] 之间 1.4s 周期脉动，
///   提示用户"游戏在跑"但不过分抢眼；
/// - 加 accent danger glow boxShadow 红色微光，让运行态"有戏"。
class LaunchButtonRunning extends StatefulWidget {
  final VoidCallback onKill;

  const LaunchButtonRunning({super.key, required this.onKill});

  // 与 LaunchButton 主容器等宽对齐。
  static const double width = 200;
  static const double height = 42;

  @override
  State<LaunchButtonRunning> createState() => _LaunchButtonRunningState();
}

class _LaunchButtonRunningState extends State<LaunchButtonRunning>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: ScumTheme.pulseDuration)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      width: LaunchButtonRunning.width,
      height: LaunchButtonRunning.height,
      child: GestureDetector(
        onTap: widget.onKill,
        child: ListenableBuilder(
          listenable: _pulse,
          builder: (context, _) {
            // t: 0→1 循环。alpha 在 0.85..1.0 之间往返。
            final t = Curves.easeInOut.transform(_pulse.value);
            final baseAlpha = 0.85 + 0.15 * (1 - t); // t=0 → 1.0, t=1 → 0.85
            return Opacity(
              opacity: baseAlpha,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    // 金属感纵向渐变：亮红 → 深红。
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors.dangerLight, // 顶部高光（danger 提亮）
                        colors.danger,
                        colors.dangerShadow, // 底部暗部（danger 压暗）
                      ],
                    ),
                    borderRadius: BorderRadius.circular(6),
                    // 立体倒角边：顶部高光边 + 底部暗边。
                    border: Border(
                      top: BorderSide(
                        color: colors.dangerHighlight.withValues(alpha: 0.6),
                        width: 1,
                      ),
                      bottom: BorderSide(color: colors.shadowMd, width: 1),
                    ),
                    // 红色微光：随 pulse 同步呼吸
                    boxShadow: [
                      BoxShadow(
                        color: colors.danger.withValues(alpha: 0.3 + 0.2 * t),
                        blurRadius: 8 + 4 * t,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop_rounded, size: 18, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        '关闭游戏',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 启动按钮"未配置路径"态 —— 灰底 + 禁用文案。
///
/// 独立文件：这是单纯的禁用态展示，未来如果要给"无网络/无 MOD"等
/// 其他禁用态复用（用对应提示语 + 颜色），直接传不同 [label] 即可。
///
/// A5 视觉微调：
/// - 加细微纵向渐变（bgPanel → bgDark），让禁用态"有形状感"而不是平贴；
/// - 加极淡的内描边（borderAccent alpha 0.3），与启用态描边呼应但明显弱化。
class LaunchButtonDisabled extends StatelessWidget {
  final String label;

  const LaunchButtonDisabled({super.key, this.label = '路径未配置'});

  static const double width = LaunchButtonRunning.width;
  static const double height = LaunchButtonRunning.height;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.bgPanel, colors.bgDark],
            ),
            borderRadius: BorderRadius.circular(6),
            // 弱化描边 + accent 暗边低 alpha，区分启用态黄铜边。
            border: Border.all(
              color: colors.borderAccent.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: colors.textDim,
              fontSize: 12,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// 启动按钮"清理中"态 —— 游戏已退出但回收 PAK/UE4SS 仍在后台运行。
///
/// 背景故事：
/// 主人反馈"关闭游戏后管理器未响应"——原因是 reclaimMods 内有指数退避
/// 重试逻辑（最长 25s+/文件），同步等待会让 UI 线程阻塞卡死。
/// 修复方案：把 reclaimMods 改为 fire-and-forget 后台任务，启动按钮立刻切
/// 到此态（橙色清理中提示），让用户清楚"正在清理"而非"程序死了"。
///
/// 视觉：
/// - 中性灰底 + 微橙色 spinner，提示"系统在干活"但不抢眼
/// - 旋转动画 1.5s/圈，无限循环
/// - 完全禁用 onTap（点击无效，避免重复触发回收流程）
class LaunchButtonReclaiming extends StatefulWidget {
  /// 自定义文案（默认「恢复游戏环境…」）。未来给 UE4SS / 自定义 mod
  /// 等不同 reclaim 场景复用。
  final String label;

  const LaunchButtonReclaiming({super.key, this.label = '恢复游戏环境…'});

  static const double width = LaunchButtonRunning.width;
  static const double height = LaunchButtonRunning.height;

  @override
  State<LaunchButtonReclaiming> createState() => _LaunchButtonReclaimingState();
}

class _LaunchButtonReclaimingState extends State<LaunchButtonReclaiming>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      width: LaunchButtonReclaiming.width,
      height: LaunchButtonReclaiming.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.bgPanel, colors.bgDark],
            ),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              // 橙色弱描边：提示"在干活"但与红/黄运行态区分
              color: colors.accent.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          // 注意：故意不包 GestureDetector.onTap——此态完全禁用点击
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListenableBuilder(
                listenable: _spin,
                builder: (context, _) => Transform.rotate(
                  angle: _spin.value * 2 * 3.1415926,
                  child: Icon(
                    Icons.autorenew_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动按钮"用户主动关闭中"态 —— 橙色金属感渐变 + 旋转 spinner。
///
/// 用于：用户点击关闭按钮 → 异步 kill 流程已发起，但游戏进程还没退出。
/// 区别于「运行中」（游戏在跑、可再次点取消）和「清理中」（已退出但环境
/// 在恢复）。此处是中间的过渡阶段。
///
/// 视觉：橙色金属渐变（区别于红=在跑、灰=清理），让用户清楚「系统响应了
/// 我的关闭请求，正在执行」。
class LaunchButtonClosing extends StatefulWidget {
  final VoidCallback? onTap;  // 保留接口：未来给「再点取消」用，目前禁用。

  const LaunchButtonClosing({super.key, this.onTap});

  static const double width = LaunchButtonRunning.width;
  static const double height = LaunchButtonRunning.height;

  @override
  State<LaunchButtonClosing> createState() => _LaunchButtonClosingState();
}

class _LaunchButtonClosingState extends State<LaunchButtonClosing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      width: LaunchButtonClosing.width,
      height: LaunchButtonClosing.height,
      child: GestureDetector(
        // 关闭中态：点击无操作（kill 流程在 worker 线程，重复点击没意义）。
        onTap: () {},
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // 橙色金属渐变（accent → accentShadow）——"系统正在响应我的请求"
                colors: [colors.accentHighlight, colors.accent],
              ),
              borderRadius: BorderRadius.circular(6),
              border: Border(
                top: BorderSide(
                  color: colors.accentHighlight.withValues(alpha: 0.6),
                  width: 1,
                ),
                bottom: BorderSide(
                  color: colors.accentShadow.withValues(alpha: 0.7),
                  width: 1,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.shadowSm,
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: _spin,
                  builder: (context, _) => Transform.rotate(
                    angle: _spin.value * 2 * 3.1415926,
                    child: const Icon(
                      Icons.autorenew_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '正在关闭游戏',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 启动按钮"游戏异常退出"态 —— 红橙渐变 + 警示三角图标 + 慢脉动 glow。
///
/// 用于：isGameRunning 轮询发现进程不在了，但用户没点关闭。
/// 这意味着游戏崩溃 / 被用户从外部强杀 / 系统关机等。
/// 与「清理中」连续：先展示红橙警示，让用户看清"游戏异常退出"，
/// 然后自动过渡到 LaunchButtonReclaiming 开始回收。
///
/// 视觉：深红渐变 + 警示三角图标，慢 pulse 提醒用户注意。
class LaunchButtonCrashed extends StatefulWidget {
  const LaunchButtonCrashed({super.key});

  static const double width = LaunchButtonRunning.width;
  static const double height = LaunchButtonRunning.height;

  @override
  State<LaunchButtonCrashed> createState() => _LaunchButtonCrashedState();
}

class _LaunchButtonCrashedState extends State<LaunchButtonCrashed>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: ScumTheme.pulseDuration)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return SizedBox(
      width: LaunchButtonCrashed.width,
      height: LaunchButtonCrashed.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // 比 Running 态更深的红 —— "异常"不是"在跑"，要给警告感
              colors: [colors.dangerShadow, colors.danger, colors.dangerShadow],
            ),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: colors.danger.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: ListenableBuilder(
            listenable: _pulse,
            builder: (context, _) {
              final pulseVal = Curves.easeInOut.transform(_pulse.value);
              final glowAlpha = 0.3 + 0.3 * pulseVal;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // 红色 glow 背景
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: colors.danger.withValues(alpha: glowAlpha),
                              blurRadius: 12 + 8 * pulseVal,
                              spreadRadius: 1 + 2 * pulseVal,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.95),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '游戏异常退出',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}