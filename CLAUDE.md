# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OnDue is a local-first obligation digest iOS app (iOS 18.0+) built with SwiftUI. It extracts actionable obligations (deadlines, requests, appointments) from Gmail inboxes and presents them in a digest view. Core principles: precision over recall, deterministic policy behavior, explainable decisions, local-first privacy.

## Build & Test Commands

```bash
# Build
xcodebuild build \
  -project OnDue.xcodeproj \
  -scheme OnDue \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest"

# Run all tests
xcodebuild test \
  -project OnDue.xcodeproj \
  -scheme OnDue \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest"

# Run a single test class
xcodebuild test \
  -project OnDue.xcodeproj \
  -scheme OnDue \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest" \
  -only-testing:"OnDueTests/RuleEngineTests"

# Run the gold replay gate (CI compliance)
./run-gold-replay-gate-local.sh

# Or run just that test directly
xcodebuild test \
  -project OnDue.xcodeproj \
  -scheme OnDue \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest" \
  -only-testing:"OnDueTests/PolicyReplayHarnessTests/testGoldDatasetV1ReplayGateHasNoHardFailures"
```

No Makefile; use `xcodebuild` or Xcode directly. Dependencies (GRDB, GoogleSignIn) are managed via Xcode's SPM integration.

## Architecture

### Layer Structure

1. **UI** (`Features/`) — SwiftUI views + `ObservableObject` ViewModels per feature (Digest, YearScan, Connect, Settings, ManualPromotion)
2. **Services** (`Services/`) — Gmail auth/sync, extraction pipeline, background scheduling, year scan
3. **Policy & Decision Engine** (`Services/Extraction/`) — `RuleEngine` evaluates hypotheses; `ObligationExtractor` orchestrates
4. **Data** (`Data/`) — GRDB+SQLite repositories; projection repos build digest-ready read models
5. **Models** (`Models/`) — GRDB record types for all persisted entities

### Dependency Injection

`AppEnvironment.live()` is the singleton DI container. All services and repositories are injected through it. Tests substitute mock implementations at this boundary.

### Canonical Decision Contract

Every evaluated message produces:
- `outcome`: `accept | needsReview | reject`
- `primaryHypothesisId`, `reasonCode`, `reasonText`, `evidence`, `policyVersion`

UI renders these fields directly — no lossy transformations. This contract is the core invariant of the system.

### Policy Engine

- 11 core hypotheses (e.g., `userActionRequired`, `deadlineImplied`, `waitingOnThirdParty`)
- Global blockers act as hard vetoes (always override hypotheses)
- No ML — weights/multipliers are stored in `rule_weight` table, not trained
- Policy changes require replay against gold dataset before merge

### Key Flows

**Ingestion**: Gmail sync → `EmailParser` normalizes → `RuleEngine` evaluates → obligations persisted → projections update UI

**Digest**: `DigestViewModel` loads projected items → user actions (`confirm`, `done`, `dismiss`, `snooze`, `block`) write feedback → projections update

**Year Scan**: `YearScanRunner` backfills/scans up to 12 months → checkpoints in `year_scan_state` → results in `year_scan_result` → items promoted via ManualPromotion flow

### Database

GRDB + SQLite with WAL mode. Key tables: `message`, `obligation`, `obligation_projection`, `year_scan_state`, `year_scan_result`, `feedback`, `suppression`, `rule_weight`, `candidate_score`. FTS5 on `message_fts`.

## Quality Gates

- **Gold replay gate** (`PolicyReplayHarnessTests/testGoldDatasetV1ReplayGateHasNoHardFailures`) runs in CI on every extraction/policy change — hard fail on regression
- Blockers must always veto; no date-only or urgency-only auto-accept
- Policy changes must be diffed and replayed before merge (`docs/reports/`)
- Performance PRs require `PerfMetrics.ScanRun` log comparison and Instruments trace

## Documentation

- `docs/ARCHITECTURE.md` — single source of truth for system architecture; update in same PR as behavior changes
- `docs/adr/ADR-XXXX-<kebab-topic>.md` — use for irreversible/high-impact decisions (schema changes, policy semantics, new module boundaries)
- `docs/reports/` — generated policy drift/reliability artifacts
