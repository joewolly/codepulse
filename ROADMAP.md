# Project Roadmap

> Derived from the verified findings in `ANALYSIS.md` at fork revision
> `b2bc01e7f4ced9d4ab8a691ea3832ee1771e4ff3`. This is the current forward
> plan. `docs/agent-aware-tracking-roadmap.md` is a completed historical
> execution record and must not be treated as an open backlog.

## Roadmap Principles

1. **Protect update trust and user execution first.** A green build does not
   outweigh a path to signing-key exposure or repository-configured code
   execution.
2. **Make privacy controls literally true.** UI copy, documentation, persisted
   compatibility fields, deletion, and exports must agree.
3. **Bound every untrusted input end to end.** Per-file limits are insufficient
   when accepted history, traversal, subprocesses, arithmetic, or decoded state
   remain unbounded.
4. **Fix invariants before adding analytics.** Correct workspace binding,
   overflow behavior, and retention precede budget alerts or richer reporting.
5. **Prefer small, reviewable increments.** Each initiative below has a stable
   ID, explicit dependency, and observable success criteria.
6. **Preserve local-first identity.** Prompt content, raw cloud sync, invented
   pricing, and provider-balance scraping remain out of scope without a separate
   approved privacy/security design.
7. **Treat the two repositories as independent peer product lines.**
   `ZacharyRW/codepulse` (`origin`) is authoritative for this roadmap and its
   releases. `joewolly/codepulse` (locally named `upstream`) is the historical
   parent and a friendly peer, not a release authority for the fork. Either
   maintainer may selectively port useful features through focused, reviewed
   changes; do not blanket-merge histories or assume version equivalence.
8. **Do not delete branches in this roadmap execution.** The user explicitly
   prohibited branch deletion. Cleanup candidates are inventory only until a
   later, separately authorized action.

Prioritization considers user impact, security severity, data/privacy risk,
reproducibility, dependency order, effort, maintainability, and fit with the
local macOS product.

## Phase 0: Immediate Safety and Repository Hygiene

No new release or production-key preflight should occur until this phase is
complete.

Decisions recorded for this phase on 2026-08-13:

- Recovery backups remain complete, full-fidelity local recovery artifacts.
  They may contain sensitive CodePulse state, including paths, user-entered
  text, and legacy external developer-tool identifiers, and must say so before
  export.
- A separately versioned, redacted/share-safe export is committed follow-on
  work under `FEAT-002`; it must not weaken or silently replace recovery
  fidelity.
- The fork and its historical parent are independent, friendly projects.
  `origin/main` and fork releases are authoritative here; future feature sharing
  is selective and does not imply shared tags, histories, or release channels.
- GitHub rulesets, protected production signing, and their verification evidence
  are Phase 0 deliverables, not an out-of-band suggestion. As a solo
  maintainer, the production environment uses a 30-minute wait timer in place
  of an independent reviewer until that maintenance model changes.

### SEC-001 — Make release-preflight inputs data, never shell source

- Move every `workflow_dispatch` value into step environment variables.
- Validate quoted runtime variables before any repository command.
- Remove `${{ inputs.* }}` interpolation from all `run` blocks, including
  artifact paths and names.
- Resolve Sparkle tooling from a deterministic SwiftPM artifact path.
- Add a workflow static test/fixture covering quotes, newlines, substitutions,
  glob/option-like strings, and malformed version/build values.
- **Success:** hostile input is rejected before checkout/build mutation and no
  shell grammar can be injected.

### SEC-002 — Separate preflight from production update signing

- Replace the production Sparkle key in preflight with a disposable test key.
- Create a protected GitHub production-signing environment with an independent
  approval or a solo-maintainer wait timer, and restrict it to reviewed
  `main`/release refs.
- Require the release workflow to identify an approved immutable commit.
- Rotate the production Sparkle key if there is evidence the current preflight
  was ever exposed; current GitHub history shows zero preflight runs, so rotation
  is not automatically required by this audit.
- **Success:** arbitrary branches and ordinary collaborators cannot access or
  exercise the production signing key.

### SEC-003 — Make Git metadata capture non-executing

- Centralize all Git invocations behind a reviewed safe configuration profile.
- Disable `core.fsmonitor`, external diff, textconv, pagers, and execution-bearing
  environment variables; use `--no-ext-diff`/`--no-textconv` where supported.
- Preserve the fixed executable and structured argument array.
- Add sentinel tests that configure each helper and prove none executes during
  start/finish capture.
- **Success:** a selected repository can influence returned metadata but cannot
  start a repository-configured program.

### BUG-001 — Enforce the receipt ledger's actual quota

- Split untruncated capacity enumeration from the 256-item consumer batch.
- Add count and aggregate-byte limits and deterministic oldest-first pruning.
- Consider concurrency between simultaneous helper processes.
- Test accepted, duplicate, malformed, and sustained rejected traffic above the
  quota.
- **Success:** receipt count/bytes never exceed the documented bound and scan
  cost remains bounded.

### BUG-002 — Bound usage numbers and make arithmetic overflow-safe

- Define realistic maximums for token fields, provider cost, timestamps, and
  relevant labels at every local usage boundary.
- Use overflow-reporting arithmetic in Claude parsing, roll-ups, analytics, and
  export; reject/quarantine invalid records rather than crash or silently wrap.
- Add `Int.max` and cumulative-overflow tests for all three integrations.
- **Success:** no accepted record or persisted state value can trap usage
  processing, Insights, or export.

### PRIV-001 — Correct the full-backup privacy contract

- Keep the current versioned recovery backup complete and unredacted; do not
  change its schema version merely to correct disclosure copy.
- At the export decision point, explicitly warn that the file can contain paths,
  user-entered text, Git/GitHub metadata, legacy external developer-tool session
  identifiers, and other locally stored state. State that it excludes
  credentials and source transcript/file contents only where the implementation
  enforces those exclusions.
- Update Settings copy, accessibility hints, `PRIVACY.md`, `SECURITY.md`, and
  contract tests to the exact full-fidelity behavior.
- Deliver `FEAT-002` later as a separate versioned, redacted/share-safe format;
  it must have a category preview and a distinct name and must never be described
  as a recovery backup.
- **Success:** a user can tell, at export time, exactly which sensitive categories
  are included; round-trip and disclosure tests enforce the same contract, and
  `FEAT-002` remains explicitly tracked.

### PRIV-002 — Complete per-integration deletion

- Filter matching legacy `developerToolContexts` from active and completed
  sessions in addition to modern graph/usage/diagnostic/checkpoint data.
- Audit any remaining legacy ledger fields for attributable integration data.
- Reload state and export a backup after deletion in regression tests.
- **Success:** the selected integration's CodePulse-held lifecycle/usage data is
  absent from memory, persisted state, and later backup output, while other
  integrations and manual session data remain intact.

### GH-002 — Protect the default and release boundaries

- Add a ruleset for `main`: pull request required, macOS validation required,
  force pushes and deletion blocked, bypass list minimal and explicit.
- Protect release tags or their creation path.
- Keep release publication and repository settings as separate approvals.
- **Success:** unreviewed commits cannot become the release/signing source and
  history cannot be rewritten through ordinary pushes.

### GH-005 — Record the independent-fork version strategy

