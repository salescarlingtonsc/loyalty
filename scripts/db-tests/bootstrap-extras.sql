-- Supplemental rehearsal bootstrap for the executed-SQL harness.
--
-- db/tests/rehearsal/bootstrap.sql was written at v100 and stubs pg_cron, supabase_vault
-- and storage. The chain has since grown a pg_net dependency (v156/v176/v284) and the
-- suite needs an `authenticator` role. This file is applied immediately after the repo
-- bootstrap so the shared file stays untouched.
--
-- Everything here is a LOCAL stand-in for a platform-provided object. Nothing in this
-- file may change product behaviour: the stubs exist so DDL applies, not so calls succeed.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator nologin;
  end if;
end $$;

-- pg_net equivalent (stub). Production dispatches edge-function ticks through
-- net.http_post; every call site goes through EXECUTE and already tolerates the
-- extension being absent, so a no-op that returns a request id is faithful enough
-- for schema replay and for the behavioural suites (which never dispatch).
create schema if not exists net;
create table if not exists net._http_response (
  id bigint generated always as identity primary key,
  status_code integer,
  content jsonb,
  created timestamptz not null default now()
);
create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb,
  timeout_milliseconds integer default 5000
) returns bigint language sql as $$
  insert into net._http_response(status_code, content)
  values (0, jsonb_build_object('stub', true, 'url', url, 'body', body))
  returning id;
$$;
grant usage on schema net to postgres, service_role;

-- supabase_vault also exposes vault.decrypted_secrets (a view over vault.secrets that
-- decrypts in place). db/tests/rehearsal/bootstrap.sql stubs only the base table; the chain
-- reads the view from v197 onward. Local stub: the "decrypted" value is the stored value.
create or replace view vault.decrypted_secrets as
  select id, name, description, secret, secret as decrypted_secret, created_at
    from vault.secrets;
grant usage on schema vault to postgres, service_role;

-- vault.create_secret(): the chain mints two HMAC keys with it (v197 join QR, v327 member QR).
-- The local stub stores the plaintext, which is exactly what the decrypted_secrets stub reads
-- back — so token derivation is self-consistent inside the scratch cluster. It is NOT
-- encryption, and nothing in this cluster is ever a real secret.
create or replace function vault.create_secret(
  new_secret text, new_name text default null,
  new_description text default '', new_key_id uuid default null
) returns uuid language sql as $$
  insert into vault.secrets(name, description, secret)
  values (new_name, new_description, new_secret)
  returning id;
$$;
create or replace function vault.update_secret(
  secret_id uuid, new_secret text default null, new_name text default null,
  new_description text default null, new_key_id uuid default null
) returns void language sql as $$
  update vault.secrets
     set secret = coalesce(new_secret, secret),
         name = coalesce(new_name, name),
         description = coalesce(new_description, description)
   where id = secret_id;
$$;
