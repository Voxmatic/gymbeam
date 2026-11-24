# GymOS

Multi-tenant gym-management SaaS for the Indian market. One backend, three apps:
Flutter member app (white-labeled per gym), Next.js admin web (gym + super-admin areas),
Supabase-style Postgres 16 backend with row-level security.

## Status

- **Phase 1 — Database: COMPLETE.** 8 migrations, 40+ `app.*` SECURITY DEFINER functions,
  RLS on every tenant table, 50/50 acceptance checks green on real PostgreSQL 16
  (including a 12-way real-thread booking race and 10 concurrent wallet claimers).
- Phase 2 — Deno Edge Functions: not started.
- Phase 3 — Next.js admin web: not started.
- Phase 4 — Flutter member app: not started.
- Phase 5 — AI trainer: not started.

## Repo layout

```
supabase/migrations/   0001 bootstrap (roles/schemas) → 0009 pilot mode
scripts/pg_cluster.mjs local PG16 cluster (embedded-postgres, port 55432)
scripts/test_backend.py Phase 1 acceptance suite (fresh DB every run)
.env.example           all env vars; pilot-optional ones marked
```

## Quick start (local dev)

```bash
cd scripts && npm install && cd ..
node scripts/pg_cluster.mjs init
node scripts/pg_cluster.mjs start
pip install "psycopg[binary]"
python scripts/test_backend.py     # creates fresh DB, applies all migrations, runs 50 checks
node scripts/pg_cluster.mjs stop
```

## Design invariants

- Money is integer **paise**; GST-inclusive prices (`taxable + gst = amount`, DB-enforced).
- Every tenant row carries `gym_id`; cross-table FKs are **composite `(id, gym_id)`** so the
  database itself rejects cross-gym links.
- `authenticated` role is **SELECT-only** under RLS; all writes go through vetted
  `app.*` SECURITY DEFINER functions with `SET search_path = app, public`.
- Authorization helpers use **positive `exists()` checks** (NULL-safe); staff checks always
  include the role; branch-scoped staff see only their branch.
- Payments are replay-safe (`provider_payment_id UNIQUE`, re-select on conflict).
- `audit_log` is append-only (trigger + revokes); never stores secrets or health notes.
- Provider keys live encrypted in `provider_keys`; **no API-role access at all** —
  service-role edge functions fetch them; super admin sees metadata only.

## Pilot mode (current defaults)

- Counter payments (cash / UPI-verified / card) via `app.record_payment`; Razorpay online
  flow is fully built and unit-tested but activates only when real `rzp_test_`/`rzp_live_`
  keys exist. A `razorpay.me` payment-page link is NOT an API key; it can be surfaced in
  `gyms.settings` as a stopgap.
- WhatsApp (`whatsapp_enabled`) defaults OFF; reminders fall back to push/in-app.
- Without FCM credentials, push rows stay visible in the member's in-app feed.

See `RUNBOOK.md` for operations and `DECISIONS.md` for locked product decisions and
known limitations.