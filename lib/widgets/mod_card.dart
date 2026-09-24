/// 自绘 PAK 卡片 —— 显示模组信息 + 设置按钮。
///
/// 全部使用 [Container] / 自绘控件实现，无 Material 控件。
///
library;

import 'package:flutter/material.dart';

import '../models/mod_entry.dart';
import '../theme/scum_theme.dart';
import '../theme/scum_colors.dart';
import 'mod_badge.dart';
import 'mod_card_action_button.dart';

/// PAK 卡片主体。
class ModCard extends StatefulWidget {
  final ModEntry mod;
  final VoidCallback onToggle;
  final int index;
  final VoidCallback? onDelete;
  final bool fromRemote;
  final VoidCallback? onOpenSettings;

  const ModCard({
    super.key,
    required this.mod,
    required this.onToggle,
    required this.index,
    this.onDelete,
    this.fromRemote = false,
    this.onOpenSettings,
  });

  @override
  State<ModCard> createState() => _ModCardState();
}

class _ModCardState extends State<ModCard> {
  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final mod = widget.mod;

    return ReorderableDragStartListener(
      index: widget.index,
      child: Container(
        margin: const EdgeInsets.only(bottom: 1),
        decoration: BoxDecoration(
          color: mod.enabled
              ? colors.bgCard
              : colors.bgCard.withValues(alpha: 0.4),
          border: Border(
            left: BorderSide(
              color: mod.enabled ? colors.accent : colors.border,
              width: mod.enabled
                  ? ScumTheme.cardLeftBorderEnabled
                  : ScumTheme.cardLeftBorderDisabled,
            ),
            bottom: BorderSide(color: colors.border, width: 0.5),
          ),
          // 启用态卡片四角微圆，与外层 ClipRRect 区分（卡片是组件级小圆角）。
          borderRadius: BorderRadius.circular(ScumTheme.cardRadius),
          // 启用态加 accent 微光：低 alpha、低模糊，让卡片"浮"起来但不抢戏。
          // 禁用态无 boxShadow —— 视觉上弱化，与启用态形成对比。
          boxShadow: mod.enabled
              ? [
                  BoxShadow(
                    color: colors.accentGlow,
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: Row(
            children: [
              // 加载顺序
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

              // 启用勾选
              _EnableCheckbox(enabled: mod.enabled, onTap: widget.onToggle),
              const SizedBox(width: 12),

              // 模组信息
              Expanded(
                child: _InfoColumn(mod: mod, fromRemote: widget.fromRemote),
              ),

              // 设置按钮（点击弹出标签/备注编辑悬浮窗）
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

              // 删除按钮
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
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  启用勾选框
// =====================================================================

/// 自绘启用勾选框。
class _EnableCheckbox extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _EnableCheckbox({required this.enabled, required this.onTap});

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

// =====================================================================
//  模组信息列
// =====================================================================

/// 模组信息列：名称 + 徽章 + 文件大小 + 描述。
class _InfoColumn extends StatelessWidget {
  final ModEntry mod;
  final bool fromRemote;

  const _InfoColumn({required this.mod, required this.fromRemote});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 主标题：永远显示 mod 名称 —— 备注不再抢占主位（任务3）。
        Row(
          children: [
            if (mod.notes.isNotEmpty) ...[
              Icon(
                Icons.notes_rounded,
                size: 13,
                color: mod.enabled ? colors.accent : colors.textDim,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                mod.name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: mod.enabled ? colors.textPrimary : colors.textDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (fromRemote) StatusBadge(label: '云上', color: colors.accent),
            if (!fromRemote) StatusBadge(label: '本地', color: colors.textDim),
            if (mod.deployed) StatusBadge(label: '已链接', color: colors.success),
          ],
        ),
        const SizedBox(height: 2),
        // 副标题行：类型 + 备注（若有）+ 大小 + 描述。
        // 名称已占主标题位，备注在此展示。
        Row(
          children: [
            TypeBadge(type: mod.type),
            const SizedBox(width: 6),
            if (mod.notes.isNotEmpty) ...[
              Flexible(
                child: Text(
                  mod.notes,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: mod.enabled ? colors.textSecondary : colors.textDim,
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              mod.fileSizeFormatted,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
            if (mod.description.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  mod.description,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ],
        ),

        // ── 标签只读 chips（空时整段隐藏；滚轮可横向滚动） ──
        if (mod.tags.isNotEmpty) ...[
          const SizedBox(height: 4),
          _TagScrollRow(tags: mod.tags, enabled: mod.enabled),
        ],
      ],
    );
  }
}

/// 只读标签 chip（无删除按钮，仅展示）。编辑走 settings 弹窗。
///
/// 滚动条铁律：mod 卡片内不允许滚动条（横向 SingleChildScrollView 也是滚动条）。
/// 改为 [Wrap]：tag 数量多时自动换行而不是横向滚动；卡片高度随行数自适应。
class _TagScrollRow extends StatelessWidget {
  final List<String> tags;
  final bool enabled;
  const _TagScrollRow({required this.tags, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [for (final tag in tags) _ReadOnlyTagChip(label: tag)],
    );
  }
}

class _ReadOnlyTagChip extends StatelessWidget {
  final String label;
  const _ReadOnlyTagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.accent,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}
