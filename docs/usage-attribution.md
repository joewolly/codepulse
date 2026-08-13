# Usage attribution and reconciliation

Feature 16 turns existing normalized usage samples into local, auditable
analytics. It does not enable a usage adapter, read any additional source, or
persist a second analytics database.

## Conservative attribution

Each sample is joined to a workspace and activity only when its stored run and
workspace links are mutually consistent with the activity graph. A sample that
has a workspace link but no unambiguous run remains workspace-attributed but
activity-unassigned. Missing, delayed, ambiguous, or contradictory links remain
in an explicit **Unassigned** bucket. Missing model, provider, effort, or
service-mode metadata remains **Unknown**; CodePulse never fills it by guesswork.

The available dimensions are workspace, activity, work type, domain,
integration, provider, model, effort, and service mode. Work type and domain
come from the matched activity's effective metadata-only classification. The
current activity model stores one effective value per dimension rather than raw
prompt-derived classifications.

## Windows and measures

The service supports local calendar day, week, month, and an explicit custom
`DateInterval`. Usage belongs to a window when its observed timestamp is inside
the half-open interval `[start, end)`.

- Token totals preserve separate input, output, cached-input, cache-write, and
  reasoning counters, plus their sum.
- Provider-reported cost, API-equivalent estimates, and Codex-credit estimates
  are aggregated only by matching representation and currency.
- Manual active time sums manual active intervals.
- Agent runtime sums agent active intervals, so parallel agents remain visible.
- Combined wall-active time is the union of manual active, agent active, and
  agent review-grace intervals, so overlap is not counted twice.
- Agent waiting sums agent waiting intervals and is never included in an active
  measure.

## Reconciliation and privacy

The Insights reconciliation surface traces each aggregate to an ordinal local
sample summary: workspace/activity labels, tool, provider, model, token totals,
and labeled costs. It intentionally excludes session fingerprints, raw external
IDs, source paths, prompts, transcripts, and raw event content. It shows a
bounded first 25 rows; the underlying report remains available to the local UI
without changing persisted source data.

## Performance

Each report builds in-memory dictionaries keyed by existing workspace, activity,
and run UUIDs, then makes one pass over the window's usage samples. There is no
disk scan or persisted analytics index. The test suite exercises a 2,000-sample
history to confirm that every sample is preserved in its dimensional totals.

For the user-facing selected-period presentation, data-quality states, and
local CSV/JSON export schema, see [Usage Insights and local
exports](usage-insights.md).
