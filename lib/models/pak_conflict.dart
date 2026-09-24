/// PAK 模组冲突数据模型。
///
/// 冲突定义：两个（及以上）**已启用**的 PAK 包含相同内部资源路径
/// （归一化小写全路径）—— 部署到游戏 `~mods` 后加载序靠后的 PAK 覆盖
/// 靠前的同名资源，被覆盖者的同名资源实际不生效。
library;

/// 一组冲突：一个资源路径同时被多个 mod 包含。
class PakConflictGroup {
  /// 归一化资源路径（小写、已去除 `../../../` 前缀）。
  final String path;

  /// 涉及冲突的 mod id 列表（按加载序升序）。
  final List<String> modIds;

  const PakConflictGroup({required this.path, required this.modIds});

  /// 同时包含此路径的 mod 数。
  int get count => modIds.length;
}

/// 一次完整冲突扫描的报告。
class ConflictReport {
  /// 冲突组列表（按路径字母序排列，方便检索）。
  final List<PakConflictGroup> groups;

  /// 参与扫描的已启用 PAK 数量。
  final int scannedModCount;

  const ConflictReport({required this.groups, required this.scannedModCount});

  /// 参与冲突的资源路径总数。
  int get totalConflictPaths => groups.length;

  /// 至少参与一个冲突的 mod id 集合。
  Set<String> get conflictedModIds {
    final set = <String>{};
    for (final g in groups) {
      set.addAll(g.modIds);
    }
    return set;
  }

  /// 该 mod 是否参与冲突。
  bool hasConflictFor(String modId) =>
      groups.any((g) => g.modIds.contains(modId));

  /// 该 mod 参与冲突的资源路径数量。
  int countFor(String modId) {
    var n = 0;
    for (final g in groups) {
      if (g.modIds.contains(modId)) n++;
    }
    return n;
  }

  /// 该 mod 参与的所有冲突组（详情面板按路径展示用）。
  List<PakConflictGroup> groupsFor(String modId) =>
      [for (final g in groups) if (g.modIds.contains(modId)) g];
}