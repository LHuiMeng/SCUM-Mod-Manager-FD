/// 在线更新 manifest 拉取 + 校验服务。
///
/// 数据源：打包者在发布时用 `--dart-define=UPDATE_MANIFEST_URL=...` 注入
/// manifest 地址（build_release.ps1 注入）；缺省为空字符串 = 无更新源：
/// 启动检查静默跳过、更新按钮永不出现。对外分发版不注入本变量 →
/// 天然不连接任何私有服务器。
///
/// 字段契约：
/// ```json
/// {
///   "version": "2.5.0",
///   "build": 5,
///   "released_at": "2026-08-14T13:00:00Z",
///   "exe_url": "/app/v2.5.0/scum_mod_manager.exe",
///   "exe_sha256": "9b2f...",
///   "exe_size_bytes": 130000,
///   "changelog": "修复云 mod 列表滚动\\n新增在线更新",
///   "signature": "<HMAC-SHA256(...) base64>"
/// }
/// ```
///
/// HMAC 校验：客户端只验证服务端签名的合法性（base64 解码后比对
/// SHA-256(canonical_fields)）。HMAC key 仅服务端持有，**绝不会**下发
/// 到客户端——这避免了"签名泄露"的常见风险。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_paths.dart';
import 'app_signals.dart';
import 'app_version.dart';

/// 远端 manifest 解析结果。
class UpdateManifest {
  final String version;
  final int build;
  final String releasedAt;
  final String exeUrl; // 可能是相对路径（拼 baseUrl）或绝对 URL
  final String exeSha256; // 64 字符 hex
  final int exeSizeBytes;
  final String changelog;
  final String signatureB64;

  const UpdateManifest({
    required this.version,
    required this.build,
    required this.releasedAt,
    required this.exeUrl,
    required this.exeSha256,
    required this.exeSizeBytes,
    required this.changelog,
    required this.signatureB64,
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> j) {
    return UpdateManifest(
      version: (j['version'] as String?) ?? '0.0.0',
      build: (j['build'] as num?)?.toInt() ?? 0,
      releasedAt: (j['released_at'] as String?) ?? '',
      exeUrl: (j['exe_url'] as String?) ?? '',
      exeSha256: (j['exe_sha256'] as String?) ?? '',
      exeSizeBytes: (j['exe_size_bytes'] as num?)?.toInt() ?? 0,
      changelog: (j['changelog'] as String?) ?? '',
      signatureB64: (j['signature'] as String?) ?? '',
    );
  }

  /// 拼接待签名的 canonical 字符串。
  ///
  /// 必须与服务端签名算法一致：按字段名升序排序后用 `\n` 连接
  /// `<field>=<value>`，再对该字节流算 HMAC-SHA256（key 见 [_hmacKey]）。
  String canonicalString() {
    // 字段顺序固定，方便对齐服务端。空值用空字符串占位避免歧义。
    final parts = <String>[
      'build=$build',
      'changelog=${_escape(changelog)}',
      'exe_sha256=$exeSha256',
      'exe_size_bytes=$exeSizeBytes',
      'exe_url=$exeUrl',
      'released_at=$releasedAt',
      'version=$version',
    ];
    return parts.join('\n');
  }

  /// changelog 可能含换行 → 转义为 \\n，确保 canonical 拼接无歧义。
  static String _escape(String s) {
    return s.replaceAll('\\', '\\\\').replaceAll('\n', '\\n');
  }
}

/// 在线更新服务（无状态 —— 所有中间态走 AppSignals ValueNotifier）。
class UpdateService {
  UpdateService._();

  /// manifest 端点（打包者注入；空 = 无更新源，跳过一切检查）。
  static const String _manifestUrl = String.fromEnvironment(
    'UPDATE_MANIFEST_URL',
    defaultValue: '',
  );

  /// 当前 manifest 端点（供 update_button 下载前复用，避免两处漂移）。
  static String get manifestUrl => _manifestUrl;

  /// 是否配置了更新源（对外版未注入 → false → 更新链路整体跳过）。
  static bool get hasUpdateSource => _manifestUrl.isNotEmpty;

