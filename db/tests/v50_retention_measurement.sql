-- Rollback-only v50 retention-measurement suite.
-- Run after the complete canonical chain through v50 in a disposable rehearsal DB.
-- Synthetic rows never commit.
begin;
\ir fixtures/pristine_chain_fixture.psql

create temporary table v50_ctx(owner_a uuid, business_a uuid, campaign uuid) on commit drop;
grant select on v50_ctx to authenticated;

create or replace function pg_temp.as_v50(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if p_role = 'anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  elsif p_role = 'authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  else
    raise exception 'unsupported v50 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v50(uuid, text) to authenticated, anon;

create or replace function pg_temp.expect_v50(p_sql text, p_label text, p_sqlstate text default '42501')
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded', p_label;
exception when others then
  if sqlstate <> p_sqlstate then
    raise exception '% failed with %, expected %: %', p_label, sqlstate, p_sqlstate, sqlerrm;
  end if;
end $$;
grant execute on function pg_temp.expect_v50(text, text, text) to authenticated, anon;

do $v50_test$
declare
  v_owner_a uuid; v_business_a uuid; v_owner_staff uuid; v_branch uuid;
  v_owner_b uuid; v_business_b uuid;
  v_manager uuid := gen_random_uuid(); v_frontdesk uuid := gen_random_uuid();
  v_base uuid; v_draft uuid; v_hash text; v_program uuid := gen_random_uuid();
  v_tax uuid; v_rule_version uuid;
  v_client uuid; v_client_ids uuid[] := array[]::uuid[];
  v_campaign uuid; v_campaign2 uuid; v_result jsonb;
  v_treatment uuid[]; v_holdout uuid[];
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_h1 uuid;
  v_c2_t1 uuid; v_c2_t2 uuid;
  v_sale_t3 uuid;
  v_members integer; v_t_members integer; v_h_members integer;
  v_bucket smallint; v_bucket_again smallint;
begin
  -- --------------------------------------------------------------------------
  -- Locate the pristine tenants: A (loyalty-active) and B (a separate tenant).
  -- --------------------------------------------------------------------------
  reset role;
  select b.id, s.user_id, s.id into v_business_a, v_owner_a, v_owner_staff
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select b.id, s.user_id into v_business_b, v_owner_b
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture B';
  if v_business_a is null or v_business_b is null then raise exception 'v50 suite requires the pristine A/B tenants'; end if;
  select id into v_branch from public.branches where business_id = v_business_a and active order by is_default desc, created_at limit 1;
  if v_branch is null then raise exception 'v50 suite requires an active branch for A'; end if;

  -- A manager (view_finance) and a frontdesk (no view_finance) on tenant A.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_manager, 'authenticated', 'authenticated',
     'v50-manager-'||substr(v_manager::text,1,8)||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_frontdesk, 'authenticated', 'authenticated',
     'v50-frontdesk-'||substr(v_frontdesk::text,1,8)||'@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business_a, v_manager, 'manager', 'V50 Manager', true),
         (v_business_a, v_frontdesk, 'frontdesk', 'V50 Frontdesk', true);

  -- --------------------------------------------------------------------------
  -- Publish a versioned retention rule (credit reward) as owner A.
  -- --------------------------------------------------------------------------
  perform pg_temp.as_v50(v_owner_a, 'authenticated');
  select active_config_version_id into v_base from public.businesses where id = v_business_a;
  select id into v_tax from public.firm_reward_taxonomy
   where business_id = v_business_a and fulfillment_kind = 'credit' and active order by sort, id limit 1;
  if v_tax is null then raise exception 'v50 suite requires a seeded credit taxonomy'; end if;
  v_draft := (public.create_loyalty_config_draft(v_business_a, v_base, 'v50-retention-setup')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_draft;
  perform public.save_retention_program_draft(v_draft, v_program, jsonb_build_object(
    'name', 'V50 winback rule', 'active', true, 'goal_visits', 1, 'period_days', 30,
    'starts_on', current_date, 'reward_taxonomy_id', v_tax, 'credit_cents', 500, 'sort', 10), v_hash);
  perform public.publish_loyalty_config(v_draft);
  select id into v_rule_version from public.retention_program_versions
   where program_id = v_program and config_version_id = v_draft and business_id = v_business_a;
  if v_rule_version is null then raise exception 'v50 could not resolve the published retention program version'; end if;

  -- 30 fresh audience clients for A (privileged fixture seeding, then resume owner).
  reset role;
  for i in 1..30 loop
    insert into public.clients(business_id, full_name) values (v_business_a, 'V50 audience '||i) returning id into v_client;
    v_client_ids := v_client_ids || v_client;
  end loop;
  perform pg_temp.as_v50(v_owner_a, 'authenticated');

  -- --------------------------------------------------------------------------
  -- Create a campaign and prove deterministic, reproducible holdout bucketing.
  -- --------------------------------------------------------------------------
  v_result := public.create_retention_campaign(
    v_business_a, v_rule_version, 'V50 lapsed winback',
    jsonb_build_object('segment', 'lapsed_60d', 'min_ltv_cents', 20000),
    50, 0, 30, 5000, 40000, 'Lapsed 60 days, above-median lifetime value.')::jsonb;
  v_campaign := (v_result->>'campaign_id')::uuid;
  if v_result->>'status' <> 'draft' then raise exception 'new campaign must start as draft'; end if;

  v_bucket := app.campaign_holdout_bucket(v_campaign, v_client_ids[1]);
  v_bucket_again := app.campaign_holdout_bucket(v_campaign, v_client_ids[1]);
  if v_bucket is distinct from v_bucket_again or v_bucket not between 0 and 99 then
    raise exception 'holdout bucket is not deterministically reproducible';
  end if;

  -- --------------------------------------------------------------------------
  -- Activate: freeze audience + assign arms deterministically.
  -- --------------------------------------------------------------------------
  v_result := public.activate_retention_campaign(v_business_a, v_campaign, v_client_ids, 'v50-activate-key-01')::jsonb;
  if v_result->>'status' <> 'active' or (v_result->>'audience_size')::int <> 30
     or coalesce((v_result->>'replayed')::boolean, true) <> false then
    raise exception 'activation did not freeze a 30-member audience: %', v_result;
  end if;
  select count(*), count(*) filter (where assignment='treatment'), count(*) filter (where assignment='holdout')
    into v_members, v_t_members, v_h_members
    from public.retention_campaign_members where campaign_id = v_campaign;
  if v_members <> 30 or v_t_members < 3 or v_h_members < 3 then
    raise exception 'deterministic split produced an unusable arm size (t=%, h=%)', v_t_members, v_h_members;
  end if;

  -- Stored bucket matches the pure helper, and assignment matches the modulo rule.
  if exists (
    select 1 from public.retention_campaign_members m
     where m.campaign_id = v_campaign
       and (m.assignment_bucket <> app.campaign_holdout_bucket(v_campaign, m.client_id)
            or (m.assignment = 'holdout') <> (m.assignment_bucket < 50))
  ) then raise exception 'stored arm assignment diverged from the deterministic bucket rule'; end if;

  -- Frozen: re-activation is idempotent and a different audience cannot mutate it.
  v_result := public.activate_retention_campaign(v_business_a, v_campaign, v_client_ids[1:5], 'v50-activate-key-02')::jsonb;
  if coalesce((v_result->>'replayed')::boolean, false) <> true
     or (select count(*) from public.retention_campaign_members where campaign_id = v_campaign) <> 30 then
    raise exception 'a frozen active audience was mutated by re-activation';
  end if;

  select array_agg(client_id order by client_id) into v_treatment
    from public.retention_campaign_members where campaign_id = v_campaign and assignment = 'treatment';
  select array_agg(client_id order by client_id) into v_holdout
    from public.retention_campaign_members where campaign_id = v_campaign and assignment = 'holdout';
  v_t1 := v_treatment[1]; v_t2 := v_treatment[2]; v_t3 := v_treatment[3]; v_h1 := v_holdout[1];

  -- --------------------------------------------------------------------------
  -- Offer issuance: treatment ok + idempotent; holdout is refused.
  -- --------------------------------------------------------------------------
  v_result := public.issue_campaign_offer(v_business_a, v_campaign, v_t1, 'v50-offer-t1-key')::jsonb;
  if (v_result->>'offer_cost_cents')::bigint <> 500 or coalesce((v_result->>'replayed')::boolean, true) <> false then
    raise exception 'first treatment offer did not issue at the rule credit cost: %', v_result;
  end if;
  v_result := public.issue_campaign_offer(v_business_a, v_campaign, v_t1, 'v50-offer-t1-key')::jsonb;
  if coalesce((v_result->>'replayed')::boolean, false) <> true
     or (select count(*) from public.retention_campaign_grants where campaign_id = v_campaign and client_id = v_t1) <> 1 then
    raise exception 'repeated identical offer issuance created a duplicate grant';
  end if;
  perform public.issue_campaign_offer(v_business_a, v_campaign, v_t2, 'v50-offer-t2-key');
  perform public.issue_campaign_offer(v_business_a, v_campaign, v_t3, 'v50-offer-t3-key');

  -- Holdout member can never receive the offer (enforced in the granting path).
  perform pg_temp.expect_v50(
    format('select public.issue_campaign_offer(%L,%L,%L,%L)', v_business_a, v_campaign, v_h1, 'v50-offer-h1-key'),
    'holdout offer issuance');
  if exists (select 1 from public.retention_campaign_grants where campaign_id = v_campaign and client_id = v_h1) then
    raise exception 'a holdout grant row was created';
  end if;

  -- --------------------------------------------------------------------------
  -- Returns within the attribution window; one treatment return is reversed.
  -- --------------------------------------------------------------------------
  perform public.record_quick_sale(v_business_a, 5000, 'cash', v_t1, v_owner_staff, v_branch, 'v50 t1 return', 'v50-sale-t1-key', true);
  perform public.record_quick_sale(v_business_a, 5000, 'cash', v_t2, v_owner_staff, v_branch, 'v50 t2 return', 'v50-sale-t2-key', true);
  v_sale_t3 := (public.record_quick_sale(v_business_a, 5000, 'cash', v_t3, v_owner_staff, v_branch, 'v50 t3 return', 'v50-sale-t3-key', true)::jsonb->'sale'->>'id')::uuid;
  perform public.record_quick_sale(v_business_a, 5000, 'cash', v_h1, v_owner_staff, v_branch, 'v50 h1 return', 'v50-sale-h1-key', true);
  -- Reverse T3: a reversed sale must never count as a return.
  perform public.reverse_sale(v_business_a, v_sale_t3, 'v50 reversal provenance for the return', 'v50-reverse-t3-key');

  -- Durable per-member first-return evidence (reversal-aware): T1, T2, H1; not T3.
  v_result := public.record_campaign_returns(v_business_a, v_campaign)::jsonb;
  if (v_result->>'newly_recorded')::int <> 3 then
    raise exception 'expected exactly 3 first-return records (t1,t2,h1), got %', v_result->>'newly_recorded';
  end if;
  if exists (select 1 from public.retention_campaign_returns where campaign_id = v_campaign and client_id = v_t3) then
    raise exception 'a reversed sale was recorded as a return';
  end if;
  if not exists (select 1 from public.retention_campaign_returns r
                  where r.campaign_id = v_campaign and r.client_id = v_t1
                    and r.assignment = 'treatment' and r.returned_at is not null) then
    raise exception 'first qualifying return sale/timestamp was not recorded per member';
  end if;

  -- --------------------------------------------------------------------------
  -- Lift readout math (owner). Split-independent absolute checks + arithmetic.
  -- --------------------------------------------------------------------------
  v_result := public.get_campaign_results(v_campaign)::jsonb;
  if (v_result->'treatment'->>'offers_issued')::int <> 3
     or (v_result->>'grant_cost_cents')::bigint <> 1500 then
    raise exception 'offers/grant-cost readout wrong: %', v_result;
  end if;
  if (v_result->'treatment'->>'returned')::int <> 2
     or (v_result->'treatment'->>'revenue_cents')::bigint <> 10000
     or (v_result->'holdout'->>'returned')::int <> 1
     or (v_result->'holdout'->>'revenue_cents')::bigint <> 5000 then
    raise exception 'reversal-aware returns/revenue readout wrong: %', v_result;
  end if;
  if (v_result->'treatment'->>'members')::int + (v_result->'holdout'->>'members')::int <> 30
     or (v_result->'treatment'->>'members')::int <> v_t_members
     or (v_result->'holdout'->>'members')::int <> v_h_members then
    raise exception 'member counts readout wrong: %', v_result;
  end if;
  -- Internal arithmetic consistency (bps, net lift, incremental counterfactual).
  if (v_result->'treatment'->>'return_rate_bps')::int <> (2 * 10000) / v_t_members
     or (v_result->'holdout'->>'return_rate_bps')::int <> (1 * 10000) / v_h_members
     or (v_result->>'net_lift_bps')::int
        <> ((2 * 10000) / v_t_members) - ((1 * 10000) / v_h_members)
     or (v_result->>'incremental_returns')::bigint
        <> 2 - round(v_t_members::numeric * 1 / v_h_members)
     or (v_result->>'incremental_revenue_cents')::bigint
        <> 10000 - round(v_t_members::numeric * 5000 / v_h_members) then
    raise exception 'incremental-lift arithmetic is inconsistent: %', v_result;
  end if;
  if (v_result->>'net_lift_bps')::int <= 0 then
    raise exception 'expected positive measured lift for this fixture: %', v_result;
  end if;

  -- Manager may read results; frontdesk (no view_finance) may not.
  perform pg_temp.as_v50(v_manager, 'authenticated');
  perform public.get_campaign_results(v_campaign);
  perform public.list_retention_campaigns(v_business_a);
  perform pg_temp.as_v50(v_frontdesk, 'authenticated');
  perform pg_temp.expect_v50(format('select public.get_campaign_results(%L)', v_campaign), 'frontdesk results read');
  perform pg_temp.expect_v50(format('select public.list_retention_campaigns(%L)', v_business_a), 'frontdesk list read');

  -- The read gate is pinned to the 'retention' module key (NOT 'loyalty'):
  -- a manager allowlisted for loyalty only is denied; retention-only is allowed.
  reset role;
  update public.staff set modules = array['loyalty']
   where business_id = v_business_a and user_id = v_manager;
  perform pg_temp.as_v50(v_manager, 'authenticated');
  perform pg_temp.expect_v50(format('select public.get_campaign_results(%L)', v_campaign), 'loyalty-only manager results read');
  perform pg_temp.expect_v50(format('select public.list_retention_campaigns(%L)', v_business_a), 'loyalty-only manager list read');
  reset role;
  update public.staff set modules = array['retention']
   where business_id = v_business_a and user_id = v_manager;
  perform pg_temp.as_v50(v_manager, 'authenticated');
  perform public.get_campaign_results(v_campaign);
  perform public.list_retention_campaigns(v_business_a);
  reset role;
  update public.staff set modules = null
   where business_id = v_business_a and user_id = v_manager;

  -- --------------------------------------------------------------------------
  -- Budget cap: a second campaign whose cap admits exactly one offer.
  -- --------------------------------------------------------------------------
  perform pg_temp.as_v50(v_owner_a, 'authenticated');
  v_campaign2 := (public.create_retention_campaign(
    v_business_a, v_rule_version, 'V50 capped', jsonb_build_object('segment', 'test'),
    50, 500, 30, null, null, null)::jsonb->>'campaign_id')::uuid;
  perform public.activate_retention_campaign(v_business_a, v_campaign2, v_client_ids, 'v50-activate-cap-key');
  select array_agg(client_id order by client_id) into v_treatment
    from public.retention_campaign_members where campaign_id = v_campaign2 and assignment = 'treatment';
  v_c2_t1 := v_treatment[1]; v_c2_t2 := v_treatment[2];
  perform public.issue_campaign_offer(v_business_a, v_campaign2, v_c2_t1, 'v50-cap-offer-1');
  perform pg_temp.expect_v50(
    format('select public.issue_campaign_offer(%L,%L,%L,%L)', v_business_a, v_campaign2, v_c2_t2, 'v50-cap-offer-2'),
    'over-budget offer issuance', '23514');

  -- --------------------------------------------------------------------------
  -- Cross-tenant + anon denials.
  -- --------------------------------------------------------------------------
  perform pg_temp.as_v50(v_owner_b, 'authenticated');
  perform pg_temp.expect_v50(format('select public.get_campaign_results(%L)', v_campaign), 'cross-tenant results read');
  perform pg_temp.expect_v50(format('select public.list_retention_campaigns(%L)', v_business_a), 'cross-tenant list read');
  perform pg_temp.expect_v50(
    format('select public.issue_campaign_offer(%L,%L,%L,%L)', v_business_a, v_campaign, v_t2, 'v50-cross-key-1'),
    'cross-tenant offer issuance');
  perform pg_temp.expect_v50(
    format('select public.activate_retention_campaign(%L,%L,%L,%L)', v_business_a, v_campaign, v_client_ids, 'v50-cross-key-2'),
    'cross-tenant activation');
  perform pg_temp.expect_v50(
    format('select public.create_retention_campaign(%L,%L,%L,%L)', v_business_a, v_rule_version, 'x', '{}'::jsonb),
    'cross-tenant campaign creation');

  perform pg_temp.as_v50(null, 'anon');
  perform pg_temp.expect_v50(format('select public.get_campaign_results(%L)', v_campaign), 'anon results read');
  perform pg_temp.expect_v50(format('select public.list_retention_campaigns(%L)', v_business_a), 'anon list read');

  -- --------------------------------------------------------------------------
  -- ACL contract: authenticated-only execution; anon has none.
  -- --------------------------------------------------------------------------
  reset role;
  if has_function_privilege('anon', 'public.get_campaign_results(uuid)', 'execute')
     or has_function_privilege('anon', 'public.create_retention_campaign(uuid,uuid,text,jsonb,integer,bigint,integer,bigint,bigint,text)', 'execute')
     or has_function_privilege('anon', 'public.activate_retention_campaign(uuid,uuid,uuid[],text)', 'execute')
     or has_function_privilege('anon', 'public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid)', 'execute')
     or has_function_privilege('anon', 'public.list_retention_campaigns(uuid)', 'execute') then
    raise exception 'v50 exposed a retention RPC to anon';
  end if;
  if not has_function_privilege('authenticated', 'public.get_campaign_results(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.record_campaign_returns(uuid,uuid)', 'execute') then
    raise exception 'v50 authenticated RPC ACL is incomplete';
  end if;

  raise notice 'v50 retention measurement suite: ALL PASS';
end $v50_test$;

reset role;
rollback;
