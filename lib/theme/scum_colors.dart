import 'package:flutter/material.dart';

/// SCUM 主题色 token（暗 / 亮各一组），通过 [ThemeExtension] 挂到 [ThemeData] 上。
///
/// 关键设计：
/// - **不再用 static const 颜色常量直接读**。所有 widget 必须通过
///   `ScumColors.of(context).xxx` 或 `Theme.of(context).extension<ScumColors>()!.xxx`
///   拿颜色，这样 `MaterialApp.themeMode` 切换时整树会自动跟着切。
/// - 几何/动画/字号常量留在 [ScumTheme]（跟主题无关，不需要走 [BuildContext]）。
/// - accent / 黄铜主题色在暗/亮两态下保持一致——只在背景层 + 文字层做翻转。
///   这样品牌识别色不会因切换主题而变，UI 也不会因亮色 accent 在白底上看不清
///   而需要再调一次。
class ScumColors extends ThemeExtension<ScumColors> {
  const ScumColors({
    required this.bgDark,
    required this.bgPanel,
    required this.bgCard,
    required this.bgHover,
    required this.accent,
    required this.accentDim,
    required this.danger,
    required this.dangerLight,
    required this.dangerShadow,
    required this.dangerHighlight,
    required this.success,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDim,
    required this.border,
    required this.borderAccent,
    required this.borderStrong,
    required this.accentGlow,
    required this.accentGlowSoft,
    required this.accentHighlight,
    required this.accentShadow,
    required this.accentDeepShadow,
    required this.successHighlight,
    required this.successShadow,
    required this.launchShadow,
    required this.launchShadowIdle,
    required this.overlay,
    required this.shadowSm,
    required this.shadowMd,
    required this.brandLogo,
    required this.badgeCfg,
    required this.badgeScr,
    required this.windowBtnIcon,
    required this.windowBtnIconHover,
    required this.logDebug,
    required this.logUi,
    required this.logTimestamp,
  });

  // ── 背景层级 ──
  final Color bgDark; // scaffold 底（窗口背景）
  final Color bgPanel; // 中间面板（侧边栏 / 顶栏）
  final Color bgCard; // 卡片底
  final Color bgHover; // hover 态

  // ── 主题强调色（两态一致）──
  final Color accent;
  final Color accentDim;

  // ── 危险色（两态一致）──
  final Color danger;
  final Color dangerLight;
  final Color dangerShadow;
  final Color dangerHighlight;

  // ── 成功色（两态一致）──
  final Color success;
  final Color successHighlight;
  final Color successShadow;

  // ── 文本层级 ──
  final Color textPrimary;
  final Color textSecondary;
  final Color textDim;

  // ── 边框 ──
  final Color border;
  final Color borderAccent;
  final Color borderStrong;

  // ── Accent 微光（启用态卡片 boxShadow 用）──
  final Color accentGlow;
  final Color accentGlowSoft;

  // ── 启动按钮金属感（两态一致）──
  final Color accentHighlight;
  final Color accentShadow;
  final Color accentDeepShadow;

  // ── 启动按钮阴影（两态一致：黑阴影）──
  final Color launchShadow;
  final Color launchShadowIdle;

  // ── 通用遮罩/阴影（两态一致：黑透明）──
  /// 浮层遮罩 —— 弹窗背后的全屏半透明黑。
  /// 暗/亮态都用 0x60000000 保持视觉一致：浅色背景上的灰层也是黑透明，
  /// 不能用主题色（不然亮态变成灰白遮罩，失去浮层感）。
  final Color overlay;

  /// 小阴影 —— 卡片/菜单等悬起元素的 drop shadow。
  final Color shadowSm;

  /// 中阴影 —— 弹窗/悬浮层等大尺寸元素的 drop shadow。
  final Color shadowMd;

