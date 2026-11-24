# GymOS Runbook

## Local database (dev/test)

Embedded PostgreSQL 16.16 via `@embedded-postgres/windows-x64` (no system install needed).

```bash
cd scripts && npm install && cd ..
node scripts/pg_cluster.mjs init      # once; data in .pgdata (gitignored)
node scripts/pg_cluster.mjs start     # 127.0.0.1:55432, trust auth, log pg.log
node scripts/pg_cluster.mjs status
node scripts/pg_cluster.mjs stop
```

Env overrides: `GYMOS_PGPORT`, `GYMOS_PGDATA`. The package ships no `psql`; use
`scripts/test_backend.py` (psycopg) or any PG client on port 55432.

## Running the acceptance suite

```bash
pip install "psycopg[binary]"
python scripts/test_backend.py
```

- Creates a **fresh database** (`gymos_test_<rand>`), re-applies ALL migrations in order,
  builds a two-gym fixture, runs 50 checks, drops the DB on success.
- On failure the DB is kept and named in the output for debugging.
- Auth simulation: `set_config('request.jwt.claims', '{"sub":<uuid>,"role":"authenticated"}')`
  + `SET ROLE authenticated`; service calls use `{"role":"service_role"}` + `SET ROLE service_role`.
- Concurrency checks use real threads with separate connections (12-way booking race,
  10-way wallet claim). Never replace these with sequential calls.

## Migrations

Files in `supabase/migrations/` are the source of truth; apply in filename order.
Each file is one transaction. On Supabase: `supabase db push`. 0001 creates the
Supabase-compatible roles (`anon`, `authenticated`, `service_role` BYPASSRLS) — on a real
Supabase project these already exist and 0001 is idempotent.

## Secrets

Copy `.env.example` → `.env`; never commit real values. Pilot-optional: Razorpay,
Interakt, FCM. `VAULT_MASTER_KEY` = `openssl rand -base64` (32 bytes, base64).
Log redaction must cover `authorization|api[_-]?key|secret|token|password|ciphertext`.

## Production deploy (when Supabase project exists — NOT done yet)

1. `supabase db push` then re-run full acceptance against the hosted DB.
2. Deploy edge functions (Phase 2): auth-session, razorpay-checkout, razorpay-webhook,
   notification-worker, member-import, admin-keys, sweeper.
3. Cron: notification-worker every 1 min; sweeper every 5 min (header `x-worker-secret`);
   SaaS billing runs inside sweeper on UTC day 1.
4. Razorpay dashboard: webhook URL + secret, events `payment.captured/failed`,
   `refund.created/processed`; Route linked account per gym (KYC) stored via `update_gym`.
5. Web on Vercel (Phase 3). Backups + PITR on. Alert on `webhook_events.status='failed'`
   and outbox dead-letter count.

## Known limitations (current)

- No Supabase project / Firebase / Razorpay / Interakt / FCM credentials yet: all provider
  integrations are schema + function logic only, **not run end-to-end**.
- Static QR check-in (rotating token is v1.1).
- UPI AutoPay, freeze UI, PT slot UI, POS/lockers/expenses/payroll are backlog (flags reserved).
- `payments` has no branch column: branch-scoped staff see gym-wide payments (by design);
  users/classes/sessions/bookings/check-ins/slots are branch-scoped.
- SaaS billing counts memberships with `status='active'` covering month-end; expiry is
  enforced at read time (dues view, booking/check-in gates), not by a status-flip job yet.