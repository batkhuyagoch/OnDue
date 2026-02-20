# Reports

This directory stores generated reliability and drift evidence artifacts.

## Weekly Mutation Artifact

The mutation replay pipeline writes a weekly markdown summary that includes:

- baseline and candidate policy versions
- dataset identifiers and mutation seed
- trust-gate pass/fail + warning outcomes
- top hypothesis deltas
- top reason-code shifts
- runtime deltas (memory and latency)

Suggested naming:

- `mutation-weekly-YYYY-MM-DD.md`

Keep generated artifacts versioned in this directory to support policy drift audits.
