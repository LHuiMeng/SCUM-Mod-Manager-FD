/// 远端 SCUM Mod Registry 返回的单条 mod manifest。
///
/// 远端 registry 条目（云上 mod 目录列表的一行）。
///
/// 数据来源：scum-mod-registry 服务，地址由打包者经 REGISTRY_BASE_URL
/// 编译期注入（缺省空 = 无云源，面板显示空列表）。
/// 服务端只暴露 GET（list / download），客户端永远不直接上传；
/// 所有上传必须通过 SSH 到服务端后用 `curl` 本地 POST 完成（绕过 CF WAF）。
///
/// 字段命名严格对齐 manifest JSON 的 snake_case 键值；
/// Dart 端遵循 lowerCamelCase 命名约定。
class RemoteModEntry {
  /// Mod 唯一 ID（小写、英文、连字符分隔，例如 "realistic-infection"）。
  final String id;

  /// 中文显示名称。
  final String name;

  /// 英文显示名称（可选；为空时回退到 [id]）。
  final String? nameEn;

  /// 语义化版本字符串，例如 "1.2.0"、"0.9.3-beta"。
  final String version;

  /// pak 文件字节数。
  final int sizeBytes;

  /// pak 文件 sha256（可选；用于完整性校验，下载时可与本地哈希比对）。
  final String? sha256;

  /// 描述文本（可选，markdown 友好）。
  final String? description;

  /// 标签列表（用于过滤/搜索，例如 ["infection", "gameplay"]）。
  final List<String> tags;

  /// 版本更新日志（可选；多行字符串，按版本倒序排列）。
  final String? updateNotes;

  /// 发布时间 ISO 8601 字符串，例如 "2026-07-30"（可选）。
  final String? releasedAt;

  /// 最低客户端版本要求，例如 "1.0.0"（可选；低于此版本应拒绝加载）。
  final String? minAppVersion;

  /// 云上作者备注（可选；**优先级高于远程服务器备注** —— 同一 sha-256
  /// 识别为同一 mod 时，云上备注直接覆盖显示，也可随推送覆盖服务器端备注）。
  final String? notes;

  /// 真实下载文件名，例如 "RealisticInfection.pak"。
  final String filename;

  /// 云端 manifest 自带的直达下载地址（可选）。为空时客户端按
  /// `base_url/mods/<id>/download` 默认规则拼接；用户可在
  /// cloud_sources.json 中按 id 覆盖下载地址
  /// （优先级：用户自定义 > 此字段 > 默认拼接）。
  final String? downloadUrl;

  /// 包类型（可选）：`"ue4ss"` = UE4SS 客户端 mod（zip 包，解压到
  /// `ue4ss/Mods/<名>/`）；缺省或 `"pak"` = 传统 PAK mod（落 `~mods/`）。
  ///
  /// 老 manifest 无此字段 —— [isUe4ssMod] 会回退按 `filename` 的 `.zip`
  /// 后缀判定，因此云端无需为兼容老客户端做特殊处理。
  final String? kind;

  const RemoteModEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.sizeBytes,
    required this.filename,
    this.nameEn,
    this.sha256,
    this.notes,
    this.description,
    this.tags = const [],
    this.updateNotes,
    this.releasedAt,
    this.minAppVersion,
    this.downloadUrl,
    this.kind,
  });

  /// 是否 UE4SS 类型 mod（显式 `kind` 优先，回退按 `.zip` 后缀判定）。
  bool get isUe4ssMod =>
      (kind ?? '').toLowerCase() == 'ue4ss' ||
      filename.toLowerCase().endsWith('.zip');

  /// 从 `/mods/<id>` 返回的 manifest JSON 构造。
  ///
  /// 所有字段都做了 null/类型兜底：服务端字段缺失时使用安全默认值而非抛错，
  /// 这样老版本 manifest 不会被一个字段缺失击穿整个 catalog。
  factory RemoteModEntry.fromJson(Map<String, dynamic> j) {
    return RemoteModEntry(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? j['id'] as String,
      nameEn: j['name_en'] as String?,
      version: (j['version'] as String?) ?? '0.0.0',
      sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      sha256: j['sha256'] as String?,
      notes: j['notes'] as String?,
      description: j['description'] as String?,
      tags: ((j['tags'] as List?)?.cast<String>()) ?? const [],
      updateNotes: j['update_notes'] as String?,
      releasedAt: j['released_at'] as String?,
      minAppVersion: j['min_app_version'] as String?,
      filename: (j['filename'] as String?) ?? '${j['id']}.pak',
      downloadUrl: j['download_url'] as String?,
      kind: j['kind'] as String?,
    );
  }

  /// 简易 semver-ish 比较器。
  ///
  /// 返回值：
  /// - `-1` 当 [a] < [b]
  /// - `0`  当 [a] == [b]
  /// - `1`  当 [a] > [b]
  ///
  /// 支持的版本格式："1.2.0"、"0.9.3-beta"、"2.0"、"1_0_0"。
  ///
  /// 不支持的格式（纯字母、含前导 + 号等）一律视为 `0`。
  /// 这意味着 `compare("abc", "1.0.0")` 返回 -1（"abc" 被认为最旧），
  /// 避免对畸形 manifest 抛异常击穿 UI。
  static int compare(String a, String b) {
    final pa = a.split(_versionSeparator);
    final pb = b.split(_versionSeparator);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final ai = i < pa.length ? int.tryParse(pa[i]) ?? 0 : 0;
      final bi = i < pb.length ? int.tryParse(pb[i]) ?? 0 : 0;
      if (ai != bi) return ai < bi ? -1 : 1;
    }
    return 0;
  }

  /// 分隔版本字符串的正则：`.` `-` `_` `+` 都视为段分隔符。
  static final RegExp _versionSeparator = RegExp(r'[.\-_+]');
}
