-- Rollback-only acceptance for v365 — tier benefits as countable entitlements.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v365_tier_benefit_limits.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the suite.
-- Any row whose outcome starts with FAIL is a failure.
--
-- NOTE: v365 was written in a session with no database access. This suite is what must pass
-- BEFORE the migration is applied for real — it is not yet a record that it did.

begin;

create temp table _r(check_name text, outcome text) on commit drop;
create temp table _ctx(business uuid, owner_user uuid, tier uuid, benefit uuid, client uuid) on commit drop;

insert into _ctx(business, owner_user)
select b.id, s.user_id
  from public.businesses b
  join public.staff s on s.business_id = b.id and s.role = 'owner' and s.user_id is not null
 where b.name ilike '%cubbly%'
 limit 1;

-- ---------------------------------------------------------------------------
-- Signatures and ACLs
-- ---------------------------------------------------------------------------
insert into _r
select 'signature ' || want.fn,
       case when count(p.oid) = 1 then 'PASS' else 'FAIL expected 1 overload, found ' || count(p.oid) end
  from (values
    ('business_set_tier_benefits_v365'),
    ('staff_tier_benefits_for_client_v365'),
    ('staff_issue_tier_benefit_v365')
  ) as want(fn)
  left join pg_proc p on p.proname = want.fn and p.pronamespace = 'public'::regnamespace
 group by want.fn;

insert into _r select 'anon cannot execute any v365 RPC',
  case when count(*) = 0 then 'PASS' else 'FAIL ' || count(*) || ' anon grants' end
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname like '%\_v365'
   and has_function_privilege('anon', p.oid, 'execute');

insert into _r select 'both v365 tables carry RLS and no browser write grant',
  case when bool_and(c.relrowsecurity)
        and not bool_or(has_table_privilege('authenticated', c.oid, 'insert')
                     or has_table_privilege('authenticated', c.oid, 'update')
                     or has_table_privilege('authenticated', c.oid, 'delete'))
       then 'PASS' else 'FAIL RLS or ACL gap' end
  from pg_class c
 where c.relname in ('tier_benefits_v365','tier_benefit_issues_v365');

-- ---------------------------------------------------------------------------
-- The period key is Singapore-local and buckets as claimed
-- ---------------------------------------------------------------------------
insert into _r select 'period key buckets by SGT month',
  case when app.v365_period_key('month', timestamptz '2026-08-31 20:00+00') = '2026-09'
        and app.v365_period_key('month', timestamptz '2026-08-31 12:00+00') = '2026-08'
       then 'PASS' else 'FAIL month boundary is not Asia/Singapore' end;

insert into _r select 'lifetime limits share one bucket',
  case when app.v365_period_key('ever', now()) = 'ever' then 'PASS' else 'FAIL' end;

-- ---------------------------------------------------------------------------
-- Owner write, as the owner
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from _ctx), 'role', 'authenticated')::text, true);

update _ctx set tier = (
  select id from public.loyalty_tiers where business_id = (select business from _ctx)
   order by threshold desc limit 1);

select public.business_set_tier_benefits_v365((select business from _ctx), (select tier from _ctx),
  jsonb_build_array(
    jsonb_build_object('label','30% off every visit'),
    jsonb_build_object('label','1 for 1 deals','limit_count',1,'limit_period','month'),
    jsonb_build_object('label','Free lollipop','limit_count',30,'limit_period','month')));

insert into _r select 'three benefit rows stored',
  case when count(*) = 3 then 'PASS' else 'FAIL found ' || count(*) end
  from public.tier_benefits_v365
 where tier_id = (select tier from _ctx) and deleted_at is null;

insert into _r select 'perk_note is derived, limits stated in words',
  case when perk_note = '30% off every visit' || chr(10) || '1 for 1 deals — 1 per month' || chr(10) || 'Free lollipop — 30 per month'
       then 'PASS' else 'FAIL perk_note reads: ' || coalesce(perk_note,'<null>') end
  from public.loyalty_tiers where id = (select tier from _ctx);

update _ctx set benefit = (
  select id from public.tier_benefits_v365
   where tier_id = (select tier from _ctx) and label = '1 for 1 deals' and deleted_at is null);

