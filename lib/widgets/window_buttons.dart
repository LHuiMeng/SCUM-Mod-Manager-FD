import 'package:flutter/material.dart';
import '../theme/scum_colors.dart';

import '../services/window_service.dart';

/// 自绘窗口按钮（最小化 / 最大化 / 关闭）。
///
/// 军事风格：默认透明背景，hover 时切换为 2A2A2A（普通按钮）或 C0392B（关闭按钮）。
/// 拆分要点：
/// - 关闭按钮和普通按钮的 hover 颜色不同，单点抽离为 [_WindowButton] 子 widget；
/// - 最大化按钮的图标需要在"最大化 / 还原"两种状态间切换，
///   因此 [WindowButtons] 用 [StatefulWidget] 跟踪 [_isMaximized]。
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  bool _isMaximized = false;

  /// 标记当前是否已 schedule 过一次 postFrame sync（防多次 build
  /// 累积未执行的 callback）。
  bool _syncScheduled = false;

  /// 同步最大化状态（覆盖双击标题栏等 C++ 侧触发的状态变更）。
  /// 当 _isMaximized 与真实状态一致时不会触发 setState，避免循环。
  void _syncMaximize() {
    _syncScheduled = false; // 已开始执行，重置 flag
    WindowService.isMaximized().then((v) {
      if (mounted && v != _isMaximized) {
        setState(() => _isMaximized = v);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // 初始同步。
    _syncMaximize();
  }

  @override
  Widget build(BuildContext context) {
    // 窗口最大化/还原后（双击标题栏等），Flutter 因约束变化会重建整棵树，
    // 此 build 会被调用。同步图标状态，覆盖 C++ 侧触发的状态变更。
    //
    // 修复（旧 bug）：之前每次 build 都 `addPostFrameCallback(_syncMaximize)`，
    // 在窗口拖拽/resize 等高频重建场景下会累积大量未执行的 postFrame callback，
    // 每个 callback 都会调一次 WindowService.isMaximized() 走 MethodChannel，
    // 严重时一帧内累积上百次往返，UI 卡顿。改为：只 schedule 一次，
    // 多次 build 只保留最后一次。
    if (!_syncScheduled) {
      _syncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncMaximize());
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: Icons.horizontal_rule_rounded,
          tooltip: '最小化',
          onTap: _minimize,
        ),
        _WindowButton(
          icon: _isMaximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          tooltip: _isMaximized ? '还原' : '最大化',
          onTap: _toggleMaximize,
        ),
        _WindowButton(
          icon: Icons.close_rounded,
          tooltip: '关闭',
          isClose: true,
          onTap: _close,
        ),
      ],
    );
  }

  void _minimize() => WindowService.minimize();

  void _toggleMaximize() async {
    await WindowService.toggleMaximize();
    final realState = await WindowService.isMaximized();
    if (mounted) {
      setState(() => _isMaximized = realState);
    }
  }

  void _close() => WindowService.close();
}

/// 单个窗口按钮（最小化/最大化/关闭三选一通用）。
///
/// 视觉差异：close 按钮 hover 时背景变红 + 图标变白；普通按钮 hover 时
/// 背景变深灰 + 图标变浅灰。
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  // 单按钮尺寸常量（hover 区）。
  static const double _buttonWidth = 46;
  static const double _buttonHeight = 32;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final isClose = widget.isClose;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          // A4 微动效：hover 时按钮微微放大（1.05），150ms 过渡。
          // 配 32px 高的按钮，scale 5% 视觉上是"上抬"而不是"放大"，
          // 比单纯换背景色更精致。
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          scale: _hovered ? 1.05 : 1.0,
          child: Container(
            width: _buttonWidth,
            height: _buttonHeight,
            color: _hovered
                ? (isClose ? colors.danger : colors.bgHover)
                : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 14,
              color: isClose && _hovered
                  ? Colors.white
                  : (_hovered
                        ? colors.windowBtnIconHover
                        : colors.windowBtnIcon),
            ),
          ),
        ),
      ),
    );
  }
}
