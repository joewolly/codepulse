# Pricing catalog and cost provenance

Feature 12 provides the local pricing foundation. Features 13–15 use it for the
separately opt-in Codex, Claude Code, and OpenCode usage adapters. Timing
continues to work without token usage or price data.

## Catalog trust and offline behavior

CodePulse ships a small JSON pricing catalog in the app bundle. Every catalog
has a schema version, monotonically increasing catalog version, issue and
expiry timestamps, a signing-key identifier, and a P-256 signature over its
canonical payload. The app verifies the signature before using either the
bundled catalog or a cached remote catalog.

When a caller requests a refresh, it accepts HTTPS only. A remote catalog must
verify, be newer than the highest bundled or cached version, and be written
atomically. Invalid signatures, malformed documents, network failures, and
replayed or downgraded versions are ignored without replacing the last verified
catalog. If a remote cache is unavailable or expired, CodePulse uses the
bundled catalog; an expired bundled catalog remains explicitly labeled as
expired rather than silently presenting its rates as current.

The bundled catalog includes published GPT-5 standard API rates and the
official Codex rate-card mappings used by Feature 13 for `gpt-5.3-codex` and
`gpt-5.2-codex`. Sources are linked in each catalog entry, including the
[GPT-5.3 Codex model page](https://developers.openai.com/api/docs/models/gpt-5.3-codex).
It does not infer prices from reasoning effort, subscription plans, or account
balances. Future catalog entries must include a provider-published source URL,
effective date, currency, model aliases, and only the token-unit rates the
provider publishes.

The current bundled catalog does not yet contain a signed Claude model entry.
Claude Code samples therefore preserve a provider-reported cost when local
metadata supplies one, can show the selected subscription/actual-charge-unknown
state, and remain unpriced for an API-equivalent estimate until a verified
catalog update publishes a matching Claude rate. OpenCode samples similarly
preserve any supplied provider-reported USD cost separately. Their normalized
model labels can resolve to the existing catalog regardless of provider label;
unknown model/rate combinations remain unpriced. A later catalog can enable an
estimate without rereading any source data.

## Cost representations

Usage records preserve provider-reported cost separately from calculated values.
Each calculated value records its exact catalog version, catalog origin,
effective date, resolved model and service mode, source URL, method, confidence,
and calculation time. That provenance is immutable, so a historical estimate
does not change when a later catalog is installed.

The only labels exposed by the model are:

- Provider-reported cost
- API-equivalent estimate
- Codex-credit estimate
- Included/subscription — actual charge unknown
- Unpriced

The estimate labels are part of the typed representation, not editable display
text. A Codex-credit estimate is neither an account balance nor an invoice.
Users can choose the primary representation per developer integration in
**Settings → Integrations**; the app retains every available representation.

## Pricing calculation

The pure calculator multiplies each available input, output, cached-input,
cache-write-input, and reasoning counter by the published per-million-token
rate, preserving six decimal places for storage. It resolves a model alias to a catalog entry. A
service-mode-specific rate is used only when that exact mode exists in the
catalog; otherwise it uses the model's default rate. Effort is recorded as an
analytical dimension and never becomes an invented multiplier.

Provider-reported cost is never recomputed or relabeled. Missing model/rate
data produces no estimate and remains unpriced until a later supported adapter
can supply trustworthy metadata.

## Attribution roll-ups

Feature 16 aggregates stored cost values only within the same representation
and currency. Provider-reported cost, API-equivalent estimates, and
Codex-credit estimates remain distinct totals, preserving their labels and
provenance. The attribution layer never converts currencies, derives an actual
charge from an estimate, or changes historical calculation provenance.