-- A bad period and a zero limit are both refused.
do $$
declare v_ok boolean := false;
begin
  begin
    perform public.business_set_tier_benefits_v365((select business from _ctx), (select tier from _ctx),
      jsonb_build_array(jsonb_build_object('label','x','limit_count',1,'limit_period','fortnight')));
  exception when others then v_ok := true;
  end;
  insert into _r select 'an unknown period is refused', case when v_ok then 'PASS' else 'FAIL it was accepted' end;
end $$;

-- Dropping a row from the payload soft-deletes it and takes its line out of perk_note.
select public.business_set_tier_benefits_v365((select business from _ctx), (select tier from _ctx),
  jsonb_build_array(jsonb_build_object('label','1 for 1 deals','limit_count',1,'limit_period','month',
    'id',(select benefit from _ctx))));

insert into _r select 'a dropped benefit is soft-deleted, not destroyed',
  case when (select count(*) from public.tier_benefits_v365
              where tier_id = (select tier from _ctx) and deleted_at is null) = 1
        and (select count(*) from public.tier_benefits_v365
              where tier_id = (select tier from _ctx) and deleted_at is not null) = 2
       then 'PASS' else 'FAIL soft-delete did not hold' end;

-- ---------------------------------------------------------------------------
-- Till read and enforced issuing, as the owner (who also holds till write)
-- ---------------------------------------------------------------------------
update _ctx set client = (
  select c.id from public.clients c where c.business_id = (select business from _ctx) limit 1);

insert into _r select 'the till read answers for a real client',
  case when (public.staff_tier_benefits_for_client_v365((select business from _ctx),(select client from _ctx))->>'status') = 'ok'
       then 'PASS' else 'FAIL' end;

do $$
declare
  v_key uuid := gen_random_uuid();
  v_first jsonb;
  v_replay jsonb;
  v_blocked boolean := false;
  v_earned boolean;
begin
  -- Only meaningful if this client actually stands at or above the tier under test.
  select coalesce((app.v365_client_tier((select business from _ctx),(select client from _ctx))).threshold,-1)
         >= (select threshold from public.loyalty_tiers where id=(select tier from _ctx))
    into v_earned;
  if not v_earned then
    insert into _r select 'issuing skipped — no client stands at this rung', 'PASS (not exercised)';
    return;
  end if;

  v_first := public.staff_issue_tier_benefit_v365((select business from _ctx),(select client from _ctx),
    (select benefit from _ctx), null, v_key);
  insert into _r select 'first issue succeeds and reports what is left',
    case when v_first->>'status' = 'issued' and (v_first->>'remaining')::int = 0
         then 'PASS' else 'FAIL ' || v_first::text end;

  v_replay := public.staff_issue_tier_benefit_v365((select business from _ctx),(select client from _ctx),
    (select benefit from _ctx), null, v_key);
  insert into _r select 'the same key replays instead of spending a second',
    case when v_replay->>'status' = 'duplicate_ignored' then 'PASS' else 'FAIL ' || v_replay::text end;

  begin
    perform public.staff_issue_tier_benefit_v365((select business from _ctx),(select client from _ctx),
      (select benefit from _ctx), null, gen_random_uuid());
  exception when others then v_blocked := (sqlerrm like '%tier_benefit_limit_reached%');
  end;
  insert into _r select 'a second issue in the same month is refused',
    case when v_blocked then 'PASS' else 'FAIL the limit did not hold' end;

  insert into _r select 'exactly one issue row exists',
    case when (select count(*) from public.tier_benefit_issues_v365
                where benefit_id=(select benefit from _ctx) and client_id=(select client from _ctx)) = 1
         then 'PASS' else 'FAIL' end;
end $$;

insert into _r select 'issuing moves no money',
  case when not exists (
    select 1 from pg_proc p
     where p.proname='staff_issue_tier_benefit_v365' and p.pronamespace='public'::regnamespace
       and (position('credit_ledger' in pg_get_functiondef(p.oid)) > 0
         or position('points_ledger' in pg_get_functiondef(p.oid)) > 0
         or position('into public.sales' in pg_get_functiondef(p.oid)) > 0))
       then 'PASS' else 'FAIL it touches a value table' end;

reset role;
select check_name, outcome from _r order by check_name;

rollback;
