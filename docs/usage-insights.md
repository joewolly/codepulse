# Usage Insights and local exports

Usage Insights is a local, derived view over the privacy-safe activity graph
and token samples already stored by CodePulse. It does not create an analytics
database, upload usage data, or read a usage source unless that integration's
separate **Track token usage** setting is enabled.

## Measures and period selection

The Insights period and project picker apply to usage totals as well as the
existing session insights. A project selection matches a workspace linked to
that CodePulse project; automatic and unassigned work remains visible through
the **No Project** filter rather than being assigned speculatively.

Usage Insights always keeps these measures distinct:

| Measure | Definition |
|---|---|
| Manual active | Active intervals on manual runs only. |
| Agent runtime | Sum of active agent intervals; simultaneous agents may overlap. |
| Combined wall-active | Union of eligible manual/agent active intervals and agent review grace; overlaps are counted once. |
| Agent waiting | Agent intervals marked waiting; excluded from active measures. |
| Tokens | The source-provided input, output, cache, cache-write, and reasoning counters that are available for a sample. |

Project, domain, work type, integration, provider, and model breakdowns retain
**Unassigned** or **Unknown** whenever a source record cannot be safely linked
to a workspace or activity.

## Cost labels

Cost cards and exports preserve the source representation. They are never
combined into a single figure that implies a bill or credit balance.

- **Provider-reported cost** is a value included in supported local metadata.
- **API-equivalent estimate** and **Codex-credit estimate** are calculations
  using immutable pricing-catalog provenance.
- Missing cost data means token totals can still be correct; Insights reports
  that prices are unavailable instead of showing zero.

## Details and data quality

The details disclosure shows timestamp, workspace/activity labels when they
are already safely attributable, integration, provider, model, token total,
and available costs. It uses an ordinal local row label internally and never
shows raw session fingerprints, paths, UUIDs, source-record IDs, prompts, or
transcript content. Claude aggregate samples explicitly state that child usage
is included once, so a parent roll-up is not added to children a second time.

Insights also makes the source state visible. Timing remains available when no
usage reader is enabled. A disabled reader, missing OpenCode plugin,
unsupported OpenCode plugin event version, malformed event, or unavailable
price data affects only the relevant usage/cost presentation; it never changes
recorded timing.

## Export

Choose **Export** in Usage Insights to write a local JSON or CSV file for the
currently selected period and project filter. JSON exports have:

- `format: "codepulse-usage-export"` and schema `version: 1`;
- export timestamp and selected range start/end;
- explicitly selected context fields; and
- rows containing token counters plus labeled cost representation and
  calculation provenance when available.

CSV repeats a row when one sample has multiple cost representations so each
amount keeps its own label, currency, and pricing provenance. Decimal values
are exported using a stable machine-readable representation, independent of
the Mac's display locale.

Workspace and activity labels are opt-in in the export menu. Provider, model,
effort, and service mode can also be selected. Paths, UUIDs, source/session
fingerprints, raw provider records, prompts, transcripts, commands, source
code, and credentials are never exportable by this feature.

Usage exports are not support bundles or backups. For a shareable,
aggregate-only diagnostic file, use **Settings → Export Redacted Support
Bundle…**; it contains no usage rows, paths, identifiers, prompts, transcripts,
or freeform session text. See
[`../PRIVACY.md`](../PRIVACY.md#integration-deletion-and-support-bundles).
