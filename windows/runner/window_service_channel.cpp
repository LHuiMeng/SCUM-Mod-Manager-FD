#pragma warning(disable:4819)
#include "window_service_channel.h"
#include "utils.h"  // Utf8FromUtf16

#include <commdlg.h>
#include <dwmapi.h>  // C1: DWM 系统级背景（Mica / 亚克力）
#include <shobjidl.h>  // IFileOpenDialog / IShellItem (目录选择)
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

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
//   - enableMica(isDark) -> DWM Mica 系统级背景
//   - openImageDialog()  -> 单选图片文件
//
// Does NOT depend on launcher / mod_link / other modules.
// 注：v3 架构起在线更新全部在 Dart 内完成（update_service.installDownloaded），
// 不再有 launchUpdater 通道；updater.exe 仅供老版本管理器迁移期使用。

namespace window_service {

// ===== 内部状态（外部不可见） =====
// 这些 static 全局变量只在 window_service_channel.cpp 内可见，
// 不需要匿名 namespace（C++17 起 static 已经够用）。

static std::vector<std::string> g_drop_queue;
static HWND g_main_hwnd = nullptr;
static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_channel;

// ===== 内部工具函数 =====

static bool IsWindowMaximizedImpl(HWND hwnd) {
    WINDOWPLACEMENT wp = {sizeof(WINDOWPLACEMENT)};
    if (!GetWindowPlacement(hwnd, &wp)) return false;
    return wp.showCmd == SW_MAXIMIZE;
}

static std::string WideToUtf8(const std::wstring& w) {
    int utf8_len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1,
                                       nullptr, 0, nullptr, nullptr);
    if (utf8_len <= 0) return std::string();
    std::string utf8(utf8_len, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &utf8[0],
                        utf8_len, nullptr, nullptr);
    if (!utf8.empty() && utf8.back() == '\0') utf8.pop_back();
    return utf8;
}

static flutter::EncodableValue EncodeStringList(
    const std::vector<std::string>& list) {
    std::vector<flutter::EncodableValue> enc_list;
    enc_list.reserve(list.size());
    for (const auto& s : list) {
        enc_list.push_back(flutter::EncodableValue(s));
    }
    return flutter::EncodableValue(std::move(enc_list));
}

// ===== 公开 API =====

void Minimize() {
    if (g_main_hwnd) ShowWindow(g_main_hwnd, SW_MINIMIZE);
}

void ToggleMaximize() {
    if (!g_main_hwnd) return;
    ShowWindow(g_main_hwnd,
               IsWindowMaximizedImpl(g_main_hwnd) ? SW_RESTORE : SW_MAXIMIZE);
}

void CloseWindow() {
    if (!g_main_hwnd) return;
    PostMessage(g_main_hwnd, WM_SYSCOMMAND, SC_CLOSE, 0);
}

bool IsWindowMaximized() {
    return g_main_hwnd && IsWindowMaximizedImpl(g_main_hwnd);
}

std::vector<std::string> DrainDroppedFilesImpl() {
    std::vector<std::string> out;
    out.swap(g_drop_queue);
    return out;
}

std::vector<std::string> OpenFileDialog() {
    std::vector<std::string> result;
    if (!g_main_hwnd) return result;

    wchar_t buffer[4096] = {0};
    OPENFILENAMEW ofn = {0};
    ofn.lStructSize = sizeof(OPENFILENAMEW);
    ofn.hwndOwner = g_main_hwnd;
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = sizeof(buffer) / sizeof(wchar_t);
    // 接受 .pak / .zip / .ini（zip 是 UE4SS mod 压缩包，Dart 端会解压判定）。
    ofn.lpstrFilter = L"SCUM Mod Files (*.pak;*.zip;*.ini)\0*.pak;*.zip;*.ini\0"
                      L"All Files (*.*)\0*.*\0";
    ofn.nFilterIndex = 1;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_ALLOWMULTISELECT |
                OFN_EXPLORER;

    if (GetOpenFileNameW(&ofn)) {
        const wchar_t* p = buffer;
        std::wstring dir = p;
        p += dir.size() + 1;
        if (*p == L'\0') {
            result.push_back(WideToUtf8(dir));
        } else {
            while (*p) {
                std::wstring full = dir + L"\\" + std::wstring(p);
                result.push_back(WideToUtf8(full));
                p += wcslen(p) + 1;
            }
        }
    }
    return result;
}

