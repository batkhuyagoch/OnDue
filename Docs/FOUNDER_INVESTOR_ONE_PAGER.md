# OnDue - Founder / Investor One-Pager

## What OnDue Is

OnDue is an obligation operating system for email.  
It extracts only actionable commitments (payments, renewals, verification steps, legal/compliance tasks, appointment actions) and turns them into a clean execution plan.

OnDue does **not** replace Gmail. It sits on top as a personal sidekick for follow-through.

## Why Now

- Email volume keeps rising while attention bandwidth does not.
- Critical obligations are buried among promos, newsletters, and pseudo-urgent noise.
- AI assistants are common, but trust in opaque decisions is low for high-stakes tasks.
- Users need fewer decisions, not another inbox workflow.

## The Problem

People miss deadlines and required actions because:
- obligations are fragmented across inbox threads,
- marketing mimics urgency,
- reminder burden is held in working memory.

The cost is missed payments, lapsed policies, delayed paperwork, and persistent cognitive overhead.

## Our Solution

OnDue uses a deterministic, explainable policy engine to classify each message into:
- `accept` (action needed),
- `needsReview` (borderline),
- `reject` (noise/non-actionable).

Every result includes explicit rationale (`hypothesis`, `reasonCode`, `reasonText`, `evidence`) so users can trust and correct decisions quickly.

## Product Wedge

The initial wedge is high-signal obligations:
- billing and payments,
- insurance and renewals,
- identity/account verification,
- delivery actions,
- legal/compliance response windows.

Users get a weekly action view and lightweight digest of borderline items for calibration.

## Why We Win (Moat)

- **Trust moat:** deterministic, versioned policy decisions with human-readable reasons.
- **Data moat:** structured feedback tied to hypotheses and context, not generic thumbs-up/down.
- **Evaluation moat:** policy replay + diff + regression harness before rollout.
- **UX moat:** single operational surface focused on action completion, not inbox triage.

## Business Model (Initial)

- Free tier: single account, core extraction, digest, timeline.
- Pro tier:
  - multi-account support,
  - richer extraction and automation,
  - advanced reminders/calendar workflows,
  - premium policy intelligence packs.

## Go-To-Market (Early)

- ICP: professionals and households managing recurring obligations.
- Channel: App Store + creator-led “life systems / productivity / ADHD workflow” communities.
- Hook: “Never miss a real obligation hidden in email again.”

## Metrics That Matter

- Weekly Active Users with completed obligations.
- Precision of accepted obligations.
- Review burden (needsReview ratio).
- Time-to-action from detection to completion.
- False positive/negative trend by hypothesis class.

## Current Status

OnDue already has:
- Gmail ingest and extraction pipeline,
- policy-driven decision contract,
- canonical reason taxonomy across engine + UI,
- feedback loop for review calibration,
- policy diff tooling and gold dataset replay tests.

## 12-Month Vision

Become the default “obligation layer” for digital life:
- email as input,
- obligations as structured objects,
- timeline/reminders as execution loop,
- trusted assistant behavior through transparent, testable policy evolution.

## Ask / Next Milestones

Near-term milestones:
- strengthen policy coverage and regression gates,
- improve onboarding and first-week activation,
- scale high-precision extraction for recurring real-world obligation classes.

Ideal support:
- distribution partners for productivity/life-admin audiences,
- strategic input on retention loops and premium packaging,
- focused capital to accelerate product polish and growth experiments.

