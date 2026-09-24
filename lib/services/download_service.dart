/// 在线更新 —— 下载服务（含 sha256 校验 + 进度回调）。
///
/// 设计：
/// - 走 `http.Client.send()` 而非 `http.get()`，方便读 chunked response。
/// - 下载中把进度写到 `AppSignals.updateProgress`（0.0 ~ 1.0）。
/// - 下载完算文件 sha256，与 manifest.exeSha256 (ZIP) 比对。
/// - 校验通过：标记 `AppSignals.updateDownloaded = true`，按钮切到「点击安装」态。
/// - 校验失败：删除文件 + reset 进度，让用户下次再点。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';
import 'app_signals.dart';
import 'update_service.dart';

class DownloadService {
  DownloadService._();

  /// 下载 + 校验一条龙。
  ///
  /// 失败一律返回 false，已下载部分会清掉，UI 回到默认态。
  /// 下载 + 校验一条龙（完整包）。
  static Future<bool> downloadAndVerify(UpdateManifest m) async {
    return _downloadTo(
      UpdateService.resolveExeUrl(m.exeUrl).toString(),
      UpdateService.downloadPath(),
      UpdateService.partPath(),
      m.exeSha256,
      m.exeSizeBytes,
      '完整更新包 v${m.version}',
    );
  }

  /// 下载 + 校验一条龙（v3.1 增量包，轻量化）。
  static Future<bool> downloadDeltaAndVerify(
      UpdateManifest m, DeltaManifest dm) async {
    return _downloadTo(
      UpdateService.resolveDeltaUrl(dm.deltaUrl).toString(),
      UpdateService.deltaPath(),
      UpdateService.deltaPartPath(),
      dm.deltaSha256,
      dm.deltaSizeBytes,
      '增量更新包 v${dm.base}->v${m.version}',
    );
  }

  /// 通用下载核心：part 两阶段下载 → sha256 校验 → rename 落位。
  static Future<bool> _downloadTo(
    String url,
    String destPath,
    String partPath,
    String expectedSha,
    int expectedSize,
    String label,
  ) async {
    AppLogger.instance.info('开始下载 $label', {
      'url': url,
      'dest': destPath,
      'expected_size': expectedSize,
      'expected_sha256': expectedSha,
    });

    AppSignals.updateProgress.value = 0.0;

    // 1) 下载到 part 临时文件 —— 防止半截残留。整个 IO 阶段包 try-catch，
    //    确保 req.send() 抛异常（如超时、网络断）时 partFile / sink
    //    都能正确关闭 + 删除，不留文件句柄泄漏。
    IOSink? sink;
    File? partFile;
    try {
      partFile = File(partPath);
      if (await partFile.exists()) await partFile.delete();
      sink = partFile.openWrite();

      final req = http.Request('GET', Uri.parse(url));
      final resp = await req.send().timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) {
        AppLogger.instance.error('下载 HTTP 非 200', {
          'status': resp.statusCode,
          'url': url,
        });
        return false;
      }

      final totalBytes = resp.contentLength ?? expectedSize;
      var received = 0;

      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (totalBytes > 0) {
          AppSignals.updateProgress.value = received / totalBytes;
        } else {
          // 没 content-length 时只置一个 indeterminate（0.5 闪动）
          AppSignals.updateProgress.value =
              (AppSignals.updateProgress.value ?? 0.0) + 0.05;
          if (AppSignals.updateProgress.value! >= 1.0) {
            AppSignals.updateProgress.value = 0.5;
          }
        }
        // 让出事件循环，避免大批量下载卡 UI
        await Future<void>.delayed(Duration.zero);
      }
      await sink.close();
      sink = null; // 已关闭，避免 finally 重复 close 抛异常

      AppLogger.instance.info('下载完成，开始校验', {
        'received_bytes': received,
        'expected_bytes': totalBytes,
        'label': label,
      });

      // 2) sha256 校验
      final ok = await _verifySha256(partPath, expectedSha);
      if (!ok) {
        // 校验失败 → 删除 part 文件 + 不改名
        try {
          await partFile.delete();
        } catch (_) {}
        AppSignals.updateProgress.value = null;
        return false;
      }

      // 3) 校验通过 → rename part → 正式文件名
      // 用 rename 而不是 copy：避免老文件残留
      try {
        if (await File(destPath).exists()) {
          await File(destPath).delete();
        }
        await partFile.rename(destPath);
      } catch (e) {
        AppLogger.instance.error('rename 更新文件失败', {'error': e.toString()});
        AppSignals.updateProgress.value = null;
        return false;
      }

      AppSignals.updateProgress.value = null;
      AppSignals.updateDownloaded.value = true;
      AppLogger.instance.info('更新下载完成且校验通过', {
        'label': label,
        'path': destPath,
        'size': received,
      });
      return true;
    } catch (e) {
      AppLogger.instance.error('更新下载异常', {'error': e.toString()});
      return false;
    } finally {
      // 兜底：异常分支（req.send 超时、网络断开）关闭未关闭的 sink
      // + 删除未完成的 part 文件，避免文件句柄泄漏 + 残留。
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (partFile != null && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      AppSignals.updateProgress.value = null;
    }
  }


  /// 读文件算 sha256（hex）并与 manifest.exeSha256 比对（小写归一化）。
  static Future<bool> _verifySha256(String path, String expectedHex) async {
    if (expectedHex.isEmpty) return false;
    try {
      final stream = File(path).openRead();
      final digest = await sha256.bind(stream).first;
      final actualHex = digest.toString(); // 默认 hex 小写
      final match =
          actualHex.toLowerCase() == expectedHex.toLowerCase();
      if (!match) {
        AppLogger.instance.error('sha256 校验失败', {
          'expected': expectedHex,
          'actual': actualHex,
        });
      }
      return match;
    } catch (e) {
      AppLogger.instance.error('sha256 校验异常', {'error': e.toString()});
      return false;
    }
  }
}