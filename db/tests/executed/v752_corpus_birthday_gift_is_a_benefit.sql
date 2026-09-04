-- EXECUTED acceptance fixture for nestly_v752
-- (db/migrations/20260924_nestly_v752_birthday_gift_is_a_benefit.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v752_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner ruling 2026-09-04: the birthday gift must be a structured benefit — same
-- editor, same mechanism as a tier benefit — not typed words, with the customer able to see it in
-- the app and let staff scan the QR. This suite proves the three load-bearing claims:
--   A1  A published discount_pct birthday benefit's customer_label is DERIVED by
--       app.v657_discount_label (the same authority a tier discount uses) — never the typed text
--       an editor might have sent, and it reflects the scope and the money cap.
--   A2  A published free_item birthday benefit's customer_label is DERIVED by
--       app.v369_benefit_label ("Free <item>") the same way.
--   A3  customer_create_gift_intent_v515 accepts gift_kind='birthday' for a live, in-window,
--       unused entitlement and quotes that same derived label — the customer-facing QR sheet
--       shows the mechanism, not typed marketing copy.
--   A4  app.ps1c_plan_checkout's new p_birthday flag actually takes money off the bill: a 10%
--       whole-bill benefit capped at $5 on a $100 line comes off at exactly $5, not $10 — proof
--       the cap is honoured, not merely displayed.
--   A5  Once the entitlement is spent (status='redeemed', the SAME one-per-window latch
--       redeem_customer_birthday_benefit already owns), a second p_birthday=true checkout is
--       refused, and a second customer_create_gift_intent_v515 for the same entitlement is
--       refused too — one use per birthday window, enforced on both the pricing path and the
--       QR-mint path, not just one of them.
--
-- WHAT THIS SUITE DELIBERATELY DOES NOT DRIVE: the full staff-scan -> record_cart_sale ->
-- redeem_customer_birthday_benefit finalisation chain. That needs a checkout_evaluations row
-- persisted by the till's own evaluate-and-lock RPC, which this fixture does not rehearse (see
-- the v752 report). A4/A5 exercise app.ps1c_plan_checkout and the entitlement latch directly,
-- which is the part nestly_v752 actually changed; record_cart_sale's counting call
-- (public.redeem_customer_birthday_benefit, itself unchanged by this migration) is covered by
-- reading its source against the migration diff, not by this executed suite.

\set ON_ERROR_STOP on

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v752_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v752_user(uuid,text) to public;

do $v752_test$
declare
  v_business   uuid;
  v_slug       text;
  v_branch     uuid := gen_random_uuid();
  v_owner_auth uuid := gen_random_uuid();
  v_staff      uuid;
  v_client     uuid;
  v_identity   uuid;
  v_customer   uuid := gen_random_uuid();
  v_link       uuid := gen_random_uuid();
  v_config     uuid;
  v_program_id uuid;
  v_version    uuid;
  v_freeitem_version uuid;
  v_entitlement uuid;
  v_freeitem_entitlement uuid;
  v_product    uuid;
  v_bill_product uuid;
  v_label      text;
  v_freeitem_label text;
  v_snapshot   jsonb;
  v_intent     jsonb;
  v_intent2    jsonb;
  v_plan       jsonb;
  v_plan2      jsonb;
  v_applied    jsonb;
  v_key        uuid := gen_random_uuid();
