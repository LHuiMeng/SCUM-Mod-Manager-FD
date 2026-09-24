// FlutterWindow 主窗口实现 —— 自绘无框标题栏。
//
// 关键架构事实：Flutter view 在创建时是独立顶层窗口，SetParent 之后变成
// WS_CHILD。WS_CHILD 没有 non-client 区域，WM_NCHITTEST 永远返回 HTCLIENT，
// HTCAPTION 对 child 完全无效 —— 这是之前多次尝试都失败的根因。
//
// 标题栏拖拽走「系统原生标题栏协议」：
//   ReleaseCapture + 向父窗口 SendMessage(WM_NCLBUTTONDOWN, HTCAPTION)
// → DefWindowProc 进入系统模态移动循环 → 自动获得 Aero Snap：拖到屏幕
//   边缘/角落时出现半屏/四分之一屏吸附预览，松手即占据，与资源管理器一致。
//
// 本方案：
// 1. child WndProc 拦截标题栏非按钮区的 WM_LBUTTONDOWN（return 0 阻止 Flutter
//    把这次点击当 click 处理），随即 ReleaseCapture + 向父窗口发送
//    WM_NCLBUTTONDOWN(HTCAPTION)，把移动交给系统循环
// 2. 标题栏 LBUTTONDBLCLK 切换父窗口最大/还原
// 3. 父窗口 ManualNcHitTest 仅处理 8px 边缘 resize（四边）
// 4. 必须在 SetChildContent 之后（child 已 parent）再 SetWindowLongPtr 子类化
//
// App 退出安全流程（v2.6+）：
// 旧版：SC_CLOSE → 直接 DestroyWindow → 进程结束 → 残留 PAK/UE4SS 污染游戏。
// 新版：SC_CLOSE → launcher_channel::RequestAppExit()：
//   - 通知 Dart「onAppExitRequest」→ Dart 走 kill game + reclaim（异步）
//   - Dart 完成后调 confirmAppExit → C++ PostMessage(WM_CLOSE) → 二次进入
//     → 此时 g_app_exit_state == confirmed → 直接 DestroyWindow。

#include "flutter_window.h"

#include <dwmapi.h>
#include <optional>
#include <windowsx.h>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "drop_target.h"
#include "launcher_channel.h"
#include "window_service_channel.h"

