# GPT-Niang（GPT 娘）macOS

Current release: **1.3.5**. This macOS package was built by CI. Platform differences in 1.3.5: Windows-only music rhythm, character gallery, auto quotes and independent character/bubble scaling; macOS-only chat-speed panel and interface language; WAV click-sound import and completion reminders are on both platforms. Chinese installation and platform comparison: [project README](../README.md#macos-安装).

Code contributions, reviews, bug reproductions and feature suggestions are credited with their PR/Issue links in the [complete contributor acknowledgements](../README.md#致谢与许可).

The widget detects Free, Go, Plus, Pro, Team/Business, Enterprise, Edu and future plan identifiers, and renders valid quota windows returned by Codex, including Go's 30-day window. A single window stays centered inside the original bubble. Plan labels do not determine entitlements or invent quota windows. To inspect the installed app's plan without exposing account identity or credentials, run `node /Applications/GPTNiangMac.app/Contents/Resources/Backend/runtime/detect-plan.mjs --json` after upgrading; from source, run `node gpt-niang-usage/runtime/detect-plan.mjs --json` at the repository root.

A native macOS companion for the Windows GPT 娘 widget. The SwiftUI canvas ports
v1.2.5's character image, 378-point animation stage, cloud outline, thought bubbles,
press/rebound Bézier curves, staggered open/close animations, flowing palettes,
quote transitions, and original sound assets. AppKit owns the transparent panel,
window following, native pointer capture, and menu bar entry.

## Requirements

- macOS 13 or newer. The release includes arm64 and x86_64 slices; actual GUI behavior on Intel and older macOS still needs verification.
- Node.js 20 or newer (no npm dependencies).
- Codex desktop installed and signed in with a ChatGPT account.
- Source builds only: Xcode command-line tools / Swift 5.9 or newer. The release app does not need Xcode or Swift.

If a CommandLineTools-only source build reports a missing SwiftUI macro plugin, `GPT_NIANG_SDK=/path/to/compatible/MacOSX.sdk ./script/build_and_run.sh --build-only` forwards the selected SDK to Swift. The default build and deployment target are unchanged. This build compatibility change is retained from [PR #8](https://github.com/T7moris/GPT-Niang/pull/8).

## Platform differences (1.3.5)

- Windows-only in this release: music rhythm, local character gallery, timed auto quotes, and independent character/bubble scaling.
- macOS-only: chat-speed panel and interface-language selection.
- Shared by both: WAV click-sound import (press/release) and completion reminders.
- Not real-machine verified yet on this macOS build: multi-display, Stage Manager, fullscreen Spaces, audio import, and the update readiness/rollback path. The macOS updater additionally requires a fresh quota-worker heartbeat before committing an update, so validate on a non-critical machine first.
## Install the release

Download `gpt-niang-usage-widget-v1.3.5-macos-universal.zip` from the [v1.3.5 GitHub Release](https://github.com/T7moris/GPT-Niang/releases/tag/v1.3.5), verify its entry in `SHA256SUMS.txt`, unzip, and move `GPTNiangMac.app` to Applications before opening. Node.js 20+ and a signed-in Codex desktop app are required; Swift/Xcode is needed only for source builds.

The release is ad-hoc signed, not Developer ID signed or notarized. If macOS blocks the first launch, after checking the source and checksum follow [Apple’s instructions](https://support.apple.com/102445) in System Settings → Privacy & Security → Open Anyway.

To calculate the downloaded ZIP’s checksum in Terminal, change to the download directory and run:

```sh
shasum -a 256 gpt-niang-usage-widget-v1.3.5-macos-universal.zip
```

Compare the result with the same filename in `SHA256SUMS.txt`; hexadecimal letter case does not matter.

## Build from source

From the repository root:

```sh
./script/build_and_run.sh
```

The script builds and ad-hoc signs `dist/GPTNiangMac.app`, then opens the app bundle.
`--build-only` builds without launching; `--verify` also checks the process.
`--logs`, `--telemetry`, and `--debug` are available for development.
Passing `--speed` after a run mode opens the separate speed panel at launch.
`GPT_NIANG_BUILD_CACHE` optionally selects a build cache directory.
`GPT_NIANG_BUILD_CONFIGURATION=release GPT_NIANG_BUILD_UNIVERSAL=1 ./script/build_and_run.sh --build-only` builds the universal release binary.

You can keep the `.app` in a permanent location and open it directly. The local
build is ad-hoc signed, not Apple notarized; Developer ID signing and notarization
are not provided in this release. The app finds the desktop's bundled Codex CLI on each
refresh and supports `GPT_NIANG_CODEX_APP` for a nonstandard Codex app location.
`GPT_NIANG_NODE` can select a custom Node executable.

## Interaction

- Click the character to show quota. Both quota and quotes hide five seconds after
  their reveal animation completes, matching the original.
- Click the quota cloud to see a quote; click the quote cloud to close it.
- Drag the character to reposition it. It snaps near the left/right edges and
  faces inward; the text remains upright.
- Single, double and rapid clicks use the ordinary quota/quote action.
  Right-click opens the native menu; the hover button and menu bar provide settings.
- Settings include scale, audio, quote editing, the original color modes, random
  color probabilities, flow pause, special quote triggers, and click-to-advance.
- Following mode hides the panel when Codex has no visible main window. Turn
  following off to keep it on the desktop. Window bounds come from public
  WindowServer metadata; no accessibility or screen-recording permission is
  requested. The selected window's position is sampled at a target 60 Hz while
  following; full window discovery runs four times per second and chooses the
  foremost Codex window. Presence heartbeats are written once per second (and
  immediately when visibility changes), and optional diagnostics four times per
  second. Timing depends on main-thread and WindowServer availability; this is
  polling, not a guarantee of zero-lag attachment. There is a 0.75-second grace
  period for transient missing metadata; this differs from the
  Windows version's native movement hooks. The panel stays at normal window level
  in following mode so other apps can cover it.
- Login launch is opt-in through macOS `SMAppService`. Enable it only after moving
  the app to its permanent location; macOS may request approval in Login Items.
- **聊天速度** in the menu bar opens a separate thread performance panel.

## Thread speed: interpretation and privacy

The speed panel reads the newest twelve unarchived entries from the local Codex
SQLite index in read-only mode, then incrementally tails only their local session
files. It extracts `event_msg/token_count` output counters and timestamps. It
computes **output counter delta / elapsed time between accounting checkpoints**.
This interval average includes reasoning, network latency and tool waiting; it
is **not live model decoder/streaming tokens per second**. Missing or reset
counters display an unavailable value rather than an invented speed. The latest
sample and its interval are shown, so a historical sample is distinguishable from
an active one. The helper runs only while the speed window is open, updates every
three seconds, and is stopped on close or app exit.

Only titles and numeric counters are displayed; message bodies, credentials and
rate-limit credit information are not emitted or saved by this helper. Rollout
paths must resolve within the Codex sessions directories, including symlink
checks. The local database schema is an implementation detail and may change;
unsupported schemas show an error. `CODEX_HOME`, when already set, is respected.

Quota still uses the shared single-writer Node worker and the read-only App Server
methods `initialize`, `account/read` and `account/rateLimits/read`. It preserves
account isolation and stale/expired snapshot behavior and performs no chat or
model-generation call. The standalone Mac app does not register an MCP plugin or
change Codex configuration.

Local preferences/quota snapshots live at:

```text
~/Library/Application Support/GPTNiangUsage
```

## Update, move, and uninstall

For 1.3.3+, use the native update controls described below. For a first upgrade from older versions, quit GPT 娘 and replace the app in its original location; preferences and custom quotes remain in the data directory above. To move the app, disable login launch first, quit, move it, and enable login launch again from the new location if needed.

Choosing **退出 GPT 娘** quits the Mac application and helpers. Reopening Codex alone does not relaunch GPT 娘; open the `.app` again. Login launch is optional, unlike the Windows installer’s default startup configuration.

To uninstall, disable login launch, quit, and remove the app. Remove the data directory separately only if you want to discard preferences and snapshots. Do not delete Codex’s own login or session data.

## Verification

```sh
cd gpt-niang-usage
node --test tests/*.test.mjs
cd ..
swift test --package-path macos
./script/build_and_run.sh --build-only
codesign --verify --deep --strict dist/GPTNiangMac.app
```

`--diagnostics /absolute/path.json` after the run mode enables a local development
snapshot of frame/visibility, gesture-event counts and quota readiness; it omits
account details and thread titles. Do not include local state in source archives.
Windows PowerShell/WPF tests must also run on Windows before merging.

Source code and documentation use the [MIT License](../LICENSE). Character
images and derived icons are excluded from that license and follow the
[character asset notice](../gpt-niang-usage/assets/CHARACTER-NOTICE.txt): project
display in non-commercial copies is permitted within the maintainers' rights;
commercial asset use requires separate permission from the relevant rights
holders. The app includes both notices. This is an independent companion,
not an official OpenAI app.

## Native updates (1.3.3+)

The SwiftUI settings window and AppKit menu provide the installed version, manual check, status and automatic-update toggle. Automatic checks start 30 seconds after launch and repeat daily. Only a newer stable official GitHub Release is installed. Close settings and the speed panel and finish dragging before installation.

URLSession downloads metadata and the universal app with bounded sizes; CryptoKit verifies SHA256SUMS and the GitHub digest where present. ZIP paths, bundle version, code-signature integrity and both architectures are validated. A separately built Swift helper uses a same-volume atomic exchange, waits for a successful app/worker startup receipt and removes the old app and download cache. If startup fails it stops the new process before restoring and reopening the old app. Interrupted transactions recover on next launch; recovery failure keeps the required files and `mac-update-diagnostic.txt` in the data directory. Cleanup retries even when automatic updates are disabled. Preferences and quotes remain outside the app.

No Windows updater or PowerShell is shipped in the Mac app. Node.js 20+ remains required for the shared quota backend. The app must be in a writable application folder. Older releases need a one-time manual upgrade. The current release is ad-hoc signed and is not Developer ID signed or notarized; macOS may require the user to approve opening it.

## 1.3.4 interaction alignment

Windows defines shared interaction behavior. Every left click, including double and rapid clicks, performs the normal quota/quote action and press/rebound feedback. Right-click opens an AppKit menu; the hover button and menu bar provide native settings. The scale range is 60–250% with 80/100/140% presets. Desktop mode supports cross-screen dragging, a remembered topmost switch (off by default), and a separately saved position. Returning to host mode immediately returns to the normal window level. Refresh does not open the bubble. Weighted quotes round-trip and custom quotes are backed up before reset.

Business `individualLimit` windows with null minutes decode alongside timed windows. Two compact rows show the personal limit and shortest time window, while hover details retain all valid windows. Interface language follows the system or an explicit Simplified/Traditional choice; authored quotes and backend data remain untouched. UI, menus, drag capture and updates remain native SwiftUI/AppKit implementations.