/// 内部：在当前线程同步执行 IFileOpenDialog 返回所选目录路径。
///
/// **必须** 在主线程（IsGUIThread=TRUE）调用 —— Flutter engine 的 binary
/// messenger 线程不是 GUI 线程，COM 失败 RPC_E_WRONG_THREAD。
/// 旧版没注意这点，从 worker 线程直接调，用户看到"选择文件夹"无反应。
static std::vector<std::string> RunFolderDialogOnMainThread(HWND hwnd) {
    std::vector<std::string> out;

    // IFileOpenDialog 是 Vista+ 提供的"现代"目录选择对话框，
    // GetOpenFileNameW 不支持纯目录选择。运行时动态获取 COM 接口。
    HRESULT (WINAPI *pCoCreateInstance)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*) =
        nullptr;
    HMODULE hOle32 = GetModuleHandleW(L"ole32.dll");
    if (hOle32) {
        pCoCreateInstance = reinterpret_cast<HRESULT (WINAPI *)(
            REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*)>(
            GetProcAddress(hOle32, "CoCreateInstance"));
    }
    if (!pCoCreateInstance) return out;

    // FOS_PICKFOLDERS = 0x20
    IFileOpenDialog* pDialog = nullptr;
    HRESULT hr = pCoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&pDialog));
    if (FAILED(hr) || !pDialog) return out;

    DWORD opts = 0;
    if (SUCCEEDED(pDialog->GetOptions(&opts))) {
        pDialog->SetOptions(opts | 0x20 /* FOS_PICKFOLDERS */);
    }
    pDialog->SetTitle(L"选择 UE4SS mod 文件夹");

    hr = pDialog->Show(hwnd);
    if (SUCCEEDED(hr)) {
        IShellItem* pItem = nullptr;
        if (SUCCEEDED(pDialog->GetResult(&pItem)) && pItem) {
            PWSTR pszPath = nullptr;
            if (SUCCEEDED(pItem->GetDisplayName(SIGDN_FILESYSPATH, &pszPath)) && pszPath) {
                out.push_back(WideToUtf8(pszPath));
                CoTaskMemFree(pszPath);
            }
            pItem->Release();
        }
    }
    pDialog->Release();
    return out;
}

/// 选择一个目录（UE4SS mod 已是文件夹形态时使用）。返回 UTF-8 路径。
/// 用户取消时返回空列表。
///
/// **关键修复（COM apartment）**：Flutter engine 的 MethodChannel handler
/// 跑在 binary messenger 线程（不是 GUI 线程）。main.cpp 用 OleInitialize
/// 把主线程设为 STA，worker 线程没初始化 COM apartment —— 在 worker 线程
/// 上调 CoCreateInstance 返回 RPC_E_WRONG_THREAD(0x8001010E)，IFileOpenDialog
/// 创建失败 → 用户点"选择文件夹"无任何反应。
///
/// 修复：先 IsGUIThread 检查；非 GUI 线程时把 dialog marshal 回主线程同步
/// 执行（modal dialog 本来就阻塞 UI，caller 线程同步等主线程不会让 UI
/// 卡更糟）。结果通过 SendMessage 的 lparam 携带 std::vector* 写回。
std::vector<std::string> OpenFolderDialog() {
    std::vector<std::string> result;
    if (!g_main_hwnd) return result;

    // 已经位于 GUI 线程（极少见 —— 通常 MethodChannel handler 不在 GUI），
    // 直接同步跑 dialog。
    if (IsGUIThread(TRUE)) {
        return RunFolderDialogOnMainThread(g_main_hwnd);
    }

    // 非 GUI 线程：marshal 回主线程。
    // 简单方案：用 SendMessage + 自定义消息 WM_USER + 0x100。
    // 主线程收到后直接同步跑 dialog，caller 线程等 SendMessage 返回。
    // 注：SendMessage 是同步调用 —— 主线程执行完 dialog 才让 caller
    // 继续走。dialog 阻塞主线程若干秒不影响 caller 线程。
    static UINT s_runDialogMsg = 0;
    if (s_runDialogMsg == 0) {
        s_runDialogMsg = RegisterWindowMessageW(L"ScumModRunFolderDialog_v1");
    }

    // 把 dialog 调用的"舞台"交给主线程：把 result 指针塞 lparam。
    // 真正的 dialog 实现挂在 FlutterWindow::MessageHandler（见
    // flutter_window.cpp 中 s_runDialogMsg 的 case 分支）。
    SendMessageW(g_main_hwnd, s_runDialogMsg, 0,
                 reinterpret_cast<LPARAM>(&result));
    return result;
}

// 3c：单选图片文件对话框（限定 .png/.jpg/.jpeg/.webp）。
// 返回 0 或 1 个 UTF-8 路径。多选由 [OpenFileDialog] 提供，本方法刻意单选
// —— 背景图只需一张，Dart 端按单值处理避免歧义。
std::vector<std::string> OpenImageDialog() {
    std::vector<std::string> result;
    if (!g_main_hwnd) return result;

    wchar_t buffer[MAX_PATH] = {0};  // 单选不需要 4096 大 buffer。
    OPENFILENAMEW ofn = {0};
    ofn.lStructSize = sizeof(OPENFILENAMEW);
    ofn.hwndOwner = g_main_hwnd;
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = sizeof(buffer) / sizeof(wchar_t);
    ofn.lpstrFilter = L"Image Files (*.png;*.jpg;*.jpeg;*.webp)\0"
                      L"*.png;*.jpg;*.jpeg;*.webp\0"
                      L"All Files (*.*)\0*.*\0";
    ofn.nFilterIndex = 1;
    // 单选：不带 OFN_ALLOWMULTISELECT。
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER;

    if (GetOpenFileNameW(&ofn)) {
        result.push_back(WideToUtf8(buffer));
    }
    return result;
}

