# Activity classification

Feature 11 classifies an activity along two independent dimensions:

- **Work type:** Coding, Debugging, Planning, Review, or Research.
- **Activity domain:** Development, File Organization, Automation,
  Administration, Documentation, Local Task, or Unknown.

## Default metadata-only classification

Automatic classification is enabled by default only for the lifecycle metadata
already accepted by the content-safe `DeveloperEventV2` boundary. Rules use a
closed source/action category, workspace identity, and a supplied file type
when present. They do not open project files or inspect prompts, transcripts,
messages, tool inputs, commands, or command output.

Each stored result contains the dimension, its constrained value, source,
confidence, timestamp, and a coarse evidence category. It does not contain the
raw metadata value that matched a rule. A later metadata result replaces an
earlier result from that source for the same dimension, keeping the persisted
state compact while retaining an explainable current label.

## Optional local prompt classification

**Settings → Integrations → Use local prompt classification** is off by
default. If a supported local integration supplies a prompt through the
dedicated in-memory API after consent, CodePulse derives the same two labels,
then immediately discards the text. It stores only `ephemeralPrompt` as the
source and `ephemeralPrompt` as the evidence category.

Prompt text, excerpts, tokens, hashes, or embeddings are never added to the
event schema, app state, diagnostics, crash reporting, exports, or backups.
Disabling the setting prevents this in-memory operation; timing and
metadata-only classification continue independently.

## Corrections and precedence

An activity’s detail view lets the user correct its work type or domain and
undo either correction. A correction is stored locally as a `userOverride`
with `userCorrection` evidence. Precedence is:

1. User override
2. Ephemeral local prompt result
3. Metadata-only result

Corrections never train a model, leave the Mac, or affect other activities.
