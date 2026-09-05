-- nestly_v786 rollback suite — every new branch is its own Razorpay subscription.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production. It drives the
-- SAME pipeline production uses (ingest_billing_event_v755 -> apply_razorpay_billing_event_v755)
-- with synthesised Razorpay envelopes, exactly as the return hop and the reconciler do.
--
-- WHAT IT PROVES
--   B1  ACLs: the owner RPCs are authenticated-only; the service RPCs and app.* are server-only.
--   B2  business_add_branch_v786 as the OWNER: the first branch stays included/shared; the second
--       is born own + pending_payment + off, with a create_checkout command of scope 'branch'
--       that snapshots the flat annual tier and names the branch.
--   B3  claim_billing_command_v786 (service role) answers the executor contract for that command:
--       scope branch, plan id and amount from the flat tier, no provider subscription yet.
--   B4  subscription.activated then subscription.charged naming the branch: the branch applier
--       (routed from the v755 applier) writes branch_subscriptions_v786, the mirrors and the
--       invoice with detail.branch_id, and switches the branch ON (active, billing_state active).
--       public.subscriptions of the company is NOT touched by a branch event.
--   B5  the company summary (get_business_billing_v758) counts the own branch out of its units;
--       get_business_billing_v786 lists the branch subscription with state 'active' and the flat
--       price; the v621 activation ignores an own branch.
--   B6  subscription.halted on the branch: branch suspended + off; company untouched.
--   B7  a later subscription.charged brings it back on (rank order, same as v755).
--   B8  cancel intent: set_branch_renewal_intent_v786 records; list_due_renewal_cancels_v764
--       lists it with branch_id inside the 48h window; mark_branch_renewal_cancel_sent_v786 marks;
--       a subscription.cancelled with a future current_end makes the branch 'canceling' with the
--       date; the v665 sweep then switches it off once the date passes.
--   B9  a stranger owner cannot mint a command for, or read, this branch (42501 / 0 rows).
--   B10 the shared-model lapse: a paid company subscription 15 days past its period end switches
--       its shared branches off; a company subscription.charged restores them.
begin;

create or replace function pg_temp.as_v786_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then return; end if;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', p_role,
    'amr', jsonb_build_array(jsonb_build_object('method','password','timestamp',1756500000)),
    'app_metadata', jsonb_build_object('provider','email','providers',jsonb_build_array('email')))::text, true);
end
$$;
grant execute on function pg_temp.as_v786_user(uuid,text) to public;

