# Codex token usage tracking

CodePulse can optionally track local Codex token usage. This is separate from
Codex lifecycle timing and is **off by default**. Enable it through **Settings
→ Track Codex token usage** only if you want CodePulse to read the limited local
metadata described here. Turning it off immediately stops enumeration and file
reads; existing local, privacy-safe history remains until CodePulse data is
deleted.

## What the reader accesses

After consent, CodePulse recursively enumerates only current
`~/.codex/sessions` regular `.jsonl` files. It does not read archived sessions,
symlinks, project files, terminal history, or other Codex configuration.

The reader accepts only these JSONL record shapes:

- `session_meta` for a session identifier, which is salted before it is stored;
- `turn_context` for the model label; and
- `event_msg` records whose type is `token_count`, for cumulative token totals.

It skips every other record before processing it. CodePulse never persists a
raw session ID, path, JSONL record, prompt, response, transcript, command,
tool argument/result, reasoning, credential, or API key.

## Incremental and resilient accounting

CodePulse stores only a salted file fingerprint, salted session fingerprint,
byte offset, file identity, model label, and cumulative counters. On the next
scan it reads newly completed lines, subtracts the prior cumulative totals, and
records only a positive delta. This prevents repeated `token_count` snapshots
from being counted again. Truncation, replacement, and rotation reset the read
offset safely; malformed and incomplete lines are ignored.

The reader bounds each scan to two megabytes per file and ignores lines longer
than 128 KB. This keeps the optional local process predictable and avoids
retaining source contents.

## Attribution and estimates

A usage sample is linked to a workspace and agent run only when exactly one
local Codex lifecycle run has the same salted session fingerprint and covers
the sample timestamp. Ambiguous, delayed, ended, or otherwise unmatched samples
remain explicitly **unassigned** rather than being guessed into a project.

For catalog-supported models, CodePulse records both an **API-equivalent
estimate** and a **Codex-credit estimate** with the signed catalog version,
effective date, source URL, and calculation timestamp. These estimates are
usage equivalents based on an official rate card; they are not account balances,
remaining credits, invoices, or actual charges. If a required rate is not
published, the sample remains unpriced for that representation.

Pricing metadata uses the signed catalog described in
[`pricing-catalog.md`](pricing-catalog.md). Usage metadata is never sent to a
CodePulse service. A separately configured pricing-catalog refresh fetches only
a public HTTPS manifest and sends no usage, session, workspace, or path data.
