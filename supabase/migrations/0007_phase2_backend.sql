-- GymOS 0007 — phase-2 backend: payment intents, webhooks, notification outbox, Route transfers, imports, devices, rate limits.
begin;

create type public.intent_status as enum ('created','paid','failed','expired');
create type public.webhook_status as enum ('received','processed','failed');
create type public.outbox_channel as enum ('push','whatsapp');
create type public.outbox_status as enum ('pending','sending','sent','dead');
create type public.transfer_status as enum ('pending','created','failed','reversed');

create table public.payment_intents (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  purpose public.payment_purpose not null,
  plan_id uuid,
  pack_code text,
  wallet_credits integer,
  amount_paise bigint not null check (amount_paise > 0),
  currency text not null default 'INR' check (currency = 'INR'),
  receipt text not null unique,
  provider_order_id text unique,
  status public.intent_status not null default 'created',
  payment_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint payment_intents_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id),
  constraint payment_intents_plan_fk foreign key (plan_id, gym_id)
    references public.membership_plans (id, gym_id),
  constraint payment_intents_payment_fk foreign key (payment_id, gym_id)
    references public.payments (id, gym_id),
  constraint payment_intents_target check (
    (purpose in ('membership','ai_addon') and plan_id is not null)
    or (purpose = 'wallet_topup' and pack_code is not null)
    or purpose = 'saas')
);

create table public.webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  event_id text not null,
  event_type text not null,
  payload jsonb not null,
  status public.webhook_status not null default 'received',
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, event_id)
);

create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  channel public.outbox_channel not null,
  template_key text not null,
  locale text not null default 'en' check (locale in ('en','hi')),
  payload jsonb not null default '{}',
  dedupe_key text not null unique,
  status public.outbox_status not null default 'pending',
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  wallet_reservation text check (wallet_reservation in ('free','credit')),
  reservation_id uuid,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint notification_outbox_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);
create index outbox_claim_idx on public.notification_outbox (status, next_attempt_at);

create table public.route_transfers (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  payment_id uuid not null unique,
  linked_account_id text not null,
  amount_paise bigint not null check (amount_paise > 0),
  status public.transfer_status not null default 'pending',
  provider_transfer_id text unique,
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint route_transfers_payment_fk foreign key (payment_id, gym_id)
    references public.payments (id, gym_id)
);

create table public.import_jobs (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  created_by uuid,
  total integer not null default 0,
  inserted integer not null default 0,
  duplicates integer not null default 0,
  invalid integer not null default 0,
  report jsonb not null default '[]',
  created_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint import_jobs_actor_fk foreign key (created_by, gym_id)
    references public.users (id, gym_id)
);

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  user_id uuid not null,
  token text not null unique,
  platform text not null check (platform in ('android','ios','web')),
  created_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint device_tokens_user_fk foreign key (user_id, gym_id)
    references public.users (id, gym_id)
);

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (key, window_start)
);

create function app.check_rate_limit(p_key text, p_limit integer, p_window_seconds integer) returns boolean
language plpgsql security definer set search_path = app, public as $$
declare
  v_window timestamptz;
  v_count integer;
begin
  perform app.require_service();
  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits (key, window_start, count) values (p_key, v_window, 1)
  on conflict (key, window_start) do update set count = rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_limit;
end;
$$;

create function app.register_device(p_actor uuid, p_token text, p_platform text) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_gym uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  select u.gym_id into v_gym from public.users u where u.id = v_actor and u.status = 'active';
  if v_gym is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  delete from public.device_tokens where token = p_token;
  insert into public.device_tokens (gym_id, user_id, token, platform)
  values (v_gym, v_actor, p_token, p_platform);
end;
$$;

create function app.create_payment_intent(p_gym uuid, p_actor uuid, p_member uuid,
  p_purpose public.payment_purpose, p_plan uuid default null, p_pack_code text default null) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_amount bigint;
  v_credits integer;
  v_existing record;
  v_id uuid;
  v_receipt text;
  v_order text;
