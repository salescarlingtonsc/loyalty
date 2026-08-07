-- V233 rollback verification: admin sessions carry the same abandoned-transaction reaper
-- that v232 gave the API role. Run inside a transaction that is ROLLED BACK.
begin;
do $$
declare v_config text[];
begin
  select rolconfig into v_config from pg_roles where rolname='postgres';
  if not (v_config @> array['idle_in_transaction_session_timeout=15min']) then
    raise exception 'v233.role: postgres is missing the idle-in-transaction reaper: %', v_config;
  end if;
  -- The API role's tighter 60s reaper from v232 must still be present — v233 adds a
  -- second net, it must not have replaced or loosened the first.
  select rolconfig into v_config from pg_roles where rolname='authenticator';
  if not (v_config @> array['idle_in_transaction_session_timeout=60s']) then
    raise exception 'v233.role: the v232 authenticator reaper was lost: %', v_config;
  end if;
end $$;
rollback;
