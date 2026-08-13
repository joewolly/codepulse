# Project Analysis

> Audit baseline: 2026-08-13, fork `ZacharyRW/codepulse`, revision
> `b2bc01e7f4ced9d4ab8a691ea3832ee1771e4ff3`. The audit work lives on the
> local branch `docs/repository-audit-roadmap`, created from the updated
> `origin/main`. No branches were deleted, pruned, rewritten, or force-pushed.

## Executive Summary

CodePulse is a native, local-first macOS menu-bar application for recording
work sessions and combining them with optional Git, GitHub, Codex, Claude Code,
and OpenCode context. It has grown from a stopwatch and journal into a
privacy-conscious activity graph with concurrent agent timing, usage/cost
attribution, history, insights, backups, and Sparkle-based updates.

The project is healthy in its core engineering baseline: the package builds,
all 219 discovered tests run with zero failures, the same suite passes under
Thread Sanitizer, production-source line coverage is 62.8%, CI is green, and
the latest fork release has a verified DMG, checksum, and Sparkle appcast. The
code is notably strong in explicit state transitions, dependency seams,
migration recovery, content-free integration schemas, signed pricing data,
redacted support output, and deterministic README screenshots.

The audit also found material trust-boundary problems that should block another
release until fixed. A selected repository can cause Git to execute
repository-configured helpers; the manual release-preflight workflow interpolates
untrusted dispatch strings into shell source; and that branch-selectable
preflight exposes the production Sparkle signing key to branch-controlled build
output. Ten medium-severity security/reliability findings include an unreachable
receipt-retention cap, token-overflow crashes, cross-workspace attribution gaps,
unbounded durable state, unsafe CSV formulas, and privacy controls whose copy or
deletion behavior does not match legacy stored data.

The recommended direction is therefore stabilization before expansion:

1. isolate production signing and neutralize repository-controlled Git execution;
2. repair privacy, correlation, arithmetic, and bounded-resource invariants;
3. add regression tests and enforce a small, intentional toolchain baseline;
4. reconcile fork/upstream product direction deliberately rather than merging
   two independently evolved `v0.8.0` lines;
5. only then consider upstream's session-automation work, retention controls,
   and a signed/notarized distribution path.

## Project Overview

| Area | Current state |
| --- | --- |
| Purpose | A private, local macOS work-session recorder with journal, insights, Git/GitHub enrichment, and optional local AI-agent timing/usage metadata. |
| Intended audience | macOS developers and other knowledge workers who want lightweight time/context history without a hosted account or telemetry service. |
| Main features | Menu-bar session lifecycle; projects and session types; pause/resume/finish review; Git and GitHub snapshots; journal filters/editing; insights; concurrent manual/agent runs; local Codex, Claude Code, and OpenCode lifecycle/usage adapters; usage-cost provenance; JSON backup; CSV/JSON usage export; Sparkle updates. |
| Stack | Swift 6.x toolchain, SwiftUI/AppKit, Swift Package Manager, Foundation, CryptoKit, Charts, `Process` wrappers for `/usr/bin/git` and optional `gh`, Sparkle 2.9.2. |
| Platform | Native macOS 13+ application; package target is macOS 13. |
| Maturity | Feature-rich pre-1.0 application with a strong automated core and a working public release pipeline, but not yet ready for another release because of confirmed security/privacy defects and incomplete manual release validation. |
| Data model | Versioned JSON `AppState` envelope containing projects, sessions, settings, an activity graph, integration processing state, usage samples, and migration history. |
| Network behavior | GitHub CLI metadata enrichment when `gh` is available; Sparkle appcast/update download; a signed pricing-catalog refresh implementation exists but has no current production caller. No account, cloud database, or telemetry service. |
| Build/test | `swift build` and `swift test`; GitHub Actions validates pushes and pull requests to `main`. |
| Distribution | `script/package_release.sh` stages a Universal 2 app/DMG when toolchains permit; tag workflow tests, packages, Sparkle-signs, publishes, downloads, and re-verifies assets. Initial downloads are intentionally not Developer ID signed or notarized. |
| Current version | `Resources/Info.plist` is `0.8.0` build `800`; the fork's latest GitHub Release is `v0.8.0`. Current `main` is 74 commits past that release tag. |

### Architecture and data flow

1. SwiftUI/AppKit entry points create a shared `SessionStore`.
2. `SessionStore` owns `AppState`, applies user actions and integration refreshes,
   coordinates Git/GitHub capture, and persists every accepted state change.
3. Manual sessions are represented compatibly in the newer
   workspace/activity/run/interval graph. Agent lifecycle events enter through a
   separate helper and bounded CodePulse-owned inbox, normalize to a strict v2
   schema, then advance an explicit run state machine.
4. Optional usage readers parse a narrow metadata allowlist from local Codex and
   Claude JSONL records or consume content-safe OpenCode plugin handoffs. Samples
   are attributed in memory to runs/workspaces and priced against a signed,
   versioned catalog.
5. History and Insights derive views from local persisted state. Backups serialize
   the entire state; support bundles use a separate aggregate-only schema.
6. The release script stages the app and Sparkle framework. GitHub Actions owns
   tag validation, packaging, Ed25519 appcast signing, publication, and artifact
   verification.

## Repository Structure

| Path | Role | Assessment |
| --- | --- | --- |
| `Sources/CodePulse/App` | App and application-delegate entry points | Small and conventional; currently uncovered by unit tests. |
| `Sources/CodePulse/Domain` | Persisted models, usage models, and agent state machine | Clear invariants and migration compatibility; several unbounded collections and unchecked numeric fields need policy. |
| `Sources/CodePulse/Sessions` | `SessionStore`, graph repository, timing metrics | Product orchestration center; `SessionStore.swift` is the largest source file at 1,147 lines and owns too many responsibilities. |
| `Sources/CodePulse/Services` | Git/GitHub, discovery, integration installation, lifecycle, and usage services | Generally well-separated and testable; most confirmed trust-boundary findings are here. |
| `Sources/CodePulse/{MenuBar,History,Insights,Settings}` | SwiftUI product surfaces | Functional, accessible in many paths, and represented by deterministic screenshots; several views are large and UI-only coverage is uneven. |
| `Sources/CodePulse/Persistence` | JSON envelope, migrations, recovery, and backups | Strong atomic-write/backup behavior; missing input complexity limits and a distinct redacted backup contract. |
| `Sources/CodePulseIntegration` | Shared schemas, validation, inboxes, path matching, OpenCode usage consent | Good isolation and strict event limits; receipt accounting, token bounds, and consent lookup need fixes. |
| `Sources/CodePulseIntegrationCLI` | Standalone hook/plugin helper | Narrow entry point with input deadline and size limits; it inherits the shared consent/inbox defects. |
| `Tests/CodePulseTests` | 34 Swift test files plus fixtures | Broad domain/service/migration/privacy coverage; no separate UI/E2E target and several app/UI files remain at 0% measured coverage. |
| `Resources` | App metadata and icon | Version/update metadata is coherent for the fork; release numbers must be changed before the next tag. |
| `docs` | Architecture decisions, integration contracts, privacy/release details, completed feature roadmap | Valuable and unusually thorough, but lacks a current index/architecture overview and still presents a completed execution plan as a roadmap. |
| `.github` | Three workflows and Dependabot version updates | Pinned actions and narrow token permissions are strengths; preflight secret handling and missing repository rules are urgent. |
| `script` | Local run, screenshot/icon generation, release packaging | Shell syntax is valid; packaging is documented and exercised by the release workflow. |
| `Package.swift` | SwiftPM products/targets and exact Sparkle dependency | Minimal and reproducible at the direct dependency level; a build creates an untracked `Package.resolved`, so the lockfile policy is undefined. |

