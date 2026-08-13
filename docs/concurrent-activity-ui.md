# Concurrent activity display and timing

CodePulse can display multiple current manual and agent runs at once in the
menu-bar **Active Now** view. This is a local read projection over the activity
graph; it does not create a second timer store or modify incoming lifecycle
events.

## What Active Now shows

Each current run identifies its workspace and activity, plus its integration
and model when that metadata is available. The view labels a run as **Active**,
**Review grace**, or **Waiting** and shows its elapsed active duration.

Review grace includes a countdown. Waiting is visually explicit and contributes
zero active time. A **Finish Manual** action appears only for the currently
open manual run created by CodePulse itself. Agent runs, including Codex,
Claude Code, and OpenCode sessions, never receive a stop control.

Selecting **Details** opens the activity's interval timeline. Timeline rows
contain only a display-safe tool/model label, state, and timestamp. They omit
raw event bodies, event reasons, session fingerprints, paths, prompts, and
transcripts.

## Concurrent timing rules

CodePulse keeps these measures distinct:

- **Personal wall-active** is the union of manual active intervals only.
- **Agent runtime** is the sum of agent active intervals; simultaneous agents
  are intentionally allowed to overlap in this measure.
- **Agent waiting** is summed separately and is never active time.
- **All-work wall-active** is the union of manual active intervals and eligible
  agent active/review-grace intervals. It de-duplicates overlaps.

For example, two agents active for the same 30 minutes have 60 minutes of
agent runtime but 30 minutes of all-work wall-active time. CodePulse does not
present the summed agent runtime as personal time.

## Privacy boundary

This view uses the existing local activity graph only. It does not inspect
directory contents, raw hook payloads, prompts, responses, transcripts,
terminal commands, or tool input/output. See
[`agent-aware-tracking-roadmap.md`](agent-aware-tracking-roadmap.md) and
[`../PRIVACY.md`](../PRIVACY.md) for the governing privacy rules.
