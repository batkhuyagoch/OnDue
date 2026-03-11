# OnDue Architecture

Last updated: 2026-02-23

## Product Intent

OnDue is a trust-first, local-first obligation sidekick for email. It extracts actionable obligations from inbox content and presents them in an operational workflow.

Core principles:
- Precision over recall for auto-accept.
- Deterministic policy behavior before adaptation.
- Explainable decisions through canonical reasoning fields.
- Local-first privacy and minimal retention.

## System Architecture

### Layers

1. UI Layer (SwiftUI + MVVM)
- Primary surfaces: digest, obligation detail, coverage/year-scan.
- `ObservableObject` view models orchestrate user actions and repository reads.

2. Coordination and Services
- Gmail auth + sync coordinators.
- Extraction/parsing pipeline.
- Background year-scan scheduling and checkpointing.

3. Policy and Decision Engine
- `RuleEngine` and `DecisionPolicy` evaluate hypotheses.
- Global blockers are hard vetoes.
- Output is a canonical decision contract.

4. Data Layer
- GRDB + SQLite persistence.
- Projection repositories build digest-ready read models.
- Feedback and metrics repositories store user action and hypothesis counters.

### Canonical Decision Contract

Every evaluated message maps to:
- `outcome` (`accept | needsReview | reject`)
- `primaryHypothesisId`
- `reasonCode`
- `reasonText`
- `evidence`
- `policyVersion`

UI rendering and labeling should consume these fields directly.

## Primary Flows

### 1) Ingestion and Extraction

1. Gmail sync fetches messages into local storage.
2. `EmailParser` normalizes subject/snippet/body/labels.
3. `RuleEngine` evaluates signals and hypotheses.
4. Accepted/review items are persisted as obligations and projected for digest.

### 2) Digest Workflow

1. `DigestViewModel` loads projected items by lens/grouping.
2. User actions (`confirm`, `done`, `dismiss`, `snooze`, `block`) write feedback and update obligation state.
3. Projection updates drive UI refresh; undo path restores status where supported.

### 3) Year Scan Workflow

1. `YearScanRunner` backfills and scans up to 12 months.
2. Progress and checkpoints persist in `year_scan_state`.
3. Results persist in `year_scan_result`.
4. Resume/pause/clear operations operate from persisted state.

## Data and State

Important persisted entities:
- `message` (provider IDs, thread IDs, content, labels)
- `obligation` (status, confidence, rationale, timestamps)
- `obligation_projection` (digest lifecycle state and due buckets)
- `year_scan_state` (in-progress/resume metadata)
- `year_scan_result` (coverage findings)

## Quality Gates

Required release safeguards:
- No date-only/urgency-only acceptance.
- Blockers always veto.
- Canonical reason taxonomy remains aligned across engine and UI.
- Policy changes must be replayed and diffed before merge.
- Gold dataset regression remains within precision/review guardrails.

## Documentation Governance

- `docs/ARCHITECTURE.md` is the single source of truth for system architecture.
- Keep architecture/process docs out of feature code folders.
- If behavior or boundaries change, update this file in the same PR.

### ADR Policy

Use ADRs for irreversible or high-impact technical decisions:
- data model/schema strategy changes
- decision-contract/policy semantic changes
- new module/service boundary decisions
- trade-off choices with meaningful alternatives

ADR path and naming:
- `docs/adr/ADR-XXXX-<kebab-topic>.md`

### Generated Reliability Artifacts

Store generated policy/reliability/drift evidence under:
- `docs/reports/`

Recommended report naming:
- `mutation-weekly-YYYY-MM-DD.md`

## Near-Term Roadmap

1. Stabilize suppression + projection integration tests.
2. Expand dataset coverage for delivery/account/legal edge cases.
3. Improve policy diff tooling metadata and rerun ergonomics.
4. Continue UX polish for digest and coverage flows without reducing precision.

