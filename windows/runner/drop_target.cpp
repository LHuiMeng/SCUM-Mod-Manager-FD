#pragma warning(disable:4819)
#include "drop_target.h"

#include <cstdio>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "window_service_channel.h"

namespace {

// Tracks the Flutter engine messenger so DropTarget can push events back.
// Set once when the main window registers its drop target. Single messenger
// for the lifetime of the process is fine.
flutter::BinaryMessenger* g_messenger = nullptr;

// The channel name Dart subscribes to (push events from C++ -> Dart).
constexpr const char* kDragChannel = "com.scummod/drag";

// Cache the (messenger, channel) pair. The channel is rebuilt whenever the
// messenger pointer changes (e.g. across engine restarts).
flutter::BinaryMessenger* g_channel_messenger = nullptr;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

flutter::MethodChannel<flutter::EncodableValue>* DragChannel() {
  if (g_messenger != g_channel_messenger) {
    g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        g_messenger, kDragChannel,
        &flutter::StandardMethodCodec::GetInstance());
    g_channel_messenger = g_messenger;
  }
  return g_channel.get();
}

void InvokeOnDart(const std::string& method) {
  if (!g_messenger) return;
  auto ch = DragChannel();
  ch->InvokeMethod(method,
                   std::unique_ptr<flutter::EncodableValue>(),
                   nullptr);
}

void InvokeFilesOnDart(const std::vector<std::string>& paths) {
  if (!g_messenger) return;
  flutter::EncodableList list;
  list.reserve(paths.size());
  for (const auto& p : paths) {
    list.push_back(flutter::EncodableValue(p));
  }
  auto ch = DragChannel();
  ch->InvokeMethod("onDroppedFiles",
                   std::make_unique<flutter::EncodableValue>(std::move(list)),
                   nullptr);
}

// 把宽字符路径转 UTF-8。空路径返回空串。
std::string WidePathToUtf8(const wchar_t* path) {
  if (!path || !*path) return std::string();
  int utf8_len = WideCharToMultiByte(CP_UTF8, 0, path, -1,
                                     nullptr, 0, nullptr, nullptr);
  if (utf8_len <= 0) return std::string();
  std::string utf8(utf8_len, 0);
  WideCharToMultiByte(CP_UTF8, 0, path, -1, &utf8[0],
                      utf8_len, nullptr, nullptr);
  if (!utf8.empty() && utf8.back() == '\0') utf8.pop_back();
  return utf8;
}

}  // namespace

DropTarget::DropTarget()
    : ref_count_(1), drag_active_(false) {}

DropTarget::~DropTarget() = default;

HRESULT __stdcall DropTarget::QueryInterface(REFIID riid, void** ppv) {
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *ppv = this;
    AddRef();
    return S_OK;
  }
  *ppv = nullptr;
  return E_NOINTERFACE;
}

ULONG __stdcall DropTarget::AddRef() {
  return InterlockedIncrement(reinterpret_cast<volatile LONG*>(&ref_count_));
}

ULONG __stdcall DropTarget::Release() {
  ULONG ref = InterlockedDecrement(reinterpret_cast<volatile LONG*>(&ref_count_));
  if (ref == 0) {
    delete this;
  }
  return ref;
}

HRESULT __stdcall DropTarget::DragEnter(IDataObject* pDataObj,
                                        DWORD grfKeyState, POINTL pt,
                                        DWORD* pdwEffect) {
  // 先格式预检：只有 CF_HDROP（资源管理器文件拖入）才接受。
  // 旧版直接接 → 浏览器拖入 text/uri-list 时 DragEnter 通知 Dart 进入
  // "接收"态，但 Drop 时 ExtractFilePaths 拿不到 CF_HDROP → paths 空 →
  // UI 显示"放入 0 项"，误进入态浪费一次重绘。
  if (pDataObj == nullptr) {
    *pdwEffect = DROPEFFECT_NONE;
    return E_POINTER;
  }
  FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  if (pDataObj->QueryGetData(&fmt) != S_OK) {
    // 不是文件拖入（可能是文字 / 图片 / URL 等），拒绝并通知 Dart 不进入接收态。
    *pdwEffect = DROPEFFECT_NONE;
    drag_active_ = false;
    return S_OK;
  }
  // Accept the drag (DROPEFFECT_COPY means "we'll handle a copy").
  *pdwEffect = DROPEFFECT_COPY;
  drag_active_ = true;
  NotifyDartDragEnter();
  return S_OK;
}

HRESULT __stdcall DropTarget::DragOver(DWORD grfKeyState, POINTL pt,
                                       DWORD* pdwEffect) {
  *pdwEffect = DROPEFFECT_COPY;
  return S_OK;
}

