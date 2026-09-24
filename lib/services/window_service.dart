import 'dart:async';

import 'package:flutter/services.dart';

/// 窗口控制服务 —— Dart 端 MethodChannel 封装。
///
/// 所有原生操作（最小化/最大化/关闭/拖拽接收/文件对话框）都在
/// C++ 端 `windows/runner/window_service_channel.cpp` 和
/// `windows/runner/drop_target.cpp` 实现。
///
/// Channel 名：`com.scummod/window`
/// 支持的方法（Dart -> C++）：
/// - `minimize`         &rarr; SC_MINIMIZE
/// - `maximize`         &rarr; 切换最大化/还原
/// - `close`            &rarr; SC_CLOSE
/// - `isMaximized`      &rarr; bool
/// - `getDroppedFiles`  &rarr; drain 拖拽队列，返回 List&lt;String&gt;
/// - `openFileDialog`   &rarr; 弹出原生文件对话框，返回 List&lt;String&gt;
/// - `enableMica`       &rarr; 探测并启用 Win11 22H2+ Mica 系统级背景，返回 bool
/// - `openImageDialog`  &rarr; 单选图片文件（背景图选择），返回 List&lt;String&gt;
///
/// 推送 channel（C++ -> Dart）：`com.scummod/drag`
/// - `onDragEnter`         &rarr; void，文件拖入窗口（悬停）
/// - `onDragLeave`         &rarr; void，文件拖出窗口
/// - `onDroppedFiles`      &rarr; List&lt;String&gt;，文件松手后回调（带路径列表）
class WindowService {
  WindowService._();

  /// 平台 MethodChannel（Dart -> C++）。
  static const MethodChannel _channel = MethodChannel('com.scummod/window');

  /// 推送 MethodChannel（C++ -> Dart），订阅 drag 事件。
  static const MethodChannel _dragChannel = MethodChannel('com.scummod/drag');

  // ===== 窗口控制 =====

  /// 最小化窗口到任务栏。
  static Future<void> minimize() => _invokeVoid('minimize');

  /// 切换最大化/还原状态。
  static Future<void> toggleMaximize() => _invokeVoid('maximize');

  /// 关闭窗口。
  static Future<void> close() => _invokeVoid('close');

  /// 查询当前是否处于最大化状态。
  ///
  /// 原生调用失败/未注册时返回 `false`（保守：视为非最大化）。
  static Future<bool> isMaximized() async {
    try {
      return await _channel.invokeMethod<bool>('isMaximized') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ===== 拖拽 & 文件对话框 =====

  /// 获取从资源管理器拖入的模组文件路径列表（PAK/INI）。
  ///
  /// 原生层维护一个拖拽队列，每次调用 drain 一次；UI 应在每次状态机
  /// 检测到拖拽结束后调用本方法。
  static Future<List<String>> getDroppedFiles() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getDroppedFiles',
      );
      return result?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// 打开原生文件选择对话框（支持多选，限定 .pak / .ini 过滤）。
  ///
  /// 返回用户选中的绝对路径列表（可能为空：用户点了取消）。
  static Future<List<String>> openFileDialog() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'openFileDialog',
      );
      return result?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// C1：探测并启用 Win11 22H2+ 系统级 Mica 背景。
  ///
  /// 参数：
  /// - [isDark]：当前应用主题是否暗色（影响 DWM 是否启用 DWMWA_USE_IMMERSIVE_DARK_MODE）。
  ///   - true → 暗色 Mica（深色透出桌面）
  ///   - false → 亮色 Mica（浅色透出桌面）
  ///   Mica 必须按应用主题设置，否则主人切到亮色时 Mica 仍渲染为系统
  ///   默认暗色，导致 Dart 透明背景看起来还是黑色。
  ///
  /// 返回值：
  /// - `true`  Mica 已启用。Dart 端应把背景设透明，让 DWM 把桌面磨砂透过来。
  /// - `false` OS 不支持 Mica（Win10 / 老 Win11）。Dart 端应改用半透明黑叠层
  ///           模拟"亚克力"效果。
  ///
  /// 调用时机：必须在主窗口 CreateWindow 之后。建议在 Flutter 首帧渲染前
  /// 调用（AppState initState 里），避免窗口一帧"实色"再变"透明"的闪烁。
  ///
  /// 主题切换时必须重调本方法（传新的 isDark），否则 Mica 颜色不会跟随。
  static Future<bool> enableMica({bool isDark = true}) async {
    try {
      return await _channel.invokeMethod<bool>(
        'enableMica',
        {'isDark': isDark},
      ) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 3c：单选图片文件对话框（限定 .png/.jpg/.jpeg/.webp）。
  ///
  /// 返回 0 或 1 个绝对路径字符串（用户取消时为空列表）。
  /// 用途：Settings 页让用户选背景图。
  static Future<List<String>> openImageDialog() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'openImageDialog',
      );
      return result?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// UE4SS mod 目录选择对话框（IFileOpenDialog + FOS_PICKFOLDERS）。
  ///
  /// 用户取消时返回空列表；选中时返回 1 个绝对路径。
  /// 用途：从对话框选择未打包的 UE4SS mod 文件夹（拖拽之外的备选入口）。
  static Future<List<String>> openFolderDialog() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'openFolderDialog',
      );
      return result?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  // ===== 推送事件订阅（C++ -> Dart） =====

  /// 拖拽进入窗口（用户从资源管理器拖文件经过窗口上方时触发）。
  ///
  /// 必须在 `initState` 注册，`dispose` 反注册。
  static void setOnDragEnter(VoidCallback? callback) {
    _onDragEnter = callback;
  }

  /// 拖拽离开窗口（光标离开窗口边界时触发）。
  static void setOnDragLeave(VoidCallback? callback) {
    _onDragLeave = callback;
  }

  /// 用户松手完成拖放（C++ 已经过滤只 .pak）。
  ///
  /// 回调参数 = 复制后的文件绝对路径列表。
  static void setOnDroppedFiles(ValueChanged<List<String>>? callback) {
    _onDroppedFiles = callback;
  }

  /// 安装 MethodChannel handler：路由到上面三个 setter 注册的回调。
  ///
  /// 必须在 main() 启动后调用一次。
  static void installDragChannelHandler() {
    _dragChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDragEnter':
          _onDragEnter?.call();
          return null;
        case 'onDragLeave':
          _onDragLeave?.call();
          return null;
        case 'onDroppedFiles':
          final files = (call.arguments as List?)?.cast<String>() ?? const [];
          _onDroppedFiles?.call(files);
          return null;
      }
      return null;
    });
  }

  static VoidCallback? _onDragEnter;
  static VoidCallback? _onDragLeave;
  static ValueChanged<List<String>>? _onDroppedFiles;

  // ===== 私有 =====

  /// 通用 void 调用包装：原生调用失败时吞掉异常（窗口操作不该把 UI 弄崩）。
  static Future<void> _invokeVoid(String method) async {
    try {
      await _channel.invokeMethod(method);
    } catch (_) {
      // 故意吞掉：窗口操作失败通常意味着进程即将结束，UI 无需提示。
    }
  }
}
