-- GymOS 0006 — platform requirements: slots, consents, flags, AI entitlements, WhatsApp wallet, keys vault, SaaS billing.
begin;

create type public.slot_booking_status as enum ('booked','cancelled','attended','no_show');
create type public.consent_kind as enum ('waiver','parq','data');
create type public.wallet_ledger_kind as enum
  ('purchase','reserve','capture','release','free_reserve','free_capture','free_release','adjust');
create type public.saas_invoice_status as enum ('open','paid','void');

create table public.gym_slots (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  branch_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  capacity integer not null check (capacity between 1 and 1000),
  created_at timestamptz not null default now(),
  constraint gym_slots_time check (start_time < end_time),
  unique (id, gym_id),
  constraint gym_slots_branch_fk foreign key (branch_id, gym_id)
    references public.branches (id, gym_id)
);

create table public.slot_bookings (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  slot_id uuid not null,
  member_id uuid not null,
  on_date date not null,
  status public.slot_booking_status not null default 'booked',
  created_at timestamptz not null default now(),
  unique (slot_id, on_date, member_id),
  unique (id, gym_id),
  constraint slot_bookings_slot_fk foreign key (slot_id, gym_id)
    references public.gym_slots (id, gym_id),
  constraint slot_bookings_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);

create view public.slot_crowd with (security_invoker = true) as
select s.id as slot_id, s.gym_id, s.branch_id, s.weekday, s.start_time, s.end_time, s.capacity,
  coalesce(b.booked, 0) as booked_today,
  case
    when coalesce(b.booked, 0) * 2 < s.capacity then 'low'
    when coalesce(b.booked, 0) * 100 < s.capacity * 85 then 'medium'
    else 'high'
  end as crowd_level
from public.gym_slots s
left join (
  select sb.slot_id, count(*) as booked
  from public.slot_bookings sb
  where sb.on_date = current_date and sb.status in ('booked','attended')
  group by sb.slot_id
) b on b.slot_id = s.id;

create table public.consents (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  kind public.consent_kind not null,
  version text not null default 'v1',
  accepted_at timestamptz not null default now(),
  unique (member_id, gym_id, kind, version),
  unique (id, gym_id),
  constraint consents_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);

create table public.feature_flags (
  gym_id uuid not null references public.gyms(id) on delete cascade,
  flag text not null check (flag in ('require_consent','whatsapp_enabled','ai_trainer','pos','lockers','expenses','payroll')),
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (gym_id, flag)
);

create table public.ai_entitlements (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  starts_on date not null,
  ends_on date not null,
  payment_id uuid,
  created_at timestamptz not null default now(),
  constraint ai_entitlements_dates check (ends_on >= starts_on),
  unique (member_id, payment_id),
  unique (id, gym_id),
  constraint ai_entitlements_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id),
  constraint ai_entitlements_payment_fk foreign key (payment_id, gym_id)
    references public.payments (id, gym_id)
);

create table public.whatsapp_wallets (
  gym_id uuid primary key references public.gyms(id) on delete cascade,
  credit_balance bigint not null default 0 check (credit_balance >= 0),
  updated_at timestamptz not null default now()
);

create table public.whatsapp_free_usage (
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  period date not null,
  used smallint not null default 0 check (used between 0 and 3),
  primary key (gym_id, member_id, period),
  constraint whatsapp_free_usage_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);

create table public.whatsapp_ledger (
  id bigint generated always as identity primary key,
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid,
  kind public.wallet_ledger_kind not null,
  credits integer not null default 0,
  reservation_id uuid,
  outbox_id uuid,
  created_at timestamptz not null default now()
);
create index whatsapp_ledger_reservation_idx on public.whatsapp_ledger (reservation_id);

create table public.wallet_packs (
  code text primary key,
  credits integer not null check (credits > 0),
  price_paise bigint not null check (price_paise >= 0)
);
insert into public.wallet_packs (code, credits, price_paise) values
  ('pack_100', 100, 9900),
  ('pack_500', 500, 44900),
  ('pack_2000', 2000, 159900);

create table public.provider_keys (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete cascade,
  provider text not null check (provider in ('interakt','razorpay','fcm','custom')),
  ciphertext bytea not null,
  nonce bytea not null,
  key_version integer not null default 1,
  fingerprint text not null,
  updated_at timestamptz not null default now(),
  unique (gym_id, provider)
);
create unique index provider_keys_platform_uniq on public.provider_keys (provider) where gym_id is null;

