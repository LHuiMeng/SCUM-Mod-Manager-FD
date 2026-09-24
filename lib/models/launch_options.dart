/// SCUM 启动选项模型
///
/// 该模型负责把 UI 上的勾选项翻译成 SCUM/S CUMServer 启动时所需的命令行参数。
/// 调用方通过 [buildArgs] 拿到最终参数列表；逻辑集中在模型内，避免散落在 UI/Service 里。
///
/// 支持 toJson / fromJson，启动选项作为 `launch_options` 一起存在 config.json 中。
class LaunchOptions {
  /// 是否开启 UE 日志（`-log`）
  bool log;

  /// 是否开启文件打开日志（`-fileopenlog`）
  bool fileOpenLog;

  /// 是否显式禁用 BattlEye（`-nobattleye`）
  bool noBattlEye;

  /// 自定义端口（`-port=<value>`，仅服务端有效）
  String port;

  /// 是否有 PAK 模组启用。
  ///
  /// 一旦存在任何 PAK 模组，必须强制 `-nobattleye`，
  /// 否则 BattlEye 会因检测到非官方 PAK 直接杀进程。
  bool hasPakMods;

  LaunchOptions({
    this.log = false,
    this.fileOpenLog = false,
    this.noBattlEye = false,
    this.port = '',
    this.hasPakMods = false,
  });

  /// 从 config.json 的 `launch_options` 字段反序列化。
  factory LaunchOptions.fromJson(Map<String, dynamic> json) {
    return LaunchOptions(
      log: json['log'] == true,
      fileOpenLog: json['fileOpenLog'] == true,
      noBattlEye: json['noBattlEye'] == true,
      port: (json['port'] as String?) ?? '',
      hasPakMods: json['hasPakMods'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'log': log,
    'fileOpenLog': fileOpenLog,
    'noBattlEye': noBattlEye,
    'port': port,
    'hasPakMods': hasPakMods,
  };

  /// 把当前选项翻译为 SCUM / SCUMServer 的命令行参数列表。
  ///
  /// [isServer] 为 true 时追加 `-port=<port>`；为 false 时忽略端口参数
  /// （客户端不接收该参数，且拼上去会导致游戏无法启动）。
  ///
  /// 端口校验：[port] 必须是合法的 1..65535 整数才会拼到命令行。
  /// 非法值（如 "abc"、空字符串、越界）一律忽略，避免 SCUM 服务端启动失败。
  List<String> buildArgs(bool isServer) {
    final args = <String>[];

    if (log) args.add('-log');

    // 有 PAK 模组时强制 -fileopenlog。
    // 原因：文件打开日志（%LOCALAPPDATA%\SCUM\Saved\Logs\SCUM.log）
    // 会记录每个 pak 的挂载/加载结果，Mod 启用时自动带上，
    // 便于在日志里确认第三方 PAK 是否真的被游戏加载。
    if (fileOpenLog || hasPakMods) args.add('-fileopenlog');

    // 有 PAK 模组时强制 -nobattleye。
    // 原因：BattlEye 校验 UE 资源完整性，第三方 PAK 会被识别为篡改，
    // 直接结束进程——所以 Mod 启用时必须显式绕过。
    if (noBattlEye || hasPakMods) args.add('-nobattleye');

    if (isServer) {
      final portValue = int.tryParse(port);
      if (portValue != null && portValue >= 1 && portValue <= 65535) {
        args.add('-port=$portValue');
      } else if (port.isNotEmpty) {
        // 输入非法但非空 —— 静默忽略（不抛异常让启动失败；UI 层应该在
        // 用户输入时就挡掉，这里是兜底）。
      }
    }
    return args;
  }

  /// 端口是否合法（用于 UI 校验）。
  static bool isValidPort(String value) {
    final n = int.tryParse(value);
    return n != null && n >= 1 && n <= 65535;
  }

  /// 不可变复制：仅覆盖传入的非空字段，未传入字段保留旧值。
  LaunchOptions copyWith({
    bool? log,
    bool? fileOpenLog,
    bool? noBattlEye,
    String? port,
    bool? hasPakMods,
  }) {
    return LaunchOptions(
      log: log ?? this.log,
      fileOpenLog: fileOpenLog ?? this.fileOpenLog,
      noBattlEye: noBattlEye ?? this.noBattlEye,
      port: port ?? this.port,
      hasPakMods: hasPakMods ?? this.hasPakMods,
    );
  }
}