- Do not overwrite either `v0.8.0` tag.
- Declare `ZacharyRW/codepulse` and its `origin/main` as authoritative for this
  product line while documenting `joewolly/codepulse` as a friendly peer and
  possible source/destination for selectively ported features.
- Document a remote-specific tag inspection/fetch procedure that does not ask
  Git to clobber a tag.
- Reserve `0.9.0` as the next fork release line; update `Info.plist` only when a
  release candidate is selected.
- **Success:** fresh-clone and update instructions do not fail on the tag
  collision, users can distinguish the independent release lines, and a future
  feature port is reviewed as a normal change rather than a history merge.

### Phase 0 verification gate

- Normal tests and Thread Sanitizer pass.
- New hostile-input/security regression tests pass.
- A safe, disposable-key preflight succeeds from an approved ref.
- Production signing environment is protected and has not been used from an
  arbitrary branch.
- `main` and release-tag rulesets are enabled and verified against the exact
  required validation check.
- Backup disclosure and per-integration deletion pass encode, reload, and
  re-export contract tests.
- Fork/repository role, `0.9.0` reservation, and collision-safe tag commands are
  documented without changing either existing `v0.8.0` tag.
- No branches are deleted.

### Phase 0 implementation plan

Keep the release freeze in effect throughout this sequence. Start every code
branch from a freshly fetched `origin/main`; do not merge `upstream/main` or any
existing feature branch. Each pull request must include the regression test and
documentation required for its own claim rather than deferring all evidence to
the final gate.

| Order | Reviewable delivery | IDs | Primary scope | Merge/evidence gate |
| --- | --- | --- | --- | --- |
| 1 | Secret-free, injection-safe preflight | SEC-001, part of SEC-002 | Refactor `.github/workflows/release-preflight.yml`; pass dispatch values through step environment variables; validate quoted runtime values before repository commands; remove direct input interpolation from every `run` block; resolve Sparkle tools from a deterministic SwiftPM artifact path; generate a disposable key per preflight run. Add a narrow static workflow check and hostile-value fixture/matrix, and run that check in normal validation. | Static scan finds no dispatch-expression interpolation in shell; quote/newline/substitution/glob/option-like inputs fail before packaging; valid synthetic values package and sign/verify with no production secret. |
| 2 | Protected production-signing workflow | SEC-002, DOC-002 | Refactor `.github/workflows/release.yml` so an unprivileged job validates and packages an immutable tag commit already contained in `origin/main`, while the signing step/job uses the `production-signing` environment. Update `docs/releasing.md` with the trust boundary, approval, immutable-SHA evidence, and rotation contingency. | Workflow review proves the production secret is referenced only through the protected environment; the approved tag SHA and `main` containment are recorded; no release is published during implementation. |
| 3 | Non-executing Git command profile | SEC-003 | Centralize the sanitized environment/configuration in `ProcessGitCommandRunner` in `Sources/CodePulse/Services/GitService.swift`; disable repository/global/system fsmonitor, pager, external-diff, and textconv execution paths while keeping `/usr/bin/git` and structured arguments. Add sentinel repositories to `GitServiceTests`/journal capture tests for every prohibited helper. | Sentinels never execute during start/finish capture; normal branch, commit, status, and diff-stat behavior remains unchanged. This must merge before Phase 1 workspace-binding work. |
| 4 | Bounded receipt ledger | BUG-001 | In `DeveloperToolInbox.swift`, separate complete quota enumeration from the 256-item consumer batch, enforce both the documented 2,048-file ceiling and an explicitly documented aggregate-byte ceiling, prune deterministically oldest-first, and serialize the prune/write critical section across helper processes. | Tests cover accepted, duplicate, malformed, sustained rejected, oversized aggregate, and concurrent traffic; count and bytes remain within bounds and consumer scans remain capped. |
| 5 | Shared usage numeric policy and checked aggregation | BUG-002 | Add one documented usage resource policy for token/cost/timestamp/label bounds; apply it at Codex, Claude, and OpenCode intake boundaries; replace trapping additions in Claude roll-ups, attribution, Insights, and export with overflow-reporting operations and a recoverable invalid/partial-data result. Validate already-persisted hostile values at consumption so old state cannot repeatedly crash a view or export. | Per-integration `Int.max`, negative, over-limit, invalid timestamp/cost, and cumulative-overflow fixtures are rejected or quarantined without wrap/trap; ordinary totals and pricing provenance are unchanged. |
| 6 | Truthful full-fidelity recovery backup | PRIV-001, DOC-001 | Preserve `CodePulseBackup` round-trip fidelity in `CodePulseBackup.swift`; replace the false Settings claim and accessibility hint; reconcile `PRIVACY.md`, `SECURITY.md`, README/integration summaries, and tests with the sensitive categories actually encoded. Explicitly distinguish recovery backup, Usage Insights export, redacted support bundle, and future `FEAT-002`. | A representative backup proves legacy IDs/paths and other selected sensitive fields round-trip; disclosure tests prove the UI/docs name them and do not promise redaction. No backup schema bump is made solely for copy. |
| 7 | Complete per-integration deletion | PRIV-002 | Extend `SessionStore.deleteIntegrationData` to remove matching legacy `developerToolContexts` from active and completed sessions, then audit the remaining legacy ledger fields for tool attribution. Preserve other tools, manual sessions, projects, and user-owned source/configuration. | For each integration, a mixed-state fixture is deleted, persisted, reloaded, and backed up; the selected tool's modern and legacy data is absent everywhere while unrelated/manual data remains byte-for-byte equivalent where practical. |
| 8 | Independent-release-line documentation | GH-005, DOC-002 | Update release and contributor-facing documentation to name the fork as its own product/release line, reserve `0.9.0`, and document `git fetch origin main --no-tags`, `git ls-remote --tags <remote>`, and an explicitly namespaced tag-fetch procedure for peer inspection. Describe future cross-repository feature work as selective port/reimplementation with migration and security review. | Commands are exercised in a disposable clone/namespace without changing either `v0.8.0`; `Info.plist` remains unchanged until an approved release candidate. |
| 9 | Repository and signing controls | GH-002, admin half of SEC-002 | Configure the protected `production-signing` environment, move its secret, protect `main`, and protect the `v*` release-tag path after the corresponding workflow/check names are stable. | Settings evidence shows independent approval, minimal bypass, required macOS validation, protected tag creation, blocked force-push/deletion, and no production secret available to preflight or arbitrary refs. |

After deliveries 1 and 2 merge, perform the first GitHub-admin checkpoint on
the fork:

1. Create the `production-signing` environment, require an independent reviewer
   and prevent self-review where available, allow only protected release tags,
   move `SPARKLE_PRIVATE_KEY_BASE64` to the environment, and remove the
   repository-level copy after the workflow is confirmed to reference the
   environment secret.
2. Recheck Actions history and available audit evidence before deciding whether
   to rotate the production Sparkle key. With no evidence of prior preflight
   exposure, retain it; if evidence appears, rotate the private key and embedded
   public key as a separate reviewed security change before any release.
3. Run the non-publishing preflight from an approved ref with the disposable key
   and record the workflow URL, commit SHA, inputs, artifact checksum, and result
   in the Phase 0 completion record.

After the validation workflow names are stable, perform the second GitHub-admin
checkpoint:

