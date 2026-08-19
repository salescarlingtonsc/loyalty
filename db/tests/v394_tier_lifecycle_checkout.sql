-- Rollback-only v394 tier-lifecycle-at-checkout acceptance suite.
-- Run after the canonical chain through v394 in a disposable database.
--
-- Owner ruling 2026-08-20: a paused or soft-deleted tier grants NOTHING — no checkout
-- discount, no staff-issuable benefit — and the customer falls to the next live rung,
-- exactly as the v393 display already computes it. This suite proves all four patched
-- sites end to end: the rung (app.v365_client_tier), the auto tier discount inside the
-- pricing authority (app.ps1c_plan_checkout), the staff Give listing
-- (staff_tier_benefits_for_client_v365), and actual issuance (staff_issue_tier_benefit_v365).
-- Ladder: Gold (sort 100, 20% benefit) over Silver (sort 10, 5% benefit), both threshold 0.
begin;

do $v394$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid; v_client uuid; v_svc uuid;
  v_gold uuid; v_silver uuid; v_gold_ben uuid;
  r public.loyalty_tiers; j jsonb; plan jsonb; s jsonb;
  v_issue jsonb;
begin
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
         'v394-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses (name, slug)
  values ('V394 tier lifecycle fixture', 'v394-tier-'||substr(gen_random_uuid()::text,1,8))
  returning id into v_biz;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (v_biz, v_owner, 'owner', 'V394 Owner', true, 'approved');
  insert into public.business_workspace_controls_v94 (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v394 acceptance suite')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v394 acceptance suite';
  insert into public.business_subscription_lifecycle_v94 (business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused = false;
  insert into public.loyalty_programs (business_id, active, configuration_status)
  values (v_biz, true, 'published');
  insert into public.clients (business_id, full_name) values (v_biz,'V394 member') returning id into v_client;
  insert into public.services (business_id, name, price_cents, duration_min)
  values (v_biz,'V394 Cut',10000,30) returning id into v_svc;
  insert into public.loyalty_tiers (business_id, name, threshold, sort) values (v_biz,'V394 Gold',0,100) returning id into v_gold;
  insert into public.loyalty_tiers (business_id, name, threshold, sort) values (v_biz,'V394 Silver',0,10) returning id into v_silver;
  insert into public.tier_benefits_v365 (business_id, tier_id, label, benefit_kind, discount_percent)
  values (v_biz, v_gold, 'Gold 20% off', 'discount_pct', 20) returning id into v_gold_ben;
  insert into public.tier_benefits_v365 (business_id, tier_id, label, benefit_kind, discount_percent)
  values (v_biz, v_silver, 'Silver 5% off', 'discount_pct', 5);

  -- A. Control: everything live — Gold rung, 20% applies, staff sees both benefits, issue works.
  r := app.v365_client_tier(v_biz, v_client);
  if r.name is distinct from 'V394 Gold' then
    raise exception 'v394 A1: expected live rung V394 Gold, got %', coalesce(r.name,'null');
  end if;
  j := app.customer_tier_json_v393(v_biz, v_client);
  if j->>'name' is distinct from 'V394 Gold' then
    raise exception 'v394 A2: display expected V394 Gold, got %', coalesce(j->>'name','null');
  end if;
  plan := app.ps1c_plan_checkout(v_biz, null, v_client,
            jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)), null);
  if (plan->>'discount_total_cents')::int is distinct from 2000 then
    raise exception 'v394 A3: live Gold must discount 2000, got %', plan->>'discount_total_cents';
  end if;
  s := public.staff_tier_benefits_for_client_v365(v_biz, v_client);
  if jsonb_array_length(s->'benefits') is distinct from 2 then
    raise exception 'v394 A4: staff list must carry 2 benefits, got %', s->'benefits';
  end if;
  v_issue := public.staff_issue_tier_benefit_v365(v_biz, v_client, v_gold_ben);
  if v_issue->>'status' is distinct from 'issued' then
    raise exception 'v394 A5: live Gold benefit must issue, got %', v_issue->>'status';
  end if;

  -- B. Gold PAUSED: rung falls to Silver, Gold's 20% does not donate, staff cannot issue it.
  update public.loyalty_tiers set paused = true where id = v_gold;
  r := app.v365_client_tier(v_biz, v_client);
  if r.name is distinct from 'V394 Silver' then
    raise exception 'v394 B1: paused Gold must yield rung V394 Silver, got %', coalesce(r.name,'null');
  end if;
  j := app.customer_tier_json_v393(v_biz, v_client);
  if j->>'name' is distinct from 'V394 Silver' then
    raise exception 'v394 B2: display expected V394 Silver, got %', coalesce(j->>'name','null');
  end if;
  plan := app.ps1c_plan_checkout(v_biz, null, v_client,
            jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)), null);
  if (plan->>'discount_total_cents')::int is distinct from 500 then
    raise exception 'v394 B3: paused Gold must not donate its 20%%; expected 500, got %', plan->>'discount_total_cents';
  end if;
  s := public.staff_tier_benefits_for_client_v365(v_biz, v_client);
  if jsonb_array_length(s->'benefits') is distinct from 1 then
    raise exception 'v394 B4: staff list must drop the paused tier benefit, got %', s->'benefits';
  end if;
  begin
    v_issue := public.staff_issue_tier_benefit_v365(v_biz, v_client, v_gold_ben);
    raise exception 'v394 B5: paused-tier benefit was ISSUED (%)', v_issue->>'status';
  exception when others then
    if sqlerrm not like '%tier_benefit_not_found%' then raise; end if;
  end;

  -- C. Gold SOFT-DELETED: identical outcome.
  update public.loyalty_tiers set paused = false, deleted_at = now() where id = v_gold;
  r := app.v365_client_tier(v_biz, v_client);
  if r.name is distinct from 'V394 Silver' then
    raise exception 'v394 C1: deleted Gold must yield rung V394 Silver, got %', coalesce(r.name,'null');
  end if;
  plan := app.ps1c_plan_checkout(v_biz, null, v_client,
            jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)), null);
  if (plan->>'discount_total_cents')::int is distinct from 500 then
    raise exception 'v394 C2: deleted Gold must not donate its 20%%; expected 500, got %', plan->>'discount_total_cents';
  end if;
  begin
    v_issue := public.staff_issue_tier_benefit_v365(v_biz, v_client, v_gold_ben);
    raise exception 'v394 C3: deleted-tier benefit was ISSUED (%)', v_issue->>'status';
  exception when others then
    if sqlerrm not like '%tier_benefit_not_found%' then raise; end if;
  end;

  -- D. BOTH rungs dead: no tier anywhere, discount zero, staff sees an empty ladder.
  update public.loyalty_tiers set paused = true where id = v_silver;
  r := app.v365_client_tier(v_biz, v_client);
  if r.id is not null then
    raise exception 'v394 D1: dead ladder must yield no rung, got %', r.name;
  end if;
  j := app.customer_tier_json_v393(v_biz, v_client);
  if j is not null then
    raise exception 'v394 D2: display must be null on a dead ladder, got %', j;
  end if;
  plan := app.ps1c_plan_checkout(v_biz, null, v_client,
            jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)), null);
  if (plan->>'discount_total_cents')::int is distinct from 0 then
    raise exception 'v394 D3: dead ladder must discount 0, got %', plan->>'discount_total_cents';
  end if;
  s := public.staff_tier_benefits_for_client_v365(v_biz, v_client);
  if s->'tier' is distinct from 'null'::jsonb then
    raise exception 'v394 D4: staff tier must be null on a dead ladder, got %', s->'tier';
  end if;

  raise notice 'v394 suite: 14 assertions passed';
end $v394$;

rollback;
