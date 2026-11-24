-- GymOS 0003 — core business logic (schema app, SECURITY DEFINER, fixed search_path).
begin;

create function app.jwt() returns jsonb
language sql stable set search_path = app, public as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

create function app.uid() returns uuid
language sql stable set search_path = app, public as $$
  select nullif(app.jwt()->>'sub', '')::uuid;
$$;

create function app.role() returns text
language sql stable set search_path = app, public as $$
  select app.jwt()->>'role';
$$;

create function app.is_super() returns boolean
language sql stable security definer set search_path = app, public as $$
  select exists (
    select 1 from public.users u
    where u.id = app.uid() and u.role = 'super_admin' and u.status = 'active'
  );
$$;

create function app.my_gym() returns uuid
language sql stable security definer set search_path = app, public as $$
  select u.gym_id from public.users u
  where u.id = app.uid() and u.status = 'active' and u.role = 'member';
$$;

-- Positive exists() check: returns the gym id ONLY for active staff of that gym, else NULL.
create function app.staff_gym(p_gym uuid) returns uuid
language sql stable security definer set search_path = app, public as $$
  select u.gym_id from public.users u
  where u.id = app.uid()
    and u.gym_id = p_gym
    and u.status = 'active'
    and u.role in ('owner','manager','receptionist','trainer');
$$;

create function app.branch_ok(p_gym uuid, p_branch uuid) returns boolean
language sql stable security definer set search_path = app, public as $$
  select exists (
    select 1 from public.users u
    where u.id = app.uid()
      and u.gym_id = p_gym
      and u.status = 'active'
      and u.role in ('owner','manager','receptionist','trainer')
      and (u.branch_id is null or p_branch is null or u.branch_id = p_branch)
  );
$$;

create function app.require_staff(p_gym uuid, p_actor uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if p_gym is null or p_actor is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_actor and u.gym_id = p_gym and u.status = 'active'
      and u.role::text = any(p_roles)
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;

create function app.resolve_actor(p_actor uuid) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_jwt uuid;
begin
  if app.role() = 'service_role' then
    if p_actor is null then
      raise exception 'ACTOR_REQUIRED' using errcode = '22004';
    end if;
    return p_actor;
  end if;
  v_jwt := app.uid();
  if v_jwt is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if p_actor is not null and p_actor <> v_jwt then
    raise exception 'ACTOR_MISMATCH' using errcode = '42501';
  end if;
  return v_jwt;
end;
$$;

create function app.require_service() returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if app.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ONLY' using errcode = '42501';
  end if;
end;
$$;

create function app.audit(p_gym uuid, p_actor uuid, p_action text,
  p_entity text default null, p_entity_id uuid default null, p_meta jsonb default '{}') returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_role public.user_role;
begin
  select u.role into v_role from public.users u where u.id = p_actor;
  insert into public.audit_log (gym_id, actor_id, actor_role, action, entity, entity_id, meta)
  values (p_gym, p_actor, v_role, p_action, p_entity, p_entity_id, coalesce(p_meta, '{}'));
end;
$$;

create function app.create_member(p_gym uuid, p_actor uuid, p_full_name text, p_phone text,
  p_email text default null, p_locale text default 'en', p_branch uuid default null) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_actor_branch uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist']);
  if p_full_name is null or length(btrim(p_full_name)) = 0 then
    raise exception 'NAME_REQUIRED' using errcode = '22004';
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;
  select u.branch_id into v_actor_branch from public.users u where u.id = v_actor;
  if v_actor_branch is not null and p_branch is distinct from v_actor_branch then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.users (gym_id, branch_id, role, full_name, phone, email, locale)
  values (p_gym, p_branch, 'member', btrim(p_full_name), p_phone, p_email, coalesce(p_locale, 'en'))
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'member.created', 'users', v_id,
    jsonb_build_object('phone_tail', right(p_phone, 4)));
  return v_id;
end;
$$;

create function app.record_payment(
  p_gym uuid, p_actor uuid, p_member uuid, p_purpose public.payment_purpose,
  p_amount_paise bigint, p_method public.payment_method,
  p_provider_payment_id text default null, p_provider_order_id text default null,
  p_gst_rate numeric default null) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_existing uuid;
  v_id uuid;
  v_gst_enabled boolean;
  v_rate numeric(5,2);
  v_gst bigint;
  v_invoice text;
