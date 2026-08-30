-- Rollback-only v655 acceptance suite (owner review, 2026-08-31).
--
-- T1  A superseded package plan can be deleted. package_plans.supersedes_plan_id is ON DELETE
--     RESTRICT, so before v655 the newer version pointed at the older one and every delete of an
--     edited package raised 23503 behind a generic "That change couldn't be saved" toast.
-- T2  Editing a package NOBODY has bought mutates it in place (owner ruling: "edit should not
--     create new > it should just edit that existing package") — same id, no extra catalogue row.
-- T3  Editing a package somebody HAS bought still clones. This is the half of v102's contract that
--     protects people who already paid: mutating in place would rewrite the price and the session
--     count on receipts and wallets they already hold.
-- T4  The new customer cancel is authenticated-only and unreachable by anon.
--
-- Run after the complete canonical chain through v655, in a disposable database or as a
-- rolled-back transaction against a prod-shaped instance. Substitute your own business, owner and
-- plan ids for the three literals below.
begin;

-- ---- acceptance, all rolled back, AS THE OWNER'S OWN ROLE ----
set local role authenticated;
set local request.jwt.claims = '{"sub":"b8ba53b5-b20d-4d6d-b6fe-66f014758fab","role":"authenticated"}';

do $t$
declare v_res json; v_cnt int;
begin
  select public.business_manage_package_plan_v193(
    '709387ff-5768-4767-9dad-abd665c2bb07','13d58bef-126e-4f7b-8d67-c1b0c727ce33','delete',null) into v_res;
  if v_res->>'status' <> 'ok' then raise exception 'T1 delete refused: %', v_res; end if;
  if (v_res->>'versions_unlinked')::int <> 1 then raise exception 'T1 expected 1 pointer released, got %', v_res->>'versions_unlinked'; end if;
  select count(*) into v_cnt from public.package_plans where id='13d58bef-126e-4f7b-8d67-c1b0c727ce33';
  if v_cnt <> 0 then raise exception 'T1 row survived the delete'; end if;
  select count(*) into v_cnt from public.package_plans where id='d24047bf-ceef-431f-9755-c37bf195f2f0';
  if v_cnt <> 1 then raise exception 'T1 the NEWER version must survive'; end if;
  raise notice 'T1 ok — a superseded plan deletes, the newer one survives';
end $t$;

do $t$
declare v_plan public.package_plans%rowtype; v_before int; v_after int;
begin
  select count(*) into v_before from public.package_plans where business_id='709387ff-5768-4767-9dad-abd665c2bb07';
  select * into v_plan from public.save_package_plan_v102(
    '709387ff-5768-4767-9dad-abd665c2bb07','d24047bf-ceef-431f-9755-c37bf195f2f0',
    '5x Haircut (Director)',40000,5,null,true,365);
  if v_plan.id <> 'd24047bf-ceef-431f-9755-c37bf195f2f0' then raise exception 'T2 edit cloned instead of mutating (new id %)', v_plan.id; end if;
  if v_plan.price_cents <> 40000 then raise exception 'T2 price not applied'; end if;
  select count(*) into v_after from public.package_plans where business_id='709387ff-5768-4767-9dad-abd665c2bb07';
  if v_after <> v_before then raise exception 'T2 an in-place edit must not add a row (% -> %)', v_before, v_after; end if;
  raise notice 'T2 ok — an unsold package is edited in place';
end $t$;

-- The purchase fixture is written with RLS out of the way (client_packages is written only by
-- sell_package_v102 in production); the EDIT under test then runs back as the owner.
reset role;
do $t$
declare v_client uuid; v_plan public.package_plans%rowtype;
begin
  select id into v_client from public.clients where business_id='709387ff-5768-4767-9dad-abd665c2bb07' limit 1;
  if v_client is null then raise notice 'T3 skipped — no client at this business'; return; end if;
  select * into v_plan from public.package_plans where id='d24047bf-ceef-431f-9755-c37bf195f2f0';
  insert into public.client_packages(business_id,client_id,plan_id,remaining,plan_name_snapshot,
    plan_version_snapshot,sessions_snapshot,price_cents_snapshot)
  values('709387ff-5768-4767-9dad-abd665c2bb07',v_client,v_plan.id,5,v_plan.name,
    v_plan.version_no,v_plan.sessions,v_plan.price_cents);
end $t$;
set local role authenticated;

do $t$
declare v_plan public.package_plans%rowtype; v_new public.package_plans%rowtype;
begin
  select * into v_plan from public.package_plans where id='d24047bf-ceef-431f-9755-c37bf195f2f0';
  if not exists(select 1 from public.client_packages where plan_id=v_plan.id) then
    raise notice 'T3 skipped — no purchase fixture'; return; end if;
  select * into v_new from public.save_package_plan_v102(
    '709387ff-5768-4767-9dad-abd665c2bb07', v_plan.id, v_plan.name, 99900, v_plan.sessions,
    v_plan.service_id, true, v_plan.expiry_days);
  if v_new.id = v_plan.id then raise exception 'T3 a SOLD plan must still clone, never mutate under the buyer'; end if;
  if v_new.supersedes_plan_id <> v_plan.id then raise exception 'T3 the clone must supersede the original'; end if;
  if (select price_cents from public.package_plans where id=v_plan.id) <> v_plan.price_cents then
    raise exception 'T3 the buyer''s version was rewritten'; end if;
  raise notice 'T3 ok — a sold package still versions and the buyer''s row is untouched';
end $t$;

do $t$
begin
  if not has_function_privilege('authenticated','public.customer_cancel_appointment_v655(text,uuid)','EXECUTE') then
    raise exception 'T4 customers cannot call the cancel'; end if;
  if has_function_privilege('anon','public.customer_cancel_appointment_v655(text,uuid)','EXECUTE') then
    raise exception 'T4 anon must NOT be able to cancel an appointment'; end if;
  raise notice 'T4 ok — cancel is authenticated-only';
end $t$;

reset role;
select 'V655_SUITE_PASSED' as verdict;

rollback;
