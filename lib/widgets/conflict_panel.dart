/// 冲突扫描详情面板 —— 列出所有冲突资源路径与涉及的 mod。
///
/// 行为（与 ModSettingsPopup 一脉相承）：
/// - 点工具栏「冲突」按钮 / 行内红色「冲突」徽章 → 屏幕中央弹出
/// - 鼠标离开悬浮窗 → 1 秒后自动关闭
/// - 面板内容实时监听 [ConflictService.shared]，扫描状态变化自动刷新
///
/// 单例 overlay：同一时刻只能打开一个。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/mod_entry.dart';
import '../models/pak_conflict.dart';
import '../services/conflict_service.dart';
import '../services/merge_service.dart';
import '../services/mod_service.dart';
import '../theme/scum_colors.dart';

/// 冲突面板的可插拔数据源 —— 让**同一个面板**既能服务主列表模组管理
/// （[ConflictService.shared] 驱动），也能服务本地镜像
/// （[ServerSftpService.scanMirrorConflicts] 结果）。
///
/// 字段用「每次 build 求值」的函数而非快照，配合 [listenable]（面板监听它
/// 重建）在扫描状态变化时自动刷新 —— 与主列表模式监听 [ConflictService]
/// 的行为完全一致。镜像模式传 [ServerSftpService] 为 listenable。
class ConflictPanelData {
  /// 面板标题（如「冲突详情 · 某文件」）。
  final String title;

  /// 面板监听的可变对象（主列表 = ConflictService；镜像 = ServerSftpService）。
  final Listenable listenable;

  /// 当前冲突组（path → 涉及 mod id 列表），每次 build 取最新。
  final List<PakConflictGroup> Function() groups;

  /// 参与扫描的 PAK 数量。
  final int Function() scannedCount;

  /// 是否正在扫描。
  final bool Function() scanning;

  /// repak 不可用。
  final bool Function() unavailable;

  /// 「重新扫描」按钮回调。
  final Future<void> Function() onRescan;

  /// 参与者显示解析：id → (显示名, 序号标签)。
  /// 主列表 = mod 名称 + 加载序号；镜像 = 文件名（id 即文件名），序号 null。
  final (String, String?)? Function(String id) participantFor;

  /// 底部说明文案（null = 默认「参与扫描：N 个已启用 PAK」）。
  final String? footerNote;

  const ConflictPanelData({
    required this.title,
    required this.listenable,
    required this.groups,
    required this.scannedCount,
    required this.scanning,
    required this.unavailable,
    required this.onRescan,
    required this.participantFor,
    this.footerNote,
  });
}

class ConflictPanel {
  ConflictPanel._();

  static OverlayEntry? _entry;
  static Timer? _closeTimer;
  static bool _showing = false;

  /// 显示冲突详情面板。
  ///
  /// [focusModId] 非空 = 聚焦某 mod（行内红色「冲突」徽章触发）：只列出
  /// 与该 mod 相关的冲突路径（其参与的路径 = 与他纠缠的 mod），而非全局
  /// 全部冲突列表；null = 工具栏按钮触发，显示全部冲突。
  /// [conflictsOnly] 当前「只看冲突」筛选是否激活（面板按钮显示对应状态）。
  /// [onToggleFilter] 点击「只看冲突 / 显示全部」时回调（由 HomeScreen 翻转筛选）。
  /// [data] 非空 = 用可插拔数据源渲染（本地镜像复用同一面板）；
  /// null = 走 [ConflictService.shared]（主列表模组管理）。
  static void show(
    BuildContext context, {
    String? focusModId,
    required bool conflictsOnly,
    required VoidCallback onToggleFilter,
    ConflictPanelData? data,
  }) {
    if (_showing) {
      _closeTimer?.cancel();
      try {
        _entry?.remove();
      } catch (_) {}
      _showing = false;
    }

    _entry = OverlayEntry(
      builder: (context) => _ConflictPanelBody(
        focusModId: focusModId,
        conflictsOnly: conflictsOnly,
        onToggleFilter: onToggleFilter,
        data: data,
        onHoverChange: (hovering) {
          if (hovering) {
            _closeTimer?.cancel();
          } else {
            _scheduleAutoClose();
          }
        },
        onClose: dismiss,
      ),
    );
    _showing = true;
    Overlay.of(context).insert(_entry!);
  }

