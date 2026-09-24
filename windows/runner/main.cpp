#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dwmapi.h>

#include "flutter_window.h"
#include "utils.h"

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM with OLE support so that RegisterDragDrop() in
  // FlutterWindow::OnCreate works (OleInitialize calls CoInitializeEx
  // internally with COINIT_APARTMENTTHREADED, plus extra OLE state).
  // CoInitializeEx alone is NOT enough - RegisterDragDrop returns
  // OLE_E_NOTINITIALIZED without OleInitialize.
  HRESULT hr_ole = ::OleInitialize(nullptr);
  if (FAILED(hr_ole) && hr_ole != RPC_E_CHANGED_MODE) {
    // RPC_E_CHANGED_MODE = COM was already initialized in a different
    // threading mode (often by Flutter engine). That's acceptable.
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"scum_mod_manager", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 创建后改窗口样式为无框：去掉 WS_CAPTION / WS_SYSMENU，
  // 保留 WS_THICKFRAME 使边框可拖拽缩放，
  // 保留 WS_MAXIMIZEBOX / WS_MINIMIZEBOX 使任务栏右键菜单保留最大/最小化。
  HWND hwnd = window.GetHandle();
  if (hwnd) {
    SetWindowLongPtr(hwnd, GWL_STYLE,
        WS_POPUP | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    // 消除窗口边框白线（WS_POPUP 默认无边框，但 DWM 可能残留 1px 白线）。
    MARGINS margins = {0, 0, 0, 0};
    DwmExtendFrameIntoClientArea(hwnd, &margins);

    // Win11 22H2+：启用 DWM 圆角，与 Flutter 侧 ScumTheme.windowCornerRadius(10) 配合。
    // 不支持的 OS 忽略即可。
    DWORD corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner, sizeof(corner));
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // OleInitialize() 必须配 OleUninitialize() —— 之前只 CoUninitialize
  // 会泄漏 OLE 内部状态（Clipboard / Drag-Drop 簿记）。OleInitialize 内部
  // 会调 CoInitializeEx(COINIT_APARTMENTTHREADED)，但反过来 OleUninitialize
  // 只释放 OLE 簿记，COM 本身还得用 CoUninitialize 关。
  ::OleUninitialize();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}