create table public.saas_invoices (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  period date not null,
  member_count integer not null check (member_count >= 0),
  amount_paise bigint not null check (amount_paise >= 0),
  invoice_no text not null unique,
  status public.saas_invoice_status not null default 'open',
  created_at timestamptz not null default now(),
  unique (gym_id, period),
  unique (id, gym_id)
);

create function app.book_slot(p_slot uuid, p_actor uuid, p_date date) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_slot record;
  v_existing record;
  v_count integer;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  if not exists (select 1 from public.users u where u.id = v_actor and u.role = 'member' and u.status = 'active') then
    raise exception 'MEMBERS_ONLY' using errcode = '42501';
  end if;
  if p_date < current_date then
    raise exception 'DATE_PAST' using errcode = '22023';
  end if;
  select s.* into v_slot from public.gym_slots s where s.id = p_slot for update;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = '22023';
  end if;
  if not exists (select 1 from public.users u where u.id = v_actor and u.gym_id = v_slot.gym_id) then
    raise exception 'NOT_IN_GYM' using errcode = '42501';
  end if;
  if extract(dow from p_date)::int <> v_slot.weekday then
    raise exception 'WEEKDAY_MISMATCH' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.member_id = v_actor and m.gym_id = v_slot.gym_id and m.status = 'active'
      and m.starts_on <= p_date and m.ends_on >= p_date
  ) then
    raise exception 'MEMBERSHIP_REQUIRED' using errcode = '22023';
  end if;
  select sb.* into v_existing from public.slot_bookings sb
    where sb.slot_id = p_slot and sb.on_date = p_date and sb.member_id = v_actor;
  if found and v_existing.status in ('booked','attended') then
    return v_existing.id;
  end if;
  select count(*) into v_count from public.slot_bookings sb
    where sb.slot_id = p_slot and sb.on_date = p_date and sb.status in ('booked','attended');
  if v_count >= v_slot.capacity then
    raise exception 'SLOT_FULL' using errcode = '22023';
  end if;
  if found then
    update public.slot_bookings set status = 'booked' where id = v_existing.id returning id into v_id;
  else
    insert into public.slot_bookings (gym_id, slot_id, member_id, on_date)
    values (v_slot.gym_id, p_slot, v_actor, p_date) returning id into v_id;
  end if;
  perform app.audit(v_slot.gym_id, v_actor, 'slot.booked', 'slot_bookings', v_id, jsonb_build_object('on_date', p_date));
  return v_id;
end;
$$;

create function app.accept_consent(p_actor uuid, p_kind public.consent_kind, p_version text default 'v1') returns void
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
  insert into public.consents (gym_id, member_id, kind, version)
  values (v_gym, v_actor, p_kind, p_version)
  on conflict (member_id, gym_id, kind, version) do nothing;
  perform app.audit(v_gym, v_actor, 'consent.accepted', 'consents', null,
    jsonb_build_object('kind', p_kind, 'version', p_version));
end;
$$;

create function app.set_feature_flag(p_gym uuid, p_flag text, p_enabled boolean) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if not app.is_super() then
    raise exception 'SUPER_ONLY' using errcode = '42501';
  end if;
  insert into public.feature_flags (gym_id, flag, enabled)
  values (p_gym, p_flag, p_enabled)
  on conflict (gym_id, flag) do update set enabled = excluded.enabled, updated_at = now();
  perform app.audit(p_gym, app.uid(), 'flag.set', 'feature_flags', null,
    jsonb_build_object('flag', p_flag, 'enabled', p_enabled));
end;
$$;

create function app.onboard_gym(p_name text, p_slug text, p_owner_name text, p_owner_phone text,
  p_price_per_member_paise bigint default 0, p_locale text default 'en') returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_gym uuid;
  v_branch uuid;
  v_owner uuid;
begin
  if not app.is_super() then
    raise exception 'SUPER_ONLY' using errcode = '42501';
  end if;
  if p_owner_phone is null or p_owner_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;
  insert into public.gyms (name, slug, price_per_member_paise, locale)
  values (p_name, p_slug, p_price_per_member_paise, coalesce(p_locale, 'en'))
  returning id into v_gym;
  insert into public.branches (gym_id, name, code) values (v_gym, 'Main', 'MAIN')
  returning id into v_branch;
  insert into public.users (gym_id, role, full_name, phone, locale)
  values (v_gym, 'owner', p_owner_name, p_owner_phone, coalesce(p_locale, 'en'))
  returning id into v_owner;
  insert into public.whatsapp_wallets (gym_id) values (v_gym);
  perform app.audit(v_gym, app.uid(), 'gym.onboarded', 'gyms', v_gym,
    jsonb_build_object('slug', p_slug, 'owner_phone_tail', right(p_owner_phone, 4)));
  return jsonb_build_object('gym_id', v_gym, 'branch_id', v_branch, 'owner_id', v_owner);
