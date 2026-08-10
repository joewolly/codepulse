# CodePulse macOS release packaging

## What the artifact is

CodePulse is distributed as a native macOS application inside a drag-to-install
`.dmg`. The package is built from Swift Package Manager source and does not
use Electron, Catalyst, or an installer package.

This v0.4 release is intentionally unsigned and non-notarized. No Apple
Developer Program account or signing credentials are required to build it.

## Requirements

- macOS 13 or later
- Xcode or a Swift toolchain with the macOS SDK
- native macOS tools including `swift`, `lipo`, `hdiutil`, `plutil`, and
  `shasum`

The release script builds arm64 and x86_64 binaries and combines them into a
Universal 2 executable when the installed Swift toolchain supports both
targets. Each run uses fresh temporary SwiftPM scratch directories, so stale
debug or release binaries are not selected accidentally.

## Build command

From the repository root:

```sh
./script/package_release.sh
```

Optional iteration modes are available:

```sh
./script/package_release.sh --app-only
./script/package_release.sh --skip-smoke
./script/package_release.sh --adhoc-sign
```

`--app-only` omits DMG creation. `--skip-smoke` omits the read-only DMG mount
and layout check. `--adhoc-sign` applies a local ad-hoc signature for bundle
integrity checks; it does not identify CodePulse to Gatekeeper and is not
Developer ID signing.

The version and build number can be overridden without editing source files:

```sh
CODEPULSE_VERSION=0.4.0 CODEPULSE_BUILD=400 ./script/package_release.sh
```

## Output

The default release writes:

```text
dist/release/
├── CodePulse.app
├── CodePulse-0.4.0.dmg
└── checksums.txt
```

The app bundle uses the canonical identifier `com.joewolly.CodePulse`, keeps
`LSUIElement` enabled for menu-bar-only behavior, targets macOS 13.0, and
contains its icon in `Contents/Resources`.

## Installation and Gatekeeper

The DMG is not Developer ID signed and is not notarized. On a Mac with normal
Gatekeeper protections, the first launch may show an unidentified-developer
or cannot-verify-developer warning. That warning is expected for this release
and is not a corrupt-DMG indication.

To install:

1. Open the DMG.
2. Drag `CodePulse.app` to `Applications`.
3. Try opening CodePulse from Finder.
4. If macOS blocks the first launch, open System Settings → Privacy & Security
   and use the available **Open Anyway** or **Allow** action for CodePulse,
   then confirm the Finder open action.

Do not disable Gatekeeper globally. The normal Finder context-menu **Open**
flow is also an appropriate way to make the explicit first-launch decision.

## Verification

The checksum file uses the release filename:

```text
SHA256 (CodePulse-0.4.0.dmg) = <64 hexadecimal characters>
```

Useful local checks include:

```sh
plutil -p dist/release/CodePulse.app/Contents/Info.plist
file dist/release/CodePulse.app/Contents/MacOS/CodePulse
lipo -info dist/release/CodePulse.app/Contents/MacOS/CodePulse
shasum -a 256 dist/release/CodePulse-0.4.0.dmg
```

The default package is intentionally unsigned, so `codesign --verify` is not
expected to report a trusted signature. With `--adhoc-sign`, the script runs
strict `codesign` verification; an ad-hoc signature verifies bundle integrity
but still provides no developer identity or notarization ticket.

## Compatibility notes

Packaging preserves `com.joewolly.CodePulse`, the existing Application
Support state path, Launch at Login through `SMAppService.mainApp`, Carbon's
global `⌥⌘T` shortcut, `/usr/bin/git`, and security-scoped project bookmarks.
The installed app should be tested from outside the source checkout before
publishing a future GitHub Release.
