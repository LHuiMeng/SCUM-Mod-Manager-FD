///
/// v2 HomeScreen —— 模组列表管理页 + 拖拽接收（事件驱动）。
///
/// 拖拽流程（实时反馈，用户还在拖就显示动画）：
/// 1. 用户从资源管理器拖 .pak 经过窗口上方
/// 2. C++ `IDropTarget::DragEnter` 触发 → Dart `onDragEnter` 回调
/// 3. DropZoneOverlay **立刻**渐显（200ms 进场）
/// 4. 用户松手 → C++ `IDropTarget::Drop` 触发 → Dart `onDroppedFiles`
/// 5. 异步复制到 `~mods/`（UI 不阻塞，overlay 持续显示）
/// 6. 复制完成后直接渐隐 overlay（150ms 出场）——"已导入 X 个"由
///    Toast/SnackBar 提示（不再额外保持 800ms，见 _dropHoldAfterImport）
/// 7. 新 mod 的 ModCard 入场动画（400ms 滑入+淡入）
///
/// 如果用户拖到窗口外面但没松手：
/// - C++ `IDropTarget::DragLeave` → 立即淡出 overlay
///
/// v2 新增：列表工具栏（搜索 + 标签筛选 + 全选反选）、卡片展开编辑备注/标签。
///
/// v2.2 调整：右下角浮层（RightDock）替代底部工具栏，
/// 启动按钮与齿轮按钮悬浮在内容右下角。
///
/// v2.3 调整：
/// - ModCard 的标签/备注改为始终显示在主行下方（无需展开）
/// - 单卡片启用/禁用/删除通过 _onModToggle/_onModDelete 触发 setState，
///   实时刷新列表视觉
/// - 全选按钮：当前全启用时切换为"全禁用"（图标 deselect_rounded）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/launch_options.dart';
import '../models/mod_entry.dart';
import '../services/background_service.dart';
import '../services/conflict_service.dart';
import '../services/launcher_service.dart';
import '../services/merge_service.dart';
import '../services/mod_service.dart';
import '../services/server_sftp_service.dart';
import '../services/ue4ss_service.dart';
import '../services/window_service.dart';
import '../services/app_logger.dart';
import '../services/app_signals.dart';
import '../services/app_version.dart';
import '../services/pinyin_search.dart';
import '../theme/scum_colors.dart';
import '../widgets/background_image_layer.dart';
import '../widgets/drop_zone_overlay.dart';
import '../widgets/overwrite_dialog.dart';
import '../widgets/right_dock.dart';
import '../widgets/mod_list_toolbar.dart';
import '../widgets/mod_table.dart';
import '../widgets/mod_settings_popup.dart';
import '../widgets/sidebar.dart';
import '../widgets/cloud_mods_panel.dart';
import '../widgets/conflict_panel.dart';
import '../widgets/server_mods_panel.dart';
import '../widgets/scrollbar_painter.dart';
import '../widgets/title_bar.dart';
import 'settings_screen.dart';
import 'log_screen.dart';

class HomeScreen extends StatefulWidget {
  final ModService modService;
  final String selectedTab;
  final ValueChanged<String> onTabChanged;
  final VoidCallback? onPathsChanged;

