# Claude Code token usage tracking

CodePulse can optionally track local Claude Code usage. This is separate from
Claude lifecycle timing and is **off by default**. Enable **Settings → Track
Claude Code token usage** only if you want this local metadata reader. Turning
it off immediately stops file enumeration and reads; existing privacy-safe
history remains local until CodePulse data is deleted.

## Transcript metadata, not transcript content

After consent, CodePulse enumerates only regular `.jsonl` files under current
`~/.claude/projects`; it excludes symlinks, project files, settings, and other
Claude directories. Claude assistant records can place message content and
usage metadata in the same JSONL object. CodePulse parses each supported
assistant record only to extract this allowlisted metadata:

- session identity, timestamp, model, effort, and service mode;
- input, output, cache-read, and cache-write token counters; and
- a provider-reported USD cost, but only when the record supplies one.

It immediately discards message content and every unsupported field. It never
persists or exports prompts, responses, transcript text, transcript paths,
commands, tools, credentials, API keys, raw session IDs, or raw file paths.
Session, source, and per-record IDs are installation-salted before persistence.

## Incremental reads and subagents

CodePulse keeps bounded file offsets and processed-record fingerprints, so new
assistant metadata is sampled once. A file replacement or rotation can be read
safely without replaying already processed records. Malformed and incomplete
lines are ignored; each scan is capped at two MB per file and lines over 128 KB
are ignored.

Claude lifecycle hooks supply the parent/subagent relationship already stored
as salted run metadata. Usage samples attach only to one matching lifecycle run
and workspace; unmatched samples remain unassigned. Child samples stay
individually inspectable. A parent roll-up normally equals parent-exclusive
samples plus each child once. When supported parent metadata explicitly says a
sample includes child usage, the latest aggregate replaces child addition to
prevent duplicate totals.

## Cost labels

Provider-reported local cost remains distinct from an estimate. Selecting
**Included/subscription — actual charge unknown** never turns subscription use
into a bill. The bundled signed catalog currently has no Claude rate card, so a
Claude API-equivalent estimate is unavailable until a verified catalog update
contains a matching model; then the existing typed calculation preserves its
catalog source and version. See [`pricing-catalog.md`](pricing-catalog.md) for
catalog trust and estimate semantics.
