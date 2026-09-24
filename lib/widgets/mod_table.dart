/// 可配置多列表格 —— 列显隐 / 列顺序 / 列宽全部可由用户自定义。
///
/// 三个能力（表头 [ModTableHeader]）：
/// 1. 右键列头 → 弹出菜单勾选显示/隐藏哪些列
/// 2. 拖拽列头 → 调整列显示顺序
/// 3. 拖动列头右缘 → 调整列宽
///
/// 泛型设计：不绑定任何数据模型。[TableColumnSpec] 描述列（id/标题/默认宽），
/// [ColumnLayout] 保存用户的顺序/可见性/宽度配置；行渲染由各面板用
/// [buildConfigurableRow] 组装「固定左列 + 可配置数据列 + 固定右列」。
///
/// 全部自绘，无 Material 控件；颜色一律走 [ScumColors.of(context)]。
library;

import 'package:flutter/material.dart';

import '../models/mod_entry.dart';
import '../services/conflict_service.dart';
import '../services/mod_service.dart';
import '../theme/scum_colors.dart';
import '../theme/scum_theme.dart';
import 'mod_badge.dart';
import 'mod_card_action_button.dart';
import 'tag_filter_menu.dart';

// =====================================================================
//  列定义（泛型）
// =====================================================================

/// 单列描述。
class TableColumnSpec {
  /// 稳定 id（同时用于 config.json 持久化键，如 'name' / 'sha256'）。
  final String id;

  /// 列头显示文案。
  final String title;

  /// 默认列宽（逻辑 px，弹性分配时的权重基准）。
  final double defaultWidth;

  /// 列内容与表头文字的对齐语义。项目惯例：**统一居中**（表头与单元格水平一致）。
  final TextAlign align;

  const TableColumnSpec(
    this.id,
    this.title,
    this.defaultWidth, {
    this.align = TextAlign.center,
  });
}

/// TextAlign → Alignment（表头/单元格统一放置）。
Alignment _alignFor(TextAlign a) => switch (a) {
  TextAlign.right => Alignment.centerRight,
  TextAlign.center => Alignment.center,
  _ => Alignment.centerLeft,
};

/// 列宽上下限（逻辑 px）。
const double _kColWidthMin = 50;
const double _kColWidthMax = 520;

/// 列配置 —— 顺序 + 可见性 + 宽度（绑定 [specs]，不绑定数据模型）。
///
/// 可见性 = 「当前显示的列顺序数组」：order 里的列 = 显示，
/// 不在 order 里的列 = 隐藏（重新显示时按 specs 声明序补到末尾）。
class ColumnLayout {
  final List<TableColumnSpec> specs;

  /// 当前显示的列 id（顺序即显示顺序）。
  List<String> order;

  /// 各列宽度覆盖（key = 列 id，value = 宽度；缺省回退 spec.defaultWidth）。
  final Map<String, double> widths;

  ColumnLayout({
    required this.specs,
    List<String>? order,
    Map<String, double>? widths,
  }) : order = order ?? [for (final s in specs) s.id],
       widths = widths ?? <String, double>{};

  /// 主界面本地 mod 列表的默认列顺序（名称/备注/类型/状态/大小/时间）。
  ColumnLayout.defaultLocal()
    : this(
        specs: localColumnSpecs,
        order: const ['name', 'notes', 'type', 'status', 'size', 'time'],
      );