Repository scale at the audited revision: 141 tracked files, 100 Swift files,
21 Markdown files, and about 33,500 tracked lines. The production and test Swift
sources contain about 21,800 lines.

## Validation Results

### Commands and outcomes

| Check | Command | Result |
| --- | --- | --- |
| Git baseline | `git status --short --branch`; `git log -1`; remote/ref comparisons | Clean `main` initially; fast-forwarded from `3810b68` to `b2bc01e` to match `origin/main`; audit branch then created. |
| Remote refresh | `git fetch --all --tags` | Branch fetches succeeded. Tag fetch failed reproducibly because fork and upstream publish different annotated `v0.8.0` tags. No prune was requested. |
| Package description | `swift package describe --type json` | Pass. Products: `CodePulse`, `codepulse-integration`, and `CodePulseIntegration`. |
| Debug build | `swift build --configuration debug` | Pass, 3.88 seconds after permitting normal Swift/Xcode cache access. |
| Tests | `swift test --configuration debug` | Pass: 219 executed, 1 skipped, 0 failures in 10.45 seconds. The skip is the expected OpenCode installer-path smoke test when OpenCode is not installed. |
| Coverage | `swift test --enable-code-coverage --configuration debug`; `swift test --show-codecov-path`; `jq` over LLVM JSON | Pass. Production sources: 9,759/15,546 lines, 62.8%; 1,261/1,978 functions, 63.8%; 2,900/4,724 regions, 61.4%. Whole-instrumented result is higher because tests are included. |
| Thread Sanitizer | `swift test --sanitize=thread --configuration debug` | Pass: 219 executed, 1 skipped, 0 failures; no sanitizer reports. |
| Shell syntax | `bash -n script/*.sh` | Pass. |
| Plist | `plutil -lint Resources/Info.plist` | Pass. |
| YAML parse | Ruby Psych parse of `.github/*.yml` | Pass. |
| Markdown links | Repository-local Markdown link checker | Pass: all 21 Markdown files had resolvable local links. |
| Patch whitespace | `git diff --check` | Pass before deliverable creation. |
| Formatting probe | `xcrun swift-format lint --recursive Sources Tests` | Tool ran and exited 0 but emitted 20,214 diagnostics, primarily 18,328 indentation and 1,316 line-length findings. There is no repository `.swift-format`, formatter check, or agreed style baseline. This is a tooling-policy gap, not 20,214 separate defects. |
| Tool availability | `command -v` checks | `swift-format` available; SwiftLint, ShellCheck, actionlint, Markdownlint, Syft, and Trivy were not installed. |
| Security scan | Codex Security standard repository scan `86e4f71a-f44a-461e-98e7-fce6360ae980` | Completed and sealed: 16 reportable findings (3 High, 10 Medium, 3 Low), all high-confidence. Coverage is partial only because dependency-advisory data and hostile runtime exploit instrumentation were unavailable. |

### Baseline limitations

The first sandboxed Swift invocation failed because the compiler could not write
its normal user module/cache directories. Re-running the same repository
commands with normal Xcode/Swift cache access succeeded; this was environmental,
not a repository failure. A clean-machine DMG install, sleep/wake matrix,
live Codex/Claude/OpenCode smoke matrix, production signing operation, and
notarization were not performed. No original failure was silently repaired.

## Existing Issue Verification

The only substantial in-repository work inventory is
`docs/agent-aware-tracking-roadmap.md`. It is an execution record, not a current
backlog: every Feature 00–18 entry is marked merged and the corresponding fork
PR/code is present. The table below does not revive those items.

