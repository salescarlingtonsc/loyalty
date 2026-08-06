-- NESTLY v178 - VERIFY THE v176 DISPATCH SECRET AGAINST VAULT
--
-- Problem: the ai-firm-reports worker authenticated the pg_cron drain by
-- comparing the x-v176-dispatch-secret header against an edge-function
-- environment secret (AI_FIRM_REPORT_DISPATCH_SECRET) that the owner had to
-- copy out of Vault by hand. The value already lives in
-- vault.decrypted_secrets as `v176_dispatch_secret`, so the copy step is pure
-- operational friction and a drift risk (rotate one, forget the other).
--
-- Fix: a service-role-only SECURITY DEFINER verifier the worker can call. The
-- edge function first honours the env secret when it is set (explicit
-- configuration wins, and rotation via env stays possible), and falls back to
-- this RPC otherwise. The secret value itself never leaves Postgres.

begin;

create or replace function public.internal_verify_v176_dispatch_secret(
  p_secret text
)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_expected text;
begin
  if p_secret is null or length(p_secret) < 32 then
    return false;
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1'
      into v_expected using 'v176_dispatch_secret';
  exception when others then
    return false;
  end;
  if coalesce(v_expected, '') = '' or length(v_expected) < 32 then
    return false;
  end if;
  return length(p_secret) = length(v_expected) and p_secret = v_expected;
end
$$;
revoke all privileges on function public.internal_verify_v176_dispatch_secret(text)
  from public, anon, authenticated, service_role;
grant execute on function public.internal_verify_v176_dispatch_secret(text)
  to service_role;

comment on function public.internal_verify_v176_dispatch_secret(text) is
  'Service-role-only check used by the ai-firm-reports worker: does the supplied x-v176-dispatch-secret header match the Vault secret v176_dispatch_secret? Returns false (never raises) on missing/short/mismatched input so the worker can treat any non-true result as 401.';

commit;