  /// 当前客户端版本 —— 统一走 [AppVersion]（编译期 dart-define 注入）。
  ///
  /// 注入方式：build 时 `--dart-define=APP_VERSION=x.y.z`（见 [AppVersion]）。
  static const String _currentVersion = AppVersion.value;

  /// HMAC 签名 key（hex）—— 仅客户端拿来 *验证* 服务端签名。
  ///
  /// **这是 public verify key**（仅做 verify，不做 sign），不构成密钥泄露——
  /// 服务端签名 key 永远不会出现在客户端。但主人原话铁律要求
  /// 「token 不能明文发送」，因此 **不写死在源码里**，而是通过
  /// `--dart-define-from-file=update_secret.json` 在编译期注入：
  ///
  /// ```json
  /// { "UPDATE_VERIFY_KEY": "<64 hex chars>" }
  /// ```
  ///
  /// `update_secret.json` 已加入 .gitignore，绝不进仓库。
  /// 未注入时（defaultValue=''）→ 校验一律失败 → 更新按钮不出现（安全降级）。
  static const String _verifyKeyHex = String.fromEnvironment(
    'UPDATE_VERIFY_KEY',
    defaultValue: '',
  );

  /// 解析后的 32 字节 key（hex → bytes）。
  static List<int> get verifyKey {
    final hex = _verifyKeyHex;
    if (hex.isEmpty || hex.length != 64) {
      // 未注入 / 非法 → 空 key，HMAC 校验必然失败（安全降级）
      return List<int>.filled(32, 0);
    }
    final bytes = <int>[];
    for (var i = 0; i < 64; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String get currentVersion => _currentVersion;

  /// 启动时调用一次：拉 manifest → 校验 → 写入 AppSignals。
  ///
  /// 失败 / 超时一律静默，不弹任何 toast（不打扰用户）。
  /// 下次启动会重试。
  static Future<void> checkOnStartup() async {
    if (!hasUpdateSource) {
      // 无更新源（对外版）→ 静默跳过，不发起任何网络请求。
      AppSignals.updateAvailable.value = false;
      return;
    }
    try {
      final manifest = await _fetchManifest();
      if (manifest == null) {
        AppSignals.updateAvailable.value = false;
        return;
      }
      // HMAC 校验
      if (!verifySignature(manifest)) {
        AppLogger.instance.error('manifest 签名校验失败', {
          'version': manifest.version,
        });
        // 签名失败时不要给用户装 —— 标记"无更新"避免被诱导去点
        AppSignals.updateAvailable.value = false;
        return;
      }
      // 版本比对
      final hasUpdate = _isNewer(manifest.version, _currentVersion);
      AppLogger.instance.info('更新检测完成', {
        'current': _currentVersion,
        'latest': manifest.version,
        'has_update': hasUpdate,
      });
      AppSignals.updateAvailable.value = hasUpdate;
      AppSignals.latestVersion.value = hasUpdate ? manifest.version : null;
    } catch (e) {
      AppLogger.instance.warning('更新检测失败（静默）', {'error': e.toString()});
      // 出错时不要把状态锁死 —— 保持 null，让标题栏不渲染按钮。
      // 下次启动会重试。
    }
  }

  static Future<UpdateManifest?> _fetchManifest() async {
    try {
      final resp = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        AppLogger.instance.warning(
          'manifest HTTP 非 200',
          {'status': resp.statusCode},
        );
        return null;
      }
      final body = jsonDecode(resp.body);
      if (body is! Map<String, dynamic>) return null;
      return UpdateManifest.fromJson(body);
    } catch (e) {
      AppLogger.instance.warning('manifest 拉取异常', {'error': e.toString()});
      return null;
    }
  }

  /// 验证服务端签名 —— HMAC-SHA256(verify_key, canonical_string) 应等于
  /// `signature` 字段的 base64 解码值。
  ///
  /// 任一步骤失败（base64 非法 / 长度不对 / 哈希不等）都返回 false。
  ///
  /// 公共 API：`update_button.dart` 下载前也要验签，避免两处独立实现漂移。
  static bool verifySignature(UpdateManifest m) {
    if (m.signatureB64.isEmpty) return false;
    try {
      final expected = base64Decode(m.signatureB64);
      final hmac = Hmac(sha256, verifyKey);
      final digest = hmac.convert(utf8.encode(m.canonicalString())).bytes;
      if (expected.length != digest.length) return false;
      // 常时间比较 —— 防止时序攻击
      var diff = 0;
      for (var i = 0; i < expected.length; i++) {
        diff |= expected[i] ^ digest[i];
      }
      return diff == 0;
    } catch (e) {
      AppLogger.instance.warning('HMAC 校验异常', {'error': e.toString()});
      return false;
    }
  }

  /// 简易 semver-ish 比较：1.0.0 < 1.0.1 < 1.1.0 < 2.0.0。
  ///
  /// 数字段不足的位置补 0，超出的截掉（与 [RemoteModEntry.compare] 同款）。
  /// 任一段无法解析为整数则视为 0。
  static bool _isNewer(String latest, String current) {
    final cmp = RemoteVersionCompare.compare(latest, current);
    return cmp > 0;
  }

  // ===== public helpers =====

  /// 把 manifest 里的 exeUrl（可能是相对路径）拼成绝对 URL。
  static Uri resolveExeUrl(String exeUrl) {
    if (exeUrl.startsWith('http://') || exeUrl.startsWith('https://')) {
      return Uri.parse(exeUrl);
    }
    final base = Uri.parse(_manifestUrl);
    return base.replace(path: exeUrl);
  }

  /// 清理旧版残留文件（%TEMP%/scum_mod_manager.update.zip + .part）。
  ///
  /// 启动时调用 —— 用户上次中断了更新 / 安装失败 / 强杀进程后，
  /// %TEMP% 里会留下半截文件，下次启动时清掉。
  ///
  /// 同时清理 `.part` 文件 —— 下载走的是 part → rename 两阶段，未完成的
  /// 下载会留下 `*.zip.part` 残留（旧版只清 .zip 会留下 .part 孤儿文件，
  /// 占 %TEMP% 空间）。
  static Future<void> cleanupStaleDownload() async {
    final paths = <String>[
      _downloadPath(),
      '${_downloadPath()}.part',
    ];
    for (final p in paths) {
      try {
        final f = File(p);
        if (await f.exists()) {
          await f.delete();
          AppLogger.instance.info('清理旧版残留更新文件', {'path': p});
        }
      } catch (_) {}
    }
  }

  /// 下载路径 —— %TEMP%/scum_mod_manager.update.zip
  static String downloadPath() => _downloadPath();

  /// 下载中临时 part 路径 —— %TEMP%/scum_mod_manager.update.zip.part
  /// 下载走 part → rename 两阶段，未完成时 part 文件留在磁盘上。
  static String partPath() => '${_downloadPath()}.part';

  static String _downloadPath() {
    final temp = Platform.environment['TEMP'] ??
        Platform.environment['TMP'] ??
        r'C:\Windows\Temp';
    return p.join(temp, 'scum_mod_manager.update.zip');
  }

  // ===== v3 架构：安装新版本（引导器 + versions/ 目录模型） =====

  /// 把已下载并校验通过的 zip 安装为新版本目录，写入 app.json 切换指针。
  ///
  /// 流程（全部在 Dart 内完成，不再需要 updater.exe）：
  ///   1) zip 移入 `{root}/versions/.staging/<ver>.zip`
  ///   2) 解压到 `{root}/versions/.staging/<ver>/`
  ///   3) 完整性校验：`data/app.so` 存在 + 版本串 == manifest.version
  ///   4) 原子提交：`.staging/<ver>` rename → `versions/<ver>`
  ///   5) 写 app.json（`current=<ver>`, `rollback=旧 current`）
  ///   6) 清理 .staging 与保留数之外的旧版本目录
  ///
  /// 全程不触碰运行中的文件（旧版本目录与用户数据均不动）——
  /// 因此无需关闭应用/游戏，error 32 一族问题在此架构下不可能发生。
  static Future<InstallResult> installDownloaded(UpdateManifest m) async {
    final root = AppPaths.instance.root;
    final ver = m.version;
    final versionsDir = p.join(root, 'versions');
    final stagingDir = p.join(versionsDir, '.staging');
    final stagingZip = p.join(stagingDir, '$ver.zip');
    final stagingVerDir = p.join(stagingDir, ver);
    final finalVerDir = p.join(versionsDir, ver);
    try {
      // 0) 记录旧 current（作 rollback 指针）
      final oldCurrent = await _readAppJsonCurrent(root);

      // 1) zip 移入 staging（跨卷 rename 会失败 → copy + delete）
      final zipFile = File(downloadPath());
      if (!await zipFile.exists()) {
        return const InstallResult(false, '下载文件不存在，请重新下载');
      }
      await Directory(stagingDir).create(recursive: true);
      final stagingZipFile = File(stagingZip);
      if (await stagingZipFile.exists()) await stagingZipFile.delete();
      if (await Directory(stagingVerDir).exists()) {
        await Directory(stagingVerDir).delete(recursive: true);
      }
      await zipFile.copy(stagingZip);
      await zipFile.delete();

      // 2) 解压
      await _unzip(stagingZip, stagingVerDir);

      // 2.5) 兼容迁移包布局（v3 首个版本发布时的特殊形态）：
      //      迁移期云端 zip 根 = 安装根（旧 updater 的信标检查需要
      //      scum_mod_manager.exe 在 zip 根），内容为
      //      {引导器, app.json, updater兼容壳, versions/<ver>/…}。
      //      若检测到嵌套目录 versions/<ver>/ 且扁平 data/app.so 不存在，
      //      把嵌套版本内容提升为 stagingVerDir 内容，再走统一校验。
      final flatAppSo = File(p.join(stagingVerDir, 'data', 'app.so'));
      final nestedVerDir = Directory(p.join(stagingVerDir, 'versions', ver));
      if (!await flatAppSo.exists() && await nestedVerDir.exists()) {
        await for (final e in nestedVerDir.list()) {
          final dest = p.join(stagingVerDir, p.basename(e.path));
          if (e is Directory) {
            if (await Directory(dest).exists()) {
              await Directory(dest).delete(recursive: true);
            }
            await Directory(e.path).rename(dest);
          } else if (e is File) {
            if (await File(dest).exists()) {
              await File(dest).delete();
            }
            await File(e.path).rename(dest);
          }
        }
        // 清理嵌套残留（versions/ 壳与迁移包根部的引导器/app.json/updater）
        final leftover = Directory(p.join(stagingVerDir, 'versions'));
        if (await leftover.exists()) {
          await leftover.delete(recursive: true);
        }
        for (final name in ['scum_mod_manager.exe', 'app.json',
            'scum_mod_manager_updater.exe']) {
          final f = File(p.join(stagingVerDir, name));
          if (await f.exists()) await f.delete();
        }
      }

      // 3) 完整性校验
      final appSo = File(p.join(stagingVerDir, 'data', 'app.so'));
      if (!await appSo.exists()) {
        return const InstallResult(false, '更新包缺少 data/app.so，安装中止');
      }
      if (!await _containsVersion(appSo, ver)) {
        return InstallResult(
            false, '更新包版本校验失败（期望 $ver），安装中止');
      }

      // 4) 原子提交
      if (await Directory(finalVerDir).exists()) {
        await Directory(finalVerDir).delete(recursive: true);
      }
      await Directory(stagingVerDir).rename(finalVerDir);

      // 5) 写 app.json
      await _writeAppJson(root, ver, oldCurrent);

      // 6) 清理
      await _cleanupVersions(versionsDir, ver, oldCurrent);

      AppLogger.instance.info('新版本安装完成', {
        'version': ver,
        'rollback': oldCurrent,
      });
      return const InstallResult(true, '安装完成，重启管理器后生效');
    } catch (e) {
      AppLogger.instance.error('安装更新失败', {'error': e.toString()});
      return InstallResult(false, '安装失败：$e');
    }
  }

  // ===== v3.1 轻量化：增量更新 =====

  /// 增量包下载路径 —— %TEMP%/scum_mod_manager.delta.zip
  static String deltaPath() {
    final temp = Platform.environment['TEMP'] ??
        Platform.environment['TMP'] ??
        r'C:\Windows\Temp';
    return p.join(temp, 'scum_mod_manager.delta.zip');
  }

  static String deltaPartPath() => '${deltaPath()}.part';

  /// 把增量清单里的 deltaUrl（可能相对）拼成绝对 URL。
  static Uri resolveDeltaUrl(String deltaUrl) {
    if (deltaUrl.startsWith('http://') || deltaUrl.startsWith('https://')) {
      return Uri.parse(deltaUrl);
    }
    final base = Uri.parse(_manifestUrl);
    return base.replace(path: deltaUrl);
  }

  /// 探测增量更新：GET `{exe_url 目录}/delta_manifest.json`。
  /// 返回验签通过的 [DeltaManifest]；不存在/验签失败返回 null（客户端回退完整包）。
  static Future<DeltaManifest?> fetchDeltaManifest(UpdateManifest m) async {
    try {
      final exeUri = resolveExeUrl(m.exeUrl);
      final dmUri = exeUri.replace(path: '${p.posix.dirname(exeUri.path)}/delta_manifest.json');
      final resp =
          await http.get(dmUri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map<String, dynamic>) return null;
      final dm = DeltaManifest.fromJson(body);
      if (!DeltaManifest.verify(dm)) {
        AppLogger.instance.warning('delta_manifest 验签失败', {
          'to': dm.to,
          'base': dm.base,
        });
        return null;
      }
      return dm;
    } catch (e) {
      AppLogger.instance.warning('delta_manifest 探测异常（回退完整包）', {
        'error': e.toString(),
      });
      return null;
    }
  }

  /// 增量安装：基于当前版本目录复制出副本 → 应用增量包变更 → 原子提交。
  ///
  /// 流程：
  ///   1. 校验基准版本目录 versions/<base>/ 存在（不存在 → 拒绝，走完整包）
  ///   2. 复制 versions/<base>/ → versions/.staging/<to>/
  ///   3. 读增量 zip 内 manifest.json（from/to 必须匹配，否则中止）
  ///   4. 应用 delete 清单 + 覆盖 files/
  ///   5. 校验 data/app.so 版本串 == to
  ///   6. 原子改名 → 写 app.json（current=to, rollback=base）→ 清理
  static Future<InstallResult> installDelta(
      UpdateManifest m, DeltaManifest dm, String deltaZipPath) async {
    final root = AppPaths.instance.root;
    final to = m.version;
    final base = dm.base;
    final versionsDir = p.join(root, 'versions');
    final baseDir = p.join(versionsDir, base);
    final stagingDir = p.join(versionsDir, '.staging');
    final stagingTo = p.join(stagingDir, to);
    final finalTo = p.join(versionsDir, to);
    try {
      if (!Directory(baseDir).existsSync()) {
        return InstallResult(
            false, '缺少基准版本目录 $base，请改用完整包更新');
      }
      // 1) 复制基准 → staging
      if (Directory(stagingTo).existsSync()) {
        await Directory(stagingTo).delete(recursive: true);
      }
      await _copyDir(baseDir, stagingTo);

      // 2) 解压增量 zip，读内部 manifest.json
      final bytes = await File(deltaZipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      Map<String, dynamic>? inner;
      for (final e in archive) {
        if (e.isFile && e.name == 'manifest.json') {
          // 防御：脚本可能产出带 BOM 的 JSON（PS5.1 历史坑），strip 后再解析
          var text = utf8.decode(e.content as List<int>);
          if (text.startsWith('\uFEFF')) text = text.substring(1);
          inner = jsonDecode(text);
          break;
        }
      }
      if (inner == null) {
        return const InstallResult(false, '增量包缺少 manifest.json，安装中止');
      }
      if (inner['from'] != base || inner['to'] != to) {
        return InstallResult(
            false, '增量包版本不匹配（期望 $base→$to），安装中止');
      }

      // 3) 应用 delete 清单（作用于 staging 副本）
      final deleteList = (inner['delete'] as List? ?? []).cast<String>();
      for (final rel in deleteList) {
        final f = File(p.join(stagingTo, rel));
        if (await f.exists()) await f.delete();
      }

      // 4) 覆盖 files/
      for (final e in archive) {
        if (!e.isFile) continue;
        // archive 包在 Windows 上会把 zip 条目名归一化为反斜杠 → 统一转正斜杠再判
        final name = e.name.replaceAll('\\', '/');
        if (name == 'manifest.json' || !name.startsWith('files/')) continue;
        final rel = name.substring('files/'.length);
        if (rel.contains('..') || rel.startsWith('/') ||
            RegExp(r'^[A-Za-z]:').hasMatch(rel)) {
          throw FormatException('增量包含非法路径条目: $rel');
        }
        final out = File(p.join(stagingTo, rel));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(e.content as List<int>, flush: true);
      }

      // 5) 校验版本
      final appSo = File(p.join(stagingTo, 'data', 'app.so'));
      if (!await appSo.exists() || !await _containsVersion(appSo, to)) {
        return InstallResult(
            false, '增量安装后版本校验失败（期望 $to），安装中止');
      }

      // 6) 原子提交
      if (Directory(finalTo).existsSync()) {
        await Directory(finalTo).delete(recursive: true);
      }
      await Directory(stagingTo).rename(finalTo);
      await _writeAppJson(root, to, base);
      await _cleanupVersions(versionsDir, to, base);

      // 清掉增量 zip
      final zf = File(deltaZipPath);
      if (await zf.exists()) await zf.delete();

      AppLogger.instance.info('增量安装完成', {
        'from': base,
        'to': to,
      });
      return const InstallResult(true, '增量安装完成，重启管理器后生效');
    } catch (e) {
      AppLogger.instance.error('增量安装失败', {'error': e.toString()});
      return InstallResult(false, '增量安装失败：$e');
    }
  }

  /// 递归复制目录（async；运行中的 exe 可读，复制不受镜像锁影响）。
  static Future<void> _copyDir(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    await for (final e in Directory(src).list(recursive: true)) {
      final rel = e.path.substring(src.length + 1);
      final target = p.join(dst, rel);
      if (e is Directory) {
        await Directory(target).create(recursive: true);
      } else if (e is File) {
        await File(e.path).copy(target);
      }
    }
  }

  /// 解压 zip 到 destDir（archive 包；拒绝 .. 穿越与绝对路径条目）。
  static Future<void> _unzip(String zipPath, String destDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name;
      // 自家发布的包，但防御性拒绝穿越条目
      if (name.contains('..') ||
          name.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(name)) {
        throw FormatException('更新包含非法路径条目: $name');
      }
      final outFile = File(p.join(destDir, name));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>, flush: true);
    }
  }