1. Add a `main` ruleset requiring pull requests, one independent approval, and
   the exact macOS validation check; dismiss stale approvals, block force pushes
   and deletion, and keep bypass authority minimal and explicit.
2. Add a release-tag ruleset for `v*` that restricts creation, update, and
   deletion to the release authority. Do not recreate, move, or delete either
   existing `v0.8.0` tag.
3. Exercise the rules with non-destructive test branches/PRs and a disposable
   non-release tag pattern where needed; record settings screenshots or API
   output and the successful required-check run. Repository settings and release
   publication remain separately approved actions.

Close Phase 0 only from a final integration branch or PR based on current
`origin/main`. Run `swift build`, `swift test`, `swift test --sanitize=thread`,
the workflow hostile-input/static checks, receipt stress/concurrency tests, the
usage overflow matrix, backup/deletion round trips, and documentation/link
checks. Re-run the protected disposable-key preflight after the final workflow
commit. Record exact commit SHAs, GitHub settings evidence, test commands/results,
and any environment-only limitations; do not tag or publish as part of the gate.

## Phase 1: Stabilization

### BUG-003 — Bind lifecycle events to canonical workspace identity

Persist or deterministically derive the run's workspace identity and require
every later event to match it. Legitimate worktree changes need an explicit,
validated rebinding transition. Cover reused session identifiers, nested roots,
and concurrent runs.

### BUG-004 — Bind OpenCode usage attribution to workspace identity

Use the validated working directory plus the candidate run/workspace roots or
Git/local identity. A mismatch must remain unassigned and create only a bounded,
content-free health diagnostic.

### SEC-004 — Neutralize spreadsheet formulas in CSV

Apply a documented inert transformation to every string cell before CSV quoting,
including leading whitespace, tabs, carriage returns, `=`, `+`, `-`, and `@`.
Keep JSON export unchanged. Test every column, including optional workspace and
activity labels.

### SEC-005 — Decode OpenCode consent at the authoritative path

Replace recursive same-name discovery with a minimal version-aware read of
`payload.settings.openCodeUsageTrackingEnabled`. Add an explicit bounded legacy
fallback if still needed; reject ambiguity.

### SEC-006 — Check Git discovery consent before unknown-path access

When an event does not match an already selected/retained workspace, consult the
global discovery toggle before invoking the Git resolver. Test that the resolver
receives zero calls while disabled.

### PERF-002 — Bound complete Git snapshot work

Stream and cap stdout/stderr, retained path bytes/count, subprocess count, and
whole-capture duration. Replace one-diff-per-untracked-file with bounded batch or
parser logic. Treat a limit as an explicit partial/unavailable snapshot, never a
session-save failure.

### PERF-003 — Bound state/recovery decoding

Check file metadata before read, limit decoded collection/string/graph sizes,
and report a recoverable error while preserving original bytes. Test primary and
backup inputs at and beyond limits, including deep nesting.

### PERF-004 — Bound and fairly resume usage-source enumeration

Move limits inside Codex/Claude source enumeration, impose time/candidate budgets,
and use a cursor or bounded priority structure so early lexicographic files cannot
starve newer valid records.

### UX-001 — Protect finished-session discard

Add a confirmation or short undo/recovery path for the destructive review-stage
action. Keep the keyboard and VoiceOver path clear; add a view/state regression
test.

### DEP-001 — Review and update Sparkle

Review changes from 2.9.2 through current 2.9.x, update in a dedicated change,
commit the chosen resolution policy, run unit/TSan/package tests, and validate
appcast signing with the safe preflight. Do not auto-merge the dependency PR.

### DEP-002 — Retire the deprecated Node.js 20 runtime

Inventory repository workflows, release tooling, local development scripts, and
any external automation configuration for Node.js 20 usage. Prioritize the
GitHub Action(s) called out by GitHub's Node 20 deprecation annotation: identify
the annotated pinned action SHA, upgrade it to a SHA-pinned compatible release
that uses the supported runtime, or replace it if no supported release exists.
Record the chosen action/runtime version and compatibility rationale, refresh
lockfiles only where they are authoritative, and run the affected workflow or
its closest non-publishing equivalent. This repository currently has no
checked-in Node runtime or package-manager configuration, so the first
deliverable is an evidence-backed automation inventory rather than an assumed
application source edit.

- **Success:** no owned workflow, tool, or documented setup path runs Node.js
  20; the selected supported LTS and validation evidence are recorded; external
  automation outside this repository is explicitly listed if it still needs an
  owner change.

### TEST-001 — Add a safety regression suite

Create a named test group covering all Phase 0/1 defects. Preserve source-level
tests for workflows where executing production capabilities would be unsafe.
Track production-source coverage from the measured 62.8% baseline, but prioritize
trust boundaries and zero-coverage app/support files over an arbitrary global
percentage.

## Phase 2: Maintainability and Developer Experience

### PERF-001 — Define durable retention and compaction

- Set transparent age, count, serialized-byte, and per-source rate budgets for
  usage samples, agent runs, automatically discovered workspaces, and activities.
- Allow export before deletion and expose partial/aggregated data status.
- Compact older data into daily/project summaries only after proving report
  invariants.
- Measure cold launch, save, backup, memory, and Insights time across growing
  fixture sizes.

### ARCH-001 — Decompose `SessionStore` without changing its public UI contract

Extract session lifecycle, integration ingestion, Git/GitHub capture,
persistence scheduling, and privacy/deletion policy into injected collaborators.
Keep one observable façade initially. Move behavior with characterization tests,
not a wholesale rewrite.

### ARCH-002 — Prepare storage for long-lived history

After retention is defined, evaluate segmented JSON, an append journal plus
compaction, or SQLite. Select based on measured data volume, atomicity, migration,
backup, and privacy requirements. Do not migrate storage merely to reduce file
size in the abstract.

### DX-001 — Make dependency resolution policy explicit

For this executable app, prefer committing `Package.resolved` so local and CI
transitive resolution agree. If maintainers choose not to, add it to `.gitignore`
and document why. A normal build must leave a clean tree.

### DX-002 — Establish incremental formatting and linting

Add a repository `.swift-format` that matches intentional conventions; format a
small mechanical-only change or enforce only changed files initially. Add shell,
workflow, plist, Markdown-link, and `git diff --check` validation using pinned or
documented tools. Do not mix a whole-repository reformat with behavioral changes.

### CI-001 — Expand deterministic validation

- Keep clean build/tests on PR and `main`.
- Add package resolution, plist, shell syntax, workflow static analysis,
  Markdown links, and changed-file formatting.
- Publish coverage as an informational artifact before adopting a threshold.
- Run TSan on a scheduled/manual cadence if per-PR cost is too high.
- Keep release preflight non-publishing and production-secret-free.

### DOC-003 — Consolidate current project documentation

Create `docs/architecture.md` and `CONTRIBUTING.md` (or one development guide),
mark the old feature roadmap historical, and make this root roadmap the only
current plan. Preserve specialist lifecycle/usage/release documents.

## Phase 3: Product Improvements

### FEAT-001 — Integration and storage health dashboard

Show per-tool enabled state, last successful read, bounded error category,
retained sample/run counts, state size, and retention status without paths,
session IDs, or content. Link directly to documented remediation and deletion.

### FEAT-002 — Share-safe portable export