begin
  v_actor := app.resolve_actor(p_actor);
  if v_actor <> p_member then
    perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist']);
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_member and u.gym_id = p_gym and u.status = 'active' and u.role = 'member'
  ) then
    raise exception 'MEMBER_NOT_IN_GYM' using errcode = '22023';
  end if;
  if p_purpose in ('membership','ai_addon') then
    select pl.price_paise into v_amount from public.membership_plans pl
      where pl.id = p_plan and pl.gym_id = p_gym and pl.active and pl.kind::text = p_purpose::text;
    if not found then
      raise exception 'PLAN_INVALID' using errcode = '22023';
    end if;
  elsif p_purpose = 'wallet_topup' then
    select wp.price_paise, wp.credits into v_amount, v_credits from public.wallet_packs wp where wp.code = p_pack_code;
    if not found then
      raise exception 'PACK_INVALID' using errcode = '22023';
    end if;
  else
    raise exception 'PURPOSE_INVALID' using errcode = '22023';
  end if;
  select pi.* into v_existing from public.payment_intents pi
    where pi.member_id = p_member and pi.purpose = p_purpose and pi.status = 'created'
      and pi.plan_id is not distinct from p_plan and pi.pack_code is not distinct from p_pack_code
      and pi.created_at > now() - interval '15 minutes'
    order by pi.created_at desc limit 1;
  if found then
    return jsonb_build_object('intent_id', v_existing.id, 'amount_paise', v_existing.amount_paise,
      'currency', v_existing.currency, 'receipt', v_existing.receipt,
      'provider_order_id', v_existing.provider_order_id, 'reused', true);
  end if;
  v_receipt := 'rcpt_' || replace(gen_random_uuid()::text, '-', '');
  insert into public.payment_intents (gym_id, member_id, purpose, plan_id, pack_code, wallet_credits, amount_paise, receipt)
  values (p_gym, p_member, p_purpose, p_plan, p_pack_code, v_credits, v_amount, v_receipt)
  returning id into v_id;
  return jsonb_build_object('intent_id', v_id, 'amount_paise', v_amount, 'currency', 'INR',
    'receipt', v_receipt, 'provider_order_id', null, 'reused', false);
end;
$$;

create function app.attach_order(p_intent uuid, p_order_id text) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  perform app.require_service();
  update public.payment_intents set provider_order_id = p_order_id, updated_at = now()
    where id = p_intent and status = 'created';
  if not found then
    raise exception 'INTENT_NOT_OPEN' using errcode = '22023';
  end if;
end;
$$;

create function app.mark_intent_failed(p_intent uuid) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  perform app.require_service();
  update public.payment_intents set status = 'failed', updated_at = now()
    where id = p_intent and status = 'created';
end;
$$;

create function app.register_webhook_event(p_provider text, p_event_id text, p_event_type text, p_payload jsonb) returns boolean
language plpgsql security definer set search_path = app, public as $$
declare
  v_id uuid;
begin
  perform app.require_service();
  insert into public.webhook_events (provider, event_id, event_type, payload)
  values (p_provider, p_event_id, p_event_type, p_payload)
  on conflict (provider, event_id) do nothing
  returning id into v_id;
  return v_id is not null;
end;
$$;

create function app.mark_webhook_event(p_provider text, p_event_id text,
  p_status public.webhook_status, p_error text default null) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  perform app.require_service();
  update public.webhook_events
    set status = p_status, attempts = attempts + 1, last_error = p_error,
        processed_at = case when p_status = 'processed' then now() else processed_at end
    where provider = p_provider and event_id = p_event_id;
end;
$$;

