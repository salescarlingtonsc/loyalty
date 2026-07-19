-- Rollback-only assertions for the v13-rebased + v22-reconciled flat-commission model.
-- Run against rehearsal/production AFTER frenly_v22_flat_commission_reconciliation.
-- Creates synthetic staff/services/appointments/sales inside one transaction and ends
-- with ROLLBACK — nothing is committed. Requires at least one business that has an
-- active owner login (staff.user_id) and one client.
begin;

do $v22_test$
declare
  v_biz uuid;
  v_client uuid;
  v_owner uuid;
  v_staff uuid; v_svc uuid; v_svc2 uuid;
  v_appt uuid; v_appt2 uuid; v_appt3 uuid;
  v_sf uuid; v_sp uuid; v_sz uuid; v_revid uuid;
  ff integer; camt integer; rev_comm integer; res json;
begin
  -- 0. ACL contract (the v22 fix itself): owner-only SECURITY DEFINER resolver.
  if exists (
    select 1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'commission_flat_cents'
       and (not p.prosecdef
            or has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute')
            or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                        where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'))
  ) then
    raise exception 'app.commission_flat_cents must be SECURITY DEFINER with an owner-only ACL (v22)';
  end if;

  -- Fixture tenant: any business with an active owner login and a client.
  select st.business_id, st.user_id into v_biz, v_owner
    from public.staff st
   where st.role = 'owner' and st.active and st.user_id is not null
   limit 1;
  if v_biz is null then
    raise exception 'v22 suite requires a business with an active owner login';
  end if;
  select id into v_client from public.clients where business_id = v_biz limit 1;
  if v_client is null then
    raise exception 'v22 suite requires at least one client in the fixture business';
  end if;

  insert into public.staff(business_id, role) values (v_biz,'staff') returning id into v_staff;
  insert into public.services(business_id,name,price_cents,duration_min,commission_flat_cents,commission_bps)
    values (v_biz,'v22 flat svc',3000,30,500,1000) returning id into v_svc;
  insert into public.services(business_id,name,price_cents,duration_min,commission_flat_cents,commission_bps)
    values (v_biz,'v22 pct svc',3000,30,null,1000) returning id into v_svc2;
  insert into public.appointments(business_id,client_id,starts_at,ends_at,service_id,staff_id)
    values (v_biz,v_client,now(),now()+interval '30 min',v_svc,v_staff) returning id into v_appt;
  insert into public.appointments(business_id,client_id,starts_at,ends_at,service_id,staff_id)
    values (v_biz,v_client,now(),now()+interval '30 min',v_svc2,v_staff) returning id into v_appt2;
  insert into public.appointments(business_id,client_id,starts_at,ends_at,service_id,staff_id)
    values (v_biz,v_client,now(),now()+interval '30 min',v_svc,v_staff) returning id into v_appt3;

  -- 1. RESOLVER: flat holds across prices; $0 / non-service / no-staff fold to NULL.
  if app.commission_flat_cents(v_biz,'service',v_staff,v_appt,now(),3000) is distinct from 500 then
    raise exception 'R1: flat@3000 must be 500'; end if;
  if app.commission_flat_cents(v_biz,'service',v_staff,v_appt,now(),6000) is distinct from 500 then
    raise exception 'R2: flat must HOLD 500 at 6000 (a %% cannot)'; end if;
  if app.commission_flat_cents(v_biz,'service',v_staff,v_appt,now(),0) is not null then
    raise exception 'R3: $0 sale must resolve NULL flat (Q13 deferral)'; end if;
  if app.commission_flat_cents(v_biz,'retail',v_staff,v_appt,now(),3000) is not null then
    raise exception 'R4: non-service kind must resolve NULL flat'; end if;
  if app.commission_flat_cents(v_biz,'service',null,v_appt,now(),3000) is not null then
    raise exception 'R5: no-staff must resolve NULL flat'; end if;

  -- 2. SNAPSHOT TRIGGER (still functions as owner after the v22 revoke).
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,staff_id,appointment_id)
    values (v_biz,v_client,'service',3000,now(),v_staff,v_appt) returning id into v_sf;
  select commission_flat_cents into ff from public.sales where id = v_sf;
  if ff is distinct from 500 then raise exception 'T1: flat sale must snapshot 500 (got %)', ff; end if;

  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,staff_id,appointment_id)
    values (v_biz,v_client,'service',3000,now(),v_staff,v_appt2) returning id into v_sp;
  select commission_flat_cents into ff from public.sales where id = v_sp;
  if ff is not null then raise exception 'T2: percentage sale must snapshot NULL flat (got %)', ff; end if;

  update public.services set commission_flat_cents = 0 where id = v_svc;
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,staff_id,appointment_id)
    values (v_biz,v_client,'service',3000,now(),v_staff,v_appt3) returning id into v_sz;
  select commission_flat_cents into ff from public.sales where id = v_sz;
  if ff is distinct from 0 then raise exception 'T4: flat-zero must snapshot 0 and beat the %% (got %)', ff; end if;

  -- 3. FULL REVERSAL through the sanctioned RPC: reversal inherits the flat snapshot, nets -flat.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  res := public.reverse_sale(v_biz, v_sf, 'v22 flat clawback verification test', 'v22revidem123');
  v_revid := (res->>'reversal_sale_id')::uuid;
  select commission_flat_cents, amount_cents into ff, camt from public.sales where id = v_revid;
  if ff is distinct from 500 then raise exception 'T3: reversal must inherit flat 500 (got %)', ff; end if;
  if camt is distinct from -3000 then raise exception 'T3: reversal amount must be -3000 (got %)', camt; end if;

  -- 4. VIEW ARITHMETIC (same CASE as public.sale_commission, on the rows'' own snapshots):
  --    flat=500 · pct=300 · flat-zero=0 · reversal=-500.
  select case when commission_flat_cents is not null
              then (case when reversal_of is not null and amount_cents < 0
                         then -commission_flat_cents else commission_flat_cents end)
              when reversal_of is not null and amount_cents < 0
                then -floor((-amount_cents) * commission_rate_bps / 10000.0)::integer
              else floor(amount_cents * commission_rate_bps / 10000.0)::integer end
    into rev_comm from public.sales where id = v_sf;
  if rev_comm <> 500 then raise exception 'V1: flat commission must be 500 (got %)', rev_comm; end if;
  select case when commission_flat_cents is not null
              then (case when reversal_of is not null and amount_cents < 0
                         then -commission_flat_cents else commission_flat_cents end)
              when reversal_of is not null and amount_cents < 0
                then -floor((-amount_cents) * commission_rate_bps / 10000.0)::integer
              else floor(amount_cents * commission_rate_bps / 10000.0)::integer end
    into rev_comm from public.sales where id = v_sp;
  if rev_comm <> 300 then raise exception 'V2: percentage commission must be 300 (got %)', rev_comm; end if;
  select case when commission_flat_cents is not null
              then (case when reversal_of is not null and amount_cents < 0
                         then -commission_flat_cents else commission_flat_cents end)
              when reversal_of is not null and amount_cents < 0
                then -floor((-amount_cents) * commission_rate_bps / 10000.0)::integer
              else floor(amount_cents * commission_rate_bps / 10000.0)::integer end
    into rev_comm from public.sales where id = v_sz;
  if rev_comm <> 0 then raise exception 'V4: flat-zero commission must be 0, not the %% (got %)', rev_comm; end if;
  select case when commission_flat_cents is not null
              then (case when reversal_of is not null and amount_cents < 0
                         then -commission_flat_cents else commission_flat_cents end)
              when reversal_of is not null and amount_cents < 0
                then -floor((-amount_cents) * commission_rate_bps / 10000.0)::integer
              else floor(amount_cents * commission_rate_bps / 10000.0)::integer end
    into rev_comm from public.sales where id = v_revid;
  if rev_comm <> -500 then raise exception 'V3: reversal commission must net -500 (got %)', rev_comm; end if;

  raise notice 'v22 flat-commission suite: ALL PASS (ACL + resolver + snapshot + reversal + view)';
end $v22_test$;

rollback;
