-- Rollback-only v651 acceptance suite: app.customer_cadence_batch_v1 is the one canonical
-- median-inter-purchase-interval computation (extracted verbatim from v107's interval_evidence
-- CTE), and app.customer_cadence_v1 is the per-customer answer built on top of it (evidence
-- source, expected-next-visit window, deviation state). v107 itself is re-pointed at the batch
-- helper by this migration; section A of the production validation chain
-- (scratchpad/phase-d-after.sql) is the decisive proof that the swap is output-identical for
-- every real business — this suite covers section B, the vocabulary and shape of the new
-- helpers, plus a self-contained equivalence check against a fixture with known intervals.
--
-- CRITICAL: get_customer_lifecycle_v107 stamps a fresh `generated_at` into every response, so
-- any before/after comparison of its payload MUST strip that key first, or the comparison fails
-- on two textually-identical calls and proves nothing. This suite does not call v107 directly
-- (that equivalence was already proven against production before this migration was trusted),
-- but the same landmine applies to app.customer_cadence_v1's own `last_visit_at`/timestamp
-- fields if this suite is ever extended to diff two live calls — compare the numeric/enum
-- fields, not raw payload equality, when time has moved between calls.
--
-- Run after the complete canonical chain through v651 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_c_rhythm uuid;   -- >=4 paid visits at known, regular intervals
  v_c_single uuid;   -- exactly one paid visit (insufficient / evidence_source 'none' guard n/a: has a visit but 0 intervals)
  v_c_none uuid;     -- zero paid visits
  v_base timestamptz := (now() at time zone 'Asia/Singapore')::date - 1;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'v651-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'V651 fixture',
    'v651-'||substr(v_business::text,1,8),'facial',true,
    array['dashboard','clients','sales','till','appointments','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','V651 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  select id into v_branch from public.branches where business_id = v_business limit 1;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='v651 rollback validation fixture',updated_at=clock_timestamp()
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

  -- The lifecycle policy trigger on public.businesses already inserted the v107 default
  -- (fallback 90d, min 3 observations, multiplier 2.0) — used as-is, not overridden, so this
  -- suite also proves the ordinary migration default is what customer_cadence_v1 reads.

  insert into public.clients(business_id, full_name, phone) values (v_business,'Rhythm','82230001') returning id into v_c_rhythm;
  insert into public.clients(business_id, full_name, phone) values (v_business,'Single Visit','82230002') returning id into v_c_single;
  insert into public.clients(business_id, full_name, phone) values (v_business,'No Visit','82230003') returning id into v_c_none;

  -- Five visits, exactly 10 days apart: four intervals, all equal to 10 -> median 10 exactly,
  -- clearing the default min-observations gate (3) with room to spare.
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
  values
    (v_business, v_c_rhythm, 'service', 5000, true, false, v_base - interval '40 days'),
    (v_business, v_c_rhythm, 'service', 5000, true, false, v_base - interval '30 days'),
    (v_business, v_c_rhythm, 'service', 5000, true, false, v_base - interval '20 days'),
    (v_business, v_c_rhythm, 'service', 5000, true, false, v_base - interval '10 days'),
    (v_business, v_c_rhythm, 'service', 5000, true, false, v_base);

  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
  values (v_business, v_c_single, 'service', 5000, true, false, v_base - interval '5 days');

  perform set_config('v651.owner', v_owner::text, true);
  perform set_config('v651.business', v_business::text, true);
  perform set_config('v651.branch', v_branch::text, true);
  perform set_config('v651.c_rhythm', v_c_rhythm::text, true);
  perform set_config('v651.c_single', v_c_single::text, true);
  perform set_config('v651.c_none', v_c_none::text, true);
end
$fixture$;

-- ---------------------------------------------------------------------------
-- A. app.customer_cadence_batch_v1 — exact interval_observations and median for the
--    known-rhythm fixture (self-contained equivalence check).
-- ---------------------------------------------------------------------------
do $a$
declare
  v_business uuid := current_setting('v651.business')::uuid;
  v_c_rhythm uuid := current_setting('v651.c_rhythm')::uuid;
  v_row record;
  v_before date := (now() at time zone 'Asia/Singapore')::date + 1;
begin
  select * into v_row
    from app.customer_cadence_batch_v1(v_business, v_before, v_before, now(), null, true) b
   where b.client_id = v_c_rhythm;
  if not found then
    raise exception 'A1: rhythm client produced no batch row at all';
  end if;
  if v_row.interval_observations <> 4 then
    raise exception 'A2: expected 4 interval observations, got %', v_row.interval_observations;
  end if;
  if v_row.median_interval_days <> 10 then
    raise exception 'A3: expected median 10 days, got %', v_row.median_interval_days;
  end if;
  if v_row.paid_visits <> 5 then
    raise exception 'A4: expected 5 paid visits, got %', v_row.paid_visits;
  end if;
  raise notice 'A OK: canonical batch computation matches the known fixture (4 observations, median 10 days)';
end
$a$;

-- ---------------------------------------------------------------------------
-- B. app.customer_cadence_v1 — per-customer vocabulary and evidence source.
-- ---------------------------------------------------------------------------
do $b$
declare
  v_business uuid := current_setting('v651.business')::uuid;
  v_c_rhythm uuid := current_setting('v651.c_rhythm')::uuid;
  v_c_single uuid := current_setting('v651.c_single')::uuid;
  v_c_none uuid := current_setting('v651.c_none')::uuid;
  v_res jsonb;
begin
  -- B1: a customer on their own established rhythm answers with a named source, a valid
  -- deviation state, and — because the source is customer_median_interval — an expected-next
  -- window that is never null.
  v_res := app.customer_cadence_v1(v_business, v_c_rhythm);
  if v_res->>'status' <> 'ready' then
    raise exception 'B1: expected ready status: %', v_res;
  end if;
  if v_res->>'evidence_source' <> 'customer_median_interval' then
    raise exception 'B2: expected the personal rhythm to clear the gate: %', v_res;
  end if;
  if v_res->>'deviation_state' not in ('within_cycle','due','late','overdue') then
    raise exception 'B3: unexpected deviation state: %', v_res;
  end if;
  if v_res->'expected_next_from' = 'null'::jsonb or v_res->'expected_next_to' = 'null'::jsonb then
    raise exception 'B4: a customer_median_interval answer must carry an expected-next window: %', v_res;
  end if;
  if (v_res->>'median_interval_days')::numeric <> 10 then
    raise exception 'B5: expected median 10 in the per-customer answer too: %', v_res;
  end if;

  -- B6: a customer with only one paid visit has zero measured intervals, so they fall back to
  -- the business policy — evidence_source business_fallback, no expected-next window.
  v_res := app.customer_cadence_v1(v_business, v_c_single);
  if v_res->>'status' <> 'ready' then
    raise exception 'B6: expected ready status for the single-visit customer: %', v_res;
  end if;
  if v_res->>'evidence_source' <> 'business_fallback' then
    raise exception 'B7: a single visit has no interval to measure, must fall back: %', v_res;
  end if;
  if v_res->'expected_next_from' <> 'null'::jsonb or v_res->'expected_next_to' <> 'null'::jsonb then
    raise exception 'B8: business_fallback must never claim a personal window: %', v_res;
  end if;
  if v_res->>'deviation_state' not in ('within_cycle','due','late','overdue') then
    raise exception 'B9: unexpected deviation state on fallback: %', v_res;
  end if;

  -- B10: a customer with no paid visit at all is insufficient, evidence_source 'none'.
  v_res := app.customer_cadence_v1(v_business, v_c_none);
  if v_res->>'status' <> 'insufficient' then
    raise exception 'B10: a visit-free customer must be insufficient: %', v_res;
  end if;
  if v_res->>'evidence_source' <> 'none' then
    raise exception 'B11: a visit-free customer must be evidence_source none: %', v_res;
  end if;

  raise notice 'B OK: per-customer cadence vocabulary (customer_median_interval / business_fallback / none, deviation states, expected-next window discipline)';
end
$b$;

reset role;
select 'V651_SUITE_PASSED' as verdict;

rollback;
