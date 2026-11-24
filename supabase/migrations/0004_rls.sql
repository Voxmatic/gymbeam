-- GymOS 0004 — row-level security for core tables.
-- authenticated = SELECT ONLY (writes via vetted app.* functions). service_role = ALL (BYPASSRLS).
-- All staff checks are POSITIVE exists() via app.staff_gym()/app.branch_ok() (NULL-safe).
begin;

grant select on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

alter table public.gyms enable row level security;
alter table public.branches enable row level security;
alter table public.users enable row level security;
alter table public.membership_plans enable row level security;
alter table public.payments enable row level security;
alter table public.memberships enable row level security;
alter table public.classes enable row level security;
alter table public.class_sessions enable row level security;
alter table public.bookings enable row level security;
alter table public.check_ins enable row level security;
alter table public.workout_sessions enable row level security;
alter table public.audit_log enable row level security;

create policy gyms_super_all on public.gyms for all to service_role using (true) with check (true);
create policy gyms_staff_select on public.gyms for select to authenticated
  using (app.staff_gym(id) is not null);
create policy gyms_member_select on public.gyms for select to authenticated
  using (id = app.my_gym());

create policy branches_super_all on public.branches for all to service_role using (true) with check (true);
create policy branches_staff_select on public.branches for select to authenticated
  using (app.branch_ok(gym_id, id));
create policy branches_member_select on public.branches for select to authenticated
  using (gym_id = app.my_gym());

create policy users_super_all on public.users for all to service_role using (true) with check (true);
create policy users_staff_select on public.users for select to authenticated
  using (app.staff_gym(gym_id) is not null and app.branch_ok(gym_id, branch_id));
create policy users_member_select on public.users for select to authenticated
  using (id = app.uid());

create policy membership_plans_super_all on public.membership_plans for all to service_role using (true) with check (true);
create policy membership_plans_staff_select on public.membership_plans for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy membership_plans_member_select on public.membership_plans for select to authenticated
  using (gym_id = app.my_gym() and active);

create policy payments_super_all on public.payments for all to service_role using (true) with check (true);
create policy payments_staff_select on public.payments for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy payments_member_select on public.payments for select to authenticated
  using (member_id = app.uid());

create policy memberships_super_all on public.memberships for all to service_role using (true) with check (true);
create policy memberships_staff_select on public.memberships for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy memberships_member_select on public.memberships for select to authenticated
  using (member_id = app.uid());

create policy classes_super_all on public.classes for all to service_role using (true) with check (true);
create policy classes_staff_select on public.classes for select to authenticated
  using (app.branch_ok(gym_id, branch_id));
create policy classes_member_select on public.classes for select to authenticated
  using (gym_id = app.my_gym());

create policy class_sessions_super_all on public.class_sessions for all to service_role using (true) with check (true);
create policy class_sessions_staff_select on public.class_sessions for select to authenticated
  using (exists (select 1 from public.classes c where c.id = class_id and app.branch_ok(c.gym_id, c.branch_id)));
create policy class_sessions_member_select on public.class_sessions for select to authenticated
  using (gym_id = app.my_gym());

create policy bookings_super_all on public.bookings for all to service_role using (true) with check (true);
create policy bookings_staff_select on public.bookings for select to authenticated
  using (exists (
    select 1 from public.class_sessions s
    join public.classes c on c.id = s.class_id
    where s.id = session_id and app.branch_ok(c.gym_id, c.branch_id)));
create policy bookings_member_select on public.bookings for select to authenticated
  using (member_id = app.uid());

create policy check_ins_super_all on public.check_ins for all to service_role using (true) with check (true);
create policy check_ins_staff_select on public.check_ins for select to authenticated
  using (app.branch_ok(gym_id, branch_id));
create policy check_ins_member_select on public.check_ins for select to authenticated
  using (member_id = app.uid());

create policy workout_sessions_super_all on public.workout_sessions for all to service_role using (true) with check (true);
create policy workout_sessions_staff_select on public.workout_sessions for select to authenticated
  using (app.staff_gym(gym_id) is not null);
create policy workout_sessions_member_select on public.workout_sessions for select to authenticated
  using (member_id = app.uid());

create policy audit_log_super_all on public.audit_log for all to service_role using (true) with check (true);
create policy audit_log_staff_select on public.audit_log for select to authenticated
  using (app.staff_gym(gym_id) is not null);

commit;