# CodePulse coming-soon features

This document tracks feature directions accepted after the 1.0.0 release. It
is a working note, not a release commitment: ideas move between statuses as
they are specified, sized, and scheduled into milestone trains. Nothing here
requires cloud services, accounts, telemetry, Developer ID signing, or
notarization.

## Status

- **Implemented** — shipped and working.
- **Accepted** — the direction is worth building; it may still need a spec.
- **Considering** — interesting, but not yet settled (scope, sizing, or fit).
- **Deferred** — intentionally not building for now; revisit later.

---

## Actionable insights

Insights is a read-only, local view of recorded work. The currently planned
Actionable Insights set is implemented: deterministic summaries and reminders
make the existing timing, Goal/Actual, and focus signals easier to inspect
without cloud involvement or AI interpretation.

| Feature | Status | Notes |
| --- | --- | --- |
| Weekly / daily local digest | Implemented | Summarize active time, sessions, projects, work types, developer-tool participation, and aggregate missing-outcome follow-up reminders for the period. Local notification; no account needed. |
| Goal vs Actual tracking | Implemented | Insights aggregates, the History follow-up/closed-loop workflow, Markdown aggregate export, and a digest follow-up signal compare recorded goals with outcomes without judging achievement. |
| Focus trends and streaks | Implemented | Deterministic Focus Patterns provide focus blocks, sustained-focus share, rapid identified project switches, a best focus day, and local time-of-day distribution. This version has no productivity score and does not claim to measure deep-work quality or cognitive cost. |
| Per-project outcome narrative | Implemented | Project Outcomes provides deterministic per-project summaries combining completed-session duration, Goal-vs-Actual state, recent recorded Goal/Actual pairs, and missing-outcome follow-up without AI or success/failure inference. |

All computation stays local and deterministic, consistent with the existing
Markdown report export.

### Local daily and weekly digests

Daily and weekly digests are **opt-in** (Settings → Data → Actionable Insights) and
disabled by default, including for existing installs. When enabled, CodePulse
summarizes the **previous completed local calendar day or week** — active time,
session count, top project and work type, Codex/OpenCode participation, and an
aggregate count of completed goal-bearing sessions missing outcomes when
applicable, plus a comparison with the preceding equivalent period — and delivers it as a
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

Continuation of the v0.9 data-portability thread. The current 1.4-era backup
format is `codepulse-backup` version 2; the planned concurrent-session
milestone adds version 3 as described above.

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
| Menu-bar project and timer at a glance | Implemented | The native menu-bar presentation shows the selected project, session type, and elapsed timer with concise accessibility output. |

---

## Multi-Project Workspaces

CodePulse is evolving from project-aware session tracking into a workspace
model. A workspace is an organizational layer above projects, allowing multiple
projects to be grouped together without combining histories, insights, or
session context. Existing project behavior remains unchanged.

| Feature                         | Status      | Notes                                                                                                                                                                                                                    |
| ------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Workspace foundation            | Implemented | Introduce a workspace container that can own one or more projects while preserving existing project-level sessions, insights, and history. Existing installs migrate into a default workspace without changing behavior. |
| Workspace switching             | Implemented | Allow users to switch between active workspaces and quickly resume different areas of work without losing context.                                                                                                       |
| Workspace dashboards            | Implemented | Provide workspace-level views combining project activity, recent sessions, and aggregate activity while keeping project data separated.                                                                                  |
| Cross-project activity insights | Implemented | Show deterministic local patterns across current Workspace Projects, including focus distribution, switching patterns, and time allocation without productivity scoring or cloud analysis. |
| Resume context                  | Implemented | Provide deterministic local context for returning to active Projects, including recent recorded sessions, Goal/Outcome state, and available Git/GitHub/developer-tool context. |
| Workspace intelligence          | Implemented | Workspace Intelligence v1 derives local Resume Context and continuation hints from recorded state. It uses no AI interpretation, productivity scoring, or cloud analysis. |

Implementation should happen incrementally:

1. Workspace foundation

   - Add workspace persistence model
   - Migrate existing projects into a default workspace
   - Keep current project workflows working

2. Workspace experience

   - Workspace selector
   - Workspace dashboard
   - Workspace-scoped navigation

3. Workspace intelligence

   - Cross-project patterns
   - Resume context
   - Local continuation hints

The goal is a clear view of both an individual project's state and the broader
portfolio of active work while preserving CodePulse's local-first privacy
model. The three-phase Workspace sequence is implemented. Workspace
Intelligence v1 is deterministic and local: it does not interpret work with AI,
assign productivity scores, or analyze data in the cloud.

---

## Concurrent Sessions & Thread-Native Tracking

**Status:** Accepted
**Target:** v1.5.0
**Normative specification:** [`docs/v1.5-concurrent-sessions.md`](v1.5-concurrent-sessions.md)

CodePulse currently has a single globally active Session even though Projects
can be organized into multiple Workspaces. The accepted v1.5 direction makes
active Sessions first-class and independent:

- multiple concurrent active Sessions, including same-Project work;
- thread-native Developer-Tool identity using `(tool, externalSessionID)`;
- independent Codex/OpenCode, cross-Project, and cross-Workspace tracking;
- independent manual and automated lifecycle, save, and per-Session Git
  capture;
- a multi-session menu-bar Active Sessions hub with per-Session accessibility;
- overlap-safe Insights that distinguish wall-clock **Active Time** from
  summed **Session Activity**;
- schema-3 and backup-v3 migration with lossless v1/v2 compatibility; and
- local, bounded, metadata-only privacy with no prompt, transcript, command,
  source, cloud, or telemetry collection.

The linked document is the reviewed product and technical contract for a later
implementation branch. v1.5 is not implemented by this roadmap entry.

---

## Out of scope

- **Apple Developer ID signing and notarization** — deliberately not pursued;
  releases are ad-hoc signed locally and remain non-notarized. Gatekeeper
  friction on first launch is accepted, and `docs/releasing.md` documents the
  safe path.
- **Cloud sync, accounts, telemetry, or product analytics** — always out of
  scope; the local-first story is the product.
