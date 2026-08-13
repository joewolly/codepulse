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
  are Phase 0 deliverables, not an out-of-band suggestion.

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
- Create a protected GitHub production-signing environment with required
  approval and restrict it to reviewed `main`/release refs.
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

### FEAT-003 — Safe backup import and recovery preview

Only after `PRIV-001` and `PERF-003`: validate format/version/size, show a summary,
offer non-destructive merge or replace semantics, write a rollback copy, and
never silently replace newer state.

### FEAT-004 — Retention controls

Expose understandable defaults and optional per-category periods. Explain raw
versus aggregated history and show projected/actual storage impact. Deletion must
honor the same privacy contract as integration deletion.

### FEAT-005 — Release readiness report

Provide a local or CI-generated, non-secret report for version/tag alignment,
tests, package contents, signature verification, manual checklist, and known
limitations. It should not become an alternate publishing mechanism.

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
13. Decide whether to port individual capabilities from the peer repository.
14. Prepare the next version, optionally complete Developer ID/notarization,
    and publish only under separate explicit release authority.
