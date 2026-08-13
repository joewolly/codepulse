# CodePulse: Agent-Aware Activity and Usage Tracking Roadmap

**Status:** Finalized planning document  
**Development target:** the contributor's fork of CodePulse  
**Initial integrations:** Codex, Claude Code, and OpenCode  
**Scope:** local processes and locally available session/usage records only

## Purpose

Turn CodePulse from a single manually started stopwatch into an optional, privacy-preserving local activity recorder for work performed with coding agents. It must accurately distinguish active work from long waits, discover workspaces without prior setup, support concurrent agent sessions, and provide trustworthy token and cost Insights without pretending subscription usage is an invoice.

This document is the implementation source of truth. Each feature is intentionally reviewable in isolation, uses a branch and PR in the contributor's own fork, and is composed of small, testable commits that are pushed immediately. Upstream contribution is optional and happens later only if the upstream owner wants it.

## Final decisions

| Topic | Final decision |
|---|---|
| Development workflow | Develop and merge in the contributor's own fork first; submit selected clean features upstream only if invited/wanted. |
| Agent scope | Codex, Claude Code, and OpenCode in the first release. |
| Token access | A separate, off-by-default **Track token usage** toggle for each integration. Activity tracking does not require token tracking. |
| Classification privacy | Metadata-only automatic classification by default. Optional enhanced classification may examine a prompt locally and transiently; it never stores or transmits prompt text. |
| Classification dimensions | Retain current work types (Coding, Debugging, Planning, Review, Research) and add a separate activity-domain dimension. |
| Manual + agent work | A matching manual activity may absorb agent runs, while manual time, agent runtime, and combined wall time remain distinct measures. |
| Costs | Preserve reported cost, API-equivalent estimate, Codex-credit estimate, subscription/unpriced state, and calculation provenance. The user selects a primary display per integration. |
| Prices | A signed, versioned pricing manifest with a bundled offline fallback. Historical calculations retain the catalog version used. |
| Codex credits | Estimate from the applicable official OpenAI/Codex rate card; never represent an estimate as remaining or billed credits. |
| Claude subagents | Show child runs individually and provide a parent roll-up that de-duplicates child totals. |
| Application architecture | Retain the SwiftPM/macOS structure and evolve it incrementally. `SessionStore` remains the app-facing facade while integration ingestion, enrichment, and legacy manual-session compatibility move into focused collaborators as agent features require them. |
| Build tooling | SwiftPM commands and repository scripts are the canonical local build/test path. XcodeBuildMCP is optional for targeted Xcode debugging or profiling, not a CI or release dependency. |
| CI and release automation | Keep validation focused on pull requests and `main`; use least-privilege permissions, cancelled superseded validation runs, bounded job time, and a non-publishing release preflight. Keep release publication isolated to the signed tag workflow. |
| Dependency maintenance | Use Dependabot for weekly Swift and GitHub Actions update PRs. Do not auto-merge dependency or release-workflow updates; require normal macOS validation and review. |
| Review grace | Default three minutes after agent completion/stop, unless resumed or a lifecycle state ends it sooner. |
| Budgets | Deferred until after the Usage Insights release is validated. |
| Cloud-only runs | Explicitly out of scope initially. A session must have a local process, hook, or local usage record accessible to CodePulse. |

## Product rules and privacy boundary

1. Agent timing and usage accounting are separate pipelines. A failed parser or disabled usage permission must never prevent timing from working.
2. The app reads only user-authorized, local integration data. It does not upload prompts, source code, transcript text, file contents, terminal commands, or raw session logs.
3. Prompt text is never persisted. Enhanced classification processes it in memory, locally, only after explicit opt-in, and discards it before event persistence.
4. Persist only the minimum event metadata necessary for identity, timing, classification, token aggregation, and diagnostics: integration, external-session ID, timestamps, lifecycle kind, workspace identity, model/effort/service mode, token counters, and parser/catalog versions.
5. Store a stable salted digest instead of a raw external session ID when an integration permits it; retain the reversible identifier only where continuation requires it, protected using platform storage controls.
6. The UI labels all financial figures correctly: **reported**, **API-equivalent estimate**, **Codex-credit estimate**, **included/subscription—actual charge unknown**, or **unpriced**.
7. No keyboard/mouse surveillance, screen capture, cloud relay, or terminal polling is introduced for activity determination. Agent lifecycle signals are the source of truth.
8. A user can disable an integration, disable its token reader, delete stored integration data, and export only the metadata described in the privacy screen.

## Target information model

```text
Workspace
  └─ Activity (user-facing task; optional manual container)
      ├─ Run (one manual or agent execution context)
      │   ├─ Interval (active, waiting, review-grace, ended)
      │   └─ Usage sample (metadata-only, de-duplicated)
      └─ Classifications (work type + activity domain + confidence/source)

Derived analytics
  • Personal/combined wall-active time = union of eligible intervals
  • Manual active time = manual intervals only
  • Agent runtime = sum of agent active intervals (overlap allowed)
  • Waiting = visible but excluded from active totals
  • Parent Claude roll-up = parent-exclusive usage + child usage once
```

### Core entities

- **Workspace:** durable identity for a Git repository, Git worktree, non-Git folder, or local-file task. A Git remote/repository identity groups related worktrees while each working root can remain separately visible.
- **Activity:** a user-facing container that has an activity domain and one or more work-type segments. A manually started activity can absorb matching agent runs.
- **Run:** an individual manual timer or external agent session. Runs are never collapsed merely because they share a workspace.
- **Interval:** an immutable time span with state/reason. Intervals make waiting and overlaps auditable.
- **Usage sample:** normalized, source-stamped token/cost metadata. Raw logs and transcript content are not stored.

### Classification dimensions

