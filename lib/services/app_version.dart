/// 应用版本统一入口 —— 运行时唯一的版本来源。
///
/// 其他模块（标题栏展示、在线更新版本比对）一律从这里取版本号，
/// **禁止**各自硬编码（此前 home_screen 标题栏写死 'v2.3'、
/// update_service 缺省 '2.4.0'，与 pubspec 的 2.5.0 三处不一致）。
///
/// 版本注入链路：
/// - `pubspec.yaml` 的 `version:` 是分发版本（打包/文件版本用）
/// - 本常量是运行时版本，构建时由打包脚本通过
///   `--dart-define=APP_VERSION=x.y.z` 注入
/// - 未注入时回退到缺省值（改 pubspec 版本时需同步这里）
library;

class AppVersion {
  AppVersion._();

  /// 当前版本号（如 "2.5.0"）。
  static const String value = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.6.5',
  );

  /// 标题栏展示用（带 v 前缀，如 "v2.5.0"）。
  static String get display => 'v$value';
}
