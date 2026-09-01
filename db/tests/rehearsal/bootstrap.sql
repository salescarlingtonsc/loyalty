-- Local rehearsal bootstrap: minimal Supabase-compatible surface for the Frenly
-- canonical chain. Mirrors what the hosted platform provides before migration 1.
-- Documented deviations from production (all platform-provided there):
--   1. pg_cron   -> cron schema + job table + schedule()/unschedule() equivalents
--   2. supabase_vault -> vault schema + secrets table
--   3. Storage -> storage schema + bucket metadata table
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
create schema if not exists storage;
grant usage on schema extensions to anon, authenticated, service_role;

-- pg_cron equivalent (stub): the chain calls cron.schedule(...) in 4 migrations
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigint generated always as identity primary key,
  schedule text not null,
  command text not null,
  jobname text unique,
  /* Real pg_cron carries `active`, and the chain depends on it: v601 pauses featureless jobs
     with cron.alter_job(active=>false) and selects `... and active`. Without the column the
     migration raises 42703 and every later migration is skipped. */
  active boolean not null default true
);

/* pg_cron writes one row per execution here; 9 migrations read it (retention sweeps, the
   run-history retention job). A table with the real column names is enough — nothing in the
   chain depends on rows appearing by themselves. */
create table if not exists cron.job_run_details (
  jobid bigint,
  runid bigint generated always as identity primary key,
  job_pid integer,
  database text,
  username text,
  command text,
  status text,
  return_message text,
  start_time timestamptz,
  end_time timestamptz
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

/* Deactivate-in-place, the shape v601 relies on: the registration and its history survive so a
   paused job reactivates with one call when its feature ships. Argument names and defaults match
   real pg_cron, because the callers use named notation (active => false). */
create or replace function cron.alter_job(
  job_id bigint,
  schedule text default null,
  command text default null,
  database text default null,
  username text default null,
  active boolean default null
) returns void language sql as $$
  update cron.job j set
    schedule = coalesce(alter_job.schedule, j.schedule),
    command  = coalesce(alter_job.command,  j.command),
    active   = coalesce(alter_job.active,   j.active)
  where j.jobid = alter_job.job_id;
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

-- Supabase Storage metadata used by the migration chain. These are rehearsal
-- stubs only; hosted Supabase owns both tables and the Storage API there.
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  name text not null,
  owner_id text,
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(bucket_id,name)
);
alter table storage.objects enable row level security;

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
