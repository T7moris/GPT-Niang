# GPT Niang integration status

Updated: 2026-10-20 (Asia/Shanghai)

## Goal

Merge upstream 1.3.5 (`f906d61`) into the custom Windows branch while retaining pixel idle/working/drag animations, quote blips, completion voice, desktop work tracking and outside-click menu dismissal. Development package version: 1.3.13; this is not an upstream release.

## Implementation

- Imported and SHA-verified the upstream commit history and current source tree. Preserved the existing feature branch as a backup before merging.
- Retained upstream gallery, independent sizing, WAV import, music, auto-quotes, reply reminders, window/occlusion behavior and runtime fixes.
- Kept custom pixel modes and voice preferences. Gallery selection updates the static animation source; frame changes update alpha/color masks; music pauses and resumes frame playback.
- Restored long quote playback without weakening the five-second click-import limit.
- Work tracking now handles ChatGPT caller identity, an installation-scoped user-temp context relay, up to 500 recent tasks subject to the host's advertised limit, local desktop task status, streaming/queued states, unknown-status follow-up reads and safe failure diagnostics. Context changes reconnect automatically; endpoints and identities are never guessed or scanned.
- Local work starts/ends now coexist with upstream completion filtering and monitor restart recovery. Work tracking and completion voice remain independent of the bubble toggle.
- No question/answer experiment or completion animation assets were enabled.

## Validation

- 20 local monitor tests, 7 desktop aggregation/context tests and 8 new recovery/protocol tests passed.
- Native WPF working/drag, menu, gallery, rendering, quote voice, completion voice and 50 completion-reminder checks passed.
- All PowerShell source files parse successfully. Changed text has passed whitespace checks.
- Full Node run: 140 passed, 26 failed, 1 skipped. Failures involve sandbox-blocked process creation/named-pipe IPC; this is not a full green run.
- Windows validation covered 61 test scripts: 56 produced passing results, including independent reruns of the drag, menu and widget harnesses. Five checks remain unpassed: the Node child-pipe check, two unchanged native occlusion checks, installation Startup-directory access and updater file replacement. The executor denies the necessary process/desktop/filesystem access; these checks are not recorded as passed.
- The real WPF drag checks include 27 size/DPI cases with 2,214 samples, 108 vertical cases with 5,400 positions, and 216 horizontal cases with 18,144 positions. The nested menu lifecycle check passed 44 assertions.
- The Windows package built and passed archive integrity, runtime manifest and version validation. Upstream source, pixel assets and voice assets remain in the bundle; maintainer status is excluded from installation archives.
- The live desktop app pipe returned access denied in this executor. Actual ordinary-chat/other-project start/end verification is still pending; protocol fixtures are not a substitute for live verification.

## Published state and remaining limits

- Fork `main` now matches upstream `f906d61`.
- Merge commit `851e97e` is available on `integration/upstream-20261020` and `codex/dragon-voice-and-settings`. Original PR #46 is open and GitHub reports it mergeable.
- The two upstream Actions runs are `action_required`: the upstream maintainer must approve them before they can execute. No CI success is claimed.
- The installed 1.3.12 widget has not been replaced. The installer preflight's Startup write and live app pipe access are denied in this executor. Do not treat a packaged build or protocol fixtures as a completed installation or live cross-project acceptance.
- Later verification should use the normal desktop execution context, preserve the existing settings, and observe ordinary-chat and other-project work start/end before claiming live acceptance. The paused question/answer experiment remains excluded.
