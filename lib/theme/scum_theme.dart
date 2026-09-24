import 'package:flutter/material.dart';

import 'scum_colors.dart';

/// SCUM Mod Manager 主题入口。
///
/// 拆分：
/// - **几何 / 动画常量**（`windowCornerRadius / cardRadius / hoverScale / ...`）：
///   跟主题无关，沿用 `static const` 全局访问（这些值跨主题不变，没必要走 BuildContext）。
/// - **颜色 token**：[ScumColors]（ThemeExtension）。所有 widget 必须通过
///   `ScumColors.of(context)` 拿颜色，保证 `MaterialApp.themeMode` 切换时
///   整树颜色跟着翻。
/// - **基础 [ThemeData]**：[darkTheme] / [lightTheme] 工厂注入对应 token。
class ScumTheme {
  ScumTheme._();

  // ── 窗口几何 ──
  /// 窗口圆角半径（像素）。与 C++ 端 ApplyWindowRoundedCorners 的 radius
  /// 必须保持一致——否则视觉上的圆角内/外缘对不齐。
  /// 改动这里后请同步修改 windows/runner/flutter_window.cpp / win32_window.cpp。
  static const double windowCornerRadius = 10;

  // ── 卡片 / 按钮几何 ──
  /// ModCard 圆角半径（启用时上/下统一用此值）。
  static const double cardRadius = 6;

  /// hover 时按钮/卡片的 scale 倍率（1.0=不缩放，1.05=放大 5%）。
  static const double hoverScale = 1.04;

  /// hover 时颜色/亮度增量（叠加在 base alpha 上）。
  static const double hoverAlphaBoost = 0.08;

  /// 启用态卡片左条宽度。
  static const double cardLeftBorderEnabled = 3;

  /// 禁用态卡片左条宽度。
  static const double cardLeftBorderDisabled = 1;

  /// 运行态（pulse）呼吸动画周期。
  static const Duration pulseDuration = Duration(milliseconds: 1400);

  // ── 主题数据 ─────────────────────────────────────────────
  /// 暗色 [ThemeData] —— 注入 [ScumColors.dark] 扩展，并把基础字段
  /// （scaffold / cardColor / dividerColor / dialogTheme 等）从 token 派生，
  /// 保证内置控件（`Theme.of(context).colorScheme` 等）也跟手绘 widget
  /// 一起切。
  static ThemeData get darkTheme {
    const c = ScumColors.dark;
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: c.bgDark,
      colorScheme: ColorScheme.dark(
        primary: c.accent,
        secondary: c.accentDim,
        surface: c.bgPanel,
        error: c.danger,
        onPrimary: c.bgDark,
        onSurface: c.textPrimary,
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(
          color: c.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
        titleMedium: TextStyle(
          color: c.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(color: c.textPrimary, fontSize: 14),
        bodyMedium: TextStyle(color: c.textSecondary, fontSize: 13),
        bodySmall: TextStyle(color: c.textDim, fontSize: 12),
        labelLarge: TextStyle(
          color: c.accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.0,
        ),
      ),
      dividerColor: c.border,
      cardColor: c.bgCard,
      canvasColor: c.bgPanel,
      dialogTheme: DialogThemeData(backgroundColor: c.bgPanel),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.bgCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.borderAccent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        labelStyle: TextStyle(color: c.textSecondary, fontSize: 13),
      ),
      // 注入颜色 token 扩展 —— widget 通过 ScumColors.of(context) 读取。
      extensions: const <ThemeExtension<dynamic>>[ScumColors.dark],
    );
  }

  /// 亮色 [ThemeData] —— 注入 [ScumColors.light] 扩展。
  static ThemeData get lightTheme {
    const c = ScumColors.light;
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: c.bgDark,
      colorScheme: ColorScheme.light(
        primary: c.accent,
        secondary: c.accentDim,
        surface: c.bgPanel,
        error: c.danger,
        onPrimary: c.bgDark,
        onSurface: c.textPrimary,
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(
          color: c.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
        titleMedium: TextStyle(
          color: c.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(color: c.textPrimary, fontSize: 14),
        bodyMedium: TextStyle(color: c.textSecondary, fontSize: 13),
        bodySmall: TextStyle(color: c.textDim, fontSize: 12),
        labelLarge: TextStyle(
          color: c.accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.0,
        ),
      ),
      dividerColor: c.border,
      cardColor: c.bgCard,
      canvasColor: c.bgPanel,
      dialogTheme: DialogThemeData(backgroundColor: c.bgPanel),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.bgCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c.borderAccent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        labelStyle: TextStyle(color: c.textSecondary, fontSize: 13),
      ),
      extensions: const <ThemeExtension<dynamic>>[ScumColors.light],
    );
  }
}