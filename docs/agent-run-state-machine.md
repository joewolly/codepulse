# Agent run state machine

Feature 04 provides the shared timing reducer used by all developer-tool
adapters. It accepts only validated `DeveloperEventV2` lifecycle metadata; it
does not read prompts, transcripts, source files, commands, or raw hook bodies.
Adapters in Features 05–07 are responsible for mapping tool-specific local
signals and correlating them to a known agent run.

## States and interval materialization

| Run state | Stored interval | Counts as agent runtime | Notes |
|---|---|---:|---|
| `new` | none | No | Awaiting a lifecycle event. |
| `active` | `active` | Yes | Agent lifecycle activity. |
| `awaitingPermission` | `waiting` | No | Explicit user/input wait. |
| `reviewGrace` | `reviewGrace` | Separately visible; eligible for the configured grace | Created by a stop. |
| `waiting` | `waiting` | No | Idle or expired review grace. |
| `ended` | closes open interval | No | Terminal. |
| `orphaned` | closes open interval conservatively | No additional time | Terminal stale-run recovery. |

`agentRuntime` contains only `active` intervals. `reviewGrace` is kept
separate, and `eligibleActive` is their sum. Waiting intervals never contribute
to either value. Elapsed span remains independently available.

## Normalized event precedence

At a timestamp equal to or later than the last accepted lifecycle event, the
following events take precedence over a run's prior non-terminal state:

1. `session.ended` → `ended`
2. `permission.requested` → `awaitingPermission`
3. `session.stopped` → `reviewGrace`
4. `session.idle` → `waiting`
5. `session.started` or `activity.observed` → `active`
6. `integration.error` → no timing transition; diagnostics only

Duplicate events that would leave the run in the same state and events older
than the last accepted event are ignored. `ended` and `orphaned` are terminal;
later events do not reopen them.

## Per-integration mapping contract

| Canonical event | Codex local hook (Feature 05) | Claude Code hook (Feature 06) | OpenCode plugin (Feature 07) |
|---|---|---|---|
| `session.started` | Session start/resume | Session start | `session.created` |
| `activity.observed` | Prompt/tool lifecycle activity | Prompt/tool lifecycle activity | busy/retry status |
| `permission.requested` | Permission request | Permission request | Supported permission state, if available |
| `session.stopped` | Stop/completed | Stop/completed | Supported stop state, if available |
| `session.idle` | Explicit local idle/wait | Explicit local idle/wait | `session.idle` or idle status |
| `session.ended` | Session end | Session end | `session.deleted` |

This table is the canonical reducer contract. Feature 05 implements the Codex
mapping through local hooks: `SessionStart`, `UserPromptSubmit`,
`PostToolUse`, `PermissionRequest`, `Stop`, and `SessionEnd`. Feature 06 uses
the documented Claude Code hooks with the same lifecycle mapping plus
`SubagentStart` and `SubagentStop`; each subagent is a separate run whose
parent is represented by a salted fingerprint. Both mappers read only
whitelisted metadata and discard prompt, transcript, command, tool, and
permission-decision fields. OpenCode remains a later feature.

Codex correlation creates or resumes a run only for a matching local workspace
root. Feature 08 will add Git workspace discovery; cloud-only sessions that
have no local hook/process remain out of scope.

## Review grace and relaunch recovery

The user-configurable review grace defaults to exactly three minutes. A stop
opens a `reviewGrace` interval. Activity resumes it to `active`; permission,
idle, and end cancel it. Without a new event, the interval becomes `waiting`
at its deadline—not at a later refresh—so a four-hour pause can add at most the
configured review grace.

On refresh/relaunch, an open agent run with no lifecycle event for 15 minutes
is marked `orphaned`. Its interval closes at its last known event or grace
deadline, never at the later recovery time. This preserves auditability without
inventing active time.