| Existing item | Source | Current status | Verification | Still relevant? | Recommended action |
| --- | --- | --- | --- | --- | --- |
| Feature 00 — governing roadmap | Feature roadmap; PR #1 | Already fixed | File and merged PR exist. | Historical only | Mark the old roadmap as a completed historical plan and link this roadmap. |
| Feature 01 — versioned persistence | Feature roadmap; PR #3 | Already fixed | Envelope/migration/recovery code and 6 migration tests pass. | Yes, as architecture | Keep docs; extend with input bounds. |
| Feature 02 — activity graph | Feature roadmap; PR #4 | Already fixed | Workspace/activity/run models and tests pass. | Yes | Keep. |
| Feature 03 — v2 event intake | Feature roadmap; PR #5 | Partially confirmed | Strict schema, diagnostics, and tests exist; receipt quota is defective. | Yes | Preserve design; fix `BUG-001`. |
| Feature 04 — agent timing | Feature roadmap; PR #7 | Already fixed | State-machine and timing tests pass. | Yes | Keep; add workspace rebinding tests. |
| Feature 05 — Codex lifecycle | Feature roadmap; PR #9 | Already fixed | Installer, mapper, lifecycle path, settings, and tests present. | Yes | Keep. |
| Feature 06 — Claude lifecycle | Feature roadmap; PRs #10/#13 | Already fixed | Parent/child mapping and lifecycle tests pass. | Yes | Keep. |
| Feature 07 — OpenCode lifecycle | Feature roadmap; PRs #11/#13 | Already fixed | Managed plugin, mapping, health, and tests present. | Yes | Keep. |
| Feature 08 — Git discovery | Feature roadmap; PRs #12/#13 | Partially confirmed | Identity/discovery code and tests pass; consent is checked after metadata access. | Yes | Fix `SEC-006` and the `SEC-003` Git execution boundary. |
| Feature 09 — local-task discovery | Feature roadmap; PR #14 | Already fixed | Bounded local file/folder resolution and tests pass. | Yes | Keep. |
| Feature 10 — concurrent activity UI | Feature roadmap; PR #15 | Already fixed | Metrics, projection, screenshots, and tests pass. | Yes | Keep. |
| Feature 11 — classification | Feature roadmap; PR #16 | Already fixed | Metadata-only classification and rejection tests pass. | Yes | Keep prompt-free boundary. |
| Feature 12 — pricing catalog | Feature roadmap; PR #17 | Already fixed | P-256 signature, monotonic version, expiry fallback, provenance, and tests pass. | Yes | Keep; update Sparkle separately. |
| Feature 13 — Codex usage | Feature roadmap; PR #18 | Partially confirmed | Opt-in reader and attribution exist; retained history and arithmetic lack global bounds. | Yes | Fix shared usage invariants. |
| Feature 14 — Claude usage | Feature roadmap; PR #19 | Partially confirmed | Parent/child de-duplication passes; enumeration and numeric aggregation are unbounded. | Yes | Fix shared usage invariants. |
| Feature 15 — OpenCode usage | Feature roadmap; PR #20 | Partially confirmed | Content-safe opt-in path exists; consent, token bound, and workspace attribution defects remain. | Yes | Fix `BUG-002`, `BUG-004`, and `SEC-005`. |
| Feature 16 — usage attribution | Feature roadmap; PR #21 | Partially confirmed | Reports and large-history tests pass; crafted OpenCode records can cross workspace boundaries. | Yes | Fix correlation before adding new analytics. |
| Feature 17 — Insights/export | Feature roadmap; PR #22 | Partially confirmed | UI, JSON/CSV export, and tests exist; CSV formulas and overflow are unsafe. | Yes | Fix export safety and arithmetic. |
| Feature 18 — hardening/release | Feature roadmap; PR #23 plus #24 | Partially confirmed | Pinned actions, privacy controls, support bundle, tests, and release docs exist; three High release/Git findings contradict completion of the security portion. | Yes | Treat the merged plan as historical; reopen only the verified defects under new IDs. |
| Prompt-content classification | README, classification doc, ADR | Confirmed deliberate defer | v2 schema rejects content-bearing fields and tests enforce it. | Relevant product boundary | Keep deferred; do not add prompt ingestion without a separate approved privacy design. |
| Cloud-only agent sessions | Completed roadmap/release guide | Confirmed deliberate defer | All adapters require a local hook/process/log/plugin. | Relevant limitation | Keep deferred unless a privacy-preserving supported API is selected. |
| Budgets, alerts, enforcement | Completed roadmap/release guide | Confirmed deliberate defer | A disabled non-persisted extension point is tested; no budget UI/logic ships. | Potential future feature | Reconsider only after data integrity, retention, and pricing validation. |
| Remaining provider balance | Completed roadmap/pricing docs | Confirmed deliberate defer | No stable trustworthy source is implemented. | Low strategic fit now | Keep deferred. |
| Unpublished effort multipliers | Completed roadmap/pricing docs | Confirmed rejected inference | Pricing code preserves effort but does not invent rates. | Yes, as guardrail | Continue to reject unpublished multipliers. |
| Raw cross-device sync | Completed roadmap/release guide | Confirmed deliberate defer | No cloud storage or account system exists. | Poor fit now | Keep deferred; local-first privacy is a differentiator. |
| Clean-machine/manual release checklist | `docs/agent-aware-release.md` | Unable to verify | No durable signed checklist result; release-preflight has zero runs. | Yes | Fix preflight first, then execute and record the matrix before release. |
| Current Claude API-equivalent pricing | `docs/pricing-catalog.md` | Confirmed limitation | Bundled signed catalog has no Claude model entry. | Yes | Keep unpriced until a provider-published signed entry is available. |
| Large Git output may lose snapshots | `docs/agent-aware-release.md` | Confirmed and understated | Source shows unbounded output plus one process per new untracked path. | Yes | Promote to `PERF-002`; bound the entire capture. |
| Persistent history grows | `docs/agent-aware-release.md` | Confirmed and understated | Usage samples and graph records have no retention policy. | Yes | Promote to `PERF-001`; deletion alone is not a capacity strategy. |

No ordinary `TODO`, `FIXME`, `HACK`, `BUG`, `XXX`, disabled-test backlog, or
placeholder implementation list was found. The single skipped test is an
environment-gated OpenCode installer smoke check, not a disabled regression.

## Newly Discovered Findings

Stable IDs below are used by `ROADMAP.md`. Security findings map to the sealed
scan's canonical rule IDs.

### Critical

No Critical finding was validated.

### High

#### SEC-001 — Manual preflight permits workflow-input shell injection

- **Category / rule:** CI/CD command injection;
  `ci.workflow-dispatch-expression-injection`; CWE-78.
- **Affected:** `.github/workflows/release-preflight.yml` lines 4–76.
- **Evidence:** `version` and `build` are strings substituted as
  `${{ inputs.* }}` directly into Bash source before their regex validation.
  The same job later receives the production Sparkle private-key secret and
  executes a `sign_update` binary found under branch-influenced `.build`.
- **Impact:** a collaborator allowed to dispatch the workflow can alter shell
  grammar, modify the checkout/build tree, and potentially capture the
  production update-signing key.
- **Verification:** inspect the rendered `run` blocks; a quote/metacharacter
  payload is parsed by Bash before the attempted value check. No production
  workflow was dispatched during this audit.
- **Fix:** pass inputs through `env`, validate only quoted runtime variables,
  remove all direct expression interpolation from shell, and resolve the
  Sparkle tool at a deterministic reviewed path.
- **Confidence:** High.

#### SEC-002 — Branch-selectable preflight crosses the production signing boundary

- **Category / rule:** excessive privilege/secret exposure;
  `ci.branch-selectable-production-signing-key`; CWE-732.
- **Affected:** `.github/workflows/release-preflight.yml`; GitHub Actions secret
  and repository rules.
- **Evidence:** `workflow_dispatch` does not restrict the ref. Checkout, tests,
  packaging, dependency build, and tool lookup use the selected branch before
  the job supplies `SPARKLE_PRIVATE_KEY_BASE64`. The fork has no branch
  protection, ruleset, or protected signing environment.
- **Impact:** a collaborator able to push and dispatch a branch can run
  branch-controlled code with the long-lived key used to authenticate updates
  to installed clients.
- **Verification:** workflow control-flow inspection plus GitHub API checks for
  main protection and rulesets. The workflow has never been run.
- **Fix:** use a disposable test key for preflight; move production signing to a
  protected environment with required approval; pin an approved ref/SHA.
- **Confidence:** High.

#### SEC-003 — Read-only Git capture can execute repository-configured programs

- **Category / rule:** command execution;
  `git.repository-config-command-execution`; CWE-78.
- **Affected:** `ProcessGitCommandRunner`, `SystemGitService`, session start and
  finish capture.
- **Evidence:** CodePulse invokes fixed `/usr/bin/git`, but inherits repository
  configuration/environment. `git status` does not disable `core.fsmonitor`;
  diff commands omit `--no-ext-diff` and `--no-textconv`.
