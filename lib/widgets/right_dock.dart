/// 右下角浮层 —— 启动按钮 + 齿轮按钮，悬浮在内容上。
///
/// 始终可见（不随侧边栏 tab 切换），固定在 HomeScreen 内容的右下角。
///
/// v2.4 新增：启动时自动部署 PAK 到游戏 ~mods，退出时自动回收（删除）。
///
/// 视觉布局：
///   ┌──────────────────────────┐
///   │                          │
///   │  (内容区域)              │
///   │                          │
///   │              [齿轮]      │
///   │              [启动按钮]  │
///   └──────────────────────────┘
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/deploy_result.dart';
import '../models/launch_options.dart';
import '../services/app_logger.dart';
import '../services/mod_service.dart';
import '../services/launcher_service.dart';
import '../services/reclaim_isolate.dart';
import '../theme/scum_colors.dart';
import 'animated_toast.dart';
import 'launch_button.dart';
import 'launch_button_states.dart';
import 'launch_options_popup.dart';

/// 右下角浮层 —— 启动游戏 + 启动选项齿轮 + 实时状态。
///
/// 工作流（v2.4）：
/// 1. 点击启动 → deployMods（复制本地 ~mods 到游戏 ~mods）
/// 2. 启动游戏进程
/// 3. 每 2 秒轮询 isGameRunning
/// 4. 进程退出 → reclaimMods（删除游戏 ~mods）+ 按钮恢复为"启动游戏"
class RightDock extends StatefulWidget {
  final ModService modService;
  final LaunchOptions launchOptions;
  final ValueChanged<LaunchOptions> onLaunchOptionsChanged;

  const RightDock({
    super.key,
    required this.modService,
    required this.launchOptions,
    required this.onLaunchOptionsChanged,
  });

  @override
  State<RightDock> createState() => _RightDockState();
}

class _RightDockState extends State<RightDock> {
  bool _isRunning = false;
  bool _isReclaiming = false;
  CloseReason? _closeReason; // null=正常，userKill=主动关，processExit=异常退出
  Timer? _exitPollTimer;
  int _crashFlashTicks = 0; // 进程异常退出后，先展示 Crashed 态几秒再转 Reclaiming

  bool get _canLaunchClient => widget.modService.scumExePath != null;
  bool get _canLaunchServer => widget.modService.serverExePath != null;

  @override
  void dispose() {
    _exitPollTimer?.cancel();
    super.dispose();
  }

  /// 后台异步回收 PAK + UE4SS。
  ///
  /// 设计要点：主人反馈"关闭游戏后管理器未响应"——原因是 [reclaimMods] 内部
  /// 有指数退避重试逻辑（每个文件最长 25s+），同步 await 会让 UI 线程阻塞。
  /// 这里把 reclaimMods 放到 fire-and-forget 的 Future 里执行，启动按钮立刻
  /// 切到「恢复游戏环境」态——既让用户知道系统在干活，又不阻塞 UI 交互。
  ///
  /// **关键修复（v2.6+）**：reclaim 期间按钮始终处于「恢复游戏环境…」态，
  /// 即使用户此时尝试点击也无效（LaunchButtonReclaiming 内部无 onTap）。
  /// reclaim 完成后才彻底释放按钮回「启动游戏」态。
  /// 防止 reclaim 中途被用户再次启动造成「游戏被关了又被启了又被关」循环。
  ///
  /// 弹出 AutoDetectToast 提示用户：
  /// - 开始：「正在恢复游戏环境…」
  /// - 完成：「游戏环境已恢复」
  Future<void> _reclaimInBackground() async {
    if (!mounted) return;
    // 游戏结束 → 停止 config 热同步（游戏目录即将被回收）
    widget.modService.stopConfigSync();
    setState(() {
      _isReclaiming = true;
      _closeReason = null;
      // _isRunning 不变 —— reclaim 期间保持 true，让 LaunchButton 的优先级
      // 逻辑走「清理中 > 关闭中 > 运行中」，按钮态固定为 Reclaiming。
    });
    AppLogger.instance.info('开始后台回收 PAK/UE4SS（不阻塞 UI）');

    // 开始时弹 toast（不阻塞，4 秒自动消失；如果 reclaim 提前完成，下面会覆盖）。
    if (mounted) {
      AutoDetectToast.show(
        context,
        message: '正在恢复游戏环境…',
        backgroundColor: ScumColors.of(context).accent,
        icon: Icons.cleaning_services_rounded,
      );
    }

    ReclaimResult? reclaimResult;
    try {
      reclaimResult = await widget.modService.reclaimMods();
      AppLogger.instance.info('后台回收完成');
    } catch (e) {
      AppLogger.instance.error('后台回收失败', {'error': e.toString()});
    }
    if (!mounted) return;

    // reclaim 完成 —— 释放按钮回「启动游戏」态。
    setState(() {
      _isReclaiming = false;
      _isRunning = false;
      _closeReason = null;
    });

    // 完成 toast —— 根据实际清理结果区分提示。
    // - frameworkLeft > 0：UE4SS 文件被锁重试耗尽，报警告
    // - frameworkLeft == 0：全部清理成功
    if (mounted) {
      final colors = ScumColors.of(context);
      if (reclaimResult != null && reclaimResult.frameworkLeft > 0) {
        AutoDetectToast.show(
          context,
          message: 'UE4SS 文件被锁未完全清理，游戏环境已部分恢复',
          backgroundColor: colors.danger,
          icon: Icons.warning_amber_rounded,
          duration: const Duration(seconds: 5),
        );
      } else {
        AutoDetectToast.show(
          context,
          message: '游戏环境已恢复',
          backgroundColor: colors.success,
          icon: Icons.check_circle_rounded,
        );
      }
    }
  }

