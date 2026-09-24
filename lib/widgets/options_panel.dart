import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';
import '../models/launch_options.dart';

/// 启动选项弹窗面板 —— 私有状态管理 checkbox，即时回写到上层 callback。
///
/// 独立文件原因：
/// - 弹窗宽度固定 240px、padding/样式与 SCUM 主题强绑定，整套视觉一处管理；
/// - 私有 [_portCtrl] + [_localLog/_localFileOpenLog/_localNoBattlEye] 三个
///   local state 跟弹窗面板生命周期同生同死，外部不感知；
/// - 若以后要给"高级选项/调试选项"另起弹窗，复制本文件改文案即可。
class OptionsPopupPanel extends StatefulWidget {
  final bool log;
  final bool fileOpenLog;
  final bool noBattlEye;

  /// 有 PAK 模组时强制开启 -fileopenlog（置灰不可关）。
  final bool forcedFileOpenLog;

  /// 有 PAK 模组时强制开启 -nobattleye（置灰不可关）。
  final bool forcedNoBattlEye;
  final String port;

  final ValueChanged<bool> onLogChanged;
  final ValueChanged<bool> onFileOpenLogChanged;
  final ValueChanged<bool> onNoBattlEyeChanged;
  final ValueChanged<String> onPortChanged;

  final VoidCallback onClose;
  final ValueChanged<bool> onHoverChange;

  const OptionsPopupPanel({
    super.key,
    required this.log,
    required this.fileOpenLog,
    required this.noBattlEye,
    required this.forcedFileOpenLog,
    required this.forcedNoBattlEye,
    required this.port,
    required this.onLogChanged,
    required this.onFileOpenLogChanged,
    required this.onNoBattlEyeChanged,
    required this.onPortChanged,
    required this.onClose,
    required this.onHoverChange,
  });

  @override
  State<OptionsPopupPanel> createState() => _OptionsPopupPanelState();
}

class _OptionsPopupPanelState extends State<OptionsPopupPanel> {
  late final TextEditingController _portCtrl;
  late bool _localLog;
  late bool _localFileOpenLog;
  late bool _localNoBattlEye;

  @override
  void initState() {
    super.initState();
    _localLog = widget.log;
    _localFileOpenLog = widget.fileOpenLog;
    _localNoBattlEye = widget.noBattlEye;
    _portCtrl = TextEditingController(text: widget.port);
    // 端口 onChanged —— 每次按键写盘性能差（config.json I/O），且让上层
    // right_dock 的 setState 频繁触发。改为 onEnd：仅在失焦 / submit 时
    // 回调一次，减少不必要的 I/O 与 UI 重建。
    _portCtrl.addListener(_onPortChanged);
  }

