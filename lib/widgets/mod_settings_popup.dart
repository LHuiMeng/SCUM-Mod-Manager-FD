/// PAK 设置悬浮窗 —— 编辑标签 + 备注。
///
/// 行为：
/// - 点击 ModCard 上的"设置"按钮 → 在屏幕中央显示
/// - 鼠标离开悬浮窗 → 1 秒后自动关闭（保存当前内容）
/// - 点击回车（备注多行框）或标签输入回车 → 立即关闭（保存）
///
/// 单例 overlay：同一时刻只能打开一个 PAK 的设置窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/scum_colors.dart';

class ModSettingsPopup {
  ModSettingsPopup._();

  static OverlayEntry? _entry;
  static Timer? _closeTimer;
  static bool _showing = false;

  /// 显示悬浮窗。
  ///
  /// [tags] 当前 mod 已有的标签列表。
  /// [notes] 当前 mod 的备注。
  /// [onSave] 用户关闭时回调，参数为 (新 tags, 新 notes)。
  static void show(
    BuildContext context, {
    required String modName,
    required List<String> tags,
    required String notes,
    required void Function(List<String> tags, String notes) onSave,
  }) {
    // 关闭已存在的弹窗（避免叠加）。
    if (_showing) {
      _closeTimer?.cancel();
      try {
        _entry?.remove();
      } catch (_) {}
      _showing = false;
      _typing = false;
    }

    _entry = OverlayEntry(
      builder: (context) => _ModSettingsPanel(
        modName: modName,
        initialTags: tags,
        initialNotes: notes,
        onSave: (newTags, newNotes) {
          // 保存 + 关闭。
          onSave(newTags, newNotes);
          _closeTimer?.cancel();
          try {
            _entry?.remove();
          } catch (_) {}
          _showing = false;
        },
        onHoverChange: (hovering) {
          if (hovering) {
            // 鼠标回到弹窗范围内 → 取消关闭准备。
            _closeTimer?.cancel();
          } else {
            // 鼠标离开弹窗 xy 范围 → 才开始准备关闭（1 秒后再确认）。
            _scheduleAutoClose();
          }
        },
      ),
    );
    _showing = true;
    Overlay.of(context).insert(_entry!);
  }

  /// 定时关闭弹窗（离开悬浮窗 1 秒后）—— 输入聚焦期间顺延重查，避免
  /// 点输入法候选窗（位于弹窗外的透明点击层上）误触发关闭。
  /// 递归 Timer：每次到期重查一次，直到用户结束输入或鼠标回到弹窗。
  static void _scheduleAutoClose() {
    _closeTimer?.cancel();
    void tryAutoClose() {
      if (_typing) {
        // 输入进行中（输入法候选窗可能正被点击）→ 推迟自动关闭。
        _closeTimer = Timer(const Duration(milliseconds: 1000), tryAutoClose);
        return;
      }
      final save = ModSettingsPopup._pendingSave;
      if (save != null) {
        save();
        ModSettingsPopup._pendingSave = null;
      }
      try {
        _entry?.remove();
      } catch (_) {}
      _showing = false;
      _typing = false;
    }

    _closeTimer = Timer(const Duration(milliseconds: 1000), tryAutoClose);
  }

  /// 是否处于输入聚焦（输入法激活）状态 —— 此期间豁免外点关闭与悬停自动关闭。
  static bool _typing = false;

  /// 离开悬浮窗时回调函数缓存（hover-leave 自动关闭时由 panel 注册）。
  static void Function()? _pendingSave;

  static void dismiss() {
    _closeTimer?.cancel();
    try {
      _entry?.remove();
    } catch (_) {}
    _showing = false;
  }
}

/// 悬浮窗面板本体（私有 widget）。
class _ModSettingsPanel extends StatefulWidget {
  final String modName;
  final List<String> initialTags;
  final String initialNotes;
  final void Function(List<String> tags, String notes) onSave;
  final ValueChanged<bool> onHoverChange;

  const _ModSettingsPanel({
    required this.modName,
    required this.initialTags,
    required this.initialNotes,
    required this.onSave,
    required this.onHoverChange,
  });

  @override
  State<_ModSettingsPanel> createState() => _ModSettingsPanelState();
}

class _ModSettingsPanelState extends State<_ModSettingsPanel> {
  late final TextEditingController _tagCtrl;
  late final TextEditingController _notesCtrl;
  late List<String> _tags;
  late final FocusNode _notesFocus;

  /// IME 组字判定 —— 仅当输入法**正在组字**（拼音候选态）时豁免自动关闭。
  /// 关闭时机以鼠标坐标为准：离开弹窗 xy 范围即开始准备关闭（1 秒后确认）；
  /// 不再以「输入框聚焦」为豁免（聚焦不会随鼠标移出而解除，会挡住关闭）。
  void _syncTyping() {
    ModSettingsPopup._typing =
        _tagCtrl.value.composing.isValid || _notesCtrl.value.composing.isValid;
  }

