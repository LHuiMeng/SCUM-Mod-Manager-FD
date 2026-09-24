#pragma warning(disable:4819)
#include "launcher_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <process.h>   // _beginthreadex
#include <string>
#include <vector>

// LauncherService MethodChannel — game process management.
//
// Channel name: com.scummod/launcher
// Supported methods:
//   - launchGame({exePath, args}) -> {success, pid}
//   - killGame()                  -> {success, async}    异步发起关闭，不阻塞调用方
//   - isGameRunning()             -> bool                进程是否仍在运行
//   - killResult()                -> bool                最近一次 killGame 是否最终成功
//   - confirmAppExit()            -> void                Dart 端确认可以安全退程序时调
//
// Critical note: CreateProcessW MUST set lpCurrentDirectory to the exe's
// parent directory, otherwise the child process inherits the manager's
// working directory and DLL loading fails (error 126 / MODULE_NOT_FOUND).
//
// Kill 异步化设计：
// 旧版 killGame 在 MethodChannel 线程上做 WaitForSingleObject 最多 5 秒，
// 直接卡死 Flutter GUI 线程（点击「关闭」后整个 UI 无响应直到 kill 返回）。
// 改为：点击立即把 kill 任务丢到 worker 线程（_beginthreadex），主线程
// 立刻返回 {async:true}。Dart 端进入「关闭中…」态，由 isGameRunning 轮询
// 检测到进程真正退出，再触发 reclaimMods 回收 PAK。

namespace launcher_channel {

// ===== 内部状态 =====

// 当前游戏进程句柄（lock_guard<std::mutex> g_process_mutex 保护）。
//
// **句柄所有权（v2.6+）**：
// 1. 创建者：LaunchGameImpl 创建进程 → 把 pi.hProcess 写到 g_game_process。
//    旧句柄（如有）转入 g_process_to_release。
// 2. 释放者：
//    - KillWorkerThread 杀完进程后 CloseHandle(proc)。
//    - IsGameRunning **不动**句柄（只读）。
//    - launchGame 启动新进程时清理上一轮的 g_process_to_release（如果还在）。
//    - Shutdown 强杀 live + 释放 dead。
//
// **历史 bug**：旧版 IsGameRunningImpl 也会 CloseHandle + 置 null g_game_process，
// 与 worker 抢同一句柄 → 双重释放 → 句柄泄漏 + 后续 launchGame 拿到旧句柄
// 误判老进程 STILL_ACTIVE → 死循环"游戏被关了又被启了又被关"。
static HANDLE g_game_process = nullptr;

// 待释放的句柄（进程已退出但还没 CloseHandle）。
// launchGame / Shutdown 是唯一 CloseHandle 这里的地方。
static HANDLE g_process_to_release = nullptr;

static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_channel;

// 最近一次 kill 操作的结果（异步线程写入，调用方读取）。
// true = 进程已退出（优雅退出或强杀成功），false = 强杀失败。
// 初始 true —— 没发起过 kill 时不算失败，避免 UI 误判。
static std::atomic<bool> g_last_kill_success{true};

// 是否正在执行 kill 任务（用于防止重复发起）。
static std::atomic<bool> g_kill_in_flight{false};

// 主窗口 HWND —— 由 FlutterWindow::OnCreate 时调用 [SetMainHwnd] 注入。
// confirmAppExit() 用它调 DestroyWindow。
static HWND g_main_hwnd = nullptr;

// 应用退出流程状态：
//   - idle: 正常状态，没有退出请求。
//   - pending: Dart 端正在做安全清理（kill + reclaim），收到 confirmAppExit 后才真正退出。
//   - confirmed: 已收到 Dart 的 confirmAppExit，正在 DestroyWindow。
// 用 atomic 防止 C++ 主线程和 MethodChannel 线程竞争。
enum class AppExitState : int { idle = 0, pending = 1, confirmed = 2 };
static std::atomic<int> g_app_exit_state{static_cast<int>(AppExitState::idle)};

// 保护 g_game_process 句柄所有权转移：worker 线程关闭时会把它置 nullptr，
// 同时 isGameRunning 检查也会在进程退出分支置 nullptr。用 mutex 串行化，
// 避免 worker 还在用句柄时另一个线程 CloseHandle 了。
static std::mutex g_process_mutex;

// ===== 内部工具函数 =====

static std::wstring Utf8ToWide(const std::string& utf8) {
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1,
                                   nullptr, 0);
    if (wlen <= 0) return std::wstring();
    std::wstring wstr(wlen, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wstr[0], wlen);
    if (!wstr.empty() && wstr.back() == L'\0') wstr.pop_back();
    return wstr;
}

