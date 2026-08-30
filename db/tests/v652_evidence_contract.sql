-- Rollback-only v652 acceptance suite: app.evidence_block_v1 is the shared contract every
-- comparative claim in the product must use, and public.get_recovery_report_v550 is the first
-- report retrofitted onto it. The blueprint's concern was that v550 led with a confident
-- "Recovered revenue (estimated)" figure computed against a baseline that is NOT a holdout —
-- it is whoever the campaign happened to miss — so this migration adds an evidence block beside
-- the existing arithmetic (unchanged) rather than replacing it.
--
-- Section C proves the evidence contract itself: the verdict ceiling, the interval-spanning-zero
-- rule, and the small-arm floor, using plain numeric inputs (no fixture required). Section D
-- proves v550's retrofit: the evidence block is present, its ceiling is early_signal (a
-- non-randomised comparison may never claim strong_pattern, however large the sample), at least
-- three limitations are named, and every pre-existing top-level key survives untouched.
--
-- Run after the complete canonical chain through v652 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

-- ---------------------------------------------------------------------------
-- C. app.evidence_block_v1 — ceiling, spanning-zero, small-arm, randomised-may-pass.
-- ---------------------------------------------------------------------------
do $c$
declare v jsonb;
begin
  -- a large, clearly separated difference still cannot exceed the ceiling
  v := app.evidence_block_v1('pop','den', current_date-30, current_date,
        400, 200, 400, 40, 'non-randomised', 'early_signal');
  if v->>'verdict' <> 'early_signal' then
    raise exception 'C1: ceiling not applied to a strong separation: %', v;
  end if;
  if (v->'difference'->>'absolute_pp')::numeric <= 0 then
    raise exception 'C2: expected a positive difference: %', v;
  end if;

  -- an interval spanning zero is insufficient, whatever the ceiling
  v := app.evidence_block_v1('pop','den', current_date-30, current_date,
        100, 50, 100, 49, 'non-randomised', 'strong_pattern');
  if v->>'verdict' <> 'insufficient' then
    raise exception 'C3: a difference indistinguishable from zero must be insufficient: %', v;
  end if;

  -- a tiny arm is insufficient regardless of separation
  v := app.evidence_block_v1('pop','den', current_date-30, current_date,
        5, 5, 5, 0, 'non-randomised', 'strong_pattern');
  if v->>'verdict' <> 'insufficient' then
    raise exception 'C4: arms below the minimum must be insufficient: %', v;
  end if;

  -- a genuinely randomised comparison may reach strong_pattern
  v := app.evidence_block_v1('pop','den', current_date-30, current_date,
        400, 200, 400, 40, 'randomised holdout', 'strong_pattern');
  if v->>'verdict' <> 'strong_pattern' then
    raise exception 'C5: a randomised comparison should be allowed to reach strong_pattern: %', v;
  end if;

  -- an unsupported ceiling value is refused, not silently accepted
  begin
    perform app.evidence_block_v1('pop','den', current_date-30, current_date,
      100, 50, 100, 10, 'non-randomised', 'not_a_real_ceiling');
    raise exception 'C6: an invalid verdict ceiling must be refused';
  exception when sqlstate '22023' then null;
  end;

  raise notice 'C OK: evidence contract (ceiling, spanning-zero, small-arm, randomised-may-pass, invalid-ceiling-refused)';
end
$c$;

