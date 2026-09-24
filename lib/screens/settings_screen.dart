import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/app_signals.dart';
import '../services/background_service.dart';
import '../services/mod_service.dart';
import '../services/server_sftp_service.dart';
import '../services/window_service.dart';
import '../models/sftp_account.dart';
import '../theme/scum_colors.dart';

/// 设置页 —— Tab 化分组（路径 / 外观 / 服务器），避免单页内容堆叠过密。
///
/// 数据流：
/// - Tab 1 路径：调 [ModService.saveConfig] + [ModService.setPaths] + scanMods
///   （路径改了必须重新扫盘，所以保留显式"保存"按钮）
/// - Tab 2 外观：Mica toggle 即时调 [WindowService.enableMica] + 写
///   `config.json.mica_enabled`；背景图选择即时写 [BackgroundService]。
///   改动即时生效，不需要显式保存按钮。
/// - Tab 3 服务器：SFTP 连接配置（主机/端口/用户名/密码/远端 ~mods 路径），
///   存入 `config.json`（`sftp_*` 键）。支持"测试连接"与"自动定位 ~mods"。
class SettingsScreen extends StatefulWidget {
  final ModService modService;
  final VoidCallback? onPathsChanged;

  const SettingsScreen({
    super.key,
    required this.modService,
    this.onPathsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _scumPathCtrl;
  late TextEditingController _serverPathCtrl;

  // ── 服务器（SFTP）Tab 控制器 ──
  late TextEditingController _sftpHostCtrl;
  late TextEditingController _sftpPortCtrl;
  late TextEditingController _sftpUserCtrl;
  late TextEditingController _sftpPassCtrl;
  late TextEditingController _sftpPathCtrl;

  /// 服务器 Tab 的\"测试连接\"状态提示（成功/失败详情），空 = 无提示。
  String _sftpStatus = '';

  // 衍生路径预览（不可编辑，仅展示）。
  late String _scumExePreview;
  late String _scumModPreview;
  late String _serverExePreview;
  late String _serverModPreview;
  late String _localModsPreview;

  // Tab 状态：'paths'（路径配置）/ 'appearance'（外观：Mica + 背景图）/ 'server'（SFTP 服务器）。
  String _selectedTab = 'paths';

  // 外观 Tab 状态：当前已选背景图文件名 / Mica toggle 状态。
  String? _bgFileName;
  late bool _micaEnabled;
  final BackgroundService _bgService = BackgroundService();

  // 上次保存时两个路径的 snapshot —— 用来判定"有未保存改动"。
  // dirty = 当前两个 TextEditingController 的文本 ≠ 这两个 snapshot。
  late String _lastSavedScumPath;
  late String _lastSavedServerPath;

  /// 有未保存改动（路径 Tab 唯一会 dirty，外观 Tab 即时生效不算 dirty）。
  bool get _dirty =>
      _scumPathCtrl.text.trim() != _lastSavedScumPath ||
      _serverPathCtrl.text.trim() != _lastSavedServerPath;

  @override
  void initState() {
    super.initState();
    final svc = widget.modService;
    final config = svc.loadConfig();
    _scumPathCtrl = TextEditingController(
      text: config['scum_install_path'] ?? svc.scumInstallPath,
    );
    _serverPathCtrl = TextEditingController(
      text: config['server_install_path'] ?? svc.serverInstallPath,
    );
    // 服务器（SFTP）配置从 config.json 读取（sftp_* 键）。
    final sftp = svc.loadSftpConfig();
    _sftpHostCtrl = TextEditingController(text: sftp['sftp_host'] ?? '');
    _sftpPortCtrl = TextEditingController(text: sftp['sftp_port'] ?? '22');
    _sftpUserCtrl = TextEditingController(text: sftp['sftp_username'] ?? '');
    _sftpPassCtrl = TextEditingController(text: sftp['sftp_password'] ?? '');
    _sftpPathCtrl = TextEditingController(text: sftp['sftp_mods_path'] ?? '');
    // 初始 snapshot = 当前文本（刚加载完没改动）。注意：trim 后存，
    // 跟 _dirty 比较时也 trim，保证"全空格"不算改动。
    _lastSavedScumPath = _scumPathCtrl.text.trim();
    _lastSavedServerPath = _serverPathCtrl.text.trim();
    _refreshDerivedPaths();
    // 3c：从 BackgroundService 读取当前背景图路径（用于显示文件名）。
    final bgPath = _bgService.currentBackgroundPath;
    if (bgPath != null) {
      _bgFileName = bgPath.split(RegExp(r'[\\/]')).last;
    }
    // Mica 状态从 config.json 读（设置页自己的真相源）；UI 显示状态用
    // AppSignals（home_screen 那边会异步探测 OS 是否真支持 Mica）。
    _micaEnabled = svc.micaEnabled;
    AppSignals.micaEnabled.value = _micaEnabled;
  }

  @override
  void dispose() {
    _scumPathCtrl.dispose();
    _serverPathCtrl.dispose();
    _sftpHostCtrl.dispose();
    _sftpPortCtrl.dispose();
    _sftpUserCtrl.dispose();
    _sftpPassCtrl.dispose();
    _sftpPathCtrl.dispose();
    super.dispose();
  }

  /// 从当前 `_scumPathCtrl`/`_serverPathCtrl` 文本重新计算衍生路径 + 写入本地 ModService。
  void _refreshDerivedPaths() {
    final svc = widget.modService;
    // 临时 setPaths 以派生路径——不调 scanMods，避免在编辑时频繁扫描。
    // 注：setPaths 会 notifyListeners → home_screen 重建。**这里只是预览**，
    // 没保存的中间态不应触发 home 的 mod 列表重扫。先把旧路径存下来，
    // 预览完后立即还原，避免污染 home_screen 看到的"当前路径"。
    final prevClient = svc.scumInstallPath;
    final prevServer = svc.serverInstallPath;
    svc.setPaths(
      scumInstallPath: _scumPathCtrl.text.trim(),
      serverInstallPath: _serverPathCtrl.text.trim(),
    );
    setState(() {
      _scumExePreview = svc.scumExePath ?? '(待配置)';
      _scumModPreview = svc.clientModsPath.isEmpty
          ? '(待配置)'
          : svc.clientModsPath;
      _serverExePreview = svc.serverExePath ?? '(待配置)';
      _serverModPreview = svc.serverModsPath.isEmpty
          ? '(待配置)'
          : svc.serverModsPath;
      _localModsPreview = svc.localModsPath;
    });
    // 还原成之前的"已保存"值，避免 home_screen 把当前未保存的输入
    // 当成真实路径（启动按钮的可用性、mod 列表等都会受影响）。
    svc.setPaths(scumInstallPath: prevClient, serverInstallPath: prevServer);
  }

  void _autoDetectScum() async {
    final colors = ScumColors.of(context);
    AppLogger.instance.ui('自动检测客户端路径', action: '点击');
    final path = widget.modService.autoDetectScumPath();
    if (!mounted) return;
    if (path != null) {
      _scumPathCtrl.text = path;
      _refreshDerivedPaths();
      _showSnack('已自动检测到 SCUM 安装路径', colors.success);
    } else {
      _showSnack('未检测到 SCUM 安装路径，请手动输入', colors.danger);
    }
  }

  Future<void> _autoDetectServer() async {
    final colors = ScumColors.of(context);
    AppLogger.instance.ui('自动检测服务端路径', action: '点击');
    final path = widget.modService.autoDetectServerPath();
    if (!mounted) return;
    if (path != null) {
      _serverPathCtrl.text = path;
      _refreshDerivedPaths();
      _showSnack('已自动检测到服务端安装路径', colors.success);
    } else {
      _showSnack('未检测到服务端安装路径，请手动输入', colors.danger);
    }
  }

  // 3c：弹原生图片对话框选背景图。复制到 exe 旁 + 更新 config.json。
  Future<void> _pickBackground() async {
    final colors = ScumColors.of(context);
    AppLogger.instance.ui('自定义背景', action: '点击');
    final picked = await WindowService.openImageDialog();
    if (picked.isEmpty) return; // 用户取消
    final newPath = await _bgService.setBackground(picked.first);
    if (newPath == null) {
      _showSnack('背景图复制失败', colors.danger);
      return;
    }
    if (!mounted) return;
    setState(() {
      _bgFileName = newPath.split(RegExp(r'[\\/]')).last;
    });
    // 通知 home_screen 重建（背景图变了）——直接更新全局 notifier。
    AppSignals.backgroundPath.value = newPath;
    AppLogger.instance.info('背景图已设置', {'path': newPath});
    _showSnack('背景图已更新', colors.success);
  }

  // 3c：清除背景图（删除复制文件 + 清空 config 字段）。
  Future<void> _clearBackground() async {
    final colors = ScumColors.of(context);
    AppLogger.instance.ui('自定义背景', action: '清除');
    await _bgService.clearBackground();
    if (!mounted) return;
    setState(() => _bgFileName = null);
    AppSignals.backgroundPath.value = null;
    _showSnack('已清除背景图', colors.textSecondary);
  }

  // Mica toggle：写 config.json + 翻 AppSignals 让 home_screen 实时调 enableMica。
  void _toggleMica() {
    AppLogger.instance.ui('Mica 开关', action: '切换');
    final next = !_micaEnabled;
    setState(() => _micaEnabled = next);
    widget.modService.setMicaEnabled(next);
    AppSignals.micaEnabled.value = next;
    final colors = ScumColors.of(context);
    _showSnack(
      next ? '已开启 Mica（OS 不支持时自动回退到亚克力）' : '已关闭 Mica（回到纯色背景）',
      colors.textSecondary,
    );
  }

  Future<void> _save() async {
    final colors = ScumColors.of(context);
    AppLogger.instance.ui(
      '保存路径配置',
      action: '点击',
      details: {
        'client_path': _scumPathCtrl.text.trim(),
        'server_path': _serverPathCtrl.text.trim(),
      },
    );
    final svc = widget.modService;
    svc.saveConfig({
      'scum_install_path': _scumPathCtrl.text.trim(),
      'server_install_path': _serverPathCtrl.text.trim(),
    });
    svc.setPaths(
      scumInstallPath: _scumPathCtrl.text.trim(),
      serverInstallPath: _serverPathCtrl.text.trim(),
    );
    await svc.scanMods();
    AppLogger.instance.info('路径配置已保存并完成模组刷新', {'mod_count': svc.mods.length});
    // 归零 snapshot —— dirty 状态消失，Tab 上的"待保存"字样熄灭。
    setState(() {
      _lastSavedScumPath = _scumPathCtrl.text.trim();
      _lastSavedServerPath = _serverPathCtrl.text.trim();
    });
    widget.onPathsChanged?.call();
    _showSnack('已保存并刷新 mod 列表', colors.success);
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Tab 栏（自绘） ──
        _SettingsTabBar(
          selected: _selectedTab,
          onSelected: (key) => setState(() => _selectedTab = key),
          pathsDirty: _dirty,
          onSave: _save,
        ),

        // ── Tab 内容 ──
        // 滚动条铁律（3b+）：除 pak 列表 / 运行日志外，**禁止滚动条**。
        // 设置页内容定高，Expanded + Column 排版；超出屏高会溢出（与原 ListView
        // 行为不同），但 720+ 高度下足以容纳所有区块。
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: _buildTabContent(colors),
          ),
        ),
      ],
    );
  }

  /// Tab 内容分发（路径 / 外观 / 服务器）。
  Widget _buildTabContent(ScumColors colors) {
    switch (_selectedTab) {
      case 'server':
        return _buildServerTab(colors);
      case 'appearance':
        return _buildAppearanceTab(colors);
      case 'paths':
      default:
        return _buildPathsTab(colors);
    }
  }

  // ───────────────────── Tab 3：服务器（SFTP 连接） ─────────────────────

  /// 服务器 Tab：SFTP 连接配置（主机/端口/用户名/密码）+ 远端 ~mods 路径。
  ///
  /// 按钮：
  /// - 测试连接：用当前输入连一次（成功后保持连接，供"自动定位"复用）
  /// - 自动定位 ~mods：在已连接会话上探测远端 `SCUM/Content/Paks/~mods`
  /// - 保存配置：把当前输入写入 config.json（`sftp_*` 键）。
  Widget _buildServerTab(ScumColors colors) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(title: 'SFTP 服务器连接'),
          const SizedBox(height: 4),
          const _HelpText(
            text:
                '通过 SFTP 访问**你自己的 SCUM 服务器**：定位远端 ~mods 目录、'
                '给服务器上的 mod 添加备注、计算 SHA-256 做文件识别校验。'
                '密码仅保存在本机 config.json（明文，勿在多用户机器使用）。',
          ),
          const SizedBox(height: 12),

          // ── 连接信息 ──
          _ServerFieldRow(
            icon: Icons.dns_rounded,
            label: '主机',
            controller: _sftpHostCtrl,
            hint: '主机名/IP，或直接粘贴 sftp://用户名@主机:端口',
            onChanged: _onSftpHostChanged,
          ),
          const SizedBox(height: 8),
          _ServerFieldRow(
            icon: Icons.numbers_rounded,
            label: '端口',
            controller: _sftpPortCtrl,
            hint: 'SSH 端口，默认 22',
          ),
          const SizedBox(height: 8),
          _ServerFieldRow(
            icon: Icons.person_rounded,
            label: '用户名',
            controller: _sftpUserCtrl,
            hint: '服务器登录账号（如 root / steam）',
          ),
          const SizedBox(height: 8),
          _ServerFieldRow(
            icon: Icons.key_rounded,
            label: '密码',
            controller: _sftpPassCtrl,
            hint: '服务器登录密码',
            obscure: true,
          ),

          const SizedBox(height: 16),

          // ── 操作按钮行 ──
          Row(
            children: [
              _ServerMiniButton(
                label: '测试连接',
                icon: Icons.wifi_tethering_rounded,
                primary: false,
                onTap: _testSftpConnection,
              ),
              const SizedBox(width: 8),
              _ServerMiniButton(
                label: '自动定位 ~mods',
                icon: Icons.my_location_rounded,
                primary: true,
                onTap: _autoLocateSftpMods,
              ),
              const Spacer(),
              _ServerMiniButton(
                label: '保存配置',
                icon: Icons.save_rounded,
                primary: false,
                onTap: _saveSftpConfig,
              ),
            ],
          ),

          // ── 状态提示 ──
          if (_sftpStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.bgCard,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _sftpStatus,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontFamily: 'Consolas',
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),

          // ── 远端 ~mods 路径 ──
          const _SectionHeader(title: '远端 ~mods 目录'),
          const SizedBox(height: 4),
          const _HelpText(
            text:
                '留空时点击"自动定位"从常见安装路径探测；也可手填绝对路径'
                '（如 /home/steam/Steam/steamapps/common/SCUM Server/SCUM/Content/Paks/~mods）。',
          ),
          const SizedBox(height: 8),
          _ServerFieldRow(
            icon: Icons.folder_outlined,
            label: '路径',
            controller: _sftpPathCtrl,
            hint: '服务器上 ~mods 的绝对路径',
            fontMono: true,
          ),

          const SizedBox(height: 20),

          // ── 账户列表管理（多服务器快速切换） ──
          const _SectionHeader(title: '服务器账户列表'),
          const SizedBox(height: 4),
          const _HelpText(
            text:
                '把当前表单保存为一个账户（可保存多台服务器），之后在远程服务器面板'
                '顶部的切换按钮一键切换。sha-256 相同的 mod 会在多台服务器间互通识别。',
          ),
          const SizedBox(height: 8),
          // 保存当前表单为新账户（同名覆盖）
          Row(
            children: [
              _MiniButton(
                label: '保存为新账户',
                onTap: _saveAsSftpAccount,
                primary: true,
              ),
              const Spacer(),
              _MiniButton(
                label: '刷新账户列表',
                onTap: () => setState(() {}),
                primary: false,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 已保存账户列表
          if (widget.modService.loadSftpAccounts().isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.bgCard,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '暂无已保存账户 — 填写上方信息后点击「保存为新账户」',
                style: TextStyle(
                  color: colors.textDim,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
            )
          else
            ...widget.modService.loadSftpAccounts().map((acc) {
              final active =
                  acc.name == widget.modService.activeSftpAccount?.name;
              final isConnectedHere =
                  widget.modService.activeSftpAccount?.key == acc.key;
              return _SftpAccountRow(
                account: acc,
                active: active || isConnectedHere,
                onActivate: () {
                  widget.modService.setActiveSftpAccount(acc.name);
                  setState(() {});
                },
                onDelete: () {
                  widget.modService.removeSftpAccount(acc.name);
                  setState(() {});
                },
              );
            }),

          const SizedBox(height: 28),
        ],
      ),
    );
  }

  /// 把当前表单保存为新账户（同名覆盖；自动设为激活账户）。
  void _saveAsSftpAccount() {
    final host = _sftpHostCtrl.text.trim();
    if (host.isEmpty) {
      _showSnack('请先填写主机', ScumColors.of(context).danger);
      return;
    }
    var account = SftpAccount(
      name: host,
      host: host,
      port: int.tryParse(_sftpPortCtrl.text.trim()) ?? 22,
      username: _sftpUserCtrl.text.trim(),
      password: _sftpPassCtrl.text,
      modsPath: _sftpPathCtrl.text.trim(),
    );
    // 主机若为完整 URI，先解析拆分再存
    final parsed = ServerSftpService.parseSftpUri(host);
    if (parsed != null && parsed.host.isNotEmpty) {
      account = SftpAccount(
        name: parsed.username ?? host,
        host: parsed.host,
        port: parsed.port ?? 22,
        username: parsed.username ?? _sftpUserCtrl.text.trim(),
        password: parsed.password ?? _sftpPassCtrl.text,
        modsPath: _sftpPathCtrl.text.trim(),
      );
    }
    widget.modService.upsertSftpAccount(account);
    // 同步回填表单（解析后的干净值）
    setState(() {
      _sftpHostCtrl.text = account.host;
      _sftpPortCtrl.text = '${account.port}';
      _sftpUserCtrl.text = account.username;
      _sftpPathCtrl.text = account.modsPath;
    });
    _showSnack('账户已保存：${account.displayName}', ScumColors.of(context).success);
  }

  /// 主机框内容变化：若粘贴了完整 `sftp://用户名@主机:端口`，自动拆分回填。
  /// 无协议前缀的 `用户名@主机:端口` 同样识别。
  void _onSftpHostChanged(String text) {
    final parsed = ServerSftpService.parseSftpUri(text);
    if (parsed == null) return;
    // 只有当解析出真实主机名才回填（避免输入过程中半截字符串误写）。
    if (parsed.host.isEmpty) return;
    // 拆出的分量若与当前各框不一致才回填（不打扰用户手填的其他字段）。
    // 端口只有显式写在输入里才回填（parsed.port != null）；否则保留用户手填端口，
    // 绝不覆盖成默认值 —— 这正是"端口被固定成 22"的根因。
    final shouldUpdateHost = parsed.host != _sftpHostCtrl.text.trim();
    final shouldUpdatePort =
        parsed.port != null &&
        (_sftpPortCtrl.text.trim() != '${parsed.port}' ||
            int.tryParse(_sftpPortCtrl.text.trim()) == null);
    final shouldUpdateUser =
        parsed.username != null &&
        parsed.username!.isNotEmpty &&
        _sftpUserCtrl.text.trim() != parsed.username;
    final shouldUpdatePass =
        parsed.password != null &&
        parsed.password!.isNotEmpty &&
        _sftpPassCtrl.text.isEmpty;
    if (!shouldUpdateHost &&
        !shouldUpdatePort &&
        !shouldUpdateUser &&
        !shouldUpdatePass) {
      return;
    }
    setState(() {
      if (shouldUpdateHost) _sftpHostCtrl.text = parsed.host;
      if (shouldUpdatePort && parsed.port != null) {
        _sftpPortCtrl.text = '${parsed.port}';
      }
      if (shouldUpdateUser) _sftpUserCtrl.text = parsed.username!;
      if (shouldUpdatePass) _sftpPassCtrl.text = parsed.password!;
    });
    final displayPort = parsed.port?.toString() ?? '(沿用端口框)';
    _sftpStatus =
        '已解析：用户名 ${parsed.username ?? '(无)'} · 主机 ${parsed.host} · 端口 $displayPort';
    if (parsed.password != null && parsed.password!.isNotEmpty) {
      _sftpStatus += ' · 密码已从 URI 提取';
    }
  }

  Future<void> _testSftpConnection() async {
    final svc = ServerSftpService.shared(widget.modService);
    var host = _sftpHostCtrl.text.trim();
    var port = int.tryParse(_sftpPortCtrl.text.trim()) ?? 22;
    var username = _sftpUserCtrl.text.trim();
    var password = _sftpPassCtrl.text;
    // 兜底解析：即使 onChanged 未触发（例如代码直接改 controller.text），
    // 主机框若是完整 URI 也保证连接前已拆分。
    final parsed = ServerSftpService.parseSftpUri(host);
    if (parsed != null && parsed.host.isNotEmpty) {
      host = parsed.host;
      // 仅当输入显式带端口才覆盖（否则尊重端口框手填值，不强制 22）。
      // 注：Dart record 字段不参与类型提升，须先取本地变量再判空。
      final parsedPort = parsed.port;
      if (parsedPort != null) port = parsedPort;
      final parsedUser = parsed.username;
      if (parsedUser != null && parsedUser.isNotEmpty) {
        username = parsedUser;
      }
      final parsedPass = parsed.password;
      if (parsedPass != null && parsedPass.isNotEmpty) {
        password = parsedPass;
      }
    }
    setState(() => _sftpStatus = '正在连接 $host:$port …');
    final ok = await svc.connect(
      host: host,
      port: port,
      username: username,
      password: password,
    );
    if (!mounted) return;
    setState(() {
      _sftpStatus = ok
          ? '连接成功 ✓ 可点击"自动定位 ~mods"或手填路径'
          : '连接失败 ✗ 请检查主机/端口/账号/密码';
    });
    final colors = ScumColors.of(context);
    _showSnack(
      ok ? 'SFTP 连接成功' : 'SFTP 连接失败',
      ok ? colors.success : colors.danger,
    );
  }

  /// 自动定位远端 ~mods：先确保已连接，再探测路径并填入输入框。
  Future<void> _autoLocateSftpMods() async {
    final svc = ServerSftpService.shared(widget.modService);
    if (!svc.isConnected) {
      await _testSftpConnection();
      if (!mounted || !svc.isConnected) return;
    }
    final colors = ScumColors.of(context);
    final found = await svc.locateModsDir();
    if (!mounted) return;
    setState(() {
      _sftpPathCtrl.text = found ?? '';
      _sftpStatus = found != null ? '已定位: $found' : '未找到 ~mods，请手动填写路径';
    });
    _showSnack(
      found != null ? '已自动定位 ~mods' : '未找到 ~mods 目录',
      found != null ? colors.success : colors.danger,
    );
  }

  /// 保存 SFTP 配置到 config.json（主机框若为完整 URI，先解析拆分布再存）。
  void _saveSftpConfig() {
    var host = _sftpHostCtrl.text.trim();
    var portStr = _sftpPortCtrl.text.trim();
    var username = _sftpUserCtrl.text.trim();
    var password = _sftpPassCtrl.text;
    // 主机框粘贴完整 URI 时，自动拆分并回填各字段（config 存干净的拆分值）。
    final parsed = ServerSftpService.parseSftpUri(host);
    if (parsed != null && parsed.host.isNotEmpty) {
      host = parsed.host;
      // 仅当输入显式带端口才保存解析端口，否则保留端口框手填值。
      if (parsed.port != null) portStr = '${parsed.port}';
      if (parsed.username != null && parsed.username!.isNotEmpty) {
        username = parsed.username!;
      }
      if (parsed.password != null && parsed.password!.isNotEmpty) {
        password = parsed.password!;
      }
    }
    widget.modService.saveSftpConfig({
      'sftp_host': host,
      'sftp_port': portStr,
      'sftp_username': username,
      'sftp_password': password,
      'sftp_mods_path': _sftpPathCtrl.text.trim(),
    });
    final colors = ScumColors.of(context);
    _showSnack('SFTP 配置已保存', colors.success);
  }

  // ───────────────────────── Tab 1：路径 ─────────────────────────
  Widget _buildPathsTab(ScumColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── SCUM 客户端路径 ──
        const _SectionHeader(title: 'SCUM 客户端安装目录'),
        const SizedBox(height: 4),
        const _HelpText(
          text:
              '指向 Steam common 下的 SCUM 根目录（不是 SCUM.exe 所在目录）。'
              '可点击"自动检测"从注册表 + Steam 库搜索。',
        ),
        const SizedBox(height: 8),
        _PathRow(
          controller: _scumPathCtrl,
          hint: r'例如: X:\SteamLibrary\steamapps\common\SCUM',
          onAutoDetect: _autoDetectScum,
          onChanged: (_) => _refreshDerivedPaths(),
        ),

        const SizedBox(height: 16),
        _DerivedPathsCard(
          title: '衍生路径（自动计算）',
          rows: [('SCUM.exe', _scumExePreview), ('客户端 ~mods', _scumModPreview)],
        ),

        const SizedBox(height: 28),

        // ── SCUM 服务端路径 ──
        const _SectionHeader(title: 'SCUM 服务端安装目录'),
        const SizedBox(height: 4),
        const _HelpText(
          text:
              '服务端独立安装路径（"SCUM Server" 文件夹的父目录）。'
              '留空则启动按钮不显示服务端入口。',
        ),
        const SizedBox(height: 8),
        _PathRow(
          controller: _serverPathCtrl,
          hint:
              r'例如: X:\SCUM_Server 或 X:\SteamLibrary\steamapps\common\SCUM Server',
          onAutoDetect: _autoDetectServer,
          onChanged: (_) => _refreshDerivedPaths(),
        ),

        const SizedBox(height: 16),
        _DerivedPathsCard(
          title: '衍生路径（自动计算）',
          rows: [
            ('SCUMServer.exe', _serverExePreview),
            ('服务端 ~mods', _serverModPreview),
          ],
        ),

        const SizedBox(height: 28),

        // ── 本地 mods 目录（只读展示） ──
        const _SectionHeader(title: '本地 mods 目录（自动创建）'),
        const SizedBox(height: 4),
        const _HelpText(
          text:
              '与管理器 exe 同级的 ~mods/ 目录，用于存放从资源管理器拖入的 mod 文件。'
              '无法手动修改路径。',
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.bgCard,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_open_rounded, size: 16, color: colors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _localModsPreview,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    decoration: TextDecoration.none,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // 底部留点余量，避免贴边。保存按钮已经在 Tab 栏最右边了，
        // 路径 Tab 内容区不再重复。
        const SizedBox(height: 24),
      ],
    );
  }

  // ───────────────────────── Tab 2：外观 ─────────────────────────
  Widget _buildAppearanceTab(ScumColors colors) {
    return SingleChildScrollView(
      // 外观 Tab 内容较少，理论上不会溢出。但保留滚动兜底——
      // 主人以后加新外观项（启动参数？主题切换？）不至于撑爆布局。
      // 滚动条只在溢出时出现，符合滚动条铁律。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Mica / 亚克力 开关 ──
          const _SectionHeader(title: 'Mica / 亚克力背景'),
          const SizedBox(height: 4),
          const _HelpText(
            text:
                'Win11 22H2+ 启用 Mica（系统级磨砂透桌面），不支持时自动回退到亚克力（半透明黑）。'
                '切换即时生效，不需要保存。',
          ),
          const SizedBox(height: 8),
          _ToggleRow(
            icon: Icons.blur_on_rounded,
            label: '启用 Mica',
            value: _micaEnabled,
            onChanged: (_) => _toggleMica(),
          ),

          const SizedBox(height: 28),

          // ── 自定义背景图 ──
          const _SectionHeader(title: '自定义背景图'),
          const SizedBox(height: 4),
          const _HelpText(
            text:
                '选择一张图片作为窗口背景（仅本地副本，不上传任何数据）。'
                '切换到 mod 列表后即时可见。',
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.bgCard,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.image_rounded, size: 16, color: colors.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _bgFileName ?? '未选择（使用 Mica/亚克力默认背景）',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                      fontFamily: 'Consolas',
                      decoration: TextDecoration.none,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // 自绘按钮组（禁止 Material 原生控件）。
                _MiniButton(
                  label: '选择图片',
                  onTap: _pickBackground,
                  primary: true,
                ),
                if (_bgFileName != null) ...[
                  const SizedBox(width: 6),
                  _MiniButton(
                    label: '清除',
                    onTap: _clearBackground,
                    primary: false,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =====================================================================
//  Tab 栏 —— 自绘，accent 下划线 + hover 态
// =====================================================================

/// Tab 项的描述信息。
class _TabItem {
  final String key;
  final String label;
  final IconData icon;
  const _TabItem(this.key, this.label, this.icon);
}

/// 设置页顶部的 Tab 栏。走 accent 下划线 + hover 态，跟侧边栏的
/// 选区逻辑保持视觉一致（都是"主色高亮 + 浅描边"）。
///
/// 右上角贴一个保存按钮 —— 永远可见，dirty 时黄铜高亮，clean 时灰化禁用。
/// 这样切到外观 Tab 时按钮仍在那里（视觉一致），但点不动。
class _SettingsTabBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;

  /// 路径 Tab 是否有未保存改动 —— 控制"待保存"字样 + 保存按钮高亮。
  final bool pathsDirty;

  /// 保存按钮回调。
  final VoidCallback onSave;

  static const _tabs = <_TabItem>[
    _TabItem('paths', '路径', Icons.folder_rounded),
    _TabItem('appearance', '外观', Icons.palette_rounded),
    _TabItem('server', '服务器', Icons.dns_rounded),
  ];

  const _SettingsTabBar({
    required this.selected,
    required this.onSelected,
    required this.pathsDirty,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      decoration: BoxDecoration(
        // 半透明让自定义背景图透过
        color: colors.bgDark.withValues(alpha: 0.82),
        // Tab 栏下边一条分隔线，让"Tab 头部 / Tab 内容"在视觉上分层。
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          for (final t in _tabs) ...[
            _TabButton(
              item: t,
              selected: selected == t.key,
              pendingBadge: pathsDirty && t.key == 'paths',
              onTap: () => onSelected(t.key),
            ),
            const SizedBox(width: 4),
          ],
          // Spacer 把保存按钮推到 Tab 栏最右端 —— 主人原话：
          // "保存配置按钮应该要放到 tab 的最右边"
          const Spacer(),
          _SaveButton(onTap: onSave, enabled: pathsDirty),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// 单个 Tab 按钮：图标 + 文字 + 选中态的 accent 下划线。
///
/// [pendingBadge] = true 时，文字后面追加一个"待保存"小字（accent 色），
/// 让用户一眼看到哪个 Tab 有未提交改动。
class _TabButton extends StatefulWidget {
  final _TabItem item;
  final bool selected;
  final bool pendingBadge;
  final VoidCallback onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.pendingBadge,
    required this.onTap,
  });

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final selected = widget.selected;
    final pending = widget.pendingBadge;
    // 选中态：accent 文字 + accent 下划线；hover：背景浅 accent；
    // 默认：次级文字 + 透明背景。
    final textColor = selected
        ? colors.accent
        : (_hovered ? colors.textPrimary : colors.textSecondary);
    final bg = _hovered && !selected ? colors.bgHover : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.item.icon, size: 14, color: textColor),
                  const SizedBox(width: 8),
                  Text(
                    widget.item.label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 1.0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  // 待保存小字 —— 紧跟 Tab 标题后面，跟 Tab 选中态同色系（accent）
                  // 但小一号 + 加粗，让"亮起"感强。空 6px 间距避免贴太紧。
                  if (pending) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(alpha: 0.15),
                        border: Border.all(
                          color: colors.accent.withValues(alpha: 0.6),
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        '待保存',
                        style: TextStyle(
                          color: colors.accent,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // 选中下划线 —— 2px accent，非选中透明（保留高度避免抖动）。
              Container(
                height: 2,
                width: 36,
                decoration: BoxDecoration(
                  color: selected ? colors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== 共用小部件（路径 / 外观两个 Tab 都有可能用到） =====

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        color: colors.accent,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 2.0,
        decoration: TextDecoration.none,
      ),
    );
  }
}

class _HelpText extends StatelessWidget {
  final String text;
  const _HelpText({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Text(
      text,
      style: TextStyle(
        color: colors.textDim,
        fontSize: 11,
        height: 1.4,
        decoration: TextDecoration.none,
      ),
    );
  }
}

class _PathRow extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback onAutoDetect;
  final ValueChanged<String> onChanged;

  const _PathRow({
    required this.controller,
    required this.hint,
    required this.onAutoDetect,
    required this.onChanged,
  });

  @override
  State<_PathRow> createState() => _PathRowState();
}

class _PathRowState extends State<_PathRow> {
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

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final borderColor = _focused ? colors.borderAccent : colors.border;
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => _focusNode.requestFocus(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.bgCard,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: borderColor,
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.folder_outlined,
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
                        fontFamily: 'Consolas',
                        decoration: TextDecoration.none,
                      ),
                      cursorColor: colors.accent,
                      backgroundCursorColor: colors.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _AutoDetectButton(onTap: widget.onAutoDetect),
      ],
    );
  }
}

/// 自绘按钮 —— 无 Material 原生控件，自绘 hover 态。
class _AutoDetectButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AutoDetectButton({required this.onTap});

  @override
  State<_AutoDetectButton> createState() => _AutoDetectButtonState();
}

class _AutoDetectButtonState extends State<_AutoDetectButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final accent = colors.accent;
    final bg = _hovered ? accent.withValues(alpha: 0.20) : Colors.transparent;
    final border = _hovered ? accent : accent.withValues(alpha: 0.5);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                '自动检测',
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
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

/// 衍生路径展示卡片（只读）。
class _DerivedPathsCard extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _DerivedPathsCard({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      decoration: BoxDecoration(
        // 用 colors.bgPanel 直接渲染（去掉 alpha 0.5）—— 之前 bgCard α0.5
        // 叠加在 bgPanel 上：
        //   - 暗色下渲染为 #1E1E1E（接近黑色，主人截图里看着"还是黑的"）
        //   - 亮色下渲染为 #F6F6F6（看起来像没翻成白色）
        // 改用 bgPanel 后：
        //   - 暗色下 = #1A1A1A（背景层 + 边框清晰区分）
        //   - 亮色下 = #EEEEEE（明显浅灰，跟 bgCard #FFFFFF 形成层次）
        color: colors.bgPanel,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 8),
          ...rows.map((r) => _DerivedRow(label: r.$1, path: r.$2)),
        ],
      ),
    );
  }
}

