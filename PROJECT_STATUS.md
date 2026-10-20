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

## Validation so far

- 20 local monitor tests, 7 desktop aggregation/context tests and 8 new recovery/protocol tests passed.
- Native WPF working/drag, menu, gallery, rendering, quote voice, completion voice and 50 completion-reminder checks passed.
- All PowerShell source files parse successfully. Changed text has passed whitespace checks.
- Full Node run: 140 passed, 26 failed, 1 skipped. Failures involve sandbox-blocked process creation/named-pipe IPC; this is not a full green run.
- Full Windows run stopped at the unchanged upstream native occlusion test. Independent collection of every Windows test is still running.
- The live desktop app pipe returned access denied in this executor. Actual ordinary-chat/other-project start/end verification is still pending; protocol fixtures are not a substitute for live verification.

## Remaining work

Finish independent Windows checks, fix any code regressions, verify packaging, publish a candidate merge for CI, and update the original PR only after reviewing the results. The installed 1.3.12 widget has not been replaced.
