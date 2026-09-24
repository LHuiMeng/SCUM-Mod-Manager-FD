/// 在线更新按钮 —— 嵌在标题栏主题切换按钮左边。
///
/// 形态（按主人定稿 E）：
/// - 无更新：整个 widget 不渲染（彻底隐藏，不占布局）。
/// - 有更新：渲染「⚡ 有新版本 v2.5.0」小按钮。
///   - 点击 → 触发下载 → 按钮原地变进度条动画（accent 横条渐变 + 百分比）。
///   - 下载完成 + sha256 通过 → 按钮变「点击安装 v2.5.0」橙色脉冲。
///   - 再次点击 → 走安装流程（v3：Dart 内解压→校验→原子提交→写 app.json，
///     重启管理器生效，无需关闭游戏）。
///
/// 全部自绘，无 Material 控件。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/app_logger.dart';
import '../services/app_signals.dart';
import '../services/download_service.dart';
import '../services/update_service.dart';
import '../theme/scum_colors.dart';

/// 标题栏里的更新按钮（默认隐藏，有新版本才渲染）。
class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key});

  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<UpdateButton>
    with TickerProviderStateMixin {
  /// 脉冲动画（下载完成态用一次）—— 0 → 1 → 0，循环 2 次后停下。
  late final AnimationController _pulseCtrl;

  /// 进度条 shader 横扫 controller（下载中态）。
  late final AnimationController _progressSweepCtrl;

  /// 当前是否正在下载（本地状态，用于决定按钮的形态）。
  bool _downloading = false;

  /// 当前是否处于"下载完成等待安装"态。
  bool _readyToInstall = false;

  /// 下载完成的 manifest（安装时需要版本号与校验信息）。
  UpdateManifest? _downloadedManifest;

  /// v3.1：本次下载是否为增量包（轻量化路径）。
  bool _downloadedIsDelta = false;

  /// v3.1：增量包清单（增量安装需要）。
  DeltaManifest? _downloadedDeltaManifest;

  /// HMAC verify key —— 与 UpdateService.verifyKey 同源（getter 实时解析）。
  /// 这里复用 UpdateService 的解析逻辑，避免两处 hex 解码漂移。
  /// 真值在主人手上（编译期 dart-define-from-file 注入），源码里无占位。

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _progressSweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _progressSweepCtrl.dispose();
    super.dispose();
  }

  Future<void> _onClick() async {
    if (_downloading) return; // 下载中点击无响应

    if (_readyToInstall) {
      _onInstallRequested();
      return;
    }

    // 触发下载
    setState(() => _downloading = true);
    _progressSweepCtrl.repeat();
    AppLogger.instance.ui('更新按钮', action: '点击下载');
    final m = await _fetchManifestForDownload();
    if (m == null) {
      _progressSweepCtrl.stop();
      setState(() => _downloading = false);
      _showSnack('无法获取更新信息，请稍后重试');
      return;
    }
    // v3.1 轻量化：先探增量包；仅当 base == 当前版本 且验签通过才走增量下载，
    // 否则回退完整包（完整包永远兜底，增量不可用零损失）。
    final dm = await UpdateService.fetchDeltaManifest(m);
    bool ok;
    bool isDelta = false;
    if (dm != null && dm.base == UpdateService.currentVersion) {
      AppLogger.instance.info('命中增量更新包', {
        'base': dm.base,
        'to': m.version,
      });
      ok = await DownloadService.downloadDeltaAndVerify(m, dm);
      isDelta = ok;
    } else {
      ok = await DownloadService.downloadAndVerify(m);
    }
    if (!mounted) return;
    if (ok) {
      _progressSweepCtrl.stop();
      _progressSweepCtrl.value = 0;
      setState(() {
        _downloading = false;
        _readyToInstall = true;
        _downloadedManifest = m;
        _downloadedIsDelta = isDelta;
        _downloadedDeltaManifest = isDelta ? dm : null;
      });
      // 触发一次脉冲动画
      await _pulseCtrl.forward(from: 0);
      _pulseCtrl.stop();
      _pulseCtrl.value = 0;
    } else {
      _progressSweepCtrl.stop();
      setState(() => _downloading = false);
      _showSnack('下载或校验失败，请稍后重试');
    }
  }

  /// 拉一次 manifest 用于下载 —— 直接走 HTTP（不走 UpdateService 私有 fetch）。
  Future<UpdateManifest?> _fetchManifestForDownload() async {
    final url = UpdateService.manifestUrl;
    if (url.isEmpty) return null; // 无更新源（对外版）
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map<String, dynamic>) return null;
      final m = UpdateManifest.fromJson(body);
      // 复用 UpdateService.verifySignature —— 与启动时检测用同一份实现，
      // 避免两处独立 HMAC 算法漂移（旧版这里有重复的 _verifyInline 已删除）。
      if (!UpdateService.verifySignature(m)) {
        AppLogger.instance.error('更新 manifest 签名校验失败（按钮触发下载）', {
          'version': m.version,
        });
        return null;
      }
      return m;
    } catch (e) {
      AppLogger.instance.warning('拉取 manifest 异常', {'error': e.toString()});
      return null;
    }
  }

  void _onInstallRequested() {
    AppLogger.instance.ui('更新按钮', action: '点击安装');
    _showConfirmDialog();
  }

  Future<void> _showConfirmDialog() async {
    final colors = ScumColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.bgPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colors.border),
        ),
        title: Text(
          '安装更新 v${AppSignals.latestVersion.value ?? ""}',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          '更新将安装到新版本目录，完成后重启管理器生效。\n'
          '本地 ~mods / config / 备注 / 背景图均不受影响，无需关闭 SCUM。',
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              '取消',
              style: TextStyle(color: colors.textDim, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '立即安装',
              style: TextStyle(
                color: colors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _doInstall();
    }
  }

  Future<void> _doInstall() async {
    // 安装前先确认下载文件还在（用户可能中途删除）
    final m = _downloadedManifest;
    if (m == null) {
      _showSnack('更新信息丢失，请重新下载');
      setState(() => _readyToInstall = false);
      AppSignals.updateDownloaded.value = false;
      return;
    }
    final file = File(UpdateService.downloadPath());
    if (!await file.exists()) {
      _showSnack('下载文件丢失，请重新下载');
      setState(() => _readyToInstall = false);
      AppSignals.updateDownloaded.value = false;
      return;
    }

    // v3 架构：安装全部在 Dart 内完成（解压 → 校验 → 原子提交 → 写 app.json），
    // 不再启动 updater.exe。安装期间无需关闭应用/游戏。
    // v3.1：增量包走 installDelta（基于当前版本复制 + 应用变更），其余走完整包。
    final result = _downloadedIsDelta && _downloadedDeltaManifest != null
        ? await UpdateService.installDelta(
            m, _downloadedDeltaManifest!, UpdateService.deltaPath())
        : await UpdateService.installDownloaded(m);
    if (!mounted) return;
    if (result.success) {
      AppLogger.instance.info('更新安装成功', {
        'version': m.version,
        'delta': _downloadedIsDelta,
        'message': result.message,
      });
      setState(() {
        _readyToInstall = false;
        _downloadedManifest = null;
        _downloadedIsDelta = false;
        _downloadedDeltaManifest = null;
      });
      AppSignals.updateDownloaded.value = false;
      AppSignals.updateAvailable.value = false;
      AppSignals.latestVersion.value = null;
      _showSnack(result.message, isError: false);
    } else {
      AppLogger.instance.error('更新安装失败', {'message': result.message});
      _showSnack(result.message);
    }
  }

  void _showSnack(String msg, {bool isError = true}) {
    final colors = ScumColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? colors.danger : colors.accent,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final latest = AppSignals.latestVersion.value ?? '';

    if (_downloading) {
      return _ProgressButton(
        progress: AppSignals.updateProgress,
        sweepCtrl: _progressSweepCtrl,
      );
    }

    if (_readyToInstall) {
      return _InstallReadyButton(
        version: latest,
        pulseCtrl: _pulseCtrl,
        onTap: _onClick,
      );
    }

    return _NewVersionButton(version: latest, onTap: _onClick);
  }
}

