// scum_mod_manager_updater.exe —— 在线更新的独立自替换工具（ZIP 解压版）。
//
// 用法（由 manager.exe 的 window_service_channel.cpp::LaunchUpdater 调用）：
//   scum_mod_manager_updater.exe
//     --target    <当前 manager.exe 所在目录>        ← 解压目标
//     --zip       <%TEMP%/scum_mod_manager.update.zip>
//     --backup    <目标目录>\scum_mod_manager.exe.bak  ← exe 回滚用
//     --parent-pid <manager.exe PID>
//
// 流程：
// 1. OpenProcess(parent_pid) + WaitForSingleObject(INFINITE) 等主进程退出
// 2. backup: MoveFileEx(target.exe → target.exe.bak) exe 回滚点
// 3. Extract: 调用 PowerShell Expand-Archive 把 ZIP 解压到目标目录（覆盖全部）
// 4. Rollback 逻辑：解压失败则从 .bak 还原 target.exe
// 5. CreateProcess(target.exe) — 启动新版
// 6. ExitProcess(0)
//
// 不依赖任何外部库（仅 kernel32 / shell32 / ole32）。

#include <windows.h>
#include <shellapi.h>
#include <cerrno>
#include <cwctype>
#include <string>
#include <vector>

static void Log(const std::wstring& msg) {
    wchar_t tempDir[MAX_PATH] = {0};
    if (!GetTempPathW(MAX_PATH, tempDir)) return;
    std::wstring path = std::wstring(tempDir) + L"scum_mod_manager_updater.log";
    HANDLE h = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                           FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t buf[1024];
    _snwprintf_s(buf, _TRUNCATE,
                 L"[%04d-%02d-%02d %02d:%02d:%02d] %s\n",
                 st.wYear, st.wMonth, st.wDay,
                 st.wHour, st.wMinute, st.wSecond,
                 msg.c_str());
    DWORD written = 0;
    WriteFile(h, buf, static_cast<DWORD>(wcslen(buf) * sizeof(wchar_t)),
              &written, nullptr);
    CloseHandle(h);
}

static bool WaitForParent(DWORD pid) {
    if (pid == 0) {
        // 没传 parentPid：可能主进程没走正常 confirmAppExit 流程
        // （如 _onAppExitRequest 里 reclaim 指数退避 60s 还没完，主进程没退）。
        // 这里不再无限等 —— 走 fallback 路径，让 MoveFileEx 自己处理句柄
        // 占用。MoveFileEx(MOVEFILE_REPLACE_EXISTING) 内部会等句柄释放。
        Log(L"no parentPid, proceeding without wait (fallback mode)");
        return true;
    }
    HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (h == nullptr) {
        Log(L"OpenProcess failed (parent may already be gone)");
        return true;
    }
    // 2.5.4 的退出回收可能超过固定时限；必须等待主进程真正结束，
    // 否则 app.so 仍被旧进程占用，解压后启动的仍可能是旧版本。
    Log(L"Waiting for parent PID " + std::to_wstring(pid) + L" to exit...");
    DWORD wait = WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
    if (wait == WAIT_OBJECT_0) {
        Log(L"Parent process exited cleanly");
        return true;
    }
    Log(L"WaitForSingleObject failed");
    return false;
}

/// file 是否位于 dir 之内（大小写不敏感的前缀比较）。
static bool IsInsideDir(const std::wstring& file, const std::wstring& dir) {
    if (dir.empty() || file.size() <= dir.size()) return false;
    for (size_t i = 0; i < dir.size(); ++i) {
        if (towlower(file[i]) != towlower(dir[i])) return false;
    }
    // 前缀吻合还要求下一字符是路径分隔符，避免 "C:\a" 误配 "C:\ab\x.exe"
    return file[dir.size()] == L'\\' || file[dir.size()] == L'/';
}

/// 去掉末尾的分隔符。
static std::wstring StripTrailingSep(std::wstring s) {
    while (!s.empty() && (s.back() == L'\\' || s.back() == L'/')) s.pop_back();
    return s;
}

static bool MoveFileAtomic(const std::wstring& src,
                           const std::wstring& dst) {
    return MoveFileExW(src.c_str(), dst.c_str(),
                       MOVEFILE_REPLACE_EXISTING |
                       MOVEFILE_WRITE_THROUGH) != 0;
}

