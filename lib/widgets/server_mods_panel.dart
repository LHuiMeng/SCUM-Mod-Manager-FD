/// 远程服务器面板 —— 通过 SFTP 浏览用户自己 SCUM 服务器的 ~mods 目录。
///
/// 功能（对应需求）：
/// - 顶部：连接状态 + 连接/断开按钮 + 远端 ~mods 路径
/// - 列表：每个服务器 PAK 一行 —— 文件名、大小、修改时间
/// - 每行可单独「计算 SHA-256」（三级策略：远端 sha256sum → certutil → SFTP 流式）
/// -「校验全部」批量计算 + 与本地同名文件自动比对（match/mismatch/localOnly）
/// - 每行可「编辑备注」——写入服务器端 {Paks}/mods_meta.json，跟随服务器
/// - 底部：操作日志（连接/扫描/哈希/写入的简要履历）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/mod_entry.dart';
import '../models/pak_conflict.dart';
import '../models/server_mod_entry.dart';
import '../models/sftp_account.dart';
import '../services/app_logger.dart';
import '../services/app_signals.dart';
import '../services/mod_service.dart';
import '../services/pinyin_search.dart';
import '../services/server_sftp_service.dart';
import '../services/window_service.dart';
import '../theme/scum_colors.dart';
import 'conflict_panel.dart';
import 'mod_badge.dart';
import 'mod_card_action_button.dart';
import 'mod_settings_popup.dart';
import 'mod_table.dart';
import 'tag_filter_menu.dart';

/// 服务器 mod 列表的可配置列。
const List<TableColumnSpec> serverColumnSpecs = [
  TableColumnSpec('name', '文件名', 220),
  TableColumnSpec('size', '大小', 90),
  TableColumnSpec('time', '修改时间', 140),
  TableColumnSpec('sha256', 'SHA-256', 280),
  TableColumnSpec('tags', '标签', 150),
  TableColumnSpec('notes', '备注', 160),
  TableColumnSpec('match', '校验', 100),
];

/// 本地镜像列表的可配置列（下载到本机的服务器 mod 副本，与模组管理同款）。
const List<TableColumnSpec> serverMirrorColumnSpecs = [
  TableColumnSpec('name', '名称', 200),
  TableColumnSpec('status', '状态', 100),
  TableColumnSpec('type', '类型', 90),
  TableColumnSpec('tags', '标签', 150),
  TableColumnSpec('notes', '备注', 160),
  TableColumnSpec('sha256', 'SHA-256', 280),
  TableColumnSpec('size', '大小', 90),
  TableColumnSpec('time', '时间', 140),
  TableColumnSpec('origin', '来源', 80),
  TableColumnSpec('conflict', '冲突', 80),
];

class ServerModsPanel extends StatefulWidget {
  final ModService modService;
  final ServerSftpService sftpService;

  const ServerModsPanel({
    super.key,
    required this.modService,
    required this.sftpService,
  });

  @override
  State<ServerModsPanel> createState() => _ServerModsPanelState();
}

class _ServerModsPanelState extends State<ServerModsPanel> {
  /// 当前正在计算哈希的文件名（UI 显示转圈）。
  final Set<String> _computing = {};

  /// 多选删除模式：进入后卡片显示勾选框，选完批量删除。
  bool _selectionMode = false;
  final Set<String> _selectedMods = <String>{};

  /// 搜索 / 标签 / 排序（与主界面、云面板一致的三件套）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  Set<String> _filterTags = <String>{};

  /// 当前排序列 id（null = 默认顺序）+ 方向。由表头点击切换（与本地列表一致）。
  String? _sortCol;
  bool _sortAsc = true;

  /// 服务器列配置（顺序 / 可见性 / 宽度，持久化到 config.json `server_table_columns`）。
  ColumnLayout _serverLayout = ColumnLayout(specs: serverColumnSpecs);

  /// 本地镜像列配置（持久化到 config.json `server_mirror_columns`）。
  ColumnLayout _mirrorLayout = ColumnLayout(specs: serverMirrorColumnSpecs);

  /// 当前视图模式：false = 服务器列表；true = 本地镜像（下载到本机的副本）。
  bool _showMirror = false;

  /// 本地镜像正在计算哈希的文件名（UI 显示转圈）。
  final Set<String> _mirrorComputing = {};

  /// 本地镜像是否正在冲突扫描。
  bool _mirrorScanning = false;

  @override
  void initState() {
    super.initState();
    widget.sftpService.addListener(_onSftpChanged);
    // 从 config.json 加载已保存的服务器列配置。
    _serverLayout = ColumnLayout.fromJson(
      widget.modService.loadConfigKey('server_table_columns'),
      specs: serverColumnSpecs,
    );
    // 从 config.json 加载已保存的本地镜像列配置。
    _mirrorLayout = ColumnLayout.fromJson(
      widget.modService.loadConfigKey('server_mirror_columns'),
      specs: serverMirrorColumnSpecs,
    );
    // 监听全局拖拽上传请求（HomeScreen 在 server_mods tab 下分发）。
    AppSignals.serverUploadRequest.addListener(_onServerUploadRequest);
  }

  @override
  void dispose() {
    widget.sftpService.removeListener(_onSftpChanged);
    AppSignals.serverUploadRequest.removeListener(_onServerUploadRequest);
    AppSignals.serverMirrorMode.value = false; // 离开服务器面板重置模式信号
    _mirrorAutoScanTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSftpChanged() {
    if (!mounted) return;
    setState(() {});
    // 服务器列表变化（刷新/上传/删除后）会改变镜像条目的 onServer/serverSha256，
    // 镜像模式可见时顺手重扫镜像文件夹（廉价目录遍历，不重算哈希）。
    if (_showMirror) widget.sftpService.loadMirrorEntries();
  }

  /// 服务器列配置变化 → setState 实时刷新 UI（拖宽高频不写盘）。
  void _onServerLayoutChanged(ColumnLayout layout) {
    setState(() => _serverLayout = layout);
  }

  /// 服务器列配置提交（拖宽松手 / 菜单操作后）→ 持久化。
  void _onServerLayoutCommit() {
    widget.modService.saveConfigKey(
      'server_table_columns',
      _serverLayout.toJson(),
    );
  }

  /// 本地镜像列配置变化 → setState 实时刷新 UI。
  void _onMirrorLayoutChanged(ColumnLayout layout) {
    setState(() => _mirrorLayout = layout);
  }

  /// 本地镜像列配置提交 → 持久化。
  void _onMirrorLayoutCommit() {
    widget.modService.saveConfigKey(
      'server_mirror_columns',
      _mirrorLayout.toJson(),
    );
  }

  /// 全局拖拽上传请求（HomeScreen 在 server_mods tab 下分发）。
  /// 按当前模式分流：服务器列表模式 → 上传到服务器；本地镜像模式 → 复制进镜像文件夹。
  void _onServerUploadRequest() {
    final paths = AppSignals.serverUploadRequest.value;
    if (paths == null || paths.isEmpty) return;
    AppSignals.serverUploadRequest.value = null; // 消费掉，避免重复触发
    if (_showMirror) {
      _addDroppedToMirror(paths);
    } else {
      _uploadDroppedPaths(paths);
    }
  }

  /// 拖拽添加本地镜像：过滤 .pak → 复制进镜像文件夹 → 自动补 SHA-256 + 扫冲突。
  Future<void> _addDroppedToMirror(List<String> paths) async {
    final paks = paths.where((p) => p.toLowerCase().endsWith('.pak')).toList();
    if (paks.isEmpty) {
      _showToast('拖入的不是 .pak 文件', color: ScumColors.of(context).danger);
      return;
    }
    final ok = await widget.sftpService.addModsToMirror(paks);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已添加 $ok 个 mod 到本地镜像' : '添加失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
    if (ok > 0) _scheduleMirrorAutoScan(); // 添加后自动扫描冲突
  }

  /// 镜像模式「添加 PAK」：原生文件对话框多选 → 复制进镜像文件夹 → 自动扫冲突。
  Future<void> _addMirrorViaDialog() async {
    final paths = await WindowService.openFileDialog();
    if (!mounted || paths.isEmpty) return;
    await _addDroppedToMirror(paths);
  }

  /// 拖拽上传：过滤 .pak → 校验连接 → 上传。
  void _uploadDroppedPaths(List<String> paths) {
    final paks = paths.where((p) => p.toLowerCase().endsWith('.pak')).toList();
    if (paks.isEmpty) {
      _showToast('拖入的不是 .pak 文件', color: ScumColors.of(context).danger);
      return;
    }
    if (!widget.sftpService.isConnected) {
      _showToast('请先连接服务器，再拖拽 .pak 上传');
      return;
    }
    _uploadPaths(paks);
  }

  /// 上传指定本地 PAK 列表到服务器（复用：文件对话框 / 拖拽 / 批量弹窗）。
  Future<void> _uploadPaths(List<String> paks) async {
    AppLogger.instance.ui(
      '服务器上传',
      action: '执行',
      details: {'count': paks.length},
    );
    final ok = await widget.sftpService.uploadModsToServer(paks);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已上传 $ok 个 mod 到服务器' : '上传失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
  }

  /// 连接按钮：优先用当前激活账户连接（无账户则提示去设置页）。
  ///
  /// 激活账户由 [ModService.activeSftpAccount] 提供；账户 host 若存的是完整
  /// `sftp://用户名@主机:端口` URI，先解析拆分再连接。
  Future<void> _connect() async {
    final svc = widget.sftpService;
    var account = widget.modService.activeSftpAccount;
    if (account == null) {
      _showToast('请先在设置页「服务器」Tab 添加并保存一个服务器账户');
      return;
    }
    var host = account.host;
    var user = account.username;
    var pass = account.password;
    var port = account.port;
    // 解析 URI（支持整段粘贴）：拆出用户名/主机/端口，补上 URI 内嵌密码。
    final parsed = ServerSftpService.parseSftpUri(host);
    if (parsed != null && parsed.host.isNotEmpty) {
      host = parsed.host;
      // 仅当 URI 显式带端口才覆盖；否则沿用账户端口（可能非 22）。
      final parsedPort = parsed.port;
      if (parsedPort != null) port = parsedPort;
      final parsedUser = parsed.username;
      if (parsedUser != null && parsedUser.isNotEmpty) {
        user = parsedUser;
      }
      final parsedPass = parsed.password;
      if (parsedPass != null && parsedPass.isNotEmpty) {
        pass = parsedPass;
      }
    }
    if (host.isEmpty || user.isEmpty) {
      _showToast('账户缺少主机或用户名，请在设置页补全');
      return;
    }
    final colors = ScumColors.of(context);
    final ok = await svc.connect(
      host: host,
      port: port,
      username: user,
      password: pass,
    );
    if (!mounted) return;
    _showToast(
      ok ? '已连接 ${account.displayName}' : '连接失败，请检查账户凭据',
      color: ok ? colors.success : colors.danger,
    );
    if (ok) {
      // 自动定位 ~mods（若账户未保存路径）
      if (svc.modsDir.isEmpty) {
        await svc.locateModsDir();
        if (mounted && svc.modsDir.isNotEmpty) {
          await svc.refreshServerMods();
        }
      } else {
        await svc.refreshServerMods();
      }
    }
  }

  /// 切换到另一账户：更新激活账户 → 断开旧会话 → 自动重连。
  Future<void> _switchAccount(SftpAccount account) async {
    widget.modService.setActiveSftpAccount(account.name);
    await widget.sftpService.disconnect();
    if (!mounted) return;
    _showToast('已切换账户：${account.displayName}');
    await _connect();
  }

  void _disconnect() {
    widget.sftpService.disconnect();
  }

  /// 刷新服务器 mod 列表。
  Future<void> _refresh() async {
    final ok = await widget.sftpService.refreshServerMods();
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok ? '已刷新服务器列表' : '刷新失败',
      color: ok ? colors.success : colors.danger,
    );
  }