  TableColumnSpec? _def(String id) {
    for (final s in specs) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 某列当前宽度。
  double widthOf(String id) {
    final def = _def(id)?.defaultWidth ?? 120;
    return widths[id]?.clamp(_kColWidthMin, _kColWidthMax) ?? def;
  }

  /// 某列是否可见。
  bool isVisible(String id) => order.contains(id);

  /// 显示某列（隐藏列重新显示时追加到末尾）。
  void show(String id) {
    if (!order.contains(id)) order.add(id);
  }

  /// 隐藏某列（从显示顺序移除，宽度保留）。
  void hide(String id) => order.remove(id);

  /// 把 [from] 列移到 [to] 列当前的位置。
  void move(String from, String to) {
    if (from == to) return;
    final fromIdx = order.indexOf(from);
    if (fromIdx == -1) return;
    order.removeAt(fromIdx);
    final toIdx = order.indexOf(to);
    order.insert(toIdx < 0 ? order.length : toIdx, from);
  }

  /// 调整列宽（delta 增量，自动 clamp）。
  void resize(String id, double delta) {
    final cur = widthOf(id);
    widths[id] = (cur + delta).clamp(_kColWidthMin, _kColWidthMax);
  }

  /// 深拷贝（隔离各调用方的就地修改）。
  ColumnLayout clone() => ColumnLayout(
    specs: specs,
    order: List<String>.from(order),
    widths: Map<String, double>.from(widths),
  );

  // ── 序列化（存 config.json `mod_table_columns` / `cloud_table_columns` 等） ──

  Map<String, dynamic> toJson() => {
    'order': [for (final id in order) id],
    'widths': {for (final e in widths.entries) e.key: e.value},
  };

  /// 从 config.json 反序列化；旧配置缺列时按 specs 声明序补到末尾。
  static ColumnLayout fromJson(
    Object? json, {
    required List<TableColumnSpec> specs,
  }) {
    final cfg = ColumnLayout(specs: specs);
    if (json is Map<String, dynamic>) {
      final orderRaw = json['order'];
      if (orderRaw is List) {
        final parsed = <String>[];
        for (final v in orderRaw) {
          if (v is String && _hasId(specs, v) && !parsed.contains(v)) {
            parsed.add(v);
          }
        }
        // 序列化文件里可能漏掉旧列：把缺失的列按 specs 序补到末尾。
        for (final s in specs) {
          if (!parsed.contains(s.id)) parsed.add(s.id);
        }
        cfg.order = parsed;
      }
      final widthsRaw = json['widths'];
      if (widthsRaw is Map) {
        widthsRaw.forEach((k, v) {
          if (v is num) cfg.widths['$k'] = v.toDouble();
        });
      }
    }
    return cfg;
  }

  static bool _hasId(List<TableColumnSpec> specs, String id) =>
      specs.any((s) => s.id == id);
}

// =====================================================================
//  主界面本地 mod 列表的列定义
// =====================================================================

/// 本地 mod 列表的可配置列。
const List<TableColumnSpec> localColumnSpecs = [
  TableColumnSpec('name', '名称', 200),
  TableColumnSpec('notes', '备注', 160),
  TableColumnSpec('type', '类型', 90),
  TableColumnSpec('status', '状态', 100),
  TableColumnSpec('tags', '标签', 150),
  TableColumnSpec('size', '大小', 90),
  TableColumnSpec('time', '时间', 140),
  TableColumnSpec('sha256', 'SHA-256', 280),
  TableColumnSpec('origin', '来源', 80),
];

// =====================================================================
//  表头（列配置交互区）
// =====================================================================

/// 表头高度（逻辑 px）—— 与数据行高度保持一致，保证文本中心对齐。
const double kTableHeaderHeight = 30;

/// 可配置列表头 —— 支持右键显隐、拖拽排序、拖宽。
class ModTableHeader extends StatelessWidget {
  final List<TableColumnSpec> specs;
  final ColumnLayout layout;
  final ValueChanged<ColumnLayout> onLayoutChanged;

  /// 列配置「提交」回调（写盘时机：拖宽松手 / 菜单操作后）。
  /// 高频的拖宽中间过程只走 [onLayoutChanged]（实时 UI），不写盘。
  final VoidCallback? onLayoutCommit;

  /// 当前排序列 id + 方向（null = 默认顺序，同时不显示排序箭头）。
  final String? sortColumnId;
  final bool sortAscending;

  /// 点击列头排序回调（null = 该面板不支持点击排序，仅保留拖拽排序）。
  final ValueChanged<String>? onSort;

  /// 表头「主勾选框」状态（仅本地 mod 列表接入；云上/服务器为 null 不显示）。
  /// checked = 当前显示的 mod 全部启用；partial = 部分启用；点击切换全选/取消。
  final ({bool checked, bool partial, VoidCallback onTap})? masterSelect;