/// 查找指定 PID 的可见主窗口（跳过 WS_EX_TOOLWINDOW）。
/// 前置声明：LaunchGameImpl 在 worker 之前调用，需要先看到本函数。
static HWND FindMainWindow(DWORD pid);

// ===== 游戏进程管理 =====

/// 启动游戏/服务端进程。
///
/// [exePath] 完整 exe 路径。
/// [args] 命令行参数列表。
/// 把字符串转义为 Windows CommandLineToArgvW 兼容形式：内部 `"` 转为 `\"`，
/// 外部包一层双引号。修复旧版直接把 `exePath` 用 `"..."` 包起来 —— 路径含
/// `"` 时会被提前关闭（C++ 端 LaunchGame 也有同样风险，对应
/// window_service_channel.cpp 的 QuoteArg；这里复用相同转义规则）。
static std::string QuoteCmdLineArg(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out.push_back('"');
    for (char c : s) {
        if (c == '"') out.push_back('\\');
        out.push_back(c);
    }
    out.push_back('"');
    return out;
}

/// 返回 {success: bool, pid: int}。
static flutter::EncodableValue LaunchGameImpl(
    const std::string& exePath,
    const std::vector<std::string>& args) {
    // 构建命令行字符串 —— 每个参数都走 QuoteCmdLineArg 转义内部双引号。
    std::string cmdLine = QuoteCmdLineArg(exePath);
    for (const auto& a : args) {
        cmdLine += ' ';
        cmdLine += QuoteCmdLineArg(a);
    }

    // 提取 exe 所在目录作为工作目录（防止 DLL 加载失败）。
    std::string::size_type pos = exePath.find_last_of("\\/");
    std::string workDir = (pos != std::string::npos)
                              ? exePath.substr(0, pos)
                              : ".";

    std::wstring wCmdLine = Utf8ToWide(cmdLine);
    std::wstring wWorkDir = Utf8ToWide(workDir);

    // 清理上一次 kill 留下的"待释放句柄"（如果有）。
    //
    // launchGame 是新进程的入口：必须先把上一次 kill 留下的句柄
    // 释放掉（否则 Shutdown 时累积泄漏）。同时清掉 g_game_process。
    //
    // 正常情况：g_process_to_release 非 null（worker 留的），g_game_process
    // 已为 null（worker 已清）。异常情况：用户绕过 Dart UI 状态机在 closing
    // 期间强行 launchGame —— g_game_process 仍指向老进程。
    //
    // 修复（v2.x+）：旧版不分青红皂白给 to_close 调 TerminateProcess +
    // WaitForSingleObject —— 如果 to_close == g_process_to_release（worker
    // 已 CloseHandle 过的死句柄），TerminateProcess(死句柄) 在 Windows 内核
    // 会返回 ERROR_INVALID_HANDLE 但语义错位；WaitForSingleObject 对死句柄
    // 返回 WAIT_FAILED —— 错误码全被吞掉。
    // 正确语义：g_process_to_release 是**已死**句柄，只需要 CloseHandle；
    // g_game_process 才是**活**进程，需要先 WM_CLOSE 友好通知 → 5s wait →
    // 兜底 TerminateProcess（与 worker 走同套优雅关闭）。
    HANDLE dead_to_release = nullptr;
    HANDLE live_to_kill = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        dead_to_release = g_process_to_release;
        g_process_to_release = nullptr;
        if (g_game_process) {
            live_to_kill = g_game_process;
            g_game_process = nullptr;
        }
    }
    // 已死的句柄 —— 只需要 CloseHandle 释放资源，**不再调 TerminateProcess**。
    if (dead_to_release) {
        CloseHandle(dead_to_release);
    }
    // 活的进程（异常路径下绕过 UI 进来的 launchGame）—— 走优雅关闭。
    if (live_to_kill) {
        // 先 PostMessage WM_CLOSE 友好通知（如果能拿到主窗口句柄）。
        const DWORD pid = GetProcessId(live_to_kill);
        if (pid != 0) {
            HWND mainWnd = FindMainWindow(pid);
            if (mainWnd != nullptr) {
                PostMessage(mainWnd, WM_CLOSE, 0, 0);
                WaitForSingleObject(live_to_kill, 5000);
            }
        }
        // 超时或拿不到窗口 → 兜底强杀。
        DWORD exitCode = 0;
        if (!GetExitCodeProcess(live_to_kill, &exitCode) ||
            exitCode == STILL_ACTIVE) {
            TerminateProcess(live_to_kill, 1);
            WaitForSingleObject(live_to_kill, 100);
        }
        CloseHandle(live_to_kill);
    }

    STARTUPINFOW si = {sizeof(STARTUPINFOW)};
    PROCESS_INFORMATION pi = {0};

    // 关键：CreateProcessW 的 lpCurrentDirectory 必须指向 exe 所在目录，
    // 否则子进程 DLL 加载会失败（error 126）。
    BOOL ok = CreateProcessW(
        nullptr,               // lpApplicationName（使用命令行第一个 token）
        &wCmdLine[0],          // lpCommandLine（可修改的缓冲区）
        nullptr,               // lpProcessAttributes
        nullptr,               // lpThreadAttributes
        FALSE,                 // bInheritHandles
        0,                     // dwCreationFlags
        nullptr,               // lpEnvironment
        wWorkDir.c_str(),      // lpCurrentDirectory ← 必须设置！
        &si,                   // lpStartupInfo
        &pi);                  // lpProcessInformation

    if (!ok) {
        DWORD err = GetLastError();
        flutter::EncodableMap result;
        result[flutter::EncodableValue("success")] =
            flutter::EncodableValue(false);
        result[flutter::EncodableValue("pid")] =
            flutter::EncodableValue(static_cast<int>(err));
        return flutter::EncodableValue(result);
    }

    // 保存新进程句柄。CloseHandle 线程句柄（不需要）。
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        g_game_process = pi.hProcess;
    }
    DWORD pid = pi.dwProcessId;
    CloseHandle(pi.hThread);

    flutter::EncodableMap result;
    result[flutter::EncodableValue("success")] =
        flutter::EncodableValue(true);
    result[flutter::EncodableValue("pid")] =
        flutter::EncodableValue(static_cast<int>(pid));
    return flutter::EncodableValue(result);
}

