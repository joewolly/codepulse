# CodePulse

[![macOS validation](https://github.com/ZacharyRW/codepulse/actions/workflows/validation.yml/badge.svg?branch=main)](https://github.com/ZacharyRW/codepulse/actions/workflows/validation.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
[![Sparkle 2.9.2](https://img.shields.io/badge/Sparkle-2.9.2-blue)](https://github.com/sparkle-project/Sparkle)

CodePulse is a native macOS menu-bar timer, coding journal, and local insights
tool for developers. It is lightweight and local-first: there are no accounts,
cloud sync, telemetry, product analytics, or activity monitoring. CodePulse
contacts GitHub only to check for and download authenticated app updates or to
optionally enrich a local session with read-only repository, pull request, and
developer-tool metadata.

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
- Receives optional local Codex, Claude Code, and OpenCode lifecycle metadata through a
  versioned, content-safe event boundary and records matching local runs as
  active, waiting, review-grace, or ended intervals. It never starts or
  controls a manual CodePulse session; cloud-only sessions without a local
  hook/process are not tracked.
- Shows all current manual and agent runs together in **Active Now**, including
  a review-grace countdown and waiting state. Agent runtime, manual active time,
  and de-duplicated combined wall-active time remain separate measures.
- Classifies agent activities from content-safe local metadata into independent
  work-type and domain labels. Prompt classification is not currently
  implemented or enabled.
- Includes a signed, versioned offline pricing catalog and optional Codex,
  Claude Code, and OpenCode token-usage adapters. Each adapter is separately
  off by default, remains independent from lifecycle timing, and stores only
  privacy-safe usage metadata. Every API-equivalent or Codex-credit value is
  clearly an estimate with immutable source provenance.
- Provides richer local Insights for active time, sessions, projects, work types,
  developer-tool participation, Git activity, and GitHub context with native
  Swift Charts.
- Adds Usage Insights for selected periods/projects: manual versus agent timing,
  waiting, token and labeled cost breakdowns, privacy-safe sample details, and
  local CSV/JSON export with opt-in context labels.
- Lets users inspect and delete CodePulse-held data for an individual developer
  integration, and generate a redacted local support bundle containing only
  aggregate diagnostics.
- Exports a versioned JSON backup of local CodePulse state.

## Download and install

CodePulse requires macOS 13 or later and is distributed as a Universal 2 app
for Apple silicon and Intel Macs.

Download the latest DMG from
[GitHub Releases](https://github.com/ZacharyRW/codepulse/releases/latest), open
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
6. If desired, open **Settings → Integrations** to enable local Codex, Claude
   Code, or OpenCode lifecycle tracking. It is optional, timing-only, and never
   controls the manual timer.
7. When enabled integrations have local activity, use **Active Now** to inspect
   concurrent runs; only the current CodePulse-owned manual timer can be
   finished from this view.
8. If you use Codex, Claude Code, or OpenCode locally, enable its **Track token
   usage** control separately in Settings to collect local token counters. See
   [`docs/codex-usage-tracking.md`](docs/codex-usage-tracking.md) before
   enabling Codex tracking or
   [`docs/claude-code-usage-tracking.md`](docs/claude-code-usage-tracking.md)
   before enabling Claude Code tracking, or
   [`docs/opencode-usage-tracking.md`](docs/opencode-usage-tracking.md) before
   enabling OpenCode tracking.
9. Open **Insights** to compare manual active time, agent runtime, combined
   wall-active time, waiting, and optional usage/cost representations. Its
   **Export** menu writes the selected period locally; workspace and activity
   labels are opt-in, and paths/source identifiers are never exported.
10. In **Settings → Integration Data**, review the stored metadata categories,
    remove one integration's CodePulse-held records when needed, export a
    full-fidelity recovery backup only for private recovery, or export a
    redacted support bundle for local troubleshooting.

Projects are optional. Adding a project grants CodePulse access only to the
folder you select, allowing it to read local Git metadata for that project.

## Screenshots

### History

![CodePulse History showing privacy-safe sample coding sessions](docs/images/history.png)

### Insights

![CodePulse Insights showing local summary metrics, activity, work types, and project totals](docs/images/insights.png)

## Local data and privacy

CodePulse stores its state as JSON under the user's Application Support
directory. Session notes, project paths, settings, Git snapshots, GitHub context
snapshots, developer-tool session metadata, redacted v2 receipt diagnostics,
and active session state stay on the Mac unless the user exports or shares a
backup. The v2 diagnostics retain only receipt status, fixed redacted rejection
codes, parser/integration versions, and installation-salted event fingerprints.
CodePulse also keeps a local deduplication ledger of processed event identifiers
and timestamps (up to 2,048 entries; event processing prunes entries older than
30 days), which may appear in exported backups. Inbox cleanup after processing
is best effort, so a filesystem failure may leave a local event file. CodePulse
does not collect prompts, responses, transcripts, source code, terminal command
contents, command output, tool-call arguments or results, permission decisions,
reasoning, conversation summaries, or credentials.

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

This fork has its own release line and treats the historical parent as a peer
for selective, reviewed feature ports. See
[`docs/fork-release-line.md`](docs/fork-release-line.md) for the collision-safe
tag workflow and the reserved `0.9.0` release line.

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

CodePulse's optional Developer Integrations use a small local helper to
normalize lifecycle metadata into `DeveloperEventV2`. The receiver validates
event size, schema, timestamp, integration, and idempotency before passing it
through CodePulse-owned v2 inboxes. It keeps bounded, redacted diagnostics and
never persists prompts, transcripts, source content, commands, or raw hook
bodies. Codex and Claude Code hooks, plus the OpenCode local plugin event API,
map local lifecycle signals into the shared agent-run state machine. Claude
subagents remain separate runs linked to their parent by an installation-salted
fingerprint. A run is correlated with an existing local workspace, a valid Git
worktree discovered from its event, or a specific non-Git folder/local-file
task. The filesystem root, home directory, and temporary locations become
transient tasks instead of overly broad projects. Sibling Git worktrees stay
separate; equivalent clones can share one workspace. These integrations do not
start or control a manual CodePulse session, and cloud-only sessions are
excluded. **Active Now** lists concurrent active, review-grace, and waiting
runs without summing overlaps as personal time; activity details expose only
safe state-transition timelines. See
[`docs/agent-run-state-machine.md`](docs/agent-run-state-machine.md) for the
event mapping and timing rules, and
[`docs/codex-lifecycle-integration.md`](docs/codex-lifecycle-integration.md)
and [`docs/claude-code-lifecycle-integration.md`](docs/claude-code-lifecycle-integration.md)
and [`docs/opencode-lifecycle-integration.md`](docs/opencode-lifecycle-integration.md)
and [`docs/git-workspace-discovery.md`](docs/git-workspace-discovery.md) for
setup, privacy, discovery, and uninstall details. See
[`docs/concurrent-activity-ui.md`](docs/concurrent-activity-ui.md) for the
concurrent-run display and aggregate timing rules.

Activity labels retain the existing work types while adding a separate domain
such as Documentation or Automation. By default, classification uses only
content-safe lifecycle/tool metadata and workspace/file-type signals. Prompt
classification is deferred: no current integration sends prompt text to
CodePulse for this purpose. Activity detail controls allow local corrections,
which always take precedence and never train or send data. See
[`docs/activity-classification.md`](docs/activity-classification.md) for the
rule, consent, and precedence contract.

The pricing foundation keeps provider-reported cost separate from
API-equivalent estimates, Codex-credit estimates, subscription/actual-charge-
unknown state, and unpriced values. It verifies signed, versioned catalogs and
retains a bundled offline catalog, while a bad, replayed, expired remote cache,
or unavailable network cannot replace a verified price source. Codex, Claude
Code, and OpenCode token usage are separately opt-in and remain local; adapters
never turn timing consent into token-reading consent. Claude parent and subagent
samples remain individually inspectable, while roll-ups count child usage once.
OpenCode usage arrives only through the managed plugin's content-safe event
handoff; an absent or unsupported handoff affects usage only. See
[`docs/pricing-catalog.md`](docs/pricing-catalog.md) for the catalog source,
signature, fallback, calculation, and labeling rules, and
[`docs/codex-usage-tracking.md`](docs/codex-usage-tracking.md) for the reader's
privacy and attribution rules, plus
[`docs/claude-code-usage-tracking.md`](docs/claude-code-usage-tracking.md) for
the Claude Code transcript-metadata boundary and roll-up rules, plus
[`docs/opencode-usage-tracking.md`](docs/opencode-usage-tracking.md) for the
OpenCode event boundary and adapter-health states.

CodePulse also provides a local usage-attribution layer for the currently
stored privacy-safe samples. It groups tokens and cost representations by
workspace, activity, work type, domain, integration, provider, model, effort,
and service mode, while retaining an explicit **Unassigned** or **Unknown**
bucket whenever a relationship is missing or inconsistent. Its timing metrics
keep manual active time, summed agent runtime, unioned combined wall-active
time, and agent waiting separate; concurrent runs never inflate wall-active
time. See [`docs/usage-attribution.md`](docs/usage-attribution.md) for metric
definitions, reconciliation, and redaction rules.

Usage Insights applies the selected period and project filter to the same local
attribution layer. It presents manual active time, summed agent runtime,
de-duplicated wall-active time, waiting, tokens, and each cost representation
without treating estimates as charges. Privacy-safe sample details and local
JSON/CSV exports retain selected date ranges, explicit source labels, and cost
provenance. Workspace/activity labels are opt-in; paths, raw identifiers,
fingerprints, prompts, and transcript content are never exported. See
[`docs/usage-insights.md`](docs/usage-insights.md) for definitions, data quality
states, and the export schema.

The agent-aware release keeps integration data and supportability local: each
tool's saved agent runs, usage samples, diagnostics, and checkpoints can be
deleted from Settings without changing user-owned logs or tool configuration.
The support bundle is a separate, aggregate-only JSON artifact that excludes
paths, source/session identifiers, prompts, transcripts, commands, source
content, and session text. See
[`docs/agent-aware-release.md`](docs/agent-aware-release.md) for migration,
rollback, release preflight, setup/removal, manual validation, and known limits.

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
