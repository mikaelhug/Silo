// steamwebhelper wrapper — makes Steam's CEF UI paint under Wine on macOS.
//
// Steam's `steamwebhelper.exe` (Chromium/CEF) renders to a BLACK window under Wine because its default
// chrome runtime + multi-process GPU/Network services don't work (the winsock NetworkService also throws
// `WSALookupServiceBegin failed`). The only reliable fix is `--single-process` (collapse CEF into one
// process) + software GPU — and there is NO steam.exe command-line flag that injects `--single-process`.
//
// So Silo renames the real `steamwebhelper.exe` → `steamwebhelper_orig.exe` and drops this wrapper in its
// place. Steam launches the wrapper with its usual arguments; the wrapper re-launches the real binary with
// the same arguments PLUS the CEF flags, forwarding inherited handles/exit code transparently.
//
// Built in the Wine pipeline (mingw-w64, 64-bit, GUI subsystem) and shipped inside the runtime at
// share/silo/steamwebhelper-wrapper.exe; SteamBottle.installWebHelperWrapper places it in the bottle.
//
//   x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o steamwebhelper-wrapper.exe steamwebhelper-wrapper.c

#include <windows.h>

static const wchar_t *kRealExe = L"steamwebhelper_orig.exe";
static const wchar_t *kInjectedFlags =
    L" --disable-gpu --single-process --disable-gpu-compositing --no-sandbox";

int wmain(void)
{
    // Path to the real steamwebhelper, in the same directory as this wrapper.
    wchar_t real[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (slash == NULL) return 1;
    slash[1] = L'\0';
    if (wcslen(real) + wcslen(kRealExe) >= MAX_PATH) return 1;
    wcscat(real, kRealExe);

    // Original command line + injected CEF flags (idempotent — Steam may already pass some).
    static wchar_t cmdline[32768];
    lstrcpynW(cmdline, GetCommandLineW(), 32000);
    if (wcsstr(cmdline, L"--single-process") == NULL)
        wcscat(cmdline, kInjectedFlags);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    // Inherit handles so Steam's IPC pipes/fds reach the real webhelper.
    if (!CreateProcessW(real, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 2;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