/// 查找指定 PID 的可见主窗口（跳过 WS_EX_TOOLWINDOW 工具窗口）。
///
/// 用于优雅关闭：先向游戏主窗口 PostMessage(WM_CLOSE)，
/// 让 UE 走正常退出流程（有机会 flush 存档），而不是直接 TerminateProcess。
static HWND FindMainWindow(DWORD pid) {
    struct EnumCtx {
        DWORD pid;
        HWND hwnd;
    };
    EnumCtx ctx = {pid, nullptr};
    EnumWindows(
        [](HWND h, LPARAM lp) -> BOOL {
            auto* c = reinterpret_cast<EnumCtx*>(lp);
            DWORD windowPid = 0;
            GetWindowThreadProcessId(h, &windowPid);
            if (windowPid != c->pid) return TRUE;  // 继续枚举
            if (!IsWindowVisible(h)) return TRUE;
            if (GetWindowLongPtr(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) {
                return TRUE;
            }
            c->hwnd = h;
            return FALSE;  // 找到第一个主窗口，停止枚举
        },
        reinterpret_cast<LPARAM>(&ctx));
    return ctx.hwnd;
}

/// 结束游戏进程 —— worker 线程函数。
///
/// 在独立线程里做完整 kill 流程（优雅关闭 + 兜底强杀），主线程立刻返回。
/// 流程：
/// 1. 在锁内把 g_game_process 置 nullptr（让 launchGame 知道无进程在跑）
/// 2. 发 WM_CLOSE → 等 5 秒
/// 3. 超时 → TerminateProcess 兜底
/// 4. 完成后 worker 自己 CloseHandle —— 句柄生命周期归 worker 管。
///
/// **关键修复（v2.6+）**：
/// 旧版 worker 与 isGameRunning 都在 CloseHandle 同一个 HANDLE，
/// 导致句柄双重释放 → 进程对象泄漏 → 后续 launchGame 拿到旧句柄
/// 误以为老进程 STILL_ACTIVE → 死循环"游戏被关了又被启了又被关"。
/// 玩家体感就是游戏被关了过一会又被启动了又被关闭了。
///
/// 现在句柄所有权分三方：
/// - launchGame：创建新句柄（写 g_game_process）
/// - worker：杀进程 + CloseHandle 自己手上的句柄
/// - launchGame（下次）/ Shutdown：处理 g_process_to_release 的句柄
/// - IsGameRunning：只读，不动句柄
static unsigned __stdcall KillWorkerThread(void* /*arg*/) {
    HANDLE proc;
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        proc = g_game_process;
        if (!proc) {
            // 没有进程或已被 launchGame/Shutdown 处理过。
            g_last_kill_success.store(true);
            g_kill_in_flight.store(false);
            return 0;
        }
        // 解 launchGame 的锁：让"用户立即重新启动"被允许（但 UI 状态机
        // 在 Dart 端已经禁掉了按钮，这里只是保险）。
        g_game_process = nullptr;
    }

    // 1) 进程已经退出（自然退出或前面轮询已经发现）。
    bool exited = (WaitForSingleObject(proc, 0) == WAIT_OBJECT_0);

    if (!exited) {
        // 2) 优雅关闭：向游戏主窗口发 WM_CLOSE。
        const DWORD pid = GetProcessId(proc);
        const HWND main_wnd = pid ? FindMainWindow(pid) : nullptr;
        if (main_wnd != nullptr) {
            PostMessage(main_wnd, WM_CLOSE, 0, 0);
        }
        exited = (WaitForSingleObject(proc, 5000) == WAIT_OBJECT_0);
    }

    if (!exited) {
        // 3) 兜底强杀（游戏无窗口 / 5 秒内未响应 WM_CLOSE）。
        TerminateProcess(proc, 1);
        WaitForSingleObject(proc, 100);  // 等待进程结束。
    }

    // 4) worker 自己做 CloseHandle —— 句柄生命周期归 worker 管，
    //    避免与 Shutdown / launchGame 抢同一句柄导致双重释放。
    CloseHandle(proc);

    g_last_kill_success.store(true);
    g_kill_in_flight.store(false);
    return 0;
}