- **Impact:** selecting or automatically discovering a prepared local Git
  repository can execute a configured helper as the CodePulse user.
- **Verification:** source trace from `SessionStore` to Git status/diff calls.
  A normal network clone does not copy `.git/config`, reducing ordinary
  exposure, but prepared local repositories are within the documented boundary.
- **Fix:** centralize a sanitized Git profile, disable execution-bearing config
  and environment features, add non-executing diff flags, and test sentinel
  helpers.
- **Confidence:** High.

### Medium

#### BUG-001 — Receipt quota can never activate

`DeveloperToolInbox.writeReceipt` checks for 2,048 receipts using
`managedJSONFiles`, but that helper returns at most 256. Every accepted,
duplicate, or rejected event can therefore create another receipt indefinitely.
This can consume disk/inodes and makes directory scans progressively more
expensive. Populate the receipt directory beyond 2,048 to reproduce the failed
invariant. Separate full capacity accounting from the 256-item processing batch
and enforce both file and byte budgets. **Confidence: High.**

#### BUG-002 — Crafted usage counters can persist a crashing overflow

OpenCode accepts any nonnegative Swift `Int`; Claude can reduce multiple nested
counters with ordinary addition; analytics and export use trapping `Int`
addition. An `Int.max` counter plus any positive counter can terminate the app,
and a persisted sample can make Insights/export repeatedly crash. Enforce
plausible per-field/record limits and checked or saturating aggregate behavior;
test both single-record and cumulative overflow. Affected components include
`OpenCodeUsageInbox`, `ClaudeUsageTracking`, `UsageAttribution`, and
`UsageInsights`. **Confidence: High.**

#### BUG-003 — Later lifecycle events are not rebound to their workspace

New agent runs resolve a working directory, but existing-run lookup happens
first and matches only integration plus salted session fingerprint. Reusing a
session identifier from another directory can update timing, classification,
model, or termination for the original workspace. Persist/derive a canonical
workspace identity for the run and reject mismatches; test deliberate session-ID
reuse across two roots. **Confidence: High.**

#### BUG-004 — OpenCode usage attribution ignores working directory

The OpenCode event validates and retains `workingDirectory`, but
`OpenCodeUsageTrackingService.attribution` filters only by fingerprint,
integration, and time. A same-ID event from another path can be charged to the
wrong project. Require the path/identity to match the candidate run's workspace
or leave the sample unassigned with a bounded diagnostic. **Confidence: High.**

#### PERF-001 — Accepted activity and usage history has no durable budget

All three usage services append to `usageSamples`; novel lifecycle sessions can
append runs, activities, and workspaces; `SessionStore` then encodes the complete
state. Inbox and diagnostic limits do not cap accepted lifetime data. Sustained
valid input therefore grows memory, saves, backups, analytics, and launch work
without bound. Define age/count/serialized-byte/rate policies and an aggregation
or archive strategy. **Confidence: High.**

#### PERF-002 — Git capture has unbounded output, paths, child count, and total time

The runner buffers stdout/stderr to EOF, `status` and `ls-files` return every
untracked path, and finish capture launches one `git diff --no-index` process
per new untracked file. The two-second limit is per process, not per snapshot.
A repository with thousands of files can delay save and pressure memory despite
background execution. Stream/cap output and records, batch work, set one total
deadline/process budget, and terminate process groups decisively. **Confidence:
High.**

#### PERF-003 — State and recovery files decode without resource limits

Launch reads complete primary/backup JSON through `Data(contentsOf:)`,
`JSONSerialization`, and `JSONDecoder`, with unbounded arrays, strings, nesting,
and graph size. A malformed oversized state can cause persistent launch denial.
Add a conservative byte cap before read and validate structural/collection
invariants while preserving the original/recovery behavior. **Confidence: High.**

#### SEC-004 — Usage CSV cells remain spreadsheet formulas

`UsageInsights.csvRow` doubles quotes and wraps each field but does not neutralize
leading `=`, `+`, `-`, `@`, whitespace, tab, or carriage-return formula forms.
Integration-controlled provider/model/mode labels reach the export. Opening a
crafted CSV in spreadsheet software may evaluate it. Neutralize every string
cell before CSV quoting and add a dangerous-prefix matrix. **Confidence: High.**

#### PRIV-001 — Backup disclosure contradicts exported legacy metadata

The Settings UI says a full backup contains “No secrets or external data,” and
`PRIVACY.md` says backups omit external session identifiers. The backup encodes
all of `AppState`, including legacy `DeveloperToolSessionContext` raw external
session IDs and working directories; a test confirms those contexts round-trip.
Adopt a versioned redacted backup contract or explicitly disclose the complete
unredacted content at the decision point. **Confidence: High.**

#### PRIV-002 — Integration deletion leaves legacy lifecycle data behind

The confirmation promises deletion of saved lifecycle data for a selected tool.
`deleteIntegrationData` removes modern runs, usage, diagnostics, and checkpoints
but never filters active/completed-session `developerToolContexts`, so raw legacy
IDs and paths remain in state and later backups. Delete those compatible fields
and add reload/backup regression tests. **Confidence: High.**

#### GH-005 — Fork/upstream `v0.8.0` tag collision breaks normal tag fetches

The fork's annotated `v0.8.0` resolves to `a4307a1`; upstream's independently
published `v0.8.0` resolves to `547cd56`. `git fetch --all --tags` refuses to
clobber the tag. The two `main` branches also diverge by 104 fork-only and 31
upstream-only commits, changing 121 files. Do not overwrite either tag or merge
blindly. Establish an explicit upstream-integration/versioning policy and use
remote-specific tag inspection or a clean namespace during reconciliation.
**Confidence: High.**

### Low