Add an explicitly redacted export separate from the complete recovery backup.
Preview included categories, use versioned schema, exclude raw identifiers/paths
by default, and retain the existing aggregate-only support bundle for diagnostics.

`PORT-003` delivers the shared export infrastructure and the history and Insights
exporters ahead of this; the redaction and category-preview requirements remain
this item's own.

### FEAT-003 — Safe backup import and recovery preview

Only after `PRIV-001` and `PERF-003`: validate format/version/size, show a summary,
offer non-destructive merge or replace semantics, write a rollback copy, and
never silently replace newer state.

`PORT-002` is the executable plan for this item, adopting the peer's restore
workflow and transactional replacement. Non-destructive merge semantics remain
open; the peer offers replacement only.

### FEAT-004 — Retention controls

Expose understandable defaults and optional per-category periods. Explain raw
versus aggregated history and show projected/actual storage impact. Deletion must
honor the same privacy contract as integration deletion.

### FEAT-005 — Release readiness report

Provide a local or CI-generated, non-secret report for version/tag alignment,
tests, package contents, signature verification, manual checklist, and known
limitations. It should not become an alternate publishing mechanism.

## Phase 3b: Interface Architecture

CodePulse records two overlapping streams of work — the person, and the agents
they set running — as `Run`s and `Interval`s in the activity graph. The interface
does not show it. The popover renders four modes into one resizing column, three
of the four interval states are visually indistinguishable, and navigation is four
link buttons opening separate windows, one of which is not a scene at all.

This program replaces that with one sidebar window whose **Now** section is a
swimlane timeline drawn from interval data, and a menu-bar item carrying a live
day ribbon so the app stays useful without opening anything. `UI-001` comes first
because the timeline and the ribbon both need interval math, and it retires an
existing duplication before a third copy appears.

Recorded decisions: the app switches to `.regular` activation only while the main
window is open; Insights migrates its timing measures onto the activity graph
while session facts remain joined from `completedSessions` behind one seam;
`⌥⌘T` opens the window at the last used section; and the ribbon reports all-work
wall-active time. Keep the menu bar independently sufficient throughout — starting,
finishing, and capturing an outcome must never require the window.

### UI-001 — Establish interval arithmetic and one state palette

Extract the interval-union algorithm duplicated in `ActivityTimingMetricsCalculator`
and `ConcurrentActivityMetricsCalculator` into a single `IntervalArithmetic`, preserving
current behavior exactly — including its dropped zero-length spans, merged touching
spans, and its unclamped end dates, which disagree with `Interval.duration(at:)`.
Record that divergence separately rather than fixing it inline. Add graph-wide lane
and hourly-bucket projections, and one palette mapping each `(RunKind, IntervalState)`
pair to a color, a symbol, and a fill style, so no state is distinguished by color
alone. Hourly bucketing must merge before bucketing so concurrent agents cannot
double-count. Preserve the unused `.ended` interval case; it is persisted and
removing it breaks decode.

Precondition: publish a monotonic graph-revision signal from the store so interface
work can invalidate on data change rather than on the one-second clock.

### UI-002 — Consolidate windows into one navigation shell

Replace the popover-plus-three-windows model with a single sidebar window covering
Now, Journal, Insights, Usage, and Integrations. Own the window from the existing
coordinator rather than a SwiftUI scene: both real entry points are a Carbon hotkey
callback and an AppKit popover button, neither of which has a SwiftUI environment,
and coordinator ownership is single-instance by construction. This retires the
title-matching reconciliation that can currently produce duplicate Insights windows.

Remove the competing minimum-size and navigation-title modifiers from the re-hosted
views; the window owns sizing and titling. Contribute an app menu so section
shortcuts are reachable, and centralize the scattered activation calls into one
ordered open path — from an accessory app, ordering a window front before activating
leaves it behind other applications. Retitle the shortcut preference to match its
new meaning.

### UI-003 — Draw the activity timeline as the Now section

One lane per workspace, with concurrent runs expanding into sub-tracks rather than
compositing into one bar. Compositing would hide exactly what the activity graph
exists to record. Offer fixed window presets rather than free zoom, auto-fit within
the day, and degrade to a real empty state on sparse days rather than an empty grid.

Recompute structure on graph revision and window change only, never on the clock;
scope the one-second tick to open segments and the playhead. Prefer Swift Charts in
the window for its accessibility descriptor, with a canvas fallback if mark diffing
proves slow. Never derive a displayed number from pixel geometry — narrow segments
are width-clamped and non-additive, so all figures come from `UI-001`.

Ship a list presentation of the same model alongside the graphic. It is both the
accessible equivalent and the fallback for pathological data.

### UI-004 — Render the menu-bar ribbon and compact popover

Draw the hourly day ribbon as a template status-item image. A template image is a
mask, so magnitude must be encoded as bar height and alpha, never hue — and the
numeric total must remain in the button title so the ribbon is never the only way
to read it. Add a new menu-bar display case rather than repurposing an existing one;
the setting is persisted and redefining a case silently rewrites user preferences.

Gate redraws behind an explicit refresh policy keyed on hour rollover, graph
revision, and a minimum interval. The current status item recomputes from whole
application state at one hertz; left unchanged, a ribbon would regenerate tens of
thousands of images per day.

The popover keeps the live run list beneath the new strip — the strip summarizes,
the list carries the affordances.

### UI-005 — Move Insights timing onto the activity graph

Rebuild the seven timing measures of the Insights summary on the activity graph so
the window's sections stop disagreeing about time; agent work exists only in the
graph, so today's legacy-backed figures omit it.

The three session-fact sections cannot follow: Git and GitHub context exist only on
completed sessions, with no counterpart on activities, runs, or workspaces. Keep them
reading completed sessions through the existing legacy-session join, but place that
join behind one lookup seam so `UI-007` becomes a backfill plus a deleted fallback
rather than a scattered edit. State the source of each figure in the interface.

### UI-006 — Correlate agent runs with their pull request

A standalone agent run currently has no GitHub context. Lifecycle events adopt an
existing activity only when exactly one manual activity is open in the workspace;
otherwise a fresh activity is minted with no session behind it and nothing to join to.
The timeline makes that gap conspicuous, because an unattributed agent lane is
something the user looks at all day.

The inputs already exist graph-side — discovered workspace roots carry a normalized
repository and branch identity, which is what the existing GitHub context service
takes. Add an optional GitHub context field to activities and capture it on agent-run
creation through the existing service and its existing debounce. The field is additive
and forward-only; historical files decode as absent and require no backfill. Honor the
established privacy posture: normalized public repository names only, no credentials,
no unrecognized remotes.

### UI-007 — Extend the graph to own session context

Follow-on to `UI-005` and `UI-006`. Move Git, GitHub, and developer-tool context onto
the activity graph under a new schema version, backfilling historical activities from
their completed sessions, then delete the legacy lookup fallback. Sequence this after
the interface has settled, and treat the backfill as the risk: it must be correct
against every existing state file, and the whole file is rewritten on every commit.

### UI-008 — Relocate management surfaces out of preferences

Integration configuration, integration data deletion, and workspace discovery are
management surfaces that need width and grow over time; move them into the window.
Activity measures are read-only metrics and belong with Insights, not preferences.
Genuine preferences — launch at login, updates, menu bar, default project, the global
shortcut, and data recovery — stay in the settings scene. Project management is the
borderline case; it fights the fixed preferences width but the sidebar is fixed at
five sections, so record a sixth section as a follow-on rather than forcing it now.

