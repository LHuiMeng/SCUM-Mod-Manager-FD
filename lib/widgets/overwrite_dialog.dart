/// PAK / UE4SS mod 导入重名冲突对话框 —— 自绘 overlay popup，"立即执行"模式。
///
/// 使用场景：用户拖入或选择多个文件 → 拷贝前先扫描目标目录，把同名冲突列出
/// → 弹此对话框让用户逐项决定 "覆盖" / "跳过"。
///
/// 设计要点：
/// - **点击即生效**：每行点击「覆盖 / 跳过」立即调上层 [onItemResolved] 处理该项，
///   处理完成后由上层调 [OverwriteDialog.markItemResolved] 划掉该行（视觉反馈）。
/// - **划掉视觉**：已决策的行降透明度 + 中划线 + 灰色 + 按钮禁用。
/// - **全项处理完自动关闭**：所有项都 markResolved → 自动 _commitAndClose。
/// - **顶部批量按钮**："全部覆盖" / "全部跳过"——点击后批量回调所有剩余未决策项。
/// - **点空白兜底**：背景点击 = 用顶部批量按钮处理所有剩余项（保证流程不卡）。
///
/// 决策回调签名：
/// - [OverwriteDialog.show.onItemResolved] 每项处理时调用 (sourcePath, overwrite)。
///   上层在该回调里执行实际的文件操作，**最后一步必须同步调**
///   [OverwriteDialog.markItemResolved]——这是 dialog 划线 + 检查关闭的依据。
/// - [OverwriteDialog.show.onAllDone] 所有项都 markResolved 之后回调一次，
///   参数 (overwritePaths, skipPaths)——上层用于后续收尾
///   （例如同步 mods.txt、关闭 drop overlay）。
library;

import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// 冲突项。
///
/// kind 用于在 UI 上展示类型徽章（PAK / UE4SS zip / UE4SS folder），
/// 让用户清楚不同类型 mod 的覆盖后果。
class OverwriteItem {
  /// 源文件 / 文件夹绝对路径。
  final String sourcePath;
  /// 目标文件 / 文件夹绝对路径（已存在，本管理器想覆盖/跳过）。
  final String destPath;
  /// 原始文件名（用于 UI 显示）。
  final String fileName;
  /// 目标文件大小（bytes；UE4SS 文件夹 = 整个目录累计字节数）。
  final int destSize;
  /// 源文件大小（bytes；UE4SS 文件夹 = 整个目录累计字节数）。
  final int sourceSize;
  /// 冲突项类型：'pak' / 'ue4ss_zip' / 'ue4ss_folder'。
  final String kind;

  OverwriteItem({
    required this.sourcePath,
    required this.destPath,
    required this.fileName,
    required this.destSize,
    required this.sourceSize,
    required this.kind,
  });
}

class OverwriteDialog {
  OverwriteDialog._();

  static OverlayEntry? _entry;
  static bool _showing = false;

  /// 显示冲突对话框（"立即执行"模式）。
  ///
  /// [items] 冲突项列表（已存在的目标 + 新源文件）。
  /// [onItemResolved] 每项处理时回调 (sourcePath, overwrite)。
  ///   上层应在该回调里执行实际的文件操作，**末尾同步**调
  ///   [OverwriteDialog.markItemResolved] 让 dialog 划线 + 检查关闭。
  /// [onAllDone] 所有项都处理完后回调 (overwritePaths, skipPaths)。
  static void show(
    BuildContext context, {
    required List<OverwriteItem> items,
    required Future<void> Function(String sourcePath, bool overwrite)
        onItemResolved,
    required void Function(List<String> overwritePaths, List<String> skipPaths)
        onAllDone,
  }) {
    if (_showing) {
      _dismiss();
    }

    final state = _OverwriteDialogState(items, onItemResolved, onAllDone);
    _entry = OverlayEntry(
      builder: (ctx) => _OverwritePanel(state: state),
    );
    _showing = true;
    Overlay.of(context).insert(_entry!);
  }

