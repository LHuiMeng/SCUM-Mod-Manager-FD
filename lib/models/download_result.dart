/// 云上 mod 下载结果 —— 成功或带用户可读失败原因。
///
/// v2.6 起下载失败不再是哑 bool：面板据此展示「为什么下载失败」
/// （网络超时 / HTTP 状态码 / 数据不完整 / 服务器不支持分段等）。
class DownloadResult {
  /// 是否成功。
  final bool ok;

  /// 失败原因（用户可读中文；ok 时为 null）。
  final String? error;

  const DownloadResult({required this.ok, this.error});

  /// 成功。
  const DownloadResult.success() : ok = true, error = null;
}
