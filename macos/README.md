# GPT-Niang（GPT 娘）macOS

Current release: **1.3.6**. The macOS package is built by the same CI release workflow as the Windows package. Version 1.3.6 fixes recovery deadlines and adds the bounded direct quota fallback; the feature scope below is unchanged. Platform differences in 1.3.6: Windows-only music rhythm, character gallery, auto quotes and independent character/bubble scaling; macOS-only chat-speed panel and interface language; WAV click-sound import and completion reminders are on both platforms. Chinese installation and platform comparison: [project README](../README.md#macos-安装).

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

## Platform differences (1.3.6)

- Windows-only in this release: music rhythm, local character gallery, timed auto quotes, and independent character/bubble scaling.
- macOS-only: chat-speed panel and interface-language selection.
- Shared by both: WAV click-sound import (press/release) and completion reminders.
- Not real-machine verified yet on this macOS build: multi-display, Stage Manager, fullscreen Spaces, audio import, and the update readiness/rollback path. The macOS updater additionally requires a fresh quota-worker heartbeat before committing an update, so validate on a non-critical machine first.
## Install the release

Download `gpt-niang-usage-widget-v1.3.6-macos-universal.zip` from the [v1.3.6 GitHub Release](https://github.com/T7moris/GPT-Niang/releases/tag/v1.3.6), verify its entry in `SHA256SUMS.txt`, unzip, and move `GPTNiangMac.app` to Applications before opening. Node.js 20+ and a signed-in Codex desktop app are required; Swift/Xcode is needed only for source builds.

The release is ad-hoc signed, not Developer ID signed or notarized. If macOS blocks the first launch, after checking the source and checksum follow [Apple’s instructions](https://support.apple.com/102445) in System Settings → Privacy & Security → Open Anyway.

To calculate the downloaded ZIP’s checksum in Terminal, change to the download directory and run:

```sh
shasum -a 256 gpt-niang-usage-widget-v1.3.6-macos-universal.zip
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
  requested. Following uses adaptive polling: roughly 10 Hz while the host is
  foreground and stationary, a target 60 Hz briefly during movement, and 1 Hz
  while the host is in the background or desktop mode is selected. Workspace
  activation/hide/Space notifications trigger immediate checks. Full discovery
  is capped at four times per second and also respects the slower timer.
  Presence heartbeats remain once per second. Invisible widget animation is
  paused; hidden quota text is not laid out continuously. Visible colour flow
  retains its animation. Window movement remains polling and needs real-world
  drag/multiscreen validation. Stage Manager and Space geometry transitions
  follow the upstream policy; minimize/no-host snapshots hide the main panel.
  Following level is floating only while the host or companion is active.
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

Choosing **退出 GPT 娘** quits the pet and its quota/completion helpers. With
application linking disabled, reopening the host does not relaunch the pet.
With **随当前应用启动与退出** enabled, the lightweight lifecycle agent remains
available: the host's next launch reopens the pet, and its final process exit
closes the pet gracefully. Manually quitting the pet while the host stays open
is respected until the host next starts. Closing windows, minimizing, switching
chats or changing the foreground application does not trigger lifecycle actions.

The link targets the entire desktop app by bundle identifier (default
`com.openai.codex`, including installations named `ChatGPT.app`), independently
of what is open inside it. It does not observe ChatGPT chat content. The setting
is off for existing installations until enabled, and leaves position, audio,
alert preferences and the separate login-launch setting intact. Login launch
may still independently open the pet when logging into the Mac; disable that
separate option if the pet should only start with the host.

The bundled `GPTNiangHostLink` LaunchAgent uses `SMAppService` on macOS 13+.
It observes workspace events and checks running host process IDs once per second
as a fallback. Tracking process IDs also detects rapid restarts without requiring
a poll in between. It never uses chat completion events for application lifetime.
Enable linking after moving the app to its permanent location. If approval is
required, allow GPT 娘 background activity under System Settings → General →
Login Items & Extensions. The settings view provides a shortcut. Disabling the
link unregisters its agent; the pet then continues to work independently.
Disable linking before moving or uninstalling the application. No host settings,
credentials or chat files are modified. Login launch remains optional.

To uninstall, disable application linking and login launch, quit, and remove the app. Remove the data directory separately only if you want to discard preferences and snapshots. Do not delete Codex’s own login or session data.

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

Windows defines shared interaction behavior. Every left click, including double and rapid clicks, performs the normal quota/quote action and press/rebound feedback. Right-click opens an AppKit menu; the hover button and menu bar provide native settings. The scale range is 60–250% with 80/100/140% presets. Desktop mode supports cross-screen dragging, a remembered topmost switch (off by default), and a separately saved position. Returning to host mode uses the foreground-host window-level policy described above. Refresh does not open the bubble. Weighted quotes round-trip and custom quotes are backed up before reset.

Business `individualLimit` windows with null minutes decode alongside timed windows. Two compact rows show the personal limit and shortest time window, while hover details retain all valid windows. Interface language follows the system or an explicit Simplified/Traditional choice; authored quotes and backend data remain untouched. UI, menus, drag capture and updates remain native SwiftUI/AppKit implementations.

## Local quota and turn-completion alerts

This source build adds **额度与完成提醒** to native Settings. Both quota switches,
completion bubbles, background completion popups, and alert sounds default off; existing preferences and quotes
are preserved. Quota data and local session monitoring come from **Codex**.
ChatGPT-kind task reminders depend on the host notification-log adapter described
below; they do not have universal conversation coverage.

- Short-window and weekly quota switches each have an independent integer
  remaining-percentage threshold (1–99%, initially 20%). Short means the shortest
  actual returned period below one day; weekly means exactly 10080 minutes.
  Other periods and Business personal caps are not mislabeled as either.
- Fresh, successfully verified account snapshots trigger a system notification
  and queued pet bubble at or below the threshold, then one more at exhaustion.
  Anonymous account fingerprints isolate persistent latches in `alert-state.json`.
  Recovery above the threshold or an observed reset rollover rearms alerts;
  changing the threshold reevaluates against that new threshold. Failed, expired,
  stale, or unidentified snapshots never trigger quota notifications.
- While quota alerts are enabled, the existing single quota worker keeps its
  60-second automatic polling cadence even with a hidden pet. This is a macOS
  heartbeat opt-in; Windows keeps its existing visibility behavior. Manual
  refresh remains available. No additional quota worker or model call is created.
- First enabling quota alerts (or selecting **测试提醒**) requests macOS alert
  authorization. If refused, bubbles still work; **打开系统通知设置** opens the
  notification settings. Permission state refreshes on app activation and every
  minute while quota alerts are enabled. System notification delivery is subject
  to macOS notification and Focus settings.
- Task reminders have independent enabled, sound and background-popup switches for
  command/permission requests, questions, and turn completion. The completion
  choices migrate unchanged. Request categories inherit the old completion
  opt-in, sound and popup choices once; subsequent changes are independent.
  Other permissions use a neutral authorization message, not a command label.
- The helper incrementally reads the host's native notification-delivery log,
  classifying its `permission`, `question`, and `turn-complete` entries, with
  a neutral fallback for other actual native notification requests.
  Renderer/forwarder duplicates, generic agent messages and conversation refresh
  events are ignored. No titles, command text or chat bodies are emitted or saved.
  Notification identifiers are hashed; completion identity matches the local
  Codex fallback to prevent duplicate sounds/popups.
- This is a compatibility adapter for the currently installed host log format,
  not a public notification-subscription API. It needs the host to actually emit
  the corresponding notification. Disabled/suppressed host notifications, quiet
  turns, changed log formats, or inaccessible logs can prevent delivery. It does
  not read macOS Notification Center or alter host configuration. ChatGPT-kind
  coverage is conditional on that same notification path; the previously reported
  DSH conversation has no observed matching notification. The 2026-10-23
  ChatGPT question test did not produce a received question event; this path
  has not passed end-to-end acceptance. Completion counters alone cannot prove
  coverage for every ChatGPT conversation. A native turn-complete notification
  reports that a turn ended, and does not establish successful task execution.
- Local Codex completion detection remains a fallback for the latest twelve
  interactive sessions. It requires a start then a matching successful explicit
  completion; cancelled, failed, historical and internal-agent turns are ignored.
  These local sessions also provide question reminders when an explicitly observed
  `request_user_input_async` call returns `accepted: true` during the current turn.
  Calls alone, failed/unavailable tools and historical questions do not trigger
  reminders. Only call metadata and the acceptance flag are used; question text
  and answers are not forwarded. This fallback works independently of native
  notification delivery, but does not cover ChatGPT Work sessions without a local
  rollout or other interaction tools without a verified acceptance format.
  Both inputs react to filesystem changes with a 30-second reconciliation fallback
  instead of a fixed three-second scan. Startup baselines skip existing content.

#### Optional approval hooks

Approval prompts can be absent from native notification logs, including explicit
`request_permissions` requests. An optional, user-reviewed Codex hook connection
can deliver those events independently of native notification settings:

- `PermissionRequest` observes actual command/file/MCP approval requests.
- `PreToolUse` matches only `request_permissions` (including its namespace alias)
  to cover that dedicated permission tool and nested code-mode invocations.
- The bundled `Backend/runtime/permission-hook.mjs` accepts hook input on stdin,
  discards tool arguments, and atomically writes only thread id, hashed event id,
  category and timestamp into the pet's private `permission-events` directory.
  It returns no hook decision or model-visible output. Errors never authorize,
  deny or interrupt an action. Existing permission alert switches, tone, volume
  and popup behavior apply to these events.
- The pet watches that directory; startup history, invalid records and symlink
  escapes are ignored. No additional periodic scanner is started.

This connection is disabled until the user installs and trusts the matching hook
definitions. GPT Niang does not modify Codex config or hook trust automatically.
Use absolute paths for both Node and the installed script (Finder's PATH may not
contain Node). Review the generated hook preview before merging into an existing
`~/.codex/hooks.json`; preserve other hooks. Codex requires review/trust of the exact
definitions. Disabling/removing the two entries stops this connection without
changing the pet's other monitoring paths.

The upstream hook contract is documented at <https://learn.chatgpt.com/docs/hooks>.
Coverage is limited to supported local hook paths. Remote ChatGPT Work and normal
ChatGPT chats need separate real-event acceptance. A dedicated permission-tool
hook signals the request's invocation; it does not establish that a human must
approve it if the host or another trusted hook decides automatically. The final
code-to-host permission-prompt delivery requires enabling and trusting these hooks
and performing a real approval test on the installed host version. A local macOS
test verified a dedicated permission request with the hooks installed and trusted;
this does not guarantee delivery on other host versions or for remote sessions.

Ordinary Chat mode in the same desktop application currently has no verified
independent event source. Disabling the host's notifications must not be assumed
to preserve normal Chat completion or question reminders. No five-second Chat
polling option is implemented: the tested standalone state-query client was
rejected by the host's code-signing check. Idle time, connection changes and
generic message updates are not treated as successful completion events.
- Completion bubbles may queue for two minutes while hidden/busy. Requests are
  not queued while hidden/busy, to avoid replaying a request after it was answered.
  Background popups remain nonactivating, mouse-transparent and six seconds long.
  Concurrent categories share one panel with separate lines. Audio is emitted on
  receipt, uses current volume and coalesces within one second. No extra system
  task notifications are sent; quota notifications keep their previous behavior.

Developer verification:

```sh
node --test gpt-niang-usage/tests/*.test.mjs
swift test --package-path macos
GPT_NIANG_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./script/verify_alert_core.sh
GPT_NIANG_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./script/verify_alert_coordinator.sh
```

The last two commands compile actual production sources and run standalone
regression checks when XCTest is unavailable. The coordinator check injects
authorization results and notification delivery; it never sends OS notifications. The SDK override is specific to a machine
with that SDK installed. Full native XCTest and platform UI tests remain needed
on a full-Xcode machine. Local ad-hoc builds are not notarized releases, and an
upstream automatic update can replace local feature changes.

### Independent background completion popup

**后台短暂显示桌宠（仅跟随模式）** is independent of the sound switch. Its new
`completionPopupEnabled` preference defaults off when upgrading older settings;
all existing toggles and thresholds decode with their previous values intact.
The local completion fallback only observes interactive Codex desktop/CLI sessions (`vscode`/`cli`).
Internal guardian reviews, delegated agents and unknown session sources are excluded
before the recent-session limit, so their task completions cannot announce that
a user reply has ended. Each task category has its own enabled switch. Enabling its popup does not
enable sound or change the desktop-mode preference.

In following mode, if the host is in the background or the main pet is hidden,
this option shows a separate character/bubble panel at the lower-right of the
screen containing the pointer. It uses the current scale, fits inside the screen's
visible frame with a 16-point margin, and lasts six seconds after the latest
completion. Consecutive completions reuse the panel and merge counts. It never
becomes key/main or activates the app, and it ignores mouse events. The main
widget's geometry, quoted text, and stored desktop coordinates are untouched.

Sound is emitted independently on receipt; silent-popup and audio-only operation
both work. A popup-presented completion is not queued again for the main bubble
or a second sound on return. In desktop mode, or with the main host foreground
and the main pet visible, completions keep the original main-bubble behavior.
Disabling all task popups, switching to desktop mode, or returning to a visible
foreground host dismisses an existing transient panel. Displaying over other
apps' full-screen Spaces depends on macOS WindowServer rules and needs separate
manual verification; no application activation or Space switch is attempted.

Native panel verification (requires access to a logged-in GUI session):

```sh
GPT_NIANG_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./script/verify_completion_popup.sh
```

This compiles and runs the actual production controller, checking mouse
transparency, non-key/non-main status, foreground-app preservation, visible-screen
bounds, event merging, expiry and unchanged placement preferences. It briefly
shows the test panel. Optional `GPT_NIANG_POPUP_PREVIEW=/absolute/path.png` renders
only its own view to a PNG for layout inspection. The core verifier also checks
negative-origin and small-screen geometry; that does not substitute for physical
multi-monitor or full-screen Spaces testing.


### Application lifecycle verification

`bash script/verify_host_link.sh` runs the production lifecycle policy and
preference checks without XCTest. `GPT_NIANG_SDK` may select an installed SDK.
After building, `python3 script/verify_host_link_native.py dist/GPTNiangMac.app`
uses two temporary apps and the actual bundled helper to verify application
launch/quit, manual pet exit, disabling/re-enabling and helper restart while
the host is already open. It does not quit the user's real host or register a
persistent service. The corresponding XCTest cases are `HostLinkTests`.
Actual system background-activity approval and a host restart should also be
checked on the installed application; policy tests do not prove OS approval.

### Selectable alert sounds

Completion, command/permission, question, and quota alerts each have a sound
picker and explicit preview button. Choices are the original bundled sound and
macOS Ping, Glass, Pop, Tink, Basso (loaded from the system, not redistributed).
Old/missing/unknown selections fall back to the original sound without resetting
other preferences. Preview uses current volume, does not enable reminders, and
is disabled at zero volume. A new preview replaces the preceding alert sound.
Within one simultaneous batch, audible command/permission requests take priority,
then questions, then completion; the existing one-second audio coalescing remains.
If a selected system sound is unavailable, playback falls back to release.wav.

### Unclassified native notifications

Actual native notification requests with unrecognized kinds or unrecognized completion identities now produce a neutral ChatGPT reminder. Known permission/question/completion events keep their classification. Generic reminders inherit completion enabled, sound, tone and popup controls. Refresh/idle records and renderer copies still do not trigger alerts. This does not detect events the host never emits.

### Quota reset reminders

Short-period and weekly reset reminders have separate switches, both default off.
They are independent of low-balance alerts and keep the existing quota worker
active while the pet is hidden. They use quota system notifications, queued pet
bubbles and the existing quota sound/volume choice (no extra task popup).
A reminder requires a fresh successful identified-account reply with a later
reset deadline after the previous deadline has elapsed. A balance increase alone
or a countdown reaching zero does not trigger it. The first valid reply establishes
a baseline, and disabling clears that category's baseline. Missing reset times,
failed/stale replies and out-of-order samples never trigger resets. Per-account,
per-window observations are persisted atomically before delivery, so normal
refreshes and restarts do not repeat notifications. An offline rollover can be
reported once on the next valid refresh while enabled; multiple missed cycles
coalesce. A changed window length establishes a new baseline. Short means the
shortest timed window below one day; weekly means exactly 10080 minutes.
Delivery is usually within the worker's next 60-second refresh, not at an exact
wall-clock deadline. A reset reports the current remaining percentage, which
need not be 100% if usage has already resumed.

### Upstream integration and power investigation (2026-10-29)

Merged upstream b6f5eb8 with the local alert, quota reset, icon and lifecycle work.
The upstream custom click WAV/worker recovery/window clipping changes are retained.
The active macOS reminder pipeline is AlertCoordinator + CompletionPopupController;
the upstream completion helper is retained for its Windows consumers, and the
macOS CompletionNotificationController is not instantiated. The menu's completion
choice aliases the same preference shown in alert settings; legacy upstream
`taskCompletionBubble` is migrated only when no alert preferences exist.

Observed old installed GUI CPU time averaged about 7% of one core over 15 seconds,
with a separate process-list reading of 16.7%. The Node helpers were near idle.
A five-second stack sample contained window polling and SwiftUI layout/drawing.
After adaptive polling and animation gating, short background samples were about
0.4–0.7%; these are CPU measurements, not watts or a battery-runtime guarantee.
Foreground tests were interrupted by application switching and did not establish
a stable foreground performance baseline. Visible full-colour animation still
requires rendering. Full-screen/multimonitor, drag feel, real battery drain and
ChatGPT question delivery retain explicit manual acceptance requirements.

Full XCTest can now run with the locally installed Xcode without changing the
global developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path macos --disable-sandbox
```

The separate command-line toolchain still cannot resolve XCTest. The standalone
Swift scripts remain useful; window tests now use an isolated module cache.
