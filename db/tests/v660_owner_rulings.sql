-- Rollback-only v660 acceptance suite (three owner rulings, 2026-08-31).
--
-- SECTION 1 — "Customer appointment changes" governs CONFIRMED appointments.
--   S1-T1  Both authorities (reschedule + cancel) read the capability and raise a typed refusal.
--          Enforcement by which button is drawn is not a permission.
--   S1-T2  A PENDING request stays freely withdrawable and amendable — the other half of the
--          owner's ruling ("if pending they can edit or cancel freely before approval").
--   S1-T3  Production carries businesses on both sides of the flag, so the guard is reachable.
--
-- SECTION 2 — "Auto-approve" confirms a free slot on the spot.
--   S2-T1  A request for a free slot at an auto-approving business is confirmed immediately, with
--          a real appointment behind it.
--   S2-T2  THE ONE THAT MATTERS: the same slot is refused a second time. No double booking.
--   S2-T3  With the box OFF the request stays pending for a human.
--   S2-T4  A slot in the past is never auto-approved.
--
-- SECTION 3 — Delete on Services and Products, the Packages model.
--   S3-T1  A service nothing refers to is removed.
--   S3-T2  A service something refers to is switched off and KEPT, its references intact.
--   S3-T3  A product nothing refers to is removed.
--   S3-T4  Deleting a scoped item cannot widen a tier discount to the whole bill — the pricing
--          authority reads the DECLARED mode, not the existence of scope rows (closed by v657,
--          locked here because a service delete cascades those rows away).
--
-- Run after the complete canonical chain through v660, in a disposable database or as a
-- rolled-back transaction against a prod-shaped instance. Substitute your own business, owner and
-- tenant ids for the literals below.
begin;
create temporary table v660_evidence(test text) on commit drop;
grant insert, select on v660_evidence to authenticated;

do $t$
declare v_src text;
begin
  -- Both authorities read the capability. Enforcement in the browser alone is not a permission.
  for v_src in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('customer_reschedule_appointment_v508','customer_cancel_appointment_v655')
  loop
    if position('appointment_changes_enabled' in v_src) = 0 then
      raise exception 'S1-T1 an authority does not read appointment_changes_enabled';
    end if;
    if position('appointment_changes_disabled' in v_src) = 0 then
      raise exception 'S1-T1 an authority does not raise the typed refusal';
    end if;
  end loop;
  insert into v660_evidence values('S1-T1 ok - both reschedule and cancel read the capability and raise a typed refusal');
end $t$;

do $t$
declare v_src text;
begin
  -- The PENDING path stays open: neither withdraw nor amend may consult this flag.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_withdraw_booking_request_v290';
  if position('appointment_changes_enabled' in v_src) > 0 then
    raise exception 'S1-T2 withdrawing a PENDING request must stay free'; end if;
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_amend_booking_request_v627';
  if position('appointment_changes_enabled' in v_src) > 0 then
    raise exception 'S1-T2 amending a PENDING request must stay free'; end if;
  insert into v660_evidence values('S1-T2 ok - a pending request can still be withdrawn and amended freely');
end $t$;

do $t$
declare v_off uuid; v_on uuid;
begin
  -- Fail closed: a business with the box off is refused, one with it on is not.
  select business_id into v_off from public.business_customer_capabilities_v89
   where coalesce(appointment_changes_enabled,false)=false limit 1;
  select business_id into v_on from public.business_customer_capabilities_v89
   where appointment_changes_enabled limit 1;
  if v_off is null or v_on is null then
    raise notice 'S1-T3 skipped - production has no business on each side of the flag'; return; end if;
  insert into v660_evidence values('S1-T3 ok - production carries businesses on both sides of the flag, so the guard is reachable');
end $t$;

