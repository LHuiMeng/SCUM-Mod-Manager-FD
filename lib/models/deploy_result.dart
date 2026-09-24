/// 部署结果 —— [ModService.deployMods] 复制 + 验证后返回。
///
/// v2.6 起部署后统一校验：目标文件存在且大小一致（PAK）/ 目标目录
/// 文件数与字节数与源一致（UE4SS mod）。校验不过则不启动游戏，
/// 防止「部分 mod 未复制过去导致加载失败」。
class DeployResult {
  /// 是否全部复制并验证通过（可安全启动游戏）。
  final bool ok;

  /// 部署失败（源缺失 / 复制异常 / 校验不过）的 mod 名称列表。
  final List<String> failed;

  const DeployResult({required this.ok, required this.failed});

  /// 全部成功。
  static const DeployResult success = DeployResult(ok: true, failed: []);
}