  /// 启动轮询检测游戏进程退出（**被动检测路径**——进程自己退出）。
  ///
  /// 区别于 `_startExitPollingAfterKill`：此处意味着用户**没有**主动点过
  /// 关闭按钮，所以是「游戏异常退出」——先展示几秒 [LaunchButtonCrashed]
  /// 警示态，再转入 reclaim。
  void _startExitPolling() {
    _exitPollTimer?.cancel();
    _exitPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      AppLogger.instance.debug('开始游戏心跳轮询');
      final running = await LauncherService.isGameRunning();
      if (running || !mounted) return;
      AppLogger.instance.info('检测到游戏进程已退出（非主动关闭）');
      _exitPollTimer?.cancel();
      _exitPollTimer = null;

      // 先切到「异常退出」态 + 弹警示 toast。
      if (mounted) {
        final colors = ScumColors.of(context);
        setState(() {
          _closeReason = CloseReason.processExit;
        });
        AutoDetectToast.show(
          context,
          message: '检测到游戏异常退出',
          backgroundColor: colors.danger,
          icon: Icons.warning_amber_rounded,
        );
      }

      // **立即** 启动 reclaim（不再等 1.5s 延迟）。
      // 旧版先等 1.5s 再 reclaim，这期间如果用户关闭管理器，
      // _kill() 会 cancel 掉 _exitPollTimer，reclaim 永远不触发。
      // 现在 reclaim 与 crash 显示并发执行，互不阻塞。
      if (mounted) {
        // ignore: discarded_futures
        _reclaimInBackground();
      }
    });
  }

  /// 启动轮询检测游戏进程退出（**用户主动 kill 后**）。
  ///
  /// kill 是异步发起的，进程退出后还得查 `killResult` 拿最终结果反馈给
  /// 用户（成功/失败 SnackBar）。
  void _startExitPollingAfterKill() {
    _exitPollTimer?.cancel();
    _exitPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      AppLogger.instance.debug('开始关闭后心跳轮询');
      final running = await LauncherService.isGameRunning();
      if (running) return; // 还在等进程退出
      if (!mounted) return;
      _exitPollTimer?.cancel();
      _exitPollTimer = null;

      // 进程已退出 —— 查 C++ 端 kill 的最终结果（worker 线程已写入）。
      bool killOk = true;
      try {
        killOk = await LauncherService.killResult();
      } catch (_) {
        killOk = true;
      }
      AppLogger.instance.info('关闭游戏最终结果', {'success': killOk});

      // 立刻切到「恢复游戏环境」态 + 后台回收（不再走 Crashed 警示——他主动点的）。
      // ignore: discarded_futures
      _reclaimInBackground();

      // kill 反馈 toast。
      if (mounted) {
        final colors = ScumColors.of(context);
        if (killOk) {
          _showSnack('游戏已关闭（环境回收中…）', colors.success);
        } else {
          AutoDetectToast.show(
            context,
            message: '强杀游戏失败，请手动结束进程',
            backgroundColor: colors.danger,
            icon: Icons.error_outline_rounded,
          );
        }
      }
    });
  }

  Future<void> _launchClient() async {
    final svc = widget.modService;
    final exePath = svc.scumExePath;
    if (exePath == null) return;

    // 守卫：closing / reclaiming 时禁止再次启动 —— 否则会启动新进程覆盖正在
    // kill 的旧进程，造成"游戏被关了又被启了又被关"的死循环。
    if (_isReclaiming || _closeReason != null) {
      AppLogger.instance.warning('启动被忽略：当前正在 closing/reclaiming', {
        'is_reclaiming': _isReclaiming,
        'close_reason': _closeReason.toString(),
      });
      return;
    }

    final opts = widget.launchOptions.copyWith(hasPakMods: svc.hasEnabledMods);
    final args = opts.buildArgs(false);
    AppLogger.instance.ui(
      '启动客户端',
      action: '点击',
      details: {
        'exe_path': exePath,
        'args': args,
        'enabled_mod_count': svc.mods.where((m) => m.enabled).length,
      },
    );

    // 先部署 PAK 到游戏 ~mods（异步，避免大批量复制卡 UI）
    setState(() {
      _isRunning = true;
      _closeReason = null;
    });
    final deploy = await svc.deployMods(isServer: false);
    // 部署验证不过（文件缺失 / 大小不一致）→ 不启动游戏，回收已部署并提示。
    if (!deploy.ok) {
      // ignore: discarded_futures
      _reclaimInBackground();
      if (mounted) {
        _showSnack(_deployFailMessage(deploy), ScumColors.of(context).danger);
      }
      return;
    }

    final result = await LauncherService.launchGame(exePath, args);
    if (result['success'] != true) {
      // 启动失败 → 后台回收已部署的 PAK（不阻塞 UI，立刻 SnackBar 提示）
      // ignore: discarded_futures
      _reclaimInBackground();
      final colors = ScumColors.of(context);
      _showSnack(
        '启动失败：${result['pid'] == 0 ? '进程未创建' : '未知错误'}',
        colors.danger,
      );
      return;
    }
    // 启动成功 → 开始轮询 + config.txt 热同步（改 ue4ss_runtime 源的 config 实时生效）
    if (!mounted) return;
    svc.startConfigSync();
    _startExitPolling();
  }

  Future<void> _launchServer() async {
    final svc = widget.modService;
    final exePath = svc.serverExePath;
    if (exePath == null) return;

    // 守卫：closing / reclaiming 时禁止再次启动 —— 与 _launchClient 同。
    if (_isReclaiming || _closeReason != null) {
      AppLogger.instance.warning('启动被忽略：当前正在 closing/reclaiming', {
        'is_reclaiming': _isReclaiming,
        'close_reason': _closeReason.toString(),
      });
      return;
    }

    final opts = widget.launchOptions.copyWith(hasPakMods: svc.hasEnabledMods);
    final args = opts.buildArgs(true);
    AppLogger.instance.ui(
      '启动服务端',
      action: '点击',
      details: {
        'exe_path': exePath,
        'args': args,
        'enabled_mod_count': svc.mods.where((m) => m.enabled).length,
      },
    );

    // 先部署 PAK 到服务端 ~mods（异步）
    setState(() {
      _isRunning = true;
      _closeReason = null;
    });
    final deploy = await svc.deployMods(isServer: true);
    // 部署验证不过 → 不启动游戏，回收已部署并提示。
    if (!deploy.ok) {
      // ignore: discarded_futures
      _reclaimInBackground();
      if (mounted) {
        _showSnack(_deployFailMessage(deploy), ScumColors.of(context).danger);
      }
      return;
    }

    final result = await LauncherService.launchGame(exePath, args);
    if (result['success'] != true) {
      // ignore: discarded_futures
      _reclaimInBackground();
      final colors = ScumColors.of(context);
      _showSnack(
        '服务端启动失败：${result['pid'] == 0 ? '进程未创建' : '未知错误'}',
        colors.danger,
      );
      return;
    }
    if (!mounted) return;
    _startExitPolling();
  }

  /// 关闭游戏/服务端 —— **完全异步，UI 立即响应**。
  ///
  /// v2.6 改造要点：旧版 `await LauncherService.killGame()` 会让 GUI 线程
  /// 等 C++ 端 5 秒 `WaitForSingleObject`，整个管理器在点击关闭后卡死。
  /// 新流程：
  /// 1. 点击 → 立即把按钮切到 [LaunchButtonClosing] 态（橙色 spinner），
  ///    UI 立刻可交互
  /// 2. `killGame()` 调用现在是 fire-and-forget，立即返回不阻塞
  /// 3. 启动 `_startExitPollingAfterKill()` 后台轮询进程退出
  /// 4. 进程真正退出后查 `killResult` + 触发后台 reclaim + SnackBar
  ///
  /// 取消旧的 exit poll（之前 startExitPolling 起的 timer），避免双 timer
  /// 抢着 reclaim。
  Future<void> _kill() async {
    AppLogger.instance.ui('关闭游戏/服务端（异步，不阻塞）', action: '点击');

    // 取消之前的轮询（防止双 poll 抢 reclaim）。
    _exitPollTimer?.cancel();
    _exitPollTimer = null;

    // 1) 立刻切到「正在关闭游戏」态（橙色 spinner）。
    if (mounted) {
      setState(() {
        _isRunning = true;
        _isReclaiming = false;
        _closeReason = CloseReason.userKill;
      });
    }

    // 2) 立即弹 toast 告诉用户「正在关闭…」（不依赖 C++ 端返回）。
    if (mounted) {
      AutoDetectToast.show(
        context,
        message: '正在关闭游戏/服务端…',
        backgroundColor: ScumColors.of(context).accent,
        icon: Icons.power_settings_new_rounded,
      );
    }

    // 3) 异步发起 kill —— 不阻塞。失败（无进程/重复 kill）也走 poll 路径，
    //    让 poll 自然走到 reclaim 状态。
    bool initiated = false;
    try {
      initiated = await LauncherService.killGame();
    } catch (e) {
      AppLogger.instance.error('killGame 调用异常', {'error': e.toString()});
    }
    AppLogger.instance.info('killGame 发起结果', {'initiated': initiated});

    // 4) 启动后台轮询检测进程退出。进程退出后再查 killResult + 触发 reclaim。
    if (!mounted) return;
    _startExitPollingAfterKill();
  }

  /// 部署失败提示文案（列出缺失/校验不过的 mod，超 3 个折叠为总数）。
  String _deployFailMessage(DeployResult deploy) {
    final names = deploy.failed.take(3).join('、');
    final extra = deploy.failed.length > 3
        ? ' 等 ${deploy.failed.length} 个 mod'
        : '';
    return '模组部署未完成，已取消启动：$names$extra';
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          right: 20,
          bottom: 20,
          child: LaunchButton(
            onLaunchClient: _launchClient,
            onLaunchServer: _launchServer,
            onKill: _kill,
            isRunning: _isRunning,
            isReclaiming: _isReclaiming,
            closeReason: _closeReason,
            canLaunchClient: _canLaunchClient,
            canLaunchServer: _canLaunchServer,
          ),
        ),
        Positioned(
          right: 20,
          bottom: 20 + LaunchButtonRunning.height + 8,
          child: _GearButton(onTap: () => _showOptionsPopup(context)),
        ),
      ],
    );
  }

  void _showOptionsPopup(BuildContext context) {
    final opts = widget.launchOptions;
    LaunchOptionsPopup.show(
      context,
      log: opts.log,
      fileOpenLog: opts.fileOpenLog,
      noBattlEye: opts.noBattlEye,
      port: opts.port,
      forcedFileOpenLog: widget.modService.hasEnabledMods,
      forcedNoBattlEye: widget.modService.hasEnabledMods,
      onLogChanged: (v) => _updateOpts(log: v),
      onFileOpenLogChanged: (v) => _updateOpts(fileOpenLog: v),
      onNoBattlEyeChanged: (v) => _updateOpts(noBattlEye: v),
      onPortChanged: (v) => _updateOpts(port: v),
    );
  }

  void _updateOpts({
    bool? log,
    bool? fileOpenLog,
    bool? noBattlEye,
    String? port,
  }) {
    AppLogger.instance.ui(
      '启动选项',
      action: '修改',
      details: <String, Object?>{
        'log': ?log,
        'file_open_log': ?fileOpenLog,
        'no_battl_eye': ?noBattlEye,
        'port': ?port,
      },
    );
    final updated = widget.launchOptions.copyWith(
      log: log,
      fileOpenLog: fileOpenLog,
      noBattlEye: noBattlEye,
      port: port,
    );
    widget.modService.saveLaunchOptions(updated);
    widget.onLaunchOptionsChanged(updated);
  }
}

// =====================================================================
//  齿轮按钮
// =====================================================================

class _GearButton extends StatefulWidget {
  final VoidCallback onTap;
  const _GearButton({required this.onTap});

  @override
  State<_GearButton> createState() => _GearButtonState();
}

class _GearButtonState extends State<_GearButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.bgPanel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hovered ? colors.borderAccent : colors.border,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.shadowSm,
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.settings_rounded,
              size: 20,
              color: _hovered ? colors.accent : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
