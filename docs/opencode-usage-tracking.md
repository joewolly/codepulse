# OpenCode token usage tracking

CodePulse can optionally track OpenCode token usage. This is separate from
OpenCode lifecycle timing and is **off by default**. Enable **Settings → Track
OpenCode token usage** only if you want this local metadata handoff. Turning it
off immediately stops the helper from accepting new usage handoffs and stops
the app from processing its usage inbox; existing privacy-safe history remains
local until CodePulse data is deleted.

## Source and consent boundary

The only source is the CodePulse-owned global OpenCode plugin at
`~/.config/opencode/plugins/codepulse-integration.js`. For a documented
`message.updated` event, it accepts only an assistant message with numeric usage
data and emits a new, bounded record to the local CodePulse integration helper.
The helper first checks the persisted OpenCode usage-consent Boolean. With no
consent, it does not decode, validate, or write an inbox record.

There is intentionally no OpenCode database, transcript, project-config, or
filesystem fallback. This keeps source access event-based and means a missing,
changed, or unsupported plugin cannot cause CodePulse to inspect stored OpenCode
data.

## Allowlisted metadata

The plugin record can contain only:

- OpenCode session and message identity, working directory, and timestamp;
- model, provider, and service-mode labels;
- numeric input, output, cache-read, cache-write, and reasoning token counters;
- an available provider-reported USD cost; and
- the CodePulse usage-plugin version.

It omits message text, prompts, responses, tool calls/results, command data,
file data, transcripts, credentials, and all other message fields. The helper
rejects malformed records, unsafe paths, oversized data, negative counters, and
records without a positive token count before storing an atomic handoff. After
processing, CodePulse removes the handoff.

The CodePulse-owned inbox is bounded to 2,048 handoff files or 16 MiB. A new
handoff that would exceed either limit is rejected before it is written, so a
stalled or misbehaving local plugin cannot grow the inbox without limit. A
rejected usage handoff affects usage metadata only; lifecycle timing continues
normally.

## Normalization and attribution

CodePulse converts the OpenCode session ID to an installation-salted fingerprint
before it is stored. It preserves normalized model and provider labels, service
mode, token counters, and provider-reported cost separately. A usage sample is
attached only when exactly one matching OpenCode lifecycle run covers its
timestamp; otherwise it remains unassigned rather than guessed into a project.
It keeps a bounded list of salted message fingerprints so repeated delivery of
the same completed `message.updated` record is removed without double-counting.

## Cost labels

Provider-reported USD cost stays distinct from an API-equivalent estimate. When
the signed local pricing catalog recognizes the model, CodePulse stores an
estimate with immutable catalog provenance; an unrecognized model or missing
rate is **Unpriced**. A provider-reported value is not recomputed, and neither
label is a bill, account balance, or subscription charge. See
[`pricing-catalog.md`](pricing-catalog.md) for catalog trust and label rules.

## Adapter health and recovery

When usage tracking is enabled, the adapter reports `waitingForPlugin` until it
receives a record and `healthy` after a supported one. A malformed handoff or a
future plugin version is reported as usage-adapter health only. It is removed
without changing activity timing, lifecycle events, or manual sessions. Repair
the managed OpenCode integration and restart OpenCode after plugin changes; the
next supported record restores the adapter to `healthy`.

## Retention and deletion

Turning off the adapter stops new handoffs but preserves existing privacy-safe
samples. To remove CodePulse-held OpenCode usage samples and inbox processing
state, use **Settings → Integration Data**. It also removes OpenCode agent runs
and attributable diagnostics, but never alters OpenCode data, user
configuration, or previously exported files. See
[`../PRIVACY.md`](../PRIVACY.md#integration-deletion-and-support-bundles).