namespace {

// -- shared drag accept rule --

/// 是否接受拖入的路径：与 drop_target.cpp 的 ExtractFilePaths 保持一致
/// (.pak / .zip / 目录)。修复：旧版 flutter_window.cpp 的 WM_DROPFILES
/// fallback 只接 .pak，与 drop_target 的 OLE 拖拽行为不一致 —— 用户从
   /// OLE 拖入 zip / 文件夹成功，从 WM_DROPFILES 拖入则被静默丢。
bool AcceptDragPath(const wchar_t* path) {
  if (path == nullptr || path[0] == L'\0') return false;
  size_t len = wcslen(path);
  // .pak 后缀（不区分大小写）。
  bool isPak = len >= 4 && path[len - 4] == L'.' &&
               (path[len - 3] == L'p' || path[len - 3] == L'P') &&
               (path[len - 2] == L'a' || path[len - 2] == L'A') &&
               (path[len - 1] == L'k' || path[len - 1] == L'K');
  if (isPak) return true;
  // .zip 后缀（不区分大小写）。
  bool isZip = len >= 4 && path[len - 4] == L'.' &&
              (path[len - 3] == L'z' || path[len - 3] == L'Z') &&
              (path[len - 2] == L'i' || path[len - 2] == L'I') &&
              (path[len - 1] == L'p' || path[len - 1] == L'P');
  if (isZip) return true;
  // 目录（已存在的文件夹当 UE4SS mod 候选）。
  DWORD attr = GetFileAttributesW(path);
  if (attr != INVALID_FILE_ATTRIBUTES &&
      (attr & FILE_ATTRIBUTE_DIRECTORY)) {
    return true;
  }
  return false;
}

// -- constants --

/// Flutter 自绘标题栏高度（逻辑 px），必须与 Dart TitleBar.height 一致。
constexpr double kTitleBarLogicalHeight = 36.0;

/// 右侧按钮区宽度（逻辑 px）：UpdateButton(≈110, 有更新时出现)
/// + ThemeToggleSlider(48) + gap(4) + 3*46(窗口按钮) = 300，余量 10。
/// 必须覆盖全部可点击控件 —— 否则按钮区内的点击会被 IsInTitleBar
/// 误判为拖拽而吞掉（WM_LBUTTONDOWN return 0，Flutter 收不到）。
constexpr double kButtonAreaLogicalWidth = 310.0;

/// 窗口可缩放边缘宽度（物理 px）。
constexpr int kResizeBorder = 8;

/// parent hwnd prop。
constexpr const wchar_t kParentHwndProp[] = L"ScmmParentHwnd";

// -- helpers --

static double GetScale(HWND child_hwnd) {
  return GetDpiForWindow(child_hwnd) / 96.0;
}

/// 是否在标题栏拖拽区域（child 客户区坐标）。右侧 buttonArea 排除。
static bool IsInTitleBar(HWND child_hwnd, int clientX, int clientY) {
  const double scale = GetScale(child_hwnd);
  const int titleBarH =
      static_cast<int>(kTitleBarLogicalHeight * scale + 0.5);
  const int buttonW =
      static_cast<int>(kButtonAreaLogicalWidth * scale + 0.5);

  RECT rc;
  GetClientRect(child_hwnd, &rc);
  const int dragLimitX = (rc.right - rc.left) - buttonW;

  return clientY >= 0 && clientY < titleBarH && clientX < dragLimitX;
}

/// Flutter 子窗口 WndProc —— 仅拦截标题栏区域鼠标事件。
/// 非标题栏区域完全放行给 Flutter（落到 CallWindowProc）。
///
/// 关键：WS_CHILD 收到 LBUTTONDOWN 后必须 SetCapture 确保鼠标离开 child
/// 后仍能持续收到消息。不 SetCapture 的话，快速拖拽时鼠标移出 child 区域
/// 后 WM_MOUSEMOVE 会停止送达，导致窗口滞留不动。
LRESULT CALLBACK FlutterChildWndProc(HWND hwnd, UINT msg,
                                     WPARAM wParam, LPARAM lParam) {
  auto origProc = reinterpret_cast<WNDPROC>(GetProp(hwnd, L"OrigProc"));
  if (!origProc) return DefWindowProc(hwnd, msg, wParam, lParam);

  HWND parent = reinterpret_cast<HWND>(GetProp(hwnd, kParentHwndProp));

  // WM_NCHITTEST：child 顶部 kResizeBorder 物理像素返回 HTTRANSPARENT，
  // 把命中测试穿透给同线程的下层窗口（父窗口），父窗口 ManualNcHitTest
  // 随即返回 HTTOP / HTTOPLEFT / HTTOPRIGHT，实现顶部四边缘 resize。
  // WM_NCCALCSIZE 已把顶部 8px 吸收进客户区（标题栏顶到物理顶部），
  // 因此顶部命中测试默认由 child 持有——不穿透的话父窗口永远收不到。
  // 其余区域放行给 Flutter 原窗口过程（落到末尾 CallWindowProc）。
  if (msg == WM_NCHITTEST) {
    POINT pt = {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
    ScreenToClient(hwnd, &pt);
    const double scale = GetScale(hwnd);
    const int border = static_cast<int>(kResizeBorder * scale + 0.5);
    if (pt.y >= 0 && pt.y < border) {
      return HTTRANSPARENT;
    }
  }

  // WM_LBUTTONDOWN：标题栏非按钮区 -> 交给系统原生标题栏拖拽协议。
  // return 0 阻止 Flutter 把这次点击当 click 处理。
  // 原生协议：ReleaseCapture + 向父窗口发送 WM_NCLBUTTONDOWN(HTCAPTION)。
  // DefWindowProc 随即进入系统模态移动循环，自动提供 Aero Snap（拖到屏幕
  // 边缘/角落出现半屏/四分之一屏吸附预览，松手自动占据——与资源管理器一致）；
  // 移动期间鼠标消息由系统循环接管，不再需要手工 SetCapture + SetWindowPos。
  if (msg == WM_LBUTTONDOWN) {
    const int x = GET_X_LPARAM(lParam);
    const int y = GET_Y_LPARAM(lParam);
    if (parent && IsInTitleBar(hwnd, x, y)) {
      ReleaseCapture();
      POINT cur;
      GetCursorPos(&cur);
      SendMessage(parent, WM_NCLBUTTONDOWN, HTCAPTION,
                  MAKELPARAM(cur.x, cur.y));
      return 0;
    }
    // 非标题栏区域：放行给 Flutter（注意：不在这里 return，落到末尾 CallWindowProc）
  }

  // WM_LBUTTONDBLCLK：标题栏双击 -> 切换父窗口最大/还原。
  if (msg == WM_LBUTTONDBLCLK) {
    const int x = GET_X_LPARAM(lParam);
    const int y = GET_Y_LPARAM(lParam);
    if (parent && IsInTitleBar(hwnd, x, y)) {
      ShowWindow(parent, IsZoomed(parent) ? SW_RESTORE : SW_MAXIMIZE);
      return 0;
    }
  }

  // WM_MOUSEMOVE / WM_LBUTTONUP / WM_CAPTURECHANGED：拖拽已交由系统原生
  // 移动循环（WM_NCLBUTTONDOWN HTCAPTION）接管，手工拖拽状态机不再需要。
  // 系统循环内部自行管理 capture 与鼠标消息路由。", "old_string": "// WM_MOUSEMOVE：拖拽中 -> 增量移动父窗口。\n  if (msg == WM_MOUSEMOVE) {\n    HANDLE hStart = GetProp(hwnd, kDragStartProp);\n    if (hStart) {\n      POINT* start = reinterpret_cast<POINT*>(hStart);\n      POINT cur;\n      GetCursorPos(&cur);\n\n      RECT rc;\n      GetWindowRect(parent, &rc);\n      const int dx = cur.x - start->x;\n      const int dy = cur.y - start->y;\n      if (dx != 0 || dy != 0) {\n        SetWindowPos(parent, nullptr,\n                     rc.left + dx,\n                     rc.top + dy,\n                     0, 0,\n                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);\n        start->x = cur.x;\n        start->y = cur.y;\n      }\n      return 0;  // 拖拽中：吃掉 move，不让 Flutter 看到（避免 hover 抖动）\n    }\n  }\n\n  // WM_LBUTTONUP：结束拖拽。\n  if (msg == WM_LBUTTONUP) {\n    HANDLE hStart = GetProp(hwnd, kDragStartProp);\n    if (hStart) {\n      delete reinterpret_cast<POINT*>(hStart);\n      RemoveProp(hwnd, kDragStartProp);\n      ReleaseCapture();\n      return 0;\n    }\n  }\n\n  // WM_CAPTURECHANGED：拖拽被意外打断（Alt+Tab 等），清理拖拽状态。\n  if (msg == WM_CAPTURECHANGED) {\n    HANDLE hStart = GetProp(hwnd, kDragStartProp);\n    if (hStart) {\n      delete reinterpret_cast<POINT*>(hStart);\n      RemoveProp(hwnd, kDragStartProp);\n    }\n    // 放行给 Flutter，不 return\n  }", "path": "windows/runner/flutter_window.cpp"}

  // WM_ERASEBKGND：阻止快速拖拽时 Windows 默认白色擦除背景。
  if (msg == WM_ERASEBKGND) {
    return 1;
  }

  // 其它消息全部放行给 Flutter。
  return CallWindowProc(origProc, hwnd, msg, wParam, lParam);
}

/// 父窗口 ManualNcHitTest —— 四边缘（含顶部）resize。
/// 顶部能收到命中测试的前提：child 在顶部 kResizeBorder 物理像素返回
/// HTTRANSPARENT（见 FlutterChildWndProc），把命中测试穿透给父窗口。
static LRESULT ManualNcHitTest(HWND hwnd, LPARAM lparam) {
  POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};

  RECT wr;
  GetWindowRect(hwnd, &wr);

  const int x = static_cast<int>(pt.x);
  const int y = static_cast<int>(pt.y);

  const int l = static_cast<int>(wr.left);
  const int r = static_cast<int>(wr.right);
  const int t = static_cast<int>(wr.top);
  const int b = static_cast<int>(wr.bottom);

  bool left   = x >= l && x < l + kResizeBorder;
  bool right  = x < r && x >= r - kResizeBorder;
  bool top    = y >= t && y < t + kResizeBorder;
  bool bottom = y < b && y >= b - kResizeBorder;

  if (top && left)     return HTTOPLEFT;
  if (top && right)    return HTTOPRIGHT;
  if (bottom && left)  return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (top)             return HTTOP;
  if (bottom)          return HTBOTTOM;
  if (left)            return HTLEFT;
  if (right)           return HTRIGHT;

  return HTCLIENT;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();

  // 必须先 SetParent（让窗口变 child），再子类化 WndProc。
  SetChildContent(child_hwnd);

  // 子类化 Flutter 子窗口：仅拦截标题栏非按钮区鼠标事件驱动父窗口拖拽。
  LONG_PTR originalProc = SetWindowLongPtr(
      child_hwnd, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(FlutterChildWndProc));
  SetProp(child_hwnd, L"OrigProc", reinterpret_cast<HANDLE>(originalProc));
  SetProp(child_hwnd, kParentHwndProp, reinterpret_cast<HANDLE>(GetHandle()));

  // MethodChannel 注册。
  window_service::Register(GetHandle(),
                           flutter_controller_->engine()->messenger());
  launcher_channel::Register(flutter_controller_->engine()->messenger());
  // 让 launcher_channel 持有主窗口句柄，用于 confirmAppExit / RequestAppExit。
  launcher_channel::SetMainHwnd(GetHandle());
  SetDragChannelMessenger(flutter_controller_->engine()->messenger());

  // 首帧后 Show 。
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    DropTarget::RegisterForWindow(GetHandle(), nullptr);
  });

  return true;
}