  /// 计算单个文件 SHA-256。
  Future<void> _computeOne(String fileName) async {
    final entry = widget.sftpService.serverMods
        .where((e) => e.fileName == fileName)
        .firstOrNull;
    if (entry == null) return;
    setState(() => _computing.add(fileName));
    await widget.sftpService.computeSha256(entry);
    if (!mounted) return;
    setState(() => _computing.remove(fileName));
  }

  /// 批量校验全部（跳过已计算的）。
  Future<void> _computeAll() async {
    final colors = ScumColors.of(context);
    setState(() {
      _computing.addAll(
        widget.sftpService.serverMods
            .where((e) => e.sha256 == null)
            .map((e) => e.fileName),
      );
    });
    await widget.sftpService.computeAllSha256();
    if (!mounted) return;
    setState(_computing.clear);
    _showToast('SHA-256 校验完成', color: colors.success);
  }

  /// 隐藏式备注互换：备注源优先级 = 云上 > 本服务器 > 其他服务器。
  ///
  /// 返回值：`(显示文案, 来源)`，来源 ∈ {'cloud', 'server', 'other'}，
  /// 仅用作细微的来源标识，不出现「其他服务器也装了此 mod」类提示横幅。
  (String, String) _effectiveNotes(ServerModEntry entry) {
    final svc = widget.sftpService;
    final sha = entry.sha256;
    if (sha != null) {
      final cloud = svc.cloudNotesBySha256(sha);
      if (cloud != null) return (cloud, 'cloud');
    }
    if (entry.notes.isNotEmpty) return (entry.notes, 'server');
    if (sha != null) {
      final other = svc.otherServerNotesBySha256(sha);
      if (other != null) return (other, 'other');
    }
    return ('', 'server');
  }

  /// 服务器面板显示列表（搜索 + 标签 + 排序后）。标签源 = 云上标签（sha-256 互换）。
  List<ServerModEntry> get _visibleServerMods {
    final svc = widget.sftpService;
    var list = svc.serverMods;
    final q = _searchQuery.trim();
    if (q.isNotEmpty) {
      list = list.where((e) {
        // 拼音/首字母检索：文件名 / 服务器备注 / 云上备注任一命中即可。
        if (PinyinSearch.matches(e.fileName, q)) return true;
        if (PinyinSearch.matches(e.notes, q)) return true;
        final cloudNotes = e.sha256 == null
            ? null
            : svc.cloudNotesBySha256(e.sha256!);
        if (cloudNotes != null && PinyinSearch.matches(cloudNotes, q)) {
          return true;
        }
        return false;
      }).toList();
    }
    if (_filterTags.isNotEmpty) {
      list = list.where((e) {
        if (e.sha256 == null) return false;
        return svc.cloudTagsBySha256(e.sha256!).any(_filterTags.contains);
      }).toList();
    }
    if (_sortCol != null) {
      final col = _sortCol!;
      final asc = _sortAsc;
      final copy = List<ServerModEntry>.from(list);
      copy.sort(
        (a, b) =>
            asc ? _compareServerMods(a, b, col) : _compareServerMods(b, a, col),
      );
      list = copy;
    }
    return list;
  }

