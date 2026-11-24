# GymOS — Locked Decisions & Engineering Notes

Product decisions below are founder-locked (from the master build prompt); do not change
them without the founder. Engineering notes record what Phase 1 testing actually caught.

## Locked product decisions

- **Money flow:** Razorpay Route; each gym has its own linked account; platform never holds
  gym money. Platform revenue = per-member monthly SaaS: distinct members with an active
  membership at month end × `gyms.price_per_member_paise`, idempotent per (gym, period).
- **Payments:** online (Razorpay) + counter (cash / UPI-verified / card) recorded by staff.
- **GST:** optional per gym; `gst_enabled ⇒ gstin length 15` (DB constraint + format check).
  Prices GST-inclusive; `taxable_paise + gst_paise = amount_paise` (DB constraint), default 18%.
- **Auth:** Firebase phone OTP + Google; first login links Firebase uid to the pre-created
  row by VERIFIED phone (oldest active unlinked match). No uninvited self-signup.
- **Roles:** super_admin (no gym), owner, manager, receptionist, trainer (permission only,
  no UI), member. Branch-scoped managers (`users.branch_id`) see only their branch;
  NULL = gym-wide.
- **Roster:** group classes (capacity + waitlist + auto-promotion + cutoff + no-show),
  open-gym crowd slots (low <50% / medium <85% / high ≥85%), PT packages (schema now, UI v1.1).
- **Check-in:** member QR scanned by staff; manual fallback; no hardware in v1.
- **Consent:** versioned waiver + PAR-Q + DPDP data consent; optional `require_consent` gate.
- **Notifications:** push + in-app always; WhatsApp via Interakt (3 free/member/month, then
  gym credit packs; wallet reserve → capture/release). SMS = Firebase OTP only, no DLT.
- **Languages:** en + hi; locale columns; extensible templates.
- **AI trainer:** on-device only; SigLIP2 classifier is a suggestion layer, not a dependency;
  pose engine (BlazePose/ML Kit) + joint-angle state machines is the core; separately paid
  add-on gated by super admin (flag + ai_addon plans + entitlements).
- **Pilot defaults:** counter payments (payment-page link is NOT API keys); WhatsApp OFF;
  FCM optional (in-app feed fallback); collections-first front-desk admin UX.
- **Licensing:** no code/assets from InlitX/GymMane (GPL-3.0); feature checklist only.

## Phase 1 engineering notes — bugs testing caught (all fixed)

1. **Member-policy RLS leak:** `my_gym()`-based "member select" policies also matched staff,
   so branch-scoped managers could read other branches' classes via the member policy.
   Fix: `app.my_gym()` returns a gym only for `role='member'`.
2. **Cross-role nested call:** `cancel_booking` (member context) called service-only
   `enqueue_notification` → SERVICE_ONLY. Fix: inline the outbox insert in `cancel_booking`.
3. **Enum cast:** `payment_purpose::plan_kind` is not a valid cast → compare `::text`.
4. **RETURNS TABLE ambiguity:** `claim_outbox` OUT column `id` collided with the table
   column in UPDATEs → renamed OUT columns (`out_*`).
5. **Enum CASE insert:** CASE over a record field yields text; inserting into
   `wallet_ledger.kind` needs `::wallet_ledger_kind`.
6. **PUBLIC execute grant:** revoking EXECUTE from `authenticated` alone is ineffective —
   functions grant EXECUTE to PUBLIC by default. Service-only functions now revoke from
   PUBLIC too (defense in depth on top of the internal `require_service()` check).

## Test-harness lessons (not product bugs)

- psycopg3 sends Python dicts as `json`; functions take `jsonb` → use `Jsonb()`.
- `%` in LIKE literals must be `%%` in parameterized queries.
- jsonb RPC results are strings; compare against `str(uuid)`, not `UUID` objects.
- A swept (recovered) outbox row is legitimately re-claimable; complete it before starting
  an isolated concurrency scenario.
- Fixture collisions: billing/overdue assertions must compute expected counts dynamically
  or use dedicated members, because earlier tests create overlapping memberships.

## Security pitfalls permanently guarded against

NULL-permission bypass (positive exists only) · FOUND overwrite (capture immediately) ·
E.164 regex over-escaping (single backslash in SQL) · role-less staff RLS (staff_gym/branch_ok
always check role) · branch default hacks (nullable branch_id + composite FK).