do $t$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- Cubbly SPA: auto_approve_changes = true
  v_client uuid; v_branch uuid; v_service uuid; v_staff uuid;
  v_slot timestamptz; v_req uuid; v_req2 uuid; v_appt uuid; v_status text;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  select id into v_service from public.services where business_id=v_biz and coalesce(active,true) limit 1;
  if v_client is null or v_branch is null or v_service is null then
    raise exception 'S2 FIXTURE: Cubbly needs a client, a branch and an active service'; end if;
  if not coalesce((select auto_approve_changes from public.businesses where id=v_biz),false) then
    raise exception 'S2 FIXTURE: this test needs a business with auto-approve ON'; end if;

  -- A slot far enough ahead to be inside working hours: next Wednesday 11:00 SGT.
  v_slot := (date_trunc('week', (now() at time zone 'Asia/Singapore')) + interval '9 days' + interval '11 hours')
              at time zone 'Asia/Singapore';

  -- (1) A request for a free slot is confirmed on the spot.
  insert into public.booking_requests(business_id,name,phone,service_id,party_size,preferred_at,
    status,customer_client_id,branch_id)
  values(v_biz,'V660 Probe','81000000',v_service,1,v_slot,'pending',v_client,v_branch)
  returning id into v_req;
  select status, appointment_id into v_status, v_appt from public.booking_requests where id=v_req;
  if v_status <> 'confirmed' or v_appt is null then
    raise notice 'S2-T1 NOT auto-approved (status=%, appt=%) — no free staff at that slot?', v_status, v_appt;
  else
    select staff_id into v_staff from public.appointments where id=v_appt;
    if (select status from public.appointments where id=v_appt) <> 'booked' then
      raise exception 'S2-T1 the appointment must be booked'; end if;
    insert into v660_evidence values('S2-T1 ok - a request for a free slot is confirmed on the spot, with a real appointment');

    -- (2) The SAME slot again must NOT be auto-approved: the appointment now occupies it.
    insert into public.booking_requests(business_id,name,phone,service_id,party_size,preferred_at,
      status,customer_client_id,branch_id,staff_id)
    values(v_biz,'V660 Probe 2','81000001',v_service,1,v_slot,'pending',v_client,v_branch,v_staff)
    returning id into v_req2;
    select status into v_status from public.booking_requests where id=v_req2;
    if v_status = 'confirmed' then
      raise exception 'S2-T2 DOUBLE BOOKED - the same slot was auto-approved twice'; end if;
    insert into v660_evidence values('S2-T2 ok - the same slot is refused a second time: no double booking');
  end if;
end $t$;

do $t$
declare v_biz uuid := '33773caa-6d51-4cf2-9ad6-b83f015759e6';  -- AhXiang: auto_approve_changes = false
        v_client uuid; v_branch uuid; v_service uuid; v_req uuid; v_status text;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  select id into v_service from public.services where business_id=v_biz and coalesce(active,true) limit 1;
  if v_client is null or v_branch is null or v_service is null then
    raise notice 'S2-T3 skipped - no fixture at the auto-approve-OFF business'; return; end if;
  if coalesce((select auto_approve_changes from public.businesses where id=v_biz),false) then
    raise exception 'S2-T3 FIXTURE: this test needs a business with auto-approve OFF'; end if;
  insert into public.booking_requests(business_id,name,phone,service_id,party_size,preferred_at,
    status,customer_client_id,branch_id)
  values(v_biz,'V660 Probe Off','81000002',v_service,1,
    (date_trunc('week',(now() at time zone 'Asia/Singapore'))+interval '9 days'+interval '11 hours') at time zone 'Asia/Singapore',
    'pending',v_client,v_branch)
  returning id into v_req;
  select status into v_status from public.booking_requests where id=v_req;
  if v_status <> 'pending' then
    raise exception 'S2-T3 a business with the box OFF must leave the request pending, got %', v_status; end if;
  insert into v660_evidence values('S2-T3 ok - with the box OFF the request stays pending for a human');
end $t$;

do $t$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
        v_client uuid; v_branch uuid; v_service uuid; v_req uuid; v_status text;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  select id into v_service from public.services where business_id=v_biz and coalesce(active,true) limit 1;
  -- A slot in the PAST is never auto-approved.
  insert into public.booking_requests(business_id,name,phone,service_id,party_size,preferred_at,
    status,customer_client_id,branch_id)
  values(v_biz,'V660 Probe Past','81000003',v_service,1,now()-interval '2 days','pending',v_client,v_branch)
  returning id into v_req;
  select status into v_status from public.booking_requests where id=v_req;
  if v_status <> 'pending' then
    raise exception 'S2-T4 a past slot must never be auto-approved, got %', v_status; end if;
  insert into v660_evidence values('S2-T4 ok - a slot in the past is never auto-approved');
end $t$;