### UI-009 — Extract shared interface primitives

Lift the Insights section, metric, and distribution primitives out of file-private
scope so other sections can use them, and relocate the shared GitHub context view out
of the history folder. Separating the usage attribution section is not a mechanical
move: it owns export state and depends on filter state currently held by its parent,
so it needs its own. Retire the window-coordinator compatibility shims and regenerate
the documentation screenshots, whose fixture must first populate the activity graph —
it currently does not, so today's menu-bar screenshot renders the idle state.

Explicitly deferred: unifying the history and insights project-filter enumerations.
They appear identical but their option builders differ, so unification carries real
behavioral risk and no user-visible benefit.

### Phase 3b verification gate

- Interval union, hourly bucketing, lane projection, refresh policy, and palette
  mapping are unit tested against fixed clocks, including daylight-saving days of
  twenty-three and twenty-five hours.
- The union extraction is proven behavior-preserving by porting existing timing
  expectations before refactoring, not by assertion.
- Hourly buckets sum exactly to the reported day total under concurrent agent runs.
- Every run-activity state has a distinct fill style and symbol, enforced by test.
- A hand-built `.ended` interval produces no drawn segment.
- Graph-backed Insights timing matches the timeline for a fixture containing both
  manual and agent runs; existing session-fact expectations still pass.
- A state file written before `UI-006` decodes with absent activity GitHub context.
- The main window is constructible from environment objects alone, so screenshots
  and tests never require a real window.
- Manual matrix: the global shortcut from another application; repeated presses
  producing no duplicate window; close and reopen preserving frame; dock icon
  appearing and disappearing with the window; the ribbon in light, dark, and
  highlighted states across Retina and non-Retina displays; VoiceOver over the
  timeline and the status item; increased contrast and differentiate-without-color;
  and days with zero, one minute, and many concurrent workspaces.

### Phase 3b risks

- Persistence, not rendering, is the latency hazard. Committing state performs a
  synchronous whole-file encode on the main thread from a one-second tick. The
  timeline does not cause this but will make it visible. Measure it under signposts;
  repairing it belongs to `PERF-001` and `ARCH-002`, not here.
- Retained history is unbounded and the timeline makes that legible to users. Do not
  bundle a destructive retention change into interface work; it is `PERF-001`.
- Canvas drawing is invisible to assistive technology. The list presentation and
  per-lane accessibility summaries are requirements, not enhancements.
- Activation-policy switching is user-visible: a dock icon and application-switcher
  entry appear while the window is open.
- Separating usage attribution changes the published Insights screenshot; plan the
  replacement images in the same change.

## Phase 3c: Upstream Feature Ports

The peer repository has diverged: this fork is 129 commits ahead and 54 behind.
Upstream spent those 54 commits on session automation and data portability while
this line spent its 129 on agent-aware activity tracking and the Phase 0 security
program. Several upstream results answer work already planned here, so this
program adopts them deliberately rather than rebuilding them.

**Rebasing or merging upstream history is rejected, not merely deferred.** It
would rewrite the history `v0.9.0` and `v0.9.1` were released from and invalidate
Sparkle update provenance for shipped builds; `docs/fork-release-line.md` already
records that upstream is not a release authority; both remotes carry `v0.8.0` and
`v0.9.0` tags resolving to different objects, so a rebase leaves tag ancestry
incoherent; and the two persistence designs are structurally different — this line
carries a versioned envelope with a migration chain, while upstream's equivalent
file has no schema versioning at all and instead offers transactional replacement.
Conflicts there are design decisions, not text merges. Each port is therefore an
independent, reviewable, revertible branch, using the no-tags fetch discipline
already documented.

Analysis found less duplication than expected. Upstream has no activity graph, so
nothing there competes with this line's agent tracking. The export work is
complementary rather than competing: this line exports usage, token, and cost
analytics, while upstream exports session history and Insights reports. The backup
format is shared ancestry that upstream extended and this line did not, making it a
genuine three-way merge. Only the file-writing infrastructure is true duplication.

Relationship to existing items: `PORT-002` and `PORT-003` substantially deliver
`FEAT-003` and part of `FEAT-002`; `PORT-004` and `PORT-005` deliver the peer
capabilities named in `FEAT-006`. Those entries remain the statements of intent;
these are the executable plans.

### PORT-001 — Project archive state

Pilot the port procedure on the smallest, fully additive change. Archiving stamps
an optional date on a project and clears it on restore; archived projects leave
active pickers and default selection while retaining all history. Because the field
is optional, existing projects decode as active and no migration is required. Adopt
the peer's tests, which already assert identity preservation across a round trip and
correct decoding of records written before the field existed.

### PORT-002 — Backup restore and transactional state replacement

Answers `FEAT-003`. This line can already write backups but cannot read them back.
Adopt the peer's restore workflow, managed storage path, transactional replacement,
and its more precise error messages, which distinguish a backup written by a newer
application version from a generally unsupported one.

**The migration chain is a correctness requirement, not a refinement.** The peer's
restore assumes an unversioned state file. Here, a backup may hold any earlier
schema version, so restore must decode, run the existing migration chain on the
restored state, and only then replace transactionally. Adopting transactional
replacement as written would bypass migration and produce a state file the
application cannot read.

Backups embed whole application state, so the activity graph round-trips without
special handling — but nothing upstream exercises that, so prove it with an explicit
test. Adopt the peer's pre-restore input-replay rejection and recovery-backup
retention hardening alongside the feature.

### PORT-003 — Exports module

Answers part of `FEAT-002`. Adopt the peer's export infrastructure first — save
panel handling, deterministic filenames, and file writing — because this line
currently performs that work inline inside an Insights view. Then move the existing
usage export onto the shared infrastructure rather than maintaining two paths.

Adopt the peer's history and Insights exporters, but wire them to this line's richer
history filtering so exports honor the active filter set, and extend them to carry
developer-tool context, which peer sessions do not have. Preserve this line's export
privacy posture, where context labels stay behind an opt-in. Verify the peer's field
escaping neutralizes leading spreadsheet formula characters before adopting it;
`SEC-004` governs that behavior here and the peer's escaping may only quote fields.

### PORT-004 — Session presets and application automation

Answers the presets and application-automation half of `FEAT-006`. Adopt the whole
cluster, off by default and explicitly opt-in.

What persists is a user-configured list of application identities. The automation
model holds no history, log, or recently-used store, and the frontmost-application
monitor subscribes to a workspace notification, matches against the configured list,
and retains nothing. It observes transiently to react; it records nothing about what
was used.

That distinction must reach the documentation. Run a `PRIV-001`-style truthfulness
pass over the README, privacy, and security documents: the current claim of no
activity monitoring needs scoping language separating observing-to-react from
recording, and must state that the subscription exists only while automation is
enabled. Adopt the peer's five follow-up fixes — malformed state recovery, status
label preservation, rule validation accessibility, atomic event acknowledgement, and
rejection of unusable preset targets — rather than rediscovering them.

Sequencing: this cluster touches the session store and settings hardest, and
`UI-002`/`UI-008` relocate settings sections into the new window. Landing it first
means integrating its settings twice. The port is unaffected either way; only
placement is.

