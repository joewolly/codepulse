# Fork release line and peer ports

`ZacharyRW/codepulse` is an independent CodePulse product line. Its `origin/main`
branch, releases, and GitHub Actions environments are authoritative for this
repository. `joewolly/codepulse` (`upstream`) is a friendly peer: it is useful
for comparing ideas and selectively sharing reviewed work, but it is not a
release authority and its history must not be blanket-merged here.

## Version and tag policy

`0.9.0` is reserved as the next release line for this fork. The source
`Info.plist` remains unchanged until a release candidate is selected. Do not
recreate, move, or delete either repository's existing `v0.8.0` tag; the two
remotes currently resolve that name to different objects.

Update this fork without importing peer tags:

```sh
git fetch origin main --no-tags
git switch main
git pull --ff-only origin main
```

Inspect tags on either remote without modifying local refs:

```sh
git ls-remote --tags origin
git ls-remote --tags upstream
```

If a peer tag needs local inspection, fetch it under a namespaced local tag.
The refspec deliberately has no force prefix, so it will refuse to overwrite an
existing local inspection tag:

```sh
git fetch upstream refs/tags/v0.8.0:refs/tags/peer/upstream-v0.8.0
git show peer/upstream-v0.8.0
```

## Selective feature ports

Treat a useful peer feature as a new, reviewable change in this fork:

1. Read the peer diff and its tests; do not assume shared version or security
   behavior.
2. Fetch only the proposed branch or commit with `--no-tags`.
3. Port or reimplement the selected change on a fork branch, including any
   migration, privacy, release, and security review it needs here.
4. Run this repository's checks and merge through the fork's protected `main`
   path.

This keeps provenance clear while allowing either maintainer to adopt an idea
without coupling releases, tags, histories, or signing trust.
