#pragma warning(disable:4819)
#ifndef RUNNER_LAUNCHER_CHANNEL_H_
#define RUNNER_LAUNCHER_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// LauncherService MethodChannel.
//
// Channel name: com.scummod/launcher
// Supported methods (Dart -> C++):
//   - launchGame({exePath, args}) -> {success, pid}
//   - killGame()                  -> {success, async}
//   - killResult()                -> bool
//   - waitKillDone({timeoutMs})   -> bool    真正等 worker 完成
//   - isGameRunning()             -> bool
//   - confirmAppExit()            -> void     (Dart cleanup done → really exit)
//
// Pushed callbacks (C++ -> Dart):
//   - onAppExitRequest            -> void     (user clicked X; please cleanup)
//
// All game-process tracking is file-static inside launcher_channel.cpp;
// external code only sees Register/SetMainHwnd/RequestAppExit/Shutdown.
namespace launcher_channel {

// Register the channel. Call once at end of FlutterWindow::OnCreate.
void Register(flutter::BinaryMessenger* messenger);

// 注入主窗口 HWND —— FlutterWindow::OnCreate 时调用一次。
// confirmAppExit / RequestAppExit 需要 HWND 来 PostMessage(WM_CLOSE)。
void SetMainHwnd(HWND hwnd);

// 用户请求退出 App（如点窗口 X）。
//
// 返回值：
//   true  = 已通知 Dart 做清理（异步），调用方**不要**直接 DestroyWindow，
//          等 Dart confirmAppExit 后再 destroy。
//   false = Dart 已经确认可退出（或不需清理），可立即 DestroyWindow。
//
// 调用方应在 WM_SYSCOMMAND/SC_CLOSE 处理里调一次，根据返回值决定是直接
// destroy 还是等 Dart confirmAppExit。
bool RequestAppExit();

// Unregister. Call at start of FlutterWindow::OnDestroy.
void Shutdown();

}  // namespace launcher_channel

#endif  // RUNNER_LAUNCHER_CHANNEL_H_