### PORT-005 — External control command line

Answers the control-transport half of `FEAT-006`, and depends on `PORT-004` because
two of its actions start a named preset. Adopt the command-line client, its transport
client, and the shared protocol, exposing status, preset and manual session start,
pause, resume, and finish, with machine-readable status output.

Transport is file-based rather than a network socket, and the peer's protocol already
bounds message size, pending command count and bytes, command age, future clock skew,
and processed-command retention.

This is the only port that adds a new local attack surface, so it takes a security
review under this line's own policy **before** merge. Adopt all three peer hardening
fixes — restricted transport permissions, cleanup of abandoned temporaries, and
statusless lifecycle responses. Confirm that the transport directory is created with
restrictive permissions, and that malformed, oversized, or flooded commands cannot
stall the refresh loop or corrupt state, since every accepted command triggers a full
synchronous state write.

### Phase 3c verification gate

- Each port is a separate branch off current `main`, with the full suite plus the
  adopted peer tests green, and a reviewed diff confirming no unintended change to
  release automation.
- No port introduces changes under the activity graph; nothing upstream touches it.
- Records written before an added field still decode, for every port that adds one.
- Restoring a backup written at an older schema version runs the migration chain
  before replacement; a truncated or newer-version backup is rejected and leaves live
  state untouched; a recovery copy is written first; and the activity graph survives a
  backup and restore cycle intact.
- Exported fields beginning with spreadsheet formula characters are inert, exports
  honor active filters, and existing usage export output is unchanged after moving to
  shared infrastructure.
- Automation is off after both fresh install and upgrade; disabling it removes the
  workspace observer; and a session of application switching leaves no observed
  application data in persisted state, verified by diffing the state file.
- Control transport restricts directory permissions to the current user, rejects
  oversized, stale, and future-skewed commands without touching state, and survives a
  flood beyond its pending limit without stalling refresh or corrupting state.
- Once all ports land: fresh install, upgrade from the previous release with a real
  state file, a full backup and restore cycle, automation enabled and disabled, and a
  disposable-key release preflight confirming `SEC-001` and `SEC-002` still hold.

### Phase 3c risks

- **Regressing Phase 0 security is the top risk.** This line's release hardening lives
  in the validation workflow, the packaging script, and the release guide — three files
  the peer also modified, substantially. Never adopt peer versions of these wholesale;
  port individual improvements only after diffing against `SEC-001` and `SEC-002`.
- Both remotes carry colliding `v0.8.0` and `v0.9.0` tags, so any fetch without the
  no-tags discipline creates ambiguous local tags. Use the namespaced inspection form
  already documented when a peer tag needs local review.
- Restore is the only port that can destroy user data, because it replaces live state.
- Divergence keeps growing while these ports land; re-compare before each one.

## Phase 4: Strategic Expansion

### FEAT-006 — Selective peer-repository feature porting

Evaluate the peer repository's session presets, application automation, control
transport, and `codepulsectl` one slice at a time against this product line's
current activity graph, privacy model, migrations, and security policy. Port or
reimplement with new branches and tests; do not merge the peer's `v0.8.0`
history wholesale. Apply the same review boundary if features later move in the
other direction.

Dependencies: Phase 0–2 stability and a migration design. The independent
ownership/release decision is already recorded in Phase 0. Risk: duplicated
automation/timing authority and a new local control boundary. Strategic fit:
High if kept local, explicit, and reversible.

`PORT-004` and `PORT-005` are the executable plans for the named capabilities,
and record the decision to adopt them opt-in with a privacy-wording pass. This
entry remains the standing policy for any future peer evaluation.

### REL-002 — Developer ID signing and notarization

Design a protected Apple signing/notarization environment distinct from Sparkle
update signing. Verify hardened runtime, entitlements, stapling, first-install
Gatekeeper behavior, and rollback. This materially improves public distribution
but requires separate Apple-account authority and operational ownership.

### FEAT-007 — Validated budgets and alerts

Consider project/tool thresholds only after retention, attribution, pricing, and
data-quality states are trustworthy. Keep estimates distinct from charges and
never claim remaining provider balance. Notifications must be local and opt-in.

## Exploratory Ideas

- A signed pricing-catalog delivery channel independent of app releases, after
  the dormant refresher gains HTTP status/response-size/validity hardening and an
  accountable publisher.
- Privacy-preserving aggregate export formats for personal review or migration,
  with no account system.
- A formal plugin adapter protocol for additional local tools, but only after
  common resource, consent, workspace-binding, and versioning rules are encoded.
- Optional local performance telemetry visible only to the user for state size,
  save duration, and reader cost. This is diagnostic data, not remote analytics.
- Sponsorship or a paid signed/notarized convenience distribution may fit an MIT
  local-first project, but should follow maintainer/product validation rather
  than drive architecture now.

## Deferred or Rejected Ideas

| Idea | Status | Reason |
| --- | --- | --- |
| Prompt/transcript classification | Deferred | Violates the current content-free boundary without a separately approved handoff, redaction, persistence, export, and crash-reporting design. |
| Cloud-only session scraping | Deferred | No stable local signal; would require new provider/account boundaries. |
| Raw cross-device synchronization | Rejected for current roadmap | Creates a hosted privacy/security platform inconsistent with the local-first product. |
| Remaining provider balance retrieval | Deferred | No documented stable trustworthy source; estimates cannot become account truth. |
| Unpublished effort multipliers | Rejected | Would invent pricing/productivity facts without provider provenance. |
| Productivity or worker scoring | Rejected | Timing/token metadata does not justify an effectiveness score and would weaken product trust. |
| Windows/Linux/mobile ports | Deferred | Native macOS interaction, process, update, and persistence behavior should stabilize first. |
| Whole-history fork/upstream merge | Rejected | Independent 104/31-commit lines and conflicting `v0.8.0` tags require feature selection, not graph reconciliation. |

## Documentation Plan

Dependency order:

1. **DOC-001:** fix backup, deletion, Claude, Git-discovery, and preflight claims
   with the corresponding Phase 0 code changes.
2. **DOC-002:** update `docs/releasing.md` to the protected test-key preflight,
   current version-neutral examples, fork release channel, and recorded manual
   checklist.
3. Mark `docs/agent-aware-tracking-roadmap.md` as a completed historical plan;
   link `ROADMAP.md` as current without deleting historical evidence.
4. Create `docs/architecture.md` with current components, data flow, trust
   boundaries, persistence model, and extension points.
5. Create `CONTRIBUTING.md` with environment setup, exact validation tiers,
   style, privacy/security invariants, PR scope, and release-authority boundaries.
6. Decide between `CHANGELOG.md` and a documented GitHub-release-note policy;
   populate it before the next version.
7. Update usage/lifecycle/schema docs after workspace binding, resource limits,
   and retention behavior land.
8. Add `CODE_OF_CONDUCT.md`, support routing, and issue-template docs only when
   public Issues/contributions are enabled.
9. Re-run the local-link checker and add it to CI.

## GitHub Improvement Plan

1. **GH-002:** main/release rulesets and protected signing environment.
2. **GH-003:** enable vulnerability alerts, Dependabot security updates, and
   private vulnerability reporting; add code scanning if a useful Swift analyzer
   is selected.