class _DerivedRow extends StatelessWidget {
  final String label;
  final String path;
  const _DerivedRow({required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 11,
                fontFamily: 'Consolas',
                decoration: TextDecoration.none,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
//  3c 自定义背景图相关小部件
// =====================================================================

/// 自绘紧凑按钮（hover/按下态），用于背景图区块的"选择图片"/"清除"按钮。
/// 不用 Material 原生控件（保持项目"全自绘"约束）。
class _MiniButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  /// true → 黄铜底（主操作）；false → 灰描边（次操作）。
  final bool primary;

  const _MiniButton({
    required this.label,
    required this.onTap,
    required this.primary,
  });

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final bg = widget.primary
        ? (_hovered ? colors.accent.withValues(alpha: 0.85) : colors.accent)
        : (_hovered ? colors.bgHover : Colors.transparent);
    final fg = widget.primary ? colors.bgDark : colors.textSecondary;
    final border = widget.primary ? Colors.transparent : colors.border;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘保存按钮 —— 黄铜底色 + hover 加深 + 暗色文字。
/// 不用 Material 原生 ElevatedButton（保持项目"全自绘"约束）。
///
/// [enabled] = false 时灰化 + 禁用（鼠标 cursor 改 default，onTap 不触发）。
/// 主人原话："有变动是 tab 会亮起待保存的字样" —— 所以 dirty 时高亮、
/// 不 dirty 时灰化，两个状态视觉上对比明显。
class _SaveButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool enabled;
  const _SaveButton({required this.onTap, required this.enabled});

  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final enabled = widget.enabled;
    // 三态颜色：
    // - enabled + hover → accent 0.85
    // - enabled + idle   → accent 1.0
    // - disabled         → bgHover 灰（无 accent 味）
    final Color bg;
    if (!enabled) {
      bg = colors.bgHover;
    } else if (_hovered) {
      bg = colors.accent.withValues(alpha: 0.85);
    } else {
      bg = colors.accent;
    }
    // 文字 / 图标颜色：enabled = bgDark（暗色压黄铜），disabled = textDim。
    final fg = enabled ? colors.bgDark : colors.textDim;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        // 禁用态 GestureDetector 不接 onTap —— 改用 Opacity 暗示不可点。
        onTap: enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.save_rounded, size: 16, color: fg),
              const SizedBox(width: 8),
              Text(
                enabled ? '保存配置' : '已保存',
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
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

/// 自绘 Toggle 行 —— 图标 + 文字 + 右对齐开关按钮。
/// 用于外观 Tab 的 Mica 开关。不用 Material Switch（保持项目"全自绘"约束）。
class _ToggleRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_ToggleRow> createState() => _ToggleRowState();
}

class _ToggleRowState extends State<_ToggleRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final on = widget.value;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onChanged(!on),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.bgCard,
            border: Border.all(
              color: _hovered ? colors.borderAccent : colors.border,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: colors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              // 开关按钮（自绘 36x18 滑块）
              _ToggleSwitch(value: on),
            ],
          ),
        ),
      ),
    );
  }
}

