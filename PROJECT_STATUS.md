# GPT Niang integration status

Updated: 2026-10-21 19:50 (Asia/Shanghai)

## Goal

Merge upstream `main` at `b6f5eb8` into the custom Windows branch while retaining pixel idle/working/drag animations, quote blips, completion voice, desktop work tracking and outside-click menu dismissal. Development package version: 1.3.15; this is not an upstream release.

## Implementation

- Imported and SHA-verified the upstream commit history and current source tree. Preserved the existing feature branch as a backup before merging.
- Retained upstream gallery, independent sizing, WAV import, music, auto-quotes, reply reminders, window/occlusion behavior and runtime fixes.
- Kept custom pixel modes and voice preferences. Gallery selection updates the static animation source; frame changes update alpha/color masks; music pauses and resumes frame playback.
- Restored long quote playback without weakening the five-second click-import limit.
- Merged upstream's native click-audio worker and stable PowerShell supervisor/binding recovery. Kept 60-second quote playback and voice/click mutual exclusion; preserved compatibility with the previous `wscript.exe` supervisor task paths.
- Work tracking now handles ChatGPT caller identity, an installation-scoped user-temp context relay, up to 500 recent tasks subject to the host's advertised limit, local desktop task status, streaming/queued states, unknown-status follow-up reads and safe failure diagnostics. Context changes reconnect automatically; endpoints and identities are never guessed or scanned.
- Local work starts/ends now coexist with upstream completion filtering and monitor restart recovery. Work tracking and completion voice remain independent of the bubble toggle.
- Local active turns refresh from session-log writes and expire after 120 seconds without a new write. Each session now retains only its latest active turn: a new start clears older turns whose terminal records were missed, and log activity refreshes only the latest turn.
- No question/answer experiment or completion animation assets were enabled.

## Validation

- 20 local monitor tests, 7 desktop aggregation/context tests and 8 new recovery/protocol tests passed.
- Native WPF working/drag, menu, gallery, rendering, quote voice, completion voice and 50 completion-reminder checks passed.
- All PowerShell source files parse successfully. Changed text has passed whitespace checks.
- Full Node run after the sync: 166 passed, 0 failed, 1 macOS-only test skipped.
- Windows regression: 58 of 60 scripts passed, and widget-only passed. `host-occlusion` and `occlusion-reminder` both failed at the real full-foreign-coverage/DWM-cloak assertion; the underlying occlusion source was not changed in this sync, and the cause remains unconfirmed.
- Installation/supervisor isolation passed all 44 assertions, including old `wscript.exe` task paths, read-only missing-binding recovery and rejection of foreign tasks. Audio import, native click queue, quote/completion voice, settings, gallery, drag/working animation and WPF entrypoint checks passed. PowerShell parsing and `git diff --check` passed.
- The real WPF drag checks include 27 size/DPI cases with 2,214 samples, 108 vertical cases with 5,400 positions, and 216 horizontal cases with 18,144 positions. The nested menu lifecycle check passed 44 assertions.
- The 1.3.15 Windows package contains 214 files and passed archive/package validation (SHA256 `F90973074FC072DDF373AF24B7301A49C43816CC0EB127745749C015A52D689D`). The local 1.3.14 installation was replaced through the transactional updater; transaction committed, 105 installed files matched the candidate, and `settings.json` plus `quotes.json` hashes stayed unchanged. The registered plugin is enabled, preflight passes, and the visible widget publishes a 1.3.15 heartbeat with `characterWorking=false` and the idle animation. Cloud status currently reports zero active tasks but `APP_STATUS_TIMEOUT`, so cross-project live detection remains unverified. No functional test suite was run for this change; Node syntax and package validation passed.
- Actual ordinary-chat/other-project start/end verification is still pending; protocol fixtures are not a substitute for live verification.

## Published state and remaining limits

- Fork `main` matches upstream `b6f5eb8972d1802821006b7208d20a834fa6a08b`.
- The upstream merge and PR #46 remain on `codex/dragon-voice-and-settings`; stale-work fix `204a948` and startup visibility fix `d455015` are pushed, and `git ls-remote` verified the remote head is `d455015`.
- PR #46 now also contains the 1.3.15 stale-turn fix and release metadata; GitHub verified the updated head as `16c84582f1515a15341cda9377fd6ca216175852`.
- The two upstream Actions runs are `action_required`; no CI success is claimed.
- The installed widget is now 1.3.15 and is visibly idle. The cloud RPC still times out; do not treat its zero cached active count as live cross-project acceptance.
- Later verification should use the normal desktop execution context, preserve the existing settings, and observe ordinary-chat and other-project work start/end before claiming live acceptance. The paused question/answer experiment remains excluded.

