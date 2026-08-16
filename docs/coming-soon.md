# CodePulse coming-soon features

This document tracks feature directions accepted after the 1.0.0 release. It
is a working note, not a release commitment: ideas move between statuses as
they are specified, sized, and scheduled into milestone trains. Nothing here
requires cloud services, accounts, telemetry, or Apple code-signing.

## Status

- **Implemented** — shipped and working.
- **Accepted** — the direction is worth building; it may still need a spec.
- **Considering** — interesting, but not yet settled (scope, sizing, or fit).
- **Deferred** — intentionally not building for now; revisit later.

---

## Actionable insights

Insights today is a read-only summary of the past. The goal of this thread is
to turn recorded data into guidance without any cloud involvement.

| Feature | Status | Notes |
| --- | --- | --- |
| Weekly / daily local digest | Implemented | Summarize active time, sessions, projects, work types, and developer-tool participation for the period. Local notification; no account needed. |
| Goal vs. actual tracking | Accepted | Sessions already capture goals and outcomes. Compare planned intent against time spent, and surface unfinished goals in History and Insights. |
| Focus trends and streaks | Considering | Deep-work block detection, longest focus streak, context-switch cost, time-of-day heatmap. Needs a definition of "deep work" that fits one-window-at-a-time local data. |
| Per-project outcome narrative | Considering | What got finished vs. abandoned per project, per period. Draws on existing goal/outcome text; formatting needs care to stay useful, not fluffy. |

All computation stays local and deterministic, consistent with the existing
Markdown report export.

### Local daily and weekly digests

Daily and weekly digests are **opt-in** (Settings → Actionable Insights) and
disabled by default, including for existing installs. When enabled, CodePulse
summarizes the **previous completed local calendar day or week** — active time,
session count, top project and work type, and Codex/OpenCode participation,
plus a comparison with the preceding equivalent period — and delivers it as a
native macOS notification at the configured time. Delivery uses the local
`UNUserNotificationCenter`; no network request, account, or remote service is
involved, and nothing from a session's goal, outcome, paths, repositories,
branches, or pull requests ever appears in a notification.

Notification permission is requested only when a digest is first enabled, and
CodePulse remains fully usable if permission is denied. Sessions are clipped
at calendar boundaries using the same active-time rules as Insights, so a
session or pause crossing midnight or a week boundary is never double-counted.
A digest period is delivered once: pending requests are replaced (never
duplicated) when settings change, and a small local ledger prevents re-notifying
a period after relaunch.

---

## Data portability

Continuation of the v0.9 data-portability thread. The backup format remains
`codepulse-backup` version 1 unless noted otherwise.

| Feature | Status | Notes |
| --- | --- | --- |
| Merge backup restore | Accepted | Restore currently replaces local data and never merges (documented in README). Add a merge path that imports sessions, projects, presets, and rules from a backup into existing data without rewriting records. |
| Encrypted backups | Considering | Passphrase-protected JSON export. Must stay local-only and verify cleanly before write; integrity checks matter more than any cloud property. |
| Full local archive export | Considering | A single deterministic HTML or JSON archive of History, Insights, exports, and settings. Complements the existing CSV and Markdown exports. |

Merge restore and encrypted backups should not weaken the existing recovery
guarantees: pre-restore recovery backups, rollback on failure, and
no second completed record per session.

---

## Automation and control surface

Continuation of the v0.8 session-automation thread. Everything here remains
opt-in and disabled by default.

| Feature | Status | Notes |
| --- | --- | --- |
| Additional developer-tool participants | Accepted | Extend context enrichment beyond Codex and OpenCode (for example Cursor, Windsurf, Claude Code) using only local lifecycle metadata. |
| Pause on lock / screensaver | Considering | Auto-pause when the display locks or the machine idles; resume on return. Needs explicit rules and a way to opt out per session. |
| Auto-finish on long idle | Considering | Finish a session after a configurable inactivity window. Must never surprise: notification or countdown before finishing. |
| Shortcuts-native actions | Considering | Real Shortcuts actions instead of wrapping Run Shell Script. Also adds scriptable value to `codepulsectl`. |
| `codepulsectl` report surface | Considering | Add report-style output (daily/weekly summaries, JSON everywhere) so scripts can consume Insights without the UI. |
| Menu-bar project and timer at a glance | Accepted | The v1.0 Milestone 3 audit (`docs/m3-audit.md`) found the status item omits the selected project and session type. Show project and elapsed time in the menu-bar item, with concise accessibility output. |

---

## Out of scope

- **Apple Developer ID signing and notarization** — deliberately not pursued;
  the app stays unsigned and non-notarized. Gatekeeper friction on first
  launch is accepted, and `docs/releasing.md` documents the safe path.
- **Cloud sync, accounts, telemetry, or product analytics** — always out of
  scope; the local-first story is the product.