| ID | Finding | Evidence and impact | Verification / recommended fix | Confidence |
| --- | --- | --- | --- | --- |
| SEC-005 | Recursive OpenCode consent lookup can accept an unrelated key | `OpenCodeUsageConsent` recursively searches all dictionaries/arrays for a same-named Boolean rather than `payload.settings`. Content-safe usage can queue while canonical consent is false. | Decode a minimal versioned envelope; test conflicting same-name fields. | High |
| PERF-004 | Codex/Claude 512-file cap is applied after full recursive sort | Both `sessionFiles()` implementations enumerate/materialize/sort every JSONL path before callers apply `prefix(512)`, on an enabled one-second refresh path. | Add traversal/time/candidate budgets and a fair resumable cursor. | High |
| SEC-006 | Disabled Git discovery still reads unknown Git metadata | `workspaceResolver.resolve` runs before the global discovery toggle check. The setting prevents creation, not preceding access. | Move the guard before unknown-path resolution; test that the resolver is never called. | High |
| UX-001 | “Discard Session” has no confirmation or undo | The destructive review-stage button calls `store.discardSession()` directly, while other destructive settings actions use alerts. An accidental click loses the unsaved completed session. | Add confirmation or a recoverable undo/grace path and UI tests. | High |
| DX-001 | SwiftPM resolution policy dirties a clean checkout | A normal package command creates an untracked root `Package.resolved`; it is neither committed nor ignored. | For an executable application, preferably commit the lockfile; otherwise explicitly ignore/document the policy. | High |
| DX-002 | Formatting has no repository baseline | Default `swift-format` produced 20,214 diagnostics and CI runs no formatter/linter. | Add a style config matching intentional current conventions, format incrementally, then enforce changed files. | High |
| DEP-001 | Sparkle is behind current patch release | `Package.swift` pins 2.9.2; the latest release queried on 2026-08-13 is 2.9.5. | Review 2.9.3–2.9.5 notes, update in a dedicated PR, package, and verify update signing. | High |
| DOC-001 | Privacy copy omits Claude in two integration summaries | `PRIVACY.md` lines 71 and 76 name Codex/OpenCode while the surrounding sections and implementation support Claude Code too. | Correct wording in the same privacy-consistency change as `PRIV-001`. | High |
| DOC-002 | Release examples still present `v0.4.3` as the concrete command/output | `docs/releasing.md` uses old example artifact/tag values while current metadata and latest release are 0.8.0. | Make examples parameterized or clearly label them illustrative; add a release-doc consistency check. | High |

### Informational strengths

- Event v2 uses a closed content-free schema, bounded identifiers/metadata,
  timestamp checks, canonical paths, installation-salted fingerprints, inbox
  quotas, and redacted diagnostics.
- Integration installers use fixed managed targets, marker checks, atomic writes,
  and symlink resistance. No path traversal or privilege-amplifying deletion
  escape was validated.
- State writes are atomic; migrations preserve original bytes and do not replace
  unknown future versions with empty state.
- Pricing manifests are signed, versioned, replay-resistant, and provenance-rich;
  invalid or expired remote data does not silently replace the last verified
  usable catalog.
- Redacted support bundles use a separate aggregate schema and exclude paths,
  identifiers, content, credentials, and freeform text.
- GitHub URLs are normalized to `github.com`, subprocess arguments are structured,
  and no private credential or signing-key value was found in the repository.
- Destructive project and integration-data actions use confirmation alerts;
  accessibility labels/hints and keyboard shortcuts are extensive.

## Architecture Assessment

### Strengths

- Explicit domain models and a state-machine reducer make timing behavior
  inspectable and testable.
- Protocol-backed clocks, persistence, readers, resolvers, and command runners
  allow deterministic unit tests without network dependence.
- Manual-session compatibility is preserved while the richer activity graph is
  adopted incrementally.
- Lifecycle and usage paths are separated, so malformed usage cannot mutate
  timing state.
- Local-first storage, opt-in readers, content rejection, cost provenance, and
  redacted diagnostics form a coherent product identity rather than scattered
  privacy patches.
- Release packaging, feed ownership, appcast signing, and post-publish asset
  verification are encoded rather than relying only on prose.

### Weaknesses and technical debt

- `SessionStore` is a 1,147-line application service coordinating UI state,
  persistence, timers, integrations, Git/GitHub, migration compatibility, and
  deletion. Its centrality makes ordering and privacy omissions easy.
- The single JSON document couples every history dimension to full-state copies,
  encoding, backup, and launch decoding. This architecture is simple and safe
  for small data but has no sustainable lifetime-growth plan.
- Workspace identity is not a first-class invariant on every agent/usage record;
  it is resolved at creation and then inferred by session fingerprint/time.
- Resource limits are implemented locally at several inboxes/readers but lack a
  shared policy for accepted durable data, process output, parsing, and arithmetic.
- Large SwiftUI files (`InsightsView`, `HistoryView`, `SettingsView`, and
  `MenuBarPopoverView`) combine view composition, formatting, export actions,
  and state wiring. UI behavior is harder to cover than the domain services.
- The fork and upstream both call independent product lines `v0.8.0`, so normal
  version/tag semantics no longer describe ancestry or feature compatibility.

### Recommended architectural improvements

1. Extract `SessionStore` collaborators for session lifecycle, integration
   ingestion, persistence scheduling, and deletion/privacy policy while keeping
   one observable façade for views.
2. Introduce a single `ResourcePolicy`/bounded-input layer covering bytes,
   records, retention age, process count/time, string lengths, and overflow.
3. Bind canonical workspace identity to agent runs and usage correlation keys.
4. Define a migration path from monolithic state to segmented/append-friendly
   storage or compacted aggregates before history volume makes it urgent.
5. Separate full recovery backups from explicitly redacted shareable exports.
6. Split UI export/formatting operations into testable services and add targeted
   view/accessibility tests rather than snapshotting implementation details.

## Test and Quality Assessment

The suite is unusually broad for a small macOS app: 219 tests cover migrations,
atomic failures, timing boundaries, concurrent intervals, project matching,
Git/GitHub parsing and async updates, integration contracts/installers,
usage/cost provenance, export privacy, screenshots, and support bundles. The
Thread Sanitizer pass gives additional confidence in exercised concurrency.

Measured production line coverage is **62.8%**. Domain and service code is often
well covered, but app entry points, several support controllers, Settings,
GitHub context UI, menu-bar labeling, and `OpenCodeUsageConsent` measured 0%.
The number should be treated as a baseline, not a target to game. The highest
value additions are regression tests for all Phase 0 findings, deletion/backup
contracts, hostile Git configuration, process/output budgets, and workflow
static checks.

CI currently performs clean build and tests on `macos-14`; it does not run
coverage, formatting, workflow lint, shell lint, sanitizer variants, or release
preflight. Add small deterministic checks first. Keep TSan scheduled/manual if
runtime cost is undesirable on every PR.

## Security and Privacy Assessment

The sealed scan found 3 High, 10 Medium, and 3 Low reportable findings, all with
high confidence. Its threat model treats selected repositories and enabled
developer-tool inputs as untrusted while assuming the macOS account is not
already fully compromised. This matches `SECURITY.md` and avoids inflating
same-user filesystem races that grant no authority beyond an already compromised
account.

No committed private credential was found. GitHub secret scanning and push
protection are enabled, with no open secret-scanning alerts. Sparkle update
archives are authenticated with an embedded public key, and the release workflow
compares the derived public key, verifies the archive, and re-downloads published
assets. Initial DMGs remain unsigned/notarized by explicit policy.

Potential risks not promoted to findings: check/use races around local inbox
files are worth hardening but did not cross a distinct authority boundary;
the signed remote pricing refresher lacks response-size/status hardening but has
no production caller; PATH fallback for `gh` was not shown to be influenced by a
selected repository; and compromised-host scenarios remain generally out of
scope.

## Performance Assessment