  /// 在 app.so 里搜索版本串（AOT 快照中 ASCII 与 UTF-16LE 两种编码都可能出现）。
  static Future<bool> _containsVersion(File appSo, String ver) async {
    final bytes = await appSo.readAsBytes();
    final asciiNeedle = utf8.encode(ver);
    final utf16Needle = <int>[];
    for (final code in ver.codeUnits) {
      utf16Needle.add(code & 0xFF);
      utf16Needle.add((code >> 8) & 0xFF);
    }
    bool contains(List<int> haystack, List<int> needle) {
      if (needle.isEmpty || needle.length > haystack.length) return false;
      for (var i = 0; i <= haystack.length - needle.length; i++) {
        var match = true;
        for (var j = 0; j < needle.length; j++) {
          if (haystack[i + j] != needle[j]) {
            match = false;
            break;
          }
        }
        if (match) return true;
      }
      return false;
    }
    return contains(bytes, asciiNeedle) || contains(bytes, utf16Needle);
  }

  /// 读 app.json 的 current（文件缺失/解析失败返回 null）。
  static Future<String?> _readAppJsonCurrent(String root) async {
    try {
      final f = File(p.join(root, 'app.json'));
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic>) return j['current'] as String?;
    } catch (_) {}
    return null;
  }

  /// 写 app.json —— current 指向新版本，rollback 指向旧版本。
  static Future<void> _writeAppJson(
      String root, String current, String? rollback) async {
    final f = File(p.join(root, 'app.json'));
    final map = <String, dynamic>{'current': current};
    if (rollback != null && rollback.isNotEmpty && rollback != current) {
      map['rollback'] = rollback;
    }
    await f.writeAsString(jsonEncode(map), flush: true);
  }

