# 1. Agent-aware activity and usage tracking decisions

- Status: accepted
- Date: 2026-08-12
- Full plan: [`docs/agent-aware-tracking-roadmap.md`](../agent-aware-tracking-roadmap.md)

## Context

CodePulse currently records one manually started stopwatch. Work performed with
coding agents is invisible to it, and a naive integration would either miss the
work entirely or count long idle waits as active time.

The roadmap linked above turns CodePulse into an optional, privacy-preserving
local recorder for agent work across Codex, Claude Code, and OpenCode. This
record captures the choices that later features may not renegotiate on their
own; everything else in the roadmap is implementation detail that can change
with evidence.

## Decision

### Privacy boundary

1. CodePulse reads only user-authorized, local integration data. It never
   uploads prompts, source code, transcript text, file contents, terminal
   commands, or raw session logs.
2. Prompt text is never persisted. Optional enhanced classification processes
   it in memory, locally, only after explicit opt-in, and discards it before
   event persistence.
3. Persistence is limited to the metadata needed for identity, timing,
   classification, token aggregation, and diagnostics.
4. External session IDs are stored as a stable salted digest wherever the
   integration allows it. A reversible identifier is retained only where
   continuation requires it, protected by platform storage controls.
5. Activity is determined from agent lifecycle signals alone. No
   keyboard/mouse surveillance, screen capture, cloud relay, or terminal
   polling is introduced.
6. Every integration can be disabled, its token reader disabled, and its
   stored data deleted. Exports cover only the metadata named on the privacy
   screen.

### Architecture

7. Timing and usage accounting are separate pipelines. A failed parser or a
   disabled usage permission must never stop timing from working.
8. Token tracking is a separate, off-by-default consent toggle per
   integration. Activity tracking never requires it.
9. All integrations feed one versioned, normalized developer-event schema, and
   one shared run-state reducer derives intervals from it. Integrations do not
   compute their own time.
10. Runs are never collapsed merely because they share a workspace. Manual
    time, agent runtime, and combined wall-active time stay distinct measures,
    and summed concurrency is never presented as personal time.
11. Waiting time is visible but excluded from active totals. Review grace after
    an agent stops defaults to three minutes.
12. Claude subagents are shown individually with a parent roll-up that counts
    child usage exactly once.

### Cost representation

13. Prices come from a signed, versioned manifest with a bundled offline
    fallback. Historical calculations retain the catalog version used, so past
    figures do not change when prices do.
14. Reported cost, API-equivalent estimate, Codex-credit estimate,
    subscription/unpriced state, and calculation provenance are all preserved.
    The user picks which one displays primarily per integration.
15. The UI never labels an estimate as an actual charge, and a Codex-credit
    estimate is never presented as remaining or billed credits.

### Scope

16. A tracked session must have a local process, hook, or local usage record.
    Cloud-only runs are out of scope for this release.
17. Budgets, threshold alerts, and enforcement are deferred until the Usage
    Insights release has been validated.

## Consequences

- Features can ship independently: timing works before any usage adapter
  exists, and a broken adapter degrades usage only.
- Some questions stay unanswerable by design. Cloud-only sessions produce no
  record, and unmatched usage samples stay in an explicit unassigned bucket
  rather than being guessed into a project.
- Cost figures carry more labels than a single number would, because a
  subscription's actual charge is genuinely unknown to the app.
- Persistence must be versioned and migration-safe before the activity model is
  replaced, which is why that work is Feature 01.

## Development workflow

Work lands in the contributor's fork first, one `feature/NN-name` branch and PR
per roadmap feature. Upstream contribution is optional and happens later, as
fresh clean branches cut from then-current `upstream/main` containing only the
changes the upstream owner wants.