  const ModTableHeader({
    super.key,
    required this.specs,
    required this.layout,
    required this.onLayoutChanged,
    this.onLayoutCommit,
    this.sortColumnId,
    this.sortAscending = true,
    this.onSort,
    this.masterSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    // 横向 8px 与各列表的 ListView.padding 对齐，保证表头 # 列与行 # 列左对齐。
    final ms = masterSelect;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        height: kTableHeaderHeight,
        decoration: BoxDecoration(
          color: colors.bgPanel.withValues(alpha: 0.85),
        ),
        child: Flex(
          direction: Axis.horizontal,
          clipBehavior: Clip.hardEdge,
          children: [
            // ── 固定左侧：顺序 + 启用（主勾选框在行勾选框同列上方） ──
            SizedBox(
              width: 28,
              child: _HeaderLabel(text: '#', align: TextAlign.center),
            ),
            const SizedBox(width: 8),
            if (ms != null)
              _MasterCheckbox(
                checked: ms.checked,
                partial: ms.partial,
                onTap: ms.onTap,
              )
            else
              const SizedBox(width: 18),
            const SizedBox(width: 12),

            // ── 可配置数据列 ──
            for (final id in layout.order)
              _ColumnHeaderCell(
                key: ValueKey('hdr-$id'),
                spec: _specOf(specs, id),
                width: layout.widthOf(id),
                layout: layout,
                onLayoutChanged: onLayoutChanged,
                onLayoutCommit: onLayoutCommit,
                sortColumnId: sortColumnId,
                sortAscending: sortAscending,
                onSort: onSort,
              ),

            // ── 固定右侧：操作区占位 ──
            const Spacer(),
            const SizedBox(width: 8),
            const SizedBox(width: 8),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  static TableColumnSpec _specOf(List<TableColumnSpec> specs, String id) {
    for (final s in specs) {
      if (s.id == id) return s;
    }
    return const TableColumnSpec('', '?', 100);
  }
}

/// 单个可配置列头：点击排序 + 右键菜单（显隐）+ 拖拽排序 + 右缘拖宽。
class _ColumnHeaderCell extends StatefulWidget {
  final TableColumnSpec spec;
  final double width;
  final ColumnLayout layout;
  final ValueChanged<ColumnLayout> onLayoutChanged;
  final VoidCallback? onLayoutCommit;

  /// 当前排序列 id + 方向（null = 不显示排序箭头、点击不排序）。
  final String? sortColumnId;
  final bool sortAscending;

  /// 点击排序回调（null = 该面板不接入点击排序）。
  final ValueChanged<String>? onSort;

  const _ColumnHeaderCell({
    super.key,
    required this.spec,
    required this.width,
    required this.layout,
    required this.onLayoutChanged,
    this.onLayoutCommit,
    this.sortColumnId,
    this.sortAscending = true,
    this.onSort,
  });

  @override
  State<_ColumnHeaderCell> createState() => _ColumnHeaderCellState();
}

class _ColumnHeaderCellState extends State<_ColumnHeaderCell> {
  bool _hovered = false;

  /// 鼠标是否悬停在右缘拖宽热区（高亮分隔线提示可调大小）。
  bool _resizeHovered = false;

  void _resize(double delta) {
    final layout = widget.layout;
    layout.resize(widget.spec.id, delta);
    widget.onLayoutChanged(layout);
  }

  void _reorder(String from) {
    final layout = widget.layout;
    layout.move(from, widget.spec.id);
    widget.onLayoutChanged(layout);
  }

  void _showMenu(Offset globalPos) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ColumnConfigMenu(
        anchorGlobal: globalPos,
        specs: widget.layout.specs,
        layout: widget.layout,
        onLayoutChanged: widget.onLayoutChanged,
        onLayoutCommit: widget.onLayoutCommit,
        onDismiss: () {
          try {
            entry.remove();
          } catch (_) {}
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final isSorted = widget.sortColumnId == widget.spec.id;
    // 表头标题与数据单元格同构（Padding h8 + Align 纯文本），保证与列内容
    // 像素级对齐；排序箭头 / 拖拽图标均以 Positioned 浮显、不参与文本布局，
    // 避免 center/right 列表头标题被图标挤偏（旧实现 Row 整体对齐 → 偏 7.5~15px）。
    final header = Container(
      width: widget.width,
      height: kTableHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.transparent,
      child: Stack(
        children: [
          // 标题本体：纯文本按 spec.align 放置（与 buildConfigurableRow 数据列完全一致）。
          Positioned.fill(
            child: Align(
              alignment: _alignFor(widget.spec.align),
              child: Text(
                widget.spec.title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: isSorted
                      ? colors.accent
                      : _hovered
                      ? colors.textPrimary
                      : colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
          // 排序指示箭头：当前排序列常显（升序 ↑ / 降序 ↓；再点一次恢复默认）。
          if (isSorted)
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              child: Center(
                child: Icon(
                  widget.sortAscending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 12,
                  color: colors.accent,
                ),
              ),
            ),
          // 拖拽提示图标：hover 浮显，不占布局 → 不影响标题几何中心。
          if (_hovered && !_resizeHovered)
            Positioned(
              right: 2,
              top: 0,
              bottom: 0,
              child: Center(
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 12,
                  color: colors.accent.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );

    return MouseRegion(
      cursor: widget.onSort == null
          ? SystemMouseCursors.grab
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != widget.spec.id,
        onAcceptWithDetails: (d) => _reorder(d.data),
        builder: (ctx, candidates, rejected) {
          final isTarget = candidates.isNotEmpty;
          return Stack(
            children: [
              // 点击 = 按该列排序；右键 = 显隐菜单；左键按住拖动 = 调整列顺序。
              // （拖宽热区叠在上层，点分隔线不会误触发排序）
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSort == null
                    ? null
                    : () => widget.onSort!(widget.spec.id),
                onSecondaryTapDown: (d) => _showMenu(d.globalPosition),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  color: isTarget
                      ? colors.accent.withValues(alpha: 0.18)
                      : Colors.transparent,
                  child: Draggable<String>(
                    data: widget.spec.id,
                    // 反馈跟随「抓住时的鼠标位置」而非控件原点（默认 childDragAnchorStrategy
                    // 会把反馈锚在原 child 左上角——抓列头中部时拖块会偏离光标）。
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: Material(
                      color: Colors.transparent,
                      child: Container(
                        height: kTableHeaderHeight - 2,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: colors.bgHover,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: colors.borderAccent),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.drag_indicator_rounded,
                              size: 12,
                              color: colors.accent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              widget.spec.title,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(opacity: 0.35, child: header),
                    child: header,
                  ),
                ),
              ),
              // 右缘拖宽热区 + 常显分隔线：让用户一眼看到「哪里可以调宽度」。
              // 平时 1px 分隔线；悬停时金色高亮 + 居中小手柄，光标变双向箭头。
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  onEnter: (_) => setState(() => _resizeHovered = true),
                  onExit: (_) => setState(() => _resizeHovered = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => _resize(d.delta.dx),
                    onHorizontalDragEnd: (_) => widget.onLayoutCommit?.call(),
                    child: SizedBox(
                      width: 8,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _resizeHovered
                              ? colors.accent.withValues(alpha: 0.15)
                              : Colors.transparent,
                          border: Border(
                            right: BorderSide(
                              color: _resizeHovered
                                  ? colors.accent
                                  : colors.border,
                              width: _resizeHovered ? 2.0 : 1.0,
                            ),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: _resizeHovered
                            ? Container(
                                width: 2,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: colors.accent,
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 表头「主勾选框」：勾选 = 当前列表里显示的 mod 全部启用；再点 = 全部禁用。
/// 部分启用时显示半选（减号）态。三态视觉与行内 [_RowCheckbox] 一致。
class _MasterCheckbox extends StatelessWidget {
  final bool checked;
  final bool partial;
  final VoidCallback onTap;

  const _MasterCheckbox({
    required this.checked,
    required this.partial,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: checked ? colors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: checked || partial ? colors.accent : colors.textDim,
              width: 1.5,
            ),
          ),
          child: checked
              ? Icon(Icons.check_rounded, size: 12, color: colors.bgDark)
              : partial
              ? Icon(Icons.remove_rounded, size: 12, color: colors.accent)
              : null,
        ),
      ),
    );
  }
}

/// 表头小标签。
class _HeaderLabel extends StatelessWidget {
  final String text;
  final TextAlign? align;
  const _HeaderLabel({required this.text, this.align});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Text(
      text,
      textAlign: align,
      style: TextStyle(
        color: colors.textDim,
        fontSize: 11,
        decoration: TextDecoration.none,
      ),
    );
  }
}

// =====================================================================
//  列配置右键菜单
// =====================================================================

/// 右键弹出的列显隐菜单 —— 自持列序副本，勾选态实时刷新，点外部关闭。
class _ColumnConfigMenu extends StatefulWidget {
  final Offset anchorGlobal;
  final List<TableColumnSpec> specs;
  final ColumnLayout layout;
  final ValueChanged<ColumnLayout> onLayoutChanged;
  final VoidCallback? onLayoutCommit;
  final VoidCallback onDismiss;

  const _ColumnConfigMenu({
    required this.anchorGlobal,
    required this.specs,
    required this.layout,
    required this.onLayoutChanged,
    this.onLayoutCommit,
    required this.onDismiss,
  });

  @override
  State<_ColumnConfigMenu> createState() => _ColumnConfigMenuState();
}

class _ColumnConfigMenuState extends State<_ColumnConfigMenu> {
  late List<String> _order;

  @override
  void initState() {
    super.initState();
    _order = List<String>.from(widget.layout.order);
  }

  void _toggle(String id) {
    setState(() {
      if (_order.contains(id)) {
        _order.remove(id);
      } else {
        _order.add(id);
      }
    });
    final layout = widget.layout.clone()..order = List<String>.from(_order);
    widget.onLayoutChanged(layout);
    // 菜单操作是低频动作，立即持久化。
    widget.onLayoutCommit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onDismiss,
      child: Stack(
        children: [
          Positioned.fill(child: Container(color: Colors.transparent)),
          Positioned(
            left: widget.anchorGlobal.dx,
            top: widget.anchorGlobal.dy,
            child: Container(
              constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
              decoration: BoxDecoration(
                color: colors.bgCard,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colors.borderStrong),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowSm,
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
                    child: Row(
                      children: [
                        Icon(
                          Icons.view_column_rounded,
                          size: 13,
                          color: colors.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '显示列',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(height: 1, color: colors.border),
                  // 固定按 specs 声明序列出全部列
                  for (final spec in widget.specs)
                    _ColumnMenuOption(
                      title: spec.title,
                      checked: _order.contains(spec.id),
                      onTap: () => _toggle(spec.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行列菜单项（checkbox + 列名）。
class _ColumnMenuOption extends StatelessWidget {
  final String title;
  final bool checked;
  final VoidCallback onTap;

  const _ColumnMenuOption({
    required this.title,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          children: [
            Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 15,
              color: checked ? colors.accent : colors.textDim,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: checked ? colors.textPrimary : colors.textDim,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  通用数据行结构
// =====================================================================

/// 组装一行：固定左列 + 可配置数据列 + 固定右列。
///
/// 所有数据列统一包 `Padding(horizontal: 8)` —— 与列头 [ModTableHeader]
/// 的内边距一致，修复「列头文字与数据文字水平错位」的坐标偏移；
/// 行高默认与表头等高（[kTableHeaderHeight]），文本中心垂直对齐。
Widget buildConfigurableRow({
  required BuildContext context,
  required ColumnLayout layout,
  required bool enabled,
  required List<Widget> fixedLeft,
  required List<Widget> fixedRight,
  required Widget Function(TableColumnSpec spec) cellBuilder,
  double height = kTableHeaderHeight,
}) {
  final colors = ScumColors.of(context);
  return Container(
    height: height,
    decoration: BoxDecoration(
      color: enabled ? colors.bgCard : colors.bgCard.withValues(alpha: 0.4),
      border: Border(
        left: BorderSide(
          color: enabled ? colors.accent : colors.border,
          width: enabled
              ? ScumTheme.cardLeftBorderEnabled
              : ScumTheme.cardLeftBorderDisabled,
        ),
        bottom: BorderSide(color: colors.border, width: 0.5),
      ),
    ),
    child: Row(
      children: [
        ...fixedLeft,
        // ── 可配置数据列 ──
        // 固定像素宽 = 与表头同列宽（layout.widthOf(id)，同一列头与列体
        // 左右列线严格一致；剩余空间由 Spacer 吸收，与表头右侧结构同构，
        // 拖宽后两侧同步、列线不漂移；溢出由 clipBehavior 裁剪兜底。 ──
        Expanded(
          child: Flex(
            direction: Axis.horizontal,
            clipBehavior: Clip.hardEdge,
            children: [
              for (final id in layout.order)
                SizedBox(
                  width: layout.widthOf(id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Align(
                      alignment: _alignFor(_specOf(layout, id).align),
                      child: cellBuilder(_specOf(layout, id)),
                    ),
                  ),
                ),
              const Spacer(),
            ],
          ),
        ),
        ...fixedRight,
      ],
    ),
  );
}

TableColumnSpec _specOf(ColumnLayout layout, String id) {
  for (final s in layout.specs) {
    if (s.id == id) return s;
  }
  return const TableColumnSpec('', '?', 100);
}

// =====================================================================
//  主界面本地 mod 表格行
// =====================================================================

/// 单行数据 —— 按列配置渲染各列，固定高度单行。
class ModTableRow extends StatefulWidget {
  final ModEntry mod;
  final ColumnLayout layout;
  final bool fromRemote;
  final ModService? svc;

  /// 当前行在列表中的索引（Reorderable 用）。
  final int index;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;
  final VoidCallback? onOpenSettings;

  /// 点击状态列「冲突」徽章时打开冲突详情面板（null = 不响应点击）。
  /// 回调携带该 mod 的 id，面板据此只显示与之冲突的路径与 mod。
  final ValueChanged<String>? onShowConflicts;

  const ModTableRow({
    super.key,
    required this.mod,
    required this.layout,
    required this.fromRemote,
    required this.index,
    required this.onToggle,
    this.onDelete,
    this.onOpenSettings,
    this.onShowConflicts,
    this.svc,
  });

  @override
  State<ModTableRow> createState() => _ModTableRowState();
}

class _ModTableRowState extends State<ModTableRow> {
  /// 若 SHA-256 列可见且该 mod 尚未计算 → 触发懒计算。
  /// 放在 build 里调用：列配置任意时刻切换可见性，下一次 build 即生效。
  void _maybeComputeSha() {
    final svc = widget.svc;
    final mod = widget.mod;
    if (svc == null) return;
    // SHA-256 列与「状态」列都需要哈希做云上对比 → 任一列可见即懒计算。
    if (!widget.layout.isVisible('sha256') &&
        !widget.layout.isVisible('status')) {
      return;
    }
    if (mod.isUe4ssMod || mod.sha256.isNotEmpty) return;
    svc.ensureSha256(mod).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 「状态」列可见 → 确保冲突扫描已就绪（冲突提示并入状态列；懒加载：扫过即忽略）。
  void _maybeEnsureConflictScan() {
    if (!widget.layout.isVisible('status')) return;
    if (widget.mod.isUe4ssMod) return;
    // ignore: discarded_futures
    ConflictService.shared.ensureReady();
  }

  /// 「状态」列可见 → 云端目录陈旧（>5 分钟）时后台静默刷新一次：
  /// 云端有新版时模组管理自动显示「有更新」（无需手动刷新云上页面）。
  void _maybeRefreshCloudCatalog() {
    if (!widget.layout.isVisible('status')) return;
    final svc = widget.svc;
    if (svc == null) return;
    svc.ensureCloudCatalogFresh();
  }

  @override
  Widget build(BuildContext context) {
    _maybeComputeSha();
    _maybeEnsureConflictScan();
    _maybeRefreshCloudCatalog();
    final colors = ScumColors.of(context);
    final mod = widget.mod;
    final svc = widget.svc;

    // 更新下载状态（云端对应条目 + 下载中）：供整行背景进度与状态徽章复用。
    final updatingCloud = svc?.cloudCounterpartFor(mod);
    final isUpdating =
        updatingCloud != null &&
        (svc?.cloudDownloadingIds.contains(updatingCloud.id) ?? false);
    final updateProgress = isUpdating
        ? (svc?.cloudDownloadProgress[updatingCloud!.id] ?? 0)
        : null;

    // 整行作为拖拽重排手柄（与旧 ModCard 行为一致，筛选态由外层禁用）。
    return ReorderableDragStartListener(
      index: widget.index,
      child: Stack(
        children: [
          buildConfigurableRow(
            context: context,
            layout: widget.layout,
            enabled: mod.enabled,
            fixedLeft: [
              SizedBox(
                width: 28,
                child: Text(
                  '${mod.loadOrder + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: mod.enabled
                        ? colors.textDim
                        : colors.textDim.withValues(alpha: 0.4),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RowCheckbox(enabled: mod.enabled, onTap: widget.onToggle),
              const SizedBox(width: 12),
            ],
            fixedRight: [
              if (widget.onOpenSettings != null) ...[
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.tune_rounded,
                  tooltip: '编辑标签/备注',
                  color: colors.textSecondary,
                  hoverColor: colors.accent,
                  onTap: widget.onOpenSettings!,
                ),
              ],
              if (widget.onDelete != null) ...[
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: '删除',
                  color: colors.textDim,
                  hoverColor: colors.danger,
                  onTap: widget.onDelete!,
                ),
              ],
            ],
            cellBuilder: (spec) => _cellFor(context, spec.id, mod),
          ),
          // 更新下载进度：整行背景从左到右按进度染色（与云上 mod 行一致）。
          if (isUpdating)
            Positioned.fill(
              child: IgnorePointer(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: updateProgress ?? 0,
                  child: ColoredBox(
                    color: colors.accent.withValues(alpha: 0.13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 单列单元格内容（水平对齐由 buildConfigurableRow 按 spec.align 统一处理）。
  Widget _cellFor(BuildContext context, String colId, ModEntry mod) {
    final colors = ScumColors.of(context);
    final style = TextStyle(
      color: mod.enabled ? colors.textPrimary : colors.textDim,
      fontSize: 12,
      decoration: TextDecoration.none,
    );
    switch (colId) {
      case 'name':
        return Text(
          mod.name,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: style.copyWith(
            fontWeight: FontWeight.w600,
            color: mod.enabled ? colors.textPrimary : colors.textDim,
          ),
        );
      case 'status':
        // 状态列按实况并排多枚徽章（不再只显示优先级最高的一枚）：
        // 冲突（红，最紧急）→ 云端「有更新」（金）/「最新」（绿）。
        // 多态可共存（如既冲突又有更新则两枚并排）。文案随列宽自适应
        // （完整 → 紧凑 → 符号），放不下的省略，各徽章 Tooltip 恒给全量。
        final colW = widget.layout.widthOf('status');
        final cs = ConflictService.shared;
        final rep = cs.report;
        final cni = (mod.isUe4ssMod || rep == null) ? 0 : rep.countFor(mod.id);
        final svc = widget.svc;
        final cloud = svc?.cloudCounterpartFor(mod);
        final hasUpdate = cloud != null && (svc?.hasCloudUpdate(mod) ?? false);

        final items =
            <
              ({
                String full,
                String compact,
                String icon,
                Color color,
                String tooltip,
                VoidCallback? onTap,
              })
            >[];
        if (cni > 0) {
          final otherCount =
              rep!.conflictedModIds.length -
              (rep.conflictedModIds.contains(mod.id) ? 1 : 0);
          items.add((
            full: cni == 1 ? '冲突' : '冲突×$cni',
            compact: '冲突',
            icon: '⚠',
            color: colors.dangerLight,
            tooltip:
                '与 $otherCount 个 mod 存在 ${cni == 1 ? '1 处' : '$cni 处'}'
                '资源冲突，点击查看详情',
            onTap: widget.onShowConflicts == null
                ? null
                : () => widget.onShowConflicts!(mod.id),
          ));
        }
        if (cloud != null) {
          final isUpdating =
              svc?.cloudDownloadingIds.contains(cloud.id) ?? false;
          items.add(
            isUpdating
                ? (
                    full: '更新中',
                    compact: '更新中',
                    icon: '⏳',
                    color: colors.accent,
                    tooltip: '正在下载更新…',
                    onTap: null,
                  )
                : hasUpdate
                ? (
                    full: '有更新',
                    compact: '更新',
                    icon: '↑',
                    color: colors.accent,
                    tooltip: '云端存在新版本，点击自动下载更新',
                    onTap: () {
                      // 点击「有更新」→ 直接下载更新（无需去云上页面）。
                      final s = widget.svc;
                      if (s == null) return;
                      // ignore: discarded_futures
                      s.downloadCloudMod(cloud);
                    },
                  )
                : (
                    full: '最新',
                    compact: '最新',
                    icon: '✓',
                    color: colors.success,
                    tooltip: '与云端一致，已是最新',
                    onTap: null,
                  ),
          );
        }
        if (items.isEmpty) {
          return StatusBadge(label: '—', color: colors.textDim);
        }
        // 文案模式：完整（宽列）→ 紧凑（中列）→ 符号（窄列）。
        final useFull = colW >= 110;
        final useCompact = colW >= 78;
        final labels = [
          for (final it in items)
            useFull ? it.full : (useCompact ? it.compact : it.icon),
        ];
        // 逐枚放入，超出可用宽度即截断（Tooltip 兜底全量）。
        double badgeW(String label) => label.runes.length * 10 + 12;
        const gap = 4.0;
        final available = colW - 16; // 列内两侧 Padding(h8) 占用
        final badgeRow = <Widget>[];
        var used = 0.0;
        for (var i = 0; i < items.length; i++) {
          final bw = badgeW(labels[i]);
          // 第一枚必放（宁超裁切）；后续放不下才省略。
          if (badgeRow.isNotEmpty && used + gap + bw > available) break;
          badgeRow.add(
            _statusBadge(
              labels[i],
              items[i].color,
              tooltip: items[i].tooltip,
              onTap: items[i].onTap,
            ),
          );
          used += bw + (badgeRow.length > 1 ? gap : 0);
        }
        return Row(mainAxisSize: MainAxisSize.min, children: badgeRow);
      case 'notes':
        return Text(
          mod.notes.isEmpty ? '—' : mod.notes,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: style.copyWith(
            color: mod.enabled ? colors.textSecondary : colors.textDim,
            fontSize: 11,
          ),
        );
      case 'type':
        return TypeBadge(type: mod.type);
      case 'tags':
        return ScumTagsRow(
          tags: mod.tags,
          colors: colors,
          enabled: mod.enabled,
        );
      case 'size':
        return Text(
          mod.fileSizeFormatted,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: style.copyWith(color: colors.textSecondary, fontSize: 11),
        );
      case 'time':
        return Text(
          _fmtTime(mod.lastModified),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: style.copyWith(
            color: colors.textDim,
            fontSize: 11,
            fontFamily: 'Consolas',
          ),
        );
      case 'sha256':
        final sha = mod.sha256;
        return sha.isEmpty
            ? Text(
                mod.isUe4ssMod ? '—' : '计算中…',
                style: style.copyWith(color: colors.textDim, fontSize: 11),
              )
            : Tooltip(
                message: sha,
                child: Text(
                  '${sha.length < 16 ? sha : sha.substring(0, 16)}…',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: style.copyWith(
                    color: colors.textDim,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                  ),
                ),
              );
      case 'origin':
        return widget.fromRemote
            ? StatusBadge(label: '云上', color: colors.accent)
            : StatusBadge(label: '本地', color: colors.textDim);
      default:
        return const SizedBox.shrink();
    }
  }

  /// 状态徽章：需要 Tooltip / 可点击（冲突看详情）时包裹渲染。
  Widget _statusBadge(
    String label,
    Color color, {
    String? tooltip,
    VoidCallback? onTap,
  }) {
    final badge = StatusBadge(label: label, color: color);
    if (tooltip == null && onTap == null) return badge;
    return Tooltip(
      message: tooltip ?? label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: badge,
      ),
    );
  }

  static String _fmtTime(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

/// 自绘启用勾选框（主列表与本地镜像共用，模组管理同款）。
class RowCheckbox extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const RowCheckbox({super.key, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: enabled ? colors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: enabled ? colors.accent : colors.textDim,
            width: 1.5,
          ),
        ),
        child: enabled
            ? Icon(Icons.check_rounded, size: 12, color: colors.bgDark)
            : null,
      ),
    );
  }
}