begin
  v_actor := app.resolve_actor(p_actor);
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'AMOUNT_INVALID' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_member and u.gym_id = p_gym and u.status = 'active' and u.role = 'member'
  ) then
    raise exception 'MEMBER_NOT_IN_GYM' using errcode = '22023';
  end if;
  if p_method = 'razorpay' then
    perform app.require_service();
    if p_provider_payment_id is null then
      raise exception 'PROVIDER_ID_REQUIRED' using errcode = '22004';
    end if;
    select p.id into v_existing from public.payments p
      where p.provider_payment_id = p_provider_payment_id;
    if found then
      return v_existing;
    end if;
  else
    perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist']);
  end if;
  select g.gst_enabled into v_gst_enabled from public.gyms g where g.id = p_gym;
  if v_gst_enabled then
    v_rate := coalesce(p_gst_rate, 18);
    v_gst := round(p_amount_paise * v_rate / (100 + v_rate));
  else
    v_rate := 0;
    v_gst := 0;
  end if;
  v_invoice := 'INV-' || to_char(now(), 'YYYYMM') || '-' || lpad(nextval('public.app_invoice_seq')::text, 8, '0');
  begin
    insert into public.payments
      (gym_id, member_id, purpose, amount_paise, taxable_paise, gst_paise, gst_rate,
       method, provider_payment_id, provider_order_id, invoice_no, recorded_by)
    values
      (p_gym, p_member, p_purpose, p_amount_paise, p_amount_paise - v_gst, v_gst, v_rate,
       p_method, p_provider_payment_id, p_provider_order_id, v_invoice,
       case when p_method = 'razorpay' then null else v_actor end)
    returning id into v_id;
  exception when unique_violation then
    if p_provider_payment_id is not null then
      select p.id into v_id from public.payments p
        where p.provider_payment_id = p_provider_payment_id;
      if v_id is not null then
        return v_id;
      end if;
    end if;
    raise;
  end;
  perform app.audit(p_gym, v_actor, 'payment.recorded', 'payments', v_id,
    jsonb_build_object('amount_paise', p_amount_paise, 'method', p_method, 'invoice_no', v_invoice));
  return v_id;
end;
$$;

create function app.record_refund(p_payment uuid, p_actor uuid default null) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_pay record;
begin
  v_actor := app.resolve_actor(p_actor);
  if app.role() <> 'service_role' and not app.is_super() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select p.* into v_pay from public.payments p where p.id = p_payment;
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = '22023';
  end if;
  if v_pay.status <> 'captured' then
    raise exception 'ALREADY_REFUNDED' using errcode = '22023';
  end if;
  update public.payments set status = 'refunded' where id = p_payment;
  perform app.audit(v_pay.gym_id, v_actor, 'payment.refunded', 'payments', p_payment,
    jsonb_build_object('amount_paise', v_pay.amount_paise));
end;
$$;

create function app.renew_membership(p_gym uuid, p_actor uuid, p_member uuid, p_plan uuid,
  p_branch uuid default null, p_payment uuid default null) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_duration integer;
  v_start date;
  v_end date;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  if app.role() <> 'service_role' then
    perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist']);
  end if;
  select pl.duration_days into v_duration from public.membership_plans pl
    where pl.id = p_plan and pl.gym_id = p_gym and pl.active and pl.kind = 'membership';
  if not found then
    raise exception 'PLAN_INVALID' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_member and u.gym_id = p_gym and u.status = 'active' and u.role = 'member'
  ) then
    raise exception 'MEMBER_NOT_IN_GYM' using errcode = '22023';
  end if;
  select greatest(current_date, coalesce(max(m.ends_on) + 1, current_date)) into v_start
    from public.memberships m
    where m.member_id = p_member and m.gym_id = p_gym and m.status = 'active';
  v_end := v_start + v_duration - 1;
  insert into public.memberships (gym_id, member_id, plan_id, branch_id, starts_on, ends_on, payment_id)
  values (p_gym, p_member, p_plan, p_branch, v_start, v_end, p_payment)
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'membership.renewed', 'memberships', v_id,
    jsonb_build_object('starts_on', v_start, 'ends_on', v_end));
  return v_id;
end;
$$;

create function app.check_in_member(p_gym uuid, p_actor uuid, p_member uuid, p_branch uuid,
  p_method public.checkin_method default 'qr') returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager','receptionist','trainer']);
  if not exists (
    select 1 from public.users u
    where u.id = p_member and u.gym_id = p_gym and u.status = 'active' and u.role = 'member'
  ) then
    raise exception 'MEMBER_NOT_IN_GYM' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.member_id = p_member and m.gym_id = p_gym and m.status = 'active'
      and m.starts_on <= current_date and m.ends_on >= current_date
  ) then
    raise exception 'MEMBERSHIP_REQUIRED' using errcode = '22023';
  end if;
  insert into public.check_ins (gym_id, member_id, branch_id, method, checked_in_by)
  values (p_gym, p_member, p_branch, p_method, v_actor)
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'checkin.' || p_method::text, 'check_ins', v_id,
    jsonb_build_object('member_id', p_member));
  return v_id;
end;
$$;

