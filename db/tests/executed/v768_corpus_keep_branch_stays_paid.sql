-- EXECUTED acceptance fixture for nestly_v768
-- (db/migrations/20261003_nestly_v768_keep_branch_stays_paid.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v768 --migrated-only
--
-- WHY THIS EXISTS. Observed live 2026-09-05: a branch whose year was paid (SGD 1,188, covers
-- until 5 Sep 2027) was switched off, then kept — and came back as pending_payment / inactive
-- with a toast telling the owner to pay for it again. Under Razorpay the decrease was only
-- SCHEDULED for cycle end, so the unit was still paid for.
--
-- ASSERTIONS (as the branch's real owner, rolled back):
--   F1  a PAID branch (active) that is stopping comes back as active, still switched on, with
--       billing_state_prior and billing_cancel_at cleared, and a change_branches command is
--       requested so the provider's scheduled reduction can be withdrawn.
--   F2  a branch that was never paid (pending_payment) that is stopping comes back as
--       pending_payment and off — this is not a widening.
--   F3  a free branch (included) comes back included, on, and requests NO command.
--   F4  the audit row names the prior state.
begin;

create temporary table v768_fixture(business_id uuid, owner_user uuid) on commit drop;

/* A tenant of its own: business (its first branch is created 'included' by the v665 trigger),
   a confirmed owner login, an owner staff row, and a subscription linked to a provider — the
   shape production has and the harness does not. Plus a sellable annual tier and an active v124
   catalogue row, which request_billing_command_v124 requires. */
do $v768_setup$
declare
  v_business uuid; v_owner uuid := gen_random_uuid(); v_now timestamptz := date_trunc('second', now());
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
begin
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V768 keep tenant','v768-keep-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard'])
  returning id into v_business;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v768-'||substr(v_owner::text,1,8)||'@example.test','',v_now,v_now,v_now);
  insert into public.staff(business_id,user_id,role,active,access_state)
  values (v_business,v_owner,'owner',true,'approved');
  /* app.is_salon_owner also needs the workspace open (v94 approval). */
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
  values (v_business,'approved',v_now,'v768 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=v_now,
    decision_reason='v768 fixture';
  if not exists (select 1 from public.branches where business_id=v_business) then
    insert into public.branches(business_id,name,is_default,active) values (v_business,'V768 main',true,true);
  end if;
  insert into public.subscriptions(business_id,status,currency,base_price_cents,included_seats,
    per_seat_price_cents,billing_provider,billing_cadence,payment_status,provider_subscription_id,
    current_period_end)
  values (v_business,'active','SGD',118800,1,0,'razorpay','annual','paid','sub_v768fixture',
    v_now + interval '300 days')
  on conflict (business_id) do update
    set provider_subscription_id='sub_v768fixture', billing_provider='razorpay',
        billing_cadence='annual', status='active', payment_status='paid',
        current_period_end=v_now + interval '300 days';
  insert into v768_fixture values (v_business, v_owner);

  v_tier := app.billing_tier_for_capacity_v664('annual', 1000);
  if v_tier.capacity_ceiling is null then
    insert into public.billing_capacity_tier_catalog_v664(
      currency,cadence,cadence_months,provider,capacity_ceiling,amount_cents,
      provider_base_price_id,tax_behavior,sales_assisted_above,active,effective_from
    ) values ('SGD','annual',12,'razorpay',1000,118800,'plan_v768tier',
      'exclusive',false,true,v_now - interval '30 days');
  elsif v_tier.provider_base_price_id is null then
    update public.billing_capacity_tier_catalog_v664
       set provider_base_price_id='plan_v768tier'
     where currency=v_tier.currency and cadence=v_tier.cadence
       and capacity_ceiling=v_tier.capacity_ceiling and effective_from=v_tier.effective_from;
  end if;
  if not exists (
    select 1 from public.billing_plan_catalog_v124 catalog
     where catalog.currency='SGD' and catalog.cadence='annual' and catalog.active
       and catalog.effective_from<=now() and (catalog.effective_to is null or catalog.effective_to>now())
  ) then
    insert into public.billing_plan_catalog_v124(
      currency, cadence, cadence_months, provider, provider_base_price_id,
      provider_capacity_price_id, base_amount_cents, included_customer_capacity,
      capacity_block_size, capacity_block_amount_cents, compare_at_monthly_cents,
      tax_behavior, active, effective_from
    ) values ('SGD','annual',12,'razorpay',null,null,118800,1000,1000,12000,16800,
      'exclusive',true, v_now - interval '30 days');
  end if;
end
$v768_setup$;

do $v768$
declare
  f record;
  v_paid uuid; v_unpaid uuid; v_free uuid;
  v_result jsonb;
  v_row public.branches%rowtype;
  v_detail jsonb;
begin
  select * into f from v768_fixture;
  perform set_config('request.jwt.claim.sub', f.owner_user::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', f.owner_user, 'role', 'authenticated', 'aud', 'authenticated')::text,
    true);

  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  insert into public.branches(business_id,name,is_default,active,billing_state)
  values (f.business_id,'v768 paid branch',false,true,'active') returning id into v_paid;
  update public.branches set billing_state='active', active=true where id=v_paid;
  insert into public.branches(business_id,name,is_default,active)
  values (f.business_id,'v768 unpaid branch',false,false) returning id into v_unpaid;
  select id into v_free from public.branches
   where business_id=f.business_id and billing_state='included' order by created_at limit 1;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);

  select * into v_row from public.branches where id=v_paid;
  if v_row.billing_state <> 'active' or not v_row.active then
    raise exception 'v768 fixture: could not stand up a paid branch (%/%)', v_row.billing_state, v_row.active;
  end if;
  select * into v_row from public.branches where id=v_unpaid;
  if v_row.billing_state <> 'pending_payment' then
    raise exception 'v768 fixture: the unpaid branch is % instead of pending_payment', v_row.billing_state;
  end if;

  -- ===========================================================================================
  -- F1 — a paid branch, switched off then kept, is still on and still paid.
  -- ===========================================================================================
  v_result := public.business_unsubscribe_branch_v665(f.business_id, v_paid, gen_random_uuid());
  select * into v_row from public.branches where id=v_paid;
  if v_row.billing_state <> 'canceling' or v_row.billing_state_prior <> 'active' or not v_row.active then
    raise exception 'F1: switch off left the paid branch at %/prior %/active %',
      v_row.billing_state, v_row.billing_state_prior, v_row.active;
  end if;
  v_result := public.business_resubscribe_branch_v665(f.business_id, v_paid, gen_random_uuid());
  select * into v_row from public.branches where id=v_paid;
  if v_row.billing_state <> 'active' then
    raise exception 'F1: Keep returned the paid branch as % (the v665 defect)', v_row.billing_state;
  end if;
  if not v_row.active then
    raise exception 'F1: Keep switched the paid branch off';
  end if;
  if v_row.billing_state_prior is not null or v_row.billing_cancel_at is not null then
    raise exception 'F1: Keep left prior/cancel_at set (%/%)', v_row.billing_state_prior, v_row.billing_cancel_at;
  end if;
  if v_result->>'billing_state' <> 'active' then
    raise exception 'F1: the RPC reported % instead of active', v_result->>'billing_state';
  end if;
  if coalesce(v_result->>'command_id','') = '' then
    raise exception 'F1: no change_branches command was requested to withdraw the scheduled reduction';
  end if;
  if not exists (
    select 1 from public.billing_commands
     where id = (v_result->>'command_id')::uuid and command_type='change_branches'
       and business_id=f.business_id
  ) then
    raise exception 'F1: the returned command id is not a change_branches command of this business';
  end if;

  -- ===========================================================================================
  -- F2 — a never-paid branch comes back unpaid and off.
  -- ===========================================================================================
  perform public.business_unsubscribe_branch_v665(f.business_id, v_unpaid, gen_random_uuid());
  v_result := public.business_resubscribe_branch_v665(f.business_id, v_unpaid, gen_random_uuid());
  select * into v_row from public.branches where id=v_unpaid;
  if v_row.billing_state <> 'pending_payment' or v_row.active then
    raise exception 'F2: Keep on a never-paid branch produced %/active=%', v_row.billing_state, v_row.active;
  end if;

  -- ===========================================================================================
  -- F3 — a free branch stays free and requests no command.
  -- ===========================================================================================
  if v_free is not null then
    perform public.business_unsubscribe_branch_v665(f.business_id, v_free, gen_random_uuid());
    v_result := public.business_resubscribe_branch_v665(f.business_id, v_free, gen_random_uuid());
    select * into v_row from public.branches where id=v_free;
    if v_row.billing_state <> 'included' then
      raise exception 'F3: Keep on a free branch produced %', v_row.billing_state;
    end if;
    if coalesce(v_result->>'command_id','') <> '' then
      raise exception 'F3: a free branch requested a billing command';
    end if;
  end if;

  -- ===========================================================================================
  -- F4 — the audit row names the prior state.
  -- ===========================================================================================
  select detail into v_detail from public.audit_log
   where entity_id=v_paid and action='BRANCH_RESUBSCRIBED_V665' order by created_at desc limit 1;
  if v_detail is null or v_detail->>'prior_state' <> 'active' or v_detail->>'restored_state' <> 'active' then
    raise exception 'F4: audit row does not name prior/restored state (%)', v_detail;
  end if;

  raise notice 'v768 corpus: F1-F4 passed';
end
$v768$;

rollback;
