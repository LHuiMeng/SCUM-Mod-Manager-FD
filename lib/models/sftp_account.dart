/// SFTP 服务器账户模型 —— 一个账户 = 一台服务器连接配置。
///
/// 支持多账户（主人需求：远程服务器界面可快速切换不同服务器）：
/// 每账户独立保存 host/port/username/password/mods_path 与显示名。
/// 持久化在 config.json 的 `sftp_accounts` 数组 + `sftp_active_account` 索引。
class SftpAccount {
  /// 账户显示名（用户可自定义，如「主服」「测试服」）。空 → 用 host 兜底。
  String name;

  /// 服务器主机（IP 或域名，不含协议前缀；支持解析完整 URI 后拆分）。
  String host;

  /// SSH 端口（默认 22）。
  int port;

  /// 登录用户名。
  String username;

  /// 登录密码（明文存本机 config.json，仅本地使用）。
  String password;

  /// 远端 ~mods 绝对路径（留空 = 未定位，连接后自动探测）。
  String modsPath;

  SftpAccount({
    String? name,
    required this.host,
    this.port = 22,
    required this.username,
    this.password = '',
    this.modsPath = '',
  }) : name = (name == null || name.isEmpty) ? host : name;

  String get displayName => name.isEmpty ? host : name;

  /// 账户唯一键（服务器标识 = 服务器 IP + 账户，非 IP:端口）：
  /// `host@username`，用于本地数据库归属与跨服互通索引。
  /// 同一台服务器不同账户（chroot 布局各用户独立）因此互不混淆。
  String get key => '$host@$username';

  factory SftpAccount.fromJson(Map<String, dynamic> json) {
    return SftpAccount(
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      modsPath: json['mods_path'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'mods_path': modsPath,
  };
}