HRESULT __stdcall DropTarget::DragLeave() {
  drag_active_ = false;
  NotifyDartDragLeave();
  return S_OK;
}

HRESULT __stdcall DropTarget::Drop(IDataObject* pDataObj, DWORD grfKeyState,
                                   POINTL pt, DWORD* pdwEffect) {
  *pdwEffect = DROPEFFECT_COPY;
  drag_active_ = false;

  auto paths = ExtractFilePaths(pDataObj);
  // 只 push 到 drag channel —— 不要 AppendDroppedFile 进 window service 的
  // 队列。dart 端的 _onDroppedFiles 已经能处理导入；双重路径会让 window
  // queue 永远累积污染（getDroppedFiles drain 时会拿到历史拖入文件）。
  NotifyDartDroppedFiles(paths);
  return S_OK;
}

// 不区分大小写比较后缀：path 是否以 suffix 结尾。
static bool EndsWithIcase(const std::wstring& path, const wchar_t* suffix) {
  size_t plen = path.size();
  size_t slen = wcslen(suffix);
  if (plen < slen) return false;
  for (size_t i = 0; i < slen; ++i) {
    wchar_t a = path[plen - slen + i];
    wchar_t b = suffix[i];
    if (a >= L'A' && a <= L'Z') a = (wchar_t)(a - L'A' + L'a');
    if (b >= L'A' && b <= L'Z') b = (wchar_t)(b - L'A' + L'a');
    if (a != b) return false;
  }
  return true;
}

std::vector<std::string> DropTarget::ExtractFilePaths(IDataObject* pDataObj) {
  std::vector<std::string> result;
  if (!pDataObj) return result;

  // CF_HDROP is the format Explorer uses for file drops.
  FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM stg = {0};
  if (FAILED(pDataObj->GetData(&fmt, &stg))) return result;

  HDROP hDrop = static_cast<HDROP>(stg.hGlobal);
  if (!hDrop) {
    ReleaseStgMedium(&stg);
    return result;
  }

  UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; i++) {
    wchar_t path[MAX_PATH];
    if (DragQueryFileW(hDrop, i, path, MAX_PATH) == 0) continue;

    // ── 接受规则 ──
    // - .pak：标准 PAK mod（必须）。
    // - .zip：UE4SS mod 压缩包（Dart 端解压后判定是否为 UE4SS mod）。
    // - 目录（DragQueryFile 返回空扩展时）：UE4SS mod 已解压形态（Dart 端
    //   探测 dlls/LogicMods/Scripts/version.dll 等特征判定）。
    std::wstring wpath(path);
    bool accepted = false;
    if (EndsWithIcase(wpath, L".pak")) {
      accepted = true;
    } else if (EndsWithIcase(wpath, L".zip")) {
      accepted = true;
    } else if (GetFileAttributesW(path) & FILE_ATTRIBUTE_DIRECTORY) {
      accepted = true;
    }
    if (!accepted) continue;

    std::string utf8 = WidePathToUtf8(path);
    if (!utf8.empty()) result.push_back(std::move(utf8));
  }

  ReleaseStgMedium(&stg);
  return result;
}

// Static helpers -----

void DropTarget::NotifyDartDragEnter() {
  InvokeOnDart("onDragEnter");
}

void DropTarget::NotifyDartDragLeave() {
  InvokeOnDart("onDragLeave");
}

void DropTarget::NotifyDartDroppedFiles(const std::vector<std::string>& paths) {
  InvokeFilesOnDart(paths);
}

bool DropTarget::RegisterForWindow(HWND hwnd, IDropTarget** out_target) {
  if (!hwnd) return false;
  auto* target = new DropTarget();
  HRESULT hr = RegisterDragDrop(hwnd, target);
  if (FAILED(hr)) {
    // Surface OLE registration failures via OutputDebugString so DebugView
    // (or VS debugger) can pick them up. fprintf to stderr goes nowhere
    // because Windows GUI subsystem has no console attached by default.
    char buf[128];
    snprintf(buf, sizeof(buf),
             "[DropTarget] RegisterDragDrop failed: hr=0x%08lx hwnd=0x%p\n",
             (unsigned long)hr, (void*)hwnd);
    OutputDebugStringA(buf);
    target->Release();
    return false;
  }
  if (out_target) *out_target = target;
  return true;
}

// Public: called by FlutterWindow::OnCreate after the engine messenger is up.
void SetDragChannelMessenger(flutter::BinaryMessenger* messenger) {
  g_messenger = messenger;
}