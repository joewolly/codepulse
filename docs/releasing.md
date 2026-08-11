# CodePulse macOS release packaging

## What the artifact is

CodePulse is distributed as a native macOS application inside a drag-to-install
`.dmg`. The package is built from Swift Package Manager source and does not
use Electron, Catalyst, or an installer package.

The current release remains intentionally unsigned and non-notarized. No Apple
Developer Program account or Developer ID signing credentials are required to
build it. Starting with v0.4.2, Sparkle provides authenticated in-app updates
using an Ed25519 update-signing key.

## Requirements

- macOS 13 or later
- Xcode or a Swift toolchain with the macOS SDK
- native macOS tools including `swift`, `lipo`, `hdiutil`, `plutil`, and
  `shasum`
- Sparkle 2.9.2, resolved through Swift Package Manager

The release script builds arm64 and x86_64 binaries and combines them into a
Universal 2 executable when the installed Swift toolchain supports both
targets. It also embeds `Sparkle.framework` in `Contents/Frameworks`, preserving
Sparkle's framework symlinks and adding the app runtime search path required to
load it from the staged bundle.

Each run uses fresh temporary SwiftPM scratch directories, so stale debug or
release binaries are not selected accidentally.

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
CODEPULSE_VERSION=0.4.2 CODEPULSE_BUILD=402 ./script/package_release.sh
```

## Output

The default release writes:

```text
dist/release/
├── CodePulse.app
├── CodePulse-0.4.2.dmg
└── checksums.txt
```

The app bundle uses the canonical identifier `com.joewolly.CodePulse`, keeps
`LSUIElement` enabled for menu-bar-only behavior, targets macOS 13.0, contains
its icon in `Contents/Resources`, and embeds Sparkle in `Contents/Frameworks`.

## Sparkle updates

CodePulse uses Sparkle for update discovery and installation starting with
v0.4.2. Existing v0.4.1 installations need to install v0.4.2 manually once;
subsequent releases can be discovered and installed through Sparkle.

The application configuration is stored in `Resources/Info.plist`:

- `SUFeedURL` points to
  `https://github.com/joewolly/codepulse/releases/latest/download/appcast.xml`
- `SUPublicEDKey` contains only the public Ed25519 verification key
- `SUEnableAutomaticChecks` enables scheduled background update checks

The Sparkle private key must never be committed to the repository. The tag
release workflow expects the exported private key to be stored as a base64
GitHub Actions repository secret named:

```text
SPARKLE_PRIVATE_KEY_BASE64
```

For example, after exporting the Sparkle private key locally:

```sh
base64 < "$HOME/.config/codepulse/sparkle-private-key" \
  | tr -d '\n' \
  | gh secret set SPARKLE_PRIVATE_KEY_BASE64 --repo joewolly/codepulse
```

The release workflow refuses to publish a release if this secret is missing.
It uses Sparkle's `sign_update` utility with the private key passed over stdin,
creates `appcast.xml`, uploads the appcast with the DMG and checksum, and then
downloads the published assets again for verification.

Each appcast item uses the immutable version-tagged GitHub Release asset URL
for its DMG. The app itself reads the appcast through GitHub's stable latest
release asset URL.

## Automated release flow

A release is initiated only after its version/build change has been merged to
`main`:

```sh
git checkout main
git pull --ff-only
git tag v0.4.2
git push origin v0.4.2
```

The `GitHub Release` workflow then:

1. validates that the tag matches `CFBundleShortVersionString`
2. validates that the tagged commit is already contained in `main`
3. runs the Swift test suite
4. builds and validates the Universal 2 DMG
5. signs the update archive with Sparkle EdDSA
6. creates and validates `appcast.xml`
7. publishes the normal latest GitHub Release
8. uploads the DMG, `checksums.txt`, and `appcast.xml`
9. downloads the published assets and verifies the checksum and appcast again

Do not manually replace release assets after a successful automated release;
the appcast signature and published archive are expected to stay in sync.

## Installation and Gatekeeper

The DMG is not Developer ID signed and is not notarized. On a Mac with normal
Gatekeeper protections, the first manual installation may show an
unidentified-developer or cannot-verify-developer warning. That warning is
expected for this distribution model and is not a corrupt-DMG indication.

To install the initial Sparkle-capable build:

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
SHA256 (CodePulse-0.4.2.dmg) = <64 hexadecimal characters>
```

Useful local checks include:

```sh
plutil -p dist/release/CodePulse.app/Contents/Info.plist
file dist/release/CodePulse.app/Contents/MacOS/CodePulse
lipo -info dist/release/CodePulse.app/Contents/MacOS/CodePulse
otool -L dist/release/CodePulse.app/Contents/MacOS/CodePulse
shasum -a 256 dist/release/CodePulse-0.4.2.dmg
```

The default package is intentionally unsigned, so `codesign --verify` is
expected to fail because CodePulse has no Apple code signature. Sparkle's
EdDSA signature authenticates the update archive independently of Apple code
signing.

With `--adhoc-sign`, the packaging script runs strict `codesign` verification;
an ad-hoc signature verifies bundle integrity but still provides no developer
identity or notarization ticket.

## Compatibility notes

Packaging preserves `com.joewolly.CodePulse`, the existing Application
Support state path, Launch at Login through `SMAppService.mainApp`, Carbon's
global `⌥⌘T` shortcut, `/usr/bin/git`, and security-scoped project bookmarks.
The installed app should still be tested from outside the source checkout
before publishing a future GitHub Release.
