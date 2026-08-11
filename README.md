# CodePulse

[![macOS validation](https://github.com/joewolly/codepulse/actions/workflows/validation.yml/badge.svg?branch=main)](https://github.com/joewolly/codepulse/actions/workflows/validation.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
[![Sparkle 2.9.2](https://img.shields.io/badge/Sparkle-2.9.2-blue)](https://github.com/sparkle-project/Sparkle)

CodePulse is a native macOS menu-bar timer, coding journal, and local insights
tool for developers. It is lightweight and local-first: there are no accounts,
cloud sync, telemetry, product analytics, or activity monitoring. CodePulse
contacts GitHub only to check for and download authenticated app updates.

<p align="center">
  <img src="docs/images/menu-bar-session.png" alt="CodePulse menu-bar timer with a running coding session" width="420">
</p>

## What it does

- Starts, pauses, resumes, and finishes focused work sessions from the menu bar.
- Records optional projects, work types, goals, and outcomes in a searchable
  coding journal.
- Captures best-effort local Git context without changing the repository.
- Summarizes active time by day, project, and work type with native Swift Charts.
- Exports a versioned JSON backup of local CodePulse state.

## Download and install

CodePulse requires macOS 13 or later and is distributed as a Universal 2 app
for Apple silicon and Intel Macs.

Download the latest DMG from
[GitHub Releases](https://github.com/joewolly/codepulse/releases/latest), open
it, and drag CodePulse to Applications. The current build is intentionally not
Developer ID signed or notarized, so macOS may require an explicit first-launch
approval. Follow the safe first-launch instructions in
[`docs/releasing.md`](docs/releasing.md#installation-and-gatekeeper); do not
disable Gatekeeper globally.

Starting with CodePulse 0.4.2, authenticated in-app updates are provided by
Sparkle. After the initial installation, use **Settings → Check for Updates…**
or allow the automatic update check.

## Quick start

1. Click the CodePulse item in the menu bar.
2. Optionally choose a project and work type, then describe the session goal.
3. Start the session and pause or resume it as needed.
4. Finish the session, record an optional outcome, and save it to History.
5. Open History to search or edit saved sessions, or open Insights to review
   local activity.

Projects are optional. Adding a project grants CodePulse access only to the
folder you select, allowing it to read local Git metadata for that project.

## Screenshots

### History

![CodePulse History showing privacy-safe sample coding sessions](docs/images/history.png)

### Insights

![CodePulse Insights showing a weekly activity chart and project totals](docs/images/insights.png)

## Local data and privacy

CodePulse stores its state as JSON under the user's Application Support
directory. Session notes, project paths, settings, Git snapshots, and active
session state stay on the Mac unless the user exports or shares a backup.

The only built-in network activity is Sparkle's update check against CodePulse
release assets on GitHub. See [`PRIVACY.md`](PRIVACY.md) for the data-handling
summary and [`SECURITY.md`](SECURITY.md) for vulnerability reporting and the
security model.

## Build from source

CodePulse is a Swift Package Manager application. On macOS with Xcode or a
Swift toolchain installed, run:

```sh
./script/build_and_run.sh
```

The script builds the package, stages a real app bundle, and launches it with
the macOS `open` command. To verify that the process starts:

```sh
./script/build_and_run.sh --verify
```

For release packaging, use `./script/package_release.sh` and follow
[`docs/releasing.md`](docs/releasing.md).

README screenshots are rendered from the real SwiftUI views with deterministic,
privacy-safe sample data. Regenerate them with:

```sh
./script/generate_readme_screenshots.sh
```

## Design notes

`SessionStore` owns the idle, running, paused, and finishing lifecycle. Session
duration is derived from timestamps and pause intervals rather than an
incrementing counter, which keeps recovery and calendar-boundary calculations
stable.

When a selected project is inside a local Git working tree, CodePulse reads the
repository root, branch, HEAD, and diff statistics at session boundaries. Git
capture is best-effort and read-only: failures never interrupt timing or saving.
Historical Git metadata is preserved when a completed session is edited.

History filters before grouping sessions by day. Insights uses the user's local
calendar and apportions active time across day and week boundaries while
excluding pauses.

## Tests

Run the deterministic SwiftPM test suite with:

```sh
swift test --configuration debug
```

Tests use injected clocks and calendars, so timer, relaunch, history, Git,
Insights, and backup behavior can be verified without sleeping.

## License

CodePulse is available under the [MIT License](LICENSE).
