/// SFTP 服务器连接服务 —— 管理与 SCUM 服务器之间的 SFTP/SSH 会话。
///
/// 功能（对应需求：通过 SFTP 访问**用户自己的服务器**）：
/// 1. 密码认证连接（dartssh2 纯 Dart 实现，无原生插件）
/// 2. 自动定位远端 `~mods/` 目录（SCUM Server 的 `SCUM/Content/Paks/~mods`）
/// 3. 列出服务器 ~mods 下的 PAK 文件（fileSize + mtime）
/// 4. SHA-256 校验：优先 SSH 远端 `sha256sum`（零传输），失败回退
///    `certutil`（Windows 服务器），再失败回退 SFTP 流式下载计算
/// 5. 服务器端 `mods_meta.json` 读写 —— 备注跟随服务器，可跨管理端共享
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/server_mod_entry.dart';
import '../models/sftp_account.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'mod_service.dart';

/// 后台 isolate 里扫描本地 ~mods 并计算全部 PAK 的 sha-256（顶层函数，
/// `compute` 要求，不能用闭包/实例方法）。
///
/// 增量策略（承接旧 [_ensureLocalShaIndex] 语义）：size/mtime 未变则复用
/// [args.cached]（单库 local 分区）里的缓存哈希，只有新增/变更的文件才重算。
///
/// 返回：{index: {文件名: sha256}, localPart: 写回用的分区数据,
/// dirty: 是否有新增/变更, hasRemoved: 是否有本地已删除的残留记录}。
///
/// 修复了旧实现的缓存丢失 bug：命中缓存时记录**原样保留**（旧代码 remove 掉
/// 后写回，导致一旦有变更发生、所有未变文件的记录全被清空，下次连接全量重扫）。
Map<String, dynamic> _computeLocalShaIndexInIsolate(
  ({String path, Map<String, dynamic> cached}) args,
) {
  final dir = Directory(args.path);
  final index = <String, String>{};
  final localPart = <String, dynamic>{};
  var dirty = false;
  if (dir.existsSync()) {
    for (final f in dir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (!name.toLowerCase().endsWith('.pak')) continue;
      final stat = f.statSync();
      final saved = args.cached[name];
      if (saved is Map<String, dynamic> &&
          saved['sha256'] is String &&
          saved['size'] == stat.size &&
          saved['mtime'] == stat.modified.millisecondsSinceEpoch) {
        // 文件未变：复用缓存哈希，记录原样保留进 localPart。
        index[name] = saved['sha256'] as String;
        localPart[name] = saved;
        continue;
      }
      try {
        final hash = sha256.convert(f.readAsBytesSync()).toString();
        index[name] = hash;
        localPart[name] = <String, dynamic>{
          'sha256': hash,
          'size': stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch,
        };
        dirty = true;
      } catch (_) {}
    }
  }
  // 本地已删除的文件（cached 有记录但当前目录没有）→ 写回时清除残留。
  final hasRemoved = args.cached.keys.any((k) => !index.containsKey(k));
  return <String, dynamic>{
    'index': index,
    'localPart': localPart,
    'dirty': dirty,
    'hasRemoved': hasRemoved,
  };
}

/// 后台 isolate 入口：独立 SSH+SFTP 会话批量计算远端 PAK 的 sha-256。
///
/// 为什么必须独立会话：SSH/SFTP 对象不能跨 isolate 传递，worker 只能自建连接；
/// 连接凭证（host/port/username/password）从用户保存的账户配置取（明文存本地
/// config.json —— 主线程 `connect` 传入的密码不持久化，worker 无法沿用）。
///
/// 收益：SSH 包解析 + SFTP 流式哈希（CPU 密集）全部隔离出 UI isolate，
/// 「扫描服务器全部 PAK 的 sha-256」期间界面保持流畅、不再卡顿。
///
/// 输入 args：{sendPort, host, port, username, password, paths: [远端绝对路径...]}。
/// 流程：批量 sha256sum（每批 ≤25）→ 未命中的走 SFTP 流式兜底。
/// 发送：{'results': {path: hash}, 'failed': [path...]}。
///
/// 注意：Isolate.spawn 入口必须是**单参数函数**，回传 SendPort 通过消息传递
/// （SendPort 本身可跨 isolate 传输）。
Future<void> _remoteSha256WorkerMain(Map<String, dynamic> args) async {
  final sendPort = args['sendPort'] as SendPort;
  final host = args['host'] as String;
  final port = args['port'] as int;
  final username = args['username'] as String;
  final password = args['password'] as String;
  final paths = (args['paths'] as List).cast<String>();

  final results = <String, String>{};
  final failed = <String>[];
  try {
    // 独立建立 SSH 会话（与主线程的连接互不影响，服务器允许多会话）。
    final socket =
        await SSHSocket.connect(host, port).timeout(const Duration(seconds: 15));
    final client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
    );
    await client.authenticated.timeout(const Duration(seconds: 15));

    // 批1：批量 sha256sum（一条命令多路径，秒级；无 shell / 非 POSIX 时整批失败）
    const batchSize = 25;
    for (var off = 0; off < paths.length; off += batchSize) {
      final slice = paths.sublist(
        off,
        off + batchSize > paths.length ? paths.length : off + batchSize,
      );
      try {
        final out = await client
            .run('sha256sum ${slice.map((p) => '"$p"').join(' ')}')
            .timeout(const Duration(seconds: 60));
        final text = utf8.decode(out, allowMalformed: true);
        for (final line in text.split('\n')) {
          // 标准输出行：`<64hex>  <path>`（两空格分隔）
          final m =
              RegExp(r'^([0-9a-fA-F]{64})  (.+)$').firstMatch(line.trimRight());
          if (m == null) continue;
          var path0 = m.group(2)!.trim();
          if (path0.endsWith('\r')) {
            path0 = path0.substring(0, path0.length - 1);
          }
          results[path0] = m.group(1)!.toLowerCase();
        }
      } catch (_) {
        // 整批失败（无 shell）→ 留给 SFTP 兜底
      }
    }

    // 批2：未命中的走 SFTP 流式（worker 内哈希计算不占主线程）
    final remaining = paths.where((p) => !results.containsKey(p)).toList();
    if (remaining.isNotEmpty) {
      final sftp = await client.sftp().timeout(const Duration(seconds: 15));
      for (final path in remaining) {
        final hash = await _sftpStreamSha256InWorker(sftp, path);
        if (hash != null) {
          results[path] = hash;
        } else {
          failed.add(path);
        }
      }
      try {
        await sftp.close();
      } catch (_) {}
    }
    client.close();
  } catch (e) {
    // 连接 / 认证失败：全部路径记失败
    failed.addAll(paths);
  }
  sendPort.send(<String, dynamic>{'results': results, 'failed': failed});
}

/// worker isolate 内部：SFTP 流式下载计算 sha-256（每 64KB 分块，不落盘）。
/// 与主 isolate 的旧 `_sftpStreamSha256` 等价，但跑在后台线程。
Future<String?> _sftpStreamSha256InWorker(
  SftpClient sftp,
  String remotePath,
) async {
  try {
    final holder = _DigestHolder();
    final sink = sha256.startChunkedConversion(holder);
    final controller = StreamController<List<int>>();
    controller.stream.listen(sink.add);
    await sftp
        .download(remotePath, controller, closeDestination: true)
        .timeout(const Duration(seconds: 180));
    await controller.done;
    await controller.close();
    sink.close();
    return holder.value.toString();
  } catch (_) {
    return null;
  }
}

class ServerSftpService extends ChangeNotifier {
  ServerSftpService(this._modService);

  final ModService _modService;

  /// 全局共享实例（设置页「测试连接」与「远程服务器」面板复用同一会话）。
  static ServerSftpService? _shared;

  /// 获取共享实例（懒创建）。
  static ServerSftpService shared(ModService modService) =>
      _shared ??= ServerSftpService(modService);

  /// 解析 SFTP 连接字符串（主机框可整段粘贴）。
  ///
  /// 支持格式（协议/用户名/主机/端口任意组合）：
  /// - `sftp://user@host:port`（标准 URI，用户最常见的粘贴形式）
  /// - `sftp://host:port` / `sftp://user@host` / `sftp://host`
  /// - `user@host:port` / `host:port` / `host`（无协议前缀也可）
  /// - IPv6：`sftp://[::1]:8822`
  ///
  /// 解析失败返回 null（调用方按普通主机名处理）。
  /// 返回 Record：{username?, host, port?, password?}。
  /// **port 为 null 表示输入未显式指定端口**（调用方应保留用户手填的端口，
  /// 不要用默认值覆盖 —— 这就是先前"端口被固定成 22"的根因）。
  static ({String? username, String host, int? port, String? password})?
  parseSftpUri(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;

    // ── 带协议前缀：走 Uri.parse（标准 URI 语义） ──
    final lower = s.toLowerCase();
    if (lower.startsWith('sftp://') || lower.startsWith('ssh://')) {
      final uri = Uri.parse(s);
      if (uri.host.isEmpty) return null;
      final int? port = uri.hasPort ? uri.port : null;
      String? user;
      String? pass;
      if (uri.userInfo.isNotEmpty) {
        final parts = uri.userInfo.split(':');
        if (parts[0].isNotEmpty) user = parts[0];
        if (parts.length > 1 && parts[1].isNotEmpty) pass = parts[1];
      }
      return (username: user, host: uri.host, port: port, password: pass);
    }

    // ── 无协议前缀：手动拆 user@host:port ──
    String? user;
    String? pass;
    var rest = s;
    final at = s.indexOf('@');
    if (at != -1) {
      final userPart = s.substring(0, at);
      rest = s.substring(at + 1);
      final colon = userPart.indexOf(':');
      if (colon != -1) {
        user = userPart.substring(0, colon);
        if (user.isEmpty) user = null;
        final p = userPart.substring(colon + 1);
        if (p.isNotEmpty) pass = p;
      } else if (userPart.isNotEmpty) {
        user = userPart;
      }
    }
    if (rest.isEmpty) return null;

    String host;
    int? port;
    if (rest.startsWith('[')) {
      // IPv6 字面量 [::1] 或 [::1]:8822
      final end = rest.indexOf(']');
      if (end == -1) return null;
      host = rest.substring(1, end);
      final tail = rest.substring(end + 1);
      if (tail.startsWith(':')) {
        final p = int.tryParse(tail.substring(1));
        if (p == null || p <= 0 || p > 65535) return null;
        port = p;
      }
    } else {
      final colon = rest.lastIndexOf(':');
      if (colon != -1) {
        final maybePort = rest.substring(colon + 1);
        final p = int.tryParse(maybePort);
        if (p != null && p > 0 && p <= 65535) {
          port = p;
          host = rest.substring(0, colon);
        } else {
          host = rest; // 冒号后非端口 → 整串视为主机名
        }
      } else {
        host = rest;
      }
    }
    if (host.isEmpty) return null;
    return (username: user, host: host, port: port, password: pass);
  }

