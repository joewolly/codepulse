# CodePulse v1.0 Milestone 3 audit

This is the pre-production-change audit for Milestone 3. It records concrete
findings from the `codex/v1.0-stability-hardening` M2 baseline and the initial
measurement harness. It is intentionally limited to M3 accessibility, UX, and
performance evidence; release-facing v1.0 work remains deferred.

## Baseline

- Branch: `codex/v1.0-stability-hardening`
- Starting M2 HEAD: `f55a5880fa12bd42a65dcea0f1a98ee59ca95a5b`
- Version/build: `0.9.0 / 900`
- Worktree exception: `?? Package.resolved`
- Baseline tests: **237 tests executed, 1 environment-dependent OpenCode installation test skipped, and 0 failures.**
- The M2 commit is an ancestor of the starting HEAD.

## Findings before fixes

### Accessibility and UX

1. The AppKit menu-bar status item announces phase, elapsed time, and
   automation, but not the selected project or session type. The SwiftUI
   menu-bar label has the same omission.
2. Critical lifecycle persistence failures are shown as an inline warning in
   the menu-bar popover, but there is no user-dismiss action. The store also
   exposes the raw localized persistence error as primary UI copy instead of a
   stable explanation that the prior state is unchanged and retry is possible.
3. History row accessibility combines project/type/duration/goal/outcome,
   branch, and developer-tool data, but omits the session time range and
   GitHub repository/pull-request context.
4. Automation rows distinguish disabled, archived, and generic attention
   states, but do not explain missing presets, missing projects, or relink
   requirements. The global automation-off state is not explained alongside
   otherwise enabled rules.
5. Long project, preset, and automation names are displayed without a
   consistent row truncation/help strategy. Session detail content has a
   bounded-height container without a scroll view, so valid long goals and
   outcomes can make important controls unreachable.
6. The Insights chart accessibility value enumerates every bucket. That is
   useful for a small chart but becomes an excessive text mirror for long
   all-time ranges; a concise title/summary is more usable.

### Performance

1. `SessionStore.now` is published on a one-second timer. History computes
   filtered, sorted, and grouped sessions from `store.now` in its body, and
   rebuilds project options from all projects/history during the same view
   invalidation.
2. Insights computes `InsightsCalculator.summary` and historical project
   options in the view body. `InsightsCalculator` scans all completed sessions
   for the all-time interval, so an idle one-second refresh can repeat large
   work even when historical inputs have not changed.
3. No database/index replacement or broad concurrency change is justified by
   the audit. The targeted candidate is to refresh expensive view-derived
   snapshots only when historical state, filters, or the relevant calendar
   boundary changes.

## Measurement policy

The large-state generator uses isolated in-memory state and deterministic
valid timelines. It covers 10,000 and 50,000 completed sessions with mixtures
of projects/No Project, session types, pauses, Git, GitHub, and developer-tool
metadata. Benchmark cases are compiled only with
`-DCODEPULSE_BENCHMARKS`, so the canonical `swift test --configuration debug`
count remains separate from benchmark iterations.

## Initial large-state measurements

The initial isolated benchmark was run with
`swift test --configuration debug -Xswiftc -DCODEPULSE_BENCHMARKS --filter LargeStateBenchmarkTests`.
Times are milliseconds on the local Apple Silicon test machine; they are
baselines for the current canonical operations, not acceptance thresholds.

| Sessions | JSON bytes | Encode | Decode | Store init | History query | History grouping | Insights | CSV | Markdown |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 7,763,268 | 68.63 | 70.71 | 0.28 | 68.83 | 29.53 | 45.05 | 954.54 | 35.63 |
| 50,000 | 38,867,590 | 336.87 | 353.99 | 0.18 | 343.14 | 164.74 | 220.76 | 4,828.89 | 35.83 |

The targeted performance change is view-level recomputation scope: History
and Insights now retain derived snapshots and refresh them on state/filter or
calendar-bucket changes rather than on every published elapsed-time tick. The
canonical query, grouping, calculator, and exporter algorithms remain
single-sourced and are still measured by the isolated harness above.