/// 紧凑型 iOS 风滑块开关（自绘）。
class _ToggleSwitch extends StatelessWidget {
  final bool value;
  const _ToggleSwitch({required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 36,
      height: 18,
      decoration: BoxDecoration(
        color: value ? colors.accent.withValues(alpha: 0.85) : colors.bgHover,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: value ? colors.bgDark : colors.textSecondary,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
//  服务器 Tab 专用小部件（自绘，遵循全自绘约束）
// =====================================================================

/// 服务器账户行 —— 显示名 + host:port + 激活/删除按钮。
class _SftpAccountRow extends StatefulWidget {
  final SftpAccount account;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback onDelete;

  const _SftpAccountRow({
    required this.account,
    required this.active,
    required this.onActivate,
    required this.onDelete,
  });

  @override
  State<_SftpAccountRow> createState() => _SftpAccountRowState();
}

class _SftpAccountRowState extends State<_SftpAccountRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final active = widget.active;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? colors.accent.withValues(alpha: 0.1)
            : _hovered
            ? colors.bgHover
            : colors.bgCard,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: active ? colors.accent.withValues(alpha: 0.5) : colors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.radio_button_checked_rounded : Icons.dns_rounded,
            size: 14,
            color: active ? colors.accent : colors.textDim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.account.displayName,
                  style: TextStyle(
                    color: active ? colors.accent : colors.textPrimary,
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  '${widget.account.host}:${widget.account.port} · ${widget.account.username}',
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
          const SizedBox(width: 8),
          // 激活按钮
          if (!active) ...[
            GestureDetector(
              onTap: widget.onActivate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '设为激活',
                  style: TextStyle(
                    color: colors.bgDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          // 删除按钮
          GestureDetector(
            onTap: widget.onDelete,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: colors.danger.withValues(alpha: 0.4)),
              ),
              child: Text(
                '删除',
                style: TextStyle(
                  color: colors.danger,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 服务器配置输入行 —— 图标 + 标签 + 自绘 EditableText。
class _ServerFieldRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final TextEditingController controller;
  final String hint;

  /// true → 密码框（obscure）。
  final bool obscure;

  /// true → Consolas 等宽字体（路径输入用）。
  final bool fontMono;

  /// 文本变化回调（主机框粘贴 sftp:// 时自动解析用）。
  final ValueChanged<String>? onChanged;

  const _ServerFieldRow({
    required this.icon,
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.fontMono = false,
    this.onChanged,
  });

  @override
  State<_ServerFieldRow> createState() => _ServerFieldRowState();
}

class _ServerFieldRowState extends State<_ServerFieldRow> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
    if (widget.onChanged != null) {
      widget.controller.addListener(() {
        widget.onChanged!(widget.controller.text);
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final borderColor = _focused ? colors.borderAccent : colors.border;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            widget.label,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => _focusNode.requestFocus(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.bgCard,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: borderColor,
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(widget.icon, size: 15, color: colors.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: EditableText(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12,
                        fontFamily: widget.fontMono ? 'Consolas' : null,
                        decoration: TextDecoration.none,
                      ),
                      obscureText: widget.obscure,
                      cursorColor: colors.accent,
                      backgroundCursorColor: colors.textDim,
                      selectionColor: colors.accent.withValues(alpha: 0.3),
                    ),
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

/// 服务器 Tab 的小型操作按钮（自绘，黄铜/描边双态）。
class _ServerMiniButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// true → 黄铜底（主操作）；false → 灰描边（次操作）。
  final bool primary;

  const _ServerMiniButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.primary,
  });

  @override
  State<_ServerMiniButton> createState() => _ServerMiniButtonState();
}

class _ServerMiniButtonState extends State<_ServerMiniButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    final bg = widget.primary
        ? (_hovered ? colors.accent.withValues(alpha: 0.85) : colors.accent)
        : (_hovered ? colors.bgHover : Colors.transparent);
    final fg = widget.primary ? colors.bgDark : colors.textSecondary;
    final border = widget.primary ? Colors.transparent : colors.border;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
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
