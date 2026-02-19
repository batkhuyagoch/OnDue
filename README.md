# OnDue (SwiftUI)

Local-first obligation digest app. V1 focuses on a daily/when-opened
digest of obligations pulled from Gmail, with optional light background
refresh (best-effort).

## Goals (MVP)
- Read-only Gmail connect (last 14-30 days only)
- High-precision obligation extraction (deadlines/requests/appointments)
- Digest UI: This Week / Upcoming / Waiting On (top 10 total)
- Actions: Create task (local), Snooze, Ignore forever
- Transparent evidence lines for trust

## Architecture
- SwiftUI UI layer
- SQLite + FTS5 for local search (placeholder scaffolding)
- Services for Gmail auth/sync, extraction, and background refresh
- Local-first repositories

This repo contains a lightweight SwiftUI structure intended to be opened
in Xcode and wired to actual frameworks (SQLite/GRDB, OAuth, background
refresh) as the next step.

## Documentation
- Project docs are centralized in `Docs/`.
- Start with `Docs/README.md`.
- Architecture decisions live in `Docs/adr/`.
- App submission readiness checklist lives in `Docs/APP_STORE_CHECKLIST.md`.
