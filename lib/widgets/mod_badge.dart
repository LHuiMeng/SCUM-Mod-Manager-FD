import 'package:flutter/material.dart';

import '../models/mod_entry.dart';
import '../theme/scum_theme.dart';
import '../theme/scum_colors.dart';

/// 状态徽章 —— 显示"远端/已链接"等标签式提示。
///
/// 独立文件：徽章样式可能在卡片、详情页、tooltip 中多处复用，
/// 单独存放避免 [ModCard] 内部样式变化时连带改坏其他位置。
class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// 模组类型徽章 —— 把 [ModType] 映射成"PAK/CFG/SCR/U4SS"色短标签。
///
/// 集中处理类型→(标签, 颜色)映射；如果以后要新增 ModType，
/// 只改这一个文件的 switch 即可。
class TypeBadge extends StatelessWidget {
  final ModType type;

  const TypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final (String label, Color color) = _resolve(type, colors);
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
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  /// 类型 → (显示标签, 主题色)。
  ///
  /// PAK 客户端/服务端共用"PAK"字样但用不同颜色区分；新增类型时在这里补一行。
  /// 颜色全部走 [ScumColors] token：
  /// - 客户端 PAK 用 `accentDim`（暗金）；
  /// - 服务端 PAK 用 `success`（军绿）；
  /// - UE4SS mod 用 `dangerLight`（警示红，区别 PAK 的黄/绿）；
  /// - CFG / SCR 是文件类型语义色，跟主题无关（两态一致）。
  static (String, Color) _resolve(ModType type, ScumColors colors) {
    switch (type) {
      case ModType.clientPak:
        return ('PAK', colors.accentDim);
      case ModType.serverPak:
        return ('PAK', colors.success);
      case ModType.ue4ssMod:
        return ('U4SS', colors.dangerLight);
      case ModType.configFile:
        return ('CFG', colors.badgeCfg);
      case ModType.script:
        return ('SCR', colors.badgeScr);
      case ModType.other:
        return ('---', colors.textDim);
    }
  }

  /// 导出 [ScumTheme] 的 success 色，给卡片行的"已部署"徽章复用。
  static Color successColor(ScumColors colors) => colors.success;
}
