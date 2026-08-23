-- nestly_v482_loyalty_fence_null_guard.sql
-- SQL three-valued logic makes NULL NOT IN (...) evaluate to NULL, not TRUE.
-- Treat absence of this backend's advisory lock as an explicit denied mode.

begin;

create or replace function app.require_loyalty_shared_v480()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business uuid := case when tg_op = 'DELETE' then old.business_id else new.business_id end;
begin
  if coalesce(app.loyalty_fence_mode_v480(v_business),'') not in ('shared','exclusive') then
    raise exception 'loyalty value write requires a transaction fence'
      using errcode='55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

revoke all on function app.require_loyalty_shared_v480() from public, anon, authenticated;

do $v482_check$
begin
  if position('coalesce(app.loyalty_fence_mode_v480(v_business)' in lower(
       pg_catalog.pg_get_functiondef('app.require_loyalty_shared_v480()'::regprocedure)))=0
     or position('not in' in lower(
       pg_catalog.pg_get_functiondef('app.require_loyalty_shared_v480()'::regprocedure)))=0 then
    raise exception 'v482 postcondition: NULL lock mode is not explicitly denied';
  end if;
end
$v482_check$;

commit;