  /// 鼠标离开面板 1 秒后自动关闭。
  static void _scheduleAutoClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(seconds: 1), dismiss);
  }

  /// 关闭面板。
  static void dismiss() {
    _closeTimer?.cancel();
    try {
      _entry?.remove();
    } catch (_) {}
    _showing = false;
  }
}

/// 面板本体（私有 widget）。
class _ConflictPanelBody extends StatefulWidget {
  /// 聚焦 mod id（非空 = 只显示与该 mod 相关的冲突路径）。
  final String? focusModId;
  final bool conflictsOnly;
  final VoidCallback onToggleFilter;

  /// 可插拔数据源（非空 = 本地镜像等自定义来源；null = ConflictService 主列表）。
  final ConflictPanelData? data;

  final ValueChanged<bool> onHoverChange;
  final VoidCallback onClose;

  const _ConflictPanelBody({
    required this.focusModId,
    required this.conflictsOnly,
    required this.onToggleFilter,
    this.data,
    required this.onHoverChange,
    required this.onClose,
  });

  @override
  State<_ConflictPanelBody> createState() => _ConflictPanelBodyState();
}

class _ConflictPanelBodyState extends State<_ConflictPanelBody> {
  /// 当前「只看冲突 mod」筛选是否激活（面板内自持，点击立即翻转，
  /// 并通过 [widget.onToggleFilter] 同步 HomeScreen 列表 —— 无需关面板即可生效）。
  late bool _conflictsOnly;