  // ── 品牌色（两态一致：Logo/品牌纹章用，跟主题无关）──
  /// Logo 与品牌标识的灰阶底色（两态都是 #555555）——
  /// 与 accent/danger/success 等语义色保持解耦，作为「品牌中性灰」独立 token 存在。
  final Color brandLogo;

  // ── 徽章 / 文件类型标识色（两态一致：语义色）──
  /// CFG 配置文件徽章色 —— 冷蓝，区别 PAK 黄绿。
  final Color badgeCfg;

  /// SCR 脚本徽章色 —— 紫色，与 CFG/SVR/CLI 区分。
  final Color badgeScr;

  // ── 窗口控件图标色（跨主题：暗态浅灰 / 亮态深灰）──
  /// 窗口按钮（min/max/close）默认图标色。
  /// 暗态浅灰 = 可见但不抢眼；亮态深灰 = 在浅背景上有对比。
  final Color windowBtnIcon;

  /// 窗口按钮 hover 图标色，比 [windowBtnIcon] 更亮一档。
  /// 暗态亮灰（强调 hover）；亮态纯黑（hover 加深）。
  final Color windowBtnIconHover;

  // ── 日志页专用高亮色（两态一致）──
  final Color logDebug;
  final Color logUi;
  final Color logTimestamp;

  // ── 工厂：暗色 token（默认）──
  static const ScumColors dark = ScumColors(
    bgDark: Color(0xFF0D0D0D),
    bgPanel: Color(0xFF1A1A1A),
    bgCard: Color(0xFF222222),
    bgHover: Color(0xFF2A2A2A),
    accent: Color(0xFFD4A843),
    accentDim: Color(0xFF8B7332),
    danger: Color(0xFFC0392B),
    dangerLight: Color(0xFFE74C3C),
    dangerShadow: Color(0xFF7F2418),
    dangerHighlight: Color(0xFFF1948A),
    success: Color(0xFF4A7C59),
    textPrimary: Color(0xFFE0E0E0),
    textSecondary: Color(0xFF888888),
    textDim: Color(0xFF555555),
    border: Color(0xFF333333),
    borderAccent: Color(0xFF5C4A1E),
    borderStrong: Color(0xFF444444),
    accentGlow: Color(0x40D4A843),
    accentGlowSoft: Color(0x20D4A843),
    accentHighlight: Color(0xFFE8C572),
    accentShadow: Color(0xFF9C7E2E),
    accentDeepShadow: Color(0xFF7A6023),
    successHighlight: Color(0xFF6FA37F),
    successShadow: Color(0xFF2F5840),
    launchShadow: Color(0x80000000),
    launchShadowIdle: Color(0x60000000),
    overlay: Color(0x60000000),
    shadowSm: Color(0x66000000),
    shadowMd: Color(0x80000000),
    brandLogo: Color(0xFF555555),
    badgeCfg: Color(0xFF3A6B8C),
    badgeScr: Color(0xFF6B4C8C),
    windowBtnIcon: Color(0xFF666666),
    windowBtnIconHover: Color(0xFFCCCCCC),
    logDebug: Color(0xFF6A7A8A),
    logUi: Color(0xFF6FAEA1),
    logTimestamp: Color(0xFF7A7A7A),
  );

