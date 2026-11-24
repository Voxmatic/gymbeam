-- GymOS 0009 — pilot mode: collections-first web RPCs + dues view.
-- Pilot defaults already in force: whatsapp_enabled OFF (reminders fall back to push),
-- counter payments via record_payment, optional payment-page link in gyms.settings.
begin;

create function app.create_class(p_gym uuid, p_actor uuid, p_branch uuid, p_name text,
  p_capacity integer, p_waitlist_capacity integer default 5, p_trainer uuid default null,
  p_name_hi text default null) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager']);
  if p_trainer is not null and not exists (
    select 1 from public.users u
    where u.id = p_trainer and u.gym_id = p_gym and u.role = 'trainer' and u.status = 'active'
  ) then
    raise exception 'TRAINER_INVALID' using errcode = '22023';
  end if;
  insert into public.classes (gym_id, branch_id, name, name_hi, capacity, waitlist_capacity, trainer_id)
  values (p_gym, p_branch, p_name, p_name_hi, p_capacity, p_waitlist_capacity, p_trainer)
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'class.created', 'classes', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create function app.create_session(p_gym uuid, p_actor uuid, p_class uuid,
  p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer default null,
  p_waitlist_capacity integer default null, p_cutoff integer default 60) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_class record;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager']);
  select c.* into v_class from public.classes c where c.id = p_class and c.gym_id = p_gym;
  if not found then
    raise exception 'CLASS_NOT_IN_GYM' using errcode = '22023';
  end if;
  if p_starts_at >= p_ends_at then
    raise exception 'TIME_INVALID' using errcode = '22023';
  end if;
  insert into public.class_sessions (gym_id, class_id, starts_at, ends_at, capacity, waitlist_capacity, cancel_cutoff_minutes)
  values (p_gym, p_class, p_starts_at, p_ends_at,
    coalesce(p_capacity, v_class.capacity), coalesce(p_waitlist_capacity, v_class.waitlist_capacity), p_cutoff)
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'session.created', 'class_sessions', v_id,
    jsonb_build_object('starts_at', p_starts_at));
  return v_id;
end;
$$;

create function app.upsert_plan(p_gym uuid, p_actor uuid, p_code text, p_name text,
  p_kind public.plan_kind, p_duration_days integer, p_price_paise bigint,
  p_gst_rate numeric default 18, p_active boolean default true, p_name_hi text default null) returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner','manager']);
  insert into public.membership_plans (gym_id, code, name, name_hi, kind, duration_days, price_paise, gst_rate, active)
  values (p_gym, p_code, p_name, p_name_hi, p_kind, p_duration_days, p_price_paise, p_gst_rate, p_active)
  on conflict (gym_id, code) do update set name = excluded.name, name_hi = excluded.name_hi,
    kind = excluded.kind, duration_days = excluded.duration_days, price_paise = excluded.price_paise,
    gst_rate = excluded.gst_rate, active = excluded.active
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'plan.upserted', 'membership_plans', v_id,
    jsonb_build_object('code', p_code, 'price_paise', p_price_paise));
  return v_id;
end;
$$;

create function app.create_staff(p_gym uuid, p_actor uuid, p_full_name text, p_phone text,
  p_role public.user_role, p_branch uuid default null, p_email text default null,
  p_locale text default 'en') returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  v_actor uuid;
  v_id uuid;
begin
  v_actor := app.resolve_actor(p_actor);
  perform app.require_staff(p_gym, v_actor, array['owner']);
  if p_role not in ('manager','receptionist','trainer') then
    raise exception 'ROLE_INVALID' using errcode = '22023';
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;
  insert into public.users (gym_id, branch_id, role, full_name, phone, email, locale)
  values (p_gym, p_branch, p_role, btrim(p_full_name), p_phone, p_email, coalesce(p_locale, 'en'))
  returning id into v_id;
  perform app.audit(p_gym, v_actor, 'staff.created', 'users', v_id,
    jsonb_build_object('role', p_role, 'phone_tail', right(p_phone, 4)));
  return v_id;
end;
$$;

create view public.dues with (security_invoker = true) as
select distinct on (m.member_id)
  m.gym_id, m.member_id, u.full_name, u.phone,
  m.id as membership_id, m.plan_id, pl.name as plan_name,
  m.starts_on, m.ends_on,
  (m.ends_on - current_date) as days_left,
  case
    when m.ends_on < current_date then 'overdue'
    when m.ends_on - current_date <= 7 then 'expiring'
    else 'active'
  end as bucket
from public.memberships m
join public.users u on u.id = m.member_id
join public.membership_plans pl on pl.id = m.plan_id
where m.status = 'active'
order by m.member_id, m.ends_on desc;

commit;