void FlutterWindow::OnDestroy() {
  window_service::Shutdown();
  launcher_channel::Shutdown();
  RevokeDragDrop(GetHandle());

  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_NCHITTEST) {
    return ManualNcHitTest(hwnd, lparam);
  }
  // 吃掉顶部 NC 边带：让自绘标题栏 (height=36) 直接顶到窗口物理顶部，
  // 不再被 OS 的 ~4px 上边框隔开。左右底部 NC 保留（用于边缘 resize）。
  //
  // 流程：先调 DefWindowProc 拿到默认客户区 RECT（保留左右底 NC），
  // 再把 top 上移 kResizeBorder（等于消除顶部 NC），返回 0 让 OS 采纳。
  if (message == WM_NCCALCSIZE && wparam == TRUE) {
    LRESULT result = ::DefWindowProc(hwnd, WM_NCCALCSIZE, wparam, lparam);
    if (result != 0) return result;
    NCCALCSIZE_PARAMS* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    // 仅修改 rgrc[0].top：把它向上推 kResizeBorder，让顶部 NC=0。
    // 左右/底部保持原样，resize 边带仍存在。
    params->rgrc[0].top -= kResizeBorder;
    return 0;
  }

  // 旧版路径（wparam=FALSE）：直接交给默认处理。
  if (message == WM_NCCALCSIZE) {
    return ::DefWindowProc(hwnd, message, wparam, lparam);
  }

  if (message == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wparam);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      wchar_t path[MAX_PATH];
      if (DragQueryFileW(hDrop, i, path, MAX_PATH) == 0) continue;

      // 用共享 AcceptDragPath —— 与 drop_target.cpp 的 OLE 拖拽行为一致。
      if (!AcceptDragPath(path)) continue;

      int utf8_len = WideCharToMultiByte(CP_UTF8, 0, path, -1,
                                         nullptr, 0, nullptr, nullptr);
      if (utf8_len <= 0) continue;
      std::string utf8(utf8_len, 0);
      WideCharToMultiByte(CP_UTF8, 0, path, -1, &utf8[0],
                          utf8_len, nullptr, nullptr);
      if (!utf8.empty() && utf8.back() == '\0') utf8.pop_back();
      window_service::AppendDroppedFile(utf8);
    }
    DragFinish(hDrop);
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message,
                                                     wparam, lparam);
    if (result) return *result;
  }

  switch (message) {
    case WM_SIZE:
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SYSCOMMAND:
      if (wparam == SC_CLOSE) {
        // 应用退出安全流程（v2.6）：
        // 旧版：直接 DestroyWindow → 进程退出 → PAK/UE4SS 残留污染游戏目录。
        // 新版：先问 launcher_channel 是否在跑游戏：
        //   - true  = 已通知 Dart，Dart 走 kill+reclaim 后调 confirmAppExit
        //             再 PostMessage(WM_CLOSE) 触发二次 SC_CLOSE；
        //   - false = Dart 已确认（或根本没游戏在跑），可立即 DestroyWindow。
        if (launcher_channel::RequestAppExit()) {
          // Dart 正在处理 → 等它回 confirmAppExit 即可。
          // 这里不 destroyWindow，避免 PAK/UE4SS 残留。
          return 0;
        }
        DestroyWindow(hwnd);
        return 0;
      }
      break;
    default:
      // 自定义消息：marshal 回主线程跑 IFileOpenDialog（window_service
      // 的 OpenFolderDialog）—— Flutter engine 的 binary messenger 线程
      // 不是 GUI 线程，COM 调用必须在主线程。
      static UINT s_runFolderMsg = 0;
      if (s_runFolderMsg == 0) {
        s_runFolderMsg = RegisterWindowMessageW(L"ScumModRunFolderDialog_v1");
      }
      if (message == s_runFolderMsg) {
        // lparam = std::vector<std::string>* 写回 result。
        auto* out = reinterpret_cast<std::vector<std::string>*>(lparam);
        if (out != nullptr) {
          // 直接调 window_service::OpenFolderDialog 的内部实现。
          // 这里直接 inline 一份 COM 调用（不放回 window_service.h 的 public API），
          // 保持原 OpenFolderDialog 公共签名不变。
          HRESULT (WINAPI *pCoCreateInstance)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*) =
              nullptr;
          HMODULE hOle32 = GetModuleHandleW(L"ole32.dll");
          if (hOle32) {
            pCoCreateInstance = reinterpret_cast<HRESULT (WINAPI *)(
                REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*)>(
                GetProcAddress(hOle32, "CoCreateInstance"));
          }
          if (pCoCreateInstance) {
            IFileOpenDialog* pDialog = nullptr;
            HRESULT hr = pCoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                           CLSCTX_INPROC_SERVER,
                                           IID_PPV_ARGS(&pDialog));
            if (SUCCEEDED(hr) && pDialog) {
              DWORD opts = 0;
              if (SUCCEEDED(pDialog->GetOptions(&opts))) {
                pDialog->SetOptions(opts | 0x20 /* FOS_PICKFOLDERS */);
              }
              pDialog->SetTitle(L"选择 UE4SS mod 文件夹");
              if (SUCCEEDED(pDialog->Show(hwnd))) {
                IShellItem* pItem = nullptr;
                if (SUCCEEDED(pDialog->GetResult(&pItem)) && pItem) {
                  PWSTR pszPath = nullptr;
                  if (SUCCEEDED(pItem->GetDisplayName(SIGDN_FILESYSPATH,
                                                    &pszPath)) && pszPath) {
                    // Wide → UTF-8 转换在内部完成。
                    int utf8_len = WideCharToMultiByte(CP_UTF8, 0, pszPath, -1,
                                                       nullptr, 0, nullptr, nullptr);
                    if (utf8_len > 1) {
                      std::string utf8(utf8_len, 0);
                      WideCharToMultiByte(CP_UTF8, 0, pszPath, -1, &utf8[0],
                                           utf8_len, nullptr, nullptr);
                      if (!utf8.empty() && utf8.back() == '\0') utf8.pop_back();
                      *out = {utf8};
                    }
                    CoTaskMemFree(pszPath);
                  }
                  pItem->Release();
                }
              }
              pDialog->Release();
            }
          }
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}