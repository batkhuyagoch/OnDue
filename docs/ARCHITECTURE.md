# OnDue Architecture

Last updated: 2026-03-19

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

## Performance Profiling Workflow

### Instrumented Stages

The Year Scan pipeline is instrumented with `os_signpost` intervals in `YearScanRunner`:

| Signpost Name     | Scope                         | What it measures                          |
|-------------------|-------------------------------|-------------------------------------------|
| `FullScan`        | Entire `run()` call           | End-to-end scan time                      |
| `MonthBackfill`   | Per-month backfill call       | Gmail API fetch + local persist per month |
| `MonthClassify`   | Per-month classification      | `obligationExtractor.scanYear` per month  |
| `PageExtraction`  | Per-page in scanning loop     | Classification of a single message batch  |

### How to Profile

1. Open Instruments, attach to OnDue on device/simulator.
2. Add the `os_signpost` instrument (or `Points of Interest`).
3. Filter by subsystem `com.ondue.yearscan`.
4. Start a Year Scan in the app and observe interval durations.
5. Also use Time Profiler to identify CPU hotspots within signpost intervals.

### Structured Metrics

`PerfMetrics.logScanRun()` emits a single structured log line at scan completion with:
- elapsed seconds, peak memory MB, pages scanned
- months backfilled, messages classified
- throttle event count, average batch size

Search console/logs for `PerfMetrics.ScanRun` to find these entries.

### Reproducible Benchmark Protocol

To compare before/after for performance changes:

1. **Same mailbox**: Use a consistent test account with a known message volume.
2. **Same simulator/device**: Pin to a specific device model (e.g., iPhone 14 Pro simulator).
3. **Same scan range**: Use a fixed `coverageScanMonths` (e.g., 12 months).
4. **Same intensity**: Use `balanced` intensity.
5. **Fresh state**: Clear year scan state before each run (`clearState`).
6. **Record**: Capture the `PerfMetrics.ScanRun` log line and Instruments trace.
7. **Compare**: Side-by-side the metrics and signpost durations.

### Acceptance Gates

A performance PR passes when:
- Full scan remains responsive during active interaction (no visible hangs).
- `PerfMetrics.ScanRun` elapsed time is equal or better vs baseline.
- Peak memory is equal or better vs baseline.
- No regression in month summary correctness or promotion results.
- Profiling evidence (Instruments trace or log comparison) is included in the PR.

## Near-Term Roadmap

1. Stabilize suppression + projection integration tests.
2. Expand dataset coverage for delivery/account/legal edge cases.
3. Improve policy diff tooling metadata and rerun ergonomics.
4. Continue UX polish for digest and coverage flows without reducing precision.

