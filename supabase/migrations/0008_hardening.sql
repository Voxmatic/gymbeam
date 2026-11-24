-- GymOS 0008 — hardening: append-only audit, GSTIN format, defense-in-depth revokes, FK indexes.
begin;

alter table public.gyms add constraint gyms_gstin_format
  check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$');

create function app.deny_mutation() returns trigger
language plpgsql set search_path = app, public as $$
begin
  raise exception 'APPEND_ONLY' using errcode = '42501';
end;
$$;

create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function app.deny_mutation();
revoke insert, update, delete on public.audit_log from anon, authenticated, service_role;

-- Defense in depth: API roles never write tables directly (RLS already denies; revoke GRANTs too).
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;

-- Service-only functions are not callable by API roles at all.
-- Functions grant EXECUTE to PUBLIC by default; revoke both PUBLIC and the API roles.
revoke execute on function app.require_service() from public, anon, authenticated;
revoke execute on function app.link_firebase_identity(text, text, text) from public, anon, authenticated;
revoke execute on function app.wallet_purchase(uuid, integer, uuid, uuid) from public, anon, authenticated;
revoke execute on function app.wallet_reserve(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function app.wallet_capture(uuid) from public, anon, authenticated;
revoke execute on function app.wallet_release(uuid) from public, anon, authenticated;
revoke execute on function app.get_provider_key(uuid, text) from public, anon, authenticated;
revoke execute on function app.check_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke execute on function app.attach_order(uuid, text) from public, anon, authenticated;
revoke execute on function app.mark_intent_failed(uuid) from public, anon, authenticated;
revoke execute on function app.register_webhook_event(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function app.mark_webhook_event(text, text, public.webhook_status, text) from public, anon, authenticated;
revoke execute on function app.apply_razorpay_payment(jsonb) from public, anon, authenticated;
revoke execute on function app.list_pending_transfers(integer) from public, anon, authenticated;
revoke execute on function app.mark_transfer(uuid, boolean, text, text) from public, anon, authenticated;
revoke execute on function app.enqueue_notification(uuid, uuid, public.outbox_channel, text, text, jsonb, text) from public, anon, authenticated;
revoke execute on function app.claim_outbox(integer) from public, anon, authenticated;
revoke execute on function app.complete_outbox(uuid, boolean, boolean, text, text) from public, anon, authenticated;
revoke execute on function app.sweep_outbox() from public, anon, authenticated;
revoke execute on function app.outbox_provider_failed(text) from public, anon, authenticated;
revoke execute on function app.generate_payment_reminders(integer) from public, anon, authenticated;

create index payments_member_idx on public.payments (member_id);
create index payments_gym_created_idx on public.payments (gym_id, created_at desc);
create index memberships_plan_idx on public.memberships (plan_id);
create index bookings_member_idx on public.bookings (member_id);
create index class_sessions_class_idx on public.class_sessions (class_id);
create index check_ins_member_idx on public.check_ins (member_id);
create index slot_bookings_member_idx on public.slot_bookings (member_id);
create index notification_outbox_member_idx on public.notification_outbox (member_id, created_at desc);

commit;