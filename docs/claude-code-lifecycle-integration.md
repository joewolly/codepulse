# Claude Code lifecycle integration

CodePulse can optionally track the timing of local Claude Code sessions. Enable
**Claude Code** under **Settings → Integrations**. CodePulse adds only its
marked hook groups to the supported user-level configuration at
`~/.claude/settings.json`; it never edits project, local-project, or managed
Claude settings.

## What is recorded

The local helper accepts only the documented hook metadata needed for timing:
the hook name, session or subagent identity, working directory, event time,
optional model and effort, and an indication that a transcript path was
present. It records neither the path nor transcript contents. It also never
stores prompts, tool input or output, commands, responses, permission details,
or raw hook payloads. External identities are converted to installation-salted
fingerprints before they enter the activity graph.

`SessionStart`, `UserPromptSubmit`, `PostToolUse`, `PermissionRequest`, `Stop`,
and `SessionEnd` drive the shared lifecycle reducer. `SubagentStart` and
`SubagentStop` create and advance separate child runs without ending or
replacing their parent. Waiting intervals and expired review grace do not count
as active agent runtime.

## Local Remote Control and cloud-only limits

Tracking requires a Claude Code process running locally on this Mac and its
configured local hook. That includes a local Claude Code session controlled via
Remote Control. Work performed only in a cloud service, or on another machine
without this helper and local hook, is intentionally not tracked.

## Health, repair, and removal

The integration row reports whether the CodePulse-marked hook groups are
present. Use **Enable / Repair integration** to recreate only those groups; it
first removes prior groups carrying the CodePulse marker, preserving unrelated
user hooks and settings. Use **Disable integration** to remove exactly those
marked groups. If you prefer to revert manually, remove only hook groups whose
handler `statusMessage` is `CodePulse Claude Code lifecycle integration
(managed)` from `~/.claude/settings.json`.

## Local smoke checklist

1. Enable Claude Code integration and verify the Settings row reports it as
   enabled.
2. Start a Claude Code session in a configured CodePulse workspace, including a
   locally running Remote Control session if available.
3. Start a subagent, perform activity in both parent and child, then end the
   parent before the child. Verify they remain separate runs.
4. Stop a run and let the review grace expire. Verify the resulting waiting
   interval is excluded from active runtime.
5. Disable the integration and verify an unrelated Claude user hook remains.
