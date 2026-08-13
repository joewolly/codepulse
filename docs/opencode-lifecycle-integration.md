# OpenCode lifecycle integration

CodePulse uses OpenCode's documented plugin event API as its lifecycle source.
When enabled, it creates one CodePulse-owned global plugin at
`~/.config/opencode/plugins/codepulse-integration.js`. OpenCode loads plugin
files from that directory at startup. No OpenCode configuration file, project
plugin, session database, or transcript is modified or read.

## Supported event contract

The plugin subscribes only to the documented session events: `session.created`,
`session.status`, `session.idle`, `session.deleted`, and `session.error`. It
passes a new, bounded local record to CodePulse containing only the event kind,
session ID, working directory, optional model/agent label, and a monotonic
event sequence. `session.status` values `busy` and `retry` become activity;
`idle` becomes waiting. A deleted session ends a run. Error and unknown state
are diagnostics only.

The lifecycle path does not subscribe to tool, command, or file events. Feature
15 adds one separate, opt-in `message.updated` subscription solely to emit a
content-safe assistant usage record; it does not forward message text or any
other message field. Prompts, messages, content, tool arguments/results,
commands, transcripts, and source files are never forwarded. There is no local
database fallback: if the plugin API is unavailable or OpenCode is not
installed, CodePulse reports the integration as unavailable rather than guessing
from stored data.

## Optional token usage

Lifecycle timing does not enable token tracking. **Track OpenCode token usage**
is a second, off-by-default consent in Settings. When it is enabled, the same
managed plugin sends a bounded, allowlisted assistant usage record through a
local helper. It includes only identity needed for salted correlation, working
directory, timestamp, model/provider, service mode, numeric token counters, and
available reported cost. The helper checks consent before it decodes or writes
the handoff. An unsupported plugin version, malformed handoff, or absent plugin
degrades token usage only; lifecycle timing continues normally. See
[`opencode-usage-tracking.md`](opencode-usage-tracking.md) for the full source,
storage, cost, and health contract.

## Validation harness

The unit fixtures verify the selected event names and generated plugin source,
then map synthetic content-free plugin records through the same v2 receiver as
other integrations. This keeps the contract reproducible without requiring a
local OpenCode installation in CI.

## Repair and removal

The Settings integration row reports both OpenCode detection and whether the
CodePulse-owned plugin is present. **Enable / Repair integration** replaces
only that marked filename; it refuses to overwrite a non-CodePulse file.
**Disable integration** removes only the managed plugin. Restart OpenCode after
enabling, repairing, or disabling so it reloads its plugin directory.
