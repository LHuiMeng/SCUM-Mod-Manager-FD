/// SCUM Mod Registry HTTP 只读客户端。
///
/// 从远端 registry 服务获取 mod 列表并下载 PAK 文件。仅支持 GET 操作
/// （list + download），无上传/删除能力。
///
/// ## 云上 mod 获取地址（统一收进 config.json，无独立 cloud_sources.json）
///
/// 出厂默认地址规则：`{base_url}/mods/<id>/download`。base_url 读
/// `{exe_dir}/config.json` 的 `cloud_sources.base_url` 节点：
/// - 段缺失或 base_url 留空 → 启动时自动写入打包默认地址（见
///   [ensureCloudSourceConfigured]）——所以「没写什么也能扫到服务器」？不会：
///   默认地址由打包者决定，用户不配时用打包默认，配了非空地址则尊重用户。
/// - 用户已在 config.json 配了 base_url（非空）→ 更新版本时**不覆盖**。
/// - 打包者在发布时注入 `REGISTRY_FORCE_OVERRIDE=true`（强覆盖指令）→
///   启动时无条件用打包默认地址覆盖用户配置（换源/迁移场景）。
///
/// 单 mod 自定义下载地址：
/// - `mods.<id>.download_url`：非空时单独指定该 mod 的下载地址；
/// - `mods.<id>.download_url` 为**空字符串** = 显式表示「未配置地址」，
///   此时面板会对该 mod 显示文字指引，告诉用户如何编辑 config.json。
///
/// 旧版独立 `cloud_sources.json` 会在启动时自动迁入 config.json 后删除
/// （见 [migrateLegacySourcesFile]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/download_result.dart';
import '../models/remote_mod_entry.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'mod_service.dart';

class RegistryClient {
  /// 打包默认 registry 服务基础地址（用户未配置 base_url 时生效）。
  ///
  /// 打包者可在发布时用 `--dart-define=REGISTRY_BASE_URL=...` 注入自定义
  /// 地址（build_release.ps1 支持 -RegistryUrl 参数）；缺省为空字符串 =
  /// 「无默认云源」：不写死任何服务地址，云上mod 面板显示空列表。
  /// 对外分发版不注入本变量 → 天然不连接任何私有服务器。
  /// **不内置独立配置文件** —— 地址统一写进 config.json 的
  /// cloud_sources.base_url 由应用统一读取。
  static const String _defaultBaseUrl = String.fromEnvironment(
    'REGISTRY_BASE_URL',
    defaultValue: '',
  );

  /// 打包者强覆盖指令：本次发布若注入 `REGISTRY_FORCE_OVERRIDE=true`，
  /// 启动时无条件用 [_defaultBaseUrl] 覆盖 config.json 里已有的
  /// cloud_sources.base_url（换源/迁移场景）。不注入 = 尊重用户配置。
  static const bool _forceOverride = bool.fromEnvironment(
    'REGISTRY_FORCE_OVERRIDE',
    defaultValue: false,
  );

  /// 超时时间。
  static const Duration _timeout = Duration(seconds: 30);

  // ===== config.json 统一读写（云源段） =====

  /// config.json 路径（与 ModService 同源，统一收口）。
  static String get _configPath =>
      p.join(AppPaths.instance.root, 'config.json');

  /// 旧版独立云源配置文件路径（一次性迁移用）。
  static String get _legacySourcesPath => p.join(
    AppPaths.instance.root,
    'cloud_sources.json',
  );