No wall-clock product profiling was run, so startup/render claims are limited to
source-backed risks and tests. Confirmed risks are the one-process-per-untracked
Git loop, unbounded process output, complete recursive usage-log enumeration,
full-state decoding, unlimited accepted history, and full-state rewrites. A
large-history analytics unit test passes quickly for its fixture, but it does not
establish behavior for years of usage or adversarial integration volume.

After bounding correctness, measure cold launch against state size, save latency
against session/usage counts, Insights render/report time, resident memory, and
Git finish capture for 1/100/1,000/10,000 new files. Use those measurements to
decide when segmented storage is necessary.

## Documentation Assessment

| Document | Status | Problems | Recommended action |
| --- | --- | --- | --- |
| `README.md` | Accurate and polished | Dense; no explicit fork/upstream divergence/status; Sparkle badge is 2.9.2. | **Update** status, contribution/reporting route, and dependency badge after upgrade; keep screenshots. |
| `PRIVACY.md` | Strong but internally inconsistent | Omits Claude in two summaries; backup identifier claim conflicts with legacy encoded state. | **Update urgently** with code/UI and deletion behavior. |
| `SECURITY.md` | Strong | Trust boundary says Git capture is read-only but configured helpers can execute; private reporting is disabled. | **Update** after fixing Git execution and enabling a reporting channel. |
| `LICENSE` | Accurate MIT license | None found. | **Keep**. |
| `docs/activity-classification.md` | Accurate | No major issue. | **Keep**; retain prompt-free boundary. |
| `docs/adr/0001-agent-aware-tracking-decisions.md` | Accurate architectural record | Some release-scoped wording now reads as current roadmap. | **Keep** as ADR; add superseding links only when decisions change. |
| `docs/agent-aware-release.md` | Useful but partially inaccurate | Calls receipts bounded and Git issue only “snapshot unavailable”; manual checklist has no recorded run. | **Update** after fixes; preserve as release/limitations guide. |
| `docs/agent-aware-tracking-roadmap.md` | Completed historical plan | Title/position can be mistaken for current backlog; all Features 00–18 are merged. | **Archive/retitle** as completed plan and link `ROADMAP.md`; do not delete. |
| `docs/agent-run-state-machine.md` | Accurate | Does not state the missing workspace-binding invariant. | **Update** with the fixed correlation contract. |
| `docs/claude-code-lifecycle-integration.md` | Accurate | Manual smoke result not recorded. | **Keep/Update** with last-verified matrix. |
| `docs/claude-code-usage-tracking.md` | Mostly accurate | Does not describe enumeration/retention limits because they do not exist. | **Update** after retention work. |
| `docs/codex-lifecycle-integration.md` | Accurate | Manual verification provenance is not dated. | **Keep/Update** verification record. |
| `docs/codex-usage-tracking.md` | Mostly accurate | Same retention/enumeration gap. | **Update** after retention work. |
| `docs/concurrent-activity-ui.md` | Accurate | No major issue. | **Keep**. |
| `docs/git-workspace-discovery.md` | Partially accurate | Consent and read-only claims omit pre-toggle access/configured-helper execution. | **Update urgently** after fixes. |
| `docs/opencode-lifecycle-integration.md` | Accurate | No major documentation defect found. | **Keep**. |
| `docs/opencode-usage-tracking.md` | Partially accurate | Consent path, token bounds, and workspace attribution are stronger in prose than code. | **Update** alongside fixes. |
| `docs/persistence-schema-v1.md` | Useful but incomplete | Says OpenCode inbox is bounded but does not distinguish defective receipt ledger or unbounded accepted history/legacy backup fields. | **Update** after schema/retention decisions. |
| `docs/pricing-catalog.md` | Accurate | Current Claude unpriced limitation is clear; remote refresh is described though not wired. | **Keep**; label refresh as dormant until shipped. |
| `docs/releasing.md` | Substantive but stale in examples | Uses v0.4.3 concrete commands/output and documents the unsafe production-key preflight. | **Update urgently** after workflow redesign; parameterize examples. |
| `docs/usage-attribution.md` | Mostly accurate | Missing required workspace/path binding for OpenCode usage. | **Update** after `BUG-004`. |
| `docs/usage-insights.md` | Mostly accurate | Does not cover CSV formula neutralization or history retention. | **Update** after fixes. |
| `ANALYSIS.md` | New canonical audit | Must be revalidated as code changes. | **Keep** as dated evidence snapshot; do not use as live status without checking code. |
| `ROADMAP.md` | New canonical forward plan | Requires owner prioritization and regular reconciliation. | **Keep** as the one current repository roadmap. |
| `CONTRIBUTING.md` | Missing | Setup/test/style/PR expectations are scattered. | **Create** after the safety phase. |
| `CHANGELOG.md` | Missing | GitHub generated notes exist only for one fork release. | **Create** or adopt a clearly documented release-notes policy before the next release. |
| `CODE_OF_CONDUCT.md` | Missing | Needed only if public contribution is invited. | **Create** when Issues/contribution are enabled. |
| `docs/architecture.md` | Missing | Architecture must be reconstructed across ADR, schema, and feature docs. | **Create** a concise current-state map and link specialized documents. |
| `docs/development.md` | Missing | README has commands, but toolchain, coverage, formatter, and test tiers lack one home. | **Create**, potentially as part of `CONTRIBUTING.md`. |

Recommended final structure: keep the README as product/install entry point;
keep `PRIVACY.md`, `SECURITY.md`, and `LICENSE` at root; make `ROADMAP.md` the
only current plan; preserve the completed feature plan under a clearly historical
name; add one current architecture overview and one contribution/development
guide; retain specialized lifecycle/usage/release documents rather than merging
them into an unmaintainable monolith.

## GitHub Repository Assessment

### Current fork state

- Public fork: `ZacharyRW/codepulse`; default branch `main`; MIT license.
- Description, homepage, and topics are empty. Issues and Discussions are
  disabled. Wiki and Projects are enabled; Projects v2 contents could not be
  read because the token lacks `read:project`.
- No open Issues, PRs, or draft PRs. PR #1 and #3–#24 are merged. PR #2 was a
  closed, unmerged temporary CI verification branch whose remote branch is gone.
- No milestones. One GitHub Release, `v0.8.0`, with DMG, checksums, and appcast.
  The release workflow succeeded.
- Current `main` validation is green. Recent PR/main validation runs are green.
  The non-publishing Release preflight has **zero runs** and must not be run with
  the production key until `SEC-001` and `SEC-002` are fixed.
- Three active workflows: macOS validation, Release preflight, GitHub Release.
  Third-party action revisions are SHA-pinned and permissions are narrow.
- Dependabot checks SwiftPM and GitHub Actions weekly, limited to three version
  PRs per ecosystem. Dependabot security updates, repository vulnerability
  alerts, private vulnerability reporting, and code scanning are disabled or
  unavailable. Secret scanning and push protection are enabled; no open secret
  alerts were found.