3. **GH-004:** set description, homepage, topics, social preview, and explicit
   independent-fork/friendly-peer status.
4. Enable Issues only with an owner and triage cadence; then add bug/feature
   forms and a security redirect. Add a PR template tied to the validation list.
5. Disable empty Wiki/Projects features or populate them intentionally. Projects
   v2 must be manually checked with a token having `read:project`.
6. Keep SHA-pinned Actions and narrow permissions; add automated dependency PRs
   to normal review, never auto-merge release/signing changes.
7. Run the safe preflight and record its URL/result before tagging. Keep tag
   publication as a separate authority boundary.

## Branch Cleanup Plan

### Safe to delete now

**None.** The user explicitly prohibited all branch deletion, including branches
that appear merged. No local or remote branch was deleted or pruned during the
audit.

### Review before deletion

The following fork branches are merged/reachable and would normally be cleanup
candidates, but they are inventory only until a later explicit authorization:

- `agent/roadmap-architecture-ci`
- `docs/complete-release-hardening-guidance`
- `feature/00-roadmap` through `feature/17-usage-insights`
- `fix/fork-sparkle-release-feed`

Review local and `origin/*` refs separately. Confirm no worktree, automation,
external link, or retained release process depends on a name before any future
deletion.

### Keep

- `main` and `origin/main` — fork default/release source.
- `docs/repository-audit-roadmap` — active audit/deliverable branch.
- `feature/18-release-hardening` and its origin ref — not literally merged;
  commit `2a32588` is patch-equivalent to merged `5bb57cb`, but the branch still
  deserves explicit owner review.
- Local `feature/06-claude-lifecycle` until its behind-origin state is reviewed;
  do not delete merely because it has no unique commits.
- All `upstream/*` refs — remote owner state and reconciliation evidence.

### Rename or migrate

- No default-branch rename is required; both remotes already use `main`.
- Do not rename either existing `v0.8.0` tag. Migrate documentation and future
  release numbering to the recorded independent-release-line policy instead.
- Optionally rename/archive the **document**
  `docs/agent-aware-tracking-roadmap.md`; this is not a branch operation.

### Manual GitHub action required

- Add rulesets/branch and tag protection.
- Configure the protected production-signing environment and reviewers.
- Enable vulnerability alerts, Dependabot security updates, and private
  vulnerability reporting.
- Inspect Projects v2 and social preview with appropriate access.
- Set repository description/homepage/topics and decide Issues/Wiki/Projects
  availability.
- No branch deletion action is requested.

## Milestone Table

| ID | Initiative | Priority | Effort | Dependencies | Target phase | Success criteria |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-001 | Safe preflight input handling | P0 | S | None | 0 | Injection matrix rejected before mutation; no direct input interpolation in shell. |
| SEC-002 | Isolate production Sparkle key | P0 | M | SEC-001, GitHub admin | 0 | Non-approved refs cannot access production signing; disposable preflight passes. |
| SEC-003 | Non-executing Git profile | P0 | M | None | 0 | Sentinel Git helpers never execute; metadata tests pass. |
| BUG-001 | Receipt capacity repair | P0 | S | None | 0 | Count/byte bounds hold above quota under accepted/rejected traffic. |
| BUG-002 | Usage numeric bounds | P0 | M | None | 0 | Int-limit fixtures cannot crash parse, Insights, or export. |
| PRIV-001 | Truthful/versioned backup contract | P0 | M | Decision recorded | 0 | UI/docs/schema/tests agree on every sensitive category. |
| PRIV-002 | Complete integration deletion | P0 | S | PRIV-001 | 0 | Selected legacy/modern data absent after reload and backup. |
| GH-002 | Main/tag protection | P0 | S | GitHub admin | 0 | Required CI/PR; force-push/deletion blocked. |
| GH-005 | Independent-fork release policy | P0 | S | Decision recorded | 0 | Tag fetch instructions work; next release line unambiguous. |
| BUG-003 | Lifecycle workspace binding | P1 | M | SEC-003 | 1 | Cross-workspace reused IDs cannot mutate existing runs. |
| BUG-004 | OpenCode usage workspace binding | P1 | S | BUG-003 | 1 | Mismatched path remains unassigned. |
| SEC-004 | Spreadsheet-safe CSV | P1 | S | None | 1 | Formula-prefix matrix exports inert cells. |
| SEC-005 | Canonical OpenCode consent | P1 | S | PERF-003 design | 1 | Conflicting nested keys cannot enable intake. |
| SEC-006 | Pre-access discovery consent | P1 | S | SEC-003 | 1 | Disabled discovery invokes no resolver for unknown paths. |
| PERF-002 | Bounded Git snapshot | P1 | M | SEC-003 | 1 | Fixed bytes/paths/processes/deadline under large fixture. |
| PERF-003 | Bounded state decode | P1 | M | PRIV-001 | 1 | Oversized/deep state fails recoverably within budgets. |
| PERF-004 | Bounded usage enumeration | P1 | M | None | 1 | Fixed scan work and fair eventual processing. |
| UX-001 | Safe session discard | P1 | S | None | 1 | Confirmation/undo prevents single-action loss. |
| DEP-001 | Sparkle patch update | P1 | S | SEC-001, SEC-002 | 1 | Normal/TSan/package/update-signature checks pass. |
| DEP-002 | Retire deprecated Node.js 20 | P1 | S | Automation inventory | 1 | No owned Node 20 runtime remains; supported LTS and validation evidence are recorded. |
| TEST-001 | Safety regression suite | P1 | M | Phase 0/1 fixes | 1 | Every confirmed defect has a failing-before/passing-after test or static assertion. |
| PERF-001 | Retention and compaction policy | P1 | L | BUG-002–004, measurements | 2 | State growth and latency remain within documented budgets. |
| ARCH-001 | Decompose SessionStore | P2 | L | TEST-001 | 2 | Responsibilities extracted with unchanged behavior/tests. |
| ARCH-002 | Long-lived storage decision | P2 | L | PERF-001, benchmarks | 2 | Evidence-backed ADR and migration/rollback prototype. |
| DX-001 | Resolution lock policy | P2 | S | DEP-001 | 2 | Package command leaves clean tree; CI/local resolve identically. |
| DX-002 | Incremental format/lint | P2 | M | Style decision | 2 | Config exists; changed files are clean without giant mixed diff. |
| CI-001 | Expanded deterministic CI | P2 | M | DX-001/002, TEST-001 | 2 | Build/test plus static checks; informational coverage artifact. |
| DOC-001 | Privacy/security consistency | P0 | S | Corresponding fixes | 0–1 | README/privacy/security/integration claims match code. |
| DOC-002 | Current release guidance | P0 | S | SEC-001/002, GH-005 | 0–1 | Version-neutral safe steps and recorded preflight. |
| DOC-003 | Architecture/contribution structure | P2 | M | Stable Phase 1 behavior | 2 | One current roadmap, current architecture, reproducible dev guide. |
| GH-003 | GitHub security features | P1 | S | GitHub admin | 1 | Alerts/security updates/private reporting enabled and documented. |
| GH-004 | Public repository metadata/templates | P2 | S | Fork role decision | 2 | Description/topics/preview/support/contribution route are clear. |
| FEAT-001 | Integration/storage health | P2 | M | PERF-001 | 3 | Users see bounded, privacy-safe health and retention state. |
| FEAT-002 | Share-safe portable export | P2 | M | PRIV-001 | 3 | Versioned redacted output with category preview and tests. |
| FEAT-003 | Safe backup import | P3 | L | PRIV-001, PERF-003 | 3 | Previewed, bounded, rollback-safe import. |
| FEAT-004 | User-facing retention controls | P2 | M | PERF-001 | 3 | Transparent defaults and export-before-delete. |
| FEAT-005 | Release readiness report | P2 | M | SEC-001/002, DOC-002 | 3 | Non-secret evidence bundle gates tagging. |
| UI-001 | Interval arithmetic and state palette | P2 | M | TEST-001 | 3b | One union implementation with ported expectations; buckets sum to day total; every state distinct without color. |
| UI-002 | Unified navigation shell | P2 | L | UI-001 | 3b | One window replaces popover-plus-three-windows; duplicate Insights window impossible; shortcut and menu routing verified. |
| UI-003 | Activity timeline as Now section | P2 | L | UI-001, UI-002 | 3b | Concurrent runs render as distinct tracks; structure recomputes on graph revision only; list presentation equivalent ships with it. |
| UI-004 | Menu-bar ribbon and compact popover | P2 | M | UI-001 | 3b | Template ribbon legible highlighted and in both appearances; redraws bounded by policy; menu bar remains independently sufficient. |
| UI-005 | Graph-backed Insights timing | P2 | L | UI-001, TEST-001 | 3b | Timing measures agree with the timeline; session facts reach legacy data through one seam; every figure states its source. |
| UI-006 | Agent-run pull-request correlation | P2 | M | UI-005 | 3b | Standalone agent runs carry repository and pull request; pre-change state files decode unchanged. |
| UI-007 | Graph-owned session context | P3 | L | UI-005, UI-006, PERF-001 | 3b–4 | Context migrated under a new schema version with verified backfill; legacy fallback deleted. |
| UI-008 | Management surfaces out of preferences | P2 | M | UI-002 | 3b | Configuration and deletion surfaces sit in the window; preferences hold only preferences. |
| UI-009 | Shared interface primitives and retirement | P2 | M | UI-002, UI-005 | 3b | Primitives reusable outside Insights; shims removed; screenshot fixture populates the activity graph. |
| PORT-001 | Project archive state | P2 | S | None | 3c | Optional field; pre-existing records decode as active; round trip preserves identity. |
| PORT-002 | Backup restore and transactional replace | P2 | L | PRIV-001, PORT-001 | 3c | Older-schema backups migrate before replacement; activity graph survives a round trip; rejected backups leave state untouched. |
| PORT-003 | Exports module | P2 | M | PORT-002 | 3c | Shared export infrastructure; formula-safe fields; filters honored; existing usage export output unchanged. |
| PORT-004 | Session presets and application automation | P2 | L | PRIV-001, PORT-003 | 3c | Off by default; no observed-application data persisted; privacy claims match shipped behavior. |
| PORT-005 | External control command line | P3 | M | PORT-004, security review | 3c | Restricted transport permissions; bounded commands cannot stall refresh or corrupt state. |
| FEAT-006 | Selective peer feature porting | P3 | XL | Phase 0–2 | 4 | Individually ported features with migrations/security tests. |
| REL-002 | Developer ID/notarization | P3 | L | Apple authority, SEC-002 | 4 | Signed, notarized, stapled app passes clean-machine Gatekeeper. |
| FEAT-007 | Validated budgets/alerts | P3 | L | PERF-001, attribution/pricing validation | 4 | Opt-in thresholds never imply balance or billed total. |