  void _onPortChanged() {
    // 仅做输入格式化（去非数字），不立即回写上层 —— 回写在失焦时触发。
    final raw = _portCtrl.text;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned != raw && _portCtrl.text != cleaned) {
      // 用 selection 兼容：保留光标在文本末尾。
      _portCtrl.value = TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(offset: cleaned.length),
      );
      return;
    }
  }

  void _commitPort() {
    // 失焦或回车时回写上层（持久化 + UI 同步）。
    final raw = _portCtrl.text;
    if (LaunchOptions.isValidPort(raw)) {
      widget.onPortChanged(raw);
    } else if (raw.isEmpty) {
      widget.onPortChanged('');
    } else {
      // 非法值：保留输入但不上报，让上层用旧值。等用户修正再触发。
    }
  }

  @override
  void dispose() {
    _portCtrl.removeListener(_onPortChanged);
    _portCtrl.dispose();
    super.dispose();
  }

  void _toggleLog() {
    setState(() => _localLog = !_localLog);
    widget.onLogChanged(_localLog);
  }

  void _toggleFileOpenLog() {
    if (widget.forcedFileOpenLog) return;
    setState(() => _localFileOpenLog = !_localFileOpenLog);
    widget.onFileOpenLogChanged(_localFileOpenLog);
  }

  void _toggleNoBattlEye() {
    if (widget.forcedNoBattlEye) return;
    setState(() => _localNoBattlEye = !_localNoBattlEye);
    widget.onNoBattlEyeChanged(_localNoBattlEye);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final forced = widget.forcedNoBattlEye;
    final forcedFileOpen = widget.forcedFileOpenLog;
    final fileOpenValue = forcedFileOpen || _localFileOpenLog;
    final nobattValue = forced || _localNoBattlEye;

    return Stack(
      children: [
        // 全屏透明点击层，点击关闭弹窗
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(color: Colors.transparent),
          ),
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 68),
            child: MouseRegion(
              onEnter: (_) => widget.onHoverChange(true),
              onExit: (_) => widget.onHoverChange(false),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - value)),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  width: 240,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colors.border),
                    boxShadow: [
                      BoxShadow(
                        color: colors.shadowMd,
                        blurRadius: 16,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '启动选项',
                        style: TextStyle(
                          color: colors.textDim,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _Checkbox(
                        label: '-log',
                        value: _localLog,
                        onTap: _toggleLog,
                        enabled: true,
                      ),
                      const SizedBox(height: 6),
                      _Checkbox(
                        label: forcedFileOpen ? '-fileopenlog (PAK 强制)' : '-fileopenlog',
                        value: fileOpenValue,
                        onTap: _toggleFileOpenLog,
                        enabled: !forcedFileOpen,
                      ),
                      const SizedBox(height: 6),
                      _Checkbox(
                        label: forced ? '-nobattleye (PAK 强制)' : '-nobattleye',
                        value: nobattValue,
                        onTap: _toggleNoBattlEye,
                        enabled: !forced,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            '-port=',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 70,
                            child: _PortField(
                              controller: _portCtrl,
                              onCommit: _commitPort,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '(服务端)',
                            style: TextStyle(
                              color: colors.textDim,
                              fontSize: 10,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 自绘复选框（不依赖 Flutter [Checkbox]，便于样式自定义）。
///
/// 私有：本面板专用，不需要被其他 widget 复用。
class _Checkbox extends StatelessWidget {
  final String label;
  final bool value;
  final VoidCallback onTap;
  final bool enabled;

  const _Checkbox({
    required this.label,
    required this.value,
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? colors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: enabled
                    ? (value ? colors.accent : colors.textDim)
                    : colors.textDim.withValues(alpha: 0.3),
              ),
            ),
            child: value
                ? Icon(Icons.check_rounded, size: 10, color: colors.bgDark)
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: enabled
                  ? colors.textSecondary
                  : colors.textDim.withValues(alpha: 0.5),
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

/// 自绘端口输入框 —— 用 EditableText + 自绘背景/边框，
/// 无 Material 原生 TextField（保持项目"全自绘"约束）。
/// 键盘类型限制数字（TextInputType.number）。
class _PortField extends StatefulWidget {
  final TextEditingController controller;

  /// 失焦 / 回车时回调（commit port 到上层）。
  final VoidCallback onCommit;

  const _PortField({required this.controller, required this.onCommit});

  @override
  State<_PortField> createState() => _PortFieldState();
}

class _PortFieldState extends State<_PortField> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() => _focused = _focusNode.hasFocus);
    // 失焦时 commit（聚焦 → 失焦）。聚焦时不调。
    if (!_focusNode.hasFocus) {
      widget.onCommit();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final borderColor = _focused ? colors.borderAccent : colors.border;
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: colors.bgCard,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: borderColor, width: _focused ? 1.5 : 1),
        ),
        child: EditableText(
          controller: widget.controller,
          focusNode: _focusNode,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 11,
            decoration: TextDecoration.none,
          ),
          cursorColor: colors.accent,
          backgroundCursorColor: colors.textDim,
          keyboardType: TextInputType.number,
          // 用户按回车 → 提交并失焦。
          onSubmitted: (_) {
            widget.onCommit();
            _focusNode.unfocus();
          },
        ),
      ),
    );
  }
}
