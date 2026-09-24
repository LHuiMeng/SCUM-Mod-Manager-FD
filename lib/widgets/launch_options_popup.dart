import 'dart:async';
import 'package:flutter/material.dart';

import 'options_panel.dart';

/// 启动选项弹窗的静态控制器。
///
/// 调用 `LaunchOptionsPopup.show(context, ...)` 在屏幕右下角显示，
/// 离开弹窗后 1 秒自动关闭，再次调用会替换旧弹窗。
///
/// 弹窗本体（[OptionsPopupPanel]）单独文件，本类只负责：
/// - 单例 overlay（同时只能一个弹窗）；
/// - hover 自动关闭计时；
/// - 显式 [dismiss]。
class LaunchOptionsPopup {
  LaunchOptionsPopup._();

  static OverlayEntry? _entry;
  static Timer? _closeTimer;
  static bool _showing = false;

  static void show(
    BuildContext context, {
    required bool log,
    required bool fileOpenLog,
    required bool noBattlEye,
    required String port,
    required bool forcedFileOpenLog,
    required bool forcedNoBattlEye,
    required ValueChanged<bool> onLogChanged,
    required ValueChanged<bool> onFileOpenLogChanged,
    required ValueChanged<bool> onNoBattlEyeChanged,
    required ValueChanged<String> onPortChanged,
  }) {
    // 修复：之前这里直接 return —— 用户在 popup 已显示时再点齿轮，
    // 第二次 show() 被吞掉，新参数（option 改了）永远不生效。
    // 现在：先 dismiss 旧 popup，再走正常 show 路径，参数完全替换。
    if (_showing) {
      _dismissInternal();
    }

    _entry = OverlayEntry(
      builder: (context) => OptionsPopupPanel(
        log: log,
        fileOpenLog: fileOpenLog,
        noBattlEye: noBattlEye,
        forcedFileOpenLog: forcedFileOpenLog,
        forcedNoBattlEye: forcedNoBattlEye,
        port: port,
        onLogChanged: onLogChanged,
        onFileOpenLogChanged: onFileOpenLogChanged,
        onNoBattlEyeChanged: onNoBattlEyeChanged,
        onPortChanged: onPortChanged,
        onClose: _dismissInternal,
        onHoverChange: (hovering) {
          if (hovering) {
            _closeTimer?.cancel();
          } else {
            _closeTimer?.cancel();
            _closeTimer = Timer(const Duration(seconds: 1), _dismissInternal);
          }
        },
      ),
    );
    _showing = true;
    Overlay.of(context).insert(_entry!);
  }

  /// 内部统一关闭逻辑 —— 同时清理 timer / overlay / showing 标志。
  /// 抽出来让 show 重入 + onClose + 自动关闭 timer 共用，避免各路径状态漂移。
  static void _dismissInternal() {
    _closeTimer?.cancel();
    _closeTimer = null;
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
    _showing = false;
  }

  static void dismiss() {
    _dismissInternal();
  }
}