Work type remains one of `coding`, `debugging`, `planning`, `review`, or `research`. Activity domain is separately classified as `development`, `fileOrganization`, `automation`, `administration`, `documentation`, `localTask`, or `unknown`. A burst can change work type without changing its workspace or activity.

## Git and PR workflow

Use the fork as the integration home:

```text
upstream/main ──(intentional sync)──> origin/main (your fork)
                                         ├─ feature/00-roadmap
                                         ├─ feature/01-persistence-migrations
                                         └─ … feature/18-release-hardening
```

1. Configure `origin` for the contributor's fork and `upstream` for `joewolly/codepulse` (or the current official repository URL).
2. Open every roadmap PR from `feature/NN-name` into **your fork's `main`**. Review, merge, and tag progress there.
3. Before a new feature, update the local `main` from the fork. Sync upstream by an intentional merge or rebase; do not hard-reset a diverged fork.
4. For eventual upstream contribution, create fresh clean branches from then-current `upstream/main` and cherry-pick/recreate only the coherent commits the owner wants. Do not assume the upstream maintainer wants every architectural feature.

### Required loop for every numbered implementation step

Each step below ends with an exact commit message. After implementing that step:

1. Run the listed focused tests (plus formatter/linter if the repository uses one).
2. Inspect `git diff` and `git status`; do not mix unrelated changes into the commit.
3. Commit using the exact message shown.
4. Push the branch immediately: `git push -u origin <feature-branch>` on its first push, then `git push origin <feature-branch>`.
5. Record any deviation, migration caveat, or manual test in the PR description and update this roadmap's status table when the feature is merged.

### Baseline verification command set

Adapt the exact target names to CodePulse's existing build configuration, but maintain these layers throughout: unit tests for model/store logic, integration tests for parsers/installers, migration fixture tests, and a manual macOS smoke test for menu-bar/UI changes.

```bash
swift build --configuration debug
swift test --configuration debug
script/build_and_run.sh
```

## Roadmap sequence

| Feature | Outcome | Depends on |
|---|---|---|
| 00 | This accepted, executable roadmap | — |
| 01 | Versioned persistence and loss-safe migration | 00 |
| 02 | Workspace/activity/run/interval model | 01 |
| 03 | Normalized developer-event intake and durable diagnostics | 02 |
| 04 | Agent-aware state machine and accurate active/waiting time | 03 |
| 05 | Codex local lifecycle integration | 04 |
| 06 | Claude Code local lifecycle integration | 04 |
| 07 | OpenCode local lifecycle integration | 04 |
| 08 | Git workspace discovery and automatic project creation | 05–07 |
| 09 | Non-Git/local-file discovery and manual-agent matching | 08 |
| 10 | Concurrent-session UI and aggregate timing metrics | 02, 04, 08–09 |
| 11 | Privacy-first automatic classification | 03, 09 |
| 12 | Pricing catalog, provenance, and cost representations | 01, 03 |
| 13 | Codex usage adapter and official credit estimates | 05, 12 |
| 14 | Claude usage adapter and subagent roll-ups | 06, 12 |
| 15 | OpenCode usage adapter | 07, 12 |
| 16 | Project/domain/work-type usage attribution | 10–11, 13–15 |
| 17 | Usage Insights and exports | 16 |
| 18 | Privacy, resilience, release hardening, and deferred-budget preparation | 17 |

## Execution status

Update this table as each feature moves. A feature is **Merged** only after its
PR has actually merged into the fork's `main`; use **In review** while the PR is
open, and leave the merged date empty until then. `—` marks a value that does
not exist yet.

