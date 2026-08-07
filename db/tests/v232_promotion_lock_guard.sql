-- V232 rollback verification: the promotion lock guard.
-- Run inside a transaction that is ROLLED BACK. Proves the success path is unchanged and
-- that both containment guards from the 2026-08-07 outage are actually installed.
begin;

-- (1) The abandoned-transaction reaper exists on the role PostgREST logs in as. This is
--     the guard that made a stuck advisory-lock holder permanent when it was absent.
do $$
declare v_config text[];
begin
  select rolconfig into v_config from pg_roles where rolname='authenticator';
  if not (v_config @> array['idle_in_transaction_session_timeout=60s']) then
    raise exception 'v232.role: authenticator is missing the idle-in-transaction reaper: %', v_config;
  end if;
end $$;

-- (2) The bounded wait is attached to the function, not to the caller's transaction, so
--     it reverts on exit and cannot silently change unrelated locking behaviour.
do $$
declare v_config text[];
begin
  select proconfig into v_config
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='v104_lock_promotion_business';
  if not (v_config @> array['lock_timeout=5s']) then
    raise exception 'v232.fn: promotion lock helper is missing its bounded wait: %', v_config;
  end if;
  if not (v_config @> array['search_path=pg_catalog, public, app, pg_temp']) then
    raise exception 'v232.fn: search_path pinning was lost: %', v_config;
  end if;
end $$;

-- (3) The success path is unchanged: an uncontended lock is still granted, still
--     transaction-scoped, and still re-entrant within one transaction.
do $$
declare v_business uuid:='00000000-0000-4000-8000-000000000231'::uuid;
begin
  perform app.v104_lock_promotion_business(v_business);
  perform app.v104_lock_promotion_business(v_business);  -- re-entrant, must not raise
  if not exists(
    select 1 from pg_locks
     where locktype='advisory' and pid=pg_backend_pid() and granted
  ) then
    raise exception 'v232.grant: the advisory lock was not granted on the success path';
  end if;
end $$;

-- (4) The guard raises a lock_not_available (55P03) that callers can distinguish, with
--     owner-readable wording rather than a raw Postgres timeout.
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='v104_lock_promotion_business';
  if v_src !~ 'when lock_not_available' then
    raise exception 'v232.handler: the timeout is not converted into a stated error';
  end if;
  if v_src !~ 'still saving' then
    raise exception 'v232.handler: the error does not tell the owner what to do';
  end if;
  if v_src !~ '55P03' then
    raise exception 'v232.handler: the error does not keep a distinguishable sqlstate';
  end if;
end $$;

rollback;
