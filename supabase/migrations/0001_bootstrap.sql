-- GymOS 0001 — bootstrap: Supabase-compatible roles + app schema on plain PostgreSQL 16.
begin;

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

grant anon, authenticated, service_role to postgres;

create schema if not exists app;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema app to anon, authenticated, service_role;

-- authenticated = SELECT ONLY (writes go through vetted app.* functions).
alter default privileges for role postgres in schema public
  grant select on tables to authenticated;
alter default privileges for role postgres in schema public
  grant all on tables to service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to service_role;
alter default privileges for role postgres in schema public
  grant usage on types to anon, authenticated, service_role;
alter default privileges for role postgres in schema app
  grant execute on functions to anon, authenticated, service_role;

commit;