create or replace function pg_temp.push_v786(p_event_id text, p_type text, p_payload jsonb, p_at timestamptz)
returns jsonb language plpgsql as $$
declare v_ingest jsonb; v_apply jsonb;
begin
  v_ingest := public.ingest_billing_event_v755('razorpay', p_event_id, p_type,
    coalesce(p_payload #>> '{payload,subscription,entity,id}', p_payload #>> '{payload,payment,entity,id}'),
    p_at, false, p_payload, encode(extensions.digest(convert_to(p_payload::text,'utf8'),'sha256'),'hex'));
  v_apply := public.apply_razorpay_billing_event_v755(p_event_id);
  if v_apply->>'status' <> 'processed' then
    raise exception 'v786 push %: apply answered %', p_event_id, v_apply;
  end if;
  return v_apply;
end
$$;
grant execute on function pg_temp.push_v786(text,text,jsonb,timestamptz) to public;

do $v786_main$
declare
  v_owner uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_main uuid;
  v_branch uuid;
  v_added jsonb;
  v_claim jsonb;
  v_command uuid;
  v_key uuid := gen_random_uuid();
  v_plan text;
  v_amount integer;
  v_sub_id text := 'sub_v786'||substr(replace(gen_random_uuid()::text,'-',''),1,12);
  v_pay1 text := 'pay_v786a'||substr(replace(gen_random_uuid()::text,'-',''),1,10);
  v_pay2 text := 'pay_v786b'||substr(replace(gen_random_uuid()::text,'-',''),1,10);
  v_entity jsonb;
  v_row public.branch_subscriptions_v786%rowtype;
  v_br public.branches%rowtype;
  v_summary jsonb;
  v_billing jsonb;
  v_due jsonb;
  v_state text;
  v_count integer;
  v_now timestamptz := now();
  v_period_end timestamptz := now() + interval '365 days';
  v_sqlstate text;
begin
  reset role;

  -- B1 · ACLs
  if has_function_privilege('anon','public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.business_add_branch_v786(uuid,text,text,text,text,uuid,text,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_business_billing_v786(uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.set_branch_renewal_intent_v786(uuid,uuid,boolean)','EXECUTE')
     or has_function_privilege('authenticated','public.claim_billing_command_v786(uuid,uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.mark_branch_renewal_cancel_sent_v786(uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','public.set_branch_payment_method_v786(uuid,text,text,text,text)','EXECUTE')
     or has_function_privilege('authenticated','app.apply_razorpay_branch_event_v786(text,uuid,uuid,smallint)','EXECUTE')
     or has_function_privilege('authenticated','app.billing_flat_tier_v786(text)','EXECUTE') then
    raise exception 'v786 B1: ACLs are not fail-closed';
  end if;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  select '00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',
         'v786-'||substr(u::text,1,8)||'@example.test','',now(),now(),now()
    from unnest(array[v_owner,v_stranger]) u;
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values (v_business,'V786 fixture','v786-'||substr(v_business::text,1,8),'test',array['dashboard','clients','sales']),
         (v_other,'V786 other','v786o-'||substr(v_other::text,1,8),'test',array['dashboard','clients','sales']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','V786 Owner',true),(v_other,v_stranger,'owner','V786 Stranger',true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='v786 fixture',updated_at=clock_timestamp()
   where business_id in (v_business,v_other);
  insert into public.subscriptions(business_id,status,payment_status,current_period_start,current_period_end,
                                   billing_provider,billing_cadence)
  values (v_business,'active','paid',now()-interval '10 days',now()+interval '355 days','manual','annual'),
         (v_other,'active','paid',now()-interval '10 days',now()+interval '355 days','manual','annual');

  -- B2 · add branches as the owner
  perform pg_temp.as_v786_user(v_owner);
  v_added := public.business_add_branch_v786(v_business,'Main',null,null,null,null,'annual',gen_random_uuid());
  if v_added->>'billing_state' <> 'included' or v_added->>'billing_mode' <> 'shared' then
    raise exception 'v786 B2: first branch was not included/shared: %', v_added;
  end if;
  v_main := (v_added->>'branch_id')::uuid;
  v_added := public.business_add_branch_v786(v_business,'East Coast','1 East Coast Rd',null,null,v_main,'annual',v_key);
  v_branch := (v_added->>'branch_id')::uuid;
  v_command := (v_added->>'command_id')::uuid;
  select * into v_br from public.branches where id = v_branch;
  if v_br.billing_mode <> 'own' or v_br.billing_state <> 'pending_payment' or v_br.active then
    raise exception 'v786 B2: second branch shape is wrong: mode=% state=% active=%', v_br.billing_mode, v_br.billing_state, v_br.active;
  end if;
  perform pg_temp.as_v786_user(null);
  if not exists (select 1 from public.billing_commands c where c.id = v_command and c.command_scope = 'branch'
                   and c.requested_branch_id = v_branch and c.command_type = 'create_checkout'
                   and c.requested_cadence = 'annual' and c.billing_tier_id_v664 is not null) then
    raise exception 'v786 B2: branch checkout command is not shaped as expected';
  end if;
  -- replay returns the same branch and command
  perform pg_temp.as_v786_user(v_owner);
  v_added := public.business_add_branch_v786(v_business,'East Coast',null,null,null,null,'annual',v_key);
  if v_added->>'status' <> 'replayed' or (v_added->>'branch_id')::uuid <> v_branch then
    raise exception 'v786 B2: replay minted a second branch: %', v_added;
  end if;

  -- B3 · claim as the service role
  perform pg_temp.as_v786_user(null);
  set local role service_role;
  v_claim := public.claim_billing_command_v786(v_command, v_owner);
  reset role;
  select tier.provider_base_price_id, tier.amount_cents into v_plan, v_amount
    from app.billing_flat_tier_v786('annual') tier;
  if v_claim->>'scope' <> 'branch' or (v_claim->>'branch_id')::uuid <> v_branch
     or v_claim->>'provider_base_price_id' <> v_plan or (v_claim->>'base_amount_cents')::integer <> v_amount
     or v_claim->>'provider_subscription_id' is not null or v_claim->>'status' <> 'processing' then
    raise exception 'v786 B3: claim contract is wrong: %', v_claim;
  end if;

  -- B4 · activated + charged naming the branch
  v_entity := jsonb_build_object('id',v_sub_id,'entity','subscription','plan_id',v_plan,'customer_id','cust_v786',
    'status','active','quantity',1,'paid_count',1,
    'current_start',extract(epoch from v_now)::bigint,'current_end',extract(epoch from v_period_end)::bigint,
    'charge_at',extract(epoch from v_period_end)::bigint,'start_at',extract(epoch from v_now)::bigint,
    'created_at',extract(epoch from v_now)::bigint,'has_scheduled_changes',false,
    'notes',jsonb_build_object('business_id',v_business::text,'branch_id',v_branch::text,'command_id',v_command::text,'cadence','annual'));
  perform pg_temp.push_v786('v786_'||v_sub_id||'_activated','subscription.activated',
    jsonb_build_object('entity','event','event','subscription.activated','payload',jsonb_build_object('subscription',jsonb_build_object('entity',v_entity))),
    v_now);
  perform pg_temp.push_v786('v786_'||v_sub_id||'_'||v_pay1||'_charged','subscription.charged',
    jsonb_build_object('entity','event','event','subscription.charged','payload',jsonb_build_object(
      'subscription',jsonb_build_object('entity',v_entity),
      'payment',jsonb_build_object('entity',jsonb_build_object('id',v_pay1,'amount',v_amount,'currency','SGD','status','captured',
        'method','card','card',jsonb_build_object('last4','4242','network','Visa'),
        'created_at',extract(epoch from v_now)::bigint,'notes',jsonb_build_object('business_id',v_business::text,'branch_id',v_branch::text))))),
    v_now + interval '1 second');
  select * into v_row from public.branch_subscriptions_v786 where branch_id = v_branch;
  select * into v_br from public.branches where id = v_branch;
  if v_row.provider_subscription_id <> v_sub_id or v_row.status <> 'active' or v_row.payment_status <> 'paid'
     or v_row.cadence <> 'annual' or v_row.unit_amount_cents <> v_amount or v_row.payment_method_last4 <> '4242' then
    raise exception 'v786 B4: branch subscription row is wrong: %', to_jsonb(v_row);
  end if;
  if v_br.billing_state <> 'active' or not v_br.active then
    raise exception 'v786 B4: the branch did not switch on (state=% active=%)', v_br.billing_state, v_br.active;
  end if;
  if not exists (select 1 from public.billing_provider_invoices i where i.provider_subscription_id = v_sub_id
                   and i.business_id = v_business and i.status = 'paid' and (i.detail->>'branch_id')::uuid = v_branch) then
    raise exception 'v786 B4: invoice was not mirrored with the branch';
  end if;
  if exists (select 1 from public.subscriptions s where s.business_id = v_business and s.provider_subscription_id is not null) then
    raise exception 'v786 B4: a branch event wrote the company subscription';
  end if;

  -- B5 · readers
  perform pg_temp.as_v786_user(v_owner);
  v_billing := public.get_business_billing_v786(v_business);
  v_summary := v_billing->'summary';
  if (v_summary->>'branches_billable')::integer <> 0 or (v_summary->>'units')::integer <> 1 then
    raise exception 'v786 B5: company summary counted the own branch: %', v_summary;
  end if;
  if jsonb_array_length(v_billing->'branch_subscriptions') <> 1
     or v_billing#>>'{branch_subscriptions,0,state}' <> 'active'
     or (v_billing#>>'{branch_subscriptions,0,branch_id}')::uuid <> v_branch
     or (v_billing#>>'{flat_price,annual_cents}')::integer <> v_amount then
    raise exception 'v786 B5: v786 read is wrong: %', v_billing->'branch_subscriptions';
  end if;
  perform pg_temp.as_v786_user(null);
  if (app.activate_pending_branches_on_paid_v621(v_business,'v786-test')->>'activated')::integer <> 0 then
    raise exception 'v786 B5: v621 activation touched an own branch';
  end if;

  -- B6 · halted: off
  v_entity := v_entity || jsonb_build_object('status','halted');
  perform pg_temp.push_v786('v786_'||v_sub_id||'_halted','subscription.halted',
    jsonb_build_object('entity','event','event','subscription.halted','payload',jsonb_build_object('subscription',jsonb_build_object('entity',v_entity))),
    v_now + interval '10 days');
  select * into v_br from public.branches where id = v_branch;
  select * into v_row from public.branch_subscriptions_v786 where branch_id = v_branch;
  if v_br.billing_state <> 'suspended' or v_br.active or v_row.payment_status <> 'failed' then
    raise exception 'v786 B6: halted did not switch the branch off (state=% active=% pay=%)', v_br.billing_state, v_br.active, v_row.payment_status;
  end if;

  -- B7 · paid again: back on
  v_entity := v_entity || jsonb_build_object('status','active');
  perform pg_temp.push_v786('v786_'||v_sub_id||'_'||v_pay2||'_charged','subscription.charged',
    jsonb_build_object('entity','event','event','subscription.charged','payload',jsonb_build_object(
      'subscription',jsonb_build_object('entity',v_entity),
      'payment',jsonb_build_object('entity',jsonb_build_object('id',v_pay2,'amount',v_amount,'currency','SGD','status','captured',
        'method','card','card',jsonb_build_object('last4','1881','network','Mastercard'),
        'created_at',extract(epoch from v_now + interval '11 days')::bigint,'notes',jsonb_build_object('business_id',v_business::text,'branch_id',v_branch::text))))),
    v_now + interval '11 days');
  select * into v_br from public.branches where id = v_branch;
  select * into v_row from public.branch_subscriptions_v786 where branch_id = v_branch;
  if v_br.billing_state <> 'active' or not v_br.active or v_row.payment_status <> 'paid' or v_row.payment_method_last4 <> '1881' then
    raise exception 'v786 B7: a later payment did not restore the branch';
  end if;

  -- B8 · renewal cancel, per branch
  perform pg_temp.as_v786_user(v_owner);
  if not (public.set_branch_renewal_intent_v786(v_business,v_branch,true)->>'cancel_requested')::boolean then
    raise exception 'v786 B8: intent was not recorded';
  end if;
  perform pg_temp.as_v786_user(null);
  update public.branch_subscriptions_v786 set current_period_end = now() + interval '20 hours' where branch_id = v_branch;
  v_due := public.list_due_renewal_cancels_v764();
  if not exists (select 1 from jsonb_array_elements(v_due->'due') d
                  where (d->>'branch_id')::uuid = v_branch and d->>'provider_subscription_id' = v_sub_id) then
    raise exception 'v786 B8: the due list does not carry the branch: %', v_due;
  end if;
  set local role service_role;
  perform public.mark_branch_renewal_cancel_sent_v786(v_branch,'test');
  reset role;
  select * into v_row from public.branch_subscriptions_v786 where branch_id = v_branch;
  if v_row.renewal_cancel_sent_at is null or not v_row.cancel_at_period_end then
    raise exception 'v786 B8: mark did not record the send';
  end if;
  v_entity := v_entity || jsonb_build_object('status','cancelled','ended_at',null,
    'current_end',extract(epoch from now() + interval '20 hours')::bigint);
  perform pg_temp.push_v786('v786_'||v_sub_id||'_cancelled','subscription.cancelled',
    jsonb_build_object('entity','event','event','subscription.cancelled','payload',jsonb_build_object('subscription',jsonb_build_object('entity',v_entity))),
    v_now + interval '12 days');
  select * into v_br from public.branches where id = v_branch;
  if v_br.billing_state <> 'canceling' or v_br.billing_cancel_at is null or not v_br.active then
    raise exception 'v786 B8: cancelled-at-cycle-end did not read as canceling (state=% at=%)', v_br.billing_state, v_br.billing_cancel_at;
  end if;
  update public.branches set billing_cancel_at = now() - interval '1 minute' where id = v_branch;
  perform app.run_branch_unsubscribe_sweep_v665();
  select * into v_br from public.branches where id = v_branch;
  if v_br.billing_state <> 'unsubscribed' or v_br.active then
    raise exception 'v786 B8: the v665 sweep did not switch the branch off';
  end if;

  -- B9 · a stranger
  perform pg_temp.as_v786_user(v_stranger);
  begin
    perform public.request_branch_billing_command_v786(v_business,v_branch,'update_card',null,gen_random_uuid());
    raise exception 'v786 B9: a stranger minted a branch command';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate <> '42501' then raise exception 'v786 B9: expected 42501, got % (%)', v_sqlstate, sqlerrm; end if;
  end;
  select count(*) into v_count from public.branch_subscriptions_v786 where business_id = v_business;
  if v_count <> 0 then raise exception 'v786 B9: a stranger can read another firm''s branch subscriptions'; end if;

  -- B10 · shared-model lapse and restore
  perform pg_temp.as_v786_user(null);
  /* subscriptions carries the v79 payment-truth guard: a test writes it as the system does. */
  perform set_config('app.v79_system_transition','on',true);
  /* Two writes on purpose: the v510 payment-link trigger re-derives payment truth from the
     mirrors whenever the provider identity changes, so the identity is written first and the
     lapsed payment truth after it. */
  update public.subscriptions
     set billing_provider = 'razorpay', provider_subscription_id = 'sub_v786company'||substr(replace(gen_random_uuid()::text,'-',''),1,8)
   where business_id = v_business;
  update public.subscriptions
     set status = 'past_due', last_paid_at = now() - interval '380 days', current_period_end = now() - interval '15 days', payment_status = 'failed'
   where business_id = v_business;
  perform set_config('app.v79_system_transition','off',true);
  perform app.sweep_lapsed_shared_branches_v786();
  select * into v_br from public.branches where id = v_main;
  if v_br.billing_state <> 'suspended' or v_br.active or v_br.billing_state_prior <> 'included' then
    raise exception 'v786 B10: the lapsed company did not switch its main branch off (state=% active=%)', v_br.billing_state, v_br.active;
  end if;
  if (app.restore_lapsed_shared_branches_v786(v_business,'v786-test')->>'restored')::integer <> 1 then
    raise exception 'v786 B10: restore did not bring the main branch back';
  end if;
  select * into v_br from public.branches where id = v_main;
  if v_br.billing_state <> 'included' or not v_br.active then
    raise exception 'v786 B10: restored branch shape is wrong';
  end if;

  raise notice 'v786 acceptance: B1–B10 passed';
end
$v786_main$;

rollback;