/// 异步发起 kill —— 立即返回 {async: true}，不等 worker。
///
/// 返回 flutter::EncodableMap 含 success 和 async 两个字段：
/// - success: 是否成功发起（无进程 / 已经在 kill 中 → false）
/// - async:   是否为异步操作（始终 true）
///
/// Dart 端 UI 立刻切到「关闭中…」态，由轮询检测进程退出后触发 reclaim。
static flutter::EncodableValue KillGameAsync() {
    bool expected = false;
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        if (!g_game_process) {
            // 没有进程可关闭。
            flutter::EncodableMap r;
            r[flutter::EncodableValue("success")] = flutter::EncodableValue(false);
            r[flutter::EncodableValue("async")] = flutter::EncodableValue(true);
            return flutter::EncodableValue(r);
        }
    }
    if (!g_kill_in_flight.compare_exchange_strong(expected, true)) {
        // 已经有 kill 在执行，避免 worker 重入。
        flutter::EncodableMap r;
        r[flutter::EncodableValue("success")] = flutter::EncodableValue(false);
        r[flutter::EncodableValue("async")] = flutter::EncodableValue(true);
        return flutter::EncodableValue(r);
    }

    // 启动 worker 线程，立刻返回。
    uintptr_t thd = _beginthreadex(
        nullptr, 0, KillWorkerThread, nullptr, 0, nullptr);
    if (thd == 0) {
        // 启动失败（OS 资源耗尽 / 线程数上限）—— 不能简单 reset 标志位
        // 然后返回 success=true：worker 根本没跑，Dart waitKillDone 会
        // 立即看到 g_kill_in_flight==false 返回 success，但实际没人 kill 游戏。
        // Dart 端接着调 reclaim → 删 PAK → 游戏 crash。
        //
        // 修复：同步在调用线程做 TerminateProcess（user 已经点等，UI 等
        // 几秒可以接受），置 g_last_kill_success=false，返回 success=true
        // 告诉 Dart "已发起"，让 Dart 走正常 reclaim 流程。
        HANDLE to_kill = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_process_mutex);
            to_kill = g_game_process;
            g_game_process = nullptr;
        }
        if (to_kill) {
            TerminateProcess(to_kill, 1);
            WaitForSingleObject(to_kill, 5000);
            CloseHandle(to_kill);
            g_last_kill_success.store(false);  // 同步强杀 = 标记失败
        }
        g_kill_in_flight.store(false);
        flutter::EncodableMap r;
        r[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
        r[flutter::EncodableValue("async")] = flutter::EncodableValue(false);
        return flutter::EncodableValue(r);
    }
    // 不需要 join —— 线程自行结束，关闭句柄避免句柄泄漏。
    CloseHandle(reinterpret_cast<HANDLE>(thd));

    g_last_kill_success.store(false);  // 初始：worker 还没跑完。

    flutter::EncodableMap r;
    r[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
    r[flutter::EncodableValue("async")] = flutter::EncodableValue(true);
    return flutter::EncodableValue(r);
}