  @override
  void initState() {
    super.initState();
    _tags = [...widget.initialTags];
    _tagCtrl = TextEditingController();
    _notesCtrl = TextEditingController(text: widget.initialNotes);
    _notesFocus = FocusNode();

    // IME 组字监听：组字（拼音候选）期间豁免自动关闭；
    // 选词上屏/取消后立即恢复「离开弹窗即准备关闭」。
    _tagCtrl.addListener(_syncTyping);
    _notesCtrl.addListener(_syncTyping);

    // ESC = 快速关闭且不保存（组字中先让给输入法取消候选）。
    HardwareKeyboard.instance.addHandler(_handleEscape);

    // 注册：hover-leave 自动关闭时调用 → 触发保存并销毁 overlay。
    ModSettingsPopup._pendingSave = _commitAndClose;
  }

  @override
  void dispose() {
    // 清理：避免 timer 触发已经 dispose 的 panel。
    if (identical(ModSettingsPopup._pendingSave, _commitAndClose)) {
      ModSettingsPopup._pendingSave = null;
    }
    // 取消本 panel 关联的 hover-leave 自动关闭 timer —— panel 已 dispose
    // 后 timer 触发会试图 _entry?.remove()（无害，但无意义），更糟的是
    // 它会试图调 _commitAndClose（已加 mounted 守卫）。
    ModSettingsPopup._closeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleEscape);
    _tagCtrl.dispose();
    _notesCtrl.dispose();
    _notesFocus.dispose();
    // 复位弹窗的输入激活态（防残留影响下次打开）。
    ModSettingsPopup._typing = false;
    super.dispose();
  }

  /// 把当前输入按空格/tab 拆分为多个标签，全部加入 _tags。
  /// 已存在的不会重复添加。提交后清空输入框。
  void _addTag() {
    final raw = _tagCtrl.text;
    if (raw.isEmpty) return;
    final parts = raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      _tagCtrl.clear();
      return;
    }
    setState(() {
      _tags = [..._tags, ...parts.where((t) => !_tags.contains(t))];
      _tagCtrl.clear();
    });
  }

  /// 文本变化监听：检测尾部空格 → 自动 commit 并清空输入。
  void _onTagTextChanged(String _) {
    final text = _tagCtrl.text;
    if (text.endsWith(' ') || text.endsWith('\t')) {
      _addTag();
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _tags = _tags.where((t) => t != tag).toList();
    });
  }

  void _commitAndClose() {
    // mounted 守卫：避免 hover-leave 自动关闭的 timer 在 panel dispose 后
    // 才触发（dispose 把 _pendingSave 引用清掉了，但 timer 早已调度）——
    // 此时 widget.onSave 可能仍然引用某些已 dispose 的资源。
    if (!mounted) return;
    widget.onSave(_tags, _notesCtrl.text.trim());
  }

  /// ESC 快速关闭且不保存。
  bool _handleEscape(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    // 输入法正在组字：ESC 先让给输入法取消候选，再按一次才关闭弹窗。
    if (_tagCtrl.value.composing.isValid ||
        _notesCtrl.value.composing.isValid) {
      return false;
    }
    _cancelAndClose();
    return true;
  }

  /// 直接撤销弹窗：不调用 onSave（丢弃未提交的标签/备注改动）。
  void _cancelAndClose() {
    ModSettingsPopup._closeTimer?.cancel();
    ModSettingsPopup._pendingSave = null; // 防 hover 计时器再保存
    ModSettingsPopup._typing = false;
    try {
      ModSettingsPopup._entry?.remove();
    } catch (_) {}
    ModSettingsPopup._showing = false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        // 全屏透明点击层，点击空白处关闭（不保存）—— 但要避免点击弹窗本体关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              // 点弹窗外的空白（含输入法候选窗误点处）：**不立即关闭**，
              // 只进入「鼠标已离开弹窗 xy 范围」状态 → 启动准备关闭计时；
              // 鼠标一旦回到弹窗内（MouseRegion onEnter）即取消。
              // 彻底规避输入法候选窗一点即关的问题。
              ModSettingsPopup._scheduleAutoClose();
            },
            child: Container(color: colors.overlay),
          ),
        ),

        // 弹窗本体（屏幕中央）
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
            child: MouseRegion(
              onEnter: (_) => widget.onHoverChange(true),
              onExit: (_) => widget.onHoverChange(false),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                builder: (context, v, child) => Opacity(
                  opacity: v,
                  child: Transform.scale(scale: 0.95 + 0.05 * v, child: child),
                ),
                child: GestureDetector(
                  // 阻止点击穿透到背景层。
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.borderAccent),
                      boxShadow: [
                        BoxShadow(
                          color: colors.shadowMd,
                          blurRadius: 16,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── 标题 ──
                        Text(
                          '编辑 · ${widget.modName}',
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // ── 标签行 ──
                        Text(
                          '标签',
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final tag in _tags)
                              _TagChip(
                                label: tag,
                                onRemove: () => _removeTag(tag),
                              ),
                            SizedBox(
                              width: 100,
                              height: 22,
                              child: _SimpleInputField(
                                controller: _tagCtrl,
                                hintText: '新标签',
                                onSubmit: (_) => _addTag(),
                                onChange: _onTagTextChanged,
                              ),
                            ),
                            _SmallAddButton(onTap: _addTag),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // ── 备注行 ──
                        Text(
                          '备注',
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 140),
                          child: _SimpleInputField(
                            controller: _notesCtrl,
                            hintText: '输入备注…',
                            maxLines: 5,
                            minLines: 3,
                            enterSubmits: true,
                            onSubmit: (_) {
                              // Enter 直接保存并关闭。
                              _commitAndClose();
                            },
                            onChange: (_) {
                              // 备注文本变化触发 setState 刷新光标位置。
                              if (mounted) setState(() {});
                            },
                            textStyle: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 12,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        // ── 底部提示 ──
                        Text(
                          '回车 = 保存并关闭 · Ctrl+回车 = 换行 · ESC = 取消 · 鼠标离开自动保存',
                          style: TextStyle(
                            color: colors.textDim.withValues(alpha: 0.7),
                            fontSize: 10,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
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

// =====================================================================
//  内部子组件（私有）
// =====================================================================

class _TagChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _TagChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colors.accent,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 3),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, size: 12, color: colors.textDim),
          ),
        ],
      ),
    );
  }
}

