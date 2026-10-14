# Windows owner-preserving occlusion recovery

Switching back from a maximized browser or VS Code can leave ChatGPT/Codex
animations and scrolling paused even after the host has regained foreground and
focus. In local application traces, an occlusion calculation ran before the real
Z-order promotion and its OCCLUDED result was applied after focus returned.
Without another effective notification the renderer remained invisible; clicking
usually caused a new calculation and restored it.

Synchronizing WPF/native owner state alone did not prevent this. Neither did
SWP_NOOWNERZORDER alone, nor a control removing the project's repeated placement
calls during switching. The exact Windows/WPF/Chromium source of the transition
ordering has not been proven.

## Recovery

`runtime/host-occlusion.ps1` retains the existing owner relationship. On relevant
window events it checks the actual windows above the host. If one ordinary opaque
window completely covers the host, it cloaks only the widget's own HWND through
DWMWA_CLOAK. When the host is stably exposed, it removes that cloak. These real
operations produce EVENT_OBJECT_CLOAKED / UNCLOAKED, which Chromium's native
occlusion tracker subscribes to and uses to schedule a new calculation.

This is a compatibility recovery, not a change to ChatGPT or simulated input.
It does not activate the widget, move the host, send mouse messages, fabricate
WinEvents, or create another process. The native owner and normal layering remain.

Foreground notifications may precede actual Z-order changes, so a 32 ms settling
timer continues for at most a 256 ms burst, ending early after restoration.
The timer stops when idle; later window events can start another burst. Each
snapshot visits at most 200 HWNDs. Geometry-only widget updates do not start it.
Layer correction is skipped while this controller owns the widget's cloak.
Leaving follow mode, hiding the host or disposal restores the controller's cloak.
DWM failures disable recovery; existing shell/inherited cloaks are not cleared.

## Evidence and limits

A local application trace reproduced the old early-calculation sequence, then
recorded a real UNCLOAKED event and a fresh calculation. The page became visible
156 ms after focus, and its compositor 184 ms after focus, with no recorded click
or wheel message in that interval. Earlier controls stayed invisible for 8–15 s.
Repeated manual testing no longer reproduced a persistent pause, although a
visible recovery delay below half a second can remain.

The recorded two-minute trial had 241 coverage checks, taking 5.7 ms in total
inside the snapshot function (maximum 1.1 ms), and 25 DWM toggles. This is not a
measurement of all extra DWM/Chromium CPU work. Minimal counters are included in
the existing presence status, with no capture or diagnostic process.

The automated tests use off-screen HWNDs and a separate covering process. They
verify real cloak events, native state, partial overlap, unchanged owner and
foreground, bounded checks and cleanup. They cannot establish real ChatGPT
rendering behavior on every machine. Actual app verification used a locally
customized v1.3.3 install; the PR is integrated against v1.3.4/main.
Combined coverage by multiple windows, complex or transparent windows, multiple
monitors and virtual desktops need further validation. This implementation
deliberately recognizes only one fully covering ordinary opaque window.

References:

- [Chromium 155 native occlusion tracker](https://github.com/chromium/chromium/blob/155.0.8059.40/ui/aura/native_window_occlusion_tracker_win.cc)
- [DWM cloak attributes](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)
- [System window events](https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants)