  /// 时间比较：null 排末尾。
  static int _cmpTime(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  /// 按列比较两个服务器 mod（升序语义；降序由调用方交换操作数，保证空值/空串排尾）。
  int _compareServerMods(ServerModEntry a, ServerModEntry b, String col) {
    final svc = widget.sftpService;
    switch (col) {
      case 'name':
        return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
      case 'size':
        return a.fileSize.compareTo(b.fileSize);
      case 'time':
        return _cmpTime(a.lastModified, b.lastModified);
      case 'sha256':
        return _cmpStr(a.sha256 ?? '', b.sha256 ?? '');
      case 'tags':
        final ta = a.sha256 == null
            ? ''
            : svc.cloudTagsBySha256(a.sha256!).join(' ');
        final tb = b.sha256 == null
            ? ''
            : svc.cloudTagsBySha256(b.sha256!).join(' ');
        return _cmpStr(ta, tb);
      case 'notes':
        return _cmpStr(_effectiveNotes(a).$1, _effectiveNotes(b).$1);
      case 'match':
        return _cmpStr(a.matchStatus, b.matchStatus);
      default:
        return 0;
    }
  }

  /// 字符串比较：空串排末尾（升序语义，不参与方向翻转）。
  static int _cmpStr(String a, String b) {
    final na = a.trim().toLowerCase();
    final nb = b.trim().toLowerCase();
    if (na.isEmpty && nb.isEmpty) return 0;
    if (na.isEmpty) return 1;
    if (nb.isEmpty) return -1;
    return na.compareTo(nb);
  }

  /// 表头点击排序：新列 → 按该列默认方向；同列连点 → 升序/降序/恢复默认循环。
  void _onHeaderSort(String colId) {
    setState(() {
      if (_sortCol != colId) {
        _sortCol = colId;
        _sortAsc = _sortFirstAsc(colId);
      } else if (_sortAsc == _sortFirstAsc(colId)) {
        _sortAsc = !_sortAsc; // 同列：翻到另一方向（升↔降）
      } else {
        _sortCol = null; // 再点：恢复默认顺序
        _sortAsc = true;
      }
    });
  }

  /// 首次点击某列的默认方向：大小/时间这类数值列降序更常用，其余列升序。
  static bool _sortFirstAsc(String colId) => colId != 'size' && colId != 'time';

  /// 全部可筛选标签（聚合各服务器条目的云上标签，含本服务器无标签的条目）。
  Set<String> get _allServerTags {
    final svc = widget.sftpService;
    final tags = <String>{};
    for (final e in svc.serverMods) {
      if (e.sha256 != null) tags.addAll(svc.cloudTagsBySha256(e.sha256!));
    }
    return tags;
  }

  bool get _hasServerFilter =>
      _searchQuery.isNotEmpty || _filterTags.isNotEmpty || _sortCol != null;

  /// 一键清除搜索/标签/排序。
  void _clearServerFilter() {
    _searchCtrl.clear();
    setState(() {
      _searchQuery = '';
      _filterTags = <String>{};
      _sortCol = null;
      _sortAsc = true;
    });
  }

  // ===== 本地镜像（下载到本机的服务器 mod 副本）=====

  /// 本地镜像可见列表（搜索 + 标签 + 排序后）。
  List<ServerMirrorEntry> get _visibleMirrorMods {
    final svc = widget.sftpService;
    var list = svc.loadMirrorEntries();
    final q = _searchQuery.trim();
    if (q.isNotEmpty) {
      list = list.where((e) {
        if (PinyinSearch.matches(e.fileName, q)) return true;
        if (PinyinSearch.matches(e.notes, q)) return true;
        final cloudNotes = e.sha256 == null
            ? null
            : svc.cloudNotesBySha256(e.sha256!);
        if (cloudNotes != null && PinyinSearch.matches(cloudNotes, q)) {
          return true;
        }
        return false;
      }).toList();
    }
    if (_filterTags.isNotEmpty) {
      list = list.where((e) {
        if (e.sha256 == null) return false;
        return svc.cloudTagsBySha256(e.sha256!).any(_filterTags.contains);
      }).toList();
    }
    if (_sortCol != null) {
      final col = _sortCol!;
      final asc = _sortAsc;
      final copy = List<ServerMirrorEntry>.from(list);
      copy.sort(
        (a, b) =>
            asc ? _compareMirrorMods(a, b, col) : _compareMirrorMods(b, a, col),
      );
      list = copy;
    }
    return list;
  }

  /// 按列比较两个镜像条目（升序语义；降序由调用方交换操作数）。
  int _compareMirrorMods(ServerMirrorEntry a, ServerMirrorEntry b, String col) {
    switch (col) {
      case 'name':
        return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
      case 'status':
        return _cmpStr(a.mirrorStatus, b.mirrorStatus);
      case 'type':
        return 0; // 镜像全是服务端 PAK，类型相同
      case 'tags':
        return _cmpStr(a.tags.join(' '), b.tags.join(' '));
      case 'notes':
        return _cmpStr(
          _mirrorEffectiveNotes(a).$1,
          _mirrorEffectiveNotes(b).$1,
        );
      case 'sha256':
        return _cmpStr(a.sha256 ?? '', b.sha256 ?? '');
      case 'size':
        return a.fileSize.compareTo(b.fileSize);
      case 'time':
        return _cmpTime(a.lastModified, b.lastModified);
      case 'origin':
        return 0; // 镜像全部来自服务器
      case 'conflict':
        return a.conflictCount.compareTo(b.conflictCount);
      default:
        return 0;
    }
  }

  /// 镜像备注（隐藏式互换：云上 > 本服务器 > 其他服务器，与服务器列表同语义）。
  (String, String) _mirrorEffectiveNotes(ServerMirrorEntry entry) {
    final svc = widget.sftpService;
    final sha = entry.sha256;
    if (sha != null) {
      final cloud = svc.cloudNotesBySha256(sha);
      if (cloud != null) return (cloud, 'cloud');
    }
    if (entry.notes.isNotEmpty) return (entry.notes, 'server');
    if (sha != null) {
      final other = svc.otherServerNotesBySha256(sha);
      if (other != null) return (other, 'other');
    }
    return ('', 'server');
  }

  /// 切换视图模式（服务器列表 ↔ 本地镜像）。
  void _setShowMirror(bool show) {
    if (_showMirror == show) return;
    setState(() => _showMirror = show);
    AppSignals.serverMirrorMode.value = show; // 供拖拽遮罩按语境显示文案
    if (show) {
      widget.sftpService.loadMirrorEntries();
      _clearServerFilter();
      _scheduleMirrorAutoScan();
    }
  }

  /// 镜像自动扫描防抖计时器（进入镜像模式后 300ms 触发一次）。
  Timer? _mirrorAutoScanTimer;

  /// 进入镜像模式后自动扫描：先补 sha-256（状态列需要），再扫冲突。
  /// 防抖合并快速来回切换。
  void _scheduleMirrorAutoScan() {
    _mirrorAutoScanTimer?.cancel();
    _mirrorAutoScanTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || !_showMirror) return;
      final entries = widget.sftpService.mirrorEntries;
      if (entries.isEmpty) return;
      // ignore: discarded_futures
      _autoScanMirror();
    });
  }

  /// 自动扫描本体：缺失的 sha-256 先补算（本地直读，秒级，状态列据此显示），
  /// 再跑冲突扫描（结果落盘 mirror_meta.json）。
  Future<void> _autoScanMirror() async {
    if (_mirrorScanning) {
      // 扫描进行中：等它结束后顺延补扫一遍（新拖入/添加的文件也纳入）。
      _scheduleMirrorAutoScan();
      return;
    }
    final svc = widget.sftpService;
    if (svc.mirrorEntries.any((e) => e.sha256 == null)) {
      await svc.computeAllMirrorSha256();
    }
    if (!mounted) return;
    await _scanMirrorConflicts();
  }

  /// 批量下载弹窗：列出服务器 mod（标记已在镜像中的），选择后下载到本机。
  Future<void> _openDownloadPopup() async {
    final entries = widget.sftpService.serverMods;
    if (entries.isEmpty) {
      _showToast('服务器 ~mods 为空，无可下载的 mod');
      return;
    }
    final mirrorNames = widget.sftpService
        .loadMirrorEntries()
        .map((e) => e.fileName)
        .toSet();
    final items =
        entries
            .map(
              (e) => (e.fileName, e.fileSize, mirrorNames.contains(e.fileName)),
            )
            .toList()
          ..sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    final selected = await _ServerDownloadPopup.show(context, items: items);
    if (!mounted || selected.isEmpty) return;
    final chosen = entries.where((e) => selected.contains(e.fileName)).toList();
    final ok = await widget.sftpService.downloadServerMods(chosen);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已下载 $ok 个 mod 到本地镜像' : '下载失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
    setState(() {});
  }

  /// 批量计算本地镜像全部 PAK 的 SHA-256。
  Future<void> _computeAllMirror() async {
    final colors = ScumColors.of(context);
    setState(() {
      _mirrorComputing.addAll(
        widget.sftpService.mirrorEntries
            .where((e) => e.sha256 == null)
            .map((e) => e.fileName),
      );
    });
    await widget.sftpService.computeAllMirrorSha256();
    if (!mounted) return;
    setState(_mirrorComputing.clear);
    _showToast('本地镜像 SHA-256 校验完成', color: colors.success);
  }

  /// 镜像冲突扫描（repak list 求交集，与主界面冲突扫描同原理）。
  Future<void> _scanMirrorConflicts() async {
    final colors = ScumColors.of(context);
    setState(() => _mirrorScanning = true);
    final result = await widget.sftpService.scanMirrorConflicts();
    if (!mounted) return;
    setState(() => _mirrorScanning = false);
    final conflicted = result.length;
    _showToast(
      conflicted > 0 ? '发现 $conflicted 个 mod 存在冲突' : '镜像内无冲突',
      color: conflicted > 0 ? colors.danger : colors.success,
    );
  }

  /// 镜像同步：先规划（本地为权威），确认后执行上传 + 删除服务器多余 mod。
  Future<void> _syncMirrorToServer() async {
    final svc = widget.sftpService;
    final colors = ScumColors.of(context);
    if (!svc.isConnected) {
      _showToast('请先连接服务器，再同步本地镜像');
      return;
    }
    setState(() => _mirrorScanning = true);
    final plan = await svc.planMirrorSync();
    if (!mounted) return;
    setState(() => _mirrorScanning = false);
    if (plan.uploads.isEmpty && plan.deletes.isEmpty) {
      _showToast('本地镜像与服务器已一致，无需同步', color: colors.success);
      return;
    }
    final body = StringBuffer()
      ..writeln('将以本地镜像为权威同步到服务器：')
      ..writeln('')
      ..writeln('▲ 上传 ${plan.uploads.length} 个：')
      ..writeln(_summarizeNames(plan.uploads))
      ..writeln('')
      ..writeln('▼ 删除服务器 ${plan.deletes.length} 个（本地镜像没有）：')
      ..writeln(_summarizeNames(plan.deletes));
    final confirmed = await _ConfirmDialog.show(
      context,
      title: '同步本地镜像到服务器',
      body: body.toString(),
      confirmLabel: '确认同步',
    );
    if (!mounted || !confirmed) return;
    final ok = await svc.executeMirrorSync(
      uploads: plan.uploads,
      deletes: plan.deletes,
    );
    if (!mounted) return;
    setState(() {});
    _showToast(
      '同步完成：成功 $ok 个操作',
      color: ok > 0 ? colors.success : colors.danger,
    );
  }

  /// 名称列表摘要（前 5 个 + 省略号）。
  static String _summarizeNames(List<String> names) {
    if (names.isEmpty) return '（无）';
    final shown = names.take(5).join('\n');
    return names.length > 5 ? '$shown\n… 等 ${names.length} 个' : shown;
  }

  /// 删除单个本地镜像副本（仅本地，不影响服务器）。
  Future<void> _deleteMirrorOne(String fileName) async {
    final confirmed = await _ConfirmDialog.show(
      context,
      title: '删除本地镜像副本',
      body: '确定删除本地镜像中的 $fileName？\n此操作只删除本机副本，不影响服务器。',
    );
    if (!mounted || !confirmed) return;
    final ok = await widget.sftpService.deleteMirrorMod(fileName);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok ? '已删除本地副本 $fileName' : '删除失败',
      color: ok ? colors.success : colors.danger,
    );
  }

  /// 编辑镜像条目的标签与备注（与模组管理同款弹窗）。
  ///
  /// - 标签 → 存 per-server `mirror_meta.json`（镜像专属）
  /// - 备注 → 服务器已有同名写服务器 mods_meta.json；尚未上传写单库，
  ///   上传后随服务器备注带过去。
  void _editMirrorSettings(ServerMirrorEntry entry) {
    final (effectiveNotes, _) = _mirrorEffectiveNotes(entry);
    ModSettingsPopup.show(
      context,
      modName: entry.fileName,
      tags: entry.tags,
      notes: effectiveNotes,
      onSave: (newTags, newNotes) {
        widget.sftpService.setMirrorTags(entry.fileName, newTags);
        widget.sftpService.updateMirrorNotes(entry.fileName, newNotes);
      },
    );
  }

  /// 切换单个镜像条目的启用态（= 是否参与下次同步）。
  void _toggleMirrorEnabled(ServerMirrorEntry entry) {
    widget.sftpService.setMirrorEnabled(entry.fileName, !entry.enabled);
    setState(() {});
  }

  /// 当前可见镜像是否全部启用（表头主勾选框「全选启用」用）。
  bool get _allMirrorEnabled =>
      _visibleMirrorMods.isNotEmpty &&
      _visibleMirrorMods.every((e) => e.enabled);

  /// 当前可见镜像是否有部分启用。
  bool get _someMirrorEnabled => _visibleMirrorMods.any((e) => e.enabled);

  /// 表头主勾选框点击：全部启用 / 全部停用（与模组管理同款行为）。
  void _toggleAllMirrorEnabled() {
    final target = !_allMirrorEnabled;
    final names = _visibleMirrorMods.map((e) => e.fileName).toList();
    for (final n in names) {
      widget.sftpService.setMirrorEnabled(n, target);
    }
    setState(() {});
  }

  /// 资源管理器定位镜像文件 / 打开镜像文件夹。
  void _revealMirrorFile(String fileName) {
    widget.sftpService.revealMirrorFile(fileName);
  }

  void _openMirrorDir() {
    widget.sftpService.openMirrorDir();
  }

  /// 点击冲突徽章 → 复用 [ConflictPanel]（与模组管理同一模块）展示详情：
  /// 每个冲突资源路径 + 与哪些镜像 mod 文件冲突。
  void _showMirrorConflictDetail(ServerMirrorEntry entry) {
    final svc = widget.sftpService;
    ConflictPanel.show(
      context,
      focusModId: entry.fileName,
      conflictsOnly: false,
      onToggleFilter: () {},
      data: ConflictPanelData(
        title: '冲突详情 · 「${entry.fileName}」',
        listenable: svc,
        // 每次 build 从当前条目取最新冲突（重新扫描后自动刷新）。
        groups: () {
          final cur = svc.mirrorEntries
              .where((e) => e.fileName == entry.fileName)
              .firstOrNull;
          if (cur == null || cur.conflicts.isEmpty) return const [];
          return [
            for (final e in cur.conflicts.entries)
              PakConflictGroup(path: e.key, modIds: [cur.fileName, ...e.value]),
          ];
        },
        scannedCount: () => svc.mirrorEntries.length,
        scanning: () => svc.isBusy,
        unavailable: () => svc.mirrorScanUnavailable,
        onRescan: () => _scanMirrorConflicts(),
        participantFor: (id) => (id, null), // 镜像参与者 = 文件名，无序号
        footerNote: '参与扫描：${svc.mirrorEntries.length} 个镜像 PAK',
      ),
    );
  }

  // ===== 文件操作（上传 / 删除） =====

  /// 进入多选删除模式。
  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selectedMods.clear();
    });
  }

  /// 退出多选删除模式。
  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedMods.clear();
    });
  }

  /// 切换单个选中态。
  void _toggleSelect(String fileName) {
    setState(() {
      if (_selectedMods.contains(fileName)) {
        _selectedMods.remove(fileName);
      } else {
        _selectedMods.add(fileName);
      }
    });
  }

  /// 全选当前可见列表。
  void _selectAllVisible() {
    setState(() {
      _selectedMods.addAll(_visibleServerMods.map((e) => e.fileName));
    });
  }

  /// 上传：原生文件对话框（支持多选 .pak）→ 逐个流式上传到服务器 ~mods。
  Future<void> _uploadViaDialog() async {
    AppLogger.instance.ui('服务器上传', action: '打开文件对话框');
    final paths = await WindowService.openFileDialog();
    if (!mounted || paths.isEmpty) return;
    final paks = paths.where((p) => p.toLowerCase().endsWith('.pak')).toList();
    if (paks.isEmpty) {
      _showToast('未选择 .pak 文件', color: ScumColors.of(context).danger);
      return;
    }
    final ok = await widget.sftpService.uploadModsToServer(paks);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已上传 $ok 个 mod 到服务器' : '上传失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
  }

  /// 批量上传：本地 ~mods 未部署 PAK 多选弹窗。
  Future<void> _openUploadPopup() async {
    final pending = _localPendingUploads();
    if (pending.isEmpty) {
      _showToast('本地 ~mods 没有未部署的 PAK');
      return;
    }
    final selected = await _LocalUploadPopup.show(context, items: pending);
    if (!mounted || selected.isEmpty) return;
    final paths = selected
        .map((n) => p.join(widget.modService.localModsPath, n))
        .toList();
    final ok = await widget.sftpService.uploadModsToServer(paths);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已上传 $ok 个 mod 到服务器' : '上传失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
  }

  /// 本地 ~mods 中未部署到服务器的 PAK（(文件名, 大小) 列表，名称排序）。
  List<(String, int)> _localPendingUploads() {
    final localDir = Directory(widget.modService.localModsPath);
    if (!localDir.existsSync()) return [];
    final serverNames = widget.sftpService.serverMods
        .map((e) => e.fileName.toLowerCase())
        .toSet();
    final result = <(String, int)>[];
    for (final f in localDir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (!name.toLowerCase().endsWith('.pak')) continue;
      if (serverNames.contains(name.toLowerCase())) continue; // 已部署跳过
      result.add((name, f.lengthSync()));
    }
    result.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return result;
  }

  /// 批量删除：确认后逐个删除所选。
  Future<void> _deleteSelected() async {
    final names = List<String>.from(_selectedMods);
    if (names.isEmpty) return;
    final confirmed = await _ConfirmDialog.show(
      context,
      title: '删除所选服务器 mod',
      body:
          '确定删除选中的 ${names.length} 个服务器 mod？\n此操作不可撤销，服务器 ~mods 中的对应 PAK 将被移除。',
    );
    if (!mounted || !confirmed) return;
    final ok = await widget.sftpService.deleteServerMods(names);
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedMods.clear();
    });
    final colors = ScumColors.of(context);
    _showToast(
      ok > 0 ? '已删除 $ok 个 mod' : '删除失败',
      color: ok > 0 ? colors.success : colors.danger,
    );
  }

  /// 删除单个 mod（确认后）。
  Future<void> _deleteOne(String fileName) async {
    final confirmed = await _ConfirmDialog.show(
      context,
      title: '删除服务器 mod',
      body: '确定删除 $fileName？\n此操作不可撤销。',
    );
    if (!mounted || !confirmed) return;
    final ok = await widget.sftpService.deleteServerMod(fileName);
    if (!mounted) return;
    final colors = ScumColors.of(context);
    _showToast(
      ok ? '已删除 $fileName' : '删除失败',
      color: ok ? colors.success : colors.danger,
    );
  }

  /// 打开备注编辑弹窗（复用 ModSettingsPopup，仅使用备注栏）。
  /// 初始文案取「当前生效的备注」（云上/他服互换后的显示值），
  /// 保存后写入本服务器的 mods_meta.json —— 云上备注可直接覆盖到服务器。
  void _editNotes(ServerModEntry entry) {
    final (effectiveNotes, _) = _effectiveNotes(entry);
    AppLogger.instance.ui(
      '服务器 mod 备注',
      action: '编辑',
      details: {'file': entry.fileName, 'notes_length': effectiveNotes.length},
    );
    ModSettingsPopup.show(
      context,
      modName: entry.fileName,
      tags: const [],
      notes: effectiveNotes,
      onSave: (newTags, newNotes) {
        AppLogger.instance.ui(
          '服务器 mod 备注',
          action: '保存',
          details: {'file': entry.fileName, 'notes_length': newNotes.length},
        );
        // 服务器备注只存 notes；tags 忽略（服务器 mods_meta.json 结构只含 notes）。
        // 异步写服务器，不阻塞 UI。
        widget.sftpService.updateServerModNotes(entry.fileName, newNotes);
      },
    );
  }

  void _showToast(String msg, {Color? color}) {
    if (!mounted) return;
    final colors = ScumColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color ?? colors.textDim,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final svc = widget.sftpService;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(colors, svc),
        const SizedBox(height: 8),
        // ── 可配置列表头（点击排序 / 右键显隐 / 拖拽排序 / 拖宽）──
        // 服务器列表与本地镜像各用一套列配置（独立持久化）。
        !_showMirror
            ? svc.serverMods.isNotEmpty
                  ? ModTableHeader(
                      specs: serverColumnSpecs,
                      layout: _serverLayout,
                      onLayoutChanged: _onServerLayoutChanged,
                      onLayoutCommit: _onServerLayoutCommit,
                      sortColumnId: _sortCol,
                      sortAscending: _sortAsc,
                      onSort: _onHeaderSort,
                    )
                  : const SizedBox.shrink()
            : svc.mirrorEntries.isNotEmpty
            ? ModTableHeader(
                specs: serverMirrorColumnSpecs,
                layout: _mirrorLayout,
                onLayoutChanged: _onMirrorLayoutChanged,
                onLayoutCommit: _onMirrorLayoutCommit,
                sortColumnId: _sortCol,
                sortAscending: _sortAsc,
                onSort: _onHeaderSort,
                // 主勾选框：全选启用/停用（与模组管理表头同款行为）。
                masterSelect: (
                  checked: _allMirrorEnabled,
                  partial: _someMirrorEnabled && !_allMirrorEnabled,
                  onTap: _toggleAllMirrorEnabled,
                ),
              )
            : const SizedBox.shrink(),
        Expanded(
          child: _showMirror
              ? (svc.mirrorEntries.isEmpty
                    ? _buildMirrorEmpty(colors, svc)
                    : _buildMirrorList(colors, svc))
              : (svc.serverMods.isEmpty
                    ? _buildEmpty(colors, svc)
                    : _buildList(colors, svc)),
        ),
        const SizedBox(height: 4),
        _buildLogBar(colors, svc),
      ],
    );
  }

  /// 顶部：连接状态 + 操作按钮 + 路径。
  Widget _buildHeader(ScumColors colors, ServerSftpService svc) {
    final connected = svc.isConnected;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: colors.bgDark.withValues(alpha: 0.82),
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 账户切换条（快速切换不同服务器） ──
          Row(
            children: [
              Icon(Icons.swap_horiz_rounded, size: 14, color: colors.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '当前账户：${widget.modService.activeSftpAccount?.displayName ?? '（无账户）'}',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _AccountSwitcherButton(
                accounts: widget.modService.loadSftpAccounts(),
                activeName: widget.modService.activeSftpAccount?.name ?? '',
                onSelected: (acc) => _switchAccount(acc),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 18,
                color: connected ? colors.success : colors.textDim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  connected ? '已连接服务器' : '未连接',
                  style: TextStyle(
                    color: connected ? colors.success : colors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              // ── 连接/断开 ──
              _PanelButton(
                label: connected ? '断开' : '连接',
                icon: connected ? Icons.link_off_rounded : Icons.link_rounded,
                primary: !connected,
                loading: svc.isBusy,
                onTap: connected ? _disconnect : _connect,
              ),
              const SizedBox(width: 6),
              // ── 刷新列表 ──
              _PanelButton(
                label: '刷新',
                icon: Icons.refresh_rounded,
                primary: false,
                enabled: connected,
                loading: svc.isBusy,
                onTap: _refresh,
              ),
              const SizedBox(width: 6),
              // ── 校验全部（仅服务器列表模式；镜像模式在校验/冲突按钮行操作）──
              if (!_showMirror)
                _PanelButton(
                  label: '校验 SHA-256',
                  icon: Icons.verified_rounded,
                  primary: false,
                  enabled: connected && svc.serverMods.isNotEmpty,
                  loading: _computing.isNotEmpty,
                  onTap: _computeAll,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 14, color: colors.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  svc.modsDir.isEmpty
                      ? '~mods 路径未定位（可在设置页「服务器」Tab 自动定位）'
                      : svc.modsDir,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── 搜索 / 标签 / 排序（与主界面、云面板一致的三件套） ──
          Row(
            children: [
              _ServerSearchField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
              const SizedBox(width: 8),
              if (_allServerTags.isNotEmpty) ...[
                _ServerTagFilterButton(
                  allTags: _allServerTags.toList()..sort(),
                  selectedTags: _filterTags,
                  onTagsChanged: (tags) => setState(() => _filterTags = tags),
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              if (_hasServerFilter)
                Text(
                  '${_visibleServerMods.length} / ${svc.serverMods.length}',
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                ),
              if (_hasServerFilter) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _clearServerFilter,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.clear_all_rounded,
                            size: 12,
                            color: colors.textDim,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '清除过滤',
                            style: TextStyle(
                              color: colors.textDim,
                              fontSize: 11,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // ── 视图模式：服务器列表 / 本地镜像（下载到本机的副本）──
          Row(
            children: [
              _ModeSegButton(
                label: '服务器列表',
                icon: Icons.dns_rounded,
                active: !_showMirror,
                onTap: () => _setShowMirror(false),
              ),
              const SizedBox(width: 6),
              _ModeSegButton(
                label: '本地镜像',
                icon: Icons.folder_copy_rounded,
                active: _showMirror,
                onTap: () => _setShowMirror(true),
              ),
              const Spacer(),
              if (_showMirror)
                Text(
                  '${svc.mirrorEntries.length} 个已下载',
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // ── 文件操作（按模式分流）──
          if (!_showMirror)
            Row(
              children: [
                if (!_selectionMode) ...[
                  _PanelButton(
                    label: '上传 PAK',
                    icon: Icons.file_upload_rounded,
                    primary: false,
                    enabled: connected && !svc.isBusy,
                    loading: false,
                    onTap: _uploadViaDialog,
                  ),
                  const SizedBox(width: 6),
                  _PanelButton(
                    label: '批量上传',
                    icon: Icons.cloud_upload_rounded,
                    primary: false,
                    enabled: connected && !svc.isBusy,
                    loading: false,
                    onTap: _openUploadPopup,
                  ),
                  const SizedBox(width: 6),
                  // ── 批量下载：服务器 mod → 本地镜像文件夹 ──
                  _PanelButton(
                    label: '批量下载',
                    icon: Icons.file_download_rounded,
                    primary: false,
                    enabled:
                        connected && svc.serverMods.isNotEmpty && !svc.isBusy,
                    loading: false,
                    onTap: _openDownloadPopup,
                  ),
                  const SizedBox(width: 6),
                  _PanelButton(
                    label: '批量删除',
                    icon: Icons.delete_sweep_rounded,
                    primary: false,
                    danger: true,
                    enabled:
                        connected && svc.serverMods.isNotEmpty && !svc.isBusy,
                    loading: false,
                    onTap: _enterSelectionMode,
                  ),
                ] else ...[
                  _PanelButton(
                    label: '删除所选（${_selectedMods.length}）',
                    icon: Icons.delete_forever_rounded,
                    primary: true,
                    danger: true,
                    enabled: _selectedMods.isNotEmpty && !svc.isBusy,
                    loading: false,
                    onTap: _deleteSelected,
                  ),
                  const SizedBox(width: 6),
                  _PanelButton(
                    label: '全选',
                    icon: Icons.select_all_rounded,
                    primary: false,
                    enabled: svc.serverMods.isNotEmpty,
                    loading: false,
                    onTap: _selectAllVisible,
                  ),
                  const SizedBox(width: 6),
                  _PanelButton(
                    label: '取消选择',
                    icon: Icons.close_rounded,
                    primary: false,
                    enabled: true,
                    loading: false,
                    onTap: _exitSelectionMode,
                  ),
                ],
                const Spacer(),
              ],
            )
          else
            Row(
              children: [
                // ── 本地镜像：添加 PAK（快速添加，无需连接服务器）──
                _PanelButton(
                  label: '添加 PAK',
                  icon: Icons.file_download_rounded,
                  primary: false,
                  enabled: true,
                  loading: false,
                  onTap: _addMirrorViaDialog,
                ),
                const SizedBox(width: 6),
                // ── 本地镜像：校验 SHA-256 ──
                _PanelButton(
                  label: '校验 SHA-256',
                  icon: Icons.verified_rounded,
                  primary: false,
                  enabled: svc.mirrorEntries.isNotEmpty && !svc.isBusy,
                  loading: _mirrorComputing.isNotEmpty,
                  onTap: _computeAllMirror,
                ),
                const SizedBox(width: 6),
                // ── 本地镜像：冲突扫描（repak 交集）──
                _PanelButton(
                  label: '冲突扫描',
                  icon: Icons.warning_amber_rounded,
                  primary: false,
                  enabled: svc.mirrorEntries.isNotEmpty && !svc.isBusy,
                  loading: _mirrorScanning,
                  onTap: _scanMirrorConflicts,
                ),
                const SizedBox(width: 6),
                // ── 本地镜像：同步到服务器（本地为权威）──
                _PanelButton(
                  label: '同步到服务器',
                  icon: Icons.sync_rounded,
                  primary: true,
                  enabled: connected && svc.mirrorEntries.isNotEmpty,
                  loading: false,
                  onTap: _syncMirrorToServer,
                ),
                const SizedBox(width: 6),
                // ── 本地镜像：打开文件夹 ──
                _PanelButton(
                  label: '打开文件夹',
                  icon: Icons.folder_open_rounded,
                  primary: false,
                  enabled: true,
                  loading: false,
                  onTap: _openMirrorDir,
                ),
                const Spacer(),
              ],
            ),
        ],
      ),
    );
  }

  /// 空态提示。
  Widget _buildEmpty(ScumColors colors, ServerSftpService svc) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 56,
            color: colors.textDim.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            svc.isConnected
                ? '服务器 ~mods 目录为空或尚未刷新'
                : '连接你的 SCUM 服务器后自动扫描 ~mods',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '服务器备注存放在 {Paks}/mods_meta.json，跟随服务器可跨管理端共享',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  /// 本地镜像空态提示。
  Widget _buildMirrorEmpty(ScumColors colors, ServerSftpService svc) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_copy_outlined,
            size: 56,
            color: colors.textDim.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '本地镜像文件夹还没有 mod',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            svc.isConnected
                ? '直接拖拽 .pak 到此即可快速添加（无需连接）\n'
                      '或在「服务器列表」模式点「批量下载」拉取服务器 mod\n'
                      '添加后自动扫描 SHA-256 / 冲突 / 备注，可同步回服务器'
                : '直接拖拽 .pak 到此即可快速添加本地镜像\n'
                      '连接服务器后可批量下载远程 mod 到本机',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              height: 1.6,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '文件夹：${svc.localMirrorDir}',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 10,
              fontFamily: 'Consolas',
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  /// 本地镜像列表（与模组管理同款：序号 + 启用勾选框 + 九列 + 行操作）。
  Widget _buildMirrorList(ScumColors colors, ServerSftpService svc) {
    final list = _visibleMirrorMods;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final entry = list[index];
        final computing = _mirrorComputing.contains(entry.fileName);
        // 隐藏式备注互换：云上 > 本服务器 > 其他服务器。
        final (noteText, noteSource) = _mirrorEffectiveNotes(entry);
        return Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: buildConfigurableRow(
              context: context,
              layout: _mirrorLayout,
              enabled: entry.enabled,
              fixedLeft: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: entry.enabled
                          ? colors.textDim
                          : colors.textDim.withValues(alpha: 0.4),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                RowCheckbox(
                  enabled: entry.enabled,
                  onTap: () => _toggleMirrorEnabled(entry),
                ),
                const SizedBox(width: 12),
              ],
              fixedRight: [
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.tune_rounded,
                  tooltip: '编辑标签/备注',
                  color: colors.textSecondary,
                  hoverColor: colors.accent,
                  onTap: () => _editMirrorSettings(entry),
                ),
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.folder_open_rounded,
                  tooltip: '在资源管理器中定位',
                  color: colors.textSecondary,
                  hoverColor: colors.accent,
                  onTap: () => _revealMirrorFile(entry.fileName),
                ),
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.verified_rounded,
                  tooltip: '计算 SHA-256',
                  color: computing ? colors.textDim : colors.accent,
                  hoverColor: colors.accent,
                  onTap: () {
                    setState(() => _mirrorComputing.add(entry.fileName));
                    widget.sftpService.computeAllMirrorSha256().whenComplete(
                      () {
                        if (mounted) {
                          setState(
                            () => _mirrorComputing.remove(entry.fileName),
                          );
                        }
                      },
                    );
                  },
                ),
                const SizedBox(width: 4),
                CardActionButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: '删除本地副本',
                  color: colors.textDim,
                  hoverColor: colors.danger,
                  onTap: () => _deleteMirrorOne(entry.fileName),
                ),
              ],
              cellBuilder: (spec) =>
                  _mirrorCell(context, spec.id, entry, noteText, noteSource),
            ),
          ),
        );
      },
    );
  }

  /// 本地镜像单列单元格渲染（与模组管理同款列语义）。
  Widget _mirrorCell(
    BuildContext context,
    String colId,
    ServerMirrorEntry entry,
    String noteText,
    String noteSource,
  ) {
    final colors = ScumColors.of(context);
    final dim = entry.enabled ? 1.0 : 0.45;
    switch (colId) {
      case 'name':
        return Text(
          entry.fileName,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: entry.enabled ? colors.textPrimary : colors.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        );
      case 'status':
        return StatusBadge(
          label: _mirrorStatusLabel(entry.mirrorStatus),
          color: _mirrorStatusColor(entry.mirrorStatus, colors),
        );
      case 'type':
        return TypeBadge(type: ModType.serverPak);
      case 'tags':
        return ScumTagsRow(
          tags: entry.tags,
          colors: colors,
          enabled: entry.enabled,
        );
      case 'notes':
        return Text(
          noteText.isEmpty ? '—' : noteText,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color:
                (noteSource == 'cloud'
                        ? colors.accent
                        : noteSource == 'other'
                        ? colors.textDim
                        : colors.textSecondary)
                    .withValues(alpha: dim),
            fontSize: 11,
            decoration: TextDecoration.none,
          ),
        );
      case 'sha256':
        final sha = entry.sha256;
        return sha == null
            ? Text(
                _mirrorComputing.contains(entry.fileName) ? '计算中…' : '未计算',
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              )
            : Tooltip(
                message: sha,
                child: Text(
                  '${sha.substring(0, 12)}…',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                ),
              );
      case 'size':
        return Text(
          entry.fileSizeFormatted,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 11,
            decoration: TextDecoration.none,
          ),
        );
      case 'time':
        return Text(
          entry.lastModified == null ? '—' : _fmtTime(entry.lastModified!),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: colors.textDim,
            fontSize: 11,
            fontFamily: 'Consolas',
            decoration: TextDecoration.none,
          ),
        );
      case 'origin':
        return StatusBadge(label: '服务器', color: colors.accent);
      case 'conflict':
        return entry.hasConflict
            ? Tooltip(
                message: entry.conflictPaths.take(5).join('\n'),
                child: GestureDetector(
                  onTap: () => _showMirrorConflictDetail(entry),
                  behavior: HitTestBehavior.opaque,
                  child: StatusBadge(
                    label: entry.conflictCount == 1
                        ? '冲突'
                        : '冲突×${entry.conflictCount}',
                    color: colors.dangerLight,
                  ),
                ),
              )
            : Text(
                '—',
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              );
      default:
        return const SizedBox.shrink();
    }
  }

  /// 镜像状态 → 显示文案（与模组管理状态徽章同风格）。
  static String _mirrorStatusLabel(String status) => switch (status) {
    'disabled' => '已停用',
    'synced' => '已同步',
    'modified' => '已修改',
    'new' => '仅本地',
    _ => '—',
  };

  /// 镜像状态 → 颜色。
  static Color _mirrorStatusColor(String status, ScumColors colors) =>
      switch (status) {
        'disabled' => colors.textDim,
        'synced' => colors.success,
        'modified' => colors.danger,
        'new' => colors.accent,
        _ => colors.textDim,
      };

  /// 服务器 mod 列表（可配置多列表格行）。
  Widget _buildList(ScumColors colors, ServerSftpService svc) {
    final list = _visibleServerMods;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final entry = list[index];
        final computing = _computing.contains(entry.fileName);
        // 隐藏式备注互换：云上 > 本服务器 > 其他服务器（不出现互通提示横幅）。
        final (noteText, noteSource) = _effectiveNotes(entry);
        // 云上标签（sha-256 匹配云端目录；与云上备注一同互换到服务器侧显示）
        final cloudTags = entry.sha256 == null
            ? const <String>[]
            : svc.cloudTagsBySha256(entry.sha256!);
        return Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: GestureDetector(
            onTap: _selectionMode ? () => _toggleSelect(entry.fileName) : null,
            behavior: HitTestBehavior.opaque,
            child: buildConfigurableRow(
              context: context,
              layout: _serverLayout,
              enabled: true,
              fixedLeft: _selectionMode
                  ? [
                      const SizedBox(width: 4),
                      _SelectionBox(
                        selected: _selectedMods.contains(entry.fileName),
                      ),
                      const SizedBox(width: 12),
                    ]
                  : [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(width: 18),
                      const SizedBox(width: 12),
                    ],
              fixedRight: _selectionMode
                  ? const []
                  : [
                      _CardIconButton(
                        icon: Icons.verified_rounded,
                        tooltip: '计算 SHA-256',
                        color: computing ? colors.textDim : colors.accent,
                        loading: computing,
                        onTap: () => _computeOne(entry.fileName),
                      ),
                      const SizedBox(width: 4),
                      _CardIconButton(
                        icon: Icons.edit_note_rounded,
                        tooltip: '编辑备注',
                        color: colors.textSecondary,
                        onTap: () => _editNotes(entry),
                      ),
                      const SizedBox(width: 4),
                      _CardIconButton(
                        icon: Icons.delete_outline_rounded,
                        tooltip: '删除此 mod',
                        color: colors.danger.withValues(alpha: 0.9),
                        onTap: () => _deleteOne(entry.fileName),
                      ),
                      const SizedBox(width: 4),
                    ],
              cellBuilder: (spec) => _serverCell(
                context,
                spec.id,
                entry,
                noteText,
                noteSource,
                cloudTags,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 服务器列表单列单元格渲染。
  /// 服务器列表单列单元格内容（水平对齐由 buildConfigurableRow 按 spec.align 统一处理）。
  Widget _serverCell(
    BuildContext context,
    String colId,
    ServerModEntry entry,
    String noteText,
    String noteSource,
    List<String> cloudTags,
  ) {
    final colors = ScumColors.of(context);
    final status = entry.matchStatus;
    switch (colId) {
      case 'name':
        return Text(
          entry.fileName,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        );
      case 'size':
        return Text(
          entry.fileSizeFormatted,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 11,
            decoration: TextDecoration.none,
          ),
        );
      case 'time':
        return Text(
          entry.lastModified == null ? '—' : _fmtTime(entry.lastModified!),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: colors.textDim,
            fontSize: 11,
            fontFamily: 'Consolas',
            decoration: TextDecoration.none,
          ),
        );
      case 'sha256':
        final sha = entry.sha256;
        return sha == null
            ? Text(
                _computing.contains(entry.fileName) ? '计算中…' : '未计算',
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              )
            : Tooltip(
                message: sha,
                child: Text(
                  '${sha.substring(0, 12)}…',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                ),
              );
      case 'tags':
        return ScumTagsRow(tags: cloudTags, colors: colors);
      case 'notes':
        return Text(
          noteText.isEmpty ? '—' : noteText,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: noteSource == 'cloud'
                ? colors.accent
                : noteSource == 'other'
                ? colors.textDim
                : colors.textSecondary,
            fontSize: 11,
            decoration: TextDecoration.none,
          ),
        );
      case 'match':
        return Text(
          _matchLabel(status),
          style: TextStyle(
            color: _matchColor(status, colors),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// 校验状态 → 显示文案。
  static String _matchLabel(String status) => switch (status) {
    'match' => '✓ 一致',
    'mismatch' => '✗ 不一致',
    'contentMatch' => '内容一致',
    'localOnly' => '仅服务器',
    _ => '—',
  };

  /// 校验状态 → 颜色。
  static Color _matchColor(String status, ScumColors colors) =>
      switch (status) {
        'match' => colors.success,
        'mismatch' => colors.danger,
        'contentMatch' => colors.textSecondary,
        _ => colors.textDim,
      };

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  /// 底部操作日志条。
  Widget _buildLogBar(ScumColors colors, ServerSftpService svc) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: colors.bgPanel.withValues(alpha: 0.9),
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      child: svc.logs.isEmpty
          ? Text(
              'SFTP 操作日志（连接 / 扫描 / 哈希 / 备注）',
              style: TextStyle(
                color: colors.textDim,
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            )
          : ListView.builder(
              itemCount: svc.logs.length,
              itemBuilder: (context, i) => Text(
                svc.logs[i],
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 10,
                  fontFamily: 'Consolas',
                  decoration: TextDecoration.none,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
    );
  }
}

// =====================================================================
//  行内云标签 chips（表格行复用）
// =====================================================================

/// 服务器面板搜索框 —— EditableText 自绘，匹配文件名 / 本服务器备注 / 云上备注。
class _ServerSearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _ServerSearchField({required this.controller, required this.onChanged});

  @override
  State<_ServerSearchField> createState() => _ServerSearchFieldState();
}

class _ServerSearchFieldState extends State<_ServerSearchField> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onChanged(widget.controller.text);
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final borderColor = _focused ? colors.borderAccent : colors.border;
    return SizedBox(
      width: 180,
      height: 28,
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: Container(
          decoration: BoxDecoration(
            color: colors.bgCard,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: borderColor, width: _focused ? 1.5 : 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 16, color: colors.textDim),
              const SizedBox(width: 4),
              Expanded(
                child: EditableText(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    fontFamily: 'sans-serif',
                  ),
                  cursorColor: colors.accent,
                  backgroundCursorColor: colors.textDim,
                  selectionColor: colors.accent.withValues(alpha: 0.3),
                ),
              ),
              if (widget.controller.text.isNotEmpty)
                GestureDetector(
                  onTap: _clear,
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: colors.textDim,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 服务器面板标签筛选按钮 —— 云上标签多选（sha-256 互换语义），LayerLink 下拉。
class _ServerTagFilterButton extends StatefulWidget {
  final List<String> allTags;
  final Set<String> selectedTags;
  final ValueChanged<Set<String>> onTagsChanged;

  const _ServerTagFilterButton({
    required this.allTags,
    required this.selectedTags,
    required this.onTagsChanged,
  });

  @override
  State<_ServerTagFilterButton> createState() => _ServerTagFilterButtonState();
}

class _ServerTagFilterButtonState extends State<_ServerTagFilterButton> {
  bool _hovered = false;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  void _toggleMenu() {
    if (_overlayEntry != null) {
      try {
        _overlayEntry!.remove();
      } catch (_) {}
      _overlayEntry = null;
    } else {
      _overlayEntry = _buildOverlay();
      Overlay.of(context).insert(_overlayEntry!);
    }
  }

  OverlayEntry _buildOverlay() {
    return OverlayEntry(
      builder: (context) => ScumTagFilterMenu(
        layerLink: _layerLink,
        sortedTags: widget.allTags,
        selectedTags: widget.selectedTags,
        onTagsChanged: (updated) {
          widget.onTagsChanged(updated);
          // 不关闭菜单，让用户继续多选
        },
        onDismiss: () {
          try {
            _overlayEntry?.remove();
          } catch (_) {}
          _overlayEntry = null;
        },
      ),
    );
  }

  @override
  void dispose() {
    try {
      _overlayEntry?.remove();
    } catch (_) {}
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final count = widget.selectedTags.length;
    final hasSelection = count > 0;
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggleMenu,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered ? colors.bgHover : colors.bgCard,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.label_rounded,
                  size: 14,
                  color: hasSelection ? colors.accent : colors.textDim,
                ),
                const SizedBox(width: 4),
                Text(
                  hasSelection ? '标签 ($count)' : '标签筛选',
                  style: TextStyle(
                    color: hasSelection ? colors.accent : colors.textDim,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 16,
                  color: colors.textDim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountSwitcherButton extends StatefulWidget {
  final List<SftpAccount> accounts;
  final String activeName;
  final ValueChanged<SftpAccount> onSelected;

  const _AccountSwitcherButton({
    required this.accounts,
    required this.activeName,
    required this.onSelected,
  });

  @override
  State<_AccountSwitcherButton> createState() => _AccountSwitcherButtonState();
}

class _AccountSwitcherButtonState extends State<_AccountSwitcherButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _openAccountMenu,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered ? colors.bgHover : colors.bgCard,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: _hovered ? colors.borderAccent : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.accounts.isEmpty
                    ? Icons.person_add_alt_1_rounded
                    : Icons.people_alt_rounded,
                size: 13,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: colors.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开账户选择弹窗（居中自绘列表）。
  void _openAccountMenu() {
    AccountSwitcherPopup.show(
      context,
      accounts: widget.accounts,
      activeName: widget.activeName,
      onSelected: (acc) {
        if (mounted) widget.onSelected(acc);
      },
    );
  }
}

/// 账户选择弹窗（OverlayEntry 居中，自绘）。
class AccountSwitcherPopup {
  AccountSwitcherPopup._();

  static OverlayEntry? _entry;

  static void show(
    BuildContext context, {
    required List<SftpAccount> accounts,
    required String activeName,
    required ValueChanged<SftpAccount> onSelected,
  }) {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = OverlayEntry(
      builder: (context) => _AccountMenuPanel(
        accounts: accounts,
        activeName: activeName,
        onSelected: (acc) {
          onSelected(acc);
          dismiss();
        },
        onDismiss: dismiss,
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  static void dismiss() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
  }
}

/// 账户菜单面板本体（居中弹窗）。
class _AccountMenuPanel extends StatelessWidget {
  final List<SftpAccount> accounts;
  final String activeName;
  final ValueChanged<SftpAccount> onSelected;
  final VoidCallback onDismiss;

  const _AccountMenuPanel({
    required this.accounts,
    required this.activeName,
    required this.onSelected,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
            child: Container(color: colors.overlay),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.bgPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.borderAccent),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowMd,
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '切换服务器账户',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '选择后自动断开旧连接并重连新服务器',
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: 10,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '暂无账户，请到设置页「服务器」Tab 添加',
                        style: TextStyle(
                          color: colors.textDim,
                          fontSize: 12,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    )
                  else
                    ...accounts.map((acc) {
                      final active = acc.name == activeName;
                      return _AccountMenuItem(
                        account: acc,
                        active: active,
                        onTap: () => onSelected(acc),
                      );
                    }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单个账户菜单项。
class _AccountMenuItem extends StatefulWidget {
  final SftpAccount account;
  final bool active;
  final VoidCallback onTap;

  const _AccountMenuItem({
    required this.account,
    required this.active,
    required this.onTap,
  });

  @override
  State<_AccountMenuItem> createState() => _AccountMenuItemState();
}

class _AccountMenuItemState extends State<_AccountMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final active = widget.active;
    final textColor = active ? colors.accent : colors.textPrimary;
    final bg = active
        ? colors.accent.withValues(alpha: 0.1)
        : _hovered
        ? colors.bgHover
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            children: [
              Icon(
                active ? Icons.radio_button_checked_rounded : Icons.dns_rounded,
                size: 13,
                color: textColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.account.displayName,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${widget.account.host}:${widget.account.port}',
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 9,
                  fontFamily: 'Consolas',
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板顶部按钮（连接/刷新/校验）。

class _PanelButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final bool danger;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  const _PanelButton({
    required this.label,
    required this.icon,
    this.primary = false,
    this.danger = false,
    this.enabled = true,
    this.loading = false,
    required this.onTap,
  });

  @override
  State<_PanelButton> createState() => _PanelButtonState();
}

class _PanelButtonState extends State<_PanelButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final enabled = widget.enabled && !widget.loading;
    final Color bg;
    if (!enabled) {
      bg = colors.bgHover;
    } else if (widget.danger) {
      bg = _hovered ? colors.danger.withValues(alpha: 0.85) : colors.danger;
    } else if (widget.primary) {
      bg = _hovered ? colors.accent.withValues(alpha: 0.85) : colors.accent;
    } else {
      bg = _hovered ? colors.bgHover : Colors.transparent;
    }
    final fg = !enabled
        ? colors.textDim
        : widget.danger || widget.primary
        ? colors.bgDark
        : colors.textSecondary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(
              color: widget.danger || widget.primary
                  ? Colors.transparent
                  : colors.border,
            ),
            borderRadius: BorderRadius.circular(3),
          ),
          child: widget.loading
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 14, color: fg),
                    const SizedBox(width: 5),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 视图模式分段按钮（服务器列表 / 本地镜像）。
class _ModeSegButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ModeSegButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  State<_ModeSegButton> createState() => _ModeSegButtonState();
}

class _ModeSegButtonState extends State<_ModeSegButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final active = widget.active;
    final fg = active ? colors.bgDark : colors.textSecondary;
    final bg = active
        ? colors.accent
        : _hovered
        ? colors.bgHover
        : colors.bgCard;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: active ? Colors.transparent : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: fg),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡片行内图标按钮（计算哈希 / 编辑备注），自绘 hover tooltip。
class _CardIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final bool loading;
  final VoidCallback onTap;

  const _CardIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    this.loading = false,
    required this.onTap,
  });

  @override
  State<_CardIconButton> createState() => _CardIconButtonState();
}

class _CardIconButtonState extends State<_CardIconButton> {
  bool _hovered = false;
  bool _showTooltip = false;
  Timer? _tooltipTimer;

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    super.dispose();
  }

  void _onEnter(_) {
    setState(() => _hovered = true);
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted && _hovered) setState(() => _showTooltip = true);
    });
  }

  void _onExit(_) {
    _tooltipTimer?.cancel();
    setState(() {
      _hovered = false;
      _showTooltip = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: _onEnter,
      onExit: _onExit,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _hovered ? colors.bgHover : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: widget.loading
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                      ),
                    )
                  : Icon(widget.icon, size: 15, color: widget.color),
            ),
            // 自绘 tooltip（浮在卡片上方）
            if (_showTooltip)
              Positioned(
                top: -26,
                left: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.bgPanel,
                    border: Border.all(color: colors.border),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    widget.tooltip,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 10,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 多选勾选框（自绘小方块：未选 = 描边方块，选中 = accent 填充 + 对勾）。
class _SelectionBox extends StatelessWidget {
  final bool selected;

  const _SelectionBox({required this.selected});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: selected
              ? colors.accent
              : colors.textDim.withValues(alpha: 0.7),
          width: 1.2,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 11, color: colors.bgDark)
          : null,
    );
  }
}

/// 确认弹窗（OverlayEntry 居中自绘）——删除等不可撤销操作前的确认。
class _ConfirmDialog {
  _ConfirmDialog._();

  static OverlayEntry? _entry;

  /// 弹出确认框；返回用户是否确认（true = 确认执行）。
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String body,
    String confirmLabel = '确认删除',
  }) {
    try {
      _entry?.remove();
    } catch (_) {}
    final completer = Completer<bool>();
    _entry = OverlayEntry(
      builder: (context) => _ConfirmPanel(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
        onConfirm: () {
          completer.complete(true);
          dismiss();
        },
        onCancel: () {
          completer.complete(false);
          dismiss();
        },
      ),
    );
    Overlay.of(context).insert(_entry!);
    return completer.future;
  }

  static void dismiss() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
  }
}