  // ── 工厂：亮色 token ──
  static const ScumColors light = ScumColors(
    bgDark: Color(0xFFF5F5F5),
    bgPanel: Color(0xFFEEEEEE),
    bgCard: Color(0xFFFFFFFF),
    bgHover: Color(0xFFE5E5E5),
    accent: Color(0xFFD4A843),
    accentDim: Color(0xFF8B7332),
    danger: Color(0xFFC0392B),
    dangerLight: Color(0xFFE74C3C),
    dangerShadow: Color(0xFF7F2418),
    dangerHighlight: Color(0xFFF1948A),
    success: Color(0xFF4A7C59),
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF555555),
    textDim: Color(0xFF888888),
    border: Color(0xFFD0D0D0),
    borderAccent: Color(0xFFB89538),
    borderStrong: Color(0xFFB0B0B0),
    accentGlow: Color(0x40D4A843),
    accentGlowSoft: Color(0x20D4A843),
    accentHighlight: Color(0xFFE8C572),
    accentShadow: Color(0xFF9C7E2E),
    accentDeepShadow: Color(0xFF7A6023),
    successHighlight: Color(0xFF6FA37F),
    successShadow: Color(0xFF2F5840),
    launchShadow: Color(0x80000000),
    launchShadowIdle: Color(0x60000000),
    overlay: Color(0x60000000),
    shadowSm: Color(0x66000000),
    shadowMd: Color(0x80000000),
    brandLogo: Color(0xFF555555),
    badgeCfg: Color(0xFF3A6B8C),
    badgeScr: Color(0xFF6B4C8C),
    // 亮态下 0xCCCCCC 在浅背景上不可见 —— 反转为深色（默认灰 / hover 纯黑）。
    windowBtnIcon: Color(0xFF888888),
    windowBtnIconHover: Color(0xFF1A1A1A),
    logDebug: Color(0xFF6A7A8A),
    logUi: Color(0xFF6FAEA1),
    logTimestamp: Color(0xFF7A7A7A),
  );

  /// 便捷读取助手 —— 等价于
  /// `Theme.of(context).extension<ScumColors>()!`，少打几个字。
  ///
  /// 使用前提：调用方必须能拿到 [BuildContext]（即必须在 widget build 方法
  /// 内部或子级回调里）。如果确实需要脱离 BuildContext 取色（比如 timer 回调），
  /// 请显式 `Theme.of(rootContext).extension<ScumColors>()!`。
  static ScumColors of(BuildContext context) {
    final ext = Theme.of(context).extension<ScumColors>();
    // 不允许 null —— 暗/亮 theme 都会注入，注入失败说明代码 bug。
    assert(
      ext != null,
      'ScumColors ThemeExtension 未注入到 ThemeData，请检查 ScumTheme.darkTheme/lightTheme。',
    );
    return ext!;
  }

  @override
  ScumColors copyWith({
    Color? bgDark,
    Color? bgPanel,
    Color? bgCard,
    Color? bgHover,
    Color? accent,
    Color? accentDim,
    Color? danger,
    Color? dangerLight,
    Color? dangerShadow,
    Color? dangerHighlight,
    Color? success,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDim,
    Color? border,
    Color? borderAccent,
    Color? borderStrong,
    Color? accentGlow,
    Color? accentGlowSoft,
    Color? accentHighlight,
    Color? accentShadow,
    Color? accentDeepShadow,
    Color? successHighlight,
    Color? successShadow,
    Color? launchShadow,
    Color? launchShadowIdle,
    Color? overlay,
    Color? shadowSm,
    Color? shadowMd,
    Color? brandLogo,
    Color? badgeCfg,
    Color? badgeScr,
    Color? windowBtnIcon,
    Color? windowBtnIconHover,
    Color? logDebug,
    Color? logUi,
    Color? logTimestamp,
  }) {
    return ScumColors(
      bgDark: bgDark ?? this.bgDark,
      bgPanel: bgPanel ?? this.bgPanel,
      bgCard: bgCard ?? this.bgCard,
      bgHover: bgHover ?? this.bgHover,
      accent: accent ?? this.accent,
      accentDim: accentDim ?? this.accentDim,
      danger: danger ?? this.danger,
      dangerLight: dangerLight ?? this.dangerLight,
      dangerShadow: dangerShadow ?? this.dangerShadow,
      dangerHighlight: dangerHighlight ?? this.dangerHighlight,
      success: success ?? this.success,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDim: textDim ?? this.textDim,
      border: border ?? this.border,
      borderAccent: borderAccent ?? this.borderAccent,
      borderStrong: borderStrong ?? this.borderStrong,
      accentGlow: accentGlow ?? this.accentGlow,
      accentGlowSoft: accentGlowSoft ?? this.accentGlowSoft,
      accentHighlight: accentHighlight ?? this.accentHighlight,
      accentShadow: accentShadow ?? this.accentShadow,
      accentDeepShadow: accentDeepShadow ?? this.accentDeepShadow,
      successHighlight: successHighlight ?? this.successHighlight,
      successShadow: successShadow ?? this.successShadow,
      launchShadow: launchShadow ?? this.launchShadow,
      launchShadowIdle: launchShadowIdle ?? this.launchShadowIdle,
      overlay: overlay ?? this.overlay,
      shadowSm: shadowSm ?? this.shadowSm,
      shadowMd: shadowMd ?? this.shadowMd,
      brandLogo: brandLogo ?? this.brandLogo,
      badgeCfg: badgeCfg ?? this.badgeCfg,
      badgeScr: badgeScr ?? this.badgeScr,
      windowBtnIcon: windowBtnIcon ?? this.windowBtnIcon,
      windowBtnIconHover: windowBtnIconHover ?? this.windowBtnIconHover,
      logDebug: logDebug ?? this.logDebug,
      logUi: logUi ?? this.logUi,
      logTimestamp: logTimestamp ?? this.logTimestamp,
    );
  }

  @override
  ScumColors lerp(ThemeExtension<ScumColors>? other, double t) {
    if (other is! ScumColors) return this;
    return ScumColors(
      bgDark: Color.lerp(bgDark, other.bgDark, t)!,
      bgPanel: Color.lerp(bgPanel, other.bgPanel, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      bgHover: Color.lerp(bgHover, other.bgHover, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentDim: Color.lerp(accentDim, other.accentDim, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerLight: Color.lerp(dangerLight, other.dangerLight, t)!,
      dangerShadow: Color.lerp(dangerShadow, other.dangerShadow, t)!,
      dangerHighlight: Color.lerp(dangerHighlight, other.dangerHighlight, t)!,
      success: Color.lerp(success, other.success, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderAccent: Color.lerp(borderAccent, other.borderAccent, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
      accentGlowSoft: Color.lerp(accentGlowSoft, other.accentGlowSoft, t)!,
      accentHighlight: Color.lerp(accentHighlight, other.accentHighlight, t)!,
      accentShadow: Color.lerp(accentShadow, other.accentShadow, t)!,
      accentDeepShadow: Color.lerp(
        accentDeepShadow,
        other.accentDeepShadow,
        t,
      )!,
      successHighlight: Color.lerp(
        successHighlight,
        other.successHighlight,
        t,
      )!,
      successShadow: Color.lerp(successShadow, other.successShadow, t)!,
      launchShadow: Color.lerp(launchShadow, other.launchShadow, t)!,
      launchShadowIdle: Color.lerp(
        launchShadowIdle,
        other.launchShadowIdle,
        t,
      )!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      shadowSm: Color.lerp(shadowSm, other.shadowSm, t)!,
      shadowMd: Color.lerp(shadowMd, other.shadowMd, t)!,
      brandLogo: Color.lerp(brandLogo, other.brandLogo, t)!,
      badgeCfg: Color.lerp(badgeCfg, other.badgeCfg, t)!,
      badgeScr: Color.lerp(badgeScr, other.badgeScr, t)!,
      windowBtnIcon: Color.lerp(windowBtnIcon, other.windowBtnIcon, t)!,
      windowBtnIconHover: Color.lerp(
        windowBtnIconHover,
        other.windowBtnIconHover,
        t,
      )!,
      logDebug: Color.lerp(logDebug, other.logDebug, t)!,
      logUi: Color.lerp(logUi, other.logUi, t)!,
      logTimestamp: Color.lerp(logTimestamp, other.logTimestamp, t)!,
    );
  }
}