// =====================================================================
//  三个按钮形态（无更新时不渲染）
// =====================================================================

/// 形态 1：有新版本 → 「⚡ 有新版本 v2.5.0」小按钮
class _NewVersionButton extends StatefulWidget {
  final String version;
  final VoidCallback onTap;
  const _NewVersionButton({required this.version, required this.onTap});

  @override
  State<_NewVersionButton> createState() => _NewVersionButtonState();
}

class _NewVersionButtonState extends State<_NewVersionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? colors.accent.withValues(alpha: 0.20)
                : colors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: colors.accent.withValues(alpha: _hovered ? 0.7 : 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.system_update_alt_rounded,
                size: 14,
                color: colors.accent,
              ),
              const SizedBox(width: 4),
              Text(
                widget.version.isEmpty
                    ? '有新版本'
                    : '有新版本 v${widget.version}',
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
      ),
    );
  }
}

/// 形态 2：下载中 → 进度条 + 百分比
class _ProgressButton extends StatelessWidget {
  final ValueNotifier<double?> progress;
  final AnimationController sweepCtrl;
  const _ProgressButton({required this.progress, required this.sweepCtrl});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return Container(
      height: 26,
      width: 130,
      decoration: BoxDecoration(
        color: colors.bgCard,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.accent.withValues(alpha: 0.6)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            // 底部：实际下载进度（accent 横条）
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, v, _) {
                final pct = v ?? 0.0;
                return Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: pct.clamp(0.0, 1.0),
                    heightFactor: 1.0,
                    child: Container(
                      color: colors.accent.withValues(alpha: 0.35),
                    ),
                  ),
                );
              },
            ),
            // 横扫 shader —— 给"下载中"一个动感
            AnimatedBuilder(
              animation: sweepCtrl,
              builder: (_, __) {
                return Align(
                  alignment: Alignment(-1 + 2 * sweepCtrl.value, 0),
                  child: Container(
                    width: 24,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          colors.accent.withValues(alpha: 0.55),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            // 文字（百分比）
            Center(
              child: ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (_, v, _) {
                  final pct = ((v ?? 0.0) * 100).clamp(0, 100).toInt();
                  return Text(
                    '下载中 $pct%',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                      shadows: [
                        Shadow(
                          color: colors.bgDark.withValues(alpha: 0.8),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 形态 3：下载完成 → 「点击安装 v2.5.0」橙色脉冲按钮
class _InstallReadyButton extends StatefulWidget {
  final String version;
  final AnimationController pulseCtrl;
  final VoidCallback onTap;
  const _InstallReadyButton({
    required this.version,
    required this.pulseCtrl,
    required this.onTap,
  });

  @override
  State<_InstallReadyButton> createState() => _InstallReadyButtonState();
}

class _InstallReadyButtonState extends State<_InstallReadyButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: widget.pulseCtrl,
          builder: (_, child) {
            final pulse = widget.pulseCtrl.value;
            return Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: colors.accent.withValues(
                  alpha: _hovered ? 0.45 : (0.30 + 0.20 * pulse),
                ),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colors.accent),
                boxShadow: [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.4 * pulse),
                    blurRadius: 6 + 6 * pulse,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.download_done_rounded,
                size: 14,
                color: colors.textPrimary,
              ),
              const SizedBox(width: 4),
              Text(
                widget.version.isEmpty
                    ? '点击安装'
                    : '点击安装 v${widget.version}',
                style: TextStyle(
                  color: colors.textPrimary,
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