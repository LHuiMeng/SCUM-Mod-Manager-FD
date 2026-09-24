/// 云上 mod 浏览面板 —— 显示远端 registry 中的 mod 列表。
///
/// 支持：
/// - 展示每个云 mod 的名称、描述、版本、大小、标签
/// - 单个下载 / 批量全部下载，下载中按钮显示加载态
/// - 已下载状态标记
/// - 后台拉取不阻塞 UI，切 tab 不会重复拉取
/// - 空态 / 错误态 / 手动刷新
/// - 自绘滚动条（大量云 mod 可滚动）
/// - 顶部搜索 + 多标签筛选
///
/// 全部自绘，无 Material 控件。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/download_result.dart';
import '../models/remote_mod_entry.dart';
import '../services/app_logger.dart';
import '../services/mod_registry_client.dart';
import '../services/mod_service.dart';
import '../services/pinyin_search.dart';
import '../services/server_sftp_service.dart';
import '../theme/scum_colors.dart';
import 'animated_toast.dart';
import 'mod_table.dart';
import 'scrollbar_painter.dart';
import 'tag_filter_menu.dart';

/// 云上 mod 列表的可配置列。
const List<TableColumnSpec> cloudColumnSpecs = [
  TableColumnSpec('name', '名称', 200),
  TableColumnSpec('version', '版本', 70),
  TableColumnSpec('localVersion', '本地版本', 90),
  TableColumnSpec('description', '描述', 200),
  TableColumnSpec('size', '大小', 90),
  TableColumnSpec('tags', '标签', 150),
  TableColumnSpec('time', '时间', 130),
  TableColumnSpec('sha256', 'SHA-256', 280),
  TableColumnSpec('notes', '备注', 160),
];

/// 云上 mod 浏览面板。
class CloudModsPanel extends StatefulWidget {
  final ModService modService;
  final VoidCallback? onModsChanged;

  /// 远程服务器 SFTP 服务（可选）：用于「备注获取」——云端无备注时，
  /// 按 sha-256 从服务器本地库取第一个非空备注兜底展示。
  final ServerSftpService? sftpService;

  const CloudModsPanel({
    super.key,
    required this.modService,
    this.onModsChanged,
    this.sftpService,
  });

  @override
  State<CloudModsPanel> createState() => _CloudModsPanelState();
}

class _CloudModsPanelState extends State<CloudModsPanel> {
  /// 是否正在后台拉取（首次或刷新时）。
  bool _refreshing = false;

  /// 拉取失败的错误信息。
  String? _error;

  /// 正在下载中的云 mod ID 集合（跨 tab 由 ModService 维护，这里只读）。
  Set<String> get _downloadingIds => widget.modService.cloudDownloadingIds;

  /// 下载进度（id → 0.0~1.0；跨 tab 由 ModService 维护，切界面不丢）。
  Map<String, double> get _downloadProgress =>
      widget.modService.cloudDownloadProgress;

  /// 是否首次渲染时数据仍为空（需启动后台拉取）。
  bool _initialFetchDone = false;

  /// 搜索框文本（小写归一化）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  /// 当前选中的云 mod 标签（多选）。
  Set<String> _selectedTags = <String>{};

  /// 当前排序列 id（null = 默认顺序）+ 方向。由表头点击切换（与本地列表一致）。
  String? _sortCol;
  bool _sortAsc = true;

  /// 云列配置（顺序 / 可见性 / 宽度，持久化到 config.json `cloud_table_columns`）。
  ColumnLayout _cloudLayout = ColumnLayout(specs: cloudColumnSpecs);