-- ---------------------------------------------------------------------------
-- Fixture for section D: a fresh tenant with a completed campaign so v550 has real
-- interventions and a real baseline to compute against.
-- ---------------------------------------------------------------------------
do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_campaign uuid;
  v_branch uuid;
  v_h uuid; v_m uuid; v_sale_h30 uuid;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'v652-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'V652 fixture',
    'v652-'||substr(v_business::text,1,8),'facial',true,
    array['dashboard','clients','sales','till','appointments','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','V652 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  select id into v_branch from public.branches where business_id = v_business limit 1;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='v652 rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  -- The v106 reporting contract is stamped effective_from = now() when the business is
  -- created, and app.v106_reporting_contract only matches rows with
  -- effective_from <= the sale's occurred_at. Fixture visits are deliberately BACKDATED, so
  -- without an earlier contract every sale is eliminated by the cadence helper's lateral
  -- join and the suite sees no rows at all. Real tenants never hit this: their contract is
  -- created before their first sale. Append an earlier version for both the business-wide
  -- and the branch-scoped lookup (the table is append-only, so this is an INSERT).
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency)
  values (v_business, null,     2, now() - interval '400 days', 'Asia/Singapore', 'SGD'),
         (v_business, v_branch, 2, now() - interval '400 days', 'Asia/Singapore', 'SGD');

  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days)
  values (v_business, 'V652 Suite Campaign', 'Free coffee', 30) returning id into v_campaign;

  -- H: a voucher winner — two prior visits, a voucher grant while lapsed, redeemed against a
  -- return inside the attribution window.
  insert into public.clients(business_id, full_name, phone, is_synthetic)
  values (v_business, 'V652 Voucher Winner', '82240001', false) returning id into v_h;
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
  values
    (v_business, v_h, 'service', 2000, true, false, now() - interval '80 days'),
    (v_business, v_h, 'service', 2000, true, false, now() - interval '60 days');
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
  values (v_business, v_h, 'service', 3000, true, false, now() - interval '30 days')
  returning id into v_sale_h30;
  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days,
    cycle_key, status, granted_at, redeemed_at, redeemed_sale_id
  ) values (
    v_business, v_campaign, v_h, 'Free coffee', 30,
    (now() - interval '40 days')::date, 'redeemed',
    now() - interval '40 days', now() - interval '30 days', v_sale_h30
  );

  -- M: a baseline stayer — lapsed at the window start (report window opens at now()-90d,
  -- and the report's min-absence rule needs the last visit at least 14 days before THAT,
  -- so the visit must sit at or before now()-104d), no intervention, never returns.
  insert into public.clients(business_id, full_name, phone, is_synthetic)
  values (v_business, 'V652 Baseline Stayer', '82240002', false) returning id into v_m;
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
  values (v_business, v_m, 'service', 2000, true, false, now() - interval '200 days');

  perform set_config('v652.owner', v_owner::text, true);
  perform set_config('v652.business', v_business::text, true);
end
$fixture$;

create or replace function pg_temp.as_v652_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end;
$$;
grant execute on function pg_temp.as_v652_user(uuid) to public;

-- ---------------------------------------------------------------------------
-- D. public.get_recovery_report_v550 — evidence block present, capped, limitations named,
--    every pre-existing key intact.
-- ---------------------------------------------------------------------------
do $d$
declare
  v_business uuid := current_setting('v652.business')::uuid;
  v_owner uuid := current_setting('v652.owner')::uuid;
  v jsonb;
begin
  perform pg_temp.as_v652_user(v_owner);
  v := public.get_recovery_report_v550(v_business,
         (now() at time zone 'Asia/Singapore')::date - 90,
         (now() at time zone 'Asia/Singapore')::date + 1);
  reset role;

  if v->'evidence' is null then
    raise exception 'D1: v550 is missing its evidence block: %', v;
  end if;
  if v->'evidence'->>'verdict_ceiling' <> 'early_signal' then
    raise exception 'D2: the recovery report must be capped at early_signal: %', v->'evidence';
  end if;
  if v->'evidence'->>'verdict' = 'strong_pattern' then
    raise exception 'D3: a non-randomised report reported a strong pattern: %', v->'evidence';
  end if;
  if jsonb_array_length(v->'evidence'->'limitations') < 3 then
    raise exception 'D4: the named limitations are missing: %', v->'evidence';
  end if;
  -- every pre-existing key still present, unaffected by the retrofit
  if v->'net' is null or v->'baseline' is null or v->'recovered' is null
     or v->'returned' is null or v->'interventions' is null or v->'monthly' is null
     or v->'low_confidence' is null or v->'window' is null then
    raise exception 'D5: v550 lost a pre-existing key: %', v;
  end if;
  -- the fixture's own arithmetic still holds: one treated (voucher), one returned, one baseline
  -- cohort member who never returned
  if (v->'interventions'->>'treated')::int <> 1 or (v->'interventions'->>'vouchers')::int <> 1 then
    raise exception 'D6: fixture intervention count mismatch: %', v->'interventions';
  end if;
  if (v->'returned'->>'count')::int <> 1 then
    raise exception 'D7: fixture return count mismatch: %', v->'returned';
  end if;
  if (v->'baseline'->>'cohort')::int <> 1 or (v->'baseline'->>'returned')::int <> 0 then
    raise exception 'D8: fixture baseline mismatch: %', v->'baseline';
  end if;

  raise notice 'D OK: v550 retrofitted — evidence block present, capped at early_signal, limitations named, pre-existing keys intact';
end
$d$;

reset role;
select 'V652_SUITE_PASSED' as verdict;

rollback;
