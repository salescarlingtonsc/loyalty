-- Rollback-only acceptance for NESTLY v620 — one entitlement authority.
--
-- Proves, at the server boundary only:
--   · app.business_operational_v620 answers the full billing matrix (trial live/expired,
--     paid inside/outside the 14-day grace, paused, unapproved, incomplete, no subscription);
--   · app.business_workspace_open_v94 is spliced onto that authority, so the four tenant
--     gates lock with billing rather than approval alone;
--   · a LOCKED owner keeps the billing escape hatch (get_business_billing_v124 must not
--     raise 42501) and can read WHY they are locked (get_business_entitlement_v620);
--   · a stranger cannot read another firm's entitlement (42501).
--
-- Self-contained fixtures (gen_random_uuid), count deltas rather than absolute counts, and
-- one transaction that ends in rollback — safe to run against production.
begin;

-- One session simulator for the whole suite. p_method drives the amr claim shape that v625
-- reads; p_role null means "keep the privileged session role, only change identity".
create or replace function pg_temp.as_v620_session(
  p_uid uuid,
  p_method text default 'password',
  p_role text default 'authenticated'
) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then
    return;
  end if;
  if p_role is not null then
    execute format('set local role %I',p_role);
  end if;
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',p_uid,
      'role',coalesce(p_role,'authenticated'),
      'amr',jsonb_build_array(
        jsonb_build_object('method',p_method,'timestamp',1756500000)
      ),
      'app_metadata',case when p_method='oauth'
        then jsonb_build_object(
          'provider','google','providers',jsonb_build_array('email','google'))
        else jsonb_build_object(
          'provider','email','providers',jsonb_build_array('email')) end
    )::text,
    true
  );
end
$fn$;
grant execute on function pg_temp.as_v620_session(uuid,text,text) to public;

do $v620_main$
declare
  v_owner uuid:=gen_random_uuid();
  v_stranger uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_entitlement jsonb;
  v_sqlstate text;
  v_billing_denied boolean:=false;
