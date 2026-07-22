-- Local rehearsal bootstrap: minimal Supabase-compatible surface for the Frenly
-- canonical chain. Mirrors what the hosted platform provides before migration 1.
-- Documented deviations from production (both platform-provided there):
--   1. pg_cron   -> cron schema + job table + schedule()/unschedule() equivalents
--   2. supabase_vault -> vault schema + secrets table
-- The two CREATE EXTENSION statements for those are skipped at apply time.

-- API roles (cluster-level; idempotent)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

grant anon, authenticated, service_role to postgres;

-- Schemas the chain expects to exist
create schema if not exists extensions;
create schema if not exists vault;
create schema if not exists auth;
grant usage on schema extensions to anon, authenticated, service_role;

-- pg_cron equivalent (stub): the chain calls cron.schedule(...) in 4 migrations
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigint generated always as identity primary key,
  schedule text not null,
  command text not null,
  jobname text unique
);
create or replace function cron.schedule(job_name text, schedule text, command text)
returns bigint language sql as $$
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid;
$$;
create or replace function cron.schedule(schedule text, command text)
returns bigint language sql as $$
  insert into cron.job(schedule, command) values (schedule, command) returning jobid;
$$;
create or replace function cron.unschedule(job_name text)
returns boolean language sql as $$
  delete from cron.job where jobname = job_name returning true;
$$;

-- supabase_vault equivalent (stub)
create table if not exists vault.secrets (
  id uuid primary key default gen_random_uuid(),
  name text,
  description text,
  secret text,
  created_at timestamptz default now()
);

-- Supabase auth surface used by the chain and test fixtures
create table if not exists auth.users (
  instance_id uuid,
  id uuid primary key,
  aud varchar(255),
  role varchar(255),
  email varchar(255),
  encrypted_password varchar(255),
  email_confirmed_at timestamptz,
  invited_at timestamptz,
  confirmed_at timestamptz,
  phone text unique,
  phone_confirmed_at timestamptz,
  last_sign_in_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  is_super_admin boolean,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  );
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to public;

-- Realtime publication the chain alters
do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- Extensions genuinely available locally (Supabase installs these into "extensions")
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_stat_statements with schema extensions;