/// 读取最近一次 kill 操作的最终结果。
static bool KillResultImpl() {
    return g_last_kill_success.load();
}

/// 等待最近一次 kill 真正完成（worker 线程退出），最多 [timeoutMs] ms。
///
/// 返回：
/// - true  = worker 已在 timeout 内完成（结果可由 [KillResultImpl] 读）
/// - false = 超时（worker 可能还在跑，调用方决定是否兜底强杀）
///
/// 用于 App 退出路径：必须确认游戏进程被杀干净了，才能 reclaim + DestroyWindow。
/// 旧版 Dart 端用 isGameRunning 轮询 10s 兜底超时 → 实际游戏进程根本没退就
/// reclaim + destroyWindow → GUI 没了但游戏进程还在桌面跑（用户报告的现象）。
///
/// 实现：Dart 端调 killGame 后立刻调 waitKillDone。worker 完成后会
/// g_kill_in_flight.store(false)，这里原子读即可。
static bool WaitKillDoneImpl(int timeoutMs) {
    const int tickMs = 100;
    int waited = 0;
    while (waited < timeoutMs) {
        if (!g_kill_in_flight.load()) return true;
        Sleep(tickMs);
        waited += tickMs;
    }
    return !g_kill_in_flight.load();
}

/// 检查游戏进程是否仍在运行。
///
/// **只读**：不动 g_game_process / g_process_to_release 所有权。
///
/// 设计要点：
/// - 老版 IsGameRunning 会改 g_game_process=nullptr + CloseHandle，与 worker
///   抢同一句柄造成双重释放 → 句柄泄漏 → launchGame 用旧句柄误判老进程
///   STILL_ACTIVE → 死循环"游戏被关了又被启了又被关"。
/// - 修复：IsGameRunning 只读句柄判断 alive/dead，不动所有权。
/// - 句柄所有权规则：
///   - 创建者：launchGame 写 g_game_process
///   - 释放者 1：KillWorkerThread 杀完后 CloseHandle(proc)（自己持有的）
///   - 释放者 2：launchGame 启动新进程时 CloseHandle(g_process_to_release)
///   - 释放者 3：Shutdown 兜底释放所有残留
static bool IsGameRunningImpl() {
    HANDLE proc;
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        proc = g_game_process;
    }
    if (!proc) return false;
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(proc, &exitCode)) {
        return false;  // 句柄不可用 → 视为已退出
    }
    return exitCode == STILL_ACTIVE;
}

// ===== MethodChannel 处理 =====

static void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "launchGame") {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
            result->Error("INVALID_ARGS", "launchGame expects a map");
            return;
        }

        // 提取 exePath。
        auto exeIt = args->find(flutter::EncodableValue("exePath"));
        if (exeIt == args->end()) {
            result->Error("MISSING_EXE", "exePath is required");
            return;
        }
        std::string exePath;
        if (auto* s = std::get_if<std::string>(&exeIt->second)) {
            exePath = *s;
        } else {
            result->Error("INVALID_EXE", "exePath must be a string");
            return;
        }

        // 提取 args 列表。
        std::vector<std::string> argList;
        auto argsIt = args->find(flutter::EncodableValue("args"));
        if (argsIt != args->end()) {
            if (auto* argArr = std::get_if<std::vector<flutter::EncodableValue>>(
                    &argsIt->second)) {
                for (const auto& arg : *argArr) {
                    if (auto* s = std::get_if<std::string>(&arg)) {
                        argList.push_back(*s);
                    }
                }
            }
        }

        result->Success(LaunchGameImpl(exePath, argList));

    } else if (method == "killGame") {
        // 异步 kill —— 立刻返回 {success, async}，由 Dart 端 UI 切到
        // 「关闭中…」态并通过 isGameRunning 轮询检测进程真正退出。
        result->Success(KillGameAsync());

    } else if (method == "killResult") {
        // 查询最近一次 kill 的最终结果（worker 线程完成后才能拿到 true）。
        result->Success(flutter::EncodableValue(KillResultImpl()));

    } else if (method == "waitKillDone") {
        // 等待最近一次 kill 真正完成（worker 退出），最多 timeoutMs。
        int timeoutMs = 30000;  // 默认 30 秒（SCUM 正常退出可能 10-30s）
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("timeoutMs"));
            if (it != args->end()) {
                if (auto* i = std::get_if<int>(&it->second)) {
                    timeoutMs = *i;
                }
            }
        }
        bool done = WaitKillDoneImpl(timeoutMs);
        result->Success(flutter::EncodableValue(done));

    } else if (method == "isGameRunning") {
        result->Success(flutter::EncodableValue(IsGameRunningImpl()));

    } else if (method == "confirmAppExit") {
        // Dart 端安全清理完成 → 真正销毁窗口。
        // 把状态置为 confirmed，RequestAppExit 检测到后会 DestroyWindow。
        g_app_exit_state.store(static_cast<int>(AppExitState::confirmed));
        if (g_main_hwnd) {
            // 直接 PostMessage 让 WM_CLOSE 路径处理，触发原生窗口关闭流程。
            PostMessage(g_main_hwnd, WM_CLOSE, 0, 0);
        }
        result->Success();

    } else {
        result->NotImplemented();
    }
}