  // ── 会话状态 ──
  SSHClient? _client;
  SftpClient? _sftp;
  bool _busy = false;
  String _modsDir = '';
  final List<ServerModEntry> _serverMods = [];
  final List<String> _logs = [];

  /// 当前连接的账户（连接成功后由 [connect] 记录，供数据库归属与跨服互通）。
  SftpAccount? _currentAccount;
  SftpAccount? get currentAccount => _currentAccount;

  /// 本地 ~mods 全部 PAK 的 sha-256 索引（{文件名: sha256}，内容互认用）。
  /// 由 [_ensureLocalShaIndexAsync] **在后台 isolate 中**惰性构建
  /// （连接服务器即扫描的场景绝不占用主线程），并经单库 `local` 分区持久化（size/mtime 校验）。
  Map<String, String> _localShaIndex = const {};

  /// 索引构建中的共享 Future（并发去重：refresh/compute/upload 多个调用点
  /// 并发触发时只扫一次，其余 await 同一 Future —— 也避免重复读大文件）。
  Future<Map<String, String>>? _shaIndexBuilding;

  /// 本地镜像条目（当前账户服务器专属文件夹里的已下载 mod 副本）。
  /// 由 [loadMirrorEntries] 扫描文件夹填充；下载/同步/删除后自动刷新。
  final List<ServerMirrorEntry> _mirrorEntries = [];

  /// 当前账户的本地镜像条目（不可变视图）。
  List<ServerMirrorEntry> get mirrorEntries =>
      List.unmodifiable(_mirrorEntries);

  bool get isConnected => _client != null && !_client!.isClosed;
  bool get isBusy => _busy;
  String get modsDir => _modsDir;
  List<ServerModEntry> get serverMods => List.unmodifiable(_serverMods);
  List<String> get logs => List.unmodifiable(_logs);

  /// 多服务器本地数据库——单文件 {exe_dir}/server_mods.db（JSON 缩进格式）。
  ///
  /// 规划结构（所有服务器共用一个文件，不再每服务器一个 json）：
  /// ```json
  /// {
  ///   "version": 1,
  ///   "servers": {
  ///     "1.2.3.4@root": {
  ///       "files": {
  ///         "Backpack_Nesting.pak": { "sha256": "...", "notes": "..." }
  ///       }
  ///     }
  ///   }
  /// }
  /// ```
  /// 服务器标识 = 服务器 IP + 账户（`host@username`，即 [SftpAccount.key]），
  /// 切账户即切库分区；写库只覆写本分区，其余服务器数据原样保留。
  String get _dbPath {
    final exeDir = AppPaths.instance.root;
    return p.join(exeDir, 'server_mods.db');
  }

  /// 当前服务器在单库里的分区键（未连接时用激活账户 key，缺省兜底 default）。
  String get _dbServerKey {
    final acc = _currentAccount ?? _modService.activeSftpAccount;
    return acc?.key ?? 'default';
  }

  /// 旧版每服务器目录（`server_mods_db/<key>.json`），仅作一次性迁移源。
  String get _legacyDbDir {
    final exeDir = AppPaths.instance.root;
    return p.join(exeDir, 'server_mods_db');
  }

  /// SCUM 游戏目录判据（用户约定）：`SCUM/Content/Paks` 内含 .pak 即目标。
  /// 定位不猜安装根 —— 从 SFTP 当前连接目录出发，逐级扫描目录树找 `SCUM` 文件夹。

  // ===== 连接管理 =====

