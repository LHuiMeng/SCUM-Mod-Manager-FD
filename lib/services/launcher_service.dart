import 'package:flutter/services.dart';

import 'app_logger.dart';
import 'app_signals.dart';

/// LauncherService — 通过 MethodChannel 与 C++ 通信，启动/关闭游戏进程。
///
/// Channel: com.scummod/launcher
/// Methods (Dart -> C++):
///   - launchGame({exePath, args}) -> {success, pid}
///   - killGame()                  -> {success, async}    异步发起，立即返回
///   - killResult()                -> bool                最近一次 kill 最终结果
///   - waitKillDone({timeoutMs})   -> bool                真正等 worker 退出
///   - isGameRunning()             -> bool                进程是否仍在运行
///   - confirmAppExit()            -> void                确认安全退出 App
///
/// Pushed callbacks (C++ -> Dart):
///   - onAppExitRequest            -> void                用户点了 X，先清理再退
///
/// C++ 侧负责 CreateProcessW（带正确的 lpCurrentDirectory）以及进程句柄管理。
///
/// Kill 异步语义（v2.6+）：
/// 旧版 killGame 在 C++ MethodChannel 线程上同步做 5s WaitForSingleObject，
/// 直接卡死 Flutter GUI 线程。改为 fire-and-forget：调用立即返回，由 C++
/// worker 线程在后台执行关闭流程，Dart 端通过 isGameRunning 轮询检测进程
/// 真正退出后再触发 reclaimMods 回收 PAK。
///
/// App 安全退出语义（v2.6+）：
/// 旧版用户点窗口 X → C++ 直接 DestroyWindow → 进程退出 → PAK/UE4SS 残留。
/// 新版：C++ 调 Dart 推送 `onAppExitRequest` → Dart 走 kill game + reclaim
/// （如果游戏还在跑）→ 完成后调 `confirmAppExit` → C++ 再 DestroyWindow。
class LauncherService {
  LauncherService._();

  static const _channel = MethodChannel('com.scummod/launcher');

  /// 用户请求退出 App 的回调（C++ 推过来）。
  ///
  /// 注册位置：HomeScreen initState；反注册 dispose。
  /// 注册方负责执行：kill game（如在跑） + reclaim（必走） + confirmAppExit。
  static void setOnAppExitRequest(Future<void> Function()? callback) {
    _onAppExitRequest = callback;
  }

  static Future<void> Function()? _onAppExitRequest;

