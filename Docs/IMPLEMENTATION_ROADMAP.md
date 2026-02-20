# OnDue Implementation Roadmap
## Policy-Driven, Trust-First Execution Plan

---

## Current Status (Updated)

### Implemented Core

- Gmail integration and incremental sync are active (OAuth, batching, history handling, date windows).
- GRDB persistence and projection-backed UI read models are active.
- Policy-driven extraction is active with canonical `DecisionContract`:
  - `outcome`, `primaryHypothesisId`, `reasonCode`, `reasonText`, `evidence`, `policyVersion`.
- Canonical reason taxonomy is wired across engine, digest UI, and labeling options.
- Year-scan is migrated to hypothesis-based logic (high-precision profile).
- Feedback context and calibration storage is active (hypothesis/context-aware review tuning).
- Gold dataset export/import + labeling surfaces are active.
- Policy replay and policy diff reporting are active in tests and DEBUG UI.
- Digest interaction flow is consolidated (confirm/done/dismiss/snooze/block actions).

### Recent Stabilization Work

- Fixed sender/domain block action matching (case/trim normalization in dismissal path).
- Fixed “Show full message” edge cases in detail view.
- Added DEBUG filter diagnostics (row + detail) for include/exclude reasoning.
- Reduced debug-memory pressure:
  - policy diff now streams comparisons,
  - labeling no longer auto-saves full dataset on every tap.
- Added unsaved-change indicator in labeling flow.
- Added shared dataset selection across Label and Policy Diff DEBUG tabs.
- Fixed SwiftUI publish-during-view-update warning in digest error flow.

---

## Decision Principles (Non-Negotiable)

- Precision over recall in auto-accept path.
- Strict reject over permissive review when uncertain.
- Global blockers always hard-veto.
- UI renders canonical decision contract, not ad-hoc signal text.
- Policy updates require replay + diff evidence before merge.

---

## Release Gates (Must Pass)

- No urgency-only/date-only acceptance.
- Blocker leak checks pass.
- Reason/hypothesis/outcome coherence holds across engine, digest UI, and label UI.
- Shipping preference behavior remains consistent with delivery-action override.
- Policy diff report generated for baseline vs candidate on representative samples.
- Gold dataset regression remains within precision/review guardrails.

---

## Execution Roadmap

### Phase A - Reliability & Coherence (In Progress)

Goal: eliminate trust-breaking inconsistencies in production behavior.

- [x] Canonical decision contract persisted and projected.
- [x] Canonical reason taxonomy wired to digest and label flows.
- [x] Delivery/appointment/account verification mappings corrected in UI consumption.
- [x] DEBUG policy diff in app with copy/export.
- [x] Shared dataset selection between policy tools.
- [x] Sender/domain suppression flow fixes.
- [x] Full-message display robustness fixes.
- [ ] Add integration tests for block sender/domain + post-sync suppression behavior.
- [ ] Add policy-tool UX polish (clear run state, last-run metadata, failure affordances).

### Phase B - Evaluation Discipline (Next)

Goal: make policy changes safe, explainable, and repeatable.

- [ ] Expand gold dataset coverage by hypothesis class and edge-case templates.
- [ ] Add per-hypothesis confusion summaries in CI test logs.
- [ ] Add blocker bypass and review-explosion guardrail tests.
- [ ] Version and archive policy diff artifacts for each policy change.

### Phase C - Product Experience Lift (Next 30-60 days)

Goal: improve activation and everyday utility without increasing false positives.

- [ ] Timeline/weekly plan polish and navigation integration quality checks.
- [ ] Daily digest workflow tightening (fewer taps, clearer intent labels).
- [ ] Better due-date extraction quality pass (relative date phrase handling).
- [ ] Onboarding copy focused on trust-first behavior and explainability.

### Phase D - Platform Expansion (60-90 days)

Goal: broaden utility behind strict quality gates.

- [ ] Notification preference surface (digest/reminder controls).
- [ ] Optional calendar integration (EventKit) behind explicit user control.
- [ ] Recurring-obligation detection experiments (disabled by default until stable).
- [ ] Multi-account UX hardening and isolation checks.

---

## Testing Strategy (Current + Planned)

### Current

- Rule engine policy replay tests.
- Policy validator tests (reason coverage and alignment).
- Candidate selector behavior tests.
- Digest filter matrix tests.

### Planned Additions

- [ ] Block sender/domain integration tests (repository + projection + selector path).
- [ ] Labeling flow state tests (dataset switching, unsaved state, save/import round-trip).
- [ ] Policy diff UI behavior tests (dataset selection and report generation smoke).

---

## Operating Metrics

Track locally first; prepare dashboard-ready schema:

- Per-hypothesis counters: fired, blocked, review, accepted.
- Review ratio trend by policy version.
- False-positive correction rate (dismiss after accept/review).
- Mapping coherence audit count (reason/hypothesis mismatch rate).

---

## Risks and Mitigations

- **Risk:** policy changes silently shift behavior.
  - **Mitigation:** enforce replay + diff artifacts and explicit policy versioning.

- **Risk:** debug tooling performance/memory impacts dev velocity.
  - **Mitigation:** streamed comparisons, explicit save flow, bounded preview payloads.

- **Risk:** UI regressions from duplicated mapping logic.
  - **Mitigation:** centralize reason mapping helpers and test expected chip labels.

---

## Immediate Next 2 Weeks

1. Add integration tests for suppression and projection consistency.
2. Strengthen gold dataset cases for delivery/account/legal edge scenarios.
3. Add policy diff run metadata (`dataset`, `policy versions`, `timestamp`) in debug UI.
4. Add one-click “re-run after save” flow in policy tools.
5. Prepare a release checklist document tied to gates above.

---

## Document Links

- Product architecture: `Docs/PRODUCT_ARCHITECTURE_V2.md`
- UX guidance: `Docs/USER_EXPERIENCE_GUIDE.md`
- Founder/investor summary: `Docs/FOUNDER_INVESTOR_ONE_PAGER.md`

---

**Last Updated**: Feb 2026  
**Project**: OnDue Email Action Sidekick  
**Status**: Active implementation with policy-driven foundation in place
