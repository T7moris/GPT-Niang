#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>

static const UINT_PTR InputSubclassId = 0x47505449;
static LRESULT CALLBACK InputProcedure(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR) {
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_NCDESTROY) RemoveWindowSubclass(window, InputProcedure, InputSubclassId);
    return DefSubclassProc(window, message, w, l);
}
static bool OwnThread(HWND window) {
    DWORD process = 0;
    const DWORD thread = GetWindowThreadProcessId(window, &process);
    return process == GetCurrentProcessId() && thread == GetCurrentThreadId();
}
extern "C" __declspec(dllexport) BOOL __stdcall AttachMouseActivation(HWND window) {
    return OwnThread(window) && SetWindowSubclass(window, InputProcedure, InputSubclassId, 0);
}
extern "C" __declspec(dllexport) BOOL __stdcall DetachMouseActivation(HWND window) {
    if (!IsWindow(window)) return TRUE;
    if (!OwnThread(window)) return FALSE;
    DWORD_PTR data = 0;
    return !GetWindowSubclass(window, InputProcedure, InputSubclassId, &data) || RemoveWindowSubclass(window, InputProcedure, InputSubclassId);
}