/// 把宽字符字符串中的单引号 `'` 翻倍（PowerShell 单引号字符串内转义）。
///
/// 历史 bug：路径里如果含单引号（极少见但合法），PowerShell 单引号字符串
/// 会被提前关闭，攻击者可借此向 PS 命令注入任意 PS 脚本执行（RCE）。
static std::wstring EscapeForPowerShellSingleQuoted(const std::wstring& s) {
    std::wstring out;
    out.reserve(s.size() + 4);
    for (wchar_t c : s) {
        if (c == L'\'') out.push_back(L'\'');
        out.push_back(c);
    }
    return out;
}

/// 用 PowerShell Expand-Archive 解压 ZIP 到目标目录。
/// 这是 Windows 10+ 内置功能，无需额外库。
static bool ExtractZip(const std::wstring& zipPath,
                       const std::wstring& destDir) {
    Log(L"Extracting ZIP: " + zipPath + L" -> " + destDir);

    // 构造 PowerShell 命令：
    //   powershell -NoProfile -Command
    //     "Expand-Archive -Path 'ZIP' -DestinationPath 'DIR' -Force"
    //
    // 安全修复：路径里的单引号必须转义为两个单引号（PowerShell 单引号
    // 字符串内转义规则），否则路径含 ' 时 PS 命令会被提前闭合，
    // 攻击者可借此注入任意 PS 脚本执行（RCE）。
    std::wstring escapedZip = EscapeForPowerShellSingleQuoted(zipPath);
    std::wstring escapedDir = EscapeForPowerShellSingleQuoted(destDir);
    // 旧 updater 的实际行为：ZIP 内容直接解压到 targetDir。
    // 因此 ZIP 必须直接包含 scum_mod_manager.exe、data/、DLL，
    // 不能额外包一层 scum_mod_manager/，否则会被解压成 targetDir/scum_mod_manager/。
    std::wstring psCmd = L"powershell -NoProfile -Command \""
        L"Expand-Archive -Path '\"" + escapedZip + L"\"' "
        L"-DestinationPath '\"" + escapedDir + L"\"' -Force\"";

    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {0};

    std::vector<wchar_t> cmdBuf(psCmd.begin(), psCmd.end());
    cmdBuf.push_back(L'\0');

    BOOL ok = CreateProcessW(
        nullptr, cmdBuf.data(),
        nullptr, nullptr,
        FALSE,
        CREATE_NO_WINDOW,
        nullptr, nullptr,
        &si, &pi);
    if (!ok) {
        DWORD err = GetLastError();
        Log(L"CreateProcess(PowerShell) failed, error = " +
            std::to_wstring(err));
        return false;
    }
    // 等 PowerShell 执行完（最长 60s）
    WaitForSingleObject(pi.hProcess, 60000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    // 检查目标文件是否已创建（scum_mod_manager.exe 为信标）
    std::wstring testExe = destDir + L"\\scum_mod_manager.exe";
    if (GetFileAttributesW(testExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        Log(L"ZIP extract verification FAILED — target exe not found");
        return false;
    }
    Log(L"ZIP extract verified OK (target exe present)");
    return true;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    Log(L"=== updater started (ZIP mode) ===");

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    std::wstring targetDir, zipPath, backupPath;
    DWORD parentPid = 0;

    if (argv != nullptr) {
        // 容错解析：逐 token 找 "--key"，取其**下一个** token 当值。
        //
        // 旧版用固定步长 2 配对（i += 2）：只要参数里多一个 / 少一个 token，
        // 后续所有键值立即错位。实测踩到过：从资源管理器拖着手动运行时，带
        // 空格的路径没加引号 → argv 被拆散 → --target 落空 → 误入 fallback
        // 模式并被「refusing unsafe fallback update」拒绝，用户只看到更新没反应。
        // 改为按键消费：某个键缺值只影响该键，不影响其它键。
        for (int i = 1; i < argc; ++i) {
            std::wstring key = argv[i];
            if (key != L"--target" && key != L"--zip" &&
                key != L"--backup" && key != L"--parent-pid") {
                continue;   // 忽略无法识别的 token（含误传的位置参数）
            }
            if (i + 1 >= argc) {
                Log(L"WARN: dangling flag (no value): " + key);
                continue;
            }
            std::wstring val = argv[i + 1];
            ++i;   // 消费掉值，避免它被当成下一个键
            if (key == L"--target") {
                targetDir = val;
            } else if (key == L"--zip") {
                zipPath = val;
            } else if (key == L"--backup") {
                backupPath = val;
            } else {
                // 用 wcstoul 替代 std::stoul —— 后者会抛 std::invalid_argument
                // 直接 terminate updater 进程（非数字 / 负数 / 溢出都会抛）。
                // 这里手动解析，校验到非数字字符时视为 0（拒绝升级）。
                wchar_t* endPtr = nullptr;
                errno = 0;
                unsigned long parsed = wcstoul(val.c_str(), &endPtr, 10);
                if (endPtr == val.c_str() || *endPtr != L'\0' || errno == ERANGE) {
                    Log(L"WARN: invalid --parent-pid value, treating as 0");
                    parentPid = 0;
                } else {
                    parentPid = static_cast<DWORD>(parsed);
                }
            }
        }
        LocalFree(argv);
    }

    // Fallback 模式：自行推断路径（兼容旧版管理器不传参）
    if (targetDir.empty() || zipPath.empty()) {
        Log(L"WARNING: missing required args — entering fallback mode");
        wchar_t updaterPath[MAX_PATH] = {0};
        if (GetModuleFileNameW(nullptr, updaterPath, MAX_PATH) == 0) {
            Log(L"FATAL: GetModuleFileNameW failed");
            return 1;
        }
        std::wstring self(updaterPath);
        size_t slash = self.find_last_of(L'\\');
        if (slash == std::wstring::npos) {
            Log(L"FATAL: cannot parse own path");
            return 1;
        }
        targetDir = self.substr(0, slash);
        backupPath = targetDir + L"\\scum_mod_manager.exe.bak";

        wchar_t tempDir[MAX_PATH] = {0};
        if (!GetTempPathW(MAX_PATH, tempDir)) {
            Log(L"FATAL: GetTempPathW failed");
            return 1;
        }
        zipPath = std::wstring(tempDir) + L"scum_mod_manager.update.zip";
        parentPid = 0;
    }

    std::wstring targetExe = targetDir + L"\\scum_mod_manager.exe";

    // ★ 自我放逐（v2.6.3）：若自身镜像位于 targetDir 内，则把副本拷到 %TEMP%
    // 再重新执行自己 —— 否则自己的镜像锁着 targetDir，第 2 步的
    // MoveFileExW(targetDir → .bak) 必报 error 32（实测）。
    // 这一步对「老版本管理器直接从安装目录启动 updater」同样生效，无需等
    // 管理器升级完成；%TEMP% 里的副本路径不在 targetDir 内，天然不会递归。
    {
        wchar_t selfBuf[MAX_PATH] = {0};
        wchar_t tempBuf[MAX_PATH] = {0};
        if (GetModuleFileNameW(nullptr, selfBuf, MAX_PATH) != 0 &&
            GetTempPathW(MAX_PATH, tempBuf) != 0) {
            std::wstring selfPath(selfBuf);
            std::wstring tDir = StripTrailingSep(targetDir);
            Log(L"updater image = " + selfPath);
            if (IsInsideDir(selfPath, tDir)) {
                std::wstring relocated = std::wstring(tempBuf) +
                                         L"scum_mod_manager_updater_run.exe";
                if (CopyFileW(selfPath.c_str(), relocated.c_str(), FALSE)) {
                    Log(L"self image inside target dir -> relaunching from " +
                        relocated);
                    std::wstring line = L"\"" + relocated + L"\"";
                    for (int i = 1; i < argc; ++i) {
                        line += L" \"" + std::wstring(argv[i]) + L"\"";
                    }
                    std::vector<wchar_t> buf(line.begin(), line.end());
                    buf.push_back(L'\0');
                    STARTUPINFOW rsi = {0};
                    rsi.cb = sizeof(rsi);
                    PROCESS_INFORMATION rpi = {0};
                    if (CreateProcessW(nullptr, buf.data(), nullptr, nullptr,
                                       FALSE, DETACHED_PROCESS, nullptr, nullptr,
                                       &rsi, &rpi)) {
                        CloseHandle(rpi.hThread);
                        CloseHandle(rpi.hProcess);
                        Log(L"relocated updater started; exiting original");
                        return 0;
                    }
                    DWORD rerr = GetLastError();
                    Log(L"WARN: relaunch failed, error = " +
                        std::to_wstring(rerr) + L" — continuing in place");
                } else {
                    DWORD cerr = GetLastError();
                    Log(L"WARN: self copy failed, error = " +
                        std::to_wstring(cerr) + L" — continuing in place");
                }
            }
        }
    }

    Log(L"target_dir  = " + targetDir);
    Log(L"zip         = " + zipPath);
    Log(L"backup      = " + backupPath);
    Log(L"parent_pid  = " + std::to_wstring(parentPid));

    if (targetDir.empty() || zipPath.empty()) {
        Log(L"FATAL: missing required args (even after fallback)");
        return 1;
    }

    // 0) 清理目标目录里的 stale 状态（.bak 旧备份 / .failed 诊断目录）
    // 关键：v2.5.5 发布时，targetDir.bak 是个**目录**，旧版用 DeleteFileW 删
    // 目录必然失败（ERROR_ACCESS_DENIED），导致 MoveFileEx 也失败 →
    // updater 退出码 1 → 用户看到「更新失败」但不知道原因。
    auto removeDirRecursive = [](const std::wstring& path) -> bool {
        DWORD attr = GetFileAttributesW(path.c_str());
        if (attr == INVALID_FILE_ATTRIBUTES) return true;  // 不存在 = 已清
        if (!(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            return DeleteFileW(path.c_str()) != 0;
        }
        // 目录 → SHFileOperation 递归删
        SHFILEOPSTRUCTW fos = {0};
        fos.wFunc = FO_DELETE;
        std::wstring fromBuf = path + L'\0';
        fos.pFrom = fromBuf.c_str();
        fos.fFlags = FOF_NO_UI | FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO;
        return SHFileOperationW(&fos) == 0;
    };
    {
        std::wstring staleBak = targetDir + L".bak";
        std::wstring staleFailed = targetDir + L".failed";
        Log(L"Cleaning stale: " + staleBak + L", " + staleFailed);
        removeDirRecursive(staleBak);
        removeDirRecursive(staleFailed);
    }

    // 1) 等主进程退出。正常模式必须确认主进程已退出，避免 Windows
    //    仍锁定 exe/app.so 时把目录移动成 .bak，造成更新后仍加载旧文件。
    if (parentPid > 0 && !WaitForParent(parentPid)) {
        Log(L"FATAL: parent did not exit");
        return 1;
    }
    if (parentPid == 0) {
        Log(L"Skipping parent wait (fallback mode)");
    }

    // 2) 备份当前安装目录（回滚点）
    //
    // updater 只接受带 parent PID 的正常流程；没有 PID 时无法证明
    // manager.exe 已退出，禁止在未知状态下替换。
    if (parentPid == 0) {
        Log(L"FATAL: parent PID missing; refusing unsafe fallback update");
        return 1;
    }
    // 正常模式：先整体备份安装目录，再解压到全新的目录。
    std::wstring dirBackup = targetDir + L".bak";
    // 先清掉旧的 .bak 目录（上次升级失败留下的，可能是目录不是文件）。
    // 复用上面的 removeDirRecursive —— 必须用 SHFileOperationW 不能用 DeleteFileW。
    removeDirRecursive(dirBackup);
    // 带重试：杀软实时扫描 / 资源管理器预览可能瞬时持有目录内句柄，
    // 单次失败就放弃会让用户看到「更新失败」而不知原因（实测 error 32）。
    bool dirMoved = false;
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (MoveFileExW(targetDir.c_str(), dirBackup.c_str(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            dirMoved = true;
            break;
        }
        Log(L"backup targetDir attempt " + std::to_wstring(attempt + 1) +
            L" failed, error = " + std::to_wstring(GetLastError()));
        Sleep(1500);
    }
    if (!dirMoved) {
        DWORD err = GetLastError();
        Log(L"FATAL: backup targetDir failed, error = " +
            std::to_wstring(err));
        return 1;
    }
    Log(L"targetDir -> .bak OK (full directory backup)");

    // 3) 解压 ZIP（解压到新创建的 targetDir 之前先确保它存在）
    CreateDirectoryW(targetDir.c_str(), nullptr);

    bool extractOk = false;
    if (!ExtractZip(zipPath, targetDir)) {
        Log(L"FATAL: ZIP extract failed");
    } else {
        // 检查解压是否真的产生了新版 exe（避免 ZIP 损坏 / 空 zip）。
        std::wstring testExe = targetDir + L"\\scum_mod_manager.exe";
        if (GetFileAttributesW(testExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
            Log(L"FATAL: extract OK but target exe missing");
        } else {
            extractOk = true;
        }
    }

    if (!extractOk) {
        // 完整还原整个 targetDir
        Log(L"Rolling back: targetDir.bak -> targetDir");
        // 先删掉解压出来的半残 targetDir
        // （不能用 RemoveDirectory 递归——自己实现简单递归删，或用 SHFileOperation）。
        // 这里保守：直接 MoveFileEx(.bak → targetDir)。如果目标已存在，
        // MOVEFILE_REPLACE_EXISTING 会覆盖。需要先确认 .bak 完整无缺。
        if (GetFileAttributesW(dirBackup.c_str()) != INVALID_FILE_ATTRIBUTES) {
            // 把半残的 targetDir 改名成 targetDir.failed 留作诊断。
            // 注意 failedDir 可能是上次留下的目录（不是文件）—— 用 removeDirRecursive 清。
            std::wstring failedDir = targetDir + L".failed";
            removeDirRecursive(failedDir);
            MoveFileExW(targetDir.c_str(), failedDir.c_str(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
            // 然后把 .bak 还原回 targetDir
            if (MoveFileExW(dirBackup.c_str(), targetDir.c_str(),
                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                Log(L"rolled back targetDir successfully");
                // 清理半残的 failed目录（best-effort）
                // 暂不删：留给主人 / 工具看 log 诊断
            } else {
                DWORD err = GetLastError();
                Log(L"rolled back FAILED, error = " +
                    std::to_wstring(err));
            }
        }
        return 1;
    }

    // 3.5) ★ 用户数据回迁（v2.6.3 修复 —— 否则一次更新就把用户的本地 mod 库
    //      / UE4SS 运行时 / 配置全部抹掉）
    //
    // 更新包刻意**不含**用户运行时数据（~mods、ue4ss_runtime、config.json、
    // mods_meta.json、server_mods.db、logs、assets、~merged），而替换策略是
    // 「整目录改名 → 解压新包 → 删 .bak」——如果不回迁，这些数据就随 .bak
    // 一起被删掉：本地 PAK 库、已装 UE4SS mod、游戏路径配置、标签备注全丢。
    {
        const wchar_t* kUserData[] = {
            L"~mods", L"~merged", L"ue4ss_runtime", L"logs", L"assets",
            L"config.json", L"mods_meta.json", L"server_mods.db"};
        int moved = 0, failed = 0;
        for (const wchar_t* name : kUserData) {
            std::wstring src = dirBackup + L"\\" + name;
            std::wstring dst = targetDir + L"\\" + name;
            DWORD attr = GetFileAttributesW(src.c_str());
            if (attr == INVALID_FILE_ATTRIBUTES) continue;   // 本来就没有
            // 新目录里若已存在同名项（ZIP 不该带，但保险），先清掉再搬。
            removeDirRecursive(dst);
            if (MoveFileExW(src.c_str(), dst.c_str(),
                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                ++moved;
            } else {
                ++failed;
                Log(L"WARN: user data restore failed: " + std::wstring(name) +
                    L", error = " + std::to_wstring(GetLastError()));
            }
        }
        Log(L"user data restored: " + std::to_wstring(moved) + L" ok, " +
            std::to_wstring(failed) + L" failed");
    }

    // 解压成功 —— 删掉 .bak
    // 复用顶部定义的 removeDirRecursive（注意 .bak 是目录不是文件）。
    if (!removeDirRecursive(dirBackup)) {
        Log(L"WARN: failed to delete targetDir.bak (best-effort)");
    }

    // 4) 启动新版本
    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};
    std::vector<wchar_t> cmdBuf(targetExe.begin(), targetExe.end());
    cmdBuf.push_back(L'\0');

    if (!CreateProcessW(targetExe.c_str(), cmdBuf.data(),
                        nullptr, nullptr, FALSE,
                        NORMAL_PRIORITY_CLASS,
                        nullptr, nullptr, &si, &pi)) {
        DWORD err = GetLastError();
        Log(L"FATAL: CreateProcess(new) failed, error = " +
            std::to_wstring(err));
        return 1;
    }
    Log(L"launched new version, pid = " +
        std::to_wstring(pi.dwProcessId));
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    Log(L"=== updater done (ZIP mode) ===");
    return 0;
}