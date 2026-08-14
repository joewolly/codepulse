# CodePulse macOS release packaging

## What the artifact is

CodePulse is distributed as a native macOS application inside a drag-to-install
`.dmg`. The package is built from Swift Package Manager source and does not
use Electron, Catalyst, or an installer package.

The current release remains intentionally unsigned and non-notarized. No Apple
Developer Program account or Developer ID signing credentials are required to
build it. Sparkle provides authenticated in-app updates using an Ed25519
update-signing key.

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

The version and build number can be overridden without editing source files.
`CODEPULSE_RELEASE_REPOSITORY` controls the Sparkle feed embedded in the staged
app bundle; use the GitHub repository that will host the release assets:

```sh
CODEPULSE_VERSION=<version> CODEPULSE_BUILD=<numeric-build> \
CODEPULSE_RELEASE_REPOSITORY=owner/codepulse \
  ./script/package_release.sh
```

Before committing a packaging or startup change, build a synthetic candidate,
apply an ad-hoc signature, and launch that staged app. Confirm the process
remains running before creating a tag:

```sh
CODEPULSE_VERSION=<next-version> CODEPULSE_BUILD=<next-build> \
  ./script/package_release.sh --app-only --adhoc-sign
open -n dist/release/CodePulse.app
pgrep -x CodePulse
```

This local smoke check exercises the staged app bundle and its resources; it is
separate from the non-publishing GitHub release preflight and from distribution
signing/notarization.

## Output

The default release writes:

```text
dist/release/
├── CodePulse.app
├── CodePulse-<version>.dmg
└── checksums.txt
```

The app bundle uses the canonical identifier `com.joewolly.CodePulse`, keeps
`LSUIElement` enabled for menu-bar-only behavior, targets macOS 13.0, contains
its icon in `Contents/Resources`, and embeds Sparkle in `Contents/Frameworks`.

## Sparkle updates

CodePulse uses Sparkle for update discovery and installation. Existing builds
published before Sparkle support need one manual update; subsequent compatible
releases can be discovered and installed through Sparkle.

The source configuration is stored in `Resources/Info.plist`. During release
packaging, `CODEPULSE_RELEASE_REPOSITORY` determines the staged app's feed URL;
the GitHub Actions workflow sets it to the repository running the workflow.
This prevents a fork release from advertising an upstream appcast or assets.

The staged app contains:

- `SUFeedURL` pointing to
  `https://github.com/<owner>/<repository>/releases/latest/download/appcast.xml`
- `SUPublicEDKey` contains only the public Ed25519 verification key
- `SUEnableAutomaticChecks` enables scheduled background update checks

The Sparkle private key must never be committed to the repository or stored as
a repository-wide Actions secret. The protected production publish job expects
the exported private key to be stored as a base64 environment secret named:

```text
SPARKLE_PRIVATE_KEY_BASE64
```

For example, after exporting the Sparkle private key locally:

```sh
base64 < "$HOME/.config/codepulse/sparkle-private-key" \
  | tr -d '\n' \
  | gh secret set SPARKLE_PRIVATE_KEY_BASE64 \
      --repo owner/codepulse \
      --env production-signing
```

Before adding the secret, configure the `production-signing` environment with
an independent reviewer or a solo-maintainer wait timer, then restrict it to
protected `v*` release tags. This fork uses a 30-minute wait timer while it has
one maintainer. Protect `main` with pull-request review and the `macOS
validation` check, while keeping the bypass list minimal. The unprivileged
prepare job validates the tag, runs tests, packages, and uploads a short-lived
candidate. Only after the protected environment gate passes does the publish
job download the candidate, re-verify the tagged commit is in `main`, and
access the production key.

Each repository that publishes releases needs its own environment secret
matching the public key embedded in `Resources/Info.plist`.
It uses Sparkle's `sign_update` utility with the private key passed over stdin,
creates `appcast.xml`, uploads the appcast with the DMG and checksum, and then
downloads the published assets again for verification.

### 0.9.0 signing-key recovery

`0.9.0` begins a new fork signing-key line after the previous private key could
not be recovered. It is a manual-upgrade release: users of earlier builds must
download and install `0.9.0` from GitHub Releases. After that installation,
Sparkle updates resume under the new key. Do not replace, move, or delete the
historical `v0.8.0` tag or release.

Each appcast item uses the immutable version-tagged GitHub Release asset URL
for its DMG. The app itself reads the appcast through GitHub's stable latest
release asset URL.

## Automated release flow

A release is initiated only after its version/build change has been merged to
`main`:

```sh
git fetch origin main --no-tags
git switch main
git pull --ff-only origin main
git tag v<version>
git push origin v<version>
```

This repository is an independent release line. Do not use an unqualified tag
fetch from the peer repository: see
[`fork-release-line.md`](fork-release-line.md) for safe remote inspection and
selective feature-port procedures.

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
Every release requires a committed `docs/releases/<version>.md` file; its text
is published as the GitHub Release notes.

Before creating a real tag, manually dispatch the **Release preflight** GitHub
Actions workflow with a synthetic semantic version and numeric build. Its inputs
are validated as environment data before checkout, it has read-only repository
permissions, creates no GitHub Release, and validates the test suite,
ad-hoc-signed package, DMG checksum, and Sparkle sign/verify flow with a
per-run disposable key. It never reads the production signing environment or
its secret.

All GitHub Actions are pinned to reviewed commit SHAs. Dependabot opens weekly
Swift and GitHub Actions updates; review these like any release-related change
and do not auto-merge them.

## Installation and Gatekeeper

The DMG is not Developer ID signed and is not notarized. On a Mac with normal
Gatekeeper protections, the first manual installation may show an
unidentified-developer or cannot-verify-developer warning. That warning is
expected for this distribution model and is not a corrupt-DMG indication.

To install the initial Sparkle-capable build:

1. Drag `CodePulse.app` into `Applications`.
2. Attempt to open CodePulse normally.
3. macOS may show the verification warning.
4. Click **Done** on that warning.
5. Open **System Settings**.
6. Open **Privacy & Security**.
7. Scroll to the **Security** section.
8. Find the blocked CodePulse message.
9. Choose **Open Anyway**.
10. Authenticate if macOS requests it.
11. Confirm launching CodePulse.

Do not disable Gatekeeper globally. The normal Finder context-menu **Open**
flow is also an appropriate way to make the explicit first-launch decision.

## Verification

The checksum file uses the release filename:

```text
SHA256 (CodePulse-<version>.dmg) = <64 hexadecimal characters>
```

Useful local checks include:

```sh
plutil -p dist/release/CodePulse.app/Contents/Info.plist
file dist/release/CodePulse.app/Contents/MacOS/CodePulse
lipo -info dist/release/CodePulse.app/Contents/MacOS/CodePulse
otool -L dist/release/CodePulse.app/Contents/MacOS/CodePulse
shasum -a 256 dist/release/CodePulse-<version>.dmg
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
