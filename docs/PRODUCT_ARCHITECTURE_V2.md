# Email Action Sidekick (OnDue) - Product & Architecture v2

## Product Thesis

OnDue is a trust-first obligation sidekick for email. It does not replace the inbox; it extracts only actionable obligations and turns them into a clear operational plan.

### Core user promise
- Reduce cognitive load from buried obligations.
- Prefer precision over volume.
- Explain every decision in plain language.
- Keep user data private and local-first.

## Problem We Solve

- Important obligations are buried among promotions, newsletters, and low-value updates.
- Marketing language mimics urgency, causing false attention and missed real deadlines.
- Users carry memory burden for renewals, payments, forms, legal and compliance actions.
- Existing email clients optimize inbox management, not obligation execution.

## Product Principles

- **Trust-first:** strict reject is better than noisy review.
- **Deterministic first:** stable policy decisions before adaptive behavior.
- **Explainable by default:** every surfaced item must have a coherent reason.
- **Single operational surface:** digest/timeline is the primary workflow.
- **Local-first privacy:** process on-device where possible; minimize retained data.

## Decision Contract (Canonical Output)

Every evaluated message produces a typed contract:

- `outcome`: `accept | needsReview | reject`
- `primaryHypothesisId`: canonical hypothesis identifier (nullable only for reject edge cases)
- `reasonCode`: canonical reason taxonomy
- `reasonText`: user-readable reason
- `evidence`: compact textual evidence list
- `policyVersion`: active decision policy version

This contract is the single source for UI rendering, feedback, labeling, and policy comparison.

## High-Level Architecture

### 1) Ingestion Layer
- `AuthService`: OAuth and token lifecycle.
- `GmailService`: sync windows, message fetch, retries, batching.
- `MessageStore`: persisted message metadata/body.

### 2) Parsing Layer
- `EmailParser`: normalize subject/snippet/body and labels.
- Entity/signal extraction: dates, explicit requests, shipment actions, verification cues, blockers.

### 3) Policy Layer (Deterministic)
- `RuleEngine` + `DecisionPolicy`:
  - evaluates hypotheses,
  - enforces global blockers,
  - resolves outcome via policy matrix,
  - emits `DecisionContract`.
- `ReasonCatalog`:
  - canonical display text,
  - short chip text,
  - labeling options.

### 4) Persistence & Projection Layer
- GRDB tables store obligations and decision contract fields.
- Projection repositories generate digest-ready read models.
- `FeedbackRepository` stores user actions and review calibration context.

### 5) UX Layer
- Digest and detail views as primary operational surfaces.
- Labeling tools for curated dataset quality.
- Debug policy tools (diff, export/copy) for safe policy iteration.

### 6) Evaluation Layer
- Gold dataset replay harness.
- Policy diff reporting (baseline vs candidate).
- Precision guardrails and blocker leak checks.

## Hypothesis-Driven Decisioning

Primary hypotheses include action-required, deadline implied, delivery action, account/identity verification, appointment action, legal/compliance, waiting/follow-up, and marketing noise.

Each hypothesis defines:
- required evidence,
- boost evidence,
- blocking evidence,
- human-readable reason template.

Global blockers are hard vetoes and must never leak into acceptance.

## Feedback Model (Safe Adaptation)

Feedback influences **review calibration** first, not opaque acceptance shifts.

- Confirm/dismiss/snooze/done actions are stored with context:
  - sender domain class,
  - label cluster,
  - thread pattern,
  - hypothesis id.
- Adaptive behavior tunes `needsReview` boundary bands.
- Acceptance remains conservative and deterministic.

## UI Contract Rules

- UI must render from canonical fields (`reasonCode`, `primaryHypothesisId`, `outcome`).
- Avoid signal-string rendering as final labels.
- Reason chips and detail rationale must be consistent.
- Shipping/marketing/security toggles must use canonical mapping and predictable overrides.

## Release Gates (Must Pass)

- No date-only or urgency-only acceptance.
- Global blockers always veto.
- Delivery/appointment/account-verification mappings are coherent end-to-end.
- Canonical reason taxonomy is synchronized across engine, digest UI, and labeling UI.
- Policy diff report generated for every policy candidate.
- Gold dataset regression within precision targets and bounded review ratio.

## Observability & Operations

- Deterministic counters per hypothesis:
  - fired, blocked, review, accepted.
- Local-first diagnostics:
  - policy diff summaries,
  - filter diagnostics in debug surfaces,
  - exportable markdown reports.
- Prepare dashboard-ready schema without changing decision determinism.

## Roadmap (30 / 60 / 90)

### 0-30 days: Stability + Coherence
- Finish canonical mapping cleanup across all UI surfaces.
- Remove stale signal-based display/filter assumptions.
- Harden block sender/domain and detail rendering edge cases.
- Add regression tests for mapping and filtering matrix.

### 31-60 days: Evaluation Discipline
- Expand gold dataset coverage by hypothesis class.
- Add confusion summaries and blocker leak dashboards.
- Establish policy rollout checklist with diff + replay artifacts.

### 61-90 days: Product Lift
- Timeline polish and reminder ergonomics.
- Optional calendar integration behind clear user consent.
- Prepare multi-account support boundaries and isolation model.

## Non-Functional Requirements

- **Privacy/Security:** least-privilege OAuth scopes, Keychain token storage, local-first processing.
- **Performance:** async/await, batched sync, memory-safe debug flows, projection-based reads.
- **Reliability:** idempotent sync, retry strategy, offline usability for fetched obligations.
- **Explainability:** deterministic and reproducible decisions per policy version.

## Scope Discipline

OnDue is an obligation operating layer on top of email, not a full email client. Inbox features are secondary to obligation precision and execution.

