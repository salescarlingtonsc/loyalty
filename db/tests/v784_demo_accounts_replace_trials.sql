-- nestly_v784 rollback suite — demo accounts replace trials; a workspace is never locked for money.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   A1  the two v620 functions keep their fail-closed ACLs (server-only; not anon, not
--       authenticated) after being re-emitted.
--   A2  an approved, unpaused firm whose trial has EXPIRED is OPEN — money never closes the door.
--   A3  the same firm flagged is_demo reads 'demo', open, is_demo=true.
--   A4  a firm with NO subscription row at all is open, and reads open_no_subscription.
--   A5  a PAUSED firm is closed — the platform's pause switch still works, demo or not.
--   A6  an UNAPPROVED firm is closed — approval still gates, demo or not.
--   A7  the tenant gate (business_workspace_open_v94) follows the same authority.
--   A8  the estate: nothing is left trialing, unpaid and not demo after the data step.
begin;

do $v784_main$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_entitlement jsonb;
  v_left integer;
begin
  reset role;

  -- A1 · ACLs
  if has_function_privilege('anon','app.business_operational_v620(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.business_operational_v620(uuid)','EXECUTE')
     or has_function_privilege('anon','app.business_entitlement_v620(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.business_entitlement_v620(uuid)','EXECUTE') then
    raise exception 'v784 A1: entitlement ACLs are not fail-closed';
  end if;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
         'v784-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(v_business,'V784 demo fixture','v784-demo-'||substr(v_business::text,1,8),'test',
         array['dashboard','clients','sales','loyalty','retention','reports']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V784 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='rollback-only v784 acceptance fixture',updated_at=clock_timestamp()
   where business_id=v_business;

  -- A2 · expired trial, not demo: OPEN.
  insert into public.subscriptions(business_id,status,payment_status,trial_ends_at,current_period_start,current_period_end)
  values(v_business,'trialing','not_collected',now()-interval '1 day',now()-interval '31 days',now()-interval '1 day');
  if not app.business_operational_v620(v_business) then
    raise exception 'v784 A2: an expired trial closed the workspace — money must never lock the door';
  end if;
  v_entitlement := app.business_entitlement_v620(v_business);
  if not (v_entitlement->>'may_access_workspace')::boolean
     or v_entitlement->>'operational_state' <> 'open_unpaid' then
    raise exception 'v784 A2: readback is wrong: %', v_entitlement;
  end if;

  -- A3 · the same firm as a demo: open, and says so.
  update public.businesses set is_demo=true where id=v_business;
  if not app.business_operational_v620(v_business) then
    raise exception 'v784 A3: a demo firm was closed';
  end if;
  v_entitlement := app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state' <> 'demo'
     or not (v_entitlement->>'may_access_workspace')::boolean
     or not (v_entitlement->>'is_demo')::boolean then
    raise exception 'v784 A3: demo entitlement readback is wrong: %', v_entitlement;
  end if;

  -- A4 · no subscription row at all: still open.
  update public.businesses set is_demo=false where id=v_business;
  delete from public.subscriptions where business_id=v_business;
  if not app.business_operational_v620(v_business) then
    raise exception 'v784 A4: a firm without a subscription row was closed';
  end if;
  v_entitlement := app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state' <> 'open_no_subscription' then
    raise exception 'v784 A4: readback without a subscription row is wrong: %', v_entitlement;
  end if;

  -- A5 · paused closes.
  update public.business_subscription_lifecycle_v94
     set state='paused',workspace_paused=true,overdue_day=14,provider_invoice_id='in_v784test',
         due_date=current_date-14,paused_at=now(),version=version+1,updated_at=now()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v784 A5: a paused firm stayed operational';
  end if;
  v_entitlement := app.business_entitlement_v620(v_business);
  if v_entitlement->>'operational_state' <> 'paused' then
    raise exception 'v784 A5: paused readback is wrong: %', v_entitlement;
  end if;
  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false,overdue_day=null,provider_invoice_id=null,due_date=null,paused_at=null,
         version=version+1,updated_at=now()
   where business_id=v_business;

  -- A6 · approval closes.
  update public.business_workspace_controls_v94
     set approval_status='pending',decided_at=null,decision_reason=null,version=version+1,updated_at=clock_timestamp()
   where business_id=v_business;
  if app.business_operational_v620(v_business) then
    raise exception 'v784 A6: an unapproved firm was operational';
  end if;
  update public.business_workspace_controls_v94
     set approval_status='approved',decided_at=clock_timestamp(),decision_reason='v784 fixture re-approval',version=version+1,updated_at=clock_timestamp()
   where business_id=v_business;

  -- A7 · the tenant gate follows the authority.
  if not app.business_workspace_open_v94(v_business) then
    raise exception 'v784 A7: business_workspace_open_v94 did not open the workspace';
  end if;

  -- A8 · the estate.
  select count(*) into v_left
    from public.businesses b
    join public.subscriptions s on s.business_id=b.id
   where s.status='trialing' and coalesce(s.payment_status,'not_collected')<>'paid'
     and not b.is_demo and b.id<>v_business;
  if v_left > 0 then
    raise exception 'v784 A8: % tenant(s) are still trialing, unpaid and not demo', v_left;
  end if;

  raise notice 'v784 acceptance: A1–A8 passed';
end
$v784_main$;

rollback;