begin
  reset role;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V752 birthday benefit fixture',
    'v752-birthday-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty','till']
  ) returning id,slug into v_business,v_slug;
  perform set_config('app.v79_system_transition', '', true);

  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'V752 branch',true,true);

  insert into public.business_workspace_controls_v94
    (business_id,approval_status,decided_at,decision_reason)
  values(v_business,'approved',now(),'v752 fixture')
  on conflict (business_id) do update
    set approval_status='approved',decided_at=now(),decision_reason='v752 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_business,'current',false)
  on conflict (business_id) do update set state='current',workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active',payment_status='paid',current_period_end=now()+interval '30 days';

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet','customer_birthday_benefits');

  -- Owner/staff, so record_cart_sale-adjacent RPCs (and a future staff scan) have someone to act
  -- as. staff.user_id must point at a real auth.users row.
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_owner_auth,'authenticated','authenticated',
    'v752-owner-' || substr(v_owner_auth::text,1,8) || '@example.test','',now(),now(),now()
  );
  insert into public.staff(business_id,user_id,role,active)
  values(v_business,v_owner_auth,'owner',true)
  returning id into v_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff,v_branch);

  -- A published config version and a birthday_programs identity, so the FKs and the "active
  -- config" join app.c45_customer_birthday_benefit_for_context relies on are all real.
  insert into public.firm_config_versions(business_id,version_no,status,source,snapshot_hash)
  values(v_business,1,'draft','manual',md5('v752-fixture'))
  returning id into v_config;

  insert into public.birthday_programs(business_id) values(v_business) returning id into v_program_id;

  -- A2 fixture product for the free_item benefit's catalogue pick.
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'V752 Birthday Cupcake',800,true)
  returning id into v_product;
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'V752 checkout line item',10000,true)
  returning id into v_bill_product;

  -- A1: the discount_pct benefit -- 10% off the whole bill, capped at $5 (500 cents). The typed
  -- customer_label below is deliberately WRONG marketing copy: A1 proves the trigger overwrites
  -- it rather than trusting it.
  insert into public.birthday_program_versions(
    program_id,config_version_id,business_id,active,
    customer_label,customer_description,customer_terms,
    fulfillment_kind,discount_percent,discount_scope,max_discount_cents,
    window_days_before,window_days_after)
  values(
    v_program_id,v_config,v_business,true,
    'THIS TYPED TEXT MUST NOT SURVIVE','A birthday treat on us.','Valid during your birthday window only.',
    'discount_pct',10,'bill',500,
    7,7)
  returning id, customer_label into v_version, v_label;

  -- The row above is now written; PUBLISH the config (the guard trigger only checks status AT
  -- insert/update/delete time on birthday_program_versions itself, so publishing after the row
  -- exists is the correct order -- exactly how a real editor save -> publish flow works).
  update public.firm_config_versions
     set status='published', published_at=now()
   where id = v_config;
  update public.businesses set active_config_version_id = v_config where id = v_business;

  -- A2: the free_item benefit, on a second business (siblings can't share one active row per
  -- v45's own business_id/config_version_id uniqueness) -- reuse the same config/programme
  -- identity is not allowed, so this is asserted via a second config version on the SAME business
  -- is also disallowed (one active row per business+config). Prove A2 via a second business
  -- instead, minimally.
  declare
    v_business2 uuid; v_config2 uuid; v_program2 uuid;
  begin
    insert into public.businesses(name,slug,industry,enabled_modules)
    values('V752 free-item fixture','v752-freeitem-' || substr(gen_random_uuid()::text,1,8),
      'test',array['dashboard','clients','sales','loyalty'])
    returning id into v_business2;
    insert into public.firm_config_versions(business_id,version_no,status,source,snapshot_hash)
    values(v_business2,1,'draft','manual',md5('v752-fixture-2'))
    returning id into v_config2;
    insert into public.birthday_programs(business_id) values(v_business2) returning id into v_program2;
    insert into public.birthday_program_versions(
      program_id,config_version_id,business_id,active,
      customer_label,customer_description,customer_terms,
      fulfillment_kind,product_id,
      window_days_before,window_days_after)
    values(
      v_program2,v_config2,v_business2,true,
      'THIS TYPED TEXT MUST NOT SURVIVE EITHER','A free treat.','Valid during your birthday window only.',
      'free_item',v_product,
      7,7)
    returning id, customer_label into v_freeitem_version, v_freeitem_label;
    update public.firm_config_versions set status='published', published_at=now() where id=v_config2;
  end;

  -- Customer, verified and linked, birthday TODAY so the fixture sits inside the window without
  -- depending on wall-clock date arithmetic elsewhere.
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
    'v752-customer-' || substr(v_customer::text,1,8) || '@example.test','',now(),now(),now()
  );
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration')
  returning id into v_identity;
  insert into public.clients(business_id,full_name,birth_date)
  values(v_business,'V752 birthday customer',current_date)
  returning id into v_client;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  -- The entitlement: hand-inserted rather than driven through "Activate", exactly as v748 hand-
  -- writes its ledger row -- the READ/APPLY behaviour under test does not depend on the
  -- activation RPC, and this keeps the window under the fixture's own control.
  select app.c45_benefit_snapshot(bpv) into v_snapshot
    from public.birthday_program_versions bpv where bpv.id = v_version;
  insert into public.customer_birthday_entitlements(
    business_id,client_id,identity_id,config_version_id,birthday_program_version_id,
    birthday_year,status,valid_from,valid_until,benefit_snapshot)
  values(
    v_business,v_client,v_identity,v_config,v_version,
    extract(year from current_date)::int,'available',
    now()-interval '1 hour',now()+interval '1 day',v_snapshot)
  returning id into v_entitlement;

  -- =============================================================================================
  -- A1 — the derived label, not the typed one, and it carries scope/cap wording.
  -- =============================================================================================
  if v_label <> app.v657_discount_label(10,'bill',500) then
    raise exception 'A1 FAILED: customer_label was not derived. got=%, want=%',
      v_label, app.v657_discount_label(10,'bill',500);
  end if;
  if v_label = 'THIS TYPED TEXT MUST NOT SURVIVE' then
    raise exception 'A1 FAILED: the typed customer_label survived the trigger';
  end if;
  raise notice 'A1 PASSED: discount_pct customer_label derived = %', v_label;

  -- =============================================================================================
  -- A2 — the free_item label, derived from the catalogue pick.
  -- =============================================================================================
  if v_freeitem_label <> ('Free ' || (select name from public.products where id = v_product)) then
    raise exception 'A2 FAILED: got=%, want=%', v_freeitem_label,
      ('Free ' || (select name from public.products where id = v_product));
  end if;
  raise notice 'A2 PASSED: free_item customer_label derived = %', v_freeitem_label;

  -- =============================================================================================
  -- A3 — the customer can mint a gift QR intent for the live entitlement, quoting the derived
  -- label.
  -- =============================================================================================
  perform pg_temp.as_v752_user(v_customer);
  select public.customer_create_gift_intent_v515(v_business,'birthday',v_entitlement,v_key)
    into v_intent;
  if v_intent->>'status' <> 'pending' then
    raise exception 'A3 FAILED: gift intent status=%, full=%', v_intent->>'status', v_intent;
  end if;
  if v_intent->>'reward_label' <> v_label then
    raise exception 'A3 FAILED: quoted label=%, want=%', v_intent->>'reward_label', v_label;
  end if;
  raise notice 'A3 PASSED: gift intent minted, reward_label=%', v_intent->>'reward_label';
  reset role;

  -- =============================================================================================
  -- A4 — the whole-bill 10% discount, capped at $5, actually comes off a $100 line: $10 would be
  -- the uncapped answer, $5 is the capped one, and only $5 must appear.
  -- =============================================================================================
  select app.ps1c_plan_checkout(
    v_business, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_bill_product,'qty',1)),
    v_config, null, true)
    into v_plan;
  if v_plan->>'status' is distinct from null and (v_plan->>'status') not in ('ok') then
    -- ps1c_plan_checkout's success path does not set a 'status' key at all on some builds; only
    -- fail loudly on an explicit ERROR-shaped status.
    if (v_plan->>'status') like '%not_available%' or (v_plan->>'status') like '%invalid%' then
      raise exception 'A4 FAILED: checkout plan errored: %', v_plan;
    end if;
  end if;
  select e into v_applied from jsonb_array_elements(coalesce(v_plan->'applied_effects','[]'::jsonb)) e
   where e->>'source' = 'birthday_benefit' limit 1;
  if v_applied is null then
    raise exception 'A4 FAILED: no birthday_benefit effect in plan: %', v_plan;
  end if;
  if (v_applied->>'amount_cents')::int <> 500 then
    raise exception 'A4 FAILED: discount amount=%, want=500 (cap honoured)', v_applied->>'amount_cents';
  end if;
  raise notice 'A4 PASSED: birthday discount capped at % cents', v_applied->>'amount_cents';

  -- =============================================================================================
  -- A5 — one use per window: once the entitlement is spent, both the pricing path and the QR-mint
  -- path refuse a second use.
  -- =============================================================================================
  -- customer_birthday_entitlements is guarded by c45_entitlement_guard against a direct
  -- UPDATE ("birthday entitlement provenance is immutable") — spending it for real, exactly
  -- as the till does, means going through public.redeem_customer_birthday_benefit as the
  -- owner/staff actor the fixture already set up.
  perform pg_temp.as_v752_user(v_owner_auth);
  perform public.redeem_customer_birthday_benefit(v_business, v_client, v_branch, gen_random_uuid());
  reset role;

  select app.ps1c_plan_checkout(
    v_business, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_bill_product,'qty',1)),
    v_config, null, true)
    into v_plan2;
  if v_plan2->>'status' <> 'birthday_benefit_not_available' then
    raise exception 'A5a FAILED: expected birthday_benefit_not_available after redemption, got %', v_plan2;
  end if;
  raise notice 'A5a PASSED: spent entitlement refused at checkout';

  -- A3's own intent is still 'pending' (never scanned/staged), so a naive second call would just
  -- replay it and never reach the entitlement-availability check A5b is proving. Expire it first,
  -- exactly as the till's own cleanup does (customer_create_gift_intent_v515 itself expires stale
  -- pending intents for a target before minting a fresh one) -- status is not one of the columns
  -- app.v515_gift_intent_guard protects, so this is a legitimate operational transition.
  update public.customer_gift_intents_v515 set status='expired' where id=(v_intent->>'intent_id')::uuid;

  perform pg_temp.as_v752_user(v_customer);
  begin
    select public.customer_create_gift_intent_v515(v_business,'birthday',v_entitlement,gen_random_uuid())
      into v_intent2;
    raise exception 'A5b FAILED: gift intent minted for a spent entitlement: %', v_intent2;
  exception when others then
    if sqlerrm not like '%not available%' then
      raise exception 'A5b FAILED: wrong refusal: %', sqlerrm;
    end if;
    raise notice 'A5b PASSED: spent entitlement refused a new gift intent (%)', sqlerrm;
  end;
  reset role;

  raise notice 'V752 SUITE: ALL ASSERTIONS PASSED';
end
$v752_test$;

rollback;