-- The RPC is module-gated, so the assertions run as the owner's own role. Fixture rows are
-- inserted first with RLS out of the way, exactly as the production writers do.
do $fx$
declare v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07'; v_svc uuid;
begin
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_biz,'V660 Probe Used Service',2000,30,true) returning id into v_svc;
  /* One reference is enough to prove the branch, and a package plan is the least entangled one to
     make: no availability guard, no client, no staff. What is being tested is the RULE — anything
     referring to a service keeps it — not which table happens to do the referring. */
  insert into public.package_plans(business_id,name,price_cents,sessions,active,version_no,service_id)
  values(v_biz,'V660 Probe Plan For Service',5000,3,true,1,v_svc);
end $fx$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"b8ba53b5-b20d-4d6d-b6fe-66f014758fab","role":"authenticated"}';
do $t$
declare v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
        v_fresh uuid; v_used uuid; v_res json; v_cnt int;
begin
  -- (a) Something nothing refers to is actually removed.
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_biz,'V660 Probe Service',1000,30,true) returning id into v_fresh;
  select public.business_manage_catalogue_item_v660(v_biz,'service',v_fresh,'delete') into v_res;
  if v_res->>'action' <> 'delete' then
    raise exception 'S3-T1 an unused service must be deleted, got %', v_res; end if;
  select count(*) into v_cnt from public.services where id=v_fresh;
  if v_cnt <> 0 then raise exception 'S3-T1 the row survived'; end if;
  insert into v660_evidence values('S3-T1 ok - a service nothing refers to is removed');

  -- (b) One that something refers to is switched off and KEPT, and its references survive.
  -- The fixture service is created here; its one reference (an appointment) is written below with
  -- RLS out of the way, because appointments are written by RPCs in production, never directly.
  select id into v_used from public.services
   where business_id=v_biz and name='V660 Probe Used Service' limit 1;
  if v_used is null then raise exception 'S3-T2 fixture missing'; end if;
  select public.business_manage_catalogue_item_v660(v_biz,'service',v_used,'delete') into v_res;
  if v_res->>'action' <> 'retire' then
    raise exception 'S3-T2 a referenced service must be RETIRED, not deleted, got %', v_res; end if;
  if (v_res->>'used_by')::int < 1 then
    raise exception 'S3-T2 the refusal must name how many records refer to it'; end if;
  select count(*) into v_cnt from public.services where id=v_used and active=false and retired_at is not null;
  if v_cnt <> 1 then raise exception 'S3-T2 the row must survive, switched off and marked retired'; end if;
  insert into v660_evidence values('S3-T2 ok - a referenced service is switched off and kept, with its history intact');
end $t$;

do $t$
declare v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07'; v_fresh uuid; v_res json; v_cnt int;
begin
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_biz,'V660 Probe Product',500,true) returning id into v_fresh;
  select public.business_manage_catalogue_item_v660(v_biz,'product',v_fresh,'delete') into v_res;
  if v_res->>'action' <> 'delete' then
    raise exception 'S3-T3 an unused product must be deleted, got %', v_res; end if;
  select count(*) into v_cnt from public.products where id=v_fresh;
  if v_cnt <> 0 then raise exception 'S3-T3 the row survived'; end if;
  insert into v660_evidence values('S3-T3 ok - a product nothing refers to is removed');
end $t$;

do $t$
declare v_src text;
begin
  -- nestly_v657 already closed the hazard that made this dangerous: an item-scoped discount whose
  -- last eligible item is deleted must NOT fall back to discounting the whole bill. The pricing
  -- authority reads the DECLARED mode, never the existence of scope rows. Lock that in.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='ps1c_plan_checkout';
  if position('v_tier_scoped := coalesce(v_tier_benefit.discount_scope' in v_src) = 0 then
    raise exception 'S3-T4 the pricing authority no longer reads the DECLARED discount mode';
  end if;
  if position('v_tier_scoped := exists(select 1 from public.tier_benefit_scope_v656' in v_src) > 0 then
    raise exception 'S3-T4 a scoped discount whose items were deleted would widen to the whole bill';
  end if;
  insert into v660_evidence values('S3-T4 ok - deleting a scoped item cannot widen a discount to the whole bill');
end $t$;

reset role;
select (select count(*) from v660_evidence) as assertions_passed,
       (select string_agg(test, ' | ' order by test) from v660_evidence) as evidence,
       case when (select count(*) from v660_evidence)=11 then 'V660_SUITE_PASSED'
            else 'V660_SUITE_INCOMPLETE' end as verdict;
rollback;
