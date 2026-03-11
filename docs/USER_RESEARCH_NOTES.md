# Utility App Behavior Constraints (OnDue)

## Scope

Technical constraints derived from repeated utility-app usage patterns.  
Use this file as a validation checklist for feature proposals and UX changes.

## Behavioral Constraints and Checks

### 1) First-session value must be immediate

Constraint:

- first run must produce either actionable output or explicit "all clear" confidence.

Checks:

- time-to-understand-value <= 2 minutes for first-time user.
- at least one meaningful decision path available on day 0.

### 2) Decision friction must stay low

Constraint:

- cards should resolve in 1-2 actions.

Checks:

- median card-to-decision latency <= 10 seconds.
- no required multi-step setup before acting on a surfaced item.

### 3) Signal volume must be bounded

Constraint:

- rank and cap surfaced items by consequence and confidence.

Checks:

- default daily queue target: 3-5 items.
- high-noise categories are suppressed or batched by default.

### 4) Explanations and correction paths are mandatory

Constraint:

- prioritized items must include "why shown" and quick correction/undo.

Checks:

- all priority cards expose explanation string.
- all destructive/confirming actions expose undo window.

### 5) Session model must be short and terminal

Constraint:

- optimize for short completion sessions, not browsing.

Checks:

- explicit completion state (`You're clear`) exists in daily flow.
- no default infinite-scrolling feeds in primary surfaces.

### 6) Time-in-app is not a success metric

Constraint:

- prioritize resolved outcomes over engagement duration.

Checks:

- improvements evaluated against completion and prevented-miss metrics, not session length growth.

## Feature Priority Heuristic

Order by expected user impact:

1. expected-event checks,
2. near-term timeline grouping,
3. deterministic personalization,
4. quick capture + clarify-later,
5. trust features such as departure checklist.

## Platform Boundary Constraint

- OnDue: prevention, prioritization, follow-through.
- Apple system tools: object-location retrieval and platform-native lookup.

Practical rule:

- location lookup requests hand off to Find My;
- pre-departure prevention remains in OnDue.

## Required Metrics

Primary:

- prevented misses per active user per month.

Supporting:

- action completion within 24h,
- median time to clear daily queue,
- scan-finding promotion rate into daily flow,
- false-positive suppression trend.

## Reject Conditions (Feature Review)

Reject or defer proposals that:

- add new top-level IA complexity without improving completion,
- increase non-critical notification volume,
- require backend complexity for core value loop,
- optimize time-spent over resolved outcomes.