| Feature | Owner | Branch | PR | Status | Merged |
|---|---|---|---|---|---|
| 00 | @ZacharyRW | `feature/00-roadmap` | [#1](https://github.com/ZacharyRW/codepulse/pull/1) | Merged | 2026-08-12 |
| 01 | @ZacharyRW | `feature/01-persistence-migrations` | [#3](https://github.com/ZacharyRW/codepulse/pull/3) | Merged | 2026-08-12 |
| 02 | @ZacharyRW | `feature/02-activity-domain-model` | [#4](https://github.com/ZacharyRW/codepulse/pull/4) | Merged | 2026-08-12 |
| 03 | @ZacharyRW | `feature/03-developer-event-v2` | [#5](https://github.com/ZacharyRW/codepulse/pull/5) | Merged | 2026-08-12 |
| 04 | @ZacharyRW | `feature/04-agent-aware-timing` | [#7](https://github.com/ZacharyRW/codepulse/pull/7) | Merged | 2026-08-12 |
| 05 | @ZacharyRW | `feature/05-codex-lifecycle` | [#9](https://github.com/ZacharyRW/codepulse/pull/9) | Merged | 2026-08-13 |
| 06 | @ZacharyRW | `feature/06-claude-lifecycle` | [#10](https://github.com/ZacharyRW/codepulse/pull/10) | Merged | 2026-08-13 |
| 07 | @ZacharyRW | `feature/07-opencode-lifecycle` | [#11](https://github.com/ZacharyRW/codepulse/pull/11) | Merged | 2026-08-13 |
| 08 | @ZacharyRW | `feature/08-git-workspace-discovery` | [#12](https://github.com/ZacharyRW/codepulse/pull/12) | Merged | 2026-08-13 |
| 09 | @ZacharyRW | `feature/09-local-task-discovery` | [#14](https://github.com/ZacharyRW/codepulse/pull/14) | Merged | 2026-08-13 |
| 10 | @ZacharyRW | `feature/10-concurrent-activity-ui` | [#15](https://github.com/ZacharyRW/codepulse/pull/15) | Merged | 2026-08-13 |
| 11 | @ZacharyRW | `feature/11-activity-classification` | [#16](https://github.com/ZacharyRW/codepulse/pull/16) | Merged | 2026-08-13 |
| 12 | @ZacharyRW | `feature/12-pricing-catalog` | [#17](https://github.com/ZacharyRW/codepulse/pull/17) | Merged | 2026-08-13 |
| 13 | @ZacharyRW | `feature/13-codex-usage` | [#18](https://github.com/ZacharyRW/codepulse/pull/18) | Merged | 2026-08-13 |
| 14 | @ZacharyRW | `feature/14-claude-usage` | [#19](https://github.com/ZacharyRW/codepulse/pull/19) | Merged | 2026-08-13 |
| 15 | @ZacharyRW | `feature/15-opencode-usage` | [#20](https://github.com/ZacharyRW/codepulse/pull/20) | Merged | 2026-08-13 |
| 16 | @ZacharyRW | `feature/16-usage-attribution` | [#21](https://github.com/ZacharyRW/codepulse/pull/21) | Merged | 2026-08-13 |
| 17 | @ZacharyRW | `feature/17-usage-insights` | [#22](https://github.com/ZacharyRW/codepulse/pull/22) | Merged | 2026-08-13 |
| 18 | @ZacharyRW | `feature/18-release-hardening` | — | In progress | — |

---

## Feature 00 — Commit the governing roadmap

**Branch:** `feature/00-roadmap`  
**PR title:** `docs: add agent-aware tracking roadmap`  
**Depends on:** none

1. Add this document at `docs/agent-aware-tracking-roadmap.md` in the fork, preserving the final decisions and the explicit out-of-scope boundary.
   - Test: Markdown preview; verify every final decision appears exactly once in the decision table.
   - Commit: `docs: add agent-aware tracking roadmap`
2. Add a compact `docs/adr/0001-agent-aware-tracking-decisions.md` that links to the roadmap and records the non-negotiable architecture/privacy choices.
   - Test: validate relative links and run repository documentation checks.
   - Commit: `docs: record agent-aware tracking decisions`
3. Add a roadmap status table with owner, feature branch, PR URL, and merged date placeholders; do not mark a feature complete before its PR is merged into the fork.
   - Test: Markdown preview and link check.
   - Commit: `docs: add roadmap execution status table`

**Acceptance criteria:** The fork has an approved source-of-truth document, a clear fork-first/upstream-later policy, and no implementation code changes. Open a PR to the fork's `main`, review it, merge it, and update the status table.

## Feature 01 — Safe, versioned persistence migrations

**Branch:** `feature/01-persistence-migrations`  
**PR title:** `feat: add versioned persistence migrations`  
**Depends on:** 00

1. Inventory every persisted CodePulse model, state file, backup file, settings key, and current decode-failure behavior. Document the baseline schema and create anonymized v1 fixtures from real shapes.
   - Test: fixture decode tests reproduce current v1 behavior without accessing user files.
   - Commit: `test: add legacy persistence fixtures`
2. Introduce a top-level schema envelope with explicit version, creation time, migration history, and payload. Preserve atomic write/backup behavior and make unknown future versions fail visibly without replacing in-memory data with an empty state.
   - Test: envelope encode/decode, future-version rejection, atomic-write failure simulation.
   - Commit: `feat: add versioned persistence envelope`
3. Implement ordered, idempotent migration functions from the existing format to the new envelope. Back up before migration and retain the last known-good readable file.
   - Test: migration fixture matrix; repeated migration does not change data; interrupted migration restores from backup.
   - Commit: `feat: migrate legacy persisted state safely`
4. Add a non-destructive recovery UI/log path: explain decode/migration failure, offer backup export, and never silently reset user data.
   - Test: view model tests and manual failure smoke test using a corrupted fixture.
   - Commit: `feat: surface persistence recovery options`

**Acceptance criteria:** Existing users load their state or receive a recoverable, non-destructive error; migrations are deterministic and tested before any activity-model replacement. Open and merge the fork PR.

## Feature 02 — Replace one stopwatch with workspace/activity/run/intervals

**Branch:** `feature/02-activity-domain-model`  
**PR title:** `feat: introduce workspace activity and run model`  
**Depends on:** 01

1. Define the new persisted models and identifiers: `Workspace`, `WorkspaceRoot`, `Activity`, `Run`, `Interval`, `IntervalState`, and `ActivityDomain`. Maintain compatibility adapters for existing projects and `ActiveSession` UI paths.
   - Test: Codable round trips, identity/equality tests, and adapter tests.
   - Commit: `feat: add workspace activity run models`
2. Add store/repository operations for creating, updating, ending, and querying runs/intervals. Enforce interval invariants: no negative duration, one open interval per run, immutable closed intervals, and no implicit cross-workspace attachment.
   - Test: store mutation, invariant, and persistence round-trip tests.
   - Commit: `feat: add activity run interval store`
3. Migrate legacy projects and active/history sessions to one workspace plus a manual activity/run, preserving timestamps, names, and current work type. Do not fabricate agent metadata.
   - Test: v1-to-v2 fixture assertions covering active, stopped, and malformed legacy sessions.
   - Commit: `feat: migrate legacy sessions to activities`
4. Add a read-only debug/diagnostic representation of the new graph so migrations and later integrations can be audited without raw source/prompt data.
   - Test: snapshot/JSON redaction tests.
   - Commit: `feat: add activity model diagnostics`

**Acceptance criteria:** CodePulse can persist multiple activities/runs while preserving all existing manual sessions after migration. The old single-session UI still works through the compatibility adapter. Open and merge the fork PR.

## Feature 03 — Normalize local developer events

**Branch:** `feature/03-developer-event-v2`  
**PR title:** `feat: add normalized developer event pipeline`  
**Depends on:** 02

1. Define a versioned `DeveloperEventV2` envelope with integration, event kind, observed time, external-session key, parent-session key, working directory, model/effort/service mode, and metadata-only payload fields. Explicitly prohibit prompt/transcript/source-content fields.
   - Test: schema encode/decode and forbidden-field/redaction tests.
   - Commit: `feat: define developer event v2 schema`
2. Build a local event receiver/CLI boundary that validates size, schema, timestamp reasonableness, integration allow-list, and idempotency key before handing an event to the app.
   - Test: malformed input, oversized input, duplicate, and clock-skew tests.
   - Commit: `feat: validate developer integration events`
3. Add a durable, bounded diagnostics journal containing event receipt status and redacted rejection reason—not raw hook input. Include parser/integration versions for supportability.
   - Test: retention, redaction, and restart recovery tests.
   - Commit: `feat: add redacted integration diagnostics`
4. Create contract-test fixtures for Codex, Claude Code, and OpenCode canonical events. Keep fixture data synthetic and free of prompt/content text.
   - Test: run all three contract suites through the normalizer.
   - Commit: `test: add developer event contract fixtures`

**Acceptance criteria:** all integrations can feed one safe, versioned event pipeline; duplicate or malformed events cannot corrupt activity state; diagnostics contain no content. Open and merge the fork PR.

## Feature 04 — Agent-aware timing state machine

**Branch:** `feature/04-agent-aware-timing`  
**PR title:** `feat: track agent active waiting and review intervals`  
**Depends on:** 03

1. Implement an explicit run-state reducer (`new`, `active`, `awaitingPermission`, `reviewGrace`, `waiting`, `ended`, `orphaned`) driven only by normalized lifecycle events. Document per-integration event mappings and transition precedence.
   - Test: exhaustive reducer transition table and duplicate/out-of-order event tests.
   - Commit: `feat: add agent run state reducer`
2. Materialize reducer transitions as intervals. Active agent execution counts toward agent runtime; waiting never counts toward active totals; preserve elapsed span separately.
   - Test: interval closure/opening and duration-calculation tests using deterministic clocks.
   - Commit: `feat: persist agent timing intervals`
3. Add the configurable review grace setting, defaulting to exactly three minutes. `Stop`/completed creates review grace; a subsequent prompt/tool action resumes active; explicit permission/wait/end cancels grace; expiration changes to waiting.
   - Test: timer scheduling, cancellation, settings migration, and boundary-at-180-seconds tests.
   - Commit: `feat: add three minute review grace`
4. Add stale-run handling: on relaunch, reconcile open runs using a conservative timeout and mark irreconcilable runs orphaned instead of inventing active time.
   - Test: app-restart fixtures and stale interval reconciliation tests.
   - Commit: `feat: reconcile interrupted agent runs`

**Acceptance criteria:** a four-hour pause after a stop contributes at most the configured three-minute review grace, not four hours; state histories are auditable. Open and merge the fork PR.

## Feature 05 — Codex lifecycle integration

**Branch:** `feature/05-codex-lifecycle`  
**PR title:** `feat: add Codex agent lifecycle tracking`  
**Depends on:** 04

1. Extract integration event ingestion, asynchronous Git/GitHub enrichment, and lifecycle reconciliation from `SessionStore` into focused collaborators. Keep `SessionStore` as the `@MainActor` application-facing facade and preserve the legacy manual-session adapter until the concurrent UI fully supersedes it.
   - Test: existing manual-session, persistence, event-reconciliation, and stale-result tests pass unchanged; add focused coordinator tests with deterministic clocks/services.
   - Commit: `refactor: isolate integration lifecycle coordination`
2. Audit the current Codex integration installer and update CodePulse-managed hook configuration without overwriting user hooks. Install only supported lifecycle hooks and provide an uninstall/repair path.
   - Test: configuration merge fixtures with unrelated user hooks preserved; manual install/uninstall smoke test.
   - Commit: `feat: manage Codex lifecycle hooks safely`
3. Map Codex local lifecycle events such as session start, prompt submit, tool activity, permission request, stop, and session end into `DeveloperEventV2`. Treat unknown events as diagnostics only.
   - Test: Codex contract fixtures and mapper tests.
   - Commit: `feat: map Codex lifecycle events`
4. Correlate Codex events by external session ID and working directory, then create/resume the appropriate agent run through the timing reducer.
   - Test: two simultaneous Codex sessions, one session resuming after stop, and duplicate-event scenarios.
   - Commit: `feat: correlate Codex runs to activities`
5. Add Codex integration settings/status: enable/disable, hook health, timing-only mode, and a clear notice that cloud-only sessions are not tracked in this release.
   - Test: settings persistence and disabled-integration rejection tests.
   - Commit: `feat: add Codex integration settings`

**Acceptance criteria:** a local Codex run controlled remotely from a phone records active/waiting intervals correctly; cloud-only work is clearly excluded; existing user hooks remain unchanged. Open and merge the fork PR.

## Feature 06 — Claude Code lifecycle integration

**Branch:** `feature/06-claude-lifecycle`  
**PR title:** `feat: add Claude Code lifecycle tracking`  
**Depends on:** 04

1. Implement a Claude Code settings/hook installer that merges only CodePulse-owned entries in the supported user-level configuration and supports exact uninstall/repair.
   - Test: settings merge/idempotency fixtures and manual revert test.
   - Commit: `feat: manage Claude Code hooks safely`
2. Map supported Claude Code hook payloads to the normalized event schema, including session, cwd, model, effort, transcript path presence (not content), parent/subagent context, and lifecycle state.
   - Test: mapper fixtures for normal, permission, stop, and subagent cases.
   - Commit: `feat: map Claude Code lifecycle events`
3. Route Claude events through the common run-state reducer and preserve parent/child relationships without treating a subagent as a replacement for its parent.
   - Test: parent plus two child runs, overlapping child activity, and parent-end-before-child scenarios.
   - Commit: `feat: track Claude parent and child runs`
4. Add Claude settings/status and documentation for local Remote Control workflows versus unsupported cloud-only sessions.
   - Test: settings UI tests and a local remote-control smoke checklist.
   - Commit: `docs: describe Claude local tracking limits`

**Acceptance criteria:** Claude Code local runs and subagents appear as separate runs, waiting time is excluded, and no transcript contents are persisted. Open and merge the fork PR.

## Feature 07 — OpenCode lifecycle integration

**Branch:** `feature/07-opencode-lifecycle`  
**PR title:** `feat: add OpenCode lifecycle tracking`  
**Depends on:** 04

1. Research and document the most stable supported OpenCode local event/plugin API. Prefer plugin-provided events; record a read-only local-data fallback only when no stable event surface is available.
   - Test: a reproducible fixture or local integration harness proves the selected surface.
   - Commit: `docs: define OpenCode lifecycle integration contract`
2. Implement the OpenCode adapter with integration-local error isolation and no destructive modification of user configuration.
   - Test: adapter mapping and disabled/missing-OpenCode tests.
   - Commit: `feat: add OpenCode lifecycle adapter`
3. Correlate OpenCode run IDs, cwd, model, and event state with the common run reducer; classify unsupported/ambiguous data as diagnostic rather than guessing.
   - Test: concurrent OpenCode sessions and restart reconciliation tests.
   - Commit: `feat: correlate OpenCode activity runs`
4. Add OpenCode integration settings, health checks, and a user-facing explanation of the selected local data source.
   - Test: settings persistence and health-state snapshots.
   - Commit: `feat: add OpenCode integration settings`

**Acceptance criteria:** OpenCode follows the same active/waiting semantics as Codex and Claude Code, without data writes outside CodePulse-owned configuration. Open and merge the fork PR.

## Feature 08 — Git workspace discovery

**Branch:** `feature/08-git-workspace-discovery`  
**PR title:** `feat: discover Git workspaces from agent activity`  
**Depends on:** 05, 06, 07

1. Build a workspace resolver that receives a cwd and finds a Git top-level root using a bounded, local command/API call. Capture root, current branch, sanitized remote identity, and worktree relation without scanning the entire disk.
   - Test: repository, nested folder, detached HEAD, no remote, and Git-worktree fixtures.
   - Commit: `feat: resolve Git workspace identity`
2. Define workspace identity precedence: normalized remote/repository identity, Git common directory/root, individual worktree root, then canonical local path. Avoid merging unrelated folders that share a name.
   - Test: equivalent clone, two worktrees, renamed-folder, and remote-less repository tests.
   - Commit: `feat: identify Git workspaces consistently`
3. Automatically create or update a discovered workspace on a valid agent event. Mark its source as automatic, retain user names/edits, and never require a preexisting manual project.
   - Test: first-event auto-create, second-event idempotency, and user-renamed workspace tests.
   - Commit: `feat: auto create Git workspaces`
4. Add workspace settings to opt out of automatic discovery globally or per workspace, and show what identity data CodePulse retains.
   - Test: opt-out prevents new creation but does not erase existing history.
   - Commit: `feat: add workspace discovery controls`

**Acceptance criteria:** an agent started anywhere inside an unknown Git repository creates/uses the correct workspace automatically, including separate worktrees. Open and merge the fork PR.

## Feature 09 — Non-Git discovery and manual-agent absorption

**Branch:** `feature/09-local-task-discovery`  
**PR title:** `feat: discover local tasks and match manual activities`  
**Depends on:** 08

1. Add a safe non-Git resolver. Specific working folders become local workspaces; broad roots such as the home directory, filesystem root, or temporary folders create a transient local task rather than registering an overly broad project.
   - Test: path canonicalization, home-directory guard, removable-volume, and temp-directory cases.
   - Commit: `feat: resolve non Git local tasks safely`
2. Add local-file task identity for event contexts that point at a file or document. Store only a display-safe path/name and a canonical local identity; do not index directory contents.
   - Test: file task creation, path redaction, and moved-file behavior tests.
   - Commit: `feat: add local file task workspaces`
3. Implement matching rules by workspace identity plus temporal overlap. When a manual activity matches an agent run, attach the run to the activity without merging its source intervals or totals.
   - Test: matching, no-match, ambiguous-match, and manual activity already-ended cases.
   - Commit: `feat: attach matching agent runs to manual activities`
4. Display separate measures for a combined activity: manual active, agent runtime, agent waiting, elapsed span, and union/combined wall-active time.
   - Test: overlap math for one manual run plus multiple agents.
   - Commit: `feat: preserve manual and agent activity metrics`

**Acceptance criteria:** file organization or non-Git automation can be tracked without falsely treating the entire home folder as a project; matching agent work enriches rather than distorts a manual timer. Open and merge the fork PR.

## Feature 10 — Concurrent sessions and live UI

**Branch:** `feature/10-concurrent-activity-ui`  
**PR title:** `feat: show concurrent agent activities`  
**Depends on:** 02, 04, 08, 09

1. Replace single-active-session assumptions in app state and menu-bar presentation with a query for all current runs, grouped by workspace/activity and ordered by state/recency. Build this as a focused read projection over the activity graph rather than adding more view/query responsibilities to `SessionStore`.
   - Test: view-model tests for zero, one, and many active/waiting runs.
   - Commit: `feat: support multiple current activity runs`
2. Build the **Active Now** UI: workspace, activity label, integration/model, run state, elapsed active time, review-grace countdown, and a clear waiting badge. Provide safe actions to open activity details or stop only CodePulse-owned manual runs.
   - Test: snapshot/accessibility tests and manual menu-bar smoke test.
   - Commit: `feat: add active now concurrent session UI`
3. Implement aggregate metric services: union of eligible intervals for personal/combined wall-active time, summed agent-active time for agent runtime, and separately summed waiting. Never use summed concurrency as personal time.
   - Test: overlap matrices across projects/tools/manual runs.
   - Commit: `feat: calculate concurrent activity metrics`
4. Add history/detail timelines that make concurrent runs and state transitions inspectable, with privacy-safe labels and no raw event bodies.
   - Test: timeline ordering, redaction, and large-history performance tests.
   - Commit: `feat: add concurrent activity timelines`

**Acceptance criteria:** multiple agents/projects can be visible at once, a waiting run contributes zero active time, and the UI never claims two overlapping 30-minute agent runs equal one hour of personal time. Open and merge the fork PR.

## Feature 11 — Automatic work-type and activity-domain classification

**Branch:** `feature/11-activity-classification`  
**PR title:** `feat: classify activity work type and domain`  
**Depends on:** 03, 09

1. Define classification records with dimension, value, source, confidence, timestamp, and an explainable evidence category. Keep work type and activity domain independent.
   - Test: model serialization and validation tests.
   - Commit: `feat: add activity classification records`
2. Implement metadata-only classification rules from lifecycle/tool metadata, workspace signals, closed file-type metadata, closed action categories, and user overrides. Do not derive labels from free-form adapter strings or inspect prompts in this mode.
   - Test: deterministic coding/debugging/planning/review/research and domain fixture matrix.
   - Commit: `feat: classify activity from metadata`
3. Defer enhanced local prompt classification until a separately approved local handoff design exists. The v2 event contract remains prompt-free; no consent control, prompt API, or integration claim ships before the handoff, redaction, and crash-reporting requirements are implementable.
   - Test: schema tests reject prompt-bearing events; future implementation must prove prompt values are absent from persistence, diagnostics, exports, backups, and any crash-reporting surface.
   - Commit: `docs: defer prompt classification pending safe handoff`
4. Add correction controls and learning boundaries: users can override a segment/activity; manual corrections take precedence and do not train/send data anywhere.
   - Test: override precedence, undo, and migration tests.
   - Commit: `feat: add activity classification overrides`

**Acceptance criteria:** metadata-only is the default; current work types remain intact; domains provide the extra context needed for file organization/administration; no prompt text is stored. Open and merge the fork PR.

## Feature 12 — Pricing catalog and cost accounting foundation

**Branch:** `feature/12-pricing-catalog`  
**PR title:** `feat: add versioned pricing catalog and cost provenance`  
**Depends on:** 01, 03

1. Define normalized usage and cost models: input/output/cache/reasoning tokens where available; provider-reported cost; API-equivalent estimate; Codex-credit estimate; currency; service mode; effort; price source; catalog version; effective date; calculation method/confidence.
   - Test: model round trips and label-enforcement tests.
   - Commit: `feat: add usage and cost accounting models`
2. Create a bundled, versioned pricing manifest and schema. Include only provider-published rate data/links, model aliases, applicable units, effective dates, and signature metadata—not guessed effort multipliers.
   - Test: schema validation, signature verification, alias resolution, and expired-catalog behavior.
   - Commit: `feat: add bundled pricing catalog`
3. Implement signed remote-manifest refresh with HTTPS, signature/key verification, monotonic version rules, rollback protection, caching, and the bundled catalog as an offline fallback. A bad remote catalog is ignored and diagnosed.
   - Test: valid refresh, invalid signature, replay, offline, and fallback tests.
   - Commit: `feat: refresh signed pricing manifests safely`
4. Implement a pure cost calculator that stores calculated values with immutable provenance. Effort is an analytical dimension; apply a different rate only when the catalog explicitly defines a provider service-mode price.
   - Test: known-rate calculations, cache-token cases, currency precision, and historical-catalog reproducibility.
   - Commit: `feat: calculate provenance backed usage costs`
5. Add per-integration primary-cost-display preference while retaining all representations. Default to provider-reported cost when available; otherwise show the clearest estimate label.
   - Test: preference persistence and presentation-label tests.
   - Commit: `feat: add cost display preferences`

**Acceptance criteria:** price updates are verifiable and safe offline; historical values do not silently change; the app cannot call an estimate an actual bill. Open and merge the fork PR.

## Feature 13 — Codex token usage and credit estimates

**Branch:** `feature/13-codex-usage`  
**PR title:** `feat: track Codex token usage and credit estimates`  
**Depends on:** 05, 12

1. Add the separate Codex **Track token usage** consent toggle, disclosure, data-location explanation, and immediate-disable behavior. Timing remains available with the toggle off.
   - Test: disabled reader never opens usage sources; toggle migration/persistence tests.
   - Commit: `feat: add Codex token tracking consent`
2. Implement a read-only incremental Codex local usage reader against the documented/current local session metadata format. Read only required counters/model metadata, maintain offsets/checkpoints, and calculate deltas from cumulative counters to avoid double counting repeated updates.
   - Test: cumulative, latest-only, repeated, truncated, rotated, and malformed-record fixtures.
   - Commit: `feat: ingest Codex usage metadata incrementally`
3. Correlate usage samples to Codex runs/workspaces conservatively. Unmatched samples remain in an explicit unassigned bucket rather than being guessed into a project.
   - Test: matching, ambiguous, delayed, and cross-workspace samples.
   - Commit: `feat: attribute Codex usage to runs`
4. Use the official rate-card mapping in the signed catalog to calculate API-equivalent cost and Codex-credit estimates where applicable. Clearly state that credits are estimated usage, not account balance or invoice data.
   - Test: rate-card fixtures, unavailable-rate behavior, and UI copy snapshots.
   - Commit: `feat: estimate Codex credits from rate card`

**Acceptance criteria:** Codex tokens can be tracked only after explicit consent, repeated metadata updates are not double-counted, and credit estimates retain official source/version provenance. Open and merge the fork PR.

## Feature 14 — Claude Code token usage and subagent accounting

**Branch:** `feature/14-claude-usage`  
**PR title:** `feat: track Claude Code usage and subagent rollups`  
**Depends on:** 06, 12

1. Add the separate Claude Code usage-consent toggle and explain transcript-path metadata versus transcript-content access. The implementation must not persist or export transcript text.
   - Test: disabled-reader and privacy disclosure tests.
   - Commit: `feat: add Claude usage tracking consent`
2. Implement a read-only parser for supported Claude Code local usage metadata, extracting only model, effort/service mode, input/output/cache token counters, reported session cost when available, timestamps, and parent/subagent identifiers.
   - Test: parser fixtures for standard, cached, fast-mode, missing-cost, and malformed metadata.
   - Commit: `feat: ingest Claude usage metadata`
3. Correlate samples to parent and subagent runs. Store child usage once and compute a parent roll-up as parent-exclusive usage plus children, preventing duplicate totals when a parent transcript already reports an aggregate.
   - Test: parent-only, children-only, embedded aggregate, and overlapping child cases.
   - Commit: `feat: add deduplicated Claude subagent rollups`
4. Present reported provider cost, subscription/actual-charge-unknown state, and API-equivalent estimate according to availability and the selected Claude display preference.
   - Test: presentation states and calculation provenance tests.
   - Commit: `feat: present Claude cost representations`

**Acceptance criteria:** Claude subagents are inspectable separately and roll up exactly once; no transcript/prompt content is retained; subscription usage is not mislabeled as a bill. Open and merge the fork PR.

## Feature 15 — OpenCode token usage

**Branch:** `feature/15-opencode-usage`  
**PR title:** `feat: track OpenCode token usage`  
**Depends on:** 07, 12

1. Add a separate OpenCode usage-consent toggle and document the preferred event-based source. The managed plugin is the sole source for this release; no local-database fallback is used, so unknown schemas cannot expose stored OpenCode data.
   - Test: consent gating and no-write guarantees.
   - Commit: `feat: add OpenCode token tracking consent`
2. Implement the stable OpenCode usage adapter from the managed plugin's content-safe event. Version-gate that event and expose unsupported/malformed diagnostics; database access remains deliberately out of scope.
   - Test: plugin-event fixtures and missing/unsupported handoff handling.
   - Commit: `feat: ingest OpenCode usage metadata`
3. Normalize OpenCode model/provider/token/stored-cost data and correlate it to runs/workspaces. Preserve supplied provider cost separately from calculated estimates.
   - Test: model alias, provider, project-match, and unassigned-usage tests.
   - Commit: `feat: attribute OpenCode usage safely`
4. Add adapter health reporting so a schema change degrades only usage tracking and does not affect activity timing.
   - Test: incompatible-schema isolation and recovery tests.
   - Commit: `feat: report OpenCode usage adapter health`

**Acceptance criteria:** OpenCode per-project tokens/costs work with explicit consent, content-safe event access, and graceful degradation. Open and merge the fork PR.

## Feature 16 — Usage attribution and cross-tool analytics layer

**Branch:** `feature/16-usage-attribution`  
**PR title:** `feat: attribute usage across projects and categories`  
**Depends on:** 10, 11, 13, 14, 15

1. Implement an attribution service that maps each normalized usage sample to workspace, activity, work-type segment, activity domain, integration, provider, model, effort, and service mode. Preserve an unassigned/unknown bucket instead of inventing certainty.
   - Test: attribution matrix for exact, delayed, ambiguous, and missing classifications.
   - Commit: `feat: attribute usage by workspace and category`
2. Add time-window aggregation for day/week/month/custom range and distinct metric definitions: tokens, reported cost, estimated cost, credit estimates, manual time, agent runtime, combined wall-active time, and waiting.
   - Test: timezone/DST boundaries, concurrent timing, and aggregation reconciliation tests.
   - Commit: `feat: aggregate agent activity and usage metrics`
3. Add reconciliation views/tests that trace aggregate totals to constituent runs/samples while redacting identifiers appropriately.
   - Test: aggregate-to-detail reconciliation and redaction tests.
   - Commit: `feat: add usage attribution reconciliation`
4. Benchmark representative history sizes and add indexed/query-efficient persistence paths without changing metric semantics.
   - Test: performance regression benchmark and result-equivalence tests.
   - Commit: `perf: optimize usage attribution queries`

**Acceptance criteria:** users can answer “which project/domain/work type/tool/model used these tokens and estimates?” with auditable totals; parallel runs do not distort personal time. Open and merge the fork PR.

## Feature 17 — Usage Insights and export

**Branch:** `feature/17-usage-insights`  
**PR title:** `feat: add agent usage insights`  
**Depends on:** 16

1. Design and implement the Insights overview: selected period, total active versus waiting, manual versus agent metrics, project ranking, integration/model breakdown, work type/domain breakdown, and properly labeled cost/credit cards.
   - Test: view-model snapshots for no data, timing-only, partial usage, and fully priced states.
   - Commit: `feat: add usage insights overview`
2. Add drill-downs from charts/cards to privacy-safe activity/run/sample details, including Claude parent/subagent presentation without duplicated totals.
   - Test: navigation, subtotal, and child-roll-up snapshot tests.
   - Commit: `feat: add usage insight drill downs`
3. Add local CSV/JSON export with a schema/version header, selected date range, user-controlled fields, explicit cost labels/provenance, and default exclusion of sensitive paths/identifiers.
   - Test: export schema, redaction, locale/currency, and round-trip tests.
   - Commit: `feat: add privacy safe usage export`
4. Add empty/error/stale-data states that tell users precisely whether timing, a specific usage reader, or pricing refresh is unavailable.
   - Test: UI state matrix and accessibility tests.
   - Commit: `feat: explain usage insight data quality`

**Acceptance criteria:** Usage Insights ships before budgets/alerts; every number has a definition and source state; exports are local and privacy-controlled. Open and merge the fork PR.

## Feature 18 — Hardening, release, and deferred budgets groundwork

**Branch:** `feature/18-release-hardening`  
**PR title:** `feat: harden agent-aware tracking release`  
**Depends on:** 17

1. Conduct a privacy/security review of local readers, installers, file permissions, diagnostics, exports, manifest verification, and deletion flows. Add a user-facing data inventory and “delete integration data” controls.
   - Test: permission-denied, redaction, deletion, and manifest-security test suites.
   - Commit: `feat: add agent tracking privacy controls`
2. Add fault-injection and long-running resilience tests for broken hooks, missing executables, partial writes, parser updates, large histories, sleep/wake, timezone changes, and app restarts.
   - Test: dedicated resilience suite and manual sleep/wake checklist.
   - Commit: `test: harden agent tracking resilience`
3. Do not add external crash reporting by default. If telemetry or crash reporting is later permitted by project policy, require explicit opt-in, a content-free schema, destination/retention/deletion documentation, and redaction tests proving prompts, transcripts, paths, and session identifiers are excluded; otherwise add fully local support-bundle generation with redaction preview. Never send raw activity content automatically.
   - Test: opt-in/opt-out, crash-report or bundle redaction, and inspection tests.
   - Commit: `feat: add redacted agent tracking support bundle`
4. Produce release notes, migration notes, a rollback/backup procedure, integration setup/uninstall guides, and a known-limitations section stating that cloud-only sessions and budgets are deferred.
   - Test: clean-machine/manual release checklist and docs link check.
   - Commit: `docs: prepare agent aware tracking release`
5. Harden CI and release automation. Update validation to the current checkout action, remove the retired feature-branch push trigger, use `contents: read`, cancel superseded validation runs, and set job timeouts. Add a non-publishing release preflight that exercises the production package, Sparkle-signing validation, and artifact verification before a release tag is created; keep the signed tag workflow as the only publisher.
   - Test: validation runs for a pull request and `main`; a preflight validates a synthetic release version/artifacts without creating a GitHub release; release-workflow permissions and tag guards are regression-tested or reviewed with a fixture checklist.
   - Commit: `ci: harden validation and release workflows`
6. Add `.github/dependabot.yml` for weekly `swift` and `github-actions` version updates from the repository root. Limit open version-update PRs to three per ecosystem, keep ecosystems separate, and document that Sparkle and workflow updates require normal review and macOS validation rather than auto-merge.
   - Test: validate the Dependabot configuration against GitHub's supported ecosystem names and confirm it detects `Package.swift` and `.github/workflows` on the default branch.
   - Commit: `ci: enable Dependabot updates`
7. Add only the data-model seams for a later budgets feature—threshold policy models are not enabled, no alerts are shipped, and no enforcement occurs. Link a follow-on roadmap issue after Insights feedback.
   - Test: confirm budget code cannot affect calculations, notifications, or UI in this release.
   - Commit: `chore: reserve usage budget extension points`

**Acceptance criteria:** the release is recoverable, privacy-audited, and robust under failed integrations; all known limits are explicit; budgets remain deferred. Open and merge the fork PR.

---

## Definition of done for the program

The roadmap is complete when all Feature 00–18 PRs have been merged into the contributor's fork `main`, migrations have been exercised on backup copies, local Codex/Claude Code/OpenCode workflows have passed the manual smoke matrix, and the release documentation states the privacy boundary and cloud-only limitation plainly.

### Required end-to-end manual scenarios

1. Start a local Codex run in an unknown Git repository from a phone/remote interface; verify automatic workspace creation, active time, a three-minute review grace after stop, then zero waiting time.
2. Run Codex and Claude Code concurrently in different projects; verify each agent runtime is 30 minutes for a 30-minute overlap while personal/combined wall-active time is 30 minutes, not 60.
3. Start a manual activity, launch a matching agent run, and verify the activity shows distinct manual, agent, waiting, and union metrics.
4. Run a Claude parent with subagents; verify child rows are visible and parent roll-up is de-duplicated.
5. Track a non-Git local-file organization task; verify it is a bounded local task, not an accidental home-directory workspace.
6. Enable and disable each per-tool usage toggle; verify disabling stops reads immediately without stopping timing or deleting prior data unless requested.
7. Work offline with an expired/unavailable remote pricing manifest; verify the signed bundled catalog is used and labeled with its version.
8. Open a historical Insight after prices change; verify its displayed calculation retains its original catalog/provenance.
9. Attempt to export and inspect a support bundle; verify prompts, transcript text, source contents, and raw hook input are absent.

## Explicitly deferred work

- Remote/cloud-only Codex or Claude sessions that have no local hook/process/usage record available to CodePulse.
- Budgets, threshold alerts, notifications, or enforcement. They follow a validated Usage Insights release.
- Remaining credit/balance retrieval from providers, unless a documented stable local/API source becomes available and a separate privacy/security design is approved.
- Any fixed “effort multiplier” that is not explicitly published by a provider in a signed catalog.
- Cross-device cloud synchronization of raw agent records.

## Upstream handoff checklist

When/if the repository owner wants contributions, choose small, coherent features (for example persistence safety, safe hook merging, or the pricing manifest) and:

1. Rebase/cherry-pick onto current `upstream/main` in a clean branch.
2. Remove fork-specific workflow wording from the PR description.
3. Supply migrations, privacy tests, and screenshots/manual instructions appropriate to that feature alone.
4. State integration limitations honestly; do not package an unvalidated full series as one upstream PR.
5. Keep the contributor's fork as the authoritative integrated version until upstream independently accepts each change.