class _SimpleInputField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final int? maxLines;
  final int? minLines;
  final TextStyle? textStyle;
  final ValueChanged<String>? onSubmit;
  final ValueChanged<String>? onChange;

  /// 聚焦状态变化回调（用于弹窗判断「输入法激活中」并豁免自动关闭）。
  final ValueChanged<bool>? onFocusChanged;

  /// 多行输入时：普通回车 → 触发 [onSubmit]（保存/提交）并拦截换行；
  /// Ctrl+回车 → 放行换行；输入法组字中回车让给选词。默认 false（原行为）。
  final bool enterSubmits;

  const _SimpleInputField({
    required this.controller,
    required this.hintText,
    this.maxLines = 1,
    this.minLines = 1,
    this.textStyle,
    this.onSubmit,
    this.onChange,
    this.onFocusChanged,
    this.enterSubmits = false,
  });

  @override
  State<_SimpleInputField> createState() => _SimpleInputFieldState();
}

class _SimpleInputFieldState extends State<_SimpleInputField> {
  bool _focused = false;
  String _text = '';
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    _text = widget.controller.text;
    if (widget.enterSubmits) {
      // 多行备注框按键策略：
      //   普通回车 = 提交保存（拦截，不换行）
      //   Ctrl+回车 = 放行换行
      //   输入法正在组字（拼音候选）时 回车让给选词
      _focus.onKeyEvent = (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        if (widget.controller.value.composing.isValid) {
          return KeyEventResult.ignored; // 组字中：回车交给输入法选词
        }
        final hw = HardwareKeyboard.instance;
        if (hw.isControlPressed || hw.isMetaPressed) {
          return KeyEventResult.ignored; // Ctrl+回车：保留换行
        }
        widget.onSubmit?.call(widget.controller.text);
        return KeyEventResult.handled; // 拦截：不插入换行
      };
    }
    _focus.addListener(() {
      final f = _focus.hasFocus;
      if (mounted) setState(() => _focused = f);
      // 上抛给弹窗：用于暂缓「鼠标离开范围后”的自动关闭计时（输入法激活中不关）。
      widget.onFocusChanged?.call(f);
    });
    widget.controller.addListener(() {
      final t = widget.controller.text;
      if (t != _text && mounted) setState(() => _text = t);
    });
    // 外部 onChange 钩子（用于监听文本空格自动提交）。
    if (widget.onChange != null) {
      widget.controller.addListener(() {
        widget.onChange!(widget.controller.text);
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final borderColor = _focused ? colors.borderAccent : colors.border;

    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgHover,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: borderColor),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Stack(
          children: [
            if (_text.isEmpty && !_focused)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.hintText,
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: widget.textStyle?.fontSize ?? 11,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            EditableText(
              controller: widget.controller,
              focusNode: _focus,
              style:
                  widget.textStyle ??
                  TextStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
              cursorColor: colors.accent,
              backgroundCursorColor: colors.textDim,
              selectionColor: colors.accent.withValues(alpha: 0.3),
              maxLines: widget.maxLines ?? 1,
              minLines: widget.minLines ?? 1,
              onSubmitted: widget.onSubmit,
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallAddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _SmallAddButton({required this.onTap});

  @override
  State<_SmallAddButton> createState() => _SmallAddButtonState();
}

class _SmallAddButtonState extends State<_SmallAddButton> {
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
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered
                ? colors.accent.withValues(alpha: 0.30)
                : colors.accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(Icons.add_rounded, size: 12, color: colors.accent),
        ),
      ),
    );
  }
}
