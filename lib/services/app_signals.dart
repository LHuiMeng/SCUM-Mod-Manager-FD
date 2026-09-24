import 'package:flutter/material.dart';

/// 3c 全局信号 —— 跨 widget 共享的小型 ValueNotifier 集合。
///
/// 用 static singleton 而非 DI 框架（项目无 DI）—— 简单够用。
class AppSignals {
  /// 当前自定义背景图的绝对路径（null = 没选过，使用 Mica/亚克力默认）。
  ///
  /// 写入方：Settings 页的 `_pickBackground` / `_clearBackground`。
  /// 读取方：HomeScreen 通过 [ValueListenableBuilder] 监听变化。
  static final ValueNotifier<String?> backgroundPath = ValueNotifier<String?>(
    null,
  );

  /// Mica/亚克力用户开关（持久化到 config.json 的 `mica_enabled`）。
  ///
  /// 写入方：Settings 页 Appearance Tab 的 Mica toggle。
  /// 读取方：HomeScreen 启动时读取，并在此 toggle 翻时实时调
  /// [WindowService.enableMica] 翻 Mica 状态。
  static final ValueNotifier<bool> micaEnabled = ValueNotifier<bool>(false);

  /// 当前主题模式（dark / light / system）。
  ///
  /// 写入方：Settings 页的主题切换控件。
  /// 读取方：main.dart 的 [MaterialApp.themeMode]。
  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.dark,
  );

  /// 在线更新信号 —— 是否检测到新版本。
  ///
  /// `null` = 尚未检测过（启动早期），`false` = 已检测且无更新，
  /// `true` = 已检测且有新版本可下载。
  ///
  /// 写入方：[UpdateService.checkOnStartup] 调成功后写入。
  /// 读取方：标题栏 [TitleBar] 通过 [ValueListenableBuilder] 决定是否渲染
  ///        `_UpdateButton`（默认 null 不渲染，false 也不渲染，仅 true 才渲染）。
  static final ValueNotifier<bool?> updateAvailable = ValueNotifier<bool?>(
    null,
  );

  /// 当前最新版本号（如 "2.5.0"），仅在 [updateAvailable] = true 时有值。
  ///
  /// 用于标题栏按钮显示「有新版本 v2.5.0」。
  static final ValueNotifier<String?> latestVersion = ValueNotifier<String?>(
    null,
  );

  /// 当前下载进度信号（0.0 ~ 1.0），null = 未下载。
  ///
  /// 用于标题栏按钮显示下载进度条。下载完成后变 null，回到「点击安装」态。
  static final ValueNotifier<double?> updateProgress = ValueNotifier<double?>(
    null,
  );

  /// 下载完成信号 —— 是否已下载好但未安装。
  ///
  /// 写入方：[DownloadService] 下载并校验完成后置 true，用户点安装后置 false。
  /// 读取方：标题栏按钮据此显示「点击安装 v2.5.0」态。
  static final ValueNotifier<bool> updateDownloaded = ValueNotifier<bool>(
    false,
  );

  // ===== 应用退出流程覆盖层 =====

  /// 应用退出覆盖层状态 —— null = 不显示，其他 = 显示并描述当前阶段。
  ///
  /// 用户点窗口 X 时，C++ 推送 `onAppExitRequest` 给 Dart，
  /// Dart 端 `_onAppExitRequest` 启动退出流程：
  ///   1. installPushHandler 收到推送 → 立即 `exitOverlayStep = initializing`
  ///      → ExitOverlay 立刻显示遮罩（修复 #1：避免 GUI 冻结）
  ///   2. _onAppExitRequest 检测 isGameRunning：
  ///      - true  → `exitOverlayStep = killingGame → reclaimingEnv → exitingApp`
  ///      - false → `exitOverlayStep = exitingApp`（跳过 kill/reclaim 步骤）
  ///   3. `confirmAppExit()` → C++ 销毁窗口 → 进程退出
  ///
  /// 读取方：[ExitOverlay] 通过 `ValueListenableBuilder` 监听 + 切换 UI。
  /// 位置：[main.dart] MaterialApp.builder 把 ExitOverlay 叠在 widget 树最顶层。
  static final ValueNotifier<ExitOverlayStep?> exitOverlayStep =
      ValueNotifier<ExitOverlayStep?>(null);

  /// 退出流程是否要走 kill/reclaim（取决于游戏是否在跑）。
  ///
  /// 由 `_onAppExitRequest` 在检测 isGameRunning 后设置：
  /// - true = 游戏在跑 → ExitOverlay 显示完整三步
  /// - false = 没游戏 → ExitOverlay 显示简化版（只"正在退出程序"）
  ///
  /// 默认 null —— 在 _onAppExitRequest 检测完前不设置。检测完后立刻设，
  /// ExitOverlay 用它决定显示完整版还是简化版（避免 #2：没游戏时也强行
  /// 显示"正在关闭游戏/恢复游戏环境"等无意义步骤）。
  static final ValueNotifier<bool?> exitOverlayHasKillGame =
      ValueNotifier<bool?>(null);

  /// 服务器面板拖拽上传请求（HomeScreen 在 server_mods tab 下松手拖入文件时
  /// 置值，ServerModsPanel 监听并消费）。null = 无请求。
  ///
  /// 写入方：HomeScreen._onDroppedFiles（当前 tab == 'server_mods' 时）。
  /// 读取方：ServerModsPanel，处理完后置回 null。
  static final ValueNotifier<List<String>?> serverUploadRequest =
      ValueNotifier<List<String>?>(null);

  /// 服务器面板当前视图模式（false = 服务器列表；true = 本地镜像）。
  /// 供 HomeScreen 拖拽遮罩按语境显示文案（拖到镜像 vs 拖到服务器）。
  /// 写入方：ServerModsPanel._setShowMirror / dispose；读取方：HomeScreen。
  static final ValueNotifier<bool> serverMirrorMode = ValueNotifier(false);
}

/// 应用退出覆盖层的步骤状态 —— 决定 ExitOverlay 显示哪一段动画。
///
/// 每步都是一个「目标步骤」+「真实状态」。Dart 端推进时设置对应 step；
/// ExitOverlay 根据当前 step 渲染对勾 / spinner / 文字。
enum ExitOverlayStep {
  /// 第 0 步：用户刚点 X —— 等待 Dart 决定走哪些步骤。
  ///
  /// **关键**（v2.7+）：C++ 拦截 WM_CLOSE 推送 onAppExitRequest，
  /// Dart 端 installPushHandler 收到推送后**立刻**设置这个 step，
  /// 让 ExitOverlay 在 GUI 上立刻显示（不等 Dart 内部 await 完成），
  /// 避免用户看到「点击 X 后 GUI 冻结几秒没反应」。
  initializing,

  /// 第 1 步：正在关闭游戏（如有游戏在跑）
  killingGame,

  /// 第 2 步：正在恢复游戏环境（删除 PAK/UE4SS 等）
  reclaimingEnv,

  /// 第 3 步：正在退出程序
  exitingApp,
}