create function app.mark_booking(p_booking uuid, p_actor uuid, p_status public.booking_status) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_b record;
begin
  v_actor := app.resolve_actor(p_actor);
  if p_status not in ('attended','no_show') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  select b.* into v_b from public.bookings b where b.id = p_booking;
  if not found then
    raise exception 'BOOKING_NOT_FOUND' using errcode = '22023';
  end if;
  perform app.require_staff(v_b.gym_id, v_actor, array['owner','manager','receptionist','trainer']);
  if v_b.status <> 'confirmed' then
    raise exception 'NOT_CONFIRMED' using errcode = '22023';
  end if;
  update public.bookings set status = p_status where id = p_booking;
  perform app.audit(v_b.gym_id, v_actor, 'booking.marked', 'bookings', p_booking,
    jsonb_build_object('status', p_status));
end;
$$;

create function app.update_gym(p_gym uuid, p_actor uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_super boolean;
begin
  v_actor := app.resolve_actor(p_actor);
  v_super := app.is_super();
  if not v_super then
    perform app.require_staff(p_gym, v_actor, array['owner']);
  end if;
  if p_patch ? 'status' and not v_super then
    raise exception 'STATUS_SUPER_ONLY' using errcode = '42501';
  end if;
  if p_patch ? 'price_per_member_paise' and not v_super then
    raise exception 'PRICE_SUPER_ONLY' using errcode = '42501';
  end if;
  update public.gyms g set
    name = coalesce(nullif(p_patch->>'name', ''), g.name),
    locale = coalesce(p_patch->>'locale', g.locale),
    gst_enabled = coalesce((p_patch->>'gst_enabled')::boolean, g.gst_enabled),
    gstin = case when p_patch ? 'gstin' then nullif(p_patch->>'gstin', '') else g.gstin end,
    razorpay_linked_account_id = case when p_patch ? 'razorpay_linked_account_id'
      then nullif(p_patch->>'razorpay_linked_account_id', '') else g.razorpay_linked_account_id end,
    settings = case when p_patch ? 'settings' then g.settings || (p_patch->'settings') else g.settings end,
    status = case when p_patch ? 'status' then (p_patch->>'status')::public.gym_status else g.status end,
    price_per_member_paise = case when p_patch ? 'price_per_member_paise'
      then (p_patch->>'price_per_member_paise')::bigint else g.price_per_member_paise end
  where g.id = p_gym;
  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = '22023';
  end if;
  perform app.audit(p_gym, v_actor, 'gym.updated', 'gyms', p_gym, p_patch - 'gstin');
end;
$$;

create function app.link_firebase_identity(p_firebase_uid text, p_phone text default null,
  p_email text default null) returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_user record;
begin
  perform app.require_service();
  if p_firebase_uid is null or length(btrim(p_firebase_uid)) = 0 then
    raise exception 'UID_REQUIRED' using errcode = '22004';
  end if;
  select u.* into v_user from public.users u where u.firebase_uid = p_firebase_uid;
  if found then
    return jsonb_build_object('id', v_user.id, 'gym_id', v_user.gym_id, 'branch_id', v_user.branch_id,
      'role', v_user.role, 'full_name', v_user.full_name, 'locale', v_user.locale, 'status', v_user.status);
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'PHONE_REQUIRED' using errcode = '22004';
  end if;
  select u.* into v_user from public.users u
    where u.phone = p_phone and u.firebase_uid is null and u.status = 'active'
    order by u.created_at, u.id limit 1;
  if not found then
    raise exception 'NO_INVITED_USER' using errcode = '22023';
  end if;
  update public.users set firebase_uid = p_firebase_uid,
    email = coalesce(p_email, email)
    where id = v_user.id;
  perform app.audit(v_user.gym_id, v_user.id, 'identity.linked', 'users', v_user.id,
    jsonb_build_object('phone_tail', right(p_phone, 4)));
  return jsonb_build_object('id', v_user.id, 'gym_id', v_user.gym_id, 'branch_id', v_user.branch_id,
    'role', v_user.role, 'full_name', v_user.full_name, 'locale', v_user.locale, 'status', v_user.status);
end;
$$;

create function app.save_workout(p_actor uuid, p_started_at timestamptz,
  p_ended_at timestamptz default null, p_summary jsonb default '{}',
  p_source public.workout_source default 'manual') returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_gym uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  select u.gym_id into v_gym from public.users u
    where u.id = v_actor and u.status = 'active' and u.role = 'member';
  if v_gym is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.workout_sessions (gym_id, member_id, source, started_at, ended_at, summary)
  values (v_gym, v_actor, p_source, p_started_at, p_ended_at, coalesce(p_summary, '{}'))
  returning id into v_id;
  return v_id;
end;
$$;

commit;