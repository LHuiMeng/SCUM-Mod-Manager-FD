import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';
import 'dashed_border_painter.dart';

/// Full-window drop zone overlay。
///
/// 当 [active] 由原生信号（Windows Explorer drag enter）置 true 时，
/// 全屏 tint + 虚线圆角 + 中心 icon 一起进场；
/// 切回 false 时同样反向出场。
///
/// 视觉拆解：
/// - tint（半透色填充）
/// - dashed frame（→ [DashedBorderPainter]）
/// - center label + icon
///
/// 之所以把 painter 抽到独立文件：算法可独立测试，也方便别的 overlay 复用。
class DropZoneOverlay extends StatefulWidget {
  /// true = 全强度显示（强边框、背景 tint、放大 icon）。
  final bool active;

  /// 刚导入的文件名列表，用于视觉确认。
  final List<String> lastImported;

  /// 中心文案（默认模组管理导入提示；服务器/镜像模式由调用方覆盖）。
  final String title;

  /// 中心图标（默认下载图标；随语境可换）。
  final IconData icon;

  const DropZoneOverlay({
    super.key,
    this.active = false,
    this.lastImported = const [],
    this.title = '松开以导入 .pak / .ini',
    this.icon = Icons.file_download_rounded,
  });

  @override
  State<DropZoneOverlay> createState() => _DropZoneOverlayState();
}

class _DropZoneOverlayState extends State<DropZoneOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const Duration _animDuration = Duration(milliseconds: 280);
  static const double _tintMaxAlpha = 0.18;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _animDuration);
    if (widget.active) _ctrl.forward();
  }

  @override
  void didUpdateWidget(covariant DropZoneOverlay old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _ctrl.forward();
    if (!widget.active && old.active) _ctrl.reverse();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return IgnorePointer(
      ignoring: !widget.active,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          return Stack(
            children: [
              // 1. 全屏 tint —— 跟随 progress 渐显
              Positioned.fill(
                child: Container(
                  color: colors.accent.withValues(alpha: _tintMaxAlpha * t),
                ),
              ),
              // 2. 虚线圆角边框
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: CustomPaint(
                    painter: DashedBorderPainter(
                      progress: t,
                      color: colors.accent,
                    ),
                  ),
                ),
              ),
              // 3. 中心 icon + 文案 + 已导入列表
              _buildCenter(t, colors),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCenter(double t, ScumColors colors) {
    return Center(
      child: Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.85 + 0.15 * t,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colors.bgDark.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.accent, width: 2),
                ),
                child: Icon(widget.icon, size: 56, color: colors.accent),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              if (widget.lastImported.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildImportedBadge(colors),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportedBadge(ScumColors colors) {
    final shown = widget.lastImported.take(3).join(', ');
    final overflow = widget.lastImported.length > 3
        ? ' +${widget.lastImported.length - 3}'
        : '';
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.bgDark.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.success, width: 1),
      ),
      child: Text(
        shown + overflow,
        style: TextStyle(
          color: colors.success,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