  /// 读取并解析 config.json（失败返回空 Map）。
  static Map<String, dynamic> _config() {
    try {
      final f = File(_configPath);
      if (!f.existsSync()) return {};
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map<String, dynamic>) return raw;
    } catch (_) {}
    return {};
  }

  /// 写入整个 config.json（2 空格缩进，与 ModService 风格一致）。
  static void _saveConfig(Map<String, dynamic> data) {
    try {
      File(
        _configPath,
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    } catch (_) {}
  }

  /// 当前云源配置段（config.json `cloud_sources`），失败返回空 Map。
  static Map<String, dynamic> _sources() {
    final cs = _config()['cloud_sources'];
    if (cs is Map<String, dynamic>) return cs;
    return {};
  }

  /// 启动合并云源配置进 config.json（统一读取，不再有独立配置文件）：
  ///
  /// 1. config.json 无 `cloud_sources` 段 → 写入 `{base_url: <打包默认>, mods: {}}`；
  /// 2. 段存在但 base_url 为空 → 补打包默认地址；
  /// 3. 段存在且 base_url 非空 → **保留用户配置，不覆盖**；
  /// 4. 打包者强覆盖指令 [REGISTRY_FORCE_OVERRIDE] 为 true → 无条件用打包
  ///    默认地址覆盖 base_url（mods 单 mod 覆盖地址保留，不受指令影响）。
  static void ensureCloudSourceConfigured(ModService svc) {
    try {
      final existing = svc.loadConfigKey('cloud_sources');
      final cs = existing is Map<String, dynamic>
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      final base = (cs['base_url'] as String?)?.trim() ?? '';
      final modsPresent = cs.containsKey('mods');
      if (_forceOverride && _defaultBaseUrl.isNotEmpty) {
        // 强覆盖指令：打包者换源 → 无条件用打包默认地址。
        // （打包默认地址为空时强覆盖无意义，跳过 —— 对外版不注入域名）
        cs['base_url'] = _defaultBaseUrl;
        AppLogger.instance.info('云源强覆盖指令生效（REGISTRY_FORCE_OVERRIDE）', {
          'base_url': _defaultBaseUrl,
        });
      } else if (base.isEmpty && _defaultBaseUrl.isNotEmpty) {
        // 用户未配置（段缺失 / base_url 留空）→ 补打包默认地址。
        // （打包默认地址为空 = 对外版无默认云源，不写任何地址）
        cs['base_url'] = _defaultBaseUrl;
        AppLogger.instance.info('云源地址已写入 config.json（打包默认）', {
          'base_url': _defaultBaseUrl,
        });
      }
      // 保证 mods 节点存在（用户自定义单 mod 地址从这里读）。
      if (!modsPresent) cs['mods'] = <String, dynamic>{};
      svc.saveConfigKey('cloud_sources', cs);
    } catch (e) {
      AppLogger.instance.warning('云源配置合入 config.json 失败', {
        'error': e.toString(),
      });
    }
  }

  /// 一次性迁移：旧版独立 `cloud_sources.json` 并入 config.json 后删除。
  ///
  /// 合并规则（config.json 优先，空缺才从旧文件补）：
  /// - config.json 无 cloud_sources 段 → 旧文件整体作为该段；
  /// - 段已存在 → base_url 若为空则用旧文件非空值；mods 键级合并（旧文件
  ///   中未出现的 id 补入，已存在的以 config 为准）。
  /// - 旧文件不存在 → 无操作（首次使用新版本 / 已迁移过）。
  static void migrateLegacySourcesFile() {
    final legacy = File(_legacySourcesPath);
    if (!legacy.existsSync()) return;
    try {
      final raw = jsonDecode(legacy.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        legacy.deleteSync();
        return;
      }
      final cfg = _config();
      final existing = cfg['cloud_sources'];
      final merged = existing is Map<String, dynamic>
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      // base_url：config 空缺才补旧文件值。
      final base = (merged['base_url'] as String?)?.trim() ?? '';
      final legacyBase = (raw['base_url'] as String?)?.trim() ?? '';
      if (base.isEmpty && legacyBase.isNotEmpty)
        merged['base_url'] = legacyBase;
      // mods：键级合并（config 已有键优先）。
      final legacyMods = raw['mods'];
      if (legacyMods is Map) {
        final mods = merged['mods'] is Map
            ? Map<String, dynamic>.from(merged['mods'] as Map)
            : <String, dynamic>{};
        legacyMods.forEach((k, v) {
          if (!mods.containsKey(k)) mods['$k'] = v;
        });
        merged['mods'] = mods;
      }
      if (!merged.containsKey('mods')) merged['mods'] = <String, dynamic>{};
      cfg['cloud_sources'] = merged;
      _saveConfig(cfg);
      legacy.deleteSync();
      AppLogger.instance.info('旧版 cloud_sources.json 已迁入 config.json', {
        'path': _legacySourcesPath,
      });
    } catch (e) {
      AppLogger.instance.warning('旧版 cloud_sources.json 迁移失败（忽略）', {
        'error': e.toString(),
      });
    }
  }

  // ===== 读取生效配置 =====

  /// 当前生效的 registry 基础地址（config.json `cloud_sources.base_url`
  /// 非空则用之，否则打包默认 —— 「打包默认，用户可改，改后不覆盖」）。
  static String get effectiveBaseUrl {
    final b = _sources()['base_url'];
    if (b is String && b.trim().isNotEmpty) return b.trim();
    return _defaultBaseUrl;
  }

  /// 某云上 mod 的自定义下载地址（config.json `cloud_sources.mods.<id>`）。
  /// 返回 null 表示用户未单独配置。
  static String? customDownloadUrlFor(RemoteModEntry mod) {
    final mods = _sources()['mods'];
    if (mods is Map) {
      final entry = mods[mod.id];
      if (entry is Map) {
        final u = entry['download_url'];
        if (u is String && u.trim().isNotEmpty) return u.trim();
      }
    }
    return null;
  }

  /// 是否存在对应云端 manifest 提供的直达下载地址（`download_url` 字段）。
  static String? manifestDownloadUrlFor(RemoteModEntry mod) {
    final u = mod.downloadUrl;
    if (u != null && u.trim().isNotEmpty) return u.trim();
    return null;
  }

  /// 该 mod 的最终下载地址（用户覆盖 > manifest 直达 > 默认拼接）。
  /// 恒有值 —— 打包默认地址规则保证了兜底。
  static String downloadUrlFor(RemoteModEntry mod) {
    final custom = customDownloadUrlFor(mod);
    if (custom != null) return custom;
    final manifest = manifestDownloadUrlFor(mod);
    if (manifest != null) return manifest;
    final base = effectiveBaseUrl;
    if (base.isEmpty) return ''; // 无云源 → 无默认拼接地址
    return '$base/mods/${mod.id}/download';
  }

  /// 是否「未配置获取地址」：用户在 config.json 里把该 mod 的
  /// download_url 显式留空（表示不使用任何默认地址）。此时面板应显示
  /// 文字指引，告诉用户如何编辑 config.json。
  static bool isDownloadUnconfigured(RemoteModEntry mod) {
    final mods = _sources()['mods'];
    if (mods is Map) {
      final entry = mods[mod.id];
      if (entry is Map) {
        final u = entry['download_url'];
        if (u is String) return u.trim().isEmpty;
      }
    }
    return false;
  }

  /// 云源配置文件路径（config.json；面板「如何添加」提示里展示给用户）。
  static String get sourcesFilePath => _configPath;

  /// 获取远端 mod 列表。
  ///
  /// 返回 [RemoteModEntry] 列表，按名称排序。
  /// 网络错误或 JSON 解析失败时返回空列表（不抛异常），并把异常详情
  /// （类型 + message + URL + 状态码）写入 AppLogger 便于上层诊断。
  static Future<List<RemoteModEntry>> fetchModList() async {
    final base = effectiveBaseUrl;
    if (base.isEmpty) {
      // 无默认云源（对外版 / 未配置）→ 不发起任何网络请求，返回空列表。
      AppLogger.instance.info('云源未配置（base_url 为空），跳过云目录拉取');
      return [];
    }
    final uri = Uri.parse('$base/mods');
    try {
      final response = await http.get(uri).timeout(_timeout);
      AppLogger.instance.info('云上 mod 目录 HTTP 响应', {
        'status': response.statusCode,
        'url': uri.toString(),
      });
      if (response.statusCode != 200) {
        AppLogger.instance.error('云上 mod 目录 HTTP 非 200', {
          'status': response.statusCode,
          'url': uri.toString(),
        });
        return [];
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>?;
      if (body == null) {
        AppLogger.instance.error('云上 mod 目录响应不是 JSON 对象', {
          'url': uri.toString(),
          'body_preview': response.body.substring(0, 200),
        });
        return [];
      }

      final modsJson = body['mods'] as List<dynamic>?;
      if (modsJson == null) return [];

      final list = modsJson
          .map((e) => RemoteModEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => a.name.compareTo(b.name));
      return list;
    } catch (e) {
      AppLogger.instance.error('云上 mod 目录请求失败', {
        'url': uri.toString(),
        'error': e.toString(),
        'error_type': e.runtimeType.toString(),
      });
      return [];
    }
  }

  /// 下载指定 mod 的 PAK 文件到 [destPath]（v2.6+ 分段多线程 + 进度 + 失败归因）。
  ///
  /// 下载地址按 [downloadUrlFor] 解析（用户自定义优先）。若该 mod 被
  /// 标记为「未配置地址」，直接返回失败原因（面板层会先展示提示）。
  ///
  /// 大文件（≥1MB）自动分段并发下载（HTTP Range，默认 4 段，总时间降到
  /// 单段耗时而非串行总和）；服务器不支持分段时退化为单流下载。
  ///
  /// [onProgress] 每秒/每块回调已收字节与总字节（用于按钮进度展示）。
  /// 返回 [DownloadResult]：失败时带用户可读原因（超时 / HTTP 码 /
  /// 数据不完整 / 网络错误等）。
  static Future<DownloadResult> downloadMod(
    RemoteModEntry mod,
    String destPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (isDownloadUnconfigured(mod)) {
      AppLogger.instance.warning('云上 mod 未配置获取地址，跳过下载', {'remote_id': mod.id});
      return const DownloadResult(ok: false, error: '该 mod 未配置获取地址');
    }
    final url = downloadUrlFor(mod);
    if (url.isEmpty) {
      // 无云源（对外版 / base_url 未配置）→ 不发起任何请求。
      AppLogger.instance.warning('云源未配置，跳过下载', {'remote_id': mod.id});
      return const DownloadResult(ok: false, error: '云源未配置，无法下载');
    }
    final uri = Uri.parse(url);
    AppLogger.instance.info('云上 mod 下载开始', {
      'remote_id': mod.id,
      'url': uri.toString(),
      'destination': destPath,
    });
    try {
      // 探测总长度 + Range 支持（Range: bytes=0-0 → 206 表示支持分段）。
      final probe = await _probeDownload(uri);
      if (!probe.rangeOk || probe.total <= 0) {
        // 服务器不支持分段 → 单流下载（仍报进度，失败可归因）。
        return _downloadStream(
          uri,
          destPath,
          probe.total,
          onProgress: onProgress,
        );
      }
      // 大文件才分段（小文件分段开销不值得）。
      const maxParts = 4;
      final parts = probe.total >= 1024 * 1024 ? maxParts : 1;
      if (parts == 1) {
        return _downloadStream(
          uri,
          destPath,
          probe.total,
          onProgress: onProgress,
        );
      }
      return _downloadParallel(
        uri,
        destPath,
        probe.total,
        parts,
        onProgress: onProgress,
      );
    } catch (e) {
      AppLogger.instance.error('云上 mod 下载请求失败', {
        'remote_id': mod.id,
        'destination': destPath,
        'error': e.toString(),
        'error_type': e.runtimeType.toString(),
      });
      return DownloadResult(ok: false, error: _friendlyError(e));
    }
  }

  /// 探测资源：返回总字节数与是否支持分段（Range）。
  static Future<({int total, bool rangeOk})> _probeDownload(Uri uri) async {
    try {
      final resp = await http
          .get(uri, headers: const {'Range': 'bytes=0-0'})
          .timeout(_timeout);
      if (resp.statusCode == 206) {
        final cr = resp.headers['content-range']; // "bytes 0-0/12345"
        if (cr != null) {
          final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
          final total = m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
          return (total: total, rangeOk: true);
        }
      }
      // 不响应 Range → 读 content-length 做单流总长（0 = 未知）。
      final cl = resp.headers['content-length'];
      final len = cl != null ? (int.tryParse(cl) ?? 0) : 0;
      return (total: len, rangeOk: false);
    } catch (_) {
      return (total: 0, rangeOk: false);
    }
  }

  /// 单流下载（服务器不支持分段 / 文件小）。流式写盘、报进度、失败归因。
  static Future<DownloadResult> _downloadStream(
    Uri uri,
    String destPath,
    int expectedTotal, {
    void Function(int received, int total)? onProgress,
  }) async {
    var received = 0;
    try {
      final resp = await http.Request('GET', uri).send().timeout(_timeout);
      if (resp.statusCode != 200) {
        return DownloadResult(
          ok: false,
          error: '服务器响应 HTTP ${resp.statusCode}',
        );
      }
      if (expectedTotal <= 0) {
        final cl = resp.headers['content-length'];
        expectedTotal = cl != null ? (int.tryParse(cl) ?? 0) : 0;
      }
      final destFile = File(destPath);
      await destFile.parent.create(recursive: true);
      final sink = destFile.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (expectedTotal > 0) onProgress?.call(received, expectedTotal);
      }
      await sink.close();
      if (expectedTotal > 0 && received != expectedTotal) {
        try {
          if (File(destPath).existsSync()) File(destPath).deleteSync();
        } catch (_) {}
        return DownloadResult(
          ok: false,
          error: '文件不完整：$received/$expectedTotal 字节',
        );
      }
      return const DownloadResult.success();
    } catch (e) {
      try {
        if (File(destPath).existsSync()) File(destPath).deleteSync();
      } catch (_) {}
      return DownloadResult(ok: false, error: _friendlyError(e));
    }
  }

  /// 分段并发下载：N 段 Range 请求并行，各自写分片，完成合并 + 校验。
  static Future<DownloadResult> _downloadParallel(
    Uri uri,
    String destPath,
    int total,
    int parts, {
    void Function(int received, int total)? onProgress,
  }) async {
    final partPath = (int i) => '$destPath.part$i';
    final chunkSize = (total / parts).ceil();
    final receivedPerPart = List<int>.filled(parts, 0);

    Future<({int received, String? error})> fetchPart(int i) async {
      final start = i * chunkSize;
      final end = i == parts - 1 ? total - 1 : start + chunkSize - 1;
      var received = 0;
      try {
        final req = http.Request('GET', uri)
          ..headers['Range'] = 'bytes=$start-$end';
        final resp = await req.send().timeout(_timeout);
        if (resp.statusCode != 206 && resp.statusCode != 200) {
          return (received: 0, error: '分段 $i 响应 HTTP ${resp.statusCode}');
        }
        final sink = File(partPath(i)).openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          receivedPerPart[i] = received;
          onProgress?.call(receivedPerPart.fold(0, (a, b) => a + b), total);
        }
        await sink.close();
        final expect = end - start + 1;
        if (received != expect) {
          return (
            received: received,
            error: '分段 $i 数据不完整（缺 ${expect - received} 字节）',
          );
        }
        return (received: received, error: null);
      } catch (e) {
        return (received: 0, error: '分段 $i：${_friendlyError(e)}');
      }
    }

    try {
      final results = await Future.wait([
        for (var i = 0; i < parts; i++) fetchPart(i),
      ]);
      final errors = [
        for (final r in results)
          if (r.error != null) r.error!,
      ];
      if (errors.isNotEmpty) {
        _cleanupParts(destPath, parts);
        return DownloadResult(ok: false, error: '分段下载失败：${errors.join('；')}');
      }
      // 合并分片（流式，避免整块读入内存）。
      final out = File(destPath).openWrite();
      for (var i = 0; i < parts; i++) {
        await out.addStream(File(partPath(i)).openRead());
      }
      await out.close();
      _cleanupParts(destPath, parts);
      final actual = File(destPath).lengthSync();
      if (actual != total) {
        try {
          if (File(destPath).existsSync()) File(destPath).deleteSync();
        } catch (_) {}
        return DownloadResult(ok: false, error: '文件不完整：$actual/$total 字节');
      }
      return const DownloadResult.success();
    } catch (e) {
      _cleanupParts(destPath, parts);
      try {
        if (File(destPath).existsSync()) File(destPath).deleteSync();
      } catch (_) {}
      return DownloadResult(ok: false, error: _friendlyError(e));
    }
  }

  /// 删除分片文件（失败 / 合并完成后的清理）。
  static void _cleanupParts(String destPath, int parts) {
    for (var i = 0; i < parts; i++) {
      try {
        final f = File('$destPath.part$i');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// 异常 → 用户可读中文原因。
  static String _friendlyError(Object e) {
    if (e is TimeoutException) return '网络超时（30 秒无响应）';
    if (e is http.ClientException) {
      final msg = e.message;
      if (msg.contains('Connection refused')) return '连接被拒绝，服务器不可达';
      if (msg.contains('timed out')) return '网络超时';
      return '网络错误：$msg';
    }
    return '下载失败：${e.toString().split('\n').first}';
  }
}
