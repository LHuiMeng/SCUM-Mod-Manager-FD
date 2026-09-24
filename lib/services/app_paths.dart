/// 安装根目录统一入口（v3 架构：引导器 + 版本目录模型）。
///
/// v3 起应用本体运行在 `{root}/versions/<ver>/` 下（scum_mod_manager_app.exe），
/// 而用户数据（~mods / ue4ss_runtime / config.json / logs / assets / ~merged …）
/// 永远位于安装根 `{root}`。Dart 侧一切取「exe 所在目录」当用户数据根的
/// 地方，都必须改走本单例 —— 否则本体一旦搬进 versions/，用户数据就会
/// 随版本目录漂移、更新即丢。
///
/// root 解析优先级：
///   1. 环境变量 SCUM_MM_ROOT —— 由引导器 scum_mod_manager.exe 在
///      CreateProcessW 前注入（子进程继承父进程环境变量）；
///   2. 兜底：Platform.resolvedExecutable 的父目录 —— 覆盖「直接双击
///      *_app.exe 调试 / 开发机 flutter run」场景，行为与旧版一致。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._();

  static final AppPaths instance = AppPaths._();

  /// 安装根（用户数据根）。必须在 main() 最前调用 [init] 后再读取。
  late final String root;

  bool _initialized = false;

  /// 必须在 main() 入口第一行调用（早于任何服务取路径）。
  void init() {
    final env = Platform.environment['SCUM_MM_ROOT'];
    if (env != null && env.isNotEmpty) {
      root = env;
    } else {
      root = File(Platform.resolvedExecutable).parent.path;
    }
    _initialized = true;
  }

  /// 拼接 root 下的子路径（与 p.join(root, ...) 等价，少打一遍 root）。
  String join(String first, [String? second, String? third, String? fourth]) {
    assert(_initialized, 'AppPaths.init() 必须在 main() 最前调用');
    final parts = <String>[
      first,
      if (second != null) second,
      if (third != null) third,
      if (fourth != null) fourth,
    ];
    return p.joinAll([root, ...parts]);
  }
}