  const HomeScreen({
    super.key,
    required this.modService,
    this.selectedTab = 'mods',
    required this.onTabChanged,
    this.onPathsChanged,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ===== Drop 状态机 =====

  _DropPhase _dropPhase = _DropPhase.hidden;
  List<String> _lastImported = const [];

  // Overlay 显隐动画 controller。
  late final AnimationController _dropFadeCtrl;

  // 新 mod 入场动画的 id 集合。
  final Set<String> _pendingEntranceIds = <String>{};

  // C1 Mica：背景恒用 colors.bgDark 不透明（见 build 注释——Mica 会渲染成
  // 系统主题色，切亮色后背景仍是黑，故废弃"透明透 Mica"方案）。
  // enableMica 调用链仍然保留：设置页 toggle 通过 AppSignals.micaEnabled
  // 触发本页 listener，维持 C++ 侧系统级属性注册——将来要恢复 Mica 视觉
  // 时只需把 build 里的 Material 背景改回透明即可。

  // 3c 自定义背景图：路径存到 AppSignals.backgroundPath（global ValueNotifier）。
  // 让 Settings 页改完后通过同一 notifier 通知 home_screen 重建。
  // 见 [AppSignals] 定义。

  // ===== 工具栏状态 =====

  final TextEditingController _searchCtrl = TextEditingController();

  /// mod 列表滚动控制器 —— 驱动自绘 ScumScrollbar。
  final ScrollController _modScrollCtrl = ScrollController();
  String _searchQuery = '';
  Set<String> _filterTags = <String>{};

  /// 当前排序列 id（null = 默认拖拽加载序）。由表头点击切换。
  String? _sortCol;

  /// 当前排序方向（true = 升序；false = 降序）。
  bool _sortAsc = true;

  /// 「只看冲突 mod」筛选开关（由冲突面板的按钮切换）。
  bool _conflictsOnly = false;

  /// PAK 类型显示开关（true = 显示客户端/服务端 PAK mod）。
  bool _showPak = true;

  /// UE4SS 类型显示开关（true = 显示 UE4SS mod）。
  bool _showUe4ss = true;

  /// 列表列配置（顺序 / 可见性 / 宽度，持久化到 config.json）。
  ColumnLayout _columnConfig = ColumnLayout.defaultLocal();

  // ===== 启动选项状态（持久化到 config.json） =====

  late LaunchOptions _launchOptions;

  // ===== 时长常量 =====

  static const Duration _dropFadeIn = Duration(milliseconds: 200);
  // 松手后是否额外保持 overlay 展示导入结果。
  // 当前为 0 = 不保持，直接渐隐（"已导入 X 个"由 _showImportToast 的
  // SnackBar 承担反馈，overlay 不再多停留 800ms）。
  static const Duration _dropHoldAfterImport = Duration(milliseconds: 0);
  static const Duration _dropFadeOut = Duration(milliseconds: 150);
  static const Duration _cardEntrance = Duration(milliseconds: 400);

  // ===== 计算属性 =====

  /// 是否有激活的筛选条件（搜索 / 标签 / 排序 / 类型开关任一激活都禁拖拽）。
  bool get _hasFilter =>
      _searchQuery.isNotEmpty ||
      _filterTags.isNotEmpty ||
      _conflictsOnly ||
      _sortCol != null ||
      !_showPak ||
      !_showUe4ss;

  /// 是否允许拖拽重排：搜索/标签/排序任一激活都禁止（列表被裁剪时可见索引
  /// 无法直接映射真实加载序）；仅 PAK/UE4SS 类型显示开关时允许拖拽——可见
  /// 子集保持与全量相对顺序一致，重排时映射回全量加载序（见 [_onReorder]）。
  bool get _canDragReorder =>
      _searchQuery.isEmpty &&
      _filterTags.isEmpty &&
      !_conflictsOnly &&
      _sortCol == null;

  /// 根据搜索、标签筛选并排序后的 mod 列表。
  List<ModEntry> get _filteredMods {
    final svc = widget.modService;
    var list = svc.mods;
    if (_searchQuery.isNotEmpty || _filterTags.isNotEmpty) {
      // 拼音/首字母检索：查询可以是原文、汉字全拼或首字母（PinyinSearch.matches
      // 内部先做原文 contains，再转拼音比对；目标文本无汉字时零转换开销）。
      final q = _searchQuery.trim();
      list = list.where((m) {
        if (q.isNotEmpty &&
            !PinyinSearch.matches(m.name, q) &&
            !PinyinSearch.matches(m.notes, q)) {
          return false;
        }
        if (_filterTags.isNotEmpty && !m.tags.any(_filterTags.contains)) {
          return false;
        }
        return true;
      }).toList();
    }
    // PAK / UE4SS 类型显示过滤（隐藏某类时其余相对顺序不变）。
    if (!_showPak || !_showUe4ss) {
      list = list.where((m) {
        final isPak =
            m.type == ModType.clientPak || m.type == ModType.serverPak;
        final isUe4 = m.type == ModType.ue4ssMod;
        if (!_showPak && isPak) return false;
        if (!_showUe4ss && isUe4) return false;
        return true;
      }).toList();
    }
    // 「只看冲突」过滤：仅保留参与冲突的 mod；扫描未完成（report 为 null）时保持原列表。
    if (_conflictsOnly) {
      final rep = ConflictService.shared.report;
      if (rep != null) {
        final ids = rep.conflictedModIds;
        list = list.where((m) => ids.contains(m.id)).toList();
      }
    }
    if (_sortCol != null) {
      final col = _sortCol!;
      final asc = _sortAsc;
      final copy = List<ModEntry>.from(list);
      copy.sort(
        (a, b) => asc ? _compareMods(a, b, col) : _compareMods(b, a, col),
      );
      list = copy;
    }
    return list;
  }

  /// 按列比较两个 mod（升序语义；降序由调用方交换操作数，保证空值/空串排尾）。
  static int _compareMods(ModEntry a, ModEntry b, String col) {
    switch (col) {
      case 'name':
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'notes':
        return _cmpStr(a.notes, b.notes);
      case 'type':
        return a.type.name.compareTo(b.type.name);
      case 'tags':
        return _cmpStr(a.tags.join(' '), b.tags.join(' '));
      case 'size':
        return a.fileSize.compareTo(b.fileSize);
      case 'time':
        return _cmpTime(a.lastModified, b.lastModified);
      case 'sha256':
        return _cmpStr(a.sha256, b.sha256);
      case 'origin':
        return (a.isCloudMod ? 1 : 0).compareTo(b.isCloudMod ? 1 : 0);
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

  /// 时间比较：null 排末尾。
  static int _cmpTime(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  // ===== 工具栏回调 =====

  void _onSearchChanged(String query) {
    AppLogger.instance.ui('模组搜索框', action: '输入', details: {'query': query});
    setState(() => _searchQuery = query);
  }

  /// 表头点击排序：新列 → 按该列默认方向；同列连点 → 升序/降序/恢复默认循环。
  void _onHeaderSort(String colId) {
    AppLogger.instance.ui('模组排序', action: '表头点击', details: {'column': colId});
    setState(() {
      if (_sortCol != colId) {
        _sortCol = colId;
        _sortAsc = _sortFirstAsc(colId);
      } else if (_sortAsc == _sortFirstAsc(colId)) {
        _sortAsc = !_sortAsc; // 同列：翻到另一方向（升↔降）
      } else {
        _sortCol = null; // 再点：恢复默认（拖拽加载序）
        _sortAsc = true;
      }
    });
  }

  /// 首次点击某列的默认方向：大小/时间这类数值列降序更常用，其余列升序。
  static bool _sortFirstAsc(String colId) => colId != 'size' && colId != 'time';

  /// PAK 类型显示切换。
  void _onShowPakChanged() {
    AppLogger.instance.ui(
      'PAK 显示切换',
      action: '点击',
      details: {'show': !_showPak},
    );
    setState(() => _showPak = !_showPak);
  }

  /// UE4SS 类型显示切换。
  void _onShowUe4ssChanged() {
    AppLogger.instance.ui(
      'UE4SS 显示切换',
      action: '点击',
      details: {'show': !_showUe4ss},
    );
    setState(() => _showUe4ss = !_showUe4ss);
  }

  /// 列配置变化（顺序/可见性/宽度）→ setState 实时刷新 UI；
  /// 防抖 300ms 写盘（常驻：拖宽/拖拽/菜单任何变化都持久化，重开不还原）。
  Timer? _columnConfigCommitTimer;
  void _onColumnConfigChanged(ColumnLayout cfg) {
    AppLogger.instance.ui('列表列配置', action: '修改');
    setState(() => _columnConfig = cfg);
    _columnConfigCommitTimer?.cancel();
    _columnConfigCommitTimer = Timer(const Duration(milliseconds: 300), () {
      widget.modService.saveConfigKey(
        'mod_table_columns',
        _columnConfig.toJson(),
      );
    });
  }

  /// 列配置提交（拖宽松手 / 菜单操作后）→ 持久化到 config.json。
  void _onColumnConfigCommitted() {
    widget.modService.saveConfigKey(
      'mod_table_columns',
      _columnConfig.toJson(),
    );
  }

  void _onTagsFilterChanged(Set<String> tags) {
    AppLogger.instance.ui(
      '模组标签筛选',
      action: '修改',
      details: {'tags': tags.toList()..sort()},
    );
    setState(() => _filterTags = tags);
  }

  /// 全选按钮 / 表头主勾选框：按「当前筛选显示的 mod」启用；全部已启用则禁用。
  void _onSelectAll() {
    final list = _filteredMods;
    if (list.isEmpty) return;
    final allEnabled = list.every((m) => m.enabled);
    AppLogger.instance.ui(
      '全选/全禁用',
      action: '点击',
      details: {'enabled': !allEnabled, 'mod_count': list.length},
    );
    widget.modService.setManyEnabled(list.map((m) => m.id), !allEnabled);
  }

  /// 反选：仅翻转「当前筛选显示的 mod」的启用态。
  void _onInvertSelection() {
    final list = _filteredMods;
    if (list.isEmpty) return;
    AppLogger.instance.ui(
      '反选模组',
      action: '点击',
      details: {'mod_count': list.length},
    );
    widget.modService.invertIds(list.map((m) => m.id));
  }

  /// 表头主勾选框三态：全部启用=勾选、部分启用=半选、全未启用=空。
  /// 随当前筛选显示列表实时计算；列表为空时不显示主勾选框。
  ({bool checked, bool partial, VoidCallback onTap})? get _masterSelectState {
    final list = _filteredMods;
    if (list.isEmpty) return null;
    final enabledCount = list.where((m) => m.enabled).length;
    return (
      checked: enabledCount == list.length,
      partial: enabledCount > 0 && enabledCount < list.length,
      onTap: _onSelectAll,
    );
  }

  // ===== ModCard 元数据回调 =====

  void _onModTagsChanged(String id, List<String> tags) {
    AppLogger.instance.ui(
      '编辑模组标签',
      action: '保存',
      details: {'mod_id': id, 'tags': tags},
    );
    widget.modService.updateModTags(id, tags);
  }

  void _onModNotesChanged(String id, String notes) {
    AppLogger.instance.ui(
      '编辑模组备注',
      action: '保存',
      details: {'mod_id': id, 'notes_length': notes.length},
    );
    widget.modService.updateModNotes(id, notes);
  }

  /// 单 PAK 启用/禁用 → setState 让 list 渲染新状态。
  void _onModToggle(String id) {
    widget.modService.toggleMod(id);
  }

  /// 拖拽重排加载顺序。
  void _onReorder(int oldIndex, int newIndex) {
    if (!_canDragReorder) return; // 搜索/标签/排序激活时仍不允许重排
    final visible = _filteredMods;
    final full = widget.modService.mods;
    if (visible.length == full.length) {
      // 无过滤：可见即全量，直接按索引重排。
      widget.modService.moveLoadOrder(oldIndex, newIndex);
      return;
    }
    // 类型（PAK/UE4SS）过滤下的重排：可见子集与全量相对顺序一致，
    // 把「可见索引」映射回全量加载序（先移除被拖项，再插到锚点前/末尾）。
    final dragged = visible[oldIndex];
    final fromFull = full.indexWhere((m) => m.id == dragged.id);
    final rest = List<ModEntry>.from(full)..removeAt(fromFull);
    final int toFull;
    if (newIndex >= visible.length) {
      toFull = rest.length; // 拖到可见末尾 → 全量末尾
    } else {
      final anchor = visible[newIndex];
      toFull = rest.indexWhere((m) => m.id == anchor.id);
    }
    widget.modService.moveLoadOrder(fromFull, toFull);
  }

  void _onModDelete(String id) {
    AppLogger.instance.ui('删除模组', action: '点击', details: {'mod_id': id});
    widget.modService.removeMod(id);
    widget.modService.reindex();
  }

  /// 打开某个 mod 的设置悬浮窗（标签/备注编辑）。
  void _onOpenSettings(String id) {
    AppLogger.instance.ui('打开模组编辑设置', action: '点击', details: {'mod_id': id});
    final mod = widget.modService.mods.firstWhere(
      (m) => m.id == id,
      orElse: () => throw StateError('mod not found: $id'),
    );
    // BuildContext 在 build() 里可用——这里通过 OverlayEntry 重建拿到。
    ModSettingsPopup.show(
      // overlay 直接用 Overlay.of(navigatorKey.currentContext)。
      // 用 navigatorKey 简化：避免 context 从子树往上传。
      // 这里简化为：依赖最近一次 build 时的 context。
      _settingsContext!,
      modName: mod.name,
      tags: mod.tags,
      notes: mod.notes,
      onSave: (newTags, newNotes) {
        widget.modService.updateModTags(id, newTags);
        widget.modService.updateModNotes(id, newNotes);
        // 不写 setState：ModService.notifyListeners 会触发 _onModServiceChanged 重建。
      },
    );
  }

  /// 缓存最近一次 build 的 BuildContext，给 popup.show 用。
  BuildContext? _settingsContext;

  // ===== 启动选项回调 =====

  void _onLaunchOptionsChanged(LaunchOptions opts) {
    setState(() => _launchOptions = opts);
  }

  // ===== init / dispose =====

  @override
  void initState() {
    super.initState();
    _dropFadeCtrl = AnimationController(vsync: this, duration: _dropFadeIn);
    _dropFadeCtrl.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          _dropPhase == _DropPhase.fadingOut) {
        if (mounted) {
          setState(() {
            _dropPhase = _DropPhase.hidden;
            _lastImported = const [];
          });
        }
      }
    });

    // 从 config.json 加载已保存的启动选项。
    _launchOptions = widget.modService.loadLaunchOptions();

    // 从 config.json 加载已保存的列表列配置（顺序/可见性/宽度）。
    _columnConfig = ColumnLayout.fromJson(
      widget.modService.loadConfigKey('mod_table_columns'),
      specs: localColumnSpecs,
    );

    WindowService.setOnDragEnter(_onDragEnter);
    WindowService.setOnDragLeave(_onDragLeave);
    WindowService.setOnDroppedFiles(_onDroppedFiles);

    // 监听 ModService 变化（ModService extends ChangeNotifier）。
    // 所有 mutator（toggleMod/removeMod/reorder/scan/refreshCloud/...）调
    // notifyListeners() 后触发这里 setState 重建——不用再在每个回调末尾手写。
    widget.modService.addListener(_onModServiceChanged);

    // 冲突扫描：绑定 ModService（变化自动重扫）+ 监听结果刷新冲突列与工具栏按钮。
    ConflictService.shared.attach(widget.modService);
    ConflictService.shared.addListener(_onConflictServiceChanged);

    // 冲突自动合并：监听冲突报告变化后台重建合并包，状态变化刷新 UI。
    MergeService.shared.attach(widget.modService);
    MergeService.shared.addListener(_onConflictServiceChanged);

    // C1：异步探测 Mica 能力，同步 AppSignals.micaEnabled 与 OS 真实支持度。
    // isDark 必须按当前主题传，否则 Mica 会渲染成系统默认（暗色）。
    // 注意：背景恒用 bgDark 不透明（见字段注释），这里只维持 C++ 侧系统级
    // 注册 + 让设置页 toggle 状态不被 OS 不支持误导。
    final initialIsDark = AppSignals.themeMode.value == ThemeMode.dark;
    // 优先用 config.json 里持久化的用户偏好（设置页 Mica toggle 写进去的）。
    // 如果 OS 不支持 Mica（Win10 / 老 Win11），enableMica 会返回 false，
    // 我们把 AppSignals 强制设回 false，避免 UI 显示"开"但实际没生效。
    final userPrefMica = widget.modService.micaEnabled;
    WindowService.enableMica(isDark: initialIsDark).then((enabled) {
      if (!mounted) return;
      final effective = userPrefMica && enabled;
      AppSignals.micaEnabled.value = effective;
      AppLogger.instance.ui(
        '系统级背景',
        action: 'Mica 探测',
        details: {
          'userPref': userPrefMica,
          'osSupported': enabled,
          'effective': effective,
          'isDark': initialIsDark,
        },
      );
    });

    // C1：监听主题切换，每次切主题都重调 enableMica 让 Mica 跟随。
    // Mica 颜色由 DWM 系统层控制，应用层切 themeMode 不会自动同步——
    // 必须主动重调。
    AppSignals.themeMode.addListener(_onThemeModeChanged);

    // 设置页 Mica toggle：用户主动翻开关，实时调 enableMica 翻 Mica 状态。
    // 注意：toggle 写盘在 Settings 那边做了，这里只关心实时翻 UI。
    AppSignals.micaEnabled.addListener(_onMicaEnabledChanged);

    // 3c：从 config.json 读取背景图路径，写入共享 notifier。
    final bgPath = _backgroundService.currentBackgroundPath;
    AppSignals.backgroundPath.value = bgPath;

    // 注册 App 退出推送回调：C++ 拦截 SC_CLOSE 后会调这个回调让我们安全清理。
    // 必须确保：游戏在跑 → 先 kill + 等进程退出 → 回收 PAK → confirmAppExit。
    LauncherService.setOnAppExitRequest(_onAppExitRequest);
  }

  /// 3c 背景图服务的单例（dart 端无 DI 框架，简单 static 实例）。
  static final BackgroundService _backgroundService = BackgroundService();

  /// 提供给 Settings 页等外部 widget 调用的服务实例入口。
  BackgroundService get backgroundService => _backgroundService;

  /// App 退出推送回调（C++ → Dart）。
  ///
  /// 触发时机：用户点窗口右上角 X → C++ 拦截 SC_CLOSE → MethodChannel
  /// 推送 `onAppExitRequest` → 本函数执行。
  ///
  /// 安全退出流程（v2.7+ 修复版）：
  /// 1. **installPushHandler 收到推送时已立即设 exitOverlayStep=initializing**，
  ///    遮罩在 GUI 上立刻显示（修复 #1：避免 GUI 冻结）。
  /// 2. 检测 isGameRunning + 设置 `exitOverlayHasKillGame`：
  ///    - true  → 走完整三步（killingGame → reclaimingEnv → exitingApp）
  ///    - false → 走简化路径（直接 exitingApp，不显示 kill/reclaim 步骤）
  /// 3. **关键**：在跑时用 waitKillDone(60s) 真正等 C++ worker 走完整个
  ///    kill 流程（WM_CLOSE + 5s 等待 + TerminateProcess 兜底），
  ///    旧版用 isGameRunning 轮询 10s 兜底，SCUM 真实退出需 10-30s
  ///    （save world + telemetry upload），10s 超时后 GUI 早退但游戏还在跑。
  /// 4. reclaim 清场（幂等，游戏不在跑也安全）。
  /// 5. 调 `LauncherService.confirmAppExit()` 让 C++ DestroyWindow。
  ///
  /// 注意：Widget 可能已经 dispose（如 HomeScreen 在某个分支被替换），所以
  /// 不要访问 widget.build context（mount 检查无意义）。直接走
  /// widget.modService / LauncherService / AppSignals 这些静态/字段引用即可。
  Future<void> _onAppExitRequest() async {
    AppLogger.instance.ui('App 退出推送回调', action: 'C++→Dart');
    final svc = widget.modService;

    try {
      // 1) 检测游戏是否在跑 —— 决定是否走完整三步（修复 #2）。
      bool wasRunning = false;
      try {
        wasRunning = await LauncherService.isGameRunning();
      } catch (e) {
        AppLogger.instance.warning('退出时检查 isGameRunning 失败', {
          'error': e.toString(),
        });
      }

      // 2) 通知 ExitOverlay 是否要走完整三步（hasKillGame）。
      //    这一步是 GUI 决定显示完整版还是简化版的关键。
      AppSignals.exitOverlayHasKillGame.value = wasRunning;

      // 3) 如果游戏在跑，走完整 kill 流程。
      if (wasRunning) {
        AppSignals.exitOverlayStep.value = ExitOverlayStep.killingGame;
        AppLogger.instance.info('退出时发现游戏在跑，先 kill + 真正等完成');
        try {
          await LauncherService.killGame();
        } catch (e) {
          AppLogger.instance.error('退出时 killGame 失败', {'error': e.toString()});
        }
        // **关键**：真正等 worker 走完整个 kill 流程（WM_CLOSE → 5s grace
        // → TerminateProcess 兜底）。最多 60s（应付 SCUM 长时间保存）。
        final done = await LauncherService.waitKillDone(timeoutMs: 60000);
        AppLogger.instance.info('退出时 waitKillDone', {'done': done});
        // 防御兜底：即使 waitKillDone 超时，再 isGameRunning 一次确认进程
        // 是否真的死了。如果还活着，再走一次 killGame（worker in_flight=false
        // 此时允许重启）。
        if (!done) {
          try {
            final stillRunning = await LauncherService.isGameRunning();
            if (stillRunning) {
              AppLogger.instance.warning('waitKillDone 超时但进程仍活，再次 kill');
              await LauncherService.killGame();
              await LauncherService.waitKillDone(timeoutMs: 10000);
            }
          } catch (_) {}
        }
      } else {
        // 游戏不在跑 —— 跳过 kill，但**仍执行 reclaim 确保 UE4SS 框架清理**。
        // 旧版直接跳过 reclaim 导致：游戏退出后用户立即关闭管理器，此时
        // RightDock._startExitPolling 的 1.5s 延迟 reclaim 尚未触发，程序
        // 就退出了，dwmapi.dll + ue4ss/ 留在游戏目录。
        // reclaim 是幂等的，已清理情况下瞬间完成。
        AppLogger.instance.info('退出时游戏不在跑，但仍执行 reclaim 清理 UE4SS 残留');
      }

      // 4) 无论游戏是否在跑，都执行 reclaim 清场（确保 UE4SS 框架/mod 被清理）。
      AppSignals.exitOverlayStep.value = ExitOverlayStep.reclaimingEnv;
      AppLogger.instance.info('退出时 reclaim 清场');
      try {
        await svc.reclaimMods();
        AppLogger.instance.info('退出 reclaim 完成');
      } catch (e) {
        AppLogger.instance.error('退出 reclaim 失败', {'error': e.toString()});
      }

      // 5) 推进到 exitingApp —— 短暂停留让用户看清（避免一闪而过）。
      AppSignals.exitOverlayStep.value = ExitOverlayStep.exitingApp;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (e, st) {
      AppLogger.instance.error('退出流程异常', {
        'error': e.toString(),
        'stack': st.toString().split('\n').take(3).join(' | '),
      });
    } finally {
      // 6) 不管前面有什么异常，最后都必须调 confirmAppExit 让 C++ 销毁窗口，
      // 否则进程永远不退出。确认前不需要再改 exitOverlayStep —— 进程即将
      // 销毁，遮罩会自然消失。
      AppLogger.instance.info('退出流程完成，通知 C++ DestroyWindow');
      try {
        await LauncherService.confirmAppExit();
      } catch (_) {
        // 已经兜底过 C++ 端会用 isMaximized 等路径绕过 → 但实际通道挂了进程
        // 自然也会退出，这里吞掉即可。
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _modScrollCtrl.dispose();
    WindowService.setOnDragEnter(null);
    WindowService.setOnDragLeave(null);
    WindowService.setOnDroppedFiles(null);
    widget.modService.removeListener(_onModServiceChanged);
    ConflictService.shared.removeListener(_onConflictServiceChanged);
    MergeService.shared.removeListener(_onConflictServiceChanged);
    MergeService.shared.detach();
    AppSignals.themeMode.removeListener(_onThemeModeChanged);
    AppSignals.micaEnabled.removeListener(_onMicaEnabledChanged);
    LauncherService.setOnAppExitRequest(null);
    _dropFadeCtrl.dispose();
    super.dispose();
  }

  /// ModService 通知回调 —— 触发本 widget 重建。
  void _onModServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 冲突扫描服务通知回调 —— 扫描开始/完成时刷新冲突列与工具栏按钮。
  void _onConflictServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 打开冲突详情面板（工具栏按钮触发，全局视角：显示全部冲突路径）。
  void _onOpenConflicts() {
    AppLogger.instance.ui('模组冲突扫描', action: '打开详情面板');
    ConflictPanel.show(
      _settingsContext!,
      conflictsOnly: _conflictsOnly,
      onToggleFilter: () {
        setState(() => _conflictsOnly = !_conflictsOnly);
      },
    );
  }

  /// 打开冲突详情面板（行内红色「冲突」徽章触发，聚焦该 mod）：
  /// 面板只列出与它冲突的路径与 mod，而非全局全部冲突列表。
  void _onOpenConflictsFor(String modId) {
    AppLogger.instance.ui(
      '模组冲突扫描',
      action: '打开详情面板（聚焦 mod）',
      details: {'mod_id': modId},
    );
    ConflictPanel.show(
      _settingsContext!,
      focusModId: modId,
      conflictsOnly: _conflictsOnly,
      onToggleFilter: () {
        setState(() => _conflictsOnly = !_conflictsOnly);
      },
    );
  }

  /// 主题切换回调 —— 重调 enableMica 让 DWM Mica 跟随应用主题。
  /// Mica 颜色由 DWM 系统层控制（DWMWA_USE_IMMERSIVE_DARK_MODE），
  /// 不重调的话切亮色后 Mica 仍渲染暗色。
  /// 背景当前恒不透明（见字段注释），此调用仅维持系统级属性同步。
  void _onThemeModeChanged() {
    final isDark = AppSignals.themeMode.value == ThemeMode.dark;
    WindowService.enableMica(isDark: isDark).then((enabled) {
      if (!mounted) return;
      AppLogger.instance.ui(
        '系统级背景',
        action: 'Mica 重调',
        details: {'enabled': enabled, 'isDark': isDark},
      );
    });
  }

  /// Mica toggle 翻动回调 —— 设置页 AppearanceTab 改了 micaEnabled。
  /// 这里只负责实时调 enableMica；写盘 Settings 那边已经做了。
  void _onMicaEnabledChanged() {
    final userWants = AppSignals.micaEnabled.value;
    final isDark = AppSignals.themeMode.value == ThemeMode.dark;
    WindowService.enableMica(isDark: isDark).then((osSupported) {
      if (!mounted) return;
      // 用户想开 + OS 真支持 → 翻 Mica；其他情况保持亚克力 fallback。
      // 背景恒不透明，此调用仅维持 C++ 侧系统级属性（见字段注释）。
      final effective = userWants && osSupported;
      AppLogger.instance.ui(
        '系统级背景',
        action: 'Mica 切换',
        details: {
          'userWants': userWants,
          'osSupported': osSupported,
          'effective': effective,
        },
      );
    });
  }

  // ===== Drag event callbacks (called on platform thread) =====

  /// 拖拽遮罩：窗口内容区全局显示（不限于模组 tab），按当前标签与
  /// 服务器镜像模式显示对应文案（导入模组 / 上传服务器 / 添加本地镜像）。
  Widget _buildDropOverlay() {
    if (_dropPhase == _DropPhase.hidden) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _dropFadeCtrl,
          builder: (context, child) {
            final t = _dropPhase == _DropPhase.fadingOut
                ? Curves.easeIn.transform(_dropFadeCtrl.value)
                : Curves.easeOut.transform(_dropFadeCtrl.value);
            return Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: ValueListenableBuilder<bool>(
                valueListenable: AppSignals.serverMirrorMode,
                builder: (context, mirrorMode, _) => DropZoneOverlay(
                  active: t > 0.05,
                  lastImported: _lastImported,
                  title: _dropOverlayTitle(mirrorMode),
                  icon: _dropOverlayIcon(mirrorMode),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 遮罩文案（按当前标签 + 镜像模式）。
  String _dropOverlayTitle(bool mirrorMode) {
    if (widget.selectedTab == 'server_mods') {
      return mirrorMode ? '松开以添加 .pak 到本地镜像' : '松开以上传 .pak 到服务器';
    }
    return '松开以导入 .pak / .ini';
  }

  /// 遮罩图标（按当前标签 + 镜像模式）。
  IconData _dropOverlayIcon(bool mirrorMode) {
    if (widget.selectedTab == 'server_mods') {
      return mirrorMode
          ? Icons.folder_copy_rounded
          : Icons.cloud_upload_rounded;
    }
    return Icons.file_download_rounded;
  }

  void _onDragEnter() {
    if (!mounted) return;
    AppLogger.instance.ui('拖入模组文件', action: '进入窗口');
    setState(() {
      _dropPhase = _DropPhase.fadingIn;
      _lastImported = const [];
    });
    _dropFadeCtrl.forward(from: 0.0);
  }

  void _onDragLeave() {
    if (!mounted) return;
    AppLogger.instance.ui('拖入模组文件', action: '离开窗口');
    if (_dropPhase == _DropPhase.fadingIn || _dropPhase == _DropPhase.holding) {
      setState(() => _dropPhase = _DropPhase.fadingOut);
      _dropFadeCtrl.reverse();
    }
  }

  Future<void> _onDroppedFiles(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;

    // 服务器面板 tab：拖入的文件改为上传到远程服务器（由 ServerModsPanel
    // 监听 AppSignals.serverUploadRequest 消费）。
    if (widget.selectedTab == 'server_mods') {
      AppSignals.serverUploadRequest.value = paths;
      return;
    }

    AppLogger.instance.ui(
      '拖入模组文件',
      action: '松开',
      details: {'count': paths.length, 'paths': paths},
    );

    setState(() {
      _dropPhase = _DropPhase.holding;
      _lastImported = paths;
    });

    final result = await _copyToLocalMods(paths);

    if (mounted) {
      setState(() {
        _lastImported = result.imported + result.ue4ssImported > 0
            ? paths.take(result.imported + result.ue4ssImported).toList()
            : const [];
      });
    }

    final beforeIds = widget.modService.mods.map((m) => m.id).toSet();
    await widget.modService.scanMods();

    // UE4SS mod 导入后立即同步 mods.txt（新 mod 默认启用 = Name : 1）。
    // 必须**在 scanMods 之后**——sync 读取的是 `_mods` 列表（已扫描填充的状态），
    // 否则 `_mods` 还是空，sync 时 ourNames 为空，写出来的 mods.txt 没新行。
    if (result.ue4ssImported > 0) {
      await widget.modService.syncUe4ssModsTxt();
    }

    final newMods = widget.modService.mods
        .where((m) => !beforeIds.contains(m.id))
        .toList();

    if (mounted && newMods.isNotEmpty) {
      setState(() {
        for (final m in newMods) {
          _pendingEntranceIds.add(m.id);
        }
      });
    }

    if (_dropHoldAfterImport > Duration.zero) {
      await Future.delayed(_dropHoldAfterImport);
    }
    if (!mounted) return;

    setState(() => _dropPhase = _DropPhase.fadingOut);
    _dropFadeCtrl.duration = _dropFadeOut;
    _dropFadeCtrl.reverse();
    _dropFadeCtrl.duration = _dropFadeIn;

    _showImportToast(result);

    if (newMods.isNotEmpty) {
      Future.delayed(_cardEntrance, () {
        if (!mounted) return;
        setState(() {
          for (final m in newMods) {
            _pendingEntranceIds.remove(m.id);
          }
        });
      });
    }
  }

  /// 把拖入/选择的源路径分发给 PAK / UE4SS zip / UE4SS 文件夹导入逻辑。
  ///
  /// 返回：(imported, skipped, ue4ssImported)。
  /// - imported: PAK 成功导入的数量；
  /// - skipped: 跳过（含冲突被丢弃、不合规、非 PAK 也不是 UE4SS 等）的总数；
  /// - ue4ssImported: UE4SS mod 成功导入的数量。
  Future<({int imported, int skipped, int ue4ssImported})> _copyToLocalMods(
    List<String> sourcePaths,
  ) async {
    final modsDir = widget.modService.localModsPath;
    if (modsDir.isEmpty)
      return (imported: 0, skipped: sourcePaths.length, ue4ssImported: 0);

    int imported = 0;
    int skipped = 0;
    int ue4ssImported = 0;

    // 分两类：pakSourcePaths = .pak 候选； ue4ssSourcePaths = zip / 文件夹候选。
    final pakSourcePaths = <String>[];
    final ue4ssSourcePaths = <String>[];
    for (final src in sourcePaths) {
      final lname = p.basename(src).toLowerCase();
      final entity = FileSystemEntity.typeSync(src);
      if (lname.endsWith('.pak') && entity == FileSystemEntityType.file) {
        pakSourcePaths.add(src);
        continue;
      }
      if (lname.endsWith('.zip') && entity == FileSystemEntityType.file) {
        // zip：探测是不是 UE4SS mod（不解压）。
        if (Ue4ssService.probe(src) == Ue4ssProbe.valid) {
          ue4ssSourcePaths.add(src);
          continue;
        }
        AppLogger.instance.warning('导入跳过：zip 不是 UE4SS mod', {'source': src});
        skipped++;
        continue;
      }
      if (entity == FileSystemEntityType.directory) {
        // 文件夹：探测是不是 UE4SS mod 目录。
        if (Ue4ssService.probe(src) == Ue4ssProbe.valid) {
          ue4ssSourcePaths.add(src);
          continue;
        }
        AppLogger.instance.warning('导入跳过：文件夹不是 UE4SS mod', {'source': src});
        skipped++;
        continue;
      }
      AppLogger.instance.warning('导入跳过：文件类型不支持', {'source': src});
      skipped++;
    }

    // ── PAK 导入（带冲突对话框）──
    if (pakSourcePaths.isNotEmpty) {
      final result = await _importPakFiles(pakSourcePaths, modsDir);
      imported += result.imported;
      skipped += result.skipped;
    }

    // ── UE4SS mod 导入（带冲突对话框，与 PAK 路径一致）──
    if (ue4ssSourcePaths.isNotEmpty) {
      final result = await _importUe4ssFiles(ue4ssSourcePaths);
      ue4ssImported += result.ue4ssImported;
      skipped += result.skipped;
    }

    return (imported: imported, skipped: skipped, ue4ssImported: ue4ssImported);
  }

  /// UE4SS mod 文件导入：先批量复制无冲突项 → 弹对话框处理冲突 → 每次点按钮
  /// 立即处理该项（解压 zip / 覆盖文件夹 / 跳过）。
  ///
  /// 返回：(ue4ssImported, skipped)。
  Future<({int ue4ssImported, int skipped})> _importUe4ssFiles(
    List<String> sources,
  ) async {
    int ue4ssImported = 0;
    int skipped = 0;
    final localRoot = widget.modService.localUe4ssRoot;

    // 阶段 1：分类——已存在（冲突）/ 不存在（新）
    final conflicts = <OverwriteItem>[];
    final fresh = <String>[];
    for (final src in sources) {
      final lname = p.basename(src).toLowerCase();
      final isZip = lname.endsWith('.zip');
      final modName = isZip
          ? lname.substring(0, lname.length - 4)
          : p.basename(src);
      final dest = p.join(localRoot, modName);

      // 源大小
      final sourceSize = isZip
          ? await File(src).length()
          : _ue4ssFolderSize(src);
      // 目标大小（不存在 = 0）
      final destSize = Directory(dest).existsSync()
          ? _ue4ssFolderSize(dest)
          : 0;

      if (Directory(dest).existsSync()) {
        conflicts.add(
          OverwriteItem(
            sourcePath: src,
            destPath: dest,
            fileName: modName,
            destSize: destSize,
            sourceSize: sourceSize,
            kind: isZip ? 'ue4ss_zip' : 'ue4ss_folder',
          ),
        );
      } else {
        fresh.add(src);
      }
    }

    // 阶段 2：直接导入 fresh 项（不等 dialog）
    for (final src in fresh) {
      final isZip = p.basename(src).toLowerCase().endsWith('.zip');
      try {
        if (isZip) {
          final extracted = await _importUe4ssFromZip(src);
          if (extracted != null) ue4ssImported++;
        } else {
          final ok = await _importUe4ssFromFolder(src);
          if (ok) ue4ssImported++;
        }
      } catch (e) {
        AppLogger.instance.error('UE4SS mod 导入失败', {
          'source': src,
          'error': e.toString(),
        });
        skipped++;
      }
    }

    // 阶段 3：有冲突 → 弹 dialog，每点一项立即处理
    if (conflicts.isNotEmpty) {
      await _resolveUe4ssConflicts(
        conflicts: conflicts,
        onImported: () => ue4ssImported++,
        onSkipped: () => skipped++,
      );
    }

    return (ue4ssImported: ue4ssImported, skipped: skipped);
  }

  /// 弹 OverwriteDialog 处理 UE4SS 冲突；每次点按钮立即处理该源。
  Future<void> _resolveUe4ssConflicts({
    required List<OverwriteItem> conflicts,
    required void Function() onImported,
    required void Function() onSkipped,
  }) async {
    final completer = Completer<void>();
    OverwriteDialog.show(
      _settingsContext!,
      items: conflicts,
      onItemResolved: (sourcePath, overwrite) async {
        final ok = await _resolveSingleUe4ssConflict(
          sourcePath: sourcePath,
          overwrite: overwrite,
        );
        if (ok) {
          onImported();
        } else {
          onSkipped();
        }
        OverwriteDialog.markItemResolved(sourcePath, overwrite);
      },
      onAllDone: (overwritePaths, skipPaths) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future;
  }

  /// 处理单个 UE4SS 冲突（覆盖 / 跳过）。
  Future<bool> _resolveSingleUe4ssConflict({
    required String sourcePath,
    required bool overwrite,
  }) async {
    final isZip = p.basename(sourcePath).toLowerCase().endsWith('.zip');
    if (!overwrite) {
      AppLogger.instance.info('UE4SS 跳过（用户选择）', {'source': sourcePath});
      return false;
    }
    try {
      if (isZip) {
        final extracted = await _importUe4ssFromZip(sourcePath, force: true);
        return extracted != null;
      } else {
        final ok = await _importUe4ssFromFolder(sourcePath, force: true);
        return ok;
      }
    } catch (e) {
      AppLogger.instance.error('UE4SS 处理失败', {
        'source': sourcePath,
        'error': e.toString(),
      });
      return false;
    }
  }

  /// 计算 UE4SS mod 文件夹的总字节数（UI 显示用）。
  static int _ue4ssFolderSize(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// PAK 文件导入：先批量复制无冲突项 → 弹对话框处理冲突 → 每次点按钮
  /// 立即处理该项（覆盖 / 跳过）。
  ///
  /// 返回：(imported, skipped)。
  Future<({int imported, int skipped})> _importPakFiles(
    List<String> sources,
    String modsDir,
  ) async {
    int imported = 0;
    int skipped = 0;

    // 阶段 1：扫冲突 + 批量复制无冲突项
    final conflicts = <OverwriteItem>[];
    final nonConflicts = <String>[];
    for (final src in sources) {
      final file = File(src);
      if (!await file.exists()) {
        AppLogger.instance.warning('导入跳过：源文件不存在', {'source': src});
        skipped++;
        continue;
      }
      final name = p.basename(src);
      final dest = p.join(modsDir, name);
      if (await File(dest).exists()) {
        final srcSize = await file.length();
        final destSize = await File(dest).length();
        conflicts.add(
          OverwriteItem(
            sourcePath: src,
            destPath: dest,
            fileName: name,
            destSize: destSize,
            sourceSize: srcSize,
            kind: 'pak',
          ),
        );
      } else {
        nonConflicts.add(src);
      }
    }

    // 阶段 2：直接复制无冲突项（不等 dialog）
    for (final src in nonConflicts) {
      final ok = await _copySinglePak(src, modsDir);
      if (ok) {
        imported++;
      } else {
        skipped++;
      }
    }

    // 阶段 3：有冲突 → 弹 dialog，每点一项立即执行
    if (conflicts.isNotEmpty) {
      await _resolvePakConflicts(
        conflicts: conflicts,
        modsDir: modsDir,
        onImported: () => imported++,
        onSkipped: () => skipped++,
      );
    }

    return (imported: imported, skipped: skipped);
  }

  /// 复制单个 PAK 文件 → 目标。成功返回 true。
  Future<bool> _copySinglePak(String src, String modsDir) async {
    final name = p.basename(src);
    final dest = p.join(modsDir, name);
    try {
      await File(src).copy(dest);
      AppLogger.instance.info('导入模组文件', {
        'source': src,
        'destination': dest,
        'size': await File(dest).length(),
      });
      return true;
    } catch (e) {
      AppLogger.instance.error('导入模组文件失败', {
        'source': src,
        'destination': dest,
        'error': e.toString(),
      });
      return false;
    }
  }

  /// 弹 OverwriteDialog 处理 PAK 冲突；每次点按钮立即处理该源。
  ///
  /// [onImported] / [onSkipped] 在每项处理完后调用，让上层累计统计。
  Future<void> _resolvePakConflicts({
    required List<OverwriteItem> conflicts,
    required String modsDir,
    required void Function() onImported,
    required void Function() onSkipped,
  }) async {
    final completer = Completer<void>();
    OverwriteDialog.show(
      _settingsContext!,
      items: conflicts,
      onItemResolved: (sourcePath, overwrite) async {
        // 每次点按钮立即处理该源
        final ok = await _resolveSinglePakConflict(
          sourcePath: sourcePath,
          modsDir: modsDir,
          overwrite: overwrite,
        );
        if (ok) {
          onImported();
        } else {
          onSkipped();
        }
        // 通知 dialog 划掉该行（dialog 内部根据 _marked 自动判断）
        OverwriteDialog.markItemResolved(sourcePath, overwrite);
      },
      onAllDone: (overwritePaths, skipPaths) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future;
  }

  /// 处理单个 PAK 冲突（覆盖 / 跳过）。
  Future<bool> _resolveSinglePakConflict({
    required String sourcePath,
    required String modsDir,
    required bool overwrite,
  }) async {
    final name = p.basename(sourcePath);
    final dest = p.join(modsDir, name);
    if (!overwrite) {
      AppLogger.instance.info('PAK 跳过（用户选择）', {'source': sourcePath});
      return false;
    }
    // 覆盖：file.copy 在目标已存在时不会自动覆盖，所以先删目标
    try {
      final destFile = File(dest);
      if (await destFile.exists()) {
        await destFile.delete();
      }
      await File(sourcePath).copy(dest);
      AppLogger.instance.info('PAK 覆盖导入', {
        'source': sourcePath,
        'destination': dest,
      });
      return true;
    } catch (e) {
      AppLogger.instance.error('PAK 覆盖失败', {
        'source': sourcePath,
        'destination': dest,
        'error': e.toString(),
      });
      return false;
    }
  }

  /// 从 zip 解压 UE4SS mod。返回解压后的根目录绝对路径，失败返回 null。
  ///
  /// [force] = true → 目标目录已存在时**先删后解压**（覆盖用，由 OverwriteDialog
  ///   在用户确认"覆盖"后才传入 true）。默认 false（首次导入）。
  Future<String?> _importUe4ssFromZip(
    String zipPath, {
    bool force = false,
  }) async {
    final lname = p.basename(zipPath);
    // 用 zip 文件名（去后缀）当 mod 名；冲突时返回 null 让上层计为 skipped。
    final modName = lname.substring(0, lname.length - 4);
    final localRoot = widget.modService.localUe4ssRoot;
    final extracted = await Ue4ssService.extractZip(
      zipPath: zipPath,
      localRoot: localRoot,
      modName: modName,
      force: force,
    );
    if (extracted == null) {
      AppLogger.instance.warning('UE4SS zip 导入跳过：解压失败或目标已存在', {
        'source': zipPath,
        'mod_name': modName,
        'force': force,
      });
      return null;
    }
    AppLogger.instance.info('UE4SS mod 从 zip 解压成功', {
      'source': zipPath,
      'destination': extracted,
      'force': force,
    });
    return extracted;
  }

  /// 把已存在的 UE4SS mod 文件夹复制到本地 `ue4ss_runtime/ue4ss/Mods/<basename>/`。
  ///
  /// [force] = true → 目标目录已存在时**先清空后复制**（覆盖用）。
  /// 默认 false（首次导入，目标不存在时直接复制；目标已存在时返回 false 让上层计 skipped）。
  Future<bool> _importUe4ssFromFolder(
    String folderPath, {
    bool force = false,
  }) async {
    final folderName = p.basename(folderPath);
    final localRoot = widget.modService.localUe4ssRoot;
    final dest = Directory(p.join(localRoot, folderName));
    if (dest.existsSync() && !force) {
      AppLogger.instance.warning('UE4SS 文件夹导入跳过：目标已存在', {
        'source': folderPath,
        'destination': dest.path,
      });
      return false;
    }
    try {
      await Ue4ssService.deployToGame(
        sourceDir: folderPath,
        destDir: dest.path,
      );
      AppLogger.instance.info('UE4SS mod 从文件夹导入成功', {
        'source': folderPath,
        'destination': dest.path,
        'force': force,
      });
      return true;
    } catch (e) {
      AppLogger.instance.error('UE4SS 文件夹导入失败', {
        'source': folderPath,
        'error': e.toString(),
      });
      return false;
    }
  }

  void _showImportToast(
    ({int imported, int skipped, int ue4ssImported}) result,
  ) {
    final colors = ScumColors.of(context);
    final totalImported = result.imported + result.ue4ssImported;
    if (totalImported == 0 && result.skipped == 0) return;
    String msg;
    if (totalImported > 0 && result.skipped > 0) {
      final parts = <String>[];
      if (result.imported > 0) parts.add('${result.imported} PAK');
      if (result.ue4ssImported > 0) parts.add('${result.ue4ssImported} UE4SS');
      msg = '已导入 ${parts.join(" + ")}（跳过 ${result.skipped} 个）';
    } else if (totalImported > 0) {
      final parts = <String>[];
      if (result.imported > 0) parts.add('${result.imported} PAK');
      if (result.ue4ssImported > 0) parts.add('${result.ue4ssImported} UE4SS');
      msg = '已导入 ${parts.join(" + ")}';
    } else {
      msg = '跳过 ${result.skipped} 个文件（已存在或类型不支持）';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: totalImported > 0 ? colors.success : colors.textDim,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ===== Build =====

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    _settingsContext = context;
    final svc = widget.modService;

    Widget content;
    if (widget.selectedTab == 'settings') {
      content = SettingsScreen(
        modService: svc,
        onPathsChanged: widget.onPathsChanged,
      );
    } else if (widget.selectedTab == 'logs') {
      content = const LogScreen();
    } else if (widget.selectedTab == 'cloud_mods') {
      content = CloudModsPanel(
        modService: svc,
        onModsChanged: widget.onPathsChanged,
        sftpService: ServerSftpService.shared(svc),
      );
    } else if (widget.selectedTab == 'server_mods') {
      content = ServerModsPanel(
        modService: svc,
        sftpService: ServerSftpService.shared(svc),
      );
    } else {
      content = _ModsArea(
        svc: svc,
        pendingEntranceIds: _pendingEntranceIds,
        scrollController: _modScrollCtrl,
        // 工具栏参数
        searchCtrl: _searchCtrl,
        searchQuery: _searchQuery,
        filterTags: _filterTags,
        sortCol: _sortCol,
        sortAsc: _sortAsc,
        masterSelect: _masterSelectState,
        canDragReorder: _canDragReorder,
        hasFilter: _hasFilter,
        filteredMods: _filteredMods,
        showPak: _showPak,
        showUe4ss: _showUe4ss,
        onShowPakChanged: _onShowPakChanged,
        onShowUe4ssChanged: _onShowUe4ssChanged,
        columnConfig: _columnConfig,
        onColumnConfigChanged: _onColumnConfigChanged,
        onColumnConfigCommit: _onColumnConfigCommitted,
        onSearchChanged: _onSearchChanged,
        onHeaderSort: _onHeaderSort,
        onTagsChanged: _onTagsFilterChanged,
        onSelectAll: _onSelectAll,
        onInvertSelection: _onInvertSelection,
        onModTagsChanged: _onModTagsChanged,
        onModNotesChanged: _onModNotesChanged,
        onModToggle: _onModToggle,
        onModDelete: _onModDelete,
        onOpenSettings: _onOpenSettings,
        onReorder: _onReorder,
        // 冲突扫描参数
        conflictsOnly: _conflictsOnly,
        conflictScanning: ConflictService.shared.scanning,
        conflictUnavailable: ConflictService.shared.unavailable,
        conflictCount: ConflictService.shared.report?.totalConflictPaths ?? 0,
        conflictedModCount:
            ConflictService.shared.report?.conflictedModIds.length ?? 0,
        onConflictTap: _onOpenConflicts,
        onShowConflicts: _onOpenConflictsFor,
      );
    }

    // 不再用 ClipRRect 包外层 —— 原先的圆角兜底让内容四周出现 ~10px 内
    // 边距,与主人的方案(让内容真正铺满窗口)冲突。C++ DWM + Region 圆
    // 角已经处理了窗口外缘,这里只需让 Dart 内容铺满整个窗口客户区即可。
    //
    // Mica 透明策略（修复主人反馈："亮色下主内容区背景仍是黑色"）：
    // - 之前：探测到 Mica 时设 Colors.transparent，让 Mica 透桌面。
    // - 根因：Windows Mica 永远渲染成系统当前主题颜色（系统暗 = 暗 Mica），
    //   主人切亮色时 Mica 不翻 → 主内容区透出桌面背景（主人桌面是黑 = 黑）。
    // - 现在：永远用 colors.bgDark。亮色下 = #F5F5F5 浅灰白（跟标题栏/侧边栏
    //   一致）。失去 Mica 视觉效果（不再磨砂透桌面），但保证主题色正确。
    // - C++ 端 EnableMica 仍然调用（保留 Mica 系统级注册），Dart 端不再
    //   透明即可。c5f6a04 的 DWMWA_USE_IMMERSIVE_DARK_MODE 跟随逻辑保留，
    //   不影响其他走 Mica 的窗口（如果将来加上）。
    return Material(
      color: colors.bgDark,
      child: Stack(
        children: [
          // 3c：自定义背景图（如果有）。叠在 Column 之前、Mica 透明层之上。
          // 用 ValueListenableBuilder 监听 [AppSignals.backgroundPath]，
          // Settings 页改完后自动 rebuild 而不需要回调。
          ValueListenableBuilder<String?>(
            valueListenable: AppSignals.backgroundPath,
            builder: (_, path, _) => BackgroundImageLayer(imagePath: path),
          ),
          Column(
            children: [
              TitleBar(version: AppVersion.display),
              Expanded(
                child: Row(
                  children: [
                    Sidebar(
                      selected: widget.selectedTab,
                      onSelected: widget.onTabChanged,
                      onModsSelected: () => widget.onTabChanged('mods'),
                      onSettingsSelected: () => widget.onTabChanged('settings'),
                      onLogsSelected: () => widget.onTabChanged('logs'),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          content,
                          // 拖拽遮罩（按标签 + 服务器镜像模式显示语境文案）
                          _buildDropOverlay(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // ── 右下角浮层（启动按钮 + 齿轮） ──
          RightDock(
            modService: svc,
            launchOptions: _launchOptions,
            onLaunchOptionsChanged: _onLaunchOptionsChanged,
          ),
        ],
      ),
    );
  }
}

/// 模组管理主区域：工具栏 + mod 列表 + DropZoneOverlay。
class _ModsArea extends StatelessWidget {
  final ModService svc;
  final Set<String> pendingEntranceIds;

  /// mod 列表滚动控制器 —— 自绘 ScumScrollbar 用。
  final ScrollController scrollController;

  // 工具栏参数
  final TextEditingController searchCtrl;
  final String searchQuery;
  final Set<String> filterTags;
  final String? sortCol;
  final bool sortAsc;
  final ({bool checked, bool partial, VoidCallback onTap})? masterSelect;
  final bool canDragReorder;
  final bool hasFilter;
  final List<ModEntry> filteredMods;
  final bool showPak;
  final bool showUe4ss;
  final VoidCallback onShowPakChanged;
  final VoidCallback onShowUe4ssChanged;
  final ColumnLayout columnConfig;
  final ValueChanged<ColumnLayout> onColumnConfigChanged;
  final VoidCallback? onColumnConfigCommit;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onHeaderSort;
  final ValueChanged<Set<String>> onTagsChanged;
  final VoidCallback onSelectAll;
  final VoidCallback onInvertSelection;
  final void Function(String id, List<String> tags) onModTagsChanged;
  final void Function(String id, String notes) onModNotesChanged;
  final void Function(String id) onModToggle;
  final void Function(String id) onModDelete;
  final void Function(String id) onOpenSettings;
  final void Function(int oldIndex, int newIndex) onReorder;

  // ===== 冲突扫描参数 =====
  /// 「只看冲突 mod」筛选激活态。
  final bool conflictsOnly;

  /// 冲突扫描进行中。
  final bool conflictScanning;

  /// repak 不可用。
  final bool conflictUnavailable;

  /// 冲突路径总数。
  final int conflictCount;

  /// 参与冲突的 mod 数量。
  final int conflictedModCount;

  /// 打开冲突面板（工具栏按钮）。
  final VoidCallback onConflictTap;

  /// 行内红色「冲突」徽章点击（打开冲突面板，聚焦该 mod；带 mod id）。
  final ValueChanged<String> onShowConflicts;

  const _ModsArea({
    required this.svc,
    required this.pendingEntranceIds,
    required this.scrollController,
    required this.searchCtrl,
    required this.searchQuery,
    required this.filterTags,
    this.sortCol,
    this.sortAsc = true,
    this.masterSelect,
    required this.canDragReorder,
    required this.hasFilter,
    required this.filteredMods,
    required this.showPak,
    required this.showUe4ss,
    required this.onShowPakChanged,
    required this.onShowUe4ssChanged,
    required this.columnConfig,
    required this.onColumnConfigChanged,
    this.onColumnConfigCommit,
    required this.onSearchChanged,
    required this.onHeaderSort,
    required this.onTagsChanged,
    required this.onSelectAll,
    required this.onInvertSelection,
    required this.onModTagsChanged,
    required this.onModNotesChanged,
    required this.onModToggle,
    required this.onModDelete,
    required this.onOpenSettings,
    required this.onReorder,
    required this.conflictsOnly,
    required this.conflictScanning,
    required this.conflictUnavailable,
    required this.conflictCount,
    required this.conflictedModCount,
    required this.onConflictTap,
    required this.onShowConflicts,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Column(
      children: [
        // ── 工具栏（搜索 / PAK / UE4SS / 标签 / 全选反选；排序已移到表头点击）──
        ModListToolbar(
          searchController: searchCtrl,
          allTags: svc.allTags,
          selectedTags: filterTags,
          onSearchChanged: onSearchChanged,
          onTagsChanged: onTagsChanged,
          onSelectAll: onSelectAll,
          onInvertSelection: onInvertSelection,
          showPak: showPak,
          showUe4ss: showUe4ss,
          onShowPakChanged: onShowPakChanged,
          onShowUe4ssChanged: onShowUe4ssChanged,
          // 计数与全选/反选同样按「当前筛选显示的 mod」计算。
          modCount: filteredMods.length,
          enabledCount: filteredMods.where((m) => m.enabled).length,
          // 冲突扫描状态与按钮
          conflictCount: conflictCount,
          conflictedModCount: conflictedModCount,
          conflictScanning: conflictScanning,
          conflictUnavailable: conflictUnavailable,
          conflictsOnly: conflictsOnly,
          onConflictTap: onConflictTap,
        ),

        // ── 可配置列表头（点击排序 / 右键显隐 / 拖拽排序 / 右缘拖宽）──
        // 表头左侧主勾选框 = 全选当前显示的 mod（再点全部取消）。
        // 空列表时不显示表头。
        if (svc.mods.isNotEmpty)
          ModTableHeader(
            specs: localColumnSpecs,
            layout: columnConfig,
            onLayoutChanged: onColumnConfigChanged,
            onLayoutCommit: onColumnConfigCommit,
            sortColumnId: sortCol,
            sortAscending: sortAsc,
            onSort: onHeaderSort,
            masterSelect: masterSelect,
          ),

        // ── 列表 / 空提示 + DropZoneOverlay ──
        Expanded(
          child: Stack(
            children: [
              // Positioned.fill 让 _ModList/_EmptyHint 撑满父 Stack；
              // loose fit 下 ReorderableListView 会收缩到最小高度（"列表坏了"）。
              // 外层套 colors.bgDark 实色背景,避免 Mica 半透让主区背景与
              // TitleBar/Sidebar/Toolbar 的 bgDark 形成色块差异——主人原图:
              // "(0,0,0) 主列表区" vs "(13,13,13) 上方"是两个独立的"卡片"。
              Positioned.fill(
                child: Container(
                  // 半透明让自定义背景图透过
                  color: colors.bgDark.withValues(alpha: 0.82),
                  child: svc.mods.isEmpty
                      ? _EmptyHint(svc: svc)
                      : _ModList(
                          svc: svc,
                          pendingEntranceIds: pendingEntranceIds,
                          filteredMods: filteredMods,
                          canDragReorder: canDragReorder,
                          hasFilter: hasFilter,
                          columnConfig: columnConfig,
                          scrollController: scrollController,
                          onModTagsChanged: onModTagsChanged,
                          onModNotesChanged: onModNotesChanged,
                          onModToggle: onModToggle,
                          onModDelete: onModDelete,
                          onOpenSettings: onOpenSettings,
                          onShowConflicts: onShowConflicts,
                          onReorder: onReorder,
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Drop 状态机。
enum _DropPhase { hidden, fadingIn, holding, fadingOut }

// ===== 空状态 =====

class _EmptyHint extends StatelessWidget {
  final ModService svc;

  const _EmptyHint({required this.svc});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 56,
            color: colors.textDim.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '暂未发现任何 mod',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本地目录：${svc.localModsPath}',
            style: TextStyle(
              color: colors.textDim,
              fontSize: 11,
              fontFamily: 'Consolas',
              decoration: TextDecoration.none,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colors.bgPanel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: colors.textDim,
                ),
                SizedBox(width: 6),
                Text(
                  '拖拽 .pak 文件到窗口即可导入',
                  style: TextStyle(
                    color: colors.textDim,
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Mod 列表（带入场动画） =====

class _ModList extends StatelessWidget {
  final ModService svc;
  final Set<String> pendingEntranceIds;
  final List<ModEntry> filteredMods;
  final bool canDragReorder;
  final bool hasFilter;
  final ColumnLayout columnConfig;
  final ScrollController scrollController;
  final void Function(String id, List<String> tags) onModTagsChanged;
  final void Function(String id, String notes) onModNotesChanged;
  final void Function(String id) onModToggle;
  final void Function(String id) onModDelete;
  final void Function(String id) onOpenSettings;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 行内红色「冲突」徽章点击（打开冲突面板，聚焦该 mod；带 mod id）。
  final ValueChanged<String> onShowConflicts;

  const _ModList({
    required this.svc,
    required this.pendingEntranceIds,
    required this.filteredMods,
    required this.canDragReorder,
    required this.hasFilter,
    required this.columnConfig,
    required this.scrollController,
    required this.onModTagsChanged,
    required this.onModNotesChanged,
    required this.onModToggle,
    required this.onModDelete,
    required this.onOpenSettings,
    required this.onShowConflicts,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final list = hasFilter ? filteredMods : svc.mods;

    // 搜索 / 标签 / 排序激活时不拖拽重排，用普通列表；
    // 仅 PAK/UE4SS 类型显示开关或全量时用可拖拽列表（索引按可见子集映射回全量）。
    final body = !canDragReorder
        ? ListView.builder(
            key: const ValueKey('mods-sorted-list'),
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 140),
            itemCount: list.length,
            itemBuilder: (context, index) => _buildCard(list[index], index),
          )
        : ReorderableListView.builder(
            key: const ValueKey('mods-reorder-list'),
            scrollController: scrollController,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 140),
            itemCount: list.length,
            buildDefaultDragHandles:
                false, // ModCard 已自带 ReorderableDragStartListener
            onReorder: (oldIndex, newIndex) {
              // ReorderableListView 对被拖拽项越过自身位置的索引调整
              if (oldIndex < newIndex) newIndex -= 1;
              onReorder(oldIndex, newIndex);
            },
            itemBuilder: (context, index) => _buildCard(list[index], index),
            proxyDecorator: (child, index, animation) => AnimatedBuilder(
              animation: animation,
              builder: (context, child) => Material(
                color: Colors.transparent,
                elevation: 4,
                child: child,
              ),
              child: child,
            ),
          );

    // 统一自绘滚动条（原生滚动条已由全局 ScrollBehavior 禁用）
    return ScumScrollbar(controller: scrollController, child: body);
  }

  Widget _buildCard(ModEntry mod, int listIndex) {
    final isNew = pendingEntranceIds.contains(mod.id);
    Widget card = ModTableRow(
      key: ValueKey(mod.id),
      index: listIndex,
      mod: mod,
      layout: columnConfig,
      fromRemote: mod.isCloudMod,
      svc: svc,
      onToggle: () => onModToggle(mod.id),
      onDelete: () => onModDelete(mod.id),
      onOpenSettings: () => onOpenSettings(mod.id),
      onShowConflicts: onShowConflicts,
    );

    if (isNew) {
      card = AnimatedSlide(
        offset: const Offset(0, 0.08),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          opacity: 1.0,
          child: card,
        ),
      );
    }
    return Padding(
      key: ValueKey(mod.id),
      padding: const EdgeInsets.only(bottom: 4),
      child: card,
    );
  }
}