  /// 清理 .staging 与保留数（current + rollback）之外的旧版本目录。
  static Future<void> _cleanupVersions(
      String versionsDir, String current, String? rollback) async {
    final staging = Directory(p.join(versionsDir, '.staging'));
    if (await staging.exists()) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
    final keep = <String>{current, ?rollback};
    try {
      await for (final e in Directory(versionsDir).list()) {
        if (e is! Directory) continue;
        if (!keep.contains(p.basename(e.path))) {
          try {
            await e.delete(recursive: true);
          } catch (_) {
            // 目录被占用（某旧版本进程尚在运行）→ 留待下次清理
          }
        }
      }
    } catch (_) {}
  }
}

/// v3.1 增量包清单（delta_manifest.json）—— 客户端探增量更新的可信入口。
///
/// 与主 manifest 同 key（UPDATE_VERIFY_KEY）签名；canonical 字段按字母序：
/// `base / delta_sha256 / delta_size_bytes / delta_url / to`（与
/// make_update_pkg.ps1 的签名规则一致）。
class DeltaManifest {
  final String to;
  final String base;
  final String deltaUrl; // 可能是相对路径（拼 baseUrl）或绝对 URL
  final String deltaSha256; // 64 字符 hex
  final int deltaSizeBytes;
  final String signatureB64;

