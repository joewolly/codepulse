# CodePulse

[![macOS validation](https://github.com/joewolly/codepulse/actions/workflows/validation.yml/badge.svg?branch=main)](https://github.com/joewolly/codepulse/actions/workflows/validation.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
[![Sparkle 2.9.2](https://img.shields.io/badge/Sparkle-2.9.2-blue)](https://github.com/sparkle-project/Sparkle)

CodePulse is a native macOS menu-bar timer, coding journal, and local insights
tool for developers. It is lightweight and local-first: there are no accounts,
cloud sync, telemetry, product analytics, or application-usage history.
Optional application automation observes only the current frontmost bundle
identifier while an explicit rule is enabled; it does not inspect windows or
retain app history. CodePulse contacts GitHub only to check for and
download authenticated app updates or to optionally enrich a local session with
read-only repository, pull request, and developer-tool metadata.

<p align="center">
  <img src="docs/images/menu-bar-session.png" alt="CodePulse menu-bar timer with a running coding session" width="420">
</p>

## What it does

- Starts, pauses, resumes, and finishes focused work sessions from the menu bar.
- Records optional projects, work types, goals, and outcomes in a searchable
  coding journal.
- Captures best-effort local Git context without changing the repository.
- GitHub context — associates local sessions with their GitHub repository and
  optionally their current pull request when the repository has a GitHub remote.
- Optionally records that Codex and/or OpenCode participated in a selected
  project's session using only local lifecycle metadata.
- Optionally starts, pauses, resumes, and saves a session from configured Codex
  or OpenCode lifecycle signals. Session Automation is disabled by default and
  never takes control of a manually started session.
- Saves reusable Session Presets for one-action manual Quick Start or eligible
  automation rules.
- Optionally starts and maintains a session while a configured application is
  frontmost, matching by bundle identifier rather than display name.
- Provides the local `codepulsectl` command for scriptable status, preset/manual
  start, pause, resume, and finish control while CodePulse is running.
- Provides richer local Insights for active time, sessions, projects, work types,
  developer-tool participation, Git activity, and GitHub context with native
  Swift Charts.
- Exports the currently filtered History as standard UTF-8 CSV.
- Exports the currently selected Insights timeframe and project as a deterministic
  local Markdown report.
- Archives projects that are no longer active without deleting their saved
  sessions, Insights, exports, presets, or automation rules.
- Exports and restores a versioned JSON backup of local CodePulse state.

## Download and install

CodePulse requires macOS 13 or later and is distributed as a Universal 2 app
for Apple silicon and Intel Macs.

Download the latest DMG from
[GitHub Releases](https://github.com/joewolly/codepulse/releases/latest), open
it, and drag CodePulse to Applications. The current build is intentionally not
Developer ID signed or notarized, so macOS may require an explicit first-launch
approval. Follow the safe first-launch instructions in
[`docs/releasing.md`](docs/releasing.md#installation-and-gatekeeper); do not
disable Gatekeeper globally.

Starting with CodePulse 0.4.2, authenticated in-app updates are provided by
Sparkle. After the initial installation, use **Settings → Check for Updates…**
or allow the automatic update check.

## Quick start

1. Click the CodePulse item in the menu bar.
2. Optionally choose a project and work type, then describe the session goal.
3. Start the session and pause or resume it as needed.
4. Finish the session, record an optional outcome, and save it to History.
5. Open History to search, filter, or edit saved sessions, or open Insights to
   review local activity and context-derived summaries.
6. If desired, create a **Settings → Session Presets** entry for a reusable
   Quick Start, then open **Settings → Integrations** to enable Codex or OpenCode
   context enrichment. Integrations are optional and separate from **Settings →
   Session Automation**, which is also optional and disabled by default.
7. For a shell, Shortcuts **Run Shell Script**, Raycast, Alfred, Stream Deck, or
   IDE task, use the bundled `codepulsectl` command described below.

Projects are optional. Adding a project grants CodePulse access only to the
folder you select, allowing it to read local Git metadata for that project.

## Getting started

On a fresh installation, CodePulse shows a short native introduction covering
local storage, optional Projects, and the first-session workflow. Accounts,
developer integrations, and Session Automation are optional. You can revisit
the introduction later from **Settings → General → Show Introduction…**.

## Backup and restore

Use **Settings → Data → Export Backup…** to save a portable, pretty-printed JSON
backup of local CodePulse projects, settings, presets, automation rules, saved
sessions, captured Git/GitHub context, developer-tool session context, and any
active-session timeline. The backup format remains `codepulse-backup` version 1,
so backups exported by CodePulse 0.8 can be restored by 0.9.

Use **Settings → Data → Restore Backup…** to inspect the selected backup before
confirming. Restore replaces the current local CodePulse data; it does not merge
sessions or projects. CodePulse first creates and verifies a private automatic
recovery backup at
`~/Library/Application Support/CodePulse/Backups/Pre-Restore Backup ...json`.
The newest five automatic pre-restore recovery backups are retained. A failed
restore leaves the current data in place or reports whether automatic rollback
succeeded.

Lifecycle changes are durably committed before CodePulse publishes start,
pause, resume, finish, save, or discard in memory. A failed lifecycle commit
leaves the prior session state available for retry. Finishing sessions and
pending automatic saves remain recoverable across relaunches, and repeated
save/replay attempts cannot create a second completed record for the same
session.

If an existing `state.json` cannot be read, CodePulse does not treat the
installation as fresh and does not overwrite the file. It opens a small
read-only recovery window with **Restore Backup…**, **Show Data Folder**, and
**Quit CodePulse**. Before an explicit restore, normal lifecycle, onboarding,
automation, and local-control writes are disabled. The original unreadable
bytes are preserved as a private local recovery copy when an explicit restore
is confirmed, under
`~/Library/Application Support/CodePulse/Backups/Unreadable State ...json`.

Restore is local-only and does not contact a cloud service. Session Automation
is restored but left disabled until it is reviewed and deliberately enabled
again. A backup moved to another Mac may contain project names and saved
folder-path snapshots whose security-scoped bookmarks no longer resolve; those
projects remain in CodePulse and are marked **Needs Relink** rather than being
deleted or silently bound to another folder. Restore is blocked while the
current installation has a running, paused, or finishing session.

## CSV and Markdown exports

Use **History → Export CSV…** to save exactly the completed sessions matching the
current History search and filters. The export uses standard UTF-8 CSV and a
user-selected local destination; an active session is not included.

Use **Insights → Export Report…** to save the currently selected timeframe and
project as a deterministic Markdown report. The report uses the existing local
Insights summary and contains no AI-generated commentary or cloud data.

Both exports are created locally at the destination you choose. CodePulse does
not upload CSV or Markdown exports.

## Project archiving

Use **Settings → Projects → Archive** when you want to retire a project without
deleting its CodePulse data. Archived projects are excluded from new-session
pickers, Quick Start, default-project selection, Session Automation, and direct
`codepulsectl` starts. CodePulse keeps the project record and does not rewrite
completed sessions.

Archived projects remain available in History and Insights, including History
CSV and Insights Markdown exports. Session Presets and automation rules that
reference an archived project are preserved and shown as unavailable until the
project is restored. Use **Restore** in Project Settings to make the same
project, preset, and rule eligible again. Archive state is part of local backup
configuration and is independent from **Needs Relink** folder status.

## External local control

`codepulsectl` is a small local controller. It talks to the running CodePulse
app through a versioned, CodePulse-owned local inbox and response path; it does
not edit `state.json`, execute shell input, contact a service, or require root,
Accessibility, or Screen Recording permission. The app validates each command,
rejects commands older than 30 seconds, and records a bounded UUID ledger so a
replayed command cannot run twice.

The preferred form starts a configured Session Preset by its unique name:

```sh
/Applications/CodePulse.app/Contents/Helpers/codepulsectl status
/Applications/CodePulse.app/Contents/Helpers/codepulsectl status --json
/Applications/CodePulse.app/Contents/Helpers/codepulsectl start --preset "CodePulse Coding"
/Applications/CodePulse.app/Contents/Helpers/codepulsectl pause
/Applications/CodePulse.app/Contents/Helpers/codepulsectl resume
/Applications/CodePulse.app/Contents/Helpers/codepulsectl finish
```

Direct manual start is also available when the project already exists in
CodePulse:

```sh
/Applications/CodePulse.app/Contents/Helpers/codepulsectl start \
  --project "CodePulse" --type coding --goal "Fix release verification"
```

CLI starts are manual sessions. CLI pause, resume, and finish behave like the
corresponding UI actions and take over an automatic session permanently for
that session. `finish` enters the normal finishing screen and does not save an
outcome automatically; save or discard it from the CodePulse UI.

`status` prints concise human-readable state. `status --json` prints only a
privacy-minimal versioned JSON status object. The command exits nonzero for
invalid arguments, an unavailable app, invalid state transitions, missing or
ambiguous presets/projects, expired/rejected commands, and local transport
failures. A response timeout is exit code 7; a mutation may already have been
applied, so re-read `status` before retrying. The embedded tool is not installed
into `/usr/local/bin`; add a shell alias or use its bundle path explicitly.

## Screenshots

### History

![CodePulse History showing privacy-safe sample coding sessions](docs/images/history.png)

### Insights

![CodePulse Insights showing local summary metrics, activity, work types, and project totals](docs/images/insights.png)

## Local data and privacy

CodePulse stores its state as JSON under the user's Application Support
directory. Session notes, project paths, settings, session presets, automation
rules, configured application bundle identifiers, active automation ownership,
Git snapshots, GitHub context snapshots, developer-tool session metadata, and
active session state stay on the Mac unless the user explicitly exports or
shares selected data or a backup.
Developer-tool metadata is limited to the tool name,
external session identifier, working directory, timestamps, lifecycle event
count, and optional model/profile labels. When Session Automation is enabled,
CodePulse uses only those local lifecycle signals and the working directory to
match an explicit rule to a configured project. CodePulse also keeps a local
deduplication ledger of processed event identifiers and timestamps (up to 2,048
entries; event processing prunes entries older than 30 days). This replay
bookkeeping remains local and is reset when a backup is restored; portable
backups include saved-session developer-tool contexts but omit the processed
event ledger. External CLI commands use a separate bounded local processing
ledger and transient response files; backup export intentionally omits that
control ledger and all command/response files. Inbox cleanup after processing is
best effort, so a filesystem failure may leave a local event file.
CodePulse does not collect
prompts, messages, responses, transcripts, source code, terminal command
contents, command output, tool-call arguments or results, permission decisions,
reasoning, conversation summaries, or credentials. Application automation, when
explicitly enabled, observes only which application is frontmost and compares
its bundle identifier with local rules. CodePulse does not collect or retain
application usage history, unrelated-app durations, window titles, document or
file names, browser URLs, screen contents, keystrokes, mouse input, clipboard
contents, or accessibility element contents.

Sparkle checks CodePulse release assets on GitHub. When `gh` is installed, the
optional GitHub Context feature uses the user's existing GitHub CLI setup for
read-only repository and pull request metadata. CodePulse does not store GitHub
credentials, and sessions still work without `gh`. See [`PRIVACY.md`](PRIVACY.md)
for the data-handling summary and [`SECURITY.md`](SECURITY.md) for vulnerability
reporting and the security model.

## Build from source

CodePulse is a Swift Package Manager application. On macOS with Xcode or a
Swift toolchain installed, run:

```sh
./script/build_and_run.sh
```

The script builds the package, stages a real app bundle, and launches it with
the macOS `open` command. To verify that the process starts:

```sh
./script/build_and_run.sh --verify
```

For release packaging, use `./script/package_release.sh` and follow
[`docs/releasing.md`](docs/releasing.md).

README screenshots are rendered from the real SwiftUI views with deterministic,
privacy-safe sample data. Regenerate them with:

```sh
./script/generate_readme_screenshots.sh
```

## Design notes

`SessionStore` owns the idle, running, paused, and finishing lifecycle. Session
duration is derived from timestamps and pause intervals rather than an
incrementing counter, which keeps recovery and calendar-boundary calculations
stable.

When a selected project is inside a local Git working tree, CodePulse reads the
repository root, branch, HEAD, and diff statistics at session boundaries. Git
capture is best-effort and read-only: failures never interrupt timing or saving.
Historical Git metadata is preserved when a completed session is edited.

CodePulse 0.5 adds GitHub Context for GitHub-hosted repositories: it can record the normalized
`owner/repository` identity and the pull request associated with the session's
branch. This enrichment is read-only, asynchronous, and failure-tolerant. It
uses the locally installed GitHub CLI (`gh`) when available; an authenticated
`gh` enables private repository and pull request metadata. CodePulse never asks
for or stores GitHub credentials and never sends session notes, timing, file
contents, or working-tree data to GitHub.

To inspect the optional CLI status yourself, use:

```sh
gh auth status
```

CodePulse 0.6 adds optional Developer Integrations for Codex and OpenCode. A
small local helper writes validated, versioned events to the CodePulse-owned
inbox at `~/Library/Application Support/CodePulse/Integrations/Inbox/`.
CodePulse associates an event only with the currently active, selected project
when the canonical working directory is that project's folder or a child
directory. No Project sessions and unrelated projects are ignored. Integration
context enrichment remains independent from Session Automation.

CodePulse 0.8 adds optional Session Automation for Codex, OpenCode, and explicit
frontmost-application rules. Session Presets hold reusable project, work type,
and goal values; automation rules reference presets by stable ID. A matching
developer-tool lifecycle signal or configured application bundle can start one
locally owned session; later claims can keep it alive, resume an automatic
pause, and finish and save it after the configured grace periods. Existing
active sessions are never switched to another project, manual lifecycle actions
take control immediately, and neither app activation changes nor raw event
files are retained as an activity history. The global automation setting is off
by default. `codepulsectl` adds bounded local manual control for status and the
normal session lifecycle; it does not add a cloud API, webhook, or network
control path.

CodePulse 0.7 adds Session Intelligence to Insights. It derives active-time
metrics from the existing local session history, supports calendar and rolling
timeframes plus project filtering, and shows participation-based developer-tool
counts, optional model/profile labels, neutral Git Activity totals, and
historical GitHub repository and pull-request context. These are local derived
views only: CodePulse does not add an analytics database, upload analytics, or
measure productivity.

History filters before grouping sessions by day and searches existing project,
journal, GitHub, and developer-tool metadata. Insights uses the user's local
calendar, apportions active time across day and week boundaries while excluding
pauses, and keeps historical GitHub snapshots unchanged.

## Tests

Run the deterministic SwiftPM test suite with:

```sh
swift test --configuration debug
```

Tests use injected clocks and calendars, so timer, relaunch, history, Git,
GitHub, Insights, and backup behavior can be verified without sleeping.

## License

CodePulse is available under the [MIT License](LICENSE).