begin
  reset role;

  -- A1 · ACLs are fail-closed: the hot-path predicate is server-only, the reader is
  -- authenticated-only, and neither is anon-callable.
  if has_function_privilege('anon','public.get_business_entitlement_v620(uuid)','EXECUTE')
     or not has_function_privilege(
          'authenticated','public.get_business_entitlement_v620(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.business_operational_v620(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.is_billing_owner_v620(uuid)','EXECUTE') then
    raise exception 'v620 A1: entitlement ACLs are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_owner,'v620-owner-'||substr(v_owner::text,1,8)||'@example.test'),
    (v_stranger,'v620-stranger-'||substr(v_stranger::text,1,8)||'@example.test')
  ) fixture(user_id,email);

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_business,'V620 entitlement fixture',
    'v620-ent-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','retention','reports']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V620 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',
         version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v620 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_business;

  -- A2 · (h) approved, unpaused, but NO subscription row at all: closed.
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A2: a firm with no subscription row was treated as operational';
  end if;

  insert into public.subscriptions(
    business_id,status,payment_status,trial_ends_at,
    current_period_start,current_period_end
  ) values(
    v_business,'trialing','not_collected',now()+interval '7 days',
    now(),now()+interval '30 days'
  );

  -- A3 · (a) a live trial is operational.
  if not app.business_operational_v620(v_business) then
    raise exception 'v620 A3: a live trial was not operational';
  end if;
  v_entitlement:=app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state'<>'trial'
     or not (v_entitlement->>'may_access_workspace')::boolean
     or v_entitlement->>'trial_state'<>'active' then
    raise exception 'v620 A4: live-trial entitlement is wrong: %',v_entitlement;
  end if;

  -- A5 · (b) an expired trial is a hard stop — no implicit grace.
  update public.subscriptions
     set trial_ends_at=now()-interval '1 day',updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A5: an expired trial stayed operational';
  end if;

  -- A6 · the splice: every tenant gate asks the same authority.
  if app.business_workspace_open_v94(v_business) then
    raise exception 'v620 A6: business_workspace_open_v94 was not spliced onto the authority';
  end if;

  -- A7 · a locked owner is no longer an owner for tenant RLS.
  perform pg_temp.as_v620_session(v_owner,'password');
  if app.is_salon_owner(v_business) then
    raise exception 'v620 A7: is_salon_owner stayed true for a trial-expired workspace';
  end if;
  if app.is_salon_member(v_business) then
    raise exception 'v620 A8: is_salon_member stayed true for a trial-expired workspace';
  end if;

  -- A9 · but the billing door stays open: a locked owner must be able to pay their way
  -- back in, so get_business_billing_v124 must NOT refuse with 42501. Any other
  -- fixture-shaped failure is not this assertion's business.
  begin
    perform public.get_business_billing_v124(v_business);
  exception when others then
    v_sqlstate:=sqlstate;
    if v_sqlstate='42501' then
      v_billing_denied:=true;
    end if;
  end;
  if v_billing_denied then
    raise exception 'v620 A9: the billing escape hatch refused a locked owner with 42501 — check the inner public.get_business_billing_v77 gate, which still calls app.is_salon_owner';
  end if;

  -- A10 · the locked owner can read WHY, and the reason names the expired trial.
  v_entitlement:=public.get_business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state'<>'trial_expired'
     or (v_entitlement->>'may_access_workspace')::boolean
     or coalesce(v_entitlement->>'restriction_reason','')='' then
    raise exception 'v620 A10: locked-owner entitlement readback is wrong: %',v_entitlement;
  end if;

  -- A11 · a stranger cannot read another firm's entitlement.
  perform pg_temp.as_v620_session(v_stranger,'password');
  begin
    perform public.get_business_entitlement_v620(v_business);
    raise exception 'v620 A11: a non-staff stranger read a firm entitlement';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v620_session(null);

  -- A12 · (c) paid inside the 14-day grace is operational.
  update public.subscriptions
     set status='active',payment_status='paid',
         current_period_start=now()-interval '20 days',
         current_period_end=now()+interval '10 days',
         updated_at=now()
   where business_id=v_business;
  if not app.business_operational_v620(v_business) then
    raise exception 'v620 A12: a paid subscription inside its period was not operational';
  end if;

  -- A13 · (d) paid but 20 days past the period end (beyond the 14-day grace) is closed.
  update public.subscriptions
     set current_period_end=now()-interval '20 days',updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A13: a lapsed paid period survived the 14-day grace';
  end if;
  v_entitlement:=app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state'<>'payment_lapsed' then
    raise exception 'v620 A14: lapsed-payment entitlement state is wrong: %',v_entitlement;
  end if;

  -- A15 · (e) a paused workspace is closed even when payment is current.
  update public.subscriptions
     set current_period_end=now()+interval '10 days',updated_at=now()
   where business_id=v_business;
  update public.business_subscription_lifecycle_v94
     set state='paused',workspace_paused=true,overdue_day=14,
         provider_invoice_id='in_v620_'||substr(v_business::text,1,8),
         due_date=(now()-interval '14 days')::date,
         paused_at=now(),version=version+1,updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A15: a paused workspace stayed operational';
  end if;

  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false,overdue_day=null,
         provider_invoice_id=null,due_date=null,
         recovered_at=now(),version=version+1,updated_at=now()
   where business_id=v_business;
  if not app.business_operational_v620(v_business) then
    raise exception 'v620 A16: recovery did not reopen a paid workspace';
  end if;

  -- A17 · (f) approval still gates everything, ahead of billing.
  update public.business_workspace_controls_v94
     set approval_status='pending',decided_by=null,decided_at=null,
         decision_reason=null,version=version+1,updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A17: an unapproved firm was operational on paid billing';
  end if;
  v_entitlement:=app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state'<>'pending_approval' then
    raise exception 'v620 A18: unapproved entitlement state is wrong: %',v_entitlement;
  end if;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v620 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_business;

  -- A19 · (g) an incomplete subscription is neither paid nor trialing: closed.
  update public.subscriptions
     set status='incomplete',payment_status='not_collected',updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v620 A19: an incomplete subscription was treated as operational';
  end if;

  -- A20 · v625 folds in here: the same predicates on a password session hold no platform
  -- authority, so is_super_admin cannot smuggle a locked firm back open.
  perform pg_temp.as_v620_session(v_owner,'password');
  if app.is_super_admin() then
    raise exception 'v620 A20: a tenant password session claimed super-admin authority';
  end if;

  perform pg_temp.as_v620_session(null);
  raise notice 'v620 entitlement authority suite: ALL PASS';
end
$v620_main$;

reset role;
rollback;
