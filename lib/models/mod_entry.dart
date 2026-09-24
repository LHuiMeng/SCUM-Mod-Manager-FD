/// SCUM 模组数据模型。
///
/// 表示扫描到的单个 .pak 文件 / UE4SS mod 文件夹的状态。
/// UI、Service、Mod 链接层共用此模型。
class ModEntry {
  /// 唯一 ID（默认 = 文件名去后缀）。
  final String id;

  /// 显示名称。
  final String name;

  /// 原始文件名（含扩展名）。UE4SS mod 时为空字符串。
  final String fileName;

  /// 原始文件 / 文件夹绝对路径。
  final String filePath;

  /// 文件字节数。UE4SS mod 时为整个文件夹累计大小。
  final int fileSize;

  /// 最后修改时间。
  final DateTime lastModified;

  /// 用户是否启用此模组。
  bool enabled;

  /// 模组类型（客户端 PAK / 服务端 PAK / UE4SS mod 等）。
  final ModType type;

  /// 可选的描述信息（从文件名或附加信息推断）。
  String description;

  // ===== MO2 风格扩展（虚拟链接 + 加载顺序） =====

  /// 加载顺序索引（0 = 最先加载，值越小优先级越低）。
  int loadOrder;

  /// 是否已通过链接部署到游戏 `~mods` 目录。
  bool deployed;

  /// 来源目录（mods/ 或外部路径）。
  /// 为空字符串时表示已在游戏 `~mods` 目录内。
  String sourceDir;

  /// 模组来源标识："local" = 本地导入, "cloud" = 从云上下载。
  /// 用于 UI 显示来源徽标（云上/本地）。
  String originSource;

  // ===== 用户自定义元数据 =====

  /// 标签列表（用于分类 / 筛选，例如 ["战斗", "生存", "载具"]）。
  List<String> tags;

  /// 用户备注（自由文本，在卡片展开时编辑）。
  String notes;

  /// 文件 SHA-256 十六进制摘要（懒计算后缓存到 mods_meta.json）。
  /// 空字符串 = 未计算；UE4SS mod（文件夹）无单文件哈希，恒为空。
  String sha256;

  /// PAK 内部资源路径清单（repak list 结果，归一化小写 + 去 `../../../` 前缀）。
  /// 冲突扫描懒加载后缓存到 mods_meta.json（`pak_entries` 字段），
  /// 内容未变不重复调 repak；UE4SS mod / 非 PAK 恒为空列表。
  List<String> pakEntries;

  // ===== UE4SS mod 扩展 =====

  /// UE4SS mod 根目录路径（仅 type == ue4ssMod 时非空）。
  /// 普通 PAK 模组此字段为空字符串。
  final String ue4ssRoot;

  /// UE4SS mod 检测到的子目录列表（如 dlls/, LogicMods/, Scripts/）。
  /// UI 副标题展示用，纯信息性。
  final List<String> ue4ssSubDirs;

  // ===============================================

  ModEntry({
    required this.id,
    required this.name,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.lastModified,
    this.enabled = true,
    this.type = ModType.clientPak,
    this.description = '',
    this.loadOrder = 0,
    this.deployed = false,
    this.sourceDir = '',
    this.originSource = 'local',
    this.tags = const [],
    this.notes = '',
    this.sha256 = '',
    this.pakEntries = const [],
    this.ue4ssRoot = '',
    this.ue4ssSubDirs = const [],
  });

  /// 复制方法：只覆盖传入的非 null 字段。
  ///
  /// 注意：`tags` / `ue4ssSubDirs` 是可变 List —— 调用方省略时不能直接
  /// 共享 this.tags 引用（否则新对象 mutations 会影响老对象）。
  /// 走防御性 `List.from(...)` 拷贝，保证新旧对象隔离。
  ModEntry copyWith({
    String? id,
    String? name,
    String? fileName,
    String? filePath,
    int? fileSize,
    DateTime? lastModified,
    bool? enabled,
    ModType? type,
    String? description,
    int? loadOrder,
    bool? deployed,
    String? sourceDir,
    String? originSource,
    List<String>? tags,
    String? notes,
    String? sha256,
    List<String>? pakEntries,
    String? ue4ssRoot,
    List<String>? ue4ssSubDirs,
  }) {
    return ModEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      lastModified: lastModified ?? this.lastModified,
      enabled: enabled ?? this.enabled,
      type: type ?? this.type,
      description: description ?? this.description,
      loadOrder: loadOrder ?? this.loadOrder,
      deployed: deployed ?? this.deployed,
      sourceDir: sourceDir ?? this.sourceDir,
      originSource: originSource ?? this.originSource,
      tags: tags != null
          ? List<String>.from(tags)
          : List<String>.from(this.tags),
      notes: notes ?? this.notes,
      sha256: sha256 ?? this.sha256,
      pakEntries: pakEntries != null
          ? List<String>.from(pakEntries)
          : List<String>.from(this.pakEntries),
      ue4ssRoot: ue4ssRoot ?? this.ue4ssRoot,
      ue4ssSubDirs: ue4ssSubDirs != null
          ? List<String>.from(ue4ssSubDirs)
          : List<String>.from(this.ue4ssSubDirs),
    );
  }

  /// 格式化文件大小（KB / MB / GB），便于 UI 直接显示。
  String get fileSizeFormatted {
    if (fileSize < _bytesPerKB) return '$fileSize B';
    if (fileSize < _bytesPerMB) {
      return '${(fileSize / _bytesPerKB).toStringAsFixed(1)} KB';
    }
    if (fileSize < _bytesPerGB) {
      return '${(fileSize / _bytesPerMB).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / _bytesPerGB).toStringAsFixed(2)} GB';
  }

  /// 根据 [sourceDir] 推断来源：
  /// - 非空 → [ModSource.external]（来自管理器自有目录，需链接）
  /// - 空 → [ModSource.gameDir]（已在游戏 ~mods 目录内）
  ModSource get source =>
      sourceDir.isNotEmpty ? ModSource.external : ModSource.gameDir;

  /// 是否是从云上下载的模组。
  bool get isCloudMod => originSource == 'cloud';

  /// 是否是 UE4SS 模组（文件夹形式，部署时整体复制到游戏目录）。
  bool get isUe4ssMod => type == ModType.ue4ssMod;

  // ===== 容量单位常量 =====
  static const int _bytesPerKB = 1024;
  static const int _bytesPerMB = 1024 * 1024;
  static const int _bytesPerGB = 1024 * 1024 * 1024;
}

/// 模组类型。
enum ModType {
  /// 客户端 PAK 模组（.pak，放到客户端 ~mods/）
  clientPak,

  /// 服务端 PAK 模组（.pak，放到服务端 ~mods/）
  serverPak,

  /// UE4SS mod（文件夹形式，整体复制到游戏目录的 UE4SS 子目录）
  ue4ssMod,

  /// 配置文件（.ini）
  configFile,

  /// 脚本/工具类。
  script,

  /// 其他未分类文件。
  other,
}

/// 模组来源。
enum ModSource {
  /// 来自管理器自己的 mods/ 目录（需链接部署）。
  external,

  /// 已在游戏 ~mods 目录内（无需再链接）。
  gameDir,
}