Effort: S = focused change, M = multi-file feature, L = architectural or
operational project, XL = coordinated product-line integration.

## Success Metrics

- Zero open High security findings; no production-signing secret reachable from
  arbitrary refs or unvalidated shell inputs.
- All 219 existing tests plus new regression tests pass normally and under the
  selected sanitizer cadence; zero unexpected skips.
- Production line coverage remains visible from the 62.8% baseline and rises in
  trust-boundary/zero-coverage files without a target-driven test-quality drop.
- Receipt, inbox, state decode, process output, traversal, arithmetic, and
  retained-history budgets have explicit tests at and beyond their limits.
- Cross-workspace lifecycle and usage fixtures always remain isolated.
- Integration deletion leaves zero selected-tool legacy/modern records in
  persisted state or new backups.
- A clean build/test leaves `git status` unchanged.
- `main` and release tags are protected; required macOS validation is green.
- Vulnerability alerts, security updates, and private reporting are enabled with
  a documented response route.
- Safe release preflight succeeds, then a tagged release is produced only from
  protected `main`; DMG, checksum, appcast signature, and downloaded assets all
  verify.
- Cold launch, save, Insights, and backup latency stay within documented budgets
  at representative retained-history sizes.
- README/privacy/security/release/integration docs pass links and match current
  behavior; only one document is labeled the current roadmap.
- No branch is deleted without a later explicit authorization and fresh review.
- One interval-union implementation remains, and reported timing measures agree
  across the menu bar, the timeline, and Insights for the same period.
- Every activity state is distinguishable without color, and every graphic
  surface has a tested assistive-technology equivalent.
- Starting, finishing, and recording the outcome of a session never require the
  main window.
- Every adopted peer capability arrives as its own reviewed port with its tests,
  and no port weakens a Phase 0 security fix or imports peer tags.
- A backup written by any released version of this line restores into the current
  version with its activity graph intact.

## Recommended Execution Order

1. Freeze production-key preflight and future release activity.
2. Land SEC-001 and SEC-002 with workflow/static tests; configure the protected
   environment and repository rules.
3. Land SEC-003 around one safe Git runner contract; build Phase 1 PERF-002 on
   that contract without delaying the Phase 0 execution fix.
4. Land BUG-001 and BUG-002 with hard-limit regression fixtures.
5. Implement the recorded full-fidelity PRIV-001 contract; immediately follow
   with PRIV-002 and DOC-001, while retaining FEAT-002 as committed follow-on
   work.
6. Bind lifecycle and OpenCode usage to workspace identity (BUG-003/BUG-004).
7. Fix CSV, consent, discovery ordering, state decode, and usage enumeration.
8. Run normal tests, TSan, coverage, static checks, and the clean-machine/manual
   integration matrix; record results.
9. Update Sparkle and release guidance, then run a disposable-key preflight from
   an approved ref.
10. Define and benchmark retention before refactoring storage or `SessionStore`.
11. Add architecture/contribution docs and GitHub public/security metadata.
12. Select Phase 3 product work based on user value and measured limits.
13. Land the interface program in dependency order: interval arithmetic and the
    state palette first, then the navigation shell, then the timeline and the
    menu-bar ribbon in either order, then graph-backed Insights timing, agent
    pull-request correlation, the preferences relocation, and finally primitive
    extraction and screenshot regeneration. Defer graph-owned session context
    until retention is defined.
14. Adopt peer capabilities as individual ports, smallest first: project archive
    to prove the procedure, then backup restore, exports, presets and application
    automation, and finally external control. Never adopt peer versions of the
    validation workflow, packaging script, or release guide wholesale, and always
    fetch the peer without tags.
14. Prepare the next version, optionally complete Developer ID/notarization,
    and publish only under separate explicit release authority.