  const DeltaManifest({
    required this.to,
    required this.base,
    required this.deltaUrl,
    required this.deltaSha256,
    required this.deltaSizeBytes,
    required this.signatureB64,
  });

  factory DeltaManifest.fromJson(Map<String, dynamic> j) {
    return DeltaManifest(
      to: (j['to'] as String?) ?? '',
      base: (j['base'] as String?) ?? '',
      deltaUrl: (j['delta_url'] as String?) ?? '',
      deltaSha256: (j['delta_sha256'] as String?) ?? '',
      deltaSizeBytes: (j['delta_size_bytes'] as num?)?.toInt() ?? 0,
      signatureB64: (j['signature'] as String?) ?? '',
    );
  }

  /// 拼接待签名的 canonical 字符串（与 make_update_pkg.ps1 一致）。
  String canonicalString() {
    return [
      'base=$base',
      'delta_sha256=$deltaSha256',
      'delta_size_bytes=$deltaSizeBytes',
      'delta_url=$deltaUrl',
      'to=$to',
    ].join('\n');
  }

  /// 验签：HMAC-SHA256(verify_key, canonical) base64 == signature。
  static bool verify(DeltaManifest dm) {
    if (dm.signatureB64.isEmpty) return false;
    try {
      final expected = base64Decode(dm.signatureB64);
      final hmac = Hmac(sha256, UpdateService.verifyKey);
      final digest = hmac.convert(utf8.encode(dm.canonicalString())).bytes;
      if (expected.length != digest.length) return false;
      var diff = 0;
      for (var i = 0; i < expected.length; i++) {
        diff |= expected[i] ^ digest[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }
}

/// v3 安装结果。
class InstallResult {
  final bool success;
  final String message;
  const InstallResult(this.success, this.message);
}

/// 简易版本比较（独立类 —— 与 RemoteModEntry.compare 同样逻辑但独立，
/// 因为 RemoteModEntry 在 cloud_mods_panel，update_service 不该跨模块引用）。
class RemoteVersionCompare {
  static final RegExp _sep = RegExp(r'[.\-_+]');

  /// 返回 1 / 0 / -1（a 大于/等于/小于 b）。
  static int compare(String a, String b) {
    final pa = a.split(_sep);
    final pb = b.split(_sep);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final ai = i < pa.length ? int.tryParse(pa[i]) ?? 0 : 0;
      final bi = i < pb.length ? int.tryParse(pb[i]) ?? 0 : 0;
      if (ai != bi) return ai < bi ? -1 : 1;
    }
    return 0;
  }
}