#pragma warning(disable:4819)
#ifndef RUNNER_WINDOW_SERVICE_CHANNEL_H_
#define RUNNER_WINDOW_SERVICE_CHANNEL_H_

#include <windows.h>

#include <string>
#include <vector>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>

// WindowService MethodChannel registration and command dispatch.
//
// Channel name: com.scummod/window
// Supported methods:
//   - minimize()         -> SC_MINIMIZE
//   - maximize()         -> toggle maximize/restore
//   - close()            -> SC_CLOSE
//   - isMaximized()      -> query WINDOWPLACEMENT
//   - getDroppedFiles()  -> drain drop queue
//   - openFileDialog()   -> GetOpenFileNameW multi-select pak/ini
//   - enableMica(isDark) -> DWM Mica 系统级背景。isDark=true 时启用暗色
//                           标题栏（DWMWA_USE_IMMERSIVE_DARK_MODE=TRUE）配
//                           暗色 Mica；isDark=false 时关闭暗色标题栏配亮色
//                           Mica。返回 bool 表 Mica 是否成功启用。
//   - openImageDialog()  -> 单选 .png/.jpg/.jpeg/.webp（背景图选择）
//
// Does NOT depend on launcher / mod_link / other modules.
// 注：v3 架构起在线更新全部在 Dart 内完成（update_service.installDownloaded），
// 不再有 launchUpdater 通道；updater.exe 仅供老版本管理器迁移期使用。
namespace window_service {

// Register the channel. Call once at end of FlutterWindow::OnCreate.
void Register(HWND main_hwnd, flutter::BinaryMessenger* messenger);

// Unregister. Call at start of FlutterWindow::OnDestroy.
void Shutdown();

// Drop queue write interface - called by flutter_window.cpp WM_DROPFILES.
void AppendDroppedFile(const std::string& utf8_path);

// Drop queue drain interface (internal; normally invoked via MethodChannel).
void DrainDroppedFiles(std::vector<std::string>& out);

// C1：DWM Mica 系统级背景启用。
// Win11 22H2+ (build 22621) 设置 DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW。
// 不支持时返回 false，Dart 端应回退到半透明黑叠层（亚克力）。
//
// [isDark]：是否启用暗色标题栏（DWMWA_USE_IMMERSIVE_DARK_MODE）。
// - true：配暗色 Mica（适用于应用切到暗色主题时）。
// - false：配亮色 Mica（适用于应用切到亮色主题时，让 Mica 真正透出
//          浅色，而不是被强制成暗色）。
bool EnableMica(bool isDark);

// 3c：单选图片文件对话框（限定 .png/.jpg/.jpeg/.webp），用于背景图选择。
// 返回 0 或 1 个 UTF-8 路径。
std::vector<std::string> OpenImageDialog();

// UE4SS mod 目录选择对话框（IFileOpenDialog + FOS_PICKFOLDERS）。
// 用户取消时返回空列表；选中时返回 1 个 UTF-8 路径。
std::vector<std::string> OpenFolderDialog();

}  // namespace window_service

#endif  // RUNNER_WINDOW_SERVICE_CHANNEL_H_