  /// 滚动控制器 —— 让 ScumScrollbar 跟随滚动。
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // 不自阻塞 UI 的拉取：如果缓存为空，在后台静默拉取。
    _lazyFetchIfNeeded();
    // 从 config.json 加载已保存的云列配置。
    _cloudLayout = ColumnLayout.fromJson(
      widget.modService.loadConfigKey('cloud_table_columns'),
      specs: cloudColumnSpecs,
    );
    // 监听 ModService 变化（service 端已 ChangeNotifier）。
    widget.modService.addListener(_onModServiceChanged);
  }

  @override
  void dispose() {
    widget.modService.removeListener(_onModServiceChanged);
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// ModService 通知回调 —— 触发本 widget 重建。
  void _onModServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 云列配置变化 → setState 实时刷新 UI；防抖 300ms 写盘（常驻）。
  Timer? _cloudLayoutCommitTimer;
  void _onCloudLayoutChanged(ColumnLayout layout) {
    setState(() => _cloudLayout = layout);
    _cloudLayoutCommitTimer?.cancel();
    _cloudLayoutCommitTimer = Timer(const Duration(milliseconds: 300), () {
      widget.modService.saveConfigKey(
        'cloud_table_columns',
        _cloudLayout.toJson(),
      );
    });
  }

  /// 云列配置提交（拖宽松手 / 菜单操作后）→ 持久化。
  void _onCloudLayoutCommit() {
    widget.modService.saveConfigKey(
      'cloud_table_columns',
      _cloudLayout.toJson(),
    );
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

  /// 缓存为空时静默后台拉取，不显示 loading 遮罩。
  Future<void> _lazyFetchIfNeeded() async {
    if (widget.modService.cloudMods.isNotEmpty) {
      _initialFetchDone = true;
      return;
    }
    // 静默后台拉取：不设 _refreshing，不阻塞 UI
    final list = await RegistryClient.fetchModList();
    if (!mounted) return;
    widget.modService.setCloudModCatalog(
      list,
    ); // 会 notify → _onModServiceChanged
    _initialFetchDone = true;
  }

  /// 用户手动刷新。
  Future<void> _refresh() async {
    AppLogger.instance.ui('刷新云上 mod 目录', action: '点击');
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await widget.modService.refreshCloudCatalog();
      if (mounted) setState(() => _refreshing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _error = '连接失败：${e.toString()}';
        });
      }
    }
  }

  Future<void> _downloadSingle(RemoteModEntry mod) async {
    // 已下载且非旧版本时点击的是「重新下载」→ 强制覆盖重下（跳过内容一致判定）；
    // 未下载 / 旧版本则走普通下载（内部已有过时覆盖与内容级判重）。
    final redownload = widget.modService.isCloudModDownloaded(mod.id) &&
        !widget.modService.isCloudOutdated(mod);
    AppLogger.instance.ui(
      redownload ? '重新下载云上 mod' : '下载云上 mod',
      action: '点击',
      details: {'remote_id': mod.id, 'name': mod.name},
    );
    // 下载状态（进行中/进度）由 ModService 跨 tab 维护，本面板无需本地记录；
    // 开始/进度/结束都会 notify → 面板 _onModServiceChanged 自动重建。
    final result =
        await widget.modService.downloadCloudMod(mod, force: redownload);
    if (!mounted) return;
    if (result.ok) {
      AppLogger.instance.info('云上 mod 下载按钮反馈：成功', {'remote_id': mod.id});
      // 新 mod 已增量加入本地列表（downloadCloudMod 内完成），无需全盘 scanMods。
      widget.onModsChanged?.call();
    } else {
      AppLogger.instance.warning('云上 mod 下载按钮反馈：失败', {
        'remote_id': mod.id,
        'error': result.error,
      });
      _showDownloadError(mod.name, result.error);
    }
  }

  Future<void> _downloadAll() async {
    AppLogger.instance.ui('下载全部云上 mod', action: '点击');
    final pending = widget.modService.cloudMods
        .where(
          (m) =>
              !widget.modService.isCloudModDownloaded(m.id) ||
              widget.modService.isCloudOutdated(m),
        )
        .toList();
    if (pending.isEmpty) return;

    // 并发下载（mod 间并发 + 单 mod 内部分段并发）：总时间下探到
    // max(单 mod) 而非 sum(所有 mod)。下载状态由 ModService 跨 tab 维护。
    final failures = <String>[];
    await Future.wait(
      pending.map((mod) async {
        final result = await widget.modService.downloadCloudMod(mod);
        if (result.ok) {
          AppLogger.instance.info('云上 mod 下载完成', {'remote_id': mod.id});
        } else {
          AppLogger.instance.warning('云上 mod 下载失败', {
            'remote_id': mod.id,
            'error': result.error,
          });
          failures.add('「${mod.name}」：${result.error}');
        }
      }),
    );
    if (!mounted) return;
    // 失败汇总提示（逐个失败原因一目了然）。
    if (failures.isNotEmpty) {
      _showDownloadError('${failures.length} 个 mod', failures.join('\n'));
    }
    // 下载完成已即时增量入本地列表；此处仅通知外层刷新。
    widget.onModsChanged?.call();
  }

  /// 下载失败提示（Toast，说明原因）。
  void _showDownloadError(String subject, String? reason) {
    if (!mounted) return;
    AutoDetectToast.show(
      context,
      message: '$subject 下载失败：${reason ?? '未知原因'}',
      backgroundColor: ScumColors.of(context).danger,
      icon: Icons.error_outline_rounded,
      duration: const Duration(seconds: 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Column(
      children: [
        _buildTopBar(colors),
        _buildToolbar(colors),
        // ── 可配置列表头（点击排序 / 右键显隐 / 拖拽排序 / 拖宽）──
        if (widget.modService.cloudMods.isNotEmpty)
          ModTableHeader(
            specs: cloudColumnSpecs,
            layout: _cloudLayout,
            onLayoutChanged: _onCloudLayoutChanged,
            onLayoutCommit: _onCloudLayoutCommit,
            sortColumnId: _sortCol,
            sortAscending: _sortAsc,
            onSort: _onHeaderSort,
          ),
        Expanded(child: _buildBody(colors)),
      ],
    );
  }

  Widget _buildToolbar(ScumColors colors) {
    final allMods = widget.modService.cloudMods;
    // 聚合所有云 mod 的标签（去重排序）。
    final allTags = <String>{for (final m in allMods) ...m.tags}.toList()
      ..sort();
    final hasFilter = _searchQuery.isNotEmpty || _selectedTags.isNotEmpty;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.bgDark.withValues(alpha: 0.82),
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          // 自绘搜索框
          _CloudSearchField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
          ),
          const SizedBox(width: 12),
          // 标签筛选下拉（无 tag 时隐藏）
          if (allTags.isNotEmpty) ...[
            _CloudTagFilterButton(
              allTags: allTags,
              selectedTags: _selectedTags,
              onTagsChanged: (tags) => setState(() => _selectedTags = tags),
            ),
            const SizedBox(width: 12),
          ],
          // 过滤命中数 / 总数
          Text(
            hasFilter
                ? '${_filteredCloudMods.length} / ${allMods.length}'
                : '${allMods.length}',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              fontFamily: 'Consolas',
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          // 清除过滤按钮
          if (hasFilter)
            GestureDetector(
              onTap: () {
                setState(() {
                  _searchCtrl.clear();
                  _searchQuery = '';
                  _selectedTags = <String>{};
                });
              },
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
      ),
    );
  }

  /// 过滤后的云 mod 列表（本地 filter，不动 ModService）。
  List<RemoteModEntry> get _filteredCloudMods {
    final all = widget.modService.cloudMods;
    if (_searchQuery.isEmpty && _selectedTags.isEmpty) return all;
    final q = _searchQuery.trim();
    final filtered = all.where((m) {
      if (q.isNotEmpty) {
        // 拼音/首字母检索：名称/ID/描述/备注任一命中即算（PinyinSearch.matches
        // 内部先做原文 contains，再转拼音比对；目标文本无汉字时零转换开销）。
        if (!PinyinSearch.matches(m.name, q) &&
            !PinyinSearch.matches(m.id, q) &&
            !PinyinSearch.matches(m.description ?? '', q) &&
            !PinyinSearch.matches(m.notes ?? '', q)) {
          return false;
        }
      }
      if (_selectedTags.isNotEmpty) {
        // 多选 = OR 语义：mod 含任一选中标签即命中
        if (!m.tags.any(_selectedTags.contains)) return false;
      }
      return true;
    }).toList();
    // 排序（默认 = 目录原有顺序；表头点击排序列 id + 方向）
    if (_sortCol != null) {
      final col = _sortCol!;
      final asc = _sortAsc;
      final copy = List<RemoteModEntry>.from(filtered);
      copy.sort(
        (a, b) =>
            asc ? _compareCloudMods(a, b, col) : _compareCloudMods(b, a, col),
      );
      return copy;
    }
    return filtered;
  }

  /// 发布时间比较（ISO 字符串，null 排末尾）。
  static int _cmpTime(String? a, String? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  /// 按列比较两个云 mod（升序语义；降序由调用方交换操作数，保证空值/空串排尾）。
  /// 本地版本列需要访问 ModService 取本地条目，故为实例方法（其余列无此依赖）。
  int _compareCloudMods(RemoteModEntry a, RemoteModEntry b, String col) {
    switch (col) {
      case 'name':
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'version':
        return _cmpStr(a.version, b.version);
      case 'localVersion':
        // 本地版本按 semver-ish 比较；无本地条目/无版本段排末尾。
        final va = widget.modService.localVersionForCloud(a);
        final vb = widget.modService.localVersionForCloud(b);
        if (va == null && vb == null) return 0;
        if (va == null) return 1;
        if (vb == null) return -1;
        return RemoteModEntry.compare(va.toLowerCase(), vb.toLowerCase());
      case 'description':
        return _cmpStr(a.description ?? '', b.description ?? '');
      case 'size':
        return a.sizeBytes.compareTo(b.sizeBytes);
      case 'tags':
        return _cmpStr(a.tags.join(' '), b.tags.join(' '));
      case 'time':
        return _cmpTime(a.releasedAt, b.releasedAt);
      case 'sha256':
        return _cmpStr(a.sha256 ?? '', b.sha256 ?? '');
      case 'notes':
        return _cmpStr(a.notes ?? '', b.notes ?? '');
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

  /// 全局下载进度：各下载中 mod 按文件大小加权平均（0.0~1.0）。
  /// 顶栏在此显示总体进度（多端并发时的第二个进度位置）。
  double get _overallProgress {
    if (_downloadingIds.isEmpty) return 0;
    var wSum = 0.0;
    var wTotal = 0.0;
    for (final m in widget.modService.cloudMods) {
      if (!_downloadingIds.contains(m.id)) continue;
      wTotal += m.sizeBytes;
      wSum += (_downloadProgress[m.id] ?? 0) * m.sizeBytes;
    }
    return wTotal > 0 ? wSum / wTotal : 0;
  }

  Widget _buildTopBar(ScumColors colors) {
    final count = widget.modService.cloudMods.length;
    final downloaded = widget.modService.cloudMods
        .where((m) => widget.modService.isCloudModDownloaded(m.id))
        .length;
    final hasPending = widget.modService.cloudMods.any(
      (m) =>
          !widget.modService.isCloudModDownloaded(m.id) ||
          widget.modService.isCloudOutdated(m),
    );

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        // 半透明让自定义背景图透过
        color: colors.bgDark.withValues(alpha: 0.82),
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, size: 16, color: colors.accent),
          const SizedBox(width: 6),
          Text(
            '云上 Mod',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($downloaded/$count)',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
          // 多端并发下载：顶栏另设一个位置显示全局进度（各 mod 按大小加权）。
          if (_downloadingIds.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
                    ),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '${_downloadingIds.length} 个下载中'
                    ' · ${(_overallProgress * 100).round()}%',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_refreshing) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
              ),
            ),
          ],
          const Spacer(),
          _IconBtn(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onTap: _refreshing ? null : _refresh,
          ),
          const SizedBox(width: 4),
          if (!_refreshing && hasPending)
            _IconBtn(
              icon: _downloadingIds.isEmpty
                  ? Icons.download_rounded
                  : Icons.downloading,
              tooltip: _downloadingIds.isEmpty ? '下载全部' : '正在下载…',
              onTap: _downloadingIds.isEmpty ? _downloadAll : null,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ScumColors colors) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 36, color: colors.textDim),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.danger,
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 12),
            _IconBtn(
              icon: Icons.refresh_rounded,
              tooltip: '重试',
              onTap: _refresh,
            ),
          ],
        ),
      );
    }

    final cloudMods = widget.modService.cloudMods;
    if (cloudMods.isEmpty) {
      if (!_initialFetchDone) {
        // 首次仍在后台拉取中，显示空白但不阻塞
        return Center(
          child: Text(
            '正在连接服务器...',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 12,
              decoration: TextDecoration.none,
            ),
          ),
        );
      }
      return Center(
        child: Text(
          '云上暂无可用 mod',
          style: TextStyle(
            color: colors.textDim,
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      );
    }

    final filtered = _filteredCloudMods;
    if (filtered.isEmpty) {
      // 有云 mod 但全部被过滤掉 —— 显示「无匹配」空态而不是空白列表。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 32,
              color: colors.textDim.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 6),
            Text(
              '没有匹配的云上 mod',
              style: TextStyle(
                color: colors.textDim,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      );
    }

    // 自绘滚动条 + ListView.builder —— 支持任意数量的云 mod。
    // 横向 8px padding 与表头 ModTableHeader 的 8px 对齐。
    return ScumScrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 140),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final mod = filtered[index];
          final isDownloading = _downloadingIds.contains(mod.id);
          final downloaded = widget.modService.isCloudModDownloaded(mod.id);
          final outdated = downloaded && widget.modService.isCloudOutdated(mod);
          // 备注获取：云端无备注时，按 sha-256 从所有服务器库取第一个非空备注。
          String? remoteNotes;
          if ((mod.notes == null || mod.notes!.isEmpty) &&
              widget.sftpService != null) {
            remoteNotes = widget.sftpService!.findServerNotesBySha256(
              mod.sha256 ?? '',
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: Stack(
              children: [
                buildConfigurableRow(
                  context: context,
                  layout: _cloudLayout,
                  enabled: true,
                  fixedLeft: [
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
                  fixedRight: [
                    const SizedBox(width: 8),
                    // 未配置获取地址的云 mod：显示文字指引，教用户如何在此文件添加。
                    if (RegistryClient.isDownloadUnconfigured(mod))
                      const _UnconfiguredSourceHint()
                    else
                      _DownloadButton(
                        downloaded: downloaded,
                        outdated: outdated,
                        downloading: isDownloading,
                        progress: _downloadProgress[mod.id],
                        // 已下载且最新 → 显示「重新下载」仍可点击（force 重下）；
                        // 仅下载进行中禁用。
                        onTap:
                            isDownloading ? null : () => _downloadSingle(mod),
                      ),
                  ],
                  cellBuilder: (spec) =>
                      _cloudCell(context, spec.id, mod, remoteNotes),
                ),
                // 整行下载进度背景（自 # 至下载按钮）：强调色按进度从左到右
                // 铺满整行 —— 行背景即进度条，按钮仅保留轻量百分比指示。
                // IgnorePointer 保证进度层不拦截行内点击/拖拽。
                if (isDownloading)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _downloadProgress[mod.id] ?? 0,
                        child: ColoredBox(
                          color: colors.accent.withValues(alpha: 0.13),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 云列表单列单元格渲染。
  /// 单列单元格内容（水平对齐由 buildConfigurableRow 按 spec.align 统一处理）。
  Widget _cloudCell(
    BuildContext context,
    String colId,
    RemoteModEntry mod,
    String? remoteNotes,
  ) {
    final colors = ScumColors.of(context);
    final dim = TextStyle(
      color: colors.textDim,
      fontSize: 11,
      fontFamily: 'Consolas',
      decoration: TextDecoration.none,
    );
    switch (colId) {
      case 'name':
        return Tooltip(
          message: mod.name,
          child: Text(
            mod.name,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        );
      case 'version':
        return Text('v${mod.version}', style: dim);
      case 'localVersion':
        // 本地对应条目版本：无本地条目 / 文件名无版本段 → 显示「—」；
        // 本地落后于云端（outdated）时以强调色提示可更新。
        final lv = widget.modService.localVersionForCloud(mod);
        if (lv == null) return Text('—', style: dim);
        final outdated = widget.modService.isCloudOutdated(mod);
        return Tooltip(
          message: outdated ? '本地版本落后于云端，可点击「更新」' : '',
          child: Text(
            'v$lv',
            style: dim.copyWith(
              color: outdated ? colors.accent : colors.textSecondary,
              fontWeight: outdated ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        );
      case 'description':
        final desc = (mod.description?.isNotEmpty ?? false)
            ? mod.description!
            : '—';
        return Tooltip(
          message: desc == '—' ? '' : desc,
          child: Text(
            desc,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
        );
      case 'size':
        return Text(_formatBytes(mod.sizeBytes), style: dim);
      case 'tags':
        return ScumTagsRow(tags: mod.tags, colors: colors);
      case 'time':
        return Text(mod.releasedAt ?? '—', style: dim);
      case 'sha256':
        final sha = mod.sha256;
        if (sha == null || sha.isEmpty) return Text('—', style: dim);
        // 按表头宽度自适应显示字符数（约每字符 7px），悬停显示完整哈希。
        final chars = ((_cloudLayout.widthOf('sha256') - 20) / 7).floor().clamp(
          8,
          64,
        );
        final shown = sha.length <= chars ? sha : '${sha.substring(0, chars)}…';
        return Tooltip(
          message: sha,
          child: Text(
            shown,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: dim.copyWith(color: colors.accent),
          ),
        );
      case 'notes':
        final note = (mod.notes != null && mod.notes!.isNotEmpty)
            ? mod.notes!
            : (remoteNotes ?? '');
        return Tooltip(
          message: note.isEmpty ? '' : note,
          child: Text(
            note.isEmpty ? '—' : note,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: (mod.notes != null && mod.notes!.isNotEmpty)
                  ? colors.accent
                  : colors.textSecondary,
              fontSize: 11,
              decoration: TextDecoration.none,
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// =====================================================================
//  行内标签 + 尺寸格式化（表格行复用）
// =====================================================================

/// 字节数格式化（KB / MB）。
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// =====================================================================
//  下载/下载中/已下载 按钮
// =====================================================================

class _DownloadButton extends StatelessWidget {
  final bool downloaded;
  final bool outdated;
  final bool downloading;

  /// 下载进度 0.0~1.0（下载中且已有数据时显示进度条 + 百分比）。
  final double? progress;
  final VoidCallback? onTap;

  const _DownloadButton({
    required this.downloaded,
    this.outdated = false,
    this.downloading = false,
    this.progress,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    if (outdated) {
      // 本地已有旧版本 → 显示「更新」：点击即覆盖下载（无需手动删旧 mod）。
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.accent.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.system_update_alt_rounded,
                size: 12,
                color: colors.accent,
              ),
              SizedBox(width: 4),
              Text(
                '更新',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (downloaded) {
      // 已下载且为最新版本：提供「重新下载」入口（force 覆盖重下，内容一致也重下）。
      // 不再是纯状态徽章 —— 点击即强制重新下载，满足「本地文件损坏/想重置时重下」。
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colors.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.success.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh_rounded, size: 12, color: colors.success),
              SizedBox(width: 4),
              Text(
                '重新下载',
                style: TextStyle(
                  color: colors.success,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (downloading) {
      // 整行背景已承担进度（见行渲染的进度染色层），按钮仅保留轻量指示
      // （spinner + 百分比），不再自带背景填充。
      final frac = (progress ?? 1.0).clamp(0.0, 1.0);
      return GestureDetector(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                progress != null ? '下载中 ${(frac * 100).round()}%' : '下载中',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: colors.accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_rounded, size: 12, color: colors.accent),
            SizedBox(width: 4),
            Text(
              '下载',
              style: TextStyle(
                color: colors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  标签 chip
// =====================================================================

// =====================================================================
//  图标按钮
// =====================================================================

/// 自绘带 hover tooltip 的图标按钮 —— 无 Material Tooltip，
/// 替代原 Material.Tooltip 包装（保持项目"全自绘"约束）。
class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _IconBtn({required this.icon, required this.tooltip, this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;
  bool _showTooltip = false;

  /// tooltip 延迟显示 timer —— dispose 时 cancel，避免 stale Future 触发
  /// 已 unmount state 的 setState（虽然 callback 内部已 mounted 守卫，
  /// 但 cancel 更稳）。
  Timer? _tooltipTimer;

  @override
  void initState() {
    super.initState();
    if (widget.tooltip.isNotEmpty) {
      _tooltipTimer = Timer(const Duration(milliseconds: 400), () {
        if (mounted && _hovered) setState(() => _showTooltip = true);
      });
    }
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final disabled = widget.onTap == null;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        if (widget.tooltip.isNotEmpty) {
          _tooltipTimer?.cancel();
          _tooltipTimer = Timer(const Duration(milliseconds: 400), () {
            if (mounted && _hovered) setState(() => _showTooltip = true);
          });
        }
      },
      onExit: (_) {
        setState(() {
          _hovered = false;
          _showTooltip = false;
        });
      },
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: disabled
                      ? colors.border.withValues(alpha: 0.4)
                      : colors.border,
                ),
              ),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: 16,
                  color: disabled
                      ? colors.textDim.withValues(alpha: 0.4)
                      : colors.textSecondary,
                ),
              ),
            ),
            // 自绘 tooltip：Positioned 在按钮上方 -28px，UnconstrainedBox
            // 解开 tight width（按钮28px），wrap text 用 IntrinsicWidth+maxLines。
            if (_showTooltip && widget.tooltip.isNotEmpty)
              Positioned(
                left: 14,
                top: -28,
                child: IgnorePointer(
                  child: UnconstrainedBox(
                    alignment: Alignment.topCenter,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.bgDark.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        widget.tooltip,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11,
                          decoration: TextDecoration.none,
                        ),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                      ),
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

// =====================================================================
//  云端面板专用：搜索 + 多标签筛选
// =====================================================================

/// 云 mod 搜索框 —— 用 EditableText 自绘，跟 ModListToolbar._SearchField
/// 同款交互，但只为本面板服务，避免互相干扰。
class _CloudSearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _CloudSearchField({required this.controller, required this.onChanged});

  @override
  State<_CloudSearchField> createState() => _CloudSearchFieldState();
}

class _CloudSearchFieldState extends State<_CloudSearchField> {
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
      width: 220,
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
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.search_rounded,
                  size: 16,
                  color: colors.textDim,
                ),
              ),
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
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: colors.textDim,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 云 mod 多标签筛选按钮 —— 点击弹出多选菜单。
///
/// 行为与 ModListToolbar._TagFilterButton 类似，但菜单本体在本类内
/// 简化实现（无清除按钮，滚动条铁律豁免：菜单项 <20 通常不会溢出）。
class _CloudTagFilterButton extends StatefulWidget {
  final List<String> allTags;
  final Set<String> selectedTags;
  final ValueChanged<Set<String>> onTagsChanged;

  const _CloudTagFilterButton({
    required this.allTags,
    required this.selectedTags,
    required this.onTagsChanged,
  });

  @override
  State<_CloudTagFilterButton> createState() => _CloudTagFilterButtonState();
}

class _CloudTagFilterButtonState extends State<_CloudTagFilterButton> {
  bool _hovered = false;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _entry;

  @override
  void dispose() {
    if (_entry != null) {
      try {
        _entry!.remove();
      } catch (_) {}
      _entry = null;
    }
    super.dispose();
  }

  void _toggleMenu() {
    if (_entry != null) {
      try {
        _entry!.remove();
      } catch (_) {}
      _entry = null;
    } else {
      _entry = _buildOverlay();
      Overlay.of(context).insert(_entry!);
    }
  }

  OverlayEntry _buildOverlay() {
    final sorted = List<String>.from(widget.allTags)..sort();
    return OverlayEntry(
      builder: (context) => ScumTagFilterMenu(
        layerLink: _layerLink,
        sortedTags: sorted,
        selectedTags: widget.selectedTags,
        onTagsChanged: widget.onTagsChanged,
        onDismiss: () {
          if (_entry != null) {
            try {
              _entry!.remove();
            } catch (_) {}
            _entry = null;
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final count = widget.selectedTags.length;
    final label = count > 0 ? '标签 ($count)' : '标签筛选';
    final hasSelection = count > 0;

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
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
                  label,
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

/// 未配置获取地址的云 mod 提示：文字描述告诉用户如何添加。
class _UnconfiguredSourceHint extends StatelessWidget {
  const _UnconfiguredSourceHint({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Tooltip(
      message:
          '该 mod 未配置下载地址。\n'
          '编辑 ${RegistryClient.sourcesFilePath}\n'
          '在 "cloud_sources" 节点的 "mods" 下按 id 添加：\n'
          '  "<mod id>": { "download_url": "https://你的地址/xxx.pak" }\n'
          '保存后刷新即可下载。',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: colors.textDim.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: colors.textDim.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded, size: 12, color: colors.textDim),
            const SizedBox(width: 3),
            Text(
              '未配置地址',
              style: TextStyle(
                color: colors.textDim,
                fontSize: 10,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
