-- Rollback-only acceptance for v417 — the company bio reaches the customer.
--   supabase db query --linked -f db/tests/v417_customer_bio.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21 (photo 7): "(shown on your portal)" struck off the Company bio label, and an
-- arrow from the field to the line under the business name in the customer app — "show here as
-- bio". businesses.bio has existed since v325 and the workspace always wrote it; no customer read
-- ever returned it, so every word was visible only to the firm that typed it.

begin;

create temp table _r(k text, v text) on commit drop;

do $$
begin
  if to_regprocedure('public.customer_get_business_summary(text)') is null then
    insert into _r values('00_deployed','FAIL customer_get_business_summary is not deployed');
    return;
  end if;
  insert into _r values('00_deployed','PASS customer_get_business_summary is deployed');

  insert into _r
  select '01_payload_carries_bio',
    case when pg_catalog.pg_get_functiondef(p.oid) ~ '''bio'', \(select b\.bio'
      then 'PASS the business payload now carries bio'
      else 'FAIL the bio is still absent from every customer read' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_business_summary';

  -- the wallet context view keeps the shape every other caller depends on: the bio is read with a
  -- scalar subquery off the row, exactly as v385 read industry_label.
  insert into _r
  select '02_context_view_untouched',
    case when pg_catalog.pg_get_functiondef(p.oid) ~ 'v32_customer_wallet_context'
      and pg_catalog.pg_get_functiondef(p.oid) !~ 'v_context\.business_bio'
      then 'PASS app.v32_customer_wallet_context was not widened for this'
      else 'FAIL the shared context view was changed' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_business_summary';

  insert into _r
  select '03_not_anon_callable',
    case when count(*)=0 then 'PASS anon cannot execute it'
         else 'FAIL a customer read is reachable without a session' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_business_summary'
    and has_function_privilege('anon', p.oid, 'execute');

  insert into _r
  select '04_authenticated_kept',
    case when count(*)=1 then 'PASS authenticated keeps execute'
         else 'FAIL the grant was lost' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_business_summary'
    and has_function_privilege('authenticated', p.oid, 'execute');
end $$;

select k as check, v as result from _r order by k;

rollback;
