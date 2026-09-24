// scum_mod_manager.exe —— v3 架构引导器（launcher）。
//
// 职责（单一）：
//   读 app.json → 校验 versions/<current>/scum_mod_manager_app.exe 存在
//   → 设环境变量 SCUM_MM_ROOT=<安装根> → CreateProcessW 启动应用 → 退出。
//
// 设计铁律：
//   - 永不自我替换：引导器本身从不被更新流程触碰，是安装目录里唯一
//     稳定不变的 exe（更新全部落在 versions/<ver>/，运行中镜像零冲突，
//     error 32 一族问题在此架构下物理不可能发生）。
//   - 不联网、不注入、无资源文件，纯 Win32（kernel32 + shell32 + user32），
//     体积 <50KB，被杀软误判概率极低。
//   - 极简 JSON 取值：app.json 是本项目自产自销的固定格式
//     {"current":"v2.6.3","rollback":"v2.6.2"}，无需引第三方 JSON 库。
//
// 回滚：versions/<current>/ 关键文件缺失时自动回退到 rollback 指向的版本。

#include <windows.h>
#include <cwchar>
#include <string>
#include <vector>

/// 当前引导器自身所在目录（安装根）。
static std::wstring GetSelfDir() {
    wchar_t buf[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring s(buf);
    size_t slash = s.find_last_of(L'\\');
    return (slash == std::wstring::npos) ? s : s.substr(0, slash);
}

/// 极简 JSON 字符串取值：从 {"key":"value", ...} 里取 key 对应的 value。
/// 找不到 key 返回空串。值里不允许出现未转义的引号（app.json 由
/// update_service.dart 用 jsonEncode 生成，格式受控，满足此假设）。
static std::wstring JsonGetString(const std::wstring& json,
                                  const std::wstring& key) {
    std::wstring needle = L"\"" + key + L"\"";
    size_t pos = json.find(needle);
    if (pos == std::wstring::npos) return L"";
    size_t colon = json.find(L':', pos);
    if (colon == std::wstring::npos) return L"";
    size_t q1 = json.find(L'"', colon);
    if (q1 == std::wstring::npos) return L"";
    size_t q2 = json.find(L'"', q1 + 1);
    if (q2 == std::wstring::npos) return L"";
    return json.substr(q1 + 1, q2 - q1 - 1);
}

/// 读 app.json（UTF-8，无 BOM）。失败返回空串。
static std::wstring ReadAppJson(const std::wstring& path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                           nullptr);
    if (h == INVALID_HANDLE_VALUE) return L"";
    std::wstring result;
    DWORD size = GetFileSize(h, nullptr);
    if (size > 0 && size < 1024 * 1024) {
        std::vector<char> buf(size);
        DWORD read = 0;
        if (ReadFile(h, buf.data(), size, &read, nullptr) && read > 0) {
            int wlen = MultiByteToWideChar(CP_UTF8, 0, buf.data(),
                                           static_cast<int>(read), nullptr, 0);
            if (wlen > 0) {
                std::vector<wchar_t> wbuf(wlen);
                MultiByteToWideChar(CP_UTF8, 0, buf.data(),
                                    static_cast<int>(read), wbuf.data(), wlen);
                result.assign(wbuf.begin(), wbuf.end());
            }
        }
    }
    CloseHandle(h);
    return result;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    std::wstring dir = GetSelfDir();

    std::wstring json = ReadAppJson(dir + L"\\app.json");
    if (json.empty()) {
        MessageBoxW(nullptr,
                    L"未找到 app.json，请重新安装 SCUM Mod Manager。",
                    L"SCUM Mod Manager", MB_ICONERROR | MB_OK);
        return 1;
    }

    std::wstring current = JsonGetString(json, L"current");
    std::wstring rollback = JsonGetString(json, L"rollback");

    // 选定要启动的版本目录：current 优先，缺失则回退 rollback。
    std::wstring ver = current;
    std::wstring appExe =
        dir + L"\\versions\\" + ver + L"\\scum_mod_manager_app.exe";
    if (ver.empty() ||
        GetFileAttributesW(appExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        ver = rollback;
        appExe =
            dir + L"\\versions\\" + ver + L"\\scum_mod_manager_app.exe";
        if (ver.empty() ||
            GetFileAttributesW(appExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
            MessageBoxW(nullptr,
                        L"应用文件缺失（versions\\<版本>\\scum_mod_manager_app.exe），\n"
                        L"请重新安装 SCUM Mod Manager。",
                        L"SCUM Mod Manager", MB_ICONERROR | MB_OK);
            return 1;
        }
    }

    // 把安装根传给应用（Dart 侧 AppPaths 据此定位用户数据根）。
    // 子进程继承父进程环境变量 —— CreateProcessW 无需额外传参。
    SetEnvironmentVariableW(L"SCUM_MM_ROOT", dir.c_str());

    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};

    std::wstring cmd = L"\"" + appExe + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');

    if (!CreateProcessW(appExe.c_str(), cmdBuf.data(), nullptr, nullptr,
                        FALSE, 0, nullptr, dir.c_str(), &si, &pi)) {
        DWORD err = GetLastError();
        wchar_t msg[512] = {0};
        _snwprintf_s(msg, _TRUNCATE,
                     L"启动应用失败（error %u）。\n请重新安装 SCUM Mod Manager。",
                     err);
        MessageBoxW(nullptr, msg, L"SCUM Mod Manager",
                    MB_ICONERROR | MB_OK);
        return 1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    // 引导器使命完成，立即退出（应用自身持有窗口）。
    return 0;
}