  /// 安装推送 channel handler（必须在 main() runApp 之后调用一次）。
  ///
  /// 把 C++ → Dart 的 `onAppExitRequest` 推送路由到 [_onAppExitRequest]。
  ///
  /// **关键**（v2.7+）：收到推送时**立刻**设置 `exitOverlayStep = initializing`，
  /// 让 ExitOverlay 在 GUI 上立即显示（不等 _onAppExitRequest 内部 await 完成）。
  /// 否则用户点 X 后会看到 GUI 冻结几秒才显示遮罩，主线程像卡死一样。
  static void installPushHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAppExitRequest':
          AppLogger.instance.info('收到 App 退出请求（C++ → Dart 推送）');
          // 立即把 exitOverlayStep 设为 initializing —— 让遮罩**立刻**出现。
          // _onAppExitRequest 内部会按真实状态推进到 killingGame /
          // reclaimingEnv / exitingApp。
          AppSignals.exitOverlayStep.value = ExitOverlayStep.initializing;
          if (_onAppExitRequest != null) {
            // 不 await —— 让 Dart 自己编排 kill+reclaim 流程。
            // ignore: discarded_futures
            _onAppExitRequest!();
          } else {
            // 没注册 handler —— 兜底直接放行退出，避免 C++ 等不到响应。
            AppLogger.instance.warning('App 退出推送未注册 handler，直接放行');
            await confirmAppExit();
          }
          return null;
      }
      return null;
    });
  }

  static Future<Map<String, dynamic>> launchGame(
    String exePath,
    List<String> args,
  ) async {
    try {
      AppLogger.instance.info('请求启动游戏进程', {'exe_path': exePath, 'args': args});
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'launchGame',
        {'exePath': exePath, 'args': args},
      );
      if (result == null) {
        AppLogger.instance.error('启动游戏返回空结果');
        return {'success': false, 'pid': 0};
      }
      final parsed = {
        'success': result['success'] ?? false,
        'pid': result['pid'] ?? 0,
      };
      AppLogger.instance.info('启动游戏结果', parsed);
      return parsed;
    } catch (e) {
      AppLogger.instance.error('启动游戏通道调用失败', {
        'exe_path': exePath,
        'error': e.toString(),
      });
      return {'success': false, 'pid': 0};
    }
  }

  /// 异步发起关闭游戏进程。
  ///
  /// **不再阻塞调用线程**：C++ 端把 WM_CLOSE + 等待 + 强杀 + 句柄清理
  /// 全部放到独立 worker 线程，本调用立即返回。返回值只表示"是否成功
  /// 发起"，不代表进程已退出。
  ///
  /// 后续流程由调用方负责：
  /// - 立即把 UI 切到「关闭中…」态
  /// - 继续用 [isGameRunning] 轮询
  /// - 进程退出后用 [killResult] 查最终结果，再触发 reclaim
  static Future<bool> killGame() async {
    try {
      AppLogger.instance.info('请求关闭游戏进程（异步发起，不阻塞）');
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'killGame',
      );
      final success = (result?['success'] as bool?) ?? false;
      AppLogger.instance.info('关闭游戏发起结果', {'success': success, 'async': true});
      return success;
    } catch (e) {
      AppLogger.instance.error('关闭游戏通道调用失败', {'error': e.toString()});
      return false;
    }
  }

  /// 查询最近一次 [killGame] 的最终执行结果。
  ///
  /// worker 线程完成 kill 流程后写入结果，本接口读取最近一次的结果。
  /// - true  = 优雅退出 / 强杀成功
  /// - false = 强杀失败 / 进程仍在（理论上不应发生，因为会先查 isGameRunning）
  static Future<bool> killResult() async {
    try {
      final result = await _channel.invokeMethod<bool>('killResult');
      return result ?? false;
    } catch (e) {
      AppLogger.instance.error('查询关闭游戏结果失败', {'error': e.toString()});
      return false;
    }
  }

  /// 等待最近一次 [killGame] 真正结束（worker 线程退出）。
  ///
  /// 返回：
  /// - true  = worker 已在 timeoutMs 内完成（游戏进程已被杀/或优雅退出）
  /// - false = 超时（worker 还在跑，调用方决定是否走兜底）
  ///
  /// **与 [killResult] 的区别**：killResult 只读最终结果（需要外面 poll）。
  /// 本接口在 C++ 端阻塞 poll g_kill_in_flight 标志，**保证 worker 真正
  /// 走完整个 kill 流程**（WM_CLOSE → 5s 等待 → TerminateProcess 兜底）。
  ///
  /// 用于 App 退出路径：必须确认游戏进程已被杀干净才能 reclaim + DestroyWindow。
  /// 旧版 Dart 用 isGameRunning 轮询 10s 兜底，但 SCUM 真实退出需要 10-30s，
  /// 10s 超时后立刻进 reclaim + destroyWindow → GUI 没了但游戏进程还在桌面跑
  /// （用户报告的现象）。
  static Future<bool> waitKillDone({int timeoutMs = 30000}) async {
    try {
      AppLogger.instance.info('等待 kill worker 完成', {'timeout_ms': timeoutMs});
      final result = await _channel.invokeMethod<bool>(
        'waitKillDone',
        {'timeoutMs': timeoutMs},
      );
      final done = result ?? false;
      AppLogger.instance.info('kill worker 完成状态', {'done': done});
      return done;
    } catch (e) {
      AppLogger.instance.error('等待 kill worker 失败', {'error': e.toString()});
      return false;
    }
  }

  static Future<bool> isGameRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isGameRunning');
      final running = result ?? false;
      AppLogger.instance.debug('游戏心跳检查', {'running': running});
      return running;
    } catch (e) {
      AppLogger.instance.error('游戏心跳检查失败', {'error': e.toString()});
      return false;
    }
  }

  /// 通知 C++ 端：Dart 侧安全清理完成，可以真正 DestroyWindow 了。
  ///
  /// 这是 [onAppExitRequest] 回调链的最后一环 —— 调完这个函数后 C++ 会
  /// 立即 PostMessage(WM_CLOSE) → 第二次进入 SC_CLOSE 时直接 DestroyWindow。
  static Future<void> confirmAppExit() async {
    try {
      AppLogger.instance.info('通知 C++：可以安全退出 App');
      await _channel.invokeMethod<void>('confirmAppExit');
    } catch (e) {
      // 兜底：万一通道挂了，记日志后吞掉 —— 进程总会退出。
      AppLogger.instance.error('confirmAppExit 失败', {'error': e.toString()});
    }
  }
}