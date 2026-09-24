/// 服务器端 mod 条目模型。
///
/// 表示通过 SFTP 扫描到的服务器 `~mods/` 目录中的一个 PAK 文件。
/// 数据来源 = SftpClient.listdir / stat 的属性 + 服务器端 `mods_meta.json` 的用户备注。
class ServerModEntry {
  /// 文件名（含 .pak 扩展名）。
  final String fileName;

  /// 远端绝对路径（`{~mods}/{fileName}`）。
  final String remotePath;

  /// 文件字节数。
  final int fileSize;

  /// 最后修改时间（服务器时间戳，可能为 null：部分 SFTP 服务器不报 mtime）。
  final DateTime? lastModified;

  /// 该文件的 SHA-256 校验值（hex 小写，64 字符）。
  /// 由 [ServerSftpService.computeSha256] 填充；null = 尚未计算。
  String? sha256;

  /// 用户备注（来自服务器端 `mods_meta.json`，跟随服务器，可跨管理端共享）。
  String notes;

  /// 本地 ~mods/ 中是否存在同名文件（用于与本地互认）。
  bool hasLocalMatch;

  /// 本地是否存在同 sha-256 内容的文件（文件名不同也认——内容互认）。
  /// 由 [ServerSftpService] 扫描/哈希后填充，对应「本地无同名文件」的修正：
  /// 同名只是第一层匹配，sha-256 相同即算本地有副本。
  bool hasLocalContentMatch;

  /// 本地同名文件的 SHA-256（hex），null = 本地无同名文件或尚未计算。
  String? localSha256;

  ServerModEntry({
    required this.fileName,
    required this.remotePath,
    required this.fileSize,
    this.lastModified,
    this.sha256,
    this.notes = '',
    this.hasLocalMatch = false,
    this.hasLocalContentMatch = false,
    this.localSha256,
  });

  /// 格式化文件大小（KB / MB / GB），与 [ModEntry.fileSizeFormatted] 一致。
  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 校验状态:
  /// - `match`      — 远端与本地同名文件 SHA-256 一致
  /// - `mismatch`   — 远端与本地同名文件 SHA-256 不一致
  /// - `contentMatch` — 本地无同名文件，但存在同 sha-256 内容的文件（内容互认）
  /// - `localOnly`  — 本地既无同名、也无同内容（仅服务器存在）
  /// - `unknown`    — 尚未比对
  String get matchStatus {
    if (sha256 == null) return 'unknown';
    if (hasLocalMatch) {
      if (localSha256 == null) return 'localOnly';
      return sha256 == localSha256 ? 'match' : 'mismatch';
    }
    if (hasLocalContentMatch) return 'contentMatch';
    return 'localOnly';
  }
}

/// 本地镜像条目 —— 服务器 mod 下载到本机后（每服务器专属文件夹
/// `{exe_dir}/server_mods/<host>@<username>/`）的本地副本。
///
/// 与 [ServerModEntry]（服务器端条目）相对：本类描述**本地文件**，
/// 并携带与服务器同名文件的比对信息（onServer / serverSha256），
/// 供「模组管理那套流程」在本地副本上运行：SHA-256 校验、冲突扫描、备注。
class ServerMirrorEntry {
  /// 文件名（含 .pak 扩展名）。
  final String fileName;

  /// 本地镜像文件绝对路径。
  final String filePath;

  /// 文件字节数。
  final int fileSize;

  /// 最后修改时间（本地文件 mtime）。
  final DateTime? lastModified;

  /// 本地文件 SHA-256（hex 小写，64 字符）。null = 尚未计算。
  String? sha256;

  /// 服务器同名文件的 SHA-256（来自当前连接服务器的列表，可能为 null）。
  String? serverSha256;

  /// 服务器 ~mods 是否存在同名文件。
  bool onServer;

  /// 用户备注（来自服务器端 mods_meta.json / 单库缓存，跟随服务器）。
  String notes;

  /// 是否参与下次同步（本地镜像的「启用开关」，与模组管理同款）。
  /// false = 跳过该 mod 的上传，服务器端保持现状不被同步。
  bool enabled;

  /// 本地标签（用户可在镜像视图编辑，存 per-server `mirror_meta.json`，
  /// 与主 ~mods 的 mods_meta.json 语义对称）。
  List<String> tags;

  /// 冲突详情：冲突资源路径 → 也包含该路径的其他镜像文件（排除自身）。
  /// 由 [ServerSftpService.scanMirrorConflicts] 填充并持久化到 mirror_meta.json，
  /// 重启/切页不丢失；点击冲突徽章据此展示与哪些 mod 文件冲突。
  Map<String, List<String>> conflicts;

  ServerMirrorEntry({
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    this.lastModified,
    this.sha256,
    this.serverSha256,
    this.onServer = false,
    this.notes = '',
    this.enabled = true,
    this.tags = const [],
    this.conflicts = const {},
  });

  /// 格式化文件大小，与 [ServerModEntry.fileSizeFormatted] 一致。
  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 冲突数。
  int get conflictCount => conflicts.length;

  /// 是否有冲突。
  bool get hasConflict => conflicts.isNotEmpty;

  /// 冲突路径列表（供 Tooltip / 摘要使用）。
  List<String> get conflictPaths => conflicts.keys.toList();

  /// 镜像校验状态（本地副本 vs 服务器）:
  /// - `disabled`  — 已停用（不参与下次同步）
  /// - `synced`    — 服务器存在同名且 SHA-256 一致（与服务器同步）
  /// - `modified`  — 服务器存在同名但 SHA-256 不一致（本地已修改，待上传）
  /// - `new`       — 服务器无同名（仅本地镜像，待上传）
  /// - `unknown`   — 尚未比对（本地哈希未算 / 服务器哈希未知）
  String get mirrorStatus {
    if (!enabled) return 'disabled';
    if (sha256 == null) return 'unknown';
    if (!onServer) return 'new';
    if (serverSha256 == null) return 'unknown';
    return sha256 == serverSha256 ? 'synced' : 'modified';
  }
}