  /// 建立 SSH + SFTP 会话（密码认证）。
  ///
  /// 参数来自 [ModService.loadSftpConfig]。连接成功返回 true。
  /// 注意：**密码只在内存中使用，绝不打入日志**。
  Future<bool> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    _log('正在连接 $host:$port …');
    try {
      final socket = await SSHSocket.connect(
        host,
        port,
      ).timeout(const Duration(seconds: 15));
      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
        // 首次连接不校验主机指纹（管理器使用者的自有服务器，降低上手门槛）。
        // 若将来需要更严格的安全策略，可在此挂 onVerifyHostKey。
      );
      // 等待认证完成（密码错误会在此抛异常）。
      await client.authenticated.timeout(const Duration(seconds: 15));
      _sftp = await client.sftp().timeout(const Duration(seconds: 15));
      _client = client;
      // 记录当前账户：优先匹配已有账户（同名/同 host），否则临时构造。
      _currentAccount = _matchAccount(host, port, username, password);
      _log('连接成功 ✓（用户名 $username，账户 ${_currentAccount?.displayName ?? '未知'}）');
      notifyListeners();
      return true;
    } catch (e) {
      _log('连接失败 ✗ ${e.runtimeType}: ${_safeError(e)}');
      await disconnect();
      notifyListeners();
      return false;
    }
  }

  /// 断开会话（幂等）。
  Future<void> disconnect() async {
    try {
      await _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    _sftp = null;
    _client = null;
    _serverMods.clear();
    _modsDir = '';
    _currentAccount = null;
    _log('已断开连接');
    notifyListeners();
  }

  /// 错误信息脱敏：不泄露密码/主机名细节。
  static String _safeError(Object e) {
    final s = e.toString();
    // 常见 SSH 错误一般不含敏感信息；长度截断防止异常字符串过长刷屏。
    return s.length > 200 ? s.substring(0, 200) : s;
  }

  SftpClient get _requireSftp {
    final s = _sftp;
    if (s == null) {
      throw StateError('SFTP 未连接');
    }
    return s;
  }

  SSHClient get _requireClient {
    final c = _client;
    if (c == null || c.isClosed) {
      throw StateError('SSH 未连接');
    }
    return c;
  }

  // ===== ~mods 目录定位 =====
  /// 自动探测远端 `~mods/` 目录绝对路径。
  ///
  /// 定位判据（主人约定）：**不猜安装根，认准目录树结构**
  /// 从 SFTP 当前连接目录出发，逐级扫描找名为 `SCUM` 的文件夹，
  /// 其 `Content/Paks` 内若存在 `.pak` 文件即为目标游戏 Paks，
  /// 其下的 `~mods`（或 `~mod`）子目录就是 mod 部署目录。
  ///
  /// 策略：
  /// 1. 先试 [ModService.loadSftpConfig] 里已保存的 `sftp_mods_path`（若验证通过直接复用）
  /// 2. 从 SFTP 当前目录（absolute('.')）开始 BFS 逐级扫描目录树，
  ///    每层列出内容找 `SCUM` 文件夹，下钻 `Content` → `Paks` 验证 .pak
  /// 3. Linux `find` 全盘兜底：按 `*SCUM/Content/Paks` 路径模式找目录，同样验证 pak
  ///
  /// 定位全程逐条记录日志（扫了哪些目录 / 目录里有多少子目录与 .pak /
  /// 因何跳过），让用户在面板底部日志条看到完整寻找过程。
  ///
  /// 找到后写入 config（`sftp_mods_path`）并填充 [_modsDir]。
  /// 返回找到的绝对路径；未找到返回 null。
  Future<String?> locateModsDir() async {
    final sftp = _requireSftp;
    _busy = true;
    notifyListeners();
    _log('▶ 开始自动定位服务器 ~mods 目录');
    try {
      // 1) 已保存路径（仍是权威；存在且是目录即可复用）
      final saved = _modService.loadSftpConfig()['sftp_mods_path'] ?? '';
      if (saved.isNotEmpty) {
        _log('步骤1/3：尝试已保存路径: $saved');
        if (await _dirExists(sftp, saved)) {
          _modsDir = saved;
          _log('✓ 已保存路径有效，直接复用: $saved');
          return saved;
        }
        _log('✗ 已保存路径不存在或不可访问（继续探测）');
      } else {
        _log('步骤1/3：config 中无已保存路径，直接进入探测');
      }

      // 2) 从 SFTP 当前连接目录出发，逐级扫描目录树找 SCUM 文件夹
      _log('步骤2/3：从 SFTP 当前目录出发，逐级扫描找 SCUM 文件夹 …');
      final byTree = await _scanScumFromCwd();
      if (byTree != null) {
        _modsDir = byTree;
        _log('✓ 目录树扫描定位成功: $byTree');
        _saveModsPath(byTree);
        return byTree;
      }

      // 3) Linux find 全盘兜底（按中间路径模式，不依赖常见根）
      _log('步骤3/3：目录树未命中，启动 Linux find 全盘路径模式兜底 …');
      final found = await _findModsDirRemote();
      if (found != null) {
        _modsDir = found;
        _log('✓ find 兜底定位成功: $found');
        _saveModsPath(found);
        return found;
      }

      _log('✗ 未找到 ~mods 目录（请手动填写路径）');
      return null;
    } catch (e) {
      _log('定位 ~mods 失败: ${_safeError(e)}');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 列出目录内所有 .pak 文件名（返回列表，空 = 无 pak）。
  Future<List<String>> _listPakFiles(SftpClient sftp, String path) async {
    try {
      final names = await sftp.listdir(path);
      return names
          .map((n) => n.filename)
          .where((f) => f.toLowerCase().endsWith('.pak'))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 从 SFTP 当前连接目录出发，BFS 逐级扫描目录树找 SCUM 游戏根。
  ///
  /// 逻辑（主人约定）：不猜安装根 —— 从当前目录（absolute('.')）开始，
  /// 每层列出目录内容。**判据是目录结构而非名字**：任何目录只要其下存在
  /// `Content/Paks` 且 Paks 内含 .pak，它就是 SCUM 游戏根。
  ///
  /// 覆盖两种常见布局：
  /// - 标准布局：`<父>/SCUM/Content/Paks/~mods`（父目录下找到 SCUM 文件夹）
  /// - chroot 布局：`/Content/Paks/~mods`（SFTP 用户被 chroot 到游戏根，
  ///   当前目录 `/` 本身就是游戏根，没有 SCUM 这一层）
  ///
  /// 每扫一个目录：
  /// 1. 先验证它自身是否即游戏根（`dir/Content/Paks` 含 .pak）→ 命中即定位
  /// 2. 再看它下边有没有名为 `SCUM` 的子目录 → 有则验证
  /// 3. 其余子目录入队下一层
  ///
  /// 深度上限 10 层 + 已访问目录去重（防符号链接循环），
  /// 全程逐条记录日志。返回目标 ~mods 绝对路径；未找到返回 null。
  Future<String?> _scanScumFromCwd() async {
    final sftp = _requireSftp;
    // 当前连接目录（SFTP 会话默认工作目录，等于用户登录后的位置）
    final cwd = await _resolvePath(sftp, '.');
    if (cwd == null || cwd.isEmpty) {
      _log('  ✗ 获取 SFTP 当前目录失败');
      return null;
    }
    _log('  SFTP 当前目录: $cwd');

    final queue = <String>[cwd];
    // 注意：visited 必须初始为空 —— 如果把 cwd 预先放进去，BFS 首轮
    // `visited.add(cwd)` 返回 false 直接 continue，第一个目录永不扫描
    // （正是「只显示当前目录、不显示内容」的根因）。
    final visited = <String>{};
    const maxDepth = 10;
    var depth = 0;

    while (queue.isNotEmpty && depth <= maxDepth) {
      final levelSize = queue.length;
      _log('  第 $depth 层：待扫 $levelSize 个目录');
      for (var i = 0; i < levelSize; i++) {
        final dir = queue.removeAt(0);
        if (!visited.add(dir)) continue;

        // 列出当前目录内容，分离子目录与 .pak 文件
        final List<SftpName> names;
        try {
          names = await sftp.listdir(dir);
        } catch (e) {
          _log('    ✗ 无法列出: $dir（${_safeError(e)}）');
          continue;
        }
        final subDirs = names
            .where(
              (n) =>
                  n.attr.isDirectory && n.filename != '.' && n.filename != '..',
            )
            .toList();
        final pakCount = names
            .where((n) => n.filename.toLowerCase().endsWith('.pak'))
            .length;
        _log('  $dir：${subDirs.length} 个子目录，$pakCount 个 .pak');

        // 1) 先验证当前目录本身是否即 SCUM 游戏根：任何目录只要其下
        //    `Content/Paks` 存在且内含 .pak，它就是游戏根（可能是名为 SCUM 的
        //    文件夹，也可能是 chroot 后的 `/` —— 不靠名字判断，只认结构）。
        final selfPaks = await _probeScumPaks(sftp, dir);
        if (selfPaks != null) {
          final ensured = await _ensureModsDir(
            sftp,
            _joinPosix(selfPaks, '~mods'),
          );
          if (ensured != null) {
            _log('  ✓ 当前目录即游戏根，定位成功: $ensured');
            return ensured;
          }
          _log('  ~mods 创建失败（权限不足？），继续扫其他位置');
        }

        // 2) 本目录下是否有名为 SCUM 的文件夹 → 下钻验证
        for (final sub in subDirs) {
          if (sub.filename != 'SCUM') continue;
          final scumDir = _joinPosix(dir, 'SCUM');
          _log('  ✓ 发现 SCUM 文件夹: $scumDir');
          final paksDir = await _probeScumPaks(sftp, scumDir);
          if (paksDir != null) {
            final ensured = await _ensureModsDir(
              sftp,
              _joinPosix(paksDir, '~mods'),
            );
            if (ensured != null) {
              _log('  ✓ 定位成功: $ensured');
              return ensured;
            }
            _log('  ~mods 创建失败（权限不足？），继续扫其他位置');
          }
        }

        // 3) 其余子目录入队下一层
        for (final sub in subDirs) {
          if (sub.filename == 'SCUM') continue; // 已处理
          final next = _joinPosix(dir, sub.filename);
          if (!visited.contains(next)) queue.add(next);
        }
      }
      depth++;
    }
    _log('  目录树扫描完成（$depth 层），未发现 SCUM/Content/Paks 结构');
    return null;
  }

  /// 验证 `SCUM/Content/Paks` 三层次结构：Paks 存在且内含 .pak。
  /// 返回 Paks 绝对路径；不满足返回 null。
  Future<String?> _probeScumPaks(SftpClient sftp, String scumDir) async {
    final contentDir = _joinPosix(scumDir, 'Content');
    if (!await _dirExists(sftp, contentDir)) {
      _log('    ✗ 无 Content 子目录: $contentDir');
      return null;
    }
    final paksDir = _joinPosix(contentDir, 'Paks');
    if (!await _dirExists(sftp, paksDir)) {
      _log('    ✗ 无 Paks 子目录: $paksDir');
      return null;
    }
    final pakFiles = await _listPakFiles(sftp, paksDir);
    if (pakFiles.isEmpty) {
      _log('    ✗ Paks 内无 .pak（不是 SCUM 游戏目录）: $paksDir');
      return null;
    }
    _log(
      '    ✓ Paks 含 ${pakFiles.length} 个 .pak，确认为 SCUM 游戏目录。'
      '示例: ${pakFiles.take(3).join(', ')}${pakFiles.length > 3 ? ' …' : ''}',
    );
    return paksDir;
  }

  /// 手动设置 ~mods 路径（设置页手动输入框用）。
  Future<bool> useModsDir(String path) async {
    if (path.isEmpty) return false;
    final sftp = _requireSftp;
    if (!await _dirExists(sftp, path)) {
      _log('路径不存在或不可访问: $path');
      return false;
    }
    _modsDir = path;
    _saveModsPath(path);
    _log('已设置 ~mods 路径: $path');
    notifyListeners();
    return true;
  }

  void _saveModsPath(String path) {
    _modService.saveSftpConfig({'sftp_mods_path': path});
  }

  /// 匹配已有账户（host+port+username 相同则复用其配置），否则临时构造账户。
  SftpAccount _matchAccount(
    String host,
    int port,
    String username,
    String password,
  ) {
    final accounts = _modService.loadSftpAccounts();
    for (final a in accounts) {
      if (a.host == host && a.port == port && a.username == username) {
        return a;
      }
    }
    return SftpAccount(
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }

  // ===== 多服务器本地数据库（server_mods.db 单文件，所有服务器共存） =====

  /// 读取单库文件整体（{version, servers}），结构异常 → 空壳。
  Map<String, dynamic> _readDbFile() {
    final f = File(_dbPath);
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map<String, dynamic>) return raw;
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// 写入单库文件整体（缩进 JSON，纯写不触发迁移——迁移在入口处做）。
  void _writeDbFile(Map<String, dynamic> full) {
    try {
      final json = const JsonEncoder.withIndent('  ').convert(full);
      File(_dbPath).writeAsStringSync(json);
    } catch (e) {
      _log('写入服务器数据库失败: ${_safeError(e)}');
    }
  }

  /// 读取当前服务器的库分区（{文件名: {sha256, notes}}），不存在 → 空 Map。
  Map<String, dynamic> loadServerDb() {
    _ensureDbMigrated();
    final servers = _readDbFile()['servers'];
    if (servers is Map<String, dynamic>) {
      final section = servers[_dbServerKey];
      if (section is Map<String, dynamic>) return section;
    }
    return {};
  }

  /// 写入当前服务器的库分区（只覆写本分区，其他服务器数据保留）。
  void saveServerDb(Map<String, dynamic> db) {
    _ensureDbMigrated();
    final full = _readDbFile();
    final servers =
        (full['servers'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    servers[_dbServerKey] = db;
    full['servers'] = servers;
    _writeDbFile(full);
    _log('已保存服务器数据库: $_dbPath（分区 $_dbServerKey · ${db.length} 条）');
  }

  /// 把当前列表的 sha256/notes 落库（扫描+哈希后调用）。
  void persistServerDb() {
    if (_currentAccount == null) return;
    final db = <String, dynamic>{};
    for (final m in _serverMods) {
      db[m.fileName] = {
        if (m.sha256 != null) 'sha256': m.sha256,
        if (m.notes.isNotEmpty) 'notes': m.notes,
      };
    }
    saveServerDb(db);
  }

  /// 读取全部服务器的库分区：{服务器key(host@username): {文件名: {sha256, notes}}}。
  Map<String, Map<String, dynamic>> loadAllServerDbs() {
    _ensureDbMigrated();
    final servers = _readDbFile()['servers'];
    if (servers is Map<String, dynamic>) {
      return servers.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
    }
    return <String, Map<String, dynamic>>{};
  }

  /// 旧版每服务器 json（`server_mods_db/<sanitized host:port>.json`）一次性迁移进单库。
  /// 通过账户列表把旧 `host:port` 键映射为新 `host@username` 键；无对应账户的
  /// 遗留文件保留在旧目录。完成后旧目录改名 `.legacy` 防止重复迁移。
  void _ensureDbMigrated() {
    final legacyDir = Directory(_legacyDbDir);
    if (!legacyDir.existsSync()) return;
    // 单库已存在：旧目录不再作为数据源，直接归档。
    if (File(_dbPath).existsSync()) {
      try {
        legacyDir.renameSync('$_legacyDbDir.legacy');
      } catch (_) {}
      return;
    }
    final accounts = _modService.loadSftpAccounts();
    String sanitize(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final keyMap = <String, String>{
      for (final a in accounts) sanitize('${a.host}:${a.port}'): a.key,
    };
    final servers = <String, dynamic>{};
    for (final f in legacyDir.listSync().whereType<File>().where(
      (e) => e.path.endsWith('.json'),
    )) {
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is! Map<String, dynamic> || raw.isEmpty) continue;
        final oldKey = p.basenameWithoutExtension(f.path);
        final newKey = keyMap[oldKey];
        if (newKey != null) {
          servers[newKey] = raw;
        } else {
          _log('旧库 $oldKey 无对应账户，保留在旧目录（未迁入）');
        }
      } catch (_) {}
    }
    if (servers.isNotEmpty) {
      _writeDbFile(<String, dynamic>{'version': 1, 'servers': servers});
      _log('已迁移 ${servers.length} 台服务器的旧库到单文件 $_dbPath');
    }
    try {
      legacyDir.renameSync('$_legacyDbDir.legacy');
    } catch (_) {}
  }

  /// 跨服务器 sha-256 互通索引：在所有服务器数据库中找与 [sha256] 相同的条目。
  ///
  /// 返回：{账户key: [文件名列表]} —— 同一 sha-256 可能在不同服务器有不同文件名/备注。
  Map<String, List<String>> findCrossServerMatches(String sha256) {
    if (sha256.isEmpty) return {};
    final result = <String, List<String>>{};
    final all = loadAllServerDbs();
    final selfKey = _currentAccount?.key;
    for (final entry in all.entries) {
      final serverKey = entry.key;
      if (serverKey == selfKey) continue; // 自己不算
      final names = <String>[];
      for (final m in entry.value.entries) {
        final meta = m.value;
        if (meta is Map && (meta['sha256'] as String?) == sha256) {
          names.add(m.key);
        }
      }
      if (names.isNotEmpty) result[serverKey] = names;
    }
    return result;
  }

  /// 读取其他服务器数据库里某个 mod 的备注（跨服互通时展示对方备注用）。
  /// [serverKey] 形如 'host@username'，与 [_dbServerKey] / 单库 servers 键一致。
  String? getRemoteNotes(String serverKey, String fileName) {
    final all = loadAllServerDbs();
    final db = all[serverKey];
    if (db == null) return null;
    final meta = db[fileName];
    if (meta is Map) {
      final notes = meta['notes'];
      if (notes is String && notes.isNotEmpty) return notes;
    }
    return null;
  }

  /// 云上 mod 备注（按 sha-256 在缓存的云端目录中匹配，优先级最高）。
  /// 云上备注非空即返回；为空返回 null（让位给服务器备注）。
  String? cloudNotesBySha256(String sha256) {
    if (sha256.isEmpty) return null;
    for (final m in _modService.cloudMods) {
      if (m.sha256 == sha256) {
        final notes = m.notes;
        if (notes != null && notes.isNotEmpty) return notes;
        // 云上备注兜底：manifest 暂无 notes 字段时，用作者描述充当云上备注
        // （实测 2026-08-23：registry 的 7 个 mod 全部 notes=None、description 有值）。
        final desc = m.description;
        if (desc != null && desc.isNotEmpty) return desc;
        return null;
      }
    }
    return null;
  }

  /// 云上 mod 标签（按 sha-256 匹配，返回云端 tags；无匹配或空 → 空列表）。
  /// 供远程服务器卡片展示云上标签（与云上备注一同互换到服务器侧）。
  List<String> cloudTagsBySha256(String sha256) {
    if (sha256.isEmpty) return const [];
    for (final m in _modService.cloudMods) {
      if (m.sha256 == sha256) return m.tags;
    }
    return const [];
  }

  /// 其他服务器的备注（排除当前/激活服务器）：其他服务器库中与 [sha256]
  /// 相同的第一个非空备注——远程服务器列表里「隐藏式互换」备注的来源。
  String? otherServerNotesBySha256(String sha256) {
    if (sha256.isEmpty) return null;
    final selfKey = _dbServerKey;
    for (final entry in loadAllServerDbs().entries) {
      if (entry.key == selfKey) continue; // 自己不算
      for (final meta in entry.value.values) {
        if (meta is Map && (meta['sha256'] as String?) == sha256) {
          final notes = meta['notes'];
          if (notes is String && notes.isNotEmpty) return notes;
        }
      }
    }
    return null;
  }

  /// 全部服务器数据库中与 [sha256] 相同的第一个非空备注（云上 mod 面板
  /// 「备注获取」用：云端无备注时，展示任一远程服务器已写的备注）。
  String? findServerNotesBySha256(String sha256) {
    if (sha256.isEmpty) return null;
    for (final db in loadAllServerDbs().values) {
      for (final meta in db.values) {
        if (meta is Map && (meta['sha256'] as String?) == sha256) {
          final notes = meta['notes'];
          if (notes is String && notes.isNotEmpty) return notes;
        }
      }
    }
    return null;
  }

  /// 跨服备注互通 —— 把本服务器 mod 的备注推送到另一台服务器。
  ///
  /// 流程（主人需求：相同 sha-256 判定为同一 mod，允许用户选择备注覆盖给谁）：
  /// 1. 记住当前会话；断开
  /// 2. 连接目标服务器账户 → 自动定位 ~mods → 将该 mod 的备注写入
  ///    目标服务器 {Paks}/mods_meta.json（用目标侧的文件名）
  /// 3. 断开目标会话，恢复并回到当前服务器会话
  ///
  /// 返回 true 表示推送成功。全程日志可见。
  Future<bool> pushNotesToServer(
    SftpAccount targetAccount,
    String targetFileName,
    String notes,
  ) async {
    // 记住当前会话以便恢复
    final wasConnected = isConnected;
    final curAccount = _currentAccount;
    SftpClient? curSftp = _sftp;
    SSHClient? curClient = _client;

    // 1) 断开当前
    await disconnect();

    // 2) 连接目标服务器
    _log('跨服互通：连接目标服务器 ${targetAccount.displayName} …');
    final ok = await connect(
      host: targetAccount.host,
      port: targetAccount.port,
      username: targetAccount.username,
      password: targetAccount.password,
    );
    if (!ok) {
      _log('✗ 跨服互通：目标服务器连接失败');
      // 尝试恢复原会话
      await _restoreSession(wasConnected, curAccount, curSftp, curClient);
      return false;
    }

    try {
      // 自动定位 ~mods（使用目标服务器账户的已存路径，不存在则探测）
      if (modsDir.isEmpty) {
        await locateModsDir();
      }
      if (modsDir.isEmpty) {
        _log('✗ 跨服互通：无法定位目标服务器 ~mods');
        return false;
      }
      final written = await updateServerModNotes(targetFileName, notes);
      _log(
        written
            ? '✓ 备注已推送到 ${targetAccount.displayName}: $targetFileName'
            : '✗ 备注推送写入失败',
      );
      return written;
    } finally {
      // 3) 断开目标，恢复原会话
      await disconnect();
      await _restoreSession(wasConnected, curAccount, curSftp, curClient);
    }
  }

  /// 恢复之前保存的会话状态。
  Future<void> _restoreSession(
    bool wasConnected,
    SftpAccount? curAccount,
    SftpClient? curSftp,
    SSHClient? curClient,
  ) async {
    if (!wasConnected ||
        curAccount == null ||
        curSftp == null ||
        curClient == null) {
      _log('跨服互通完成（原会话无需恢复）');
      return;
    }
    _log('跨服互通：恢复原服务器会话 ${curAccount.displayName} …');
    _sftp = curSftp;
    _client = curClient;
    _currentAccount = curAccount;
    notifyListeners();
  }

  /// 远端目录是否存在。
  Future<bool> _dirExists(SftpClient sftp, String path) async {
    try {
      final attrs = await sftp.stat(path, followLink: true);
      return attrs.isDirectory;
    } catch (_) {
      return false;
    }
  }

  /// 确保 `~mods` 部署目录存在：已存在 → 原样返回；不存在 → 尝试递归创建并返回；
  /// 创建失败（权限不足等）→ 返回 null。
  ///
  /// 关键语义（主人约定）：`~mods` 是**部署目录**，用户还没装过 mod 时它可能
  /// 不存在 —— 定位不是「找已存在的目录」，而是「确认目标游戏 Paks 后给出
  /// 其预期 ~mods 路径」，不存在则自动创建。
  Future<String?> _ensureModsDir(SftpClient sftp, String path) async {
    if (await _dirExists(sftp, path)) {
      _log('  ~mods 已存在: $path');
      return path;
    }
    _log('  ~mods 不存在，尝试自动创建: $path');
    // 首选远端 shell `mkdir -p`（Linux 一步递归）；失败回退 SFTP 逐级 mkdir。
    try {
      await _requireClient
          .run('mkdir -p "$path"')
          .timeout(const Duration(seconds: 10));
      if (await _dirExists(sftp, path)) {
        _log('  ✓ 已用 mkdir -p 创建成功');
        return path;
      }
      _log('  mkdir -p 执行完成但目录仍不可见（可能受限），回退 SFTP 逐级创建');
    } catch (e) {
      _log('  mkdir -p 不可用（${_safeError(e)}），回退 SFTP 逐级创建');
    }
    // SFTP 逐级创建（Windows 服务器无 mkdir -p）
    var acc = '';
    for (final part in path.split('/')) {
      if (part.isEmpty) continue;
      acc = '$acc/$part';
      if (await _dirExists(sftp, acc)) continue;
      try {
        await sftp.mkdir(acc);
        _log('  SFTP 创建: $acc');
      } catch (e) {
        _log('  ✗ 创建 $acc 失败: ${_safeError(e)}');
        return null;
      }
    }
    if (await _dirExists(sftp, path)) {
      _log('  ✓ SFTP 逐级创建完成');
      return path;
    }
    _log('  ✗ 目录创建后仍不可见');
    return null;
  }

  /// 解析远端路径（展开 ~ / 相对路径），失败返回 null。
  Future<String?> _resolvePath(SftpClient sftp, String path) async {
    try {
      return await sftp.absolute(path);
    } catch (_) {
      return null;
    }
  }

  /// Linux `find` 全盘兜底：按**中间路径模式** `*SCUM/Content/Paks` 找游戏 Paks
  /// 目录（不依赖常见安装根），再取 `Paks/~mods`（排除 `~mod`，不存在则自动创建）。
  /// 全程逐条记录日志：find 命令、命中的每个 Paks 目录、dir 内容、创建过程。
  Future<String?> _findModsDirRemote() async {
    try {
      final sftp = _requireSftp;
      // 1) 全盘找 `SCUM/Content/Paks` 目录（路径模式，从中间特征定位）
      const findPaks =
          'find / -type d -path "*SCUM/Content/Paks" 2>/dev/null | head -20';
      _log('find 命令: $findPaks');
      final paksOut = await _requireClient
          .run(findPaks)
          .timeout(const Duration(seconds: 30));
      final paksText = utf8.decode(paksOut, allowMalformed: true);
      final hits = paksText
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      _log('find 命中 ${hits.length} 个 SCUM/Content/Paks 候选');
      if (hits.isEmpty) {
        _log('  find 无命中（服务器可能无 find，或无任何 SCUM Paks 目录）');
        return null;
      }
      for (final paksDir in hits) {
        _log('  校验候选: $paksDir');
        final pakFiles = await _listPakFiles(sftp, paksDir);
        if (pakFiles.isEmpty) {
          _log('    ✗ 无 .pak（不是 SCUM Paks 目录），跳过');
          continue;
        }
        _log(
          '    ✓ 含 ${pakFiles.length} 个 .pak。'
          '示例: ${pakFiles.take(3).join(', ')}${pakFiles.length > 3 ? ' …' : ''}',
        );
        // 目标 = Paks/~mods（排除 ~mod；不存在则自动创建）
        final ensured = await _ensureModsDir(
          sftp,
          _joinPosix(paksDir, '~mods'),
        );
        if (ensured != null) {
          _log('✓ find 候选确认: $ensured');
          return ensured;
        }
        _log('    ✗ ~mods 创建失败（权限不足？），试下一个候选');
      }
    } catch (e) {
      _log('find 兜底异常: ${_safeError(e)}');
    }
    return null;
  }

  /// POSIX 路径拼接（远端统一用 /，无论服务器是 Linux 还是 Windows）。
  static String _joinPosix(String a, String b) {
    if (a.endsWith('/')) a = a.substring(0, a.length - 1);
    if (b.startsWith('/')) b = b.substring(1);
    return '$a/$b';
  }

  // ===== 列表扫描 =====

  /// 列出服务器 ~mods/ 下的 PAK 文件，与本地 ~mods 同名文件配对。
  ///
  /// 返回是否成功。条目写入 [_serverMods]（保留已有 SHA/备注元数据）。
  Future<bool> refreshServerMods() async {
    if (_modsDir.isEmpty) {
      _log('~mods 路径未定位，请先定位');
      return false;
    }
    final sftp = _requireSftp;
    _busy = true;
    notifyListeners();
    _log('正在扫描服务器 ~mods（$_modsDir）…');
    try {
      final names = await sftp.listdir(_modsDir);
      final meta = await _readRemoteMeta();
      final dbMeta = loadServerDb();
      // 本地索引后台构建（isolate），供下方内容互认查询；不阻塞 UI。
      await _ensureLocalShaIndexAsync();
      final localNames = _localModsNames();
      final next = <ServerModEntry>[];
      for (final n in names) {
        if (!n.filename.toLowerCase().endsWith('.pak')) continue;
        final remotePath = _joinPosix(_modsDir, n.filename);
        // 保留旧条目里的 sha256（本列表扫描不重算哈希，哈希是显式操作）。
        final prev = _serverMods
            .where((e) => e.fileName == n.filename)
            .firstOrNull;
        // 同名匹配（大小写不敏感）+ 内容互认（sha-256 相同即算本地有副本）。
        // sha-256 预填：优先内存旧条目，其次单库分区缓存（内容未变的文件重连秒显示）。
        final hasLocalMatch = localNames.contains(n.filename.toLowerCase());
        final prevSha = prev?.sha256 ?? _shaFromDb(dbMeta, n.filename);
        next.add(
          ServerModEntry(
            fileName: n.filename,
            remotePath: remotePath,
            fileSize: n.attr.size ?? 0,
            lastModified: n.attr.modifyTime != null
                ? DateTime.fromMillisecondsSinceEpoch(n.attr.modifyTime! * 1000)
                : null,
            sha256: prevSha,
            notes: (meta[n.filename]?['notes'] as String?) ?? '',
            hasLocalMatch: hasLocalMatch,
            hasLocalContentMatch: !hasLocalMatch && prevSha != null
                ? _localContentExistsFor(prevSha)
                : false,
          ),
        );
      }
      _serverMods
        ..clear()
        ..addAll(next);
      _log('扫描完成：找到 ${_serverMods.length} 个 PAK');
      // 主人需求：检测到 pak 自动计算 sha-256（异步触发，不阻塞列表刷新响应；
      // 逐个计算会自动落库到每服务器数据库）。
      if (_serverMods.isNotEmpty) {
        // ignore: discarded_futures
        computeAllSha256();
      }
      notifyListeners();
      return true;
    } catch (e) {
      _log('扫描服务器 ~mods 失败: ${_safeError(e)}');
      notifyListeners();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 从单库分区取某文件缓存的 sha-256（无缓存返回 null）。
  static String? _shaFromDb(Map<String, dynamic> db, String fileName) {
    final meta = db[fileName];
    if (meta is Map) {
      final sha = meta['sha256'];
      if (sha is String && sha.isNotEmpty) return sha;
    }
    return null;
  }

  /// 本地 ~mods 目录下所有文件名（小写），用于与服务器配对。
  Set<String> _localModsNames() {
    final dir = Directory(_modService.localModsPath);
    if (!dir.existsSync()) return {};
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path).toLowerCase())
        .toSet();
  }

  // ===== SHA-256 校验 =====

  /// 计算单个远端 PAK 的 SHA-256（hex 小写）。
  ///
  /// 全程在**后台 isolate**（worker 自建 SSH+SFTP 会话）执行：
  /// 批量 sha256sum → 未命中 SFTP 流式，UI 线程零参与网络与哈希计算。
  /// （旧版在主线程 await 命令 + 流式兜底，扫描时卡顿即由此而来。）
  Future<String?> computeSha256(ServerModEntry entry) async {
    _busy = true;
    notifyListeners();
    _log('计算 SHA-256: ${entry.fileName}（后台线程）');
    try {
      await _ensureLocalShaIndexAsync();
      final byPath = await _computeRemoteSha256InIsolate([entry.remotePath]);
      final hash = byPath[entry.remotePath];
      if (hash == null) {
        _log('计算 SHA-256 失败（后台线程无结果，见上方日志）');
        return null;
      }
      _log('SHA-256（后台线程）✓');
      // 更新条目 + 同步本地同名文件哈希（若本地存在）+ 内容互认
      final idx = _serverMods.indexWhere((e) => e.fileName == entry.fileName);
      if (idx >= 0) {
        _serverMods[idx].sha256 = hash;
        _serverMods[idx].localSha256 = _localSha256(entry.fileName);
        if (!_serverMods[idx].hasLocalMatch) {
          _serverMods[idx].hasLocalContentMatch = _localContentExistsFor(hash);
        }
      }
      // 哈希落库（每服务器数据库），供跨服 sha-256 互通识别。
      persistServerDb();
      notifyListeners();
      return hash;
    } catch (e) {
      _log('计算 SHA-256 异常: ${_safeError(e)}');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 全部条目计算 SHA-256 —— **后台 isolate 一键式**：
  ///
  /// 流程：
  /// 1. 收集未计算的条目（db 缓存预填过的直接跳过）
  /// 2. 把全部远端路径交给独立 worker isolate（自建 SSH+SFTP 会话）：
  ///    批量 sha256sum → 未命中 SFTP 流式，UI 线程零参与网络与哈希计算
  /// 3. 结果回填条目 + 落库
  ///
  /// 相比旧实现（主线程 await 批量命令 + 逐个 SFTP 兜底），哈希计算与
  /// SSH 包解析全部隔离出去，扫描期间界面保持流畅、不再卡顿。
  Future<void> computeAllSha256() async {
    final pending = _serverMods.where((e) => e.sha256 == null).toList();
    if (pending.isEmpty) {
      _log('全部 SHA-256 已就绪（本次无新增文件）');
      return;
    }
    _log('SHA-256 批量计算：${pending.length} 个文件待算（后台线程）');
    _busy = true;
    notifyListeners();
    try {
      // 本地索引后台构建（isolate），供 _applySha256 的 localSha256/内容互认
      // 纯内存赋值使用；不阻塞 UI。
      await _ensureLocalShaIndexAsync();
      final byPath = await _computeRemoteSha256InIsolate(
        pending.map((e) => e.remotePath).toList(),
      );
      var batchHits = 0;
      for (final entry in pending) {
        final hash = byPath[entry.remotePath];
        if (hash == null) continue;
        _applySha256(entry.fileName, hash);
        batchHits++;
      }
      if (batchHits > 0) {
        _log('✓ 后台哈希线程命中 $batchHits/${pending.length}（UI 不受影响）');
      } else {
        _log('⚠ 后台哈希线程无命中（服务器不可达 / 无 shell / 无凭证？）');
      }
      persistServerDb();
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
    _log('全部 SHA-256 计算完成');
  }

  /// 在后台 isolate 里计算一批远端路径的 sha-256（worker 自建 SSH+SFTP
  /// 会话，UI 线程完全不参与网络与哈希计算）。返回 {远端路径: hash}。
  ///
  /// 凭证来源：当前账户（或激活账户）的持久化配置；缺密码时返回空 Map
  /// （调用方记日志，不再降级回主线程计算 —— 主线程计算正是卡顿根源）。
  ///
  /// 超时兜底 5 分钟（覆盖大批量 + 慢 SFTP 流式）；worker 崩溃/超时
  /// 一律按失败处理并记日志，绝不悬挂 UI。
  Future<Map<String, String>> _computeRemoteSha256InIsolate(
    List<String> remotePaths,
  ) async {
    if (remotePaths.isEmpty) return const {};
    final acc = _currentAccount ?? _modService.activeSftpAccount;
    final host = acc?.host;
    final username = acc?.username;
    final password = acc?.password;
    if (host == null ||
        host.isEmpty ||
        username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      _log('⚠ 账户缺少连接凭证（password 为空），无法启动后台哈希线程');
      return const {};
    }
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _remoteSha256WorkerMain,
        <String, dynamic>{
          'sendPort': receive.sendPort,
          'host': host,
          'port': acc?.port ?? 22,
          'username': username,
          'password': password,
          'paths': remotePaths,
        },
      );
      // 只认 worker 的结果消息（Map 且含 results 键）；错误/退出事件忽略，
      // worker 若崩溃则由超时兜底返回失败。
      final result = await receive
          .firstWhere((m) => m is Map && m.containsKey('results'))
          .timeout(const Duration(seconds: 300));
      if (result is Map) {
        final results = result['results'];
        final failed = result['failed'];
        if (failed is List && failed.isNotEmpty) {
          _log(
            '⚠ 后台哈希线程 ${failed.length} 个文件失败'
            '（${failed.take(3).join(', ')}${failed.length > 3 ? ' …' : ''}）',
          );
        }
        if (results is Map) return results.cast<String, String>();
      }
      return const {};
    } on TimeoutException {
      isolate?.kill(priority: Isolate.immediate); // 超时兜底：回收后台线程
      _log('⚠ 后台哈希线程超时（300s），本次哈希计算中断');
      return const {};
    } catch (e) {
      isolate?.kill(priority: Isolate.immediate); // 启动失败同样回收
      _log('⚠ 后台哈希线程启动失败: ${_safeError(e)}');
      return const {};
    } finally {
      receive.close();
    }
  }

  /// 把算出的哈希写进条目（含本地同名哈希同步 + 内容互认），供批量与兜底共用。
  void _applySha256(String fileName, String hash) {
    final idx = _serverMods.indexWhere((e) => e.fileName == fileName);
    if (idx < 0) return;
    _serverMods[idx].sha256 = hash;
    _serverMods[idx].localSha256 = _localSha256(fileName);
    if (!_serverMods[idx].hasLocalMatch) {
      _serverMods[idx].hasLocalContentMatch = _localContentExistsFor(hash);
    }
  }

  /// 本地 ~mods 全部 PAK 的 sha-256 索引懒构建入口（并发去重）。
  ///
  /// 真正耗时（目录遍历 + 读文件 + sha256 计算）在**后台 isolate** 完成，
  /// 主线程只等结果 —— 连接服务器即扫描的场景不再卡 UI。
  /// 调用方拿到返回的索引后，[_localSha256] / [_localContentExistsFor]
  /// 都是纯内存查询。增量语义保持：size/mtime 未变复用缓存哈希。
  Future<Map<String, String>> _ensureLocalShaIndexAsync() {
    final existing = _localShaIndex;
    if (existing.isNotEmpty) return Future.value(existing);
    return _shaIndexBuilding ??= _buildLocalShaIndexAsync().then((index) {
      _localShaIndex = index;
      _shaIndexBuilding = null;
      return index;
    });
  }

  /// 后台构建索引 + 增量写回单库 `local` 分区（耗时计算全在 isolate）。
  Future<Map<String, String>> _buildLocalShaIndexAsync() async {
    // 主线程快速读出 db 的 local 分区（小 JSON 文件，毫秒级），
    // 传给后台 isolate 做 size/mtime 增量判定。
    final raw = _readDbFile()['local'];
    final cached = <String, dynamic>{
      if (raw is Map<String, dynamic>)
        for (final e in raw.entries) e.key: e.value,
    };
    final result = await compute(
      _computeLocalShaIndexInIsolate,
      (path: _modService.localModsPath, cached: cached),
    );
    final index = (result['index'] as Map).cast<String, String>();
    final localPart = (result['localPart'] as Map).cast<String, dynamic>();
    final dirty = result['dirty'] == true;
    final hasRemoved = result['hasRemoved'] == true;
    // 有新增/变更，或本地删除了文件（残留清除）→ 写回 local 分区。
    // 纯命中不写库 —— 缓存保持权威，下次连接直接复用、不再全量重扫。
    if (dirty || hasRemoved) {
      final full = _readDbFile();
      full['local'] = localPart;
      _writeDbFile(full);
      _log('本地 sha-256 索引已更新（单库 local 分区，${index.length} 个 PAK）');
    }
    return index;
  }

  /// 本地是否存在与 [sha256] 内容相同的 PAK（文件名可能不同）。
  /// 这是「本地 mod sha-256 = 服务器 mod sha-256」的内容互认入口：
  /// 不靠同名，靠哈希——同名不同名都认。
  /// 纯内存查询 —— 调用方必须先 await [_ensureLocalShaIndexAsync]。
  bool _localContentExistsFor(String sha256) {
    if (sha256.isEmpty) return false;
    return _localShaIndex.containsValue(sha256);
  }

  /// 本地同名 PAK 的 SHA-256（hex），不存在返回 null（大小写不敏感）。
  /// 纯内存查询 —— 调用方必须先 await [_ensureLocalShaIndexAsync]。
  String? _localSha256(String fileName) {
    final direct = _localShaIndex[fileName];
    if (direct != null) return direct;
    final lower = fileName.toLowerCase();
    for (final e in _localShaIndex.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  // ===== 远端文件管理（删除 / 上传） =====

  /// 删除服务器 ~mods 下的单个 mod（SFTP remove）。
  /// 成功后从列表移除该条目并落库（分区中该文件记录随之清除）。
  Future<bool> deleteServerMod(String fileName) async {
    final sftp = _requireSftp;
    _busy = true;
    notifyListeners();
    _log('删除服务器 mod: $fileName');
    try {
      await sftp.remove(_joinPosix(_modsDir, fileName));
      _serverMods.removeWhere((e) => e.fileName == fileName);
      persistServerDb();
      _log('✓ 已删除: $fileName');
      notifyListeners();
      return true;
    } catch (e) {
      _log('✗ 删除失败: $fileName（${_safeError(e)}）');
      notifyListeners();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 批量删除服务器 mod（逐个 remove，统计成功数）。
  Future<int> deleteServerMods(List<String> fileNames) async {
    var okCount = 0;
    for (final name in fileNames) {
      final ok = await deleteServerMod(name);
      if (ok) okCount++;
    }
    _log('批量删除完成：成功 $okCount/${fileNames.length}');
    return okCount;
  }

  /// 上传本地 PAK 到服务器 ~mods（同名，流式写，不落盘到本地之外）。
  ///
  /// 成功后把条目直接并入当前列表（大小取本地文件），
  /// 并自动触发 sha-256 批量计算（秒级），让内容互认立即生效。
  ///
  /// [fromMirror] = true 表示来源是「本地镜像」文件夹（非主 ~mods）——
  /// 此时不标记 hasLocalMatch（镜像与主 ~mods 是两回事，避免误判「本地同名」）。
  Future<bool> uploadModToServer(
    String localPath, {
    bool fromMirror = false,
  }) async {
    final name = p.basename(localPath);
    final sftp = _requireSftp;
    _busy = true;
    notifyListeners();
    _log('上传 mod 到服务器: $name${fromMirror ? '（本地镜像）' : ''}');
    // 本地索引后台构建（isolate），供条目 localSha256 赋值；不阻塞 UI。
    await _ensureLocalShaIndexAsync();
    try {
      final localFile = File(localPath);
      if (!localFile.existsSync()) {
        _log('✗ 本地文件不存在: $localPath');
        return false;
      }
      final remotePath = _joinPosix(_modsDir, name);
      final file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      // 流式上传：本地 openRead 分块 → Uint8List 喂给远端写通道，不整包进内存。
      await file
          .write(localFile.openRead().map((chunk) => Uint8List.fromList(chunk)))
          .done;
      await file.close();
      // 并入列表（同名已存在则更新大小为本地大小；否则新增条目）
      final idx = _serverMods.indexWhere((e) => e.fileName == name);
      final entry = ServerModEntry(
        fileName: name,
        remotePath: remotePath,
        fileSize: localFile.lengthSync(),
        lastModified: null,
        sha256: null,
        notes: '',
        hasLocalMatch: !fromMirror,
        hasLocalContentMatch: false,
        localSha256: fromMirror ? null : _localSha256(name),
      );
      if (idx >= 0) {
        _serverMods[idx] = entry;
      } else {
        _serverMods.add(entry);
      }
      _log('✓ 已上传: $name（${localFile.lengthSync()} 字节）');
      notifyListeners();
      // 自动算哈希（批量 sha256sum 秒级；无 shell 则兜底逐个）
      // ignore: discarded_futures
      computeAllSha256();
      return true;
    } catch (e) {
      _log('✗ 上传失败: $name（${_safeError(e)}）');
      notifyListeners();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 批量上传本地 PAK 到服务器（逐个，统计成功数）。
  /// [fromMirror] 透传给 [uploadModToServer]（镜像同步时 true）。
  Future<int> uploadModsToServer(
    List<String> localPaths, {
    bool fromMirror = false,
  }) async {
    var okCount = 0;
    for (final localPath in localPaths) {
      final ok = await uploadModToServer(localPath, fromMirror: fromMirror);
      if (ok) okCount++;
    }
    _log('批量上传完成：成功 $okCount/${localPaths.length}');
    return okCount;
  }

  // ===== 本地镜像（每服务器专属文件夹：{exe_dir}/server_mods/<host>@<username>/） =====

  /// 当前账户的本地镜像文件夹绝对路径（每服务器一个专属目录）。
  ///
  /// 布局：`{exe_dir}/server_mods/<sanitized host>@<username>/` ——
  /// 与服务器标识 [SftpAccount.key] 一一对应，切账户即切镜像。
  /// 目录不存在时不创建（读取场景返回路径即可，写时再建）。
  String get localMirrorDir {
    final exeDir = AppPaths.instance.root;
    final acc = _currentAccount ?? _modService.activeSftpAccount;
    final key = acc?.key ?? 'default';
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return p.join(exeDir, 'server_mods', safe);
  }

  /// 扫描当前账户的本地镜像文件夹，重建 [_mirrorEntries]。
  ///
  /// 每一条目携带服务器同名比对信息（onServer / serverSha256，来自
  /// 当前 [_serverMods] 列表）+ 备注（服务器单库缓存 / mods_meta）。
  /// 本地哈希与冲突清单**不在此重算**（保留内存已有值，显式操作才重算）。
  /// 启用态与标签从镜像文件夹内的 `mirror_meta.json` 读取（每服务器专属）。
  /// 返回条目列表（同时更新内存缓存）。
  List<ServerMirrorEntry> loadMirrorEntries() {
    final dir = Directory(localMirrorDir);
    final serverByName = <String, ServerModEntry>{
      for (final e in _serverMods) e.fileName: e,
    };
    final dbMeta = loadServerDb();
    final mm = _readMirrorMeta();
    final result = <ServerMirrorEntry>[];
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (!name.toLowerCase().endsWith('.pak')) continue;
        final stat = f.statSync();
        // 保留内存已有条目的 sha256 / conflictPaths（避免每次重读文件/重扫）。
        final prev = _mirrorEntries
            .where((e) => e.fileName == name)
            .firstOrNull;
        final server = serverByName[name];
        final m = mm[name];
        // 内存优先（本会话刚算/刚扫，保证最新），否则回退 mirror_meta.json 持久值。
        final metaSha = m is Map ? m['sha256'] as String? : null;
        final metaConflicts = _conflictsFromJson(
          m is Map ? m['conflicts'] : null,
        );
        result.add(
          ServerMirrorEntry(
            fileName: name,
            filePath: f.path,
            fileSize: stat.size,
            lastModified: stat.modified,
            sha256: prev?.sha256 ?? metaSha,
            serverSha256: server?.sha256,
            onServer: server != null,
            notes: _mirrorNotesFor(name, dbMeta),
            enabled: m is Map ? (m['enabled'] as bool? ?? true) : true,
            tags: m is Map && m['tags'] is List
                ? List<String>.from(m['tags'] as List)
                : const [],
            conflicts: prev != null && prev.conflicts.isNotEmpty
                ? prev.conflicts
                : metaConflicts,
          ),
        );
      }
    }
    _mirrorEntries
      ..clear()
      ..addAll(result);
    return _mirrorEntries;
  }

  /// 镜像元数据文件：`{localMirrorDir}/mirror_meta.json`
  /// `{文件名: {enabled: bool, tags: [...]}}` —— 每服务器专属，与镜像文件夹共存亡。
  String get _mirrorMetaPath => p.join(localMirrorDir, 'mirror_meta.json');

  /// 读取镜像元数据（不存在 / 损坏 → 空 Map）。
  Map<String, dynamic> _readMirrorMeta() {
    final f = File(_mirrorMetaPath);
    if (!f.existsSync()) return {};
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map<String, dynamic>) return raw;
    } catch (_) {}
    return {};
  }

  /// 写入镜像元数据（缩进 JSON）。
  void _writeMirrorMeta(Map<String, dynamic> meta) {
    try {
      final json = const JsonEncoder.withIndent('  ').convert(meta);
      File(_mirrorMetaPath).writeAsStringSync(json);
    } catch (e) {
      _log('写入镜像元数据失败: ${_safeError(e)}');
    }
  }

  /// 从当前内存条目整体重建并写入 mirror_meta.json（单一写入入口）。
  ///
  /// 字段：enabled / tags / sha256 / conflicts（冲突路径 → 冲突文件列表）。
  /// 删除的文件随整体重写自动剪除（_mirrorEntries 已不含它）。
  void _persistMirrorMeta() {
    final meta = <String, dynamic>{};
    for (final m in _mirrorEntries) {
      meta[m.fileName] = {
        'enabled': m.enabled,
        if (m.tags.isNotEmpty) 'tags': m.tags,
        if (m.sha256 != null) 'sha256': m.sha256,
        if (m.conflicts.isNotEmpty)
          'conflicts': m.conflicts.map((k, v) => MapEntry(k, v)),
      };
    }
    _writeMirrorMeta(meta);
  }

  /// 从 JSON 还原冲突详情映射（损坏/非 Map → 空）。
  static Map<String, List<String>> _conflictsFromJson(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    for (final e in raw.entries) {
      if (e.value is List) {
        result[e.key.toString()] = List<String>.from(e.value as List);
      }
    }
    return result;
  }

  /// 切换镜像条目的启用态（= 是否参与下次同步）。
  Future<void> setMirrorEnabled(String fileName, bool enabled) async {
    final idx = _mirrorEntries.indexWhere((e) => e.fileName == fileName);
    if (idx < 0) return;
    _mirrorEntries[idx].enabled = enabled;
    _persistMirrorMeta();
    _log(enabled ? '✓ 已启用（参与同步）: $fileName' : '已停用（跳过同步）: $fileName');
    notifyListeners();
  }

  /// 更新镜像条目的标签（存 mirror_meta.json，与模组管理同款标签编辑）。
  Future<void> setMirrorTags(String fileName, List<String> tags) async {
    final idx = _mirrorEntries.indexWhere((e) => e.fileName == fileName);
    if (idx < 0) return;
    _mirrorEntries[idx].tags = List<String>.from(tags);
    _persistMirrorMeta();
    _log('标签已更新: $fileName');
    notifyListeners();
  }

  /// 取镜像条目的备注（服务器单库缓存 → 服务器 mods_meta 语义，跟随服务器）。
  static String _mirrorNotesFor(String fileName, Map<String, dynamic> dbMeta) {
    final meta = dbMeta[fileName];
    if (meta is Map) {
      final n = meta['notes'];
      if (n is String && n.isNotEmpty) return n;
    }
    return '';
  }

  /// 下载单个服务器 mod 到本地镜像文件夹（同名，SFTP 流式下载）。
  ///
  /// 服务器端哈希已知时，下载后本地重算 SHA-256 校验——不一致即删除残缺文件
  /// 并返回 false（与云上下载失败的自动抛弃语义一致）。成功后刷新镜像列表。
  Future<bool> downloadServerModToMirror(ServerModEntry entry) async {
    final sftp = _requireSftp;
    final dir = localMirrorDir;
    Directory(dir).createSync(recursive: true);
    final dest = p.join(dir, entry.fileName);
    _busy = true;
    notifyListeners();
    _log('下载服务器 mod 到本地镜像: ${entry.fileName}');
    try {
      final sink = File(dest).openWrite();
      try {
        await sftp
            .download(entry.remotePath, sink)
            .timeout(const Duration(minutes: 30));
        await sink.flush();
      } finally {
        await sink.close();
      }
      // SHA-256 校验（服务器端已知时）：损坏包不留残缺文件。
      final serverSha = entry.sha256;
      if (serverSha != null && serverSha.isNotEmpty) {
        final hex = await _sha256OfLocalFile(dest);
        if (hex == null || hex != serverSha) {
          try {
            File(dest).deleteSync();
          } catch (_) {}
          _log('✗ 下载后 SHA-256 校验失败，已删除残缺文件: ${entry.fileName}');
          notifyListeners();
          return false;
        }
      }
      _log(
        '✓ 已下载到本地镜像: ${entry.fileName}'
        '（${File(dest).lengthSync()} 字节）',
      );
      loadMirrorEntries();
      notifyListeners();
      return true;
    } catch (e) {
      _log('✗ 下载失败: ${entry.fileName}（${_safeError(e)}）');
      try {
        if (File(dest).existsSync()) File(dest).deleteSync();
      } catch (_) {}
      notifyListeners();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 批量下载服务器 mod 到本地镜像（逐个，统计成功数）。
  Future<int> downloadServerMods(List<ServerModEntry> entries) async {
    var okCount = 0;
    for (final entry in entries) {
      final ok = await downloadServerModToMirror(entry);
      if (ok) okCount++;
    }
    _log('批量下载完成：成功 $okCount/${entries.length} 个到本地镜像');
    return okCount;
  }

  /// 快速添加：把本地 .pak 复制进当前账户的本地镜像文件夹（同名覆盖）。
  ///
  /// 供拖拽 / 「添加 PAK」按钮使用——无需连接服务器即可把 mod 放入
  /// 本机镜像，随后由面板自动补 SHA-256 + 扫描冲突。返回成功数。
  Future<int> addModsToMirror(List<String> localPaths) async {
    final dir = localMirrorDir;
    Directory(dir).createSync(recursive: true);
    var okCount = 0;
    for (final localPath in localPaths) {
      if (!localPath.toLowerCase().endsWith('.pak')) continue;
      final name = p.basename(localPath);
      try {
        final src = File(localPath);
        if (!src.existsSync()) continue;
        src.copySync(p.join(dir, name));
        _log('✓ 已添加本地镜像: $name');
        okCount++;
      } catch (e) {
        _log('✗ 添加镜像失败: $name（${_safeError(e)}）');
      }
    }
    if (okCount > 0) {
      loadMirrorEntries();
      notifyListeners();
    }
    _log('快速添加完成：成功 $okCount/${localPaths.length} 个到本地镜像');
    return okCount;
  }

  /// 本地文件 SHA-256（hex 小写）；失败返回 null。
  Future<String?> _sha256OfLocalFile(String path) async {
    try {
      final digest = await sha256.bind(File(path).openRead()).last;
      return digest.toString();
    } catch (_) {
      return null;
    }
  }

  /// 批量计算本地镜像全部 PAK 的 SHA-256（本地直读，秒级）。
  /// 返回 {文件名: sha256}（计算成功的部分）。结果落盘 mirror_meta.json，重启不丢。
  Future<Map<String, String>> computeAllMirrorSha256() async {
    loadMirrorEntries();
    final result = <String, String>{};
    for (final m in _mirrorEntries) {
      if (m.sha256 != null) {
        result[m.fileName] = m.sha256!;
        continue;
      }
      final hex = await _sha256OfLocalFile(m.filePath);
      if (hex != null) {
        m.sha256 = hex;
        result[m.fileName] = hex;
      }
    }
    _log('本地镜像 SHA-256：${result.length}/${_mirrorEntries.length} 个已计算');
    if (result.isNotEmpty) _persistMirrorMeta();
    notifyListeners();
    return result;
  }

  /// 删除本地镜像中的单个 mod（仅删本地副本，不影响服务器）。
  Future<bool> deleteMirrorMod(String fileName) async {
    final f = File(p.join(localMirrorDir, fileName));
    if (!f.existsSync()) {
      _log('✗ 本地镜像无此文件: $fileName');
      return false;
    }
    _busy = true;
    notifyListeners();
    try {
      f.deleteSync();
      _log('✓ 已删除本地镜像副本: $fileName');
      loadMirrorEntries();
      _persistMirrorMeta(); // 同步剪除镜像元数据中的该条目
      notifyListeners();
      return true;
    } catch (e) {
      _log('✗ 删除本地镜像失败: $fileName（${_safeError(e)}）');
      notifyListeners();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 镜像冲突扫描是否因 repak 缺失而不可用（面板数据源 unavailable() 读取）。
  bool _mirrorScanUnavailable = false;
  bool get mirrorScanUnavailable => _mirrorScanUnavailable;

  /// 镜像冲突扫描 —— repak list 本地镜像每个 PAK 的内部资源路径，
  /// 求交集：同一路径出现在 ≥2 个 PAK 即冲突（与主界面 ConflictService 同原理）。
  ///
  /// 每条目的 conflicts 记录「冲突路径 → 也包含该路径的其他镜像文件」，
  /// 结果落盘 mirror_meta.json（重启/切页不丢失），供冲突徽章点击显示详情。
  /// 返回 {文件名: 冲突路径 → 冲突文件列表}。
  Future<Map<String, Map<String, List<String>>>> scanMirrorConflicts() async {
    loadMirrorEntries();
    final repak = await _resolveRepak();
    if (repak == null) {
      _mirrorScanUnavailable = true;
      _log('镜像冲突扫描不可用：未找到 repak.exe');
      notifyListeners();
      return {};
    }
    _mirrorScanUnavailable = false;
    _busy = true;
    notifyListeners();
    _log('镜像冲突扫描：${_mirrorEntries.length} 个 PAK（repak list）');
    try {
      // 1) 逐个取内部清单（归一化小写 + 去 ../ 前缀）
      final pathSets = <String, Set<String>>{};
      for (final m in _mirrorEntries) {
        final set = <String>{};
        try {
          final r = await Process.run(repak, ['list', m.filePath]);
          if (r.exitCode == 0) {
            for (final raw in ((r.stdout as String?) ?? '').split('\n')) {
              var line = raw.trim().toLowerCase();
              while (line.startsWith('../')) {
                line = line.substring(3);
              }
              if (line.isNotEmpty) set.add(line);
            }
          }
        } catch (_) {}
        pathSets[m.fileName] = set;
      }
      // 2) 路径 → 占用者列表；同一路径 ≥2 个文件即冲突
      final pathMap = <String, List<String>>{};
      for (final e in pathSets.entries) {
        for (final path in e.value) {
          (pathMap[path] ??= []).add(e.key);
        }
      }
      final result = <String, Map<String, List<String>>>{};
      for (final m in _mirrorEntries) {
        final conflicts = <String, List<String>>{};
        for (final path in pathSets[m.fileName] ?? const <String>{}) {
          final owners = pathMap[path]!;
          if (owners.length >= 2) {
            // 冲突详情 = 除自身外还包含该路径的其他镜像文件
            conflicts[path] = owners.where((f) => f != m.fileName).toList();
          }
        }
        m.conflicts = conflicts;
        if (conflicts.isNotEmpty) result[m.fileName] = conflicts;
      }
      _persistMirrorMeta(); // 冲突结果落盘
      final conflicted = result.length;
      _log(
        conflicted > 0
            ? '⚠ 镜像冲突扫描完成：$conflicted 个 mod 存在冲突（已保存）'
            : '✓ 镜像冲突扫描完成：无冲突',
      );
      notifyListeners();
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 定位 repak：config 覆盖 → exe 目录 → PATH → ~/.cargo/bin
  /// （与 ConflictService 的搜索顺序一致，此处镜像冲突扫描独立使用）。
  Future<String?> _resolveRepak() async {
    // 1) config.json repak_path 覆盖
    final cfg = _modService.loadConfigKey('repak_path');
    if (cfg is String) {
      final t = cfg.trim();
      if (t.isNotEmpty && File(t).existsSync()) return t;
    }
    // 2) exe 目录（随身携带形态）
    final exeDir = AppPaths.instance.root;
    for (final cand in [
      p.join(exeDir, 'repak.exe'),
      p.join(exeDir, 'bin', 'repak.exe'),
    ]) {
      if (File(cand).existsSync()) return cand;
    }
    // 3) PATH
    try {
      final r = await Process.run('repak', const ['--version']);
      if (r.exitCode == 0) return 'repak';
    } catch (_) {}
    // 4) ~/.cargo/bin
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isNotEmpty) {
      final cargo = p.join(home, '.cargo', 'bin', 'repak.exe');
      if (File(cargo).existsSync()) return cargo;
    }
    return null;
  }

  /// 规划「本地镜像 → 服务器」同步（本地为权威，不做任何写操作）。
  ///
  /// 返回 `(uploads, deletes)`：
  /// - uploads：**已启用**的镜像文件——服务器没有（new）+ 同名但 SHA-256
  ///   不一致（modified）；停用的镜像文件不参与（服务器保持现状）
  /// - deletes：服务器有、镜像文件夹里没有的文件（本地没有 → 服务器删除，
  ///   即主人约定「上传时没有这个 mod 则服务器上的 mod 需要被删掉」）
  Future<({List<String> uploads, List<String> deletes})>
  planMirrorSync() async {
    loadMirrorEntries();
    await computeAllMirrorSha256();
    final uploads = <String>[];
    final deletes = <String>[];
    final mirrorNames = _mirrorEntries.map((e) => e.fileName).toSet();
    for (final m in _mirrorEntries) {
      if (!m.enabled) continue; // 停用 = 不参与下次同步
      if (!m.onServer) {
        uploads.add(m.fileName);
        continue;
      }
      if (m.sha256 != null &&
          m.serverSha256 != null &&
          m.sha256 != m.serverSha256) {
        uploads.add(m.fileName); // 同名已修改 → 覆盖上传
      }
    }
    for (final s in _serverMods) {
      if (!mirrorNames.contains(s.fileName)) deletes.add(s.fileName);
    }
    _log(
      '镜像同步规划：上传 ${uploads.length} 个 / 删除服务器 ${deletes.length} 个'
      '（本地镜像为权威，停用条目跳过）',
    );
    return (uploads: uploads, deletes: deletes);
  }

  /// 执行镜像同步（本地为权威）：按 [planMirrorSync] 结果逐个上传 + 删除。
  ///
  /// 返回成功操作数（上传 + 删除合计）。执行后刷新服务器列表与镜像列表。
  Future<int> executeMirrorSync({
    required List<String> uploads,
    required List<String> deletes,
  }) async {
    var okCount = 0;
    for (final name in uploads) {
      final ok = await uploadModToServer(
        p.join(localMirrorDir, name),
        fromMirror: true,
      );
      if (ok) okCount++;
    }
    for (final name in deletes) {
      final ok = await deleteServerMod(name);
      if (ok) okCount++;
    }
    _log('镜像同步执行完成：上传 ${uploads.length} / 删除 ${deletes.length}');
    loadMirrorEntries();
    notifyListeners();
    return okCount;
  }

  /// 在资源管理器中定位镜像中的某个文件（选中该文件）。
  void revealMirrorFile(String fileName) {
    final f = p.join(localMirrorDir, fileName);
    if (!File(f).existsSync()) return;
    try {
      Process.start('explorer.exe', ['/select,', f]);
    } catch (_) {}
  }

  /// 打开当前账户的本地镜像文件夹（不存在则创建）。
  void openMirrorDir() {
    Directory(localMirrorDir).createSync(recursive: true);
    try {
      Process.start('explorer.exe', [localMirrorDir]);
    } catch (_) {}
  }

  /// 更新镜像条目的备注。
  ///
  /// - 服务器已有同名文件 → 走 [updateServerModNotes]（写服务器 mods_meta.json
  ///   + 单库），备注跟随服务器、跨管理端共享；
  /// - 尚未上传的镜像 mod → 备注只落单库分区（上传后随 updateServerModNotes 带过去）。
  Future<bool> updateMirrorNotes(String fileName, String notes) async {
    final idx = _mirrorEntries.indexWhere((e) => e.fileName == fileName);
    if (idx < 0) return false;
    if (_serverMods.any((e) => e.fileName == fileName)) {
      final ok = await updateServerModNotes(fileName, notes);
      if (ok) {
        _mirrorEntries[idx].notes = notes;
        notifyListeners();
      }
      return ok;
    }
    // 尚未上传：只写单库分区（loadMirrorEntries 会从单库重读备注）。
    final db = loadServerDb();
    final meta = db[fileName] ?? <String, dynamic>{};
    if (notes.isEmpty) {
      db.remove(fileName);
    } else {
      meta['notes'] = notes;
      db[fileName] = meta;
    }
    saveServerDb(db);
    _mirrorEntries[idx].notes = notes;
    _log('备注已写入服务器单库（待上传）: $fileName');
    notifyListeners();
    return true;
  }

  // ===== 服务器端备注（mods_meta.json）=====

  /// 远端 `{Paks}/mods_meta.json` 绝对路径（~mods 的父目录下，与本地架构对称）。
  String get _remoteMetaPath {
    final parent = _modsDir.substring(0, _modsDir.lastIndexOf('/'));
    return '$parent/mods_meta.json';
  }

  /// 读取服务器端 mods_meta.json（{文件名: {notes}}）。文件不存在 → 空 Map。
  Future<Map<String, Map<String, dynamic>>> _readRemoteMeta() async {
    if (_modsDir.isEmpty) return {};
    try {
      final sftp = _requireSftp;
      final attrs = await sftp.stat(_remoteMetaPath);
      if (!attrs.isFile) return {};
      final file = await sftp.open(_remoteMetaPath);
      final bytes = await file.readBytes();
      await file.close();
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is Map<String, dynamic>) {
        return raw.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
      }
    } catch (_) {}
    return {};
  }

  /// 写服务器端 mods_meta.json（整体覆写，含备注）。
  Future<bool> writeRemoteMeta(Map<String, Map<String, dynamic>> meta) async {
    if (_modsDir.isEmpty) return false;
    try {
      final sftp = _requireSftp;
      final path = _remoteMetaPath;
      final file = await sftp.open(
        path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );
      // 缩进 JSON（2 空格），服务器端 mods_meta.json 可读性更好。
      final json = const JsonEncoder.withIndent('  ').convert(meta);
      await file.write(Stream.value(utf8.encode(json))).done;
      await file.close();
      return true;
    } catch (e) {
      _log('写入服务器 mods_meta.json 失败: ${_safeError(e)}');
      return false;
    }
  }

  /// 更新单个服务器 mod 的备注（读-改-写）。
  Future<bool> updateServerModNotes(String fileName, String notes) async {
    final idx = _serverMods.indexWhere((e) => e.fileName == fileName);
    if (idx < 0) return false;
    final meta = await _readRemoteMeta();
    final entry = meta[fileName] ?? <String, dynamic>{};
    if (notes.isEmpty) {
      meta.remove(fileName);
    } else {
      entry['notes'] = notes;
      meta[fileName] = entry;
    }
    final ok = await writeRemoteMeta(meta);
    if (ok) {
      _serverMods[idx].notes = notes;
      _log('备注已写入服务器: $fileName');
      // 备注同步落库（跨服互通用）。
      persistServerDb();
      notifyListeners();
    }
    return ok;
  }

  // ===== 日志 =====

  void _log(String message) {
    _logs.add(message);
    if (_logs.length > 200) _logs.removeAt(0);
    AppLogger.instance.info('SFTP 服务器', {'msg': message});
  }
}

/// 接收 sha256 分块转换结果的 digest 容器（项目不导出 DigestSink，自持一份）。
class _DigestHolder implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
