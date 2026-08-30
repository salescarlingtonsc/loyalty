-- Rollback-only v659 acceptance suite (owner ruling 2026-08-31, given twice).
--
-- T1  A plan that HAS been sold now edits in place — same id, and no second catalogue row. This is
--     the owner's "edit should not create new"; v102 cloned on every edit and v655 narrowed that
--     to sold plans only.
-- T2  ...and the buyer keeps the name, sessions and price they paid for. This is the other half of
--     the ruling ("nothing change for customers who bought"), and it holds because
--     client_packages snapshots every fact at the moment of sale.
-- T3  The buyer's own wallet card (customer_get_packages) reads that snapshot. It was the ONE
--     reader anywhere still taking the plan's name and session count live, which is the only
--     reason editing a sold plan was ever unsafe. Fixing it also fixes a bug older than this
--     batch: `remaining` is stored on the purchase while the denominator was live, so raising a
--     plan from 5 sessions to 10 made a fully-used package read "0 of 10 left".
-- T4  Clone-on-edit is REMOVED, not left behind as unreachable code.
--
-- Run after the complete canonical chain through v659, in a disposable database or as a
-- rolled-back transaction against a prod-shaped instance. Substitute your own business and owner
-- ids for the literals below.
begin;
create temporary table v659_evidence(test text) on commit drop;
-- The assertions below run as the owner's own role, so that role must be able to record them.
grant insert, select on v659_evidence to authenticated;
-- Fixture: a plan with a real purchase against it, written with RLS out of the way
-- (client_packages is written only by sell_package_v102 in production).
do $fx$
declare v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
        v_client uuid; v_plan uuid;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  insert into public.package_plans(business_id,name,price_cents,sessions,active,version_no,expiry_days)
  values(v_biz,'V659 Probe Plan',20000,5,true,1,null) returning id into v_plan;
  insert into public.client_packages(business_id,client_id,plan_id,remaining,plan_name_snapshot,
    plan_version_snapshot,sessions_snapshot,price_cents_snapshot)
  values(v_biz,v_client,v_plan,0,'V659 Probe Plan',1,5,20000);
  perform set_config('v659.plan', v_plan::text, true);
end $fx$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"b8ba53b5-b20d-4d6d-b6fe-66f014758fab","role":"authenticated"}';

do $t$
declare v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
        v_plan uuid := current_setting('v659.plan')::uuid;
        v_new public.package_plans%rowtype; v_before int; v_after int;
begin
  select count(*) into v_before from public.package_plans where business_id=v_biz;
  -- The plan HAS been sold. Editing it must still edit it.
  select * into v_new from public.save_package_plan_v102(v_biz, v_plan,
    'V659 Probe Plan RENAMED', 99900, 10, null, true, 30);
  if v_new.id <> v_plan then
    raise exception 'T1 a SOLD plan must now edit in place, got a new id %', v_new.id; end if;
  select count(*) into v_after from public.package_plans where business_id=v_biz;
  if v_after <> v_before then
    raise exception 'T1 editing must not add a catalogue row (% -> %)', v_before, v_after; end if;
  if v_new.price_cents <> 99900 or v_new.sessions <> 10 then
    raise exception 'T1 the edit did not apply'; end if;
  insert into v659_evidence values('T1 ok - a SOLD plan edits in place: same id, no second catalogue row');
end $t$;

do $t$
declare v_plan uuid := current_setting('v659.plan')::uuid; r record;
begin
  -- The BUYER's row is untouched by that edit: every fact still says what they bought.
  select * into r from public.client_packages where plan_id=v_plan;
  if r.plan_name_snapshot <> 'V659 Probe Plan' then
    raise exception 'T2 the buyer''s package NAME changed to %', r.plan_name_snapshot; end if;
  if r.sessions_snapshot <> 5 then
    raise exception 'T2 the buyer''s session count changed to %', r.sessions_snapshot; end if;
  if r.price_cents_snapshot <> 20000 then
    raise exception 'T2 the buyer''s price changed to %', r.price_cents_snapshot; end if;
  insert into v659_evidence values('T2 ok - the buyer keeps the name, sessions and price they paid for');
end $t$;

reset role;
do $t$
declare v_src text;
begin
  -- The buyer's own wallet card no longer reads the live plan at all.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_packages';
  if position('join public.package_plans' in v_src) > 0 then
    raise exception 'T3 the wallet card still joins the live plan'; end if;
  if position('cp.plan_name_snapshot as plan_name' in v_src) = 0
     or position('cp.sessions_snapshot as sessions_purchased' in v_src) = 0 then
    raise exception 'T3 the wallet card is not reading the purchase snapshot'; end if;
  insert into v659_evidence values('T3 ok - the wallet card reads the purchase snapshot, not the live plan');
  -- And clone-on-edit is retired rather than merely bypassed.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='save_package_plan_v102';
  if position('supersedes_plan_id=v_previous.id' in v_src) > 0 then
    raise exception 'T4 the clone-on-edit branch is still present'; end if;
  insert into v659_evidence values('T4 ok - clone-on-edit is removed, not left behind as dead code');
end $t$;
select (select count(*) from v659_evidence) as assertions_passed,
       (select string_agg(test,' | ' order by test) from v659_evidence) as evidence,
       case when (select count(*) from v659_evidence)=4 then 'V659_SUITE_PASSED' else 'V659_SUITE_INCOMPLETE' end as verdict;

rollback;
