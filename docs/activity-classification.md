# Activity classification

Feature 11 classifies an activity along two independent dimensions:

- **Work type:** Coding, Debugging, Planning, Review, or Research.
- **Activity domain:** Development, File Organization, Automation,
  Administration, Documentation, Local Task, or Unknown.

## Default metadata-only classification

Automatic classification is enabled by default only for the lifecycle metadata
already accepted by the content-safe `DeveloperEventV2` boundary. Rules use a
closed action category, an optional closed file-type category, and workspace
identity. They do not derive labels from free-form adapter strings, open project
files, or inspect prompts, transcripts, messages, tool inputs, commands, or
command output.

Each stored result contains the dimension, its constrained value, source,
confidence, timestamp, and a coarse evidence category. It does not contain the
raw metadata value that matched a rule. A later metadata result replaces an
earlier result from that source for the same dimension, keeping the persisted
state compact while retaining an explainable current label.

## Prompt classification is deferred

No current integration supplies prompt text for classification, and CodePulse
has no prompt-classification setting or prompt-processing API. The event schema
continues to reject prompt-bearing fields. A future implementation needs a
separate approved local handoff design, explicit consent, and tests proving
that prompt text is absent from state, diagnostics, exports, backups, and any
future crash-reporting surface before it can ship.

## Corrections and precedence

An activity’s detail view lets the user correct its work type or domain and
undo either correction. A correction is stored locally as a `userOverride`
with `userCorrection` evidence. Precedence is:

1. User override
2. Metadata-only result

Corrections never train a model, leave the Mac, or affect other activities.