create function app.apply_razorpay_payment(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_entity jsonb;
  v_order text;
  v_pay_id text;
  v_amount bigint;
  v_currency text;
  v_intent record;
  v_gym record;
  v_plan record;
  v_payment uuid;
  v_rate numeric;
begin
  perform app.require_service();
  v_entity := p_payload->'payload'->'payment'->'entity';
  if v_entity is null then
    raise exception 'PAYLOAD_INVALID' using errcode = '22023';
  end if;
  if v_entity->>'status' is distinct from 'captured' then
    return jsonb_build_object('ignored', 'not_captured');
  end if;
  v_order := v_entity->>'order_id';
  v_pay_id := v_entity->>'id';
  v_amount := (v_entity->>'amount')::bigint;
  v_currency := v_entity->>'currency';
  select pi.* into v_intent from public.payment_intents pi where pi.provider_order_id = v_order;
  if not found then
    perform app.audit(null, null, 'webhook.unknown_order', 'webhook_events', null,
      jsonb_build_object('order_id', v_order, 'provider_payment_id', v_pay_id));
    return jsonb_build_object('ignored', 'unknown_order');
  end if;
  if v_intent.status = 'paid' then
    return jsonb_build_object('already_paid', true);
  end if;
  if v_amount <> v_intent.amount_paise or v_currency is distinct from v_intent.currency then
    raise exception 'AMOUNT_MISMATCH' using errcode = '22023';
  end if;
  v_rate := null;
  if v_intent.plan_id is not null then
    select pl.gst_rate into v_rate from public.membership_plans pl where pl.id = v_intent.plan_id;
  end if;
  v_payment := app.record_payment(v_intent.gym_id, v_intent.member_id, v_intent.member_id,
    v_intent.purpose, v_amount, 'razorpay', v_pay_id, v_order, v_rate);
  if v_intent.purpose = 'membership' then
    perform app.renew_membership(v_intent.gym_id, v_intent.member_id, v_intent.member_id,
      v_intent.plan_id, null, v_payment);
  elsif v_intent.purpose = 'ai_addon' then
    select pl.* into v_plan from public.membership_plans pl where pl.id = v_intent.plan_id;
    insert into public.ai_entitlements (gym_id, member_id, starts_on, ends_on, payment_id)
    values (v_intent.gym_id, v_intent.member_id, current_date, current_date + v_plan.duration_days - 1, v_payment)
    on conflict (member_id, payment_id) do nothing;
  elsif v_intent.purpose = 'wallet_topup' then
    perform app.wallet_purchase(v_intent.gym_id, v_intent.wallet_credits, v_intent.member_id, v_payment);
  end if;
  update public.payment_intents set status = 'paid', payment_id = v_payment, updated_at = now()
    where id = v_intent.id;
  select g.* into v_gym from public.gyms g where g.id = v_intent.gym_id;
  if v_gym.razorpay_linked_account_id is not null and v_intent.purpose in ('membership','ai_addon') then
    insert into public.route_transfers (gym_id, payment_id, linked_account_id, amount_paise)
    values (v_intent.gym_id, v_payment, v_gym.razorpay_linked_account_id, v_amount)
    on conflict (payment_id) do nothing;
  end if;
  perform app.audit(v_intent.gym_id, v_intent.member_id, 'payment.applied', 'payments', v_payment,
    jsonb_build_object('purpose', v_intent.purpose, 'amount_paise', v_amount));
  return jsonb_build_object('payment_id', v_payment, 'intent_id', v_intent.id, 'fulfilled', v_intent.purpose);
end;
$$;

create function app.list_pending_transfers(p_limit integer default 20)
returns table (id uuid, gym_id uuid, payment_id uuid, linked_account_id text, amount_paise bigint, attempts integer)
language sql stable security definer set search_path = app, public as $$
  select t.id, t.gym_id, t.payment_id, t.linked_account_id, t.amount_paise, t.attempts
  from public.route_transfers t
  where t.status = 'pending'
  order by t.created_at
  limit p_limit;
$$;

create function app.mark_transfer(p_transfer uuid, p_ok boolean,
  p_provider_transfer_id text default null, p_error text default null) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_attempts integer;
begin
  perform app.require_service();
  update public.route_transfers set attempts = attempts + 1, updated_at = now()
    where id = p_transfer returning attempts into v_attempts;
  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = '22023';
  end if;
  if p_ok then
    update public.route_transfers set status = 'created', provider_transfer_id = p_provider_transfer_id, last_error = null
      where id = p_transfer;
  elsif v_attempts >= 8 then
    update public.route_transfers set status = 'failed', last_error = p_error where id = p_transfer;
  else
    update public.route_transfers set status = 'pending', last_error = p_error where id = p_transfer;
  end if;
end;
$$;

create function app.enqueue_notification(p_gym uuid, p_member uuid, p_channel public.outbox_channel,
  p_template_key text, p_locale text, p_payload jsonb, p_dedupe_key text) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_id uuid;
begin
  perform app.require_service();
  insert into public.notification_outbox (gym_id, member_id, channel, template_key, locale, payload, dedupe_key)
  values (p_gym, p_member, p_channel, p_template_key, coalesce(p_locale, 'en'), coalesce(p_payload, '{}'), p_dedupe_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

create function app.claim_outbox(p_batch integer default 20)
returns table (out_id uuid, out_gym_id uuid, out_member_id uuid, out_channel public.outbox_channel,
  out_template_key text, out_locale text, out_payload jsonb, out_attempts integer,
  out_wallet_reservation text, out_reservation_id uuid)
language plpgsql security definer set search_path = app, public as $$
declare
  v_row record;
  v_res jsonb;
begin
  perform app.require_service();
  for v_row in
    select o.* from public.notification_outbox o
    where o.status = 'pending' and o.next_attempt_at <= now()
    order by o.next_attempt_at, o.created_at
    limit p_batch
    for update skip locked
  loop
    if v_row.channel = 'whatsapp' and v_row.reservation_id is null then
      begin
        v_res := app.wallet_reserve(v_row.gym_id, v_row.member_id, v_row.member_id);
      exception when sqlstate '22023' then
        if sqlerrm <> 'INSUFFICIENT_CREDITS' then
          raise;
        end if;
        update public.notification_outbox set status = 'dead', last_error = 'INSUFFICIENT_CREDITS', updated_at = now()
          where id = v_row.id;
        insert into public.notification_outbox (gym_id, member_id, channel, template_key, locale, payload, dedupe_key)
        values (v_row.gym_id, v_row.member_id, 'push', v_row.template_key, v_row.locale, v_row.payload,
          'fallback:' || v_row.dedupe_key)
        on conflict (dedupe_key) do nothing;
        continue;
      end;
      update public.notification_outbox
        set wallet_reservation = v_res->>'source', reservation_id = (v_res->>'reservation_id')::uuid
        where id = v_row.id;
    end if;
    update public.notification_outbox
      set status = 'sending', attempts = attempts + 1, locked_at = now(), updated_at = now()
      where id = v_row.id;
    return query
      select o.id, o.gym_id, o.member_id, o.channel, o.template_key, o.locale, o.payload,
        o.attempts, o.wallet_reservation, o.reservation_id
      from public.notification_outbox o where o.id = v_row.id;
  end loop;
end;
$$;

create function app.complete_outbox(p_outbox uuid, p_ok boolean, p_permanent boolean default false,
  p_error text default null, p_provider_message_id text default null) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_row record;
begin
  perform app.require_service();
  select o.* into v_row from public.notification_outbox o where o.id = p_outbox for update;
  if not found then
    raise exception 'OUTBOX_NOT_FOUND' using errcode = '22023';
  end if;
  if p_ok then
    update public.notification_outbox
      set status = 'sent', provider_message_id = p_provider_message_id, last_error = null, locked_at = null, updated_at = now()
      where id = p_outbox;
    if v_row.channel = 'whatsapp' and v_row.reservation_id is not null then
      perform app.wallet_capture(v_row.reservation_id);
    end if;
  elsif p_permanent or v_row.attempts >= 8 then
    update public.notification_outbox set status = 'dead', last_error = p_error, locked_at = null, updated_at = now()
      where id = p_outbox;
    if v_row.channel = 'whatsapp' and v_row.reservation_id is not null then
      perform app.wallet_release(v_row.reservation_id);
    end if;
  else
    update public.notification_outbox
      set status = 'pending', last_error = p_error, locked_at = null,
          next_attempt_at = now() + (least(60, power(2, v_row.attempts)::int) || ' minutes')::interval,
          updated_at = now()
      where id = p_outbox;
  end if;
end;
$$;

create function app.sweep_outbox() returns integer
language plpgsql security definer set search_path = app, public as $$
declare
  v_count integer;
begin
  perform app.require_service();
  update public.notification_outbox
    set status = 'pending', locked_at = null, updated_at = now()
    where status = 'sending' and locked_at < now() - interval '5 minutes';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create function app.outbox_provider_failed(p_provider_message_id text) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_row record;
begin
  perform app.require_service();
  select o.* into v_row from public.notification_outbox o
    where o.provider_message_id = p_provider_message_id and o.status = 'sent'
    order by o.updated_at desc limit 1;
  if not found then
    return;
  end if;
  update public.notification_outbox set status = 'dead', last_error = 'provider_delivery_failed', updated_at = now()
    where id = v_row.id;
  if v_row.channel = 'whatsapp' and v_row.reservation_id is not null then
    perform app.wallet_release(v_row.reservation_id);
  end if;
end;
$$;

create function app.book_class(p_session uuid, p_actor uuid default null) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_member record;
  v_sess record;
  v_existing record;
  v_reuse boolean;
  v_confirmed integer;
  v_waitlisted integer;
  v_flag boolean;
  v_status public.booking_status;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  select u.* into v_member from public.users u
    where u.id = v_actor and u.role = 'member' and u.status = 'active';
  if not found then
    raise exception 'MEMBERS_ONLY' using errcode = '42501';
  end if;
  select s.* into v_sess from public.class_sessions s where s.id = p_session for update;
  if not found then
    raise exception 'SESSION_NOT_FOUND' using errcode = '22023';
  end if;
  if v_member.gym_id is distinct from v_sess.gym_id then
    raise exception 'NOT_IN_GYM' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.member_id = v_actor and m.gym_id = v_sess.gym_id and m.status = 'active'
      and m.starts_on <= current_date and m.ends_on >= current_date
  ) then
    raise exception 'MEMBERSHIP_REQUIRED' using errcode = '22023';
  end if;
  select f.enabled into v_flag from public.feature_flags f
    where f.gym_id = v_sess.gym_id and f.flag = 'require_consent';
  if coalesce(v_flag, false) and not exists (
    select 1 from public.consents c
    where c.member_id = v_actor and c.gym_id = v_sess.gym_id and c.kind = 'data'
  ) then
    raise exception 'CONSENT_REQUIRED' using errcode = '42501';
  end if;
  select b.* into v_existing from public.bookings b
    where b.session_id = p_session and b.member_id = v_actor;
  v_reuse := found;
  if v_reuse and v_existing.status in ('confirmed','waitlisted') then
    raise exception 'ALREADY_BOOKED' using errcode = '22023';
  end if;
  select count(*) into v_confirmed from public.bookings b
    where b.session_id = p_session and b.status = 'confirmed';
  select count(*) into v_waitlisted from public.bookings b
    where b.session_id = p_session and b.status = 'waitlisted';
  if v_confirmed < v_sess.capacity then
    v_status := 'confirmed';
  elsif v_waitlisted < v_sess.waitlist_capacity then
    v_status := 'waitlisted';
  else
    raise exception 'SESSION_FULL' using errcode = '22023';
  end if;
  if v_reuse then
    update public.bookings set status = v_status, created_at = now()
      where id = v_existing.id returning id into v_id;
  else
    insert into public.bookings (gym_id, session_id, member_id, status)
    values (v_sess.gym_id, p_session, v_actor, v_status)
    returning id into v_id;
  end if;
  perform app.audit(v_sess.gym_id, v_actor, 'booking.created', 'bookings', v_id,
    jsonb_build_object('status', v_status));
  return jsonb_build_object('booking_id', v_id, 'status', v_status);
end;
$$;

create function app.cancel_booking(p_booking uuid, p_actor uuid default null) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_b record;
  v_sess record;
  v_is_staff boolean;
  v_promote record;
  v_promoted uuid;
  v_member record;
begin
  v_actor := app.resolve_actor(p_actor);
  select b.* into v_b from public.bookings b where b.id = p_booking for update;
  if not found then
    raise exception 'BOOKING_NOT_FOUND' using errcode = '22023';
  end if;
  select s.* into v_sess from public.class_sessions s where s.id = v_b.session_id for update;
  v_is_staff := app.staff_gym(v_b.gym_id) is not null;
  if not v_is_staff and v_b.member_id <> v_actor then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_b.status not in ('confirmed','waitlisted') then
    raise exception 'NOT_CANCELLABLE' using errcode = '22023';
  end if;
  if not v_is_staff and now() >= v_sess.starts_at - make_interval(mins => v_sess.cancel_cutoff_minutes) then
    raise exception 'CUTOFF_PASSED' using errcode = '22023';
  end if;
  update public.bookings set status = 'cancelled' where id = p_booking;
  if v_b.status = 'confirmed' then
    select b2.* into v_promote from public.bookings b2
      where b2.session_id = v_b.session_id and b2.status = 'waitlisted'
      order by b2.created_at, b2.id limit 1
      for update;
    if found then
      update public.bookings set status = 'confirmed' where id = v_promote.id;
      v_promoted := v_promote.id;
      select u.* into v_member from public.users u where u.id = v_promote.member_id;
      insert into public.notification_outbox (gym_id, member_id, channel, template_key, locale, payload, dedupe_key)
      values (v_b.gym_id, v_promote.member_id, 'push', 'waitlist_promoted', v_member.locale,
        jsonb_build_object('session_id', v_b.session_id), 'promoted:' || v_promote.id)
      on conflict (dedupe_key) do nothing;
    end if;
  end if;
  perform app.audit(v_b.gym_id, v_actor, 'booking.cancelled', 'bookings', p_booking,
    jsonb_build_object('promoted', v_promoted));
  return jsonb_build_object('cancelled', p_booking, 'promoted', v_promoted);
end;
$$;

create function app.generate_payment_reminders(p_days integer default 3) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_m record;
  v_channel public.outbox_channel;
  v_wa boolean;
  v_new_expiring integer := 0;
  v_new_overdue integer := 0;
  v_id uuid;
  v_payload jsonb;
begin
  perform app.require_service();
  for v_m in
    select m.member_id, m.gym_id, m.ends_on, u.locale, u.full_name, g.name as gym_name, pl.name as plan_name
    from public.memberships m
    join public.users u on u.id = m.member_id
    join public.gyms g on g.id = m.gym_id
    join public.membership_plans pl on pl.id = m.plan_id
    where m.status = 'active' and m.ends_on = current_date + p_days
  loop
    select f.enabled into v_wa from public.feature_flags f
      where f.gym_id = v_m.gym_id and f.flag = 'whatsapp_enabled';
    v_channel := case when coalesce(v_wa, false) then 'whatsapp' else 'push' end;
    v_payload := jsonb_build_object('name', v_m.full_name, 'gym', v_m.gym_name,
      'plan', v_m.plan_name, 'ends_on', v_m.ends_on);
    v_id := app.enqueue_notification(v_m.gym_id, v_m.member_id, v_channel, 'membership_expiring',
      v_m.locale, v_payload, 'expiry:' || v_m.member_id || ':' || v_m.ends_on);
    if v_id is not null then
      v_new_expiring := v_new_expiring + 1;
    end if;
  end loop;
  for v_m in
    select m.member_id, m.gym_id, m.ends_on, u.locale, u.full_name, g.name as gym_name, pl.name as plan_name
    from public.memberships m
    join public.users u on u.id = m.member_id
    join public.gyms g on g.id = m.gym_id
    join public.membership_plans pl on pl.id = m.plan_id
    where m.status in ('active','expired')
      and m.ends_on in (current_date - 1, current_date - 7)
      and not exists (
        select 1 from public.memberships m2
        where m2.member_id = m.member_id and m2.gym_id = m.gym_id and m2.status = 'active'
          and m2.starts_on <= current_date and m2.ends_on >= current_date
      )
  loop
    select f.enabled into v_wa from public.feature_flags f
      where f.gym_id = v_m.gym_id and f.flag = 'whatsapp_enabled';
    v_channel := case when coalesce(v_wa, false) then 'whatsapp' else 'push' end;
    v_payload := jsonb_build_object('name', v_m.full_name, 'gym', v_m.gym_name,
      'plan', v_m.plan_name, 'ended_on', v_m.ends_on);
    v_id := app.enqueue_notification(v_m.gym_id, v_m.member_id, v_channel, 'membership_overdue',
      v_m.locale, v_payload, 'overdue:' || v_m.member_id || ':' || v_m.ends_on);
    if v_id is not null then
      v_new_overdue := v_new_overdue + 1;
    end if;
  end loop;
  return jsonb_build_object('expiring_new', v_new_expiring, 'overdue_new', v_new_overdue);
end;
$$;

create function app.import_members(p_gym uuid, p_actor uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_row jsonb;
  v_name text;
  v_phone text;
  v_plan_code text;
  v_days_left integer;
  v_plan record;
  v_member uuid;
  v_job uuid;
  v_total integer := 0;
  v_inserted integer := 0;
  v_duplicates integer := 0;
  v_invalid integer := 0;
  v_report jsonb := '[]';
  v_seen text[] := array[]::text[];
  v_i integer := 0;
  v_status text;
  v_reason text;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist']);
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'ROWS_INVALID' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'TOO_MANY_ROWS' using errcode = '22023';
  end if;
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_i := v_i + 1;
    v_total := v_total + 1;
    v_name := btrim(coalesce(v_row->>'full_name', ''));
    v_phone := btrim(coalesce(v_row->>'phone', ''));
    v_plan_code := nullif(btrim(coalesce(v_row->>'plan_code', '')), '');
    v_days_left := nullif(v_row->>'days_left', '')::integer;
    v_status := null;
    v_reason := null;
    if v_name = '' or v_phone !~ '^\+[1-9][0-9]{7,14}$' then
      v_status := 'invalid';
      v_reason := case when v_name = '' then 'empty_name' else 'bad_phone' end;
      v_invalid := v_invalid + 1;
    elsif v_phone = any(v_seen) or exists (
      select 1 from public.users u where u.gym_id = p_gym and u.phone = v_phone
    ) then
      v_status := 'duplicate';
      v_duplicates := v_duplicates + 1;
    else
      insert into public.users (gym_id, role, full_name, phone, email, locale)
      values (p_gym, 'member', v_name, v_phone, nullif(v_row->>'email', ''),
        coalesce(nullif(v_row->>'locale', ''), 'en'))
      returning id into v_member;
      if v_plan_code is not null then
        select pl.* into v_plan from public.membership_plans pl
          where pl.gym_id = p_gym and pl.code = v_plan_code and pl.active and pl.kind = 'membership';
        if found then
          insert into public.memberships (gym_id, member_id, plan_id, starts_on, ends_on)
          values (p_gym, v_member, v_plan.id, current_date,
            current_date + greatest(coalesce(v_days_left, v_plan.duration_days), 1) - 1);
        end if;
      end if;
      v_seen := array_append(v_seen, v_phone);
      v_status := 'inserted';
      v_inserted := v_inserted + 1;
    end if;
    v_report := v_report || jsonb_build_array(jsonb_build_object(
      'row', v_i, 'phone_tail', right(v_phone, 4), 'status', v_status, 'reason', v_reason));
  end loop;
  insert into public.import_jobs (gym_id, created_by, total, inserted, duplicates, invalid, report)
  values (p_gym, v_actor, v_total, v_inserted, v_duplicates, v_invalid, v_report)
  returning id into v_job;
  perform app.audit(p_gym, v_actor, 'members.imported', 'import_jobs', v_job,
    jsonb_build_object('total', v_total, 'inserted', v_inserted, 'duplicates', v_duplicates, 'invalid', v_invalid));
  return jsonb_build_object('job_id', v_job, 'total', v_total, 'inserted', v_inserted,
    'duplicates', v_duplicates, 'invalid', v_invalid, 'report', v_report);
end;
$$;

-- RLS for phase-2 tables.
alter table public.payment_intents enable row level security;
alter table public.webhook_events enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.route_transfers enable row level security;
alter table public.import_jobs enable row level security;
alter table public.device_tokens enable row level security;
alter table public.rate_limits enable row level security;

create policy payment_intents_super_all on public.payment_intents for all to service_role using (true) with check (true);
create policy payment_intents_staff_select on public.payment_intents for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy payment_intents_member_select on public.payment_intents for select to authenticated
  using (member_id = app.uid());

create policy webhook_events_super_all on public.webhook_events for all to service_role using (true) with check (true);
create policy webhook_events_super_select on public.webhook_events for select to authenticated
  using (app.is_super());

create policy notification_outbox_super_all on public.notification_outbox for all to service_role using (true) with check (true);
create policy notification_outbox_staff_select on public.notification_outbox for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy notification_outbox_member_select on public.notification_outbox for select to authenticated
  using (member_id = app.uid());

create policy route_transfers_super_all on public.route_transfers for all to service_role using (true) with check (true);
create policy route_transfers_staff_select on public.route_transfers for select to authenticated
  using (app.staff_gym(gym_id) is not null);

create policy import_jobs_super_all on public.import_jobs for all to service_role using (true) with check (true);
create policy import_jobs_staff_select on public.import_jobs for select to authenticated
  using (app.staff_gym(gym_id) is not null);

create policy device_tokens_super_all on public.device_tokens for all to service_role using (true) with check (true);
create policy device_tokens_own_select on public.device_tokens for select to authenticated
  using (user_id = app.uid());

-- rate_limits: NO API-role access.

commit;