/// 确认框面板本体（居中弹窗，标题 + 正文 + 取消 / 红色确认按钮）。
class _ConfirmPanel extends StatelessWidget {
  final String title;
  final String body;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _ConfirmPanel({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onCancel,
            child: Container(color: colors.overlay),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.bgPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.borderAccent),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowMd,
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: colors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    body,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      height: 1.5,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: onCancel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: onConfirm,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colors.danger,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            confirmLabel,
                            style: TextStyle(
                              color: colors.bgDark,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 服务器 mod 批量下载弹窗（居中多选，勾选后「下载所选」到本地镜像）。
///
/// items：`(文件名, 大小, 是否已在本地镜像)` —— 已在镜像的条目带「已下载」标记。
class _ServerDownloadPopup {
  _ServerDownloadPopup._();

  static OverlayEntry? _entry;

  /// 弹出批量下载选择框；返回用户选择的文件名列表（取消 = 空列表）。
  static Future<List<String>> show(
    BuildContext context, {
    required List<(String, int, bool)> items,
  }) {
    try {
      _entry?.remove();
    } catch (_) {}
    final completer = Completer<List<String>>();
    _entry = OverlayEntry(
      builder: (context) => _ServerDownloadPanel(
        items: items,
        onDownload: (names) {
          completer.complete(names);
          dismiss();
        },
        onCancel: () {
          completer.complete(const []);
          dismiss();
        },
      ),
    );
    Overlay.of(context).insert(_entry!);
    return completer.future;
  }

  static void dismiss() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
  }
}

/// 批量下载面板本体（标题 + 列表 + 全选/清除 + 下载所选/取消）。
class _ServerDownloadPanel extends StatefulWidget {
  final List<(String, int, bool)> items;
  final ValueChanged<List<String>> onDownload;
  final VoidCallback onCancel;

  const _ServerDownloadPanel({
    required this.items,
    required this.onDownload,
    required this.onCancel,
  });

  @override
  State<_ServerDownloadPanel> createState() => _ServerDownloadPanelState();
}

class _ServerDownloadPanelState extends State<_ServerDownloadPanel> {
  final Set<String> _selected = {};

  bool get _allSelected =>
      _selected.length == widget.items.length && widget.items.isNotEmpty;

  void _toggle(String name) {
    setState(() {
      if (_selected.contains(name)) {
        _selected.remove(name);
      } else {
        _selected.add(name);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.items.map((e) => e.$1));
      }
    });
  }

  static String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onCancel,
            child: Container(color: colors.overlay),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, maxHeight: 420),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.bgPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.borderAccent),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowMd,
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.file_download_rounded,
                        size: 16,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '批量下载服务器 mod',
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: widget.onCancel,
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textDim,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '选择服务器 mod 下载到本地镜像文件夹（每服务器专属目录）',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.items.length,
                      itemBuilder: (context, i) {
                        final (name, size, already) = widget.items[i];
                        final sel = _selected.contains(name);
                        return GestureDetector(
                          onTap: () => _toggle(name),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: sel
                                  ? colors.accent.withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Row(
                              children: [
                                _SelectionBox(selected: sel),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontSize: 11,
                                      fontFamily: 'Consolas',
                                      decoration: TextDecoration.none,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (already) ...[
                                  Text(
                                    '已下载',
                                    style: TextStyle(
                                      color: colors.success,
                                      fontSize: 9,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Text(
                                  _sizeText(size),
                                  style: TextStyle(
                                    color: colors.textDim,
                                    fontSize: 10,
                                    fontFamily: 'Consolas',
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _toggleAll,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            _allSelected ? '清除选择' : '全选',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 10,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onCancel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _selected.isEmpty
                            ? null
                            : () => widget.onDownload(
                                List<String>.from(_selected),
                              ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _selected.isEmpty
                                ? colors.bgHover
                                : colors.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '下载所选（${_selected.length}）',
                            style: TextStyle(
                              color: _selected.isEmpty
                                  ? colors.textDim
                                  : colors.bgDark,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 本地未部署 PAK 批量上传弹窗（居中多选，勾选后「上传所选」）。
class _LocalUploadPopup {
  _LocalUploadPopup._();

  static OverlayEntry? _entry;

  /// 弹出批量上传选择框；返回用户选择的文件名列表（取消 = 空列表）。
  static Future<List<String>> show(
    BuildContext context, {
    required List<(String, int)> items,
  }) {
    try {
      _entry?.remove();
    } catch (_) {}
    final completer = Completer<List<String>>();
    _entry = OverlayEntry(
      builder: (context) => _LocalUploadPanel(
        items: items,
        onUpload: (names) {
          completer.complete(names);
          dismiss();
        },
        onCancel: () {
          completer.complete(const []);
          dismiss();
        },
      ),
    );
    Overlay.of(context).insert(_entry!);
    return completer.future;
  }

  static void dismiss() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
  }
}

/// 批量上传面板本体（标题 + 列表 + 全选/清除 + 上传所选/取消）。
class _LocalUploadPanel extends StatefulWidget {
  final List<(String, int)> items;
  final ValueChanged<List<String>> onUpload;
  final VoidCallback onCancel;

  const _LocalUploadPanel({
    required this.items,
    required this.onUpload,
    required this.onCancel,
  });

  @override
  State<_LocalUploadPanel> createState() => _LocalUploadPanelState();
}

class _LocalUploadPanelState extends State<_LocalUploadPanel> {
  final Set<String> _selected = {};

  bool get _allSelected => _selected.length == widget.items.length;

  void _toggle(String name) {
    setState(() {
      if (_selected.contains(name)) {
        _selected.remove(name);
      } else {
        _selected.add(name);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.items.map((e) => e.$1));
      }
    });
  }

  static String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onCancel,
            child: Container(color: colors.overlay),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, maxHeight: 420),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.bgPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.borderAccent),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowMd,
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_rounded,
                        size: 16,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '批量上传（本地未部署）',
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: widget.onCancel,
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textDim,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '本地 ~mods 中未部署到服务器的 ${widget.items.length} 个 PAK',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.items.length,
                      itemBuilder: (context, i) {
                        final (name, size) = widget.items[i];
                        final sel = _selected.contains(name);
                        return GestureDetector(
                          onTap: () => _toggle(name),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: sel
                                  ? colors.accent.withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Row(
                              children: [
                                _SelectionBox(selected: sel),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontSize: 11,
                                      fontFamily: 'Consolas',
                                      decoration: TextDecoration.none,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  _sizeText(size),
                                  style: TextStyle(
                                    color: colors.textDim,
                                    fontSize: 10,
                                    fontFamily: 'Consolas',
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _toggleAll,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            _allSelected ? '清除选择' : '全选',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 10,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onCancel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _selected.isEmpty
                            ? null
                            : () =>
                                  widget.onUpload(List<String>.from(_selected)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _selected.isEmpty
                                ? colors.bgHover
                                : colors.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '上传所选（${_selected.length}）',
                            style: TextStyle(
                              color: _selected.isEmpty
                                  ? colors.textDim
                                  : colors.bgDark,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
