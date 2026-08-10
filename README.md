# CodePulse

CodePulse is a native macOS menu-bar coding-session timer, coding journal, and
local development insights tool. It is intentionally offline and lightweight:
projects, goals, outcomes, and session types are optional, and there are no
cloud, account, telemetry, remote-service, or activity-monitoring features.

## Build and run

CodePulse is a Swift Package Manager macOS application targeting macOS 13 or
later. On macOS with Xcode or the Swift toolchain installed, run:

    ./script/build_and_run.sh

The script builds the package, stages a real app bundle, and launches it
through the macOS open command. Use ./script/build_and_run.sh --verify to
confirm the process starts.

For unsigned native macOS distribution, use `./script/package_release.sh`.
The versioned DMG and checksum are written under `dist/release/`; see
[`docs/releasing.md`](docs/releasing.md) for the release and first-launch notes.

## Architecture

The session lifecycle is owned by SessionStore, which is the single
authoritative source for the idle/running/paused/finishing state. ActiveSession
and CompletedSession persist timestamps and pause intervals; active duration is
calculated from those dates rather than an incrementing counter. Local JSON
state lives under the user's Application Support directory.

Completed sessions snapshot the project display name and session type. History
supports native search, composable project/date/type/Git filters, day summaries,
and safe editing of journal fields. Editing a session's start shifts the entire
timeline, including pause intervals, so active duration remains stable.
Historical Git metadata is read-only and is never recaptured during edits.

Projects can be renamed, relinked, revealed in Finder, or removed from
CodePulse without deleting the user's folder. Saved history keeps its project
snapshot after a project is removed.

When a project folder is inside a local Git working tree, a session also
snapshots the repository root, branch, and HEAD at start and finish. History
stores the captured metadata, so it remains useful if the repository later
moves or disappears. Git is best-effort: non-Git projects and Git command
failures do not affect timing or saving. Committed changes are measured from
the two captured revisions. Uncommitted files are included only when their
paths were clean at session start; pre-existing dirty paths are intentionally
excluded to avoid claiming unrelated work. Binary files contribute to the file
count but not inserted/deleted line totals.

Today's total and Insights use the user's local Calendar and subtract pause
intervals over exact date intervals, including sessions that cross midnight or
week boundaries. Insights shows current/previous period totals, the absolute
comparison, time by project, time by session type, and a native Swift Charts
daily activity view. The active session contributes to the current period.

The Workflow settings include an optional ⌥⌘T shortcut that opens History and a
versioned JSON backup export. Backup files use the codepulse-backup format
marker and version 1, and include local state only. v0.3 intentionally provides
export without restore to keep replacement of local data non-destructive.

## Tests

Tests live in Tests/CodePulseTests and use injected clocks and calendars, so
pause/resume, relaunch recovery, wall-clock jumps, day/week boundaries,
history queries, edit semantics, Git preservation, Insights aggregation, and
backup validation are deterministic without sleeping.
