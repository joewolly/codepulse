# Codex local lifecycle tracking

CodePulse can optionally track local Codex lifecycle timing. Enable it in
**Settings → Integrations → Codex**. CodePulse writes only its marked command
hooks in `~/.codex/hooks.json`, enables the `hooks` feature only when it is not
already configured, and removes only those marked entries when disabled.

Codex must be installed locally and its hooks must not be explicitly disabled.
If Codex reports that a hook needs trust review, review it with `/hooks` before
expecting it to run. The installed helper is intentionally fail-soft: a helper
failure cannot block or alter Codex.

## What CodePulse receives

The local hook adapter maps these Codex events to CodePulse lifecycle metadata:

| Codex hook | CodePulse lifecycle |
|---|---|
| `SessionStart` | session started / active |
| `UserPromptSubmit`, `PostToolUse` | activity observed / active |
| `PermissionRequest` | awaiting permission / waiting |
| `Stop` | review grace |
| `SessionEnd` | ended |

The adapter reads only session identity, working directory, event name,
timestamp, optional model, and optional service mode. It never stores prompts,
responses, transcripts, source files, commands, tool arguments/results, hook
output, or a permission decision. Persisted agent runs use an
installation-scoped fingerprint rather than the external Codex session ID.

## Optional token usage

Lifecycle timing does not enable token usage tracking. **Track Codex token
usage** is a second, off-by-default consent in Settings. Once enabled,
CodePulse reads the minimum token-counter and model metadata from current
`~/.codex/sessions` JSONL files, stores only salted identifiers and aggregated
deltas, and stops reading immediately when disabled. It never reads transcript
content or archived Codex sessions. See
[`codex-usage-tracking.md`](codex-usage-tracking.md) for the exact fields,
checkpointing, attribution, estimate labels, and retention behavior.

## Limits and recovery

CodePulse correlates a local Codex run only when its working directory is
within a workspace already known to CodePulse. Git and non-Git automatic
workspace discovery is planned separately. Codex cloud-only sessions without a
local process or hook are not tracked.

Use **Disable integration** to remove CodePulse-managed hooks. Existing timing
history remains local until deleted through CodePulse's data controls.