  /// 上层完成单项处理后调用：划掉该行 + 检查关闭。
  ///
  /// 公开 API：home_screen 的 onItemResolved lambda 末尾同步调用此方法。
  /// 若上层忘了调，dialog 永不关闭——所以这是约定。
  static void markItemResolved(String sourcePath, bool overwrite) {
    final entry = _entry;
    if (entry == null) return;
    final state = _currentState();
    if (state == null) return;
    state.markResolved(sourcePath, overwrite);
  }

  static _OverwriteDialogState? _currentState() {
    // 通过 OverlayEntry 的 _OverwritePanel 找到 state。
    // 这里我们用 panel 在 dispose 时清空 state 注册表，所以用静态引用。
    return _OverwriteDialogState._currentInstance;
  }

  static void _dismiss() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
    _showing = false;
    _OverwriteDialogState._currentInstance = null;
  }
}

/// 对话框共享状态：跟踪所有未决策项 + 已决策项 + 顶部批量状态。
///
/// 单例模式：同一时刻只有一个 OverwriteDialog 实例活跃，
/// 通过 [_currentInstance] 让 [OverwriteDialog.markItemResolved] 找到当前实例。
class _OverwriteDialogState {
  static _OverwriteDialogState? _currentInstance;

  final List<OverwriteItem> items;

  /// 每项的最终决策：null = 未决策，true = 覆盖，false = 跳过。
  final Map<String, bool> _decisions = {};

  /// 已处理的项（已 markItemResolved 调过），用于避免重复处理 + 触发关闭检查。
  final Set<String> _marked = <String>{};

  /// 顶部批量按钮：true = 全部覆盖；false = 全部跳过。
  bool bulkOverwrite = true;

  /// 每项处理回调（实际执行文件覆盖 / 跳过操作）。
  final Future<void> Function(String sourcePath, bool overwrite)
      onItemResolved;

  /// 全部处理完回调。
  final void Function(List<String> overwritePaths, List<String> skipPaths)
      onAllDone;

  /// panel widget 引用——用于 markResolved 触发 panel 重建（划线 + 禁用按钮）。
  _OverwritePanelState? _panel;

  /// 安全调 setState —— 即使 panel 已 dispose（dispose 之后才把 _panel
  /// 置 null 之前那一帧间隙），也不抛 `setState() called after dispose()`。
  void _safePanelSetState() {
    final panel = _panel;
    if (panel != null && panel.mounted) {
      panel.setState(() {});
    }
  }

  _OverwriteDialogState(this.items, this.onItemResolved, this.onAllDone) {
    _currentInstance = this;
  }

  /// 注册 panel（panel mount 时调）。
  void attachPanel(_OverwritePanelState panel) {
    _panel = panel;
  }

  /// 解除 panel 注册（panel dispose 时调）。
  void detachPanel(_OverwritePanelState panel) {
    if (identical(_panel, panel)) _panel = null;
  }

  /// 处理单项决策（用户点「覆盖 / 跳过」按钮时调）。
  ///
  /// 1. 立即禁用该行按钮（视觉反馈：用户操作已捕获）
  /// 2. 异步调用上层 onItemResolved 处理文件
  /// 3. 等上层完成后关闭 dialog（由上层的 markItemResolved 触发）
  Future<void> resolve(String sourcePath, bool overwrite) async {
    if (_marked.contains(sourcePath)) return;
    _decisions[sourcePath] = overwrite;
    // 立即 setState 让按钮禁用（视觉反馈用户操作已被捕获）
    _safePanelSetState();
    // 等上层完整处理完（包括 markItemResolved）。
    // 上层约定：处理完文件后必须同步调 OverwriteDialog.markItemResolved。
    await onItemResolved(sourcePath, overwrite);
  }

  /// 上层调用：处理完一项后，划掉该行 + 检查关闭。
  void markResolved(String sourcePath, bool overwrite) {
    if (_marked.contains(sourcePath)) return;
    _decisions[sourcePath] = overwrite;
    _marked.add(sourcePath);
    _safePanelSetState();
    if (_isAllResolved) {
      _commitAndClose();
    }
  }