// ===== 注册/注销 =====

void Register(flutter::BinaryMessenger* messenger) {
    g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "com.scummod/launcher",
        &flutter::StandardMethodCodec::GetInstance());
    g_channel->SetMethodCallHandler(HandleMethodCall);
}

/// 注入主窗口 HWND —— FlutterWindow::OnCreate 时调用一次。
///
/// confirmAppExit 需要 HWND 来 PostMessage(WM_CLOSE)。
void SetMainHwnd(HWND hwnd) {
    g_main_hwnd = hwnd;
}

/// 用户请求退出 App（如点击窗口 X 按钮）。
///
/// 返回值：
/// - true  = 已经通知 Dart 做清理（异步），调用方应**不要**直接 DestroyWindow，
///           等待 Dart 调 confirmAppExit 后再 destroy。
/// - false = Dart 已确认可退出，可立即 DestroyWindow。
///
/// 调用方应在 WM_SYSCOMMAND/SC_CLOSE 处理里调一次本函数，根据返回值决定
/// 是直接 destroy 还是等待 Dart confirmAppExit。
bool RequestAppExit() {
    int expected = static_cast<int>(AppExitState::idle);
    if (g_app_exit_state.compare_exchange_strong(expected,
            static_cast<int>(AppExitState::pending))) {
        // idle → pending 转移成功，说明 Dart 还没在做安全清理。
        // 通过 MethodChannel 通知 Dart「用户请求退出 App」。
        if (g_channel) {
            g_channel->InvokeMethod("onAppExitRequest", nullptr);
        }
        return true;  // 调用方应等待 Dart confirmAppExit
    }
    // 状态不是 idle：要么 pending（Dart 正在清理），要么 confirmed（Dart 已确认）。
    if (g_app_exit_state.load() == static_cast<int>(AppExitState::confirmed)) {
        return false;  // Dart 已经确认，调用方可以直接 destroy
    }
    // pending：忽略重复请求
    return true;
}

void Shutdown() {
    // 收集所有需要处理的句柄：
    // - live_proc：还活着的进程 → TerminateProcess + CloseHandle
    // - dead_handle：已退出但未释放的句柄 → 仅 CloseHandle
    // 注：worker 自己的句柄（local proc）由 worker 自己 CloseHandle，
    // 不会走 g_process_to_release —— 因为新版 worker 直接 CloseHandle 自己的句柄。
    HANDLE live_proc = nullptr;
    HANDLE dead_handle = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_process_mutex);
        live_proc = g_game_process;
        dead_handle = g_process_to_release;
        g_game_process = nullptr;
        g_process_to_release = nullptr;
    }
    // 1) 终止活进程。
    if (live_proc) {
        TerminateProcess(live_proc, 1);
        WaitForSingleObject(live_proc, 100);
        CloseHandle(live_proc);
    }
    // 2) 关闭已退出进程的待释放句柄。
    if (dead_handle && dead_handle != live_proc) {
        CloseHandle(dead_handle);
    }
    // 复位 kill 标志位 —— 防止下次启动时还残留 in-flight 状态。
    g_kill_in_flight.store(false);
    g_last_kill_success.store(true);
    g_app_exit_state.store(static_cast<int>(AppExitState::idle));
    g_main_hwnd = nullptr;
    if (g_channel) {
        g_channel->SetMethodCallHandler(nullptr);
        g_channel.reset();
    }
}

}  // namespace launcher_channel