  @override
  void initState() {
    super.initState();
    _conflictsOnly = widget.conflictsOnly;
    // 打开面板**不**自动重新扫描：冲突数据由各数据源自行维护常驻
    // （主列表 ConflictService 随 mod 变化 400ms 防抖自动重扫；
    //  镜像进入模式时已自动扫描并落盘 mirror_meta.json）。
    // 需要刷新时点面板内「重新扫描」按钮即可。
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final cs = ConflictService.shared;
    final data = widget.data;
    final svc = cs.attachedSvc;
    final focusName = _focusName(svc, widget.focusModId) ?? widget.focusModId;

    return Stack(
      children: [
        // 全屏透明点击层，点空白 → 进入自动关闭计时（与 ModSettingsPopup 一致）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: ConflictPanel._scheduleAutoClose,
            child: Container(color: colors.overlay),
          ),
        ),
        // 面板本体（屏幕中央）。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
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
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Container(
                    width: 560,
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
                    child: ListenableBuilder(
                      // 主列表模式同时监听冲突扫描与冲突合并两个服务，
                      // 合并进度 / 完成 / 失败状态实时刷新底部说明。
                      listenable: Listenable.merge([
                        data?.listenable ?? cs,
                        MergeService.shared,
                      ]),
                      builder: (context, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── 标题行 + 实时状态 ──
                          Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                                color: _headerColor(colors, data, cs),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                data?.title ??
                                    (focusName != null
                                        ? '冲突详情 · 「$focusName」'
                                        : '模组冲突扫描'),
                                style: TextStyle(
                                  color: colors.accent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                              const Spacer(),
                              _StateChip(colors: colors, data: data, cs: cs),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Container(height: 1, color: colors.border),
                          const SizedBox(height: 8),

                          // ── 主体：不可用 / 扫描中 / 报告 ──
                          Flexible(child: _buildBody(colors, data, cs, svc)),

                          const SizedBox(height: 8),
                          Container(height: 1, color: colors.border),
                          const SizedBox(height: 8),

                          // ── 底部说明 + 操作 ──
                          _buildFooter(colors, data, cs, svc),
                        ],
                      ),
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

  /// 聚焦 mod id → 显示名（null = 全局模式 / 未找到）。
  String? _focusName(ModService? svc, String? focusModId) {
    if (focusModId == null || svc == null) return null;
    for (final m in svc.mods) {
      if (m.id == focusModId) return m.name;
    }
    return null;
  }

  Color _headerColor(
    ScumColors colors,
    ConflictPanelData? data,
    ConflictService cs,
  ) {
    if (data != null) {
      if (data.scanning() || data.unavailable()) return colors.textDim;
      return data.groups().isEmpty ? colors.success : colors.dangerLight;
    }
    if (cs.scanning) return colors.textDim;
    if (cs.unavailable) return colors.textDim;
    final rep = cs.report;
    if (rep == null || rep.groups.isEmpty) return colors.success;
    return colors.dangerLight;
  }

  Widget _buildBody(
    ScumColors colors,
    ConflictPanelData? data,
    ConflictService cs,
    ModService? svc,
  ) {
    // 数据源分流：自定义来源（镜像）与 ConflictService（主列表）取同样的
    // 不可用 / 扫描中 / 冲突组语义，只是取值来源不同。
    final unavailable = data != null ? data.unavailable() : cs.unavailable;
    if (unavailable) {
      return _HintBox(
        colors: colors,
        icon: Icons.error_outline_rounded,
        color: colors.textDim,
        message:
            '未找到 repak.exe，无法读取 PAK 内部清单。\n'
            '可从 GitHub repak 发布页下载，放入 exe 目录，\n'
            '或在 config.json 中设置 repak_path。',
      );
    }
    final scanning = data != null ? data.scanning() : cs.scanning;
    if (scanning) {
      return _HintBox(
        colors: colors,
        icon: Icons.sync_rounded,
        color: colors.textDim,
        message: '正在读取已启用 PAK 的内部资源清单…',
      );
    }
    final allGroups = data != null
        ? data.groups()
        : (cs.report?.groups ?? const []);
    // 聚焦模式（主列表）：只列出与该 mod 相关的冲突路径。
    final focusModId = widget.focusModId;
    final groups = data == null && focusModId != null && cs.report != null
        ? cs.report!.groupsFor(focusModId)
        : allGroups;
    if (groups.isEmpty) {
      final focusName = _focusName(svc, focusModId) ?? focusModId;
      return _HintBox(
        colors: colors,
        icon: Icons.check_circle_outline_rounded,
        color: colors.success,
        message: focusName != null
            ? '「$focusName」当前无冲突：'
                  '该 mod 参与的资源路径互不重叠。'
            : '未检测到冲突：已启用 PAK 的资源路径互不重叠。',
      );
    }
    return _ConflictList(
      colors: colors,
      groups: groups,
      highlightModId: focusModId,
      participantFor: data != null
          ? data.participantFor
          : _modParticipantFor(svc),
    );
  }

  /// 主列表模式的参与者解析：mod id → (名称, 加载序号标签)。
  (String, String?)? Function(String id) _modParticipantFor(ModService? svc) {
    final byId = {for (final m in svc?.mods ?? const <ModEntry>[]) m.id: m};
    return (id) {
      final m = byId[id];
      return m == null ? null : (m.name, '#${m.loadOrder + 1}');
    };
  }

  Widget _buildFooter(
    ScumColors colors,
    ConflictPanelData? data,
    ConflictService cs,
    ModService? svc,
  ) {
    final rep = cs.report;
    final scanned = data != null
        ? data.scannedCount()
        : (rep?.scannedModCount ?? 0);
    final hasConflict = data != null
        ? data.groups().isNotEmpty
        : (rep != null && rep.groups.isNotEmpty);
    final scanning = data != null ? data.scanning() : cs.scanning;
    return Row(
      children: [
        Text(
          data?.footerNote ?? _mainListMergeNote(scanned),
          style: TextStyle(
            color: colors.textDim,
            fontSize: 10,
            decoration: TextDecoration.none,
          ),
        ),
        const Spacer(),
        // 只看冲突 / 显示全部（仅主列表有列表筛选联动；自定义数据源不显示）
        if (data == null && hasConflict && !scanning) ...[
          _PanelButton(
            colors: colors,
            label: _conflictsOnly ? '显示全部' : '只看冲突 mod',
            icon: _conflictsOnly
                ? Icons.view_list_rounded
                : Icons.filter_alt_rounded,
            active: _conflictsOnly,
            onTap: () {
              // 立即翻转自身文案 + 同步 HomeScreen 列表（马上切换，无需关闭面板）。
              setState(() => _conflictsOnly = !_conflictsOnly);
              widget.onToggleFilter();
            },
          ),
          const SizedBox(width: 6),
        ],
        // 重新扫描
        _PanelButton(
          colors: colors,
          label: '重新扫描',
          icon: Icons.refresh_rounded,
          active: false,
          onTap: () {
            final d = data;
            if (d != null) {
              // ignore: discarded_futures
              d.onRescan();
            } else {
              // ignore: discarded_futures
              ConflictService.shared.refresh();
            }
          },
        ),
        const SizedBox(width: 6),
        _PanelButton(
          colors: colors,
          label: '关闭',
          icon: Icons.close_rounded,
          active: false,
          onTap: widget.onClose,
        ),
      ],
    );
  }

  /// 主列表模式的底部说明：扫描计数 + 冲突自动合并状态。
  /// 无合并需求 / 合并不可用 / 合并中 / 已合并 / 合并失败 分情况提示。
  String _mainListMergeNote(int scanned) {
    final ms = MergeService.shared;
    final base = '参与扫描：$scanned 个已启用 PAK';
    if (ms.unavailable) return '$base · 自动合并不可用（未找到 repak）';
    if (ms.merging) return '$base · 正在合并冲突：${ms.progress}';
    final m = ms.current;
    if (m != null) {
      return '$base · 已自动合并 ${m.mergedModNames.length} 个冲突 mod → '
          '${m.mergedName}';
    }
    if (ms.lastError != null) {
      return '$base · 自动合并失败：${ms.lastError}（按原顺序部署）';
    }
    return base;
  }
}

/// 实时状态胶囊：无冲突（绿）/ N 处冲突（红）/ 扫描中 / 不可用。
class _StateChip extends StatelessWidget {
  final ScumColors colors;
  final ConflictPanelData? data;
  final ConflictService cs;

  const _StateChip({
    required this.colors,
    required this.data,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = _resolve();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  (String, Color) _resolve() {
    final data = this.data; // public 字段不做类型提升，先收窄本地变量
    if (data != null) {
      if (data.unavailable()) return ('不可用', colors.textDim);
      if (data.scanning()) return ('扫描中…', colors.textDim);
      final groups = data.groups();
      if (groups.isEmpty) return ('无冲突', colors.success);
      final mods = <String>{};
      for (final g in groups) {
        mods.addAll(g.modIds);
      }
      return (
        '${groups.length} 处冲突 · ${mods.length} 个 mod',
        colors.dangerLight,
      );
    }
    if (cs.unavailable) return ('不可用', colors.textDim);
    if (cs.scanning) return ('扫描中…', colors.textDim);
    final rep = cs.report;
    if (rep == null) return ('未扫描', colors.textDim);
    if (rep.groups.isEmpty) return ('无冲突', colors.success);
    return (
      '${rep.groups.length} 处冲突 · ${rep.conflictedModIds.length} 个 mod',
      colors.dangerLight,
    );
  }
}

/// 冲突列表：每个路径一组，列出涉及的 mod。
///
/// 全局模式（工具栏按钮）显示全部冲突路径；聚焦模式（行内徽章）只显示
/// 与该 mod 相关的冲突路径 —— 每条路径上列出的 mod 正是与它纠缠的冲突对象。
class _ConflictList extends StatelessWidget {
  final ScumColors colors;

  /// 要显示的冲突组（主列表：全局/聚焦；镜像：该条目相关组）。
  final List<PakConflictGroup> groups;

  /// 参与者解析：id → (显示名, 序号标签)。主列表 = mod 名称 + 加载序号；
  /// 镜像 = 文件名（序号 null）。
  final (String, String?)? Function(String id) participantFor;

  /// 聚焦 mod id（非空时该 id 的徽章高亮为主色，方便辨认「本 mod」）。
  final String? highlightModId;

  const _ConflictList({
    required this.colors,
    required this.groups,
    required this.participantFor,
    this.highlightModId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: groups.length,
            separatorBuilder: (_, _) => Container(
              height: 1,
              color: colors.border.withValues(alpha: 0.5),
            ),
            itemBuilder: (context, i) {
              final g = groups[i];
              return _ConflictGroupTile(
                colors: colors,
                group: g,
                participantFor: participantFor,
                highlightModId: highlightModId,
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '加载序靠后的 PAK 会覆盖靠前的同名资源，实际生效的只有其中一个。',
          style: TextStyle(
            color: colors.textDim,
            fontSize: 10,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

/// 单个冲突路径条目。
class _ConflictGroupTile extends StatelessWidget {
  final ScumColors colors;
  final PakConflictGroup group;
  final (String, String?)? Function(String id) participantFor;
  final String? highlightModId;

  const _ConflictGroupTile({
    required this.colors,
    required this.group,
    required this.participantFor,
    this.highlightModId,
  });

  @override
  Widget build(BuildContext context) {
    // 解析参与者的显示信息（id → 名称/序号）；解析失败的 id 跳过。
    final participants = <(String, String, String?)>[];
    for (final id in group.modIds) {
      final p = participantFor(id);
      if (p != null) participants.add((id, p.$1, p.$2));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 13,
                color: colors.dangerLight,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: group.path,
                  child: Text(
                    group.path,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '×${group.count}',
                style: TextStyle(
                  color: colors.dangerLight,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 19),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final (id, label, order) in participants)
                  _ConflictChip(
                    colors: colors,
                    label: label,
                    orderLabel: order,
                    highlight: id == highlightModId,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 冲突涉及的 mod 小胶囊：显示名 + 可选序号标签（镜像模式无序号）。
class _ConflictChip extends StatelessWidget {
  final ScumColors colors;
  final String label;

  /// 序号标签（主列表 = `#N`；镜像 = null 不显示）。
  final String? orderLabel;

  /// 是否为聚焦目标（点击徽章进入的那个 mod）—— 高亮为主色便于辨认。
  final bool highlight;

  const _ConflictChip({
    required this.colors,
    required this.label,
    this.orderLabel,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = highlight ? colors.accent : colors.dangerLight;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: highlight ? 0.22 : 0.1),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: chipColor.withValues(alpha: highlight ? 0.7 : 0.3),
          width: highlight ? 1.2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (orderLabel != null) ...[
            Text(
              orderLabel!,
              style: TextStyle(
                color: colors.textDim,
                fontSize: 9,
                fontFamily: 'Consolas',
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 3),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: chipColor,
                fontSize: 10,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息提示框（不可用 / 扫描中 / 无冲突）。
class _HintBox extends StatelessWidget {
  final ScumColors colors;
  final IconData icon;
  final Color color;
  final String message;

  const _HintBox({
    required this.colors,
    required this.icon,
    required this.color,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                height: 1.5,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板底部操作按钮（全自绘）。
class _PanelButton extends StatelessWidget {
  final ScumColors colors;
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  const _PanelButton({
    required this.colors,
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? colors.accent.withValues(alpha: 0.18)
                : colors.bgCard,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? colors.accent : colors.border,
              width: active ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: active ? colors.accent : colors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: active ? colors.accent : colors.textSecondary,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
