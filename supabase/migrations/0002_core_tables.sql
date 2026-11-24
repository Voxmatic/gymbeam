-- GymOS 0002 — core tables. Money = integer paise; composite (id, gym_id) FKs reject cross-gym links.
begin;

create type public.user_role as enum ('super_admin','owner','manager','receptionist','trainer','member');
create type public.gym_status as enum ('trial','active','suspended','closed');
create type public.user_status as enum ('active','disabled');
create type public.plan_kind as enum ('membership','pt_package','ai_addon');
create type public.payment_purpose as enum ('membership','ai_addon','wallet_topup','saas');
create type public.payment_method as enum ('razorpay','cash','upi_manual','card_manual','migration');
create type public.payment_status as enum ('captured','refunded');
create type public.membership_status as enum ('active','frozen','cancelled','expired');
create type public.booking_status as enum ('confirmed','waitlisted','cancelled','attended','no_show');
create type public.checkin_method as enum ('qr','manual');
create type public.workout_source as enum ('manual','ai_trainer');

create table public.gyms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  status public.gym_status not null default 'trial',
  locale text not null default 'en' check (locale in ('en','hi')),
  gst_enabled boolean not null default false,
  gstin text,
  razorpay_linked_account_id text,
  price_per_member_paise bigint not null default 0 check (price_per_member_paise >= 0),
  settings jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint gyms_gstin_required check (not gst_enabled or (gstin is not null and length(gstin) = 15))
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  code text not null,
  timezone text not null default 'Asia/Kolkata',
  created_at timestamptz not null default now(),
  unique (gym_id, code),
  unique (id, gym_id)
);

create table public.users (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete cascade,
  branch_id uuid,
  role public.user_role not null,
  full_name text not null check (length(btrim(full_name)) > 0),
  phone text,
  email text,
  firebase_uid text unique,
  locale text not null default 'en' check (locale in ('en','hi')),
  status public.user_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint users_super_admin_no_gym check ((role = 'super_admin') = (gym_id is null)),
  constraint users_phone_e164 check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  unique (id, gym_id),
  constraint users_branch_fk foreign key (branch_id, gym_id)
    references public.branches (id, gym_id)
);
create unique index users_gym_phone_uniq on public.users (gym_id, phone) where phone is not null;

create table public.membership_plans (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  code text not null,
  name text not null,
  name_hi text,
  kind public.plan_kind not null default 'membership',
  duration_days integer not null check (duration_days between 1 and 3650),
  price_paise bigint not null check (price_paise >= 0),
  gst_rate numeric(5,2) not null default 18 check (gst_rate >= 0 and gst_rate <= 100),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (gym_id, code),
  unique (id, gym_id)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  purpose public.payment_purpose not null,
  amount_paise bigint not null check (amount_paise > 0),
  taxable_paise bigint not null check (taxable_paise >= 0),
  gst_paise bigint not null check (gst_paise >= 0),
  gst_rate numeric(5,2) not null default 0 check (gst_rate >= 0),
  method public.payment_method not null,
  provider_payment_id text unique,
  provider_order_id text,
  invoice_no text not null unique,
  status public.payment_status not null default 'captured',
  recorded_by uuid,
  created_at timestamptz not null default now(),
  constraint payments_amount_split check (taxable_paise + gst_paise = amount_paise),
  constraint payments_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id),
  constraint payments_recorded_by_fk foreign key (recorded_by, gym_id)
    references public.users (id, gym_id),
  unique (id, gym_id)
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  plan_id uuid not null,
  branch_id uuid,
  starts_on date not null,
  ends_on date not null,
  status public.membership_status not null default 'active',
  payment_id uuid,
  created_at timestamptz not null default now(),
  constraint memberships_dates check (ends_on >= starts_on),
  constraint memberships_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id),
  constraint memberships_plan_fk foreign key (plan_id, gym_id)
    references public.membership_plans (id, gym_id),
  constraint memberships_branch_fk foreign key (branch_id, gym_id)
    references public.branches (id, gym_id),
  constraint memberships_payment_fk foreign key (payment_id, gym_id)
    references public.payments (id, gym_id),
  unique (id, gym_id)
);
create index memberships_member_ends_idx on public.memberships (gym_id, member_id, ends_on desc);

create table public.classes (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  branch_id uuid not null,
  name text not null check (length(btrim(name)) > 0),
  name_hi text,
  capacity integer not null check (capacity between 1 and 500),
  waitlist_capacity integer not null default 5 check (waitlist_capacity >= 0),
  trainer_id uuid,
  created_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint classes_branch_fk foreign key (branch_id, gym_id)
    references public.branches (id, gym_id),
  constraint classes_trainer_fk foreign key (trainer_id, gym_id)
    references public.users (id, gym_id)
);

create table public.class_sessions (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  class_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity integer not null check (capacity between 1 and 500),
  waitlist_capacity integer not null default 5 check (waitlist_capacity >= 0),
  cancel_cutoff_minutes integer not null default 60 check (cancel_cutoff_minutes >= 0),
  created_at timestamptz not null default now(),
  constraint class_sessions_time check (starts_at < ends_at),
  unique (id, gym_id),
  constraint class_sessions_class_fk foreign key (class_id, gym_id)
    references public.classes (id, gym_id)
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  session_id uuid not null,
  member_id uuid not null,
  status public.booking_status not null default 'confirmed',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, member_id),
  unique (id, gym_id),
  constraint bookings_session_fk foreign key (session_id, gym_id)
    references public.class_sessions (id, gym_id),
  constraint bookings_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);
create index bookings_session_status_idx on public.bookings (session_id, status, created_at);

create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  branch_id uuid not null,
  method public.checkin_method not null,
  checked_in_by uuid,
  checked_in_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint check_ins_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id),
  constraint check_ins_branch_fk foreign key (branch_id, gym_id)
    references public.branches (id, gym_id),
  constraint check_ins_staff_fk foreign key (checked_in_by, gym_id)
    references public.users (id, gym_id)
);

create table public.workout_sessions (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  member_id uuid not null,
  source public.workout_source not null default 'manual',
  started_at timestamptz not null,
  ended_at timestamptz,
  summary jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (id, gym_id),
  constraint workout_sessions_member_fk foreign key (member_id, gym_id)
    references public.users (id, gym_id)
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  gym_id uuid,
  actor_id uuid,
  actor_role public.user_role,
  action text not null,
  entity text,
  entity_id uuid,
  meta jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index audit_log_gym_idx on public.audit_log (gym_id, created_at desc);

create sequence public.app_invoice_seq;

create function app.touch_updated_at() returns trigger
language plpgsql set search_path = app, public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger gyms_touch before update on public.gyms
  for each row execute function app.touch_updated_at();
create trigger users_touch before update on public.users
  for each row execute function app.touch_updated_at();
create trigger bookings_touch before update on public.bookings
  for each row execute function app.touch_updated_at();

commit;