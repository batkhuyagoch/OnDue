# OnDue Documentation

All product/architecture/process documentation lives in this folder.

## Read First

1. `PRODUCT_ARCHITECTURE_V2.md` - system intent and architecture boundaries
2. `IMPLEMENTATION_ROADMAP.md` - current execution state and next milestones
3. `USER_EXPERIENCE_GUIDE.md` - UX behavior and user-facing flows
4. `FOUNDER_INVESTOR_ONE_PAGER.md` - external narrative and positioning
5. `reports/README.md` - generated reliability and drift artifact conventions
6. `APP_STORE_CHECKLIST.md` - submission and privacy readiness checklist

## Documentation Standards

- Keep root `README.md` short (onboarding + links only).
- Keep long-form docs in `Docs/` only.
- Update docs in the same PR when behavior/architecture changes.
- Prefer one source of truth per topic (avoid duplicate strategy docs).
- Add important technical decisions as ADRs under `Docs/adr/`.

## Naming and Placement Rules

- Major canonical docs: `UPPER_SNAKE_CASE.md`.
- ADR records: `Docs/adr/ADR-XXXX-<kebab-topic>.md`.
- Do not place product/strategy docs under code folders.

## Maintenance Checklist

When shipping a substantial change, check:

- Architecture impact reflected in `PRODUCT_ARCHITECTURE_V2.md`
- Scope/status reflected in `IMPLEMENTATION_ROADMAP.md`
- UX changes reflected in `USER_EXPERIENCE_GUIDE.md`
- External messaging impact reflected in `FOUNDER_INVESTOR_ONE_PAGER.md` (if needed)