  /// 批量处理所有剩余未决策项（点「全部覆盖」/「全部跳过」/点空白时调）。
  ///
  /// 按顺序同步触发每项上层处理，等所有 markItemResolved 完成才关 dialog。
  Future<void> resolveAllRemaining(bool overwrite) async {
    bulkOverwrite = overwrite;
    for (final item in items) {
      if (_marked.contains(item.sourcePath)) continue;
      _decisions[item.sourcePath] = overwrite;
      _safePanelSetState();
      // onItemResolved 是 async，必须 await 它执行完——
      // 否则上层还没处理完就检查 _isAllResolved 会提前关闭。
      await onItemResolved(item.sourcePath, overwrite);
    }
    if (_isAllResolved) {
      _commitAndClose();
    }
  }

  bool get _isAllResolved =>
      items.every((it) => _marked.contains(it.sourcePath));

  /// 触发 onAllDone 回调并关闭 overlay。
  void _commitAndClose() {
    final overwrite = <String>[];
    final skip = <String>[];
    for (final item in items) {
      final d = _decisions[item.sourcePath];
      if (d == true) {
        overwrite.add(item.sourcePath);
      } else if (d == false) {
        skip.add(item.sourcePath);
      }
    }
    // 用 microtask 防止在 setState 过程中触发 overlay 移除
    Future.microtask(() {
      onAllDone(overwrite, skip);
    });
    OverwriteDialog._dismiss();
  }

  /// 点空白兜底：用顶部批量按钮处理所有剩余未决策项。
  void resolveAllRemainingViaBackground() {
    resolveAllRemaining(bulkOverwrite);
  }
}

/// 顶层 panel widget。
class _OverwritePanel extends StatefulWidget {
  final _OverwriteDialogState state;

  const _OverwritePanel({required this.state});

  @override
  State<_OverwritePanel> createState() => _OverwritePanelState();
}

class _OverwritePanelState extends State<_OverwritePanel> {
  @override
  void initState() {
    super.initState();
    widget.state.attachPanel(this);
  }