end;
$$;

create function app.wallet_purchase(p_gym uuid, p_credits integer, p_actor uuid,
  p_payment uuid default null) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
begin
  perform app.require_service();
  v_actor := app.resolve_actor(p_actor);
  if p_credits is null or p_credits <= 0 then
    raise exception 'CREDITS_INVALID' using errcode = '22023';
  end if;
  insert into public.whatsapp_wallets (gym_id, credit_balance) values (p_gym, p_credits)
  on conflict (gym_id) do update set credit_balance = whatsapp_wallets.credit_balance + excluded.credit_balance,
    updated_at = now();
  insert into public.whatsapp_ledger (gym_id, kind, credits) values (p_gym, 'purchase', p_credits);
  perform app.audit(p_gym, v_actor, 'wallet.purchased', 'whatsapp_wallets', null,
    jsonb_build_object('credits', p_credits));
end;
$$;

create function app.wallet_reserve(p_gym uuid, p_member uuid, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_wallet record;
  v_period date;
  v_used smallint;
  v_reservation uuid;
begin
  perform app.require_service();
  v_actor := app.resolve_actor(p_actor);
  v_period := date_trunc('month', current_date)::date;
  select w.* into v_wallet from public.whatsapp_wallets w where w.gym_id = p_gym for update;
  if not found then
    insert into public.whatsapp_wallets (gym_id) values (p_gym);
    select w.* into v_wallet from public.whatsapp_wallets w where w.gym_id = p_gym for update;
  end if;
  insert into public.whatsapp_free_usage (gym_id, member_id, period, used)
  values (p_gym, p_member, v_period, 0)
  on conflict (gym_id, member_id, period) do nothing;
  select f.used into v_used from public.whatsapp_free_usage f
    where f.gym_id = p_gym and f.member_id = p_member and f.period = v_period for update;
  v_reservation := gen_random_uuid();
  if v_used < 3 then
    update public.whatsapp_free_usage set used = used + 1
      where gym_id = p_gym and member_id = p_member and period = v_period;
    insert into public.whatsapp_ledger (gym_id, member_id, kind, credits, reservation_id)
    values (p_gym, p_member, 'free_reserve', 1, v_reservation);
    return jsonb_build_object('reservation_id', v_reservation, 'source', 'free');
  elsif v_wallet.credit_balance >= 1 then
    update public.whatsapp_wallets set credit_balance = credit_balance - 1, updated_at = now()
      where gym_id = p_gym;
    insert into public.whatsapp_ledger (gym_id, member_id, kind, credits, reservation_id)
    values (p_gym, p_member, 'reserve', 1, v_reservation);
    return jsonb_build_object('reservation_id', v_reservation, 'source', 'credit');
  else
    raise exception 'INSUFFICIENT_CREDITS' using errcode = '22023';
  end if;
end;
$$;

create function app.wallet_capture(p_reservation uuid) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_res record;
begin
  perform app.require_service();
  select l.* into v_res from public.whatsapp_ledger l
    where l.reservation_id = p_reservation and l.kind in ('reserve','free_reserve')
    order by l.id limit 1;
  if not found then
    raise exception 'RESERVATION_NOT_FOUND' using errcode = '22023';
  end if;
  if exists (select 1 from public.whatsapp_ledger l
    where l.reservation_id = p_reservation and l.kind in ('capture','free_capture','release','free_release')) then
    return;
  end if;
  insert into public.whatsapp_ledger (gym_id, member_id, kind, credits, reservation_id)
  values (v_res.gym_id, v_res.member_id,
    (case when v_res.kind = 'free_reserve' then 'free_capture' else 'capture' end)::public.wallet_ledger_kind,
    v_res.credits, p_reservation);
end;
$$;

create function app.wallet_release(p_reservation uuid) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_res record;
  v_period date;
begin
  perform app.require_service();
  select l.* into v_res from public.whatsapp_ledger l
    where l.reservation_id = p_reservation and l.kind in ('reserve','free_reserve')
    order by l.id limit 1;
  if not found then
    raise exception 'RESERVATION_NOT_FOUND' using errcode = '22023';
  end if;
  if exists (select 1 from public.whatsapp_ledger l
    where l.reservation_id = p_reservation and l.kind in ('capture','free_capture','release','free_release')) then
    return;
  end if;
  if v_res.kind = 'reserve' then
    update public.whatsapp_wallets set credit_balance = credit_balance + v_res.credits, updated_at = now()
      where gym_id = v_res.gym_id;
  else
    v_period := date_trunc('month', current_date)::date;
    update public.whatsapp_free_usage set used = greatest(used - v_res.credits, 0)
      where gym_id = v_res.gym_id and member_id = v_res.member_id and period = v_period;
  end if;
  insert into public.whatsapp_ledger (gym_id, member_id, kind, credits, reservation_id)
  values (v_res.gym_id, v_res.member_id,
    (case when v_res.kind = 'free_reserve' then 'free_release' else 'release' end)::public.wallet_ledger_kind,
    v_res.credits, p_reservation);
end;
$$;

create function app.set_provider_key(p_gym uuid, p_provider text, p_ciphertext bytea,
  p_nonce bytea, p_fingerprint text, p_key_version integer default 1) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if not app.is_super() then
    raise exception 'SUPER_ONLY' using errcode = '42501';
  end if;
  if p_gym is null then
    update public.provider_keys set ciphertext = p_ciphertext, nonce = p_nonce,
      fingerprint = p_fingerprint, key_version = p_key_version, updated_at = now()
      where gym_id is null and provider = p_provider;
    if not found then
      insert into public.provider_keys (gym_id, provider, ciphertext, nonce, fingerprint, key_version)
      values (null, p_provider, p_ciphertext, p_nonce, p_fingerprint, p_key_version);
    end if;
  else
    insert into public.provider_keys (gym_id, provider, ciphertext, nonce, fingerprint, key_version)
    values (p_gym, p_provider, p_ciphertext, p_nonce, p_fingerprint, p_key_version)
    on conflict (gym_id, provider) do update set ciphertext = excluded.ciphertext,
      nonce = excluded.nonce, fingerprint = excluded.fingerprint,
      key_version = excluded.key_version, updated_at = now();
  end if;
  perform app.audit(p_gym, app.uid(), 'key.set', 'provider_keys', null,
    jsonb_build_object('provider', p_provider, 'fingerprint', p_fingerprint));
end;
$$;

create function app.list_provider_keys(p_gym uuid default null)
returns table (gym_id uuid, provider text, fingerprint text, key_version integer, updated_at timestamptz)
language plpgsql security definer set search_path = app, public as $$
begin
  if not app.is_super() then
    raise exception 'SUPER_ONLY' using errcode = '42501';
  end if;
  return query
    select k.gym_id, k.provider, k.fingerprint, k.key_version, k.updated_at
    from public.provider_keys k
    where (p_gym is null or k.gym_id = p_gym or k.gym_id is null)
    order by k.gym_id nulls first, k.provider;
end;
$$;

create function app.delete_provider_key(p_gym uuid, p_provider text) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if not app.is_super() then
    raise exception 'SUPER_ONLY' using errcode = '42501';
  end if;
  if p_gym is null then
    delete from public.provider_keys where gym_id is null and provider = p_provider;
  else
    delete from public.provider_keys where gym_id = p_gym and provider = p_provider;
  end if;
  perform app.audit(p_gym, app.uid(), 'key.deleted', 'provider_keys', null,
    jsonb_build_object('provider', p_provider));
end;
$$;

create function app.get_provider_key(p_gym uuid, p_provider text)
returns table (ciphertext bytea, nonce bytea, key_version integer)
language plpgsql security definer set search_path = app, public as $$
begin
  perform app.require_service();
  return query
    select k.ciphertext, k.nonce, k.key_version from public.provider_keys k
    where k.provider = p_provider and (k.gym_id = p_gym or k.gym_id is null)
    order by k.gym_id nulls last limit 1;
  perform app.audit(p_gym, null, 'key.fetched', 'provider_keys', null,
    jsonb_build_object('provider', p_provider));
end;
$$;

create function app.run_saas_billing(p_period date) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_gym record;
  v_end date;
  v_count integer;
  v_amount bigint;
  v_created integer := 0;
  v_skipped integer := 0;
  v_invoice text;
begin
  if app.role() <> 'service_role' and not app.is_super() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_period is null or extract(day from p_period) <> 1 then
    raise exception 'PERIOD_INVALID' using errcode = '22023';
  end if;
  v_end := (p_period + interval '1 month' - interval '1 day')::date;
  for v_gym in
    select g.id, g.price_per_member_paise from public.gyms g where g.status in ('trial','active')
  loop
    select count(distinct m.member_id) into v_count
      from public.memberships m
      where m.gym_id = v_gym.id and m.status = 'active'
        and m.starts_on <= v_end and m.ends_on >= v_end;
    v_amount := v_count * v_gym.price_per_member_paise;
    v_invoice := 'SAAS-' || to_char(p_period, 'YYYYMM') || '-' || lpad(nextval('public.app_invoice_seq')::text, 8, '0');
    insert into public.saas_invoices (gym_id, period, member_count, amount_paise, invoice_no)
    values (v_gym.id, p_period, v_count, v_amount, v_invoice)
    on conflict (gym_id, period) do nothing;
    if found then
      v_created := v_created + 1;
      perform app.audit(v_gym.id, app.uid(), 'saas.billed', 'saas_invoices', null,
        jsonb_build_object('period', p_period, 'member_count', v_count, 'amount_paise', v_amount));
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;
  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;

-- RLS for platform tables. authenticated = SELECT ONLY; writes via app.* functions.
alter table public.gym_slots enable row level security;
alter table public.slot_bookings enable row level security;
alter table public.consents enable row level security;
alter table public.feature_flags enable row level security;
alter table public.ai_entitlements enable row level security;
alter table public.whatsapp_wallets enable row level security;
alter table public.whatsapp_free_usage enable row level security;
alter table public.whatsapp_ledger enable row level security;
alter table public.wallet_packs enable row level security;
alter table public.provider_keys enable row level security;
alter table public.saas_invoices enable row level security;

create policy gym_slots_super_all on public.gym_slots for all to service_role using (true) with check (true);
create policy gym_slots_staff_select on public.gym_slots for select to authenticated
  using (app.branch_ok(gym_id, branch_id));
create policy gym_slots_member_select on public.gym_slots for select to authenticated
  using (gym_id = app.my_gym());

create policy slot_bookings_super_all on public.slot_bookings for all to service_role using (true) with check (true);
create policy slot_bookings_staff_select on public.slot_bookings for select to authenticated
  using (exists (select 1 from public.gym_slots s where s.id = slot_id and app.branch_ok(s.gym_id, s.branch_id)));
create policy slot_bookings_member_select on public.slot_bookings for select to authenticated
  using (member_id = app.uid());

create policy consents_super_all on public.consents for all to service_role using (true) with check (true);
create policy consents_staff_select on public.consents for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy consents_member_select on public.consents for select to authenticated
  using (member_id = app.uid());

create policy feature_flags_super_all on public.feature_flags for all to service_role using (true) with check (true);
create policy feature_flags_staff_select on public.feature_flags for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy feature_flags_member_select on public.feature_flags for select to authenticated
  using (gym_id = app.my_gym());

create policy ai_entitlements_super_all on public.ai_entitlements for all to service_role using (true) with check (true);
create policy ai_entitlements_staff_select on public.ai_entitlements for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy ai_entitlements_member_select on public.ai_entitlements for select to authenticated
  using (member_id = app.uid());

create policy whatsapp_wallets_super_all on public.whatsapp_wallets for all to service_role using (true) with check (true);
create policy whatsapp_wallets_staff_select on public.whatsapp_wallets for select to authenticated
  using (app.staff_gym(gym_id) is not null);

create policy whatsapp_free_usage_super_all on public.whatsapp_free_usage for all to service_role using (true) with check (true);
create policy whatsapp_free_usage_staff_select on public.whatsapp_free_usage for select to authenticated
  using (app.staff_gym(gym_id) is not null);

create policy whatsapp_ledger_super_all on public.whatsapp_ledger for all to service_role using (true) with check (true);
create policy whatsapp_ledger_staff_select on public.whatsapp_ledger for select to authenticated
  using (app.staff_gym(gym_id) is not null);

create policy wallet_packs_read on public.wallet_packs for select to authenticated using (true);
create policy wallet_packs_super_all on public.wallet_packs for all to service_role using (true) with check (true);

-- provider_keys: NO API-role access at all (vault reads/writes go through service-role edge functions).

create policy saas_invoices_super_all on public.saas_invoices for all to service_role using (true) with check (true);
create policy saas_invoices_staff_select on public.saas_invoices for select to authenticated
  using (app.staff_gym(gym_id) is not null);

commit;