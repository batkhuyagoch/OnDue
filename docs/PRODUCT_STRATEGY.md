# OnDue Product Strategy (Technical)

## Scope

This document defines implementation constraints, data contracts, and rollout order for local-first obligation intelligence.

## Non-Negotiable Constraints

- Local-first processing and storage by default.
- UI information architecture remains `Now / Later / Done`.
- No infinite-feed interaction patterns.
- No backend dependency for core ranking/extraction loops.
- Platform boundary: OnDue handles prevention/follow-through; Find My handles item location.

## Current System Baseline

- Digest flow: `Now / Later / Done` with global search.
- Long scan runtime: resumable, throttled, persisted (`year_scan_state`, `year_scan_result`).
- Quality gates: gold replay hard-failure checks + mutation metrics.
- Gap: long-scan output is not fully integrated into daily obligation flow.

## Target Runtime Contracts

### 1) Long Scan Output Contract

Every long-scan finding must resolve into one of:

1. promoted to normal obligation flow (`Now`/`Later`),
2. converted into expected-event pattern signal,
3. dropped with explicit reason code (low confidence, missing due date, suppressed).

Required persistence fields:

- source (`scan`, `sync`, `capture`),
- promotionDecision,
- promotionReasonCode,
- confidence,
- dueDate (nullable).

### 2) Deterministic Personalization Contract (No ML)

Behavioral signals:

- `done`, `snooze`, `dismiss`, `confirm`, `notThisMonth`.

Derived weights:

- senderWeight,
- categoryWeight,
- dismissalPenalty,
- recurrenceBoost,
- dueUrgencyBoost.

Scoring:

`finalScore = baseRuleScore + senderWeight + categoryWeight + dueUrgencyBoost + recurrenceBoost - dismissalPenalty`

Safety:

- full explainability for ranked items,
- user reset for learned preferences,
- local-only storage unless optional sync is enabled.

### 3) Upcoming Timeline Contract

Single timeline view grouped by due horizon:

- `Today`,
- `Next 3 Days`,
- `Next 7 Days`,
- `Later`.

All grouped items must remain actionable via existing actions (`Done`, `Snooze`, optional `Add to Calendar`).

No new top-level buckets beyond `Now / Later / Done`.

## Data Model Additions (Planned)

- `user_behavior_signal`
- `sender_preference`
- `category_preference`
- `expected_event_pattern`
- `promotion_audit` (or equivalent fields on existing projection rows)

## Delivery Sequence

1. Bridge long-scan findings into daily flow (promotion + reason codes).
2. Add upcoming timeline grouping for due items.
3. Implement deterministic weighting with behavior signals.
4. Implement expected-event checks (missing statement/bill/package follow-up).
5. Add quick-capture clarify-later flow.

## Quality Gates

Keep existing:

- gold replay hard failures.

Strengthen:

- promote large policy drift (`decisionDeltaIndex`) from warning to fail threshold in CI,
- fail on invariant break and blocker leakage,
- track promotion-rate regressions for scan-to-daily bridge.

## Operational Metrics

Primary:

- prevented misses per active user per month.

Supporting:

- action completion within 24h,
- median time to clear daily queue,
- scan findings promotion rate,
- false-positive suppression trend.

## Out of Scope (Current Phase)

- backend-heavy inference pipelines,
- bidirectional multi-system sync,
- monetization features,
- additional top-level navigation modes.

