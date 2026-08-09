# CodePulse

CodePulse is a native macOS menu-bar coding-session timer and local coding
journal. It is intentionally offline and lightweight: projects and goals are
optional, and no Git, cloud, account, telemetry, or activity-monitoring
features are included in this foundation.

## Build and run

CodePulse is a Swift Package Manager macOS application targeting macOS 13 or
later. On macOS with Xcode or the Swift toolchain installed, run:

    ./script/build_and_run.sh

The script builds the package, stages a real app bundle, and launches it
through the macOS open command. Use ./script/build_and_run.sh --verify to
confirm the process starts.

## Architecture

The session lifecycle is owned by SessionStore, which is the single
authoritative source for the idle/running/paused/finishing state. ActiveSession
and CompletedSession persist timestamps and pause intervals; active duration is
calculated from those dates rather than an incrementing counter. Local JSON
state lives under the user's Application Support directory.

Completed sessions snapshot the project display name. This keeps history
meaningful if a project is renamed or removed later, while the optional project
record retains its folder path and security-scoped bookmark for future Git-aware
work.

Today's total uses the user's local Calendar and subtracts pause intervals over
the exact day interval, including sessions that cross midnight. History is
grouped by the local calendar day on which a session started.

## Tests

Core timer tests live in Tests/CodePulseTests and use an injected clock, so
pause/resume, relaunch recovery, wall-clock jumps, and day boundaries are
deterministic without sleeping.