  @override
  void dispose() {
    widget.state.detachPanel(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final colors = ScumColors.of(context);

    return Stack(
      children: [
        // 全屏遮罩 + 点击空白 = 用顶部批量按钮处理所有剩余项
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: state.resolveAllRemainingViaBackground,
            child: Container(color: colors.overlay),
          ),
        ),

        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 460),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              builder: (context, v, child) => Opacity(
                opacity: v,
                child: Transform.scale(scale: 0.95 + 0.05 * v, child: child),
              ),
              child: GestureDetector(
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
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 标题 ──
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: colors.dangerLight,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '检测到同名 mod',
                            style: TextStyle(
                              color: colors.dangerLight,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${state.items.length} 项冲突',
                            style: TextStyle(
                              color: colors.textDim,
                              fontSize: 10,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '本地已存在同名文件，点击「覆盖」或「跳过」立即生效。'
                        '点空白 = 用顶部批量按钮处理所有剩余项。',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // ── 批量按钮 ──
                      Row(
                        children: [
                          _BulkButton(
                            label: '全部覆盖',
                            active: state.bulkOverwrite,
                            danger: true,
                            onTap: () =>
                                state.resolveAllRemaining(true),
                          ),
                          const SizedBox(width: 6),
                          _BulkButton(
                            label: '全部跳过',
                            active: !state.bulkOverwrite,
                            danger: false,
                            onTap: () =>
                                state.resolveAllRemaining(false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // ── 冲突列表 ──
                      Flexible(
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 280),
                          decoration: BoxDecoration(
                            color: colors.bgCard,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: colors.border),
                          ),
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: state.items.length,
                            itemBuilder: (context, idx) {
                              final item = state.items[idx];
                              final resolved =
                                  state._marked.contains(item.sourcePath);
                              return _ConflictRow(
                                item: item,
                                resolved: resolved,
                                onOverwrite: resolved
                                    ? null
                                    : () => state.resolve(
                                          item.sourcePath,
                                          true,
                                        ),
                                onSkip: resolved
                                    ? null
                                    : () => state.resolve(
                                          item.sourcePath,
                                          false,
                                        ),
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // ── 底部提示 ──
                      Text(
                        '点击「覆盖」或「跳过」立即处理该行',
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
      ],
    );
  }
}

/// 冲突项单行 UI。
class _ConflictRow extends StatelessWidget {
  final OverwriteItem item;
  final bool resolved;

  /// null 表示已解决，按钮禁用。
  final VoidCallback? onOverwrite;
  final VoidCallback? onSkip;

  const _ConflictRow({
    required this.item,
    required this.resolved,
    required this.onOverwrite,
    required this.onSkip,
  });

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // 文件名 + 类型徽章 + (已处理：删除线)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: resolved
                              ? colors.textDim
                              : colors.textPrimary,
                          fontSize: 12,
                          fontFamily: 'Consolas',
                          decoration: resolved
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _KindBadge(kind: item.kind),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '已存在 ${_formatSize(item.destSize)}',
                      style: TextStyle(
                        color: colors.textDim,
                        fontSize: 10,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '→ 新 ${_formatSize(item.sourceSize)}',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 10,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 覆盖按钮
          _ChoiceButton(
            label: '覆盖',
            disabled: resolved,
            onTap: onOverwrite,
          ),
          const SizedBox(width: 4),
          // 跳过按钮
          _ChoiceButton(
            label: '跳过',
            disabled: resolved,
            onTap: onSkip,
          ),
        ],
      ),
    );
  }
}

/// 类型徽章 —— 让冲突项列表里能区分 PAK / UE4SS zip / UE4SS folder。
class _KindBadge extends StatelessWidget {
  final String kind;

  const _KindBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final (String label, Color color) = switch (kind) {
      'pak' => ('PAK', colors.accentDim),
      'ue4ss_zip' => ('ZIP', colors.badgeCfg),
      'ue4ss_folder' => ('DIR', colors.success),
      _ => ('---', colors.textDim),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// 批量按钮（"全部覆盖" / "全部跳过"）。
class _BulkButton extends StatefulWidget {
  final String label;
  final bool active;
  final bool danger;
  final VoidCallback onTap;

  const _BulkButton({
    required this.label,
    required this.active,
    required this.danger,
    required this.onTap,
  });

  @override
  State<_BulkButton> createState() => _BulkButtonState();
}

class _BulkButtonState extends State<_BulkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final base = widget.danger ? colors.dangerLight : colors.textDim;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: widget.active
                ? base.withValues(alpha: 0.20)
                : (_hovered
                    ? colors.bgHover
                    : colors.bgCard),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: widget.active
                  ? base
                  : (_hovered ? colors.border : colors.border),
              width: widget.active ? 1.0 : 0.8,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.active ? base : colors.textSecondary,
              fontSize: 11,
              fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单项选择按钮（覆盖/跳过）。
class _ChoiceButton extends StatefulWidget {
  final String label;

  /// true 时禁用点击（已解决）。
  final bool disabled;

  /// null 表示禁用（已解决）。
  final VoidCallback? onTap;

  const _ChoiceButton({
    required this.label,
    required this.disabled,
    required this.onTap,
  });

  @override
  State<_ChoiceButton> createState() => _ChoiceButtonState();
}

class _ChoiceButtonState extends State<_ChoiceButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: widget.disabled ? null : (_) => setState(() => _hovered = true),
      onExit: widget.disabled ? null : (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.disabled
                ? colors.bgHover.withValues(alpha: 0.3)
                : (_hovered ? colors.bgHover : Colors.transparent),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: widget.disabled
                  ? colors.border
                  : (_hovered ? colors.border : colors.border),
              width: 0.8,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.disabled ? colors.textDim : colors.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}