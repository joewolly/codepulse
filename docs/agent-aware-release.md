# Agent-aware tracking release guide

This guide is the release, recovery, and known-limitations record for the
agent-aware tracking program. It applies to the integrated Feature 00–18
series and complements the packaging instructions in [Releasing CodePulse](releasing.md).

## Release notes

CodePulse now supports optional local lifecycle tracking for Codex, Claude
Code, and OpenCode; multiple concurrent runs; waiting and review-grace timing;
workspace/local-task discovery; content-safe metadata classification; and
separately opt-in local usage insights. Usage exports identify estimates and
reported cost representations instead of claiming a billed total or remaining
credit balance.

The hardening release adds an in-app data inventory, per-integration deletion,
a local redacted support bundle, bounded OpenCode usage handoffs, safer
workflow permissions and concurrency, a manual non-publishing release
preflight, weekly dependency-update PRs, and reserved-only budget model seams.
No budget policy, alert, notification, or enforcement is enabled.

## Migration and rollback

The existing versioned state migration remains non-destructive: CodePulse keeps
the last readable `state.json.backup` before replacing saved state. A migration
or decode issue is presented in Settings as a recovery condition; use **Export
Recovery Copy…** before changing data.

To roll back an app update:

1. Quit CodePulse.
2. Preserve `~/Library/Application Support/CodePulse/state.json` and its
   `.backup` beside a separate user-chosen backup copy.
3. Install the prior compatible app version.
4. If the older app cannot read the state schema, return to the current app and
   export the recovery copy rather than editing JSON by hand.

There is no automatic backup import. Backups and recovery copies can contain
user-entered session text and paths, so review and protect them before sharing.

## Local integration setup and removal

Enable lifecycle tracking in **Settings → Integrations**. CodePulse edits only
its marked Codex/Claude hook entries or its marked global OpenCode plugin; use
the adjacent Disable control to remove that CodePulse-owned configuration.

Token readers are separate, off by default, and can be disabled without
stopping timing. **Settings → Integration Data** lists the stored categories
and offers a destructive, confirmed per-tool deletion. It removes CodePulse's
saved agent runs, usage samples, attributable diagnostics, and reader
checkpoints for that tool; it does not change user-owned source logs, external
tool configuration, manual sessions, or existing backups.

Use **Export Redacted Support Bundle…** only when troubleshooting. The local
JSON file contains aggregate counts, integration states, and redacted
diagnostic totals—never paths, session IDs/fingerprints, prompts, transcript
text, source content, command data, or freeform session text. Review it before
sharing.

## Clean-machine/manual checklist

- Install from the DMG and use the Gatekeeper flow in [Releasing CodePulse](releasing.md#installation-and-gatekeeper); do not disable Gatekeeper globally.
- Enable/disable each lifecycle integration and verify only CodePulse-owned
  configuration changes.
- Confirm turning off each token reader stops new reads while timing continues.
- Run concurrent local Codex and Claude Code sessions and confirm agent runtime
  sums overlaps while combined wall-active time does not.
- Trigger an OpenCode handoff overflow in the integration harness; it must
  reject the extra event without changing timing.
- Export a support bundle and inspect it for absence of prompt, transcript,
  path, source, and session-identifier content.
- Run the non-publishing **Release preflight** workflow with a synthetic
  version/build. It tests, packages, validates the DMG checksum, validates the
  Sparkle signature using the repository secret, and uploads a short-retention
  artifact without creating a release.

## Known limitations and security review

- A session needs a local process, hook, or locally available usage record.
  Cloud-only sessions are intentionally not tracked.
- Automatic workspace/local-task discovery uses only an integration-provided
  canonical working directory; it does not enumerate directories. Treat a
  locally compromised integration as able to propose paths within the account's
  existing filesystem access. Disable automatic Git workspace discovery and
  integrations if that trust boundary is unacceptable.
- The first-install DMG is intentionally not Developer ID signed or notarized.
  Sparkle authenticates subsequent updates, not the user's original download.
  Developer ID signing/notarization requires separate Apple-account authority.
- Git/GitHub enrichment uses short process timeouts, but unusually large local
  repository output can still make a snapshot unavailable. It never changes the
  repository or timing state.
- Usage queues are bounded, but persistent history grows with retained local
  activity. Delete integration data when it is no longer needed.
- Budgets, alerts, remaining provider-credit/balance lookup, and cross-device
  synchronization remain deferred.

The security review also confirmed content-bearing lifecycle fields are
rejected, V2 inboxes use bounded redacted receipts and symlink checks, and
usage exports default to excluding paths and identifiers. Release workflows now
pin third-party action revisions before a release secret or publishing
permission is used. Dependabot PRs—including Sparkle and workflow revisions—are
never auto-merged and require normal macOS validation and review.
