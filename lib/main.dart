import 'package:flutter/material.dart';

import 'services/app_logger.dart';
import 'services/app_paths.dart';
import 'services/app_signals.dart';
import 'services/update_service.dart';
import 'screens/home_screen.dart';
import 'services/launcher_service.dart';
import 'services/mod_service.dart';
import 'services/ue4ss_framework_service.dart';
import 'services/window_service.dart';
import 'theme/scum_theme.dart';
import 'widgets/exit_overlay.dart';
import 'widgets/splash_screen.dart';

/// 禁用 Flutter 桌面端默认的原生滚动条（platform Scrollbar）。
///
/// 项目统一用自绘 [ScumScrollbar]（scrollbar_painter.dart），
/// 桌面平台 ScrollBehavior 默认会给每个可滚动区域注入系统滚动条，
/// 与自绘滚动条叠加出现"双滚动条"。这里让 buildScrollbar 直接返回
/// child，保留自绘、去掉原生。
class _NoNativeScrollbarBehavior extends ScrollBehavior {
  const _NoNativeScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// SCUM Mod Manager v2 —— 入口。
///
/// 启动流程：
/// 1. 注册拖拽事件 handler（必须在 runApp 之后）
/// 2. 创建 ModService，调 autoDetectPathsAndApply()（启动时自动检测）
/// 3. 渲染主界面（带 selectedTab 状态控制侧边栏切换）
void main() {
  // v3 架构：先定安装根（引导器注入的 SCUM_MM_ROOT 优先），
  // 任何服务取路径之前必须完成。
  AppPaths.instance.init();
  // 日志默认关闭，用户需在「运行日志」页手动启用。
  // runApp() initializes WidgetsFlutterBinding which creates the ServicesBinding
  // singleton - we MUST install the drag-channel handler AFTER runApp(), otherwise
  // MethodChannel.setMethodCallHandler throws on null ServicesBinding.instance.
  WidgetsFlutterBinding.ensureInitialized();
  WindowService.installDragChannelHandler();
  LauncherService.installPushHandler();
  AppLogger.instance.info('拖拽/launcher 事件通道已安装');
  runApp(const ScumModManagerApp());
}

class ScumModManagerApp extends StatefulWidget {
  const ScumModManagerApp({super.key});

  @override
  State<ScumModManagerApp> createState() => _ScumModManagerAppState();
}

class _ScumModManagerAppState extends State<ScumModManagerApp> {
  late final ModService _modService;
  String _selectedTab = 'mods';
  // C2 Splash：app 是否"初始化完成"，完成后通知 SplashGate 启动淡出。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // WindowService.installDragChannelHandler() 已在 runApp 之前调用。

    _modService = ModService();
    // 启动时自动检测游戏路径（注册表 + Steam 库扫描）。
    // scanMods 已改异步（内部 await reclaimMods），用 then 确保日志里的
    // mod_count 是扫描完成后的真实值。
    // ignore: discarded_futures
    _modService.autoDetectPathsAndApply().then((_) {
      AppLogger.instance.info('启动路径检测与模组扫描已完成', {
        'client_path': _modService.scumInstallPath,
        'server_path': _modService.serverInstallPath,
        'mod_count': _modService.mods.length,
      });
    });
    // 启动时自动刷新云上 mod 目录。
    // ignore: discarded_futures
    _modService.refreshCloudCatalog();
    AppLogger.instance.info('云上 mod 目录刷新任务已启动');

        // 在线更新：清理上次残留 + 异步 fire-and-forget 检测更新。
        // 失败一律静默，不打扰用户。
        // ignore: discarded_futures
        UpdateService.cleanupStaleDownload();
        // ignore: discarded_futures
        UpdateService.checkOnStartup();
        AppLogger.instance.info('在线更新检测已启动', {
          'current_version': UpdateService.currentVersion,
        });

    // 给 Flutter 一帧时间把第一帧画出来（避免 Splash 切到主界面时
    // 看到空白帧），然后标记 ready 让 Splash 开始淡出。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });

    // UE4SS 框架首次解压（fire-and-forget）：
    // - 内置 assets/ue4ss_framework.zip → {exe_dir}/ue4ss_runtime/
    // - 幂等：stamp 文件比对 zip 字节大小，未变就跳过。
    // - 不阻塞 App 启动：用户在 UI 上看到主界面时后台解压一般已经完成。
    // ignore: discarded_futures
    Ue4ssFrameworkService.ensureExtracted();
    AppLogger.instance.info('UE4SS 框架解压任务已启动');
  }

  void _onTabChanged(String tab) {
    AppLogger.instance.ui('侧边栏：$tab', details: {'tab': tab});
    setState(() => _selectedTab = tab);
  }

  void _onPathsChanged() {
    // settings 保存路径后会调 scanMods()；这里只需触发 HomeScreen 重建。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // ValueListenableBuilder 让 themeMode 变化时 MaterialApp 重建，
    // 自动在 dark/light 主题间切换（无需手动 setState）。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSignals.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'SCUM Mod Manager',
          debugShowCheckedModeBanner: false,
          // 禁用桌面默认原生滚动条 —— 滚动条统一走自绘 ScumScrollbar
          scrollBehavior: const _NoNativeScrollbarBehavior(),
          theme: ScumTheme.lightTheme,
          darkTheme: ScumTheme.darkTheme,
          themeMode: mode,
          builder: (context, child) => Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              AppLogger.instance.ui(
                '应用窗口',
                action: '指针按下',
                details: {
                  'x': event.position.dx.round(),
                  'y': event.position.dy.round(),
                  'buttons': event.buttons,
                  'device_kind': event.kind.name,
                },
              );
            },
            child: child ?? const SizedBox.shrink(),
          ),
          // C2 Splash：用 SplashGate 包裹主界面 —— app 渲染在底层，
          // Splash 叠在上面，ready=true 后 SplashGate 自动淡出。
          // 应用退出遮罩：ExitOverlay 叠在最顶层，用户点窗口 X 时由 C++
          // 推送的 onAppExitRequest 触发，显示三步关闭动画。
          home: Stack(
            children: [
              SplashGate(
                ready: _ready,
                app: HomeScreen(
                  modService: _modService,
                  selectedTab: _selectedTab,
                  onTabChanged: _onTabChanged,
                  onPathsChanged: _onPathsChanged,
                ),
              ),
              // ExitOverlay 在 Stack 顶层 —— 渲染时盖住一切。
              // 自身带 ValueListenableBuilder 监听 AppSignals.exitOverlayStep，
              // step=null 时不渲染（不占事件）。
              const ExitOverlay(),
            ],
          ),
        );
      },
    );
  }
}