- `main` has no branch protection and the repository has no rulesets. Auto-merge,
  update-branch, and automatic branch deletion are disabled. Merge, squash, and
  rebase strategies are all allowed.
- No issue templates, PR template, funding file, contribution guide, code of
  conduct, deployment environment, Pages site, or Packages were found. This is
  not inherently wrong, but it conflicts with presenting the fork as a public
  maintained release source.
- Social-preview rendering and repository-page visual metadata were not
  inspectable through the available API. README screenshots themselves are
  deterministic, current-looking, privacy-safe fixtures and render clearly.

### Recommended GitHub improvements

1. Immediately protect production signing with an environment/approval and
   protect `main`/release tags with a ruleset requiring macOS validation and
   blocking force-push/deletion.
2. Enable vulnerability alerts, Dependabot security updates, and private
   vulnerability reporting; document the actual reporting route.
3. Declare whether the fork is the integrated product, an experimental fork, or
   a contribution staging area relative to `joewolly/codepulse`.
4. Add a concise description, homepage/release link, topics (`macos`, `swift`,
   `swiftui`, `time-tracking`, `developer-tools`, `local-first`), and a social
   preview.
5. Enable Issues only if maintainers will triage them; then add bug/feature forms,
   a security redirect, and a PR template. Disable empty Wiki/Projects features
   if they are not used.
6. Add a coverage/reporting policy only after the metric is stable; avoid a badge
   that implies an enforced threshold when none exists.

## Branch Assessment

### Default branches and divergence

Both `origin` and `upstream` report `main` as their default; no `master` or
`trunk` branch/reference was found. Local `main` was safely fast-forwarded to
`origin/main` at `b2bc01e`. It was not merged with upstream: neither remote main
is an ancestor of the other. `origin/main...upstream/main` contains 104/31 unique
commits and a 121-file content delta. Upstream's 31 commits add a different
v0.8 session-automation/control/preset line; the fork's 104 commits add the
agent-aware tracking/usage/release-hardening line.

### Fork local and remote branches

All dates are 2026 and all branches are recent, not stale by age. “0 unique”
means the tip is reachable from current `main`. No deletion is authorized or
performed.

| Branch | Last activity | Merge status | Associated PR | Unique commits vs `main` | Recommended action | Reason |
| --- | --- | --- | --- | ---: | --- | --- |
| `main` / `origin/main` | Aug 13 | Default/current | — | 0 | Keep | Fork default and release source. |
| `docs/repository-audit-roadmap` | Aug 13 | Active audit branch | None | 0 committed at branch creation | Keep | Contains this audit work once committed. |
| `feature/00-roadmap` / origin | Aug 12 | Merged | #1 | 0 | Retain for now | User explicitly prohibited deletion; historical feature tip. |
| `feature/01-persistence-migrations` / origin | Aug 12 | Merged | #3 | 0 | Retain for now | Same. |
| `feature/02-activity-domain-model` / origin | Aug 12 | Merged | #4 | 0 | Retain for now | Same. |
| `feature/03-developer-event-v2` / origin | Aug 12 | Merged | #5 | 0 | Retain for now | Same. |
| `fix/fork-sparkle-release-feed` / origin | Aug 12 | Merged | #6 | 0 | Retain for now | Holds fork-specific update history. |
| `feature/04-agent-aware-timing` / origin | Aug 12 | Merged | #7 | 0 | Retain for now | Historical feature tip. |
| `agent/roadmap-architecture-ci` / origin | Aug 12 | Merged | #8 | 0 | Retain for now | Historical documentation tip. |
| `feature/05-codex-lifecycle` / origin | Aug 12 | Merged | #9 | 0 | Retain for now | Historical feature tip. |
| local `feature/06-claude-lifecycle` | Aug 12 | Merged; 12 commits behind its origin ref | #10/#13 lineage | 0 | Keep; optionally fast-forward later | Local tip has no unique work, but no cleanup was authorized. |
| `origin/feature/06-claude-lifecycle` | Aug 13 | Merged | #10 and #13 | 0 | Retain for now | Aggregated stacked-branch lineage. |
| `feature/07-opencode-lifecycle` / origin | Aug 12 | Merged through stacked branch | #11/#13 | 0 | Retain for now | Historical stacked feature tip. |
| `feature/08-git-workspace-discovery` / origin | Aug 13 | Merged through stacked branch | #12/#13 | 0 | Retain for now | Historical stacked feature tip. |
| `feature/09-local-task-discovery` / origin | Aug 13 | Merged | #14 | 0 | Retain for now | Historical feature tip. |
| `feature/10-concurrent-activity-ui` / origin | Aug 13 | Merged | #15 | 0 | Retain for now | Same. |
| `feature/11-activity-classification` / origin | Aug 13 | Merged | #16 | 0 | Retain for now | Same. |
| `feature/12-pricing-catalog` / origin | Aug 13 | Merged | #17 | 0 | Retain for now | Same. |
| `feature/13-codex-usage` / origin | Aug 13 | Merged | #18 | 0 | Retain for now | Same. |
| `feature/14-claude-usage` / origin | Aug 13 | Merged | #19 | 0 | Retain for now | Same. |
| `feature/15-opencode-usage` / origin | Aug 13 | Merged | #20 | 0 | Retain for now | Same. |
| `feature/16-usage-attribution` / origin | Aug 13 | Merged | #21 | 0 | Retain for now | Same. |
| `feature/17-usage-insights` / origin | Aug 13 | Merged | #22 | 0 | Retain for now | Same. |
| `feature/18-release-hardening` / origin | Aug 13 | Commit not ancestor, but patch-equivalent | #23 | 1 syntactic, 0 semantic | Keep/review | Unique commit `2a32588` has the same stable patch-id as merged `5bb57cb`; current content differs only in roadmap status, but branch is not literally merged. |
| `docs/complete-release-hardening-guidance` / origin | Aug 13 | Merged | #24 | 0 | Retain for now | Most recent merged documentation branch. |

The deleted remote `ci/verify-actions` branch belonged to closed unmerged PR #2;
it was already absent before this audit. This audit deleted nothing.

### Upstream remote branches

Every listed upstream side branch is an ancestor of `upstream/main` and has zero
unique commits relative to that remote default. These refs are controlled by the
upstream owner; no action should be taken from the fork audit.