// ── C1 Mica 系统级背景 ──
//
// Win11 22H2+ (build 22621) 通过 DWMWA_SYSTEMBACKDROP_TYPE 设置 Mica。
// DWMWA_SYSTEMBACKDROP_TYPE / DWMSBT_MAINWINDOW 在旧 SDK 未定义，手动声明。
// 返回值：
//   true  = Mica 已启用（Dart 端可以把背景设透明让桌面磨砂透过来）
//   false = OS 不支持 Mica（Dart 端应该用半透明黑叠层兜底，模拟"亚克力"）

#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMSBT_MAINWINDOW
#define DWMSBT_MAINWINDOW 2
#endif

bool EnableMica(bool isDark) {
    if (!g_main_hwnd) return false;

    // DWMWA_USE_IMMERSIVE_DARK_MODE：必须按当前应用主题设置，否则 Mica
    // 会始终渲染为系统默认（暗色），主人切到亮色时背景还是黑色。
    // - isDark=true  → 暗色 Mica（深色透出桌面）
    // - isDark=false → 亮色 Mica（浅色透出桌面）
    BOOL enable_dark = isDark ? TRUE : FALSE;
    ::DwmSetWindowAttribute(g_main_hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                            &enable_dark, sizeof(enable_dark));

    // Mica 主体：设置 DWMSBT_MAINWINDOW。
    // 不支持的 OS 会返回 E_INVALIDARG / E_NOTIMPL。
    DWORD backdrop = DWMSBT_MAINWINDOW;
    HRESULT hr = ::DwmSetWindowAttribute(
        g_main_hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
        &backdrop, sizeof(backdrop));
    return SUCCEEDED(hr);
}

// ===== MethodChannel 处理 =====

static void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "minimize") {
        Minimize();
        result->Success();
    } else if (method == "maximize") {
        ToggleMaximize();
        result->Success();
    } else if (method == "close") {
        CloseWindow();
        result->Success();
    } else if (method == "isMaximized") {
        result->Success(flutter::EncodableValue(IsWindowMaximized()));
    } else if (method == "getDroppedFiles") {
        result->Success(EncodeStringList(DrainDroppedFilesImpl()));
    } else if (method == "openFileDialog") {
        result->Success(EncodeStringList(OpenFileDialog()));
    } else if (method == "enableMica") {
        // C1：探测并启用 Win11 22H2+ 系统级 Mica 背景。
        // 返回 bool 给 Dart：Dart 据此决定背景是透明（Mica 真透）还是
        // 半透明黑叠层（亚克力 fallback）。
        //
        // 参数：{"isDark": bool} —— 当前应用主题是否暗色。
        // Mica 必须按应用主题设暗/亮标题栏，否则主人切亮色时 Mica 仍
        // 渲染暗色（DWM 系统层面），导致 Dart 透明背景看起来还是黑色。
        bool isDark = true; // 兼容旧调用：未传 isDark 默认当暗色。
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("isDark"));
            if (it != args->end()) {
                if (auto* b = std::get_if<bool>(&it->second)) {
                    isDark = *b;
                }
            }
        }
        result->Success(flutter::EncodableValue(EnableMica(isDark)));
    } else if (method == "openImageDialog") {
        // 3c：单选图片文件对话框（.png/.jpg/.jpeg/.webp）。
        result->Success(EncodeStringList(OpenImageDialog()));
    } else if (method == "openFolderDialog") {
        // UE4SS mod：用户拖入文件夹后未解压时的备选——让用户从对话框选目录。
        result->Success(EncodeStringList(OpenFolderDialog()));
    } else {
        result->NotImplemented();
    }
}

void Register(HWND main_hwnd, flutter::BinaryMessenger* messenger) {
    g_main_hwnd = main_hwnd;
    g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "com.scummod/window",
        &flutter::StandardMethodCodec::GetInstance());
    g_channel->SetMethodCallHandler(HandleMethodCall);
}

void Shutdown() {
    if (g_channel) {
        g_channel->SetMethodCallHandler(nullptr);
        g_channel.reset();
    }
    g_main_hwnd = nullptr;
}

void AppendDroppedFile(const std::string& utf8_path) {
    g_drop_queue.push_back(utf8_path);
}

void DrainDroppedFiles(std::vector<std::string>& out) {
    out.swap(g_drop_queue);
}

}  // namespace window_service