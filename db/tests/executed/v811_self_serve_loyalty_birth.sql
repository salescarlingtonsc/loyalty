-- EXECUTED acceptance fixture for nestly_v811
-- (db/migrations/20261007_nestly_v811_self_serve_loyalty_birth.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v811 --migrated-only
--
-- WHY THIS EXISTS. Observed live 2026-10-07 by the tenant divergence scan (D11, "stranded
-- birth"): three paying production firms — Cafe 111, Cafe 312 and cs cafe on, all born
-- 2026-09-05 through the self-serve checkout — have the loyalty module ON, an approved
-- workspace, a paid annual subscription, and NO public.loyalty_programs row, NO
-- firm_config_versions row and a NULL businesses.active_config_version_id. With no version 1
-- the firm cannot open Grow at all (create_loyalty_config_draft raises 'base configuration not
-- found'), and every versioned reader resolves to nothing.
--
-- THE CLASS. nestly_v565 ruled that app.ensure_loyalty_program_row is the ONE birth of that row —
-- idempotent, definer, UNGATED — precisely because two paths "inserted it only if
-- app.c45_owner_loyalty_write said yes and SILENTLY SKIPPED it otherwise". nestly_v763 built the
-- self-serve activation path afterwards and re-introduced exactly that guarded private insert. It
-- was the last path in the estate that could decline to seed and say nothing. The guard resolves
-- through app.business_operational_v620 — workspace approved AND the billing lifecycle not
-- paused — which is runtime state being written by the same transaction and its sibling billing
-- triggers, so the answer is a race and the losing branch is silent.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   V0  NON-VACUITY: in the fixture's state the module authority really does say NO —
--       app.c45_owner_loyalty_write is false for the firm's own owner. Without this, V1 would
--       pass for the wrong reason.
--   V1  The real trigger path still activates the tenant (nothing about v766 is broken).
--   V2  THE FIX: that tenant is born WITH its loyalty_programs row, carrying the v565 preset and
--       recommendation_source 'self_service_onboarding_preset'. This is the assertion that fails
--       before nestly_v811 — the guarded insert skips here.
--   V3  The seed trigger completed the birth: firm_config_versions version 1, status published,
--       source 'self_service_onboarding_preset', and businesses.active_config_version_id claimed.
--   V4  D11 ITSELF: the scan's exact stranded-birth predicate returns no row for this tenant.
--   V5  IDEMPOTENT: replaying the birth leaves exactly one loyalty row and one version 1 — the
--       backfill in the migration can be re-run without doubling anything.
--   V6  THE REFUSAL IS NOT WEAKENED (the D20 half of this change): an OWNER of a firm with the
--       customerintel module OFF is still refused 42501 by public.get_customer_intelligence_v83,
--       and the authority that refuses them is app.ci_access_gate_v667, which asks app.can_module
--       and raises 42501 — the exact shape the refined D20 rule follows one call deep.
--   V7  POSITIVE CONTROL for V6: with the module ON, the same owner is not refused by the module
--       authority. (Any other outcome is tolerated; only a 42501 module refusal fails.)
--
-- Every assertion is recorded as a row; the final gate makes any FAIL fatal. Rolled back.
begin;

create temp table v811_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v811_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v811_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;
grant execute on function pg_temp.v811_note(integer,text,boolean,text) to authenticated;

create or replace function pg_temp.v811_as_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.v811_as_system() to authenticated;

create or replace function pg_temp.v811_as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated','aud','authenticated')::text, true);
end
$$;
grant execute on function pg_temp.v811_as_user(uuid) to authenticated;

do $v811_test$
declare
  v_now timestamptz := date_trunc('second', now());
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_catalog uuid;
  v_bundle uuid;
  v_sector text;
  v_capacity integer := 10000;
  v_amount integer;

  v_biz uuid;
  v_owner uuid := gen_random_uuid();
  v_staff uuid;
  v_branch uuid;

  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_lp public.loyalty_programs%rowtype;
  v_fcv public.firm_config_versions%rowtype;
  v_active_cfg uuid;
  v_guard boolean;
  v_count integer;
  v_d11 integer;

  -- V6/V7
  v_ci_off uuid;
  v_ci_on uuid;
  v_ci_owner_off uuid := gen_random_uuid();
  v_ci_owner_on uuid := gen_random_uuid();
  v_refused boolean;
  v_sqlstate text;
  v_gate_def text;
begin
  perform pg_temp.v811_as_system();

  -- =========================================================================================
  -- FIXTURE · one self-serve tenant, built exactly the way nestly_v766's corpus builds one, so
  -- the REAL writer runs: the paid-invoice mirror fires billing_first_paid_evidence_v144, which
  -- fires app.activate_self_serve_paid_v130, which calls app.self_serve_activation_apply_v763.
  -- =========================================================================================
  v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  if v_tier.capacity_ceiling is null then
    insert into public.billing_capacity_tier_catalog_v664(
      currency,cadence,cadence_months,provider,capacity_ceiling,amount_cents,
      provider_base_price_id,tax_behavior,sales_assisted_above,active,effective_from
    ) values ('SGD','annual',12,'razorpay',v_capacity,118800,'plan_v811tier',
      'exclusive',false,true,v_now - interval '30 days');
    v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  end if;
  if v_tier.provider_base_price_id is null then
    update public.billing_capacity_tier_catalog_v664
       set provider_base_price_id='plan_v811tier'
     where currency=v_tier.currency and cadence=v_tier.cadence
       and capacity_ceiling=v_tier.capacity_ceiling
       and effective_from=v_tier.effective_from;
    v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  end if;
  if v_tier.provider_base_price_id is null or v_tier.amount_cents is null then
    raise exception 'v811 fixture: could not stand up an annual tier for % customers', v_capacity;
  end if;
  v_amount := v_tier.amount_cents;

  select id, sector_key into v_bundle, v_sector
    from public.sector_bundle_versions
   where status = 'published' and 'loyalty' = any(modules)
   order by created_at limit 1;
  if v_bundle is null then
    raise exception 'v811 fixture: no published Loyalty-capable sector bundle in the harness schema';
  end if;

  insert into public.billing_plan_catalog_v124(
    currency, cadence, cadence_months, provider, provider_base_price_id,
    provider_capacity_price_id, base_amount_cents, included_customer_capacity,
    capacity_block_size, capacity_block_amount_cents, compare_at_monthly_cents,
    tax_behavior, active, effective_from
  ) values (
    'SGD','annual',12,'razorpay',null,null,118800,1000,1000,12000,16800,
    'exclusive',true, v_now - interval '30 days'
  ) returning id into v_catalog;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V811 stranded birth','v811-'||substr(gen_random_uuid()::text,1,8),'test',
          array['dashboard','loyalty'])
  returning id into v_biz;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'zz-v811-'||substr(v_owner::text,1,8)||'@example.test','',v_now,v_now,v_now);

  insert into public.staff(business_id,user_id,role,active)
  values (v_biz,v_owner,'owner',true) returning id into v_staff;

  select id into v_branch from public.branches where business_id=v_biz order by created_at limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name,is_default,active)
    values (v_biz,'V811 main',true,true) returning id into v_branch;
  end if;

  insert into public.business_workspace_controls_v94(business_id,approval_status)
  values (v_biz,'pending')
  on conflict (business_id) do update set approval_status='pending', decided_at=null,
    decided_by=null, decision_reason=null;

  -- THE STATE THAT MAKES THE GUARD SAY NO, pinned deterministically.
  --
  -- app.c45_owner_loyalty_write asks app.can_module_write -> app.staff_module_mode_v94, which
  -- resolves through app.effective_platform_module_mode_v94 (a platform override) AND through
  -- app.business_operational_v620 (the workspace approved AND the billing lifecycle not paused).
  -- In production it was the SECOND of those that lost the race: both halves are runtime state
  -- being written by this very transaction and its sibling billing triggers. That is not a state
  -- a fixture can pin, because the same billing evidence that fires the activation also moves the
  -- lifecycle. So this pins the FIRST half instead — a platform override holding 'loyalty' at
  -- 'disabled' while the firm is being born — which drives the identical guard to the identical
  -- answer (false) through a route no billing trigger can undo mid-test. What is being proven is
  -- not which input said no; it is that a NO of any kind no longer costs the tenant its birth.
  insert into public.platform_module_overrides_v94(business_id, module_key, mode, reason)
  values (v_biz, 'loyalty', 'disabled', 'v811 fixture: pin the module authority to NO');

  insert into public.self_serve_business_onboarding_v130(
    business_id, owner_user_id, owner_staff_id, default_branch_id, bundle_version_id,
    setup_idempotency_key, request_hash, owner_name, owner_email, business_name, business_slug,
    sector_key, selected_cadence, selected_customer_capacity, billing_catalog_id_v124,
    legal_accepted_at, status
  ) values (
    v_biz, v_owner, v_staff, v_branch, v_bundle,
    gen_random_uuid(), repeat('8',64), 'V811 Owner', 'zz-v811@example.test',
    'V811 stranded birth', (select slug from public.businesses where id=v_biz),
    v_sector, 'annual', v_capacity, v_catalog, v_now - interval '1 hour', 'payment_pending'
  );

  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, pricing_model, cadence, customer_capacity,
    capacity_blocks, provider_base_price_id, provider_capacity_item_id,
    provider_capacity_price_id, provider_event_created_at, last_event_id
  ) values
    (v_biz,'sub_v811','v124_customer_capacity','annual',v_tier.capacity_ceiling,
     v_tier.capacity_ceiling/1000, v_tier.provider_base_price_id, null, null, v_now,'evt_v811');

  -- =========================================================================================
  -- V0 — NON-VACUITY. The module authority says NO for this firm's own owner right now.
  -- =========================================================================================
  -- The claims, not the role: app.c45_owner_loyalty_write reads auth.uid() and is EXECUTE-able by
  -- postgres only ({postgres=X/postgres} on production) — it is asked BY the definer functions,
  -- never by a session. Impersonating the owner's identity without switching role is exactly the
  -- context app.self_serve_activation_apply_v763 asks it in.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text, true);
  v_guard := app.c45_owner_loyalty_write(v_biz);
  perform pg_temp.v811_as_system();
  perform pg_temp.v811_note(0, 'V0 the module authority refuses the owner (non-vacuity)',
    v_guard is false, 'c45_owner_loyalty_write='||coalesce(v_guard::text,'<null>'));

  -- =========================================================================================
  -- THE WRITER RUNS. Mirroring the paid invoice is what fires the real activation path.
  -- =========================================================================================
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id
  ) values
    (v_biz,'cust_v811','sub_v811','inv_v811','SGD','paid',
     true,v_amount,0,v_amount,v_amount,v_amount,0,v_now,v_now+interval '365 days',v_now,false,
     v_now,10,'evt_v811');

  -- =========================================================================================
  -- V1 — the activation itself still works.
  -- =========================================================================================
  select * into v_onboarding from public.self_serve_business_onboarding_v130 where business_id=v_biz;
  perform pg_temp.v811_note(1, 'V1 the self-serve tenant activates',
    v_onboarding.status = 'active' and v_onboarding.activation_invoice_id = 'inv_v811',
    'status='||coalesce(v_onboarding.status,'<null>'));

  -- =========================================================================================
  -- V2 — THE FIX. Born with the loyalty row, guard or no guard. FAILS BEFORE nestly_v811.
  -- =========================================================================================
  select * into v_lp from public.loyalty_programs where business_id=v_biz;
  perform pg_temp.v811_note(2, 'V2 the tenant is born with its loyalty_programs row',
    v_lp.id is not null
      and v_lp.kind = 'points'
      and v_lp.earn_points_per_dollar = 1
      and v_lp.redeem_points = 800
      and v_lp.reward_credit_cents = 2000
      and v_lp.active is false
      and v_lp.loyalty_model = 'classic'
      and v_lp.recommendation_source = 'self_service_onboarding_preset',
    case when v_lp.id is null then 'no loyalty_programs row (the stranded birth)'
         else 'kind='||v_lp.kind||' earn='||v_lp.earn_points_per_dollar
              ||' redeem='||v_lp.redeem_points||' credit='||v_lp.reward_credit_cents
              ||' source='||coalesce(v_lp.recommendation_source,'<null>') end);

  -- =========================================================================================
  -- V3 — the seed trigger completed the birth (version 1 published, pointer claimed).
  -- =========================================================================================
  select * into v_fcv from public.firm_config_versions
   where business_id=v_biz and version_no=1;
  select active_config_version_id into v_active_cfg from public.businesses where id=v_biz;
  perform pg_temp.v811_note(3, 'V3 version 1 is published and the pointer is claimed',
    v_fcv.id is not null and v_fcv.status = 'published'
      and v_fcv.source = 'self_service_onboarding_preset'
      and v_active_cfg = v_fcv.id,
    'version1='||coalesce(v_fcv.id::text,'<none>')||' status='||coalesce(v_fcv.status,'<null>')
      ||' pointer='||coalesce(v_active_cfg::text,'<null>'));

  -- =========================================================================================
  -- V4 — D11 itself, evaluated exactly as db/tests/tenant_divergence_scan.sql evaluates it.
  -- =========================================================================================
  select count(*) into v_d11
    from public.businesses b
    left join public.loyalty_programs lp on lp.business_id = b.id
   where b.id = v_biz
     and (('loyalty' = any(b.enabled_modules) and lp.id is null)
          or b.active_config_version_id is null);
  perform pg_temp.v811_note(4, 'V4 the D11 stranded-birth predicate reports nothing',
    v_d11 = 0, 'D11 rows='||v_d11);

  -- =========================================================================================
  -- V5 — replaying the birth is a no-op (the migration''s backfill is re-runnable).
  -- =========================================================================================
  perform app.ensure_loyalty_program_row(v_biz, 'self_service_onboarding_preset');
  select count(*) into v_count from public.loyalty_programs where business_id=v_biz;
  select count(*) into v_d11 from public.firm_config_versions
   where business_id=v_biz and version_no=1;
  perform pg_temp.v811_note(5, 'V5 the birth is idempotent',
    v_count = 1 and v_d11 = 1, 'loyalty rows='||v_count||' version-1 rows='||v_d11);

  -- =========================================================================================
  -- V6 / V7 — the D20 half. The refined rule follows the authority ONE call deep because
  -- nestly_v721 moved it into app.ci_access_gate_v667. Prove the refusal it stands for is real.
  -- =========================================================================================
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V811 CI off','v811-cioff-'||substr(gen_random_uuid()::text,1,8),'test',
          array['dashboard','reports'])
  returning id into v_ci_off;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V811 CI on','v811-cion-'||substr(gen_random_uuid()::text,1,8),'test',
          array['dashboard','reports','customerintel'])
  returning id into v_ci_on;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_ci_owner_off,'authenticated','authenticated',
     'zz-v811-cioff-'||substr(v_ci_owner_off::text,1,8)||'@example.test','',v_now,v_now,v_now),
    ('00000000-0000-0000-0000-000000000000',v_ci_owner_on,'authenticated','authenticated',
     'zz-v811-cion-'||substr(v_ci_owner_on::text,1,8)||'@example.test','',v_now,v_now,v_now);

  insert into public.staff(business_id,user_id,role,active)
  values (v_ci_off,v_ci_owner_off,'owner',true),(v_ci_on,v_ci_owner_on,'owner',true);

  insert into public.business_workspace_controls_v94(
    business_id,approval_status,decided_at,decision_reason)
  values (v_ci_off,'approved',v_now,'v811 fixture'),(v_ci_on,'approved',v_now,'v811 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=v_now,
    decision_reason='v811 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_ci_off,false),(v_ci_on,false)
  on conflict (business_id) do update set workspace_paused=false;

  -- The gate this reader delegates to must be the one the refined D20 rule recognises: in `app`,
  -- asking app.can_module, and RAISING 42501. Structural, and deliberately the same predicate.
  v_gate_def := pg_get_functiondef('app.ci_access_gate_v667(uuid,uuid)'::regprocedure);
  perform pg_temp.v811_note(6,
    'V6a the CI reader delegates to a refusing gate that asks the module authority',
    position('ci_access_gate_v667' in pg_get_functiondef(
      'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'::regprocedure)) > 0
    and position('can_module' in v_gate_def) > 0
    and position('42501' in v_gate_def) > 0,
    'v83 -> app.ci_access_gate_v667 -> can_module + 42501');

  v_refused := false; v_sqlstate := null;
  perform pg_temp.v811_as_user(v_ci_owner_off);
  begin
    perform public.get_customer_intelligence_v83(
      v_ci_off, null, (v_now - interval '30 days')::date, v_now::date, 10, null, null, null);
  exception when others then
    v_sqlstate := sqlstate;
    v_refused := (sqlstate = '42501');
  end;
  perform pg_temp.v811_as_system();
  perform pg_temp.v811_note(7,
    'V6b an owner whose firm has customerintel OFF is still refused 42501',
    v_refused, 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  v_sqlstate := null;
  perform pg_temp.v811_as_user(v_ci_owner_on);
  begin
    perform public.get_customer_intelligence_v83(
      v_ci_on, null, (v_now - interval '30 days')::date, v_now::date, 10, null, null, null);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v811_as_system();
  perform pg_temp.v811_note(8,
    'V7 positive control: with the module ON the same owner is not refused by the authority',
    coalesce(v_sqlstate,'') <> '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));
end
$v811_test$;

select seq, step, outcome, detail from v811_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v811_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v811 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