| Branch | Last activity | Merge status / PR | Unique vs `upstream/main` | Recommended action |
| --- | --- | --- | ---: | --- |
| `upstream/main` | Aug 13 | Default/current | 0 | Keep |
| `upstream/codex/v0.1-session-foundation` | Aug 9 | Merged, upstream #1 | 0 | Upstream owner decides |
| `upstream/codex/v0.2-git-context` | Aug 9 | Merged, #2 | 0 | Upstream owner decides |
| `upstream/codex/v0.3-complete-local-experience` | Aug 9 | Merged, #3 | 0 | Upstream owner decides |
| `upstream/codex/v0.4-macos-distribution` | Aug 10 | Merged, #4 | 0 | Upstream owner decides |
| `upstream/codex/v0.4.1-menu-bar-reliability` | Aug 10 | Merged, #5 | 0 | Upstream owner decides |
| `upstream/agent/automate-github-releases` | Aug 10 | Merged, #6 | 0 | Upstream owner decides |
| `upstream/agent/sparkle-updates` | Aug 10 | Merged, #7 | 0 | Upstream owner decides |
| `upstream/agent/sparkle-updates-copy` | Aug 10 | Ancestor; no distinct PR found | 0 | Upstream owner decides |
| `upstream/agent/v0.4.3-sparkle-validation` | Aug 10 | Merged, #8 | 0 | Upstream owner decides |
| `upstream/agent/improve-project-documentation` | Aug 10 | Merged, #9 | 0 | Upstream owner decides |
| `upstream/agent/add-readme-badges` | Aug 10 | Merged, #10 | 0 | Upstream owner decides |
| `upstream/codex/v0.5-github-context` | Aug 10 | Merged, #11 | 0 | Upstream owner decides |
| `upstream/codex/fix-local-bundle-signing` | Aug 10 | Merged, #12 | 0 | Upstream owner decides |
| `upstream/codex/v0.5.1-quit-action` | Aug 11 | Merged, #13 | 0 | Upstream owner decides |
| `upstream/codex/v0.6-developer-integrations` | Aug 11 | Merged, #14 | 0 | Upstream owner decides |
| `upstream/codex/v0.7-session-intelligence` | Aug 12 | Merged, #16 | 0 | Upstream owner decides |
| `upstream/codex/v0.8-session-automation` | Aug 13 | Merged, #18 | 0 | Keep as reconciliation source; upstream owner decides cleanup |

### Tag and release hygiene

Tags `v0.4.0` through `v0.7.0` are present locally. The fork's annotated
`v0.8.0` and upstream's annotated `v0.8.0` have different objects and peeled
commits, causing the observed fetch rejection. Do not force-update the tag.
Before another fork release, choose a version greater than `0.8.0`, update
`Info.plist`, run a safe preflight, and tag only a commit contained in protected
fork `main`.

## Product and Feature Opportunities

### Near-term improvements

- Integration/storage health panel: show state size, retained sample/run counts,
  last successful read, bounded warnings, and an explicit retention action.
- Share-safe export: keep full recovery backup, but offer a separate redacted
  portable export with a preview of included categories.
- Session discard recovery: confirmation plus short undo or “Recently discarded”
  recovery fits the journal identity and prevents accidental loss.
- Release readiness view/check command: aggregate version/tag, tests, signing
  environment, appcast, and manual checklist without receiving production
  secrets on arbitrary refs.

### Larger feature ideas

- Carefully port upstream session presets, frontmost-application automation,
  and local `codepulsectl` control after a feature-by-feature security and data
  migration review. This fits CodePulse, but the two v0.8 lines must not be
  wholesale-merged.
- Configurable retention/compaction with transparent raw-versus-aggregate
  periods and export-before-delete. High product value and also risk reduction.
- Developer ID signing and notarization for first-install trust. High public
  distribution value but requires Apple-account authority and a protected
  signing design.
- Import/restore with preview, version validation, size limits, and non-destructive
  merge/replace choices. Useful only after a safe backup schema is defined.

### Alternative directions

- Treat the fork as an “agent-aware CodePulse” distribution while upstream
  remains automation-oriented, with explicit names/version channels and small
  upstream contributions. This minimizes merge risk but increases maintenance.
- Converge into one product by selecting feature slices and a common data model,
  not by reconciling commit graphs. Higher long-term leverage, higher short-term
  coordination cost.

### Experimental ideas

- Budget/threshold notifications based only on validated retained data and
  signed price provenance; never imply provider balance or billed total.
- Local-only rules that summarize old usage into daily/project aggregates while
  keeping a user-selected raw retention window.
- Optional signed catalog distribution independent of app releases, once the
  dormant refresher has response/status/size hardening and an operational owner.

### Ideas not recommended now

- Prompt/transcript ingestion or “AI productivity scoring”: conflicts with the
  content-free privacy boundary and offers weakly grounded value.
- Raw cross-device cloud sync: creates an account/security/privacy platform far
  beyond the current local-first identity.
- Windows/Linux/mobile ports: core UX and APIs are deeply macOS-specific; fix and
  validate the native product first.
- Provider-balance scraping or unpublished effort multipliers: unstable,
  misleading, and explicitly rejected by current provenance principles.

## Recommended Priorities

1. **SEC-001/SEC-002:** quarantine the production Sparkle key from preflight and
   eliminate workflow-expression injection before anyone dispatches it.
2. **SEC-003:** ensure selected Git repositories cannot execute configured
   programs during capture.
3. **PRIV-001/PRIV-002:** make backup disclosure and integration deletion true
   for legacy data.
4. **BUG-001/BUG-002:** restore hard storage/arithmetic bounds and add regression
   tests.
5. **BUG-003/BUG-004:** bind lifecycle and usage events to workspace identity.
6. **PERF-001–PERF-004:** define one bounded-resource/retention policy and measure
   its effect.
7. Protect `main` and release tags; enable vulnerability reporting/alerts; repair
   public metadata and contribution routing.
8. Resolve the fork/upstream versioning strategy before selecting automation
   features or publishing another release.
9. Consolidate current documentation and add development/architecture guides.
10. Only after stabilization, plan signing/notarization and the next product
    increment.

## Limitations

- GitHub Projects v2 contents were inaccessible because the authenticated token
  lacks `read:project`; social preview and some UI-only repository settings were
  not exposed by the API.
- Vulnerability alerts and Dependabot security updates are disabled, so an
  authoritative dependency-CVE inventory was not available. The audit checked
  current direct version/release state but does not claim Sparkle is CVE-free.
- No production secrets, secret values, or collaborator list were inspected.
- No destructive Git/GitHub action, branch deletion, issue/PR change, ruleset
  mutation, secret change, release, publication, or push was performed.
- Runtime UI interaction, VoiceOver, keyboard traversal, contrast measurement,
  sleep/wake behavior, clean-machine install, live third-party integrations,
  production signing, and hostile exploit PoCs were not executed. Code review,
  deterministic screenshots, tests, and Thread Sanitizer provide partial—not
  complete—evidence for those surfaces.
- `ANALYSIS.md` is a dated audit snapshot. Current code, Git, GitHub state, and
  approved canonical documents supersede it as changes land.
