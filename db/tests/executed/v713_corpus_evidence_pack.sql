-- EXECUTED acceptance fixture for nestly_v713 — the AI firm-report evidence pack finally carries
-- an evidence_class-bearing object, and it does so through the REAL production caller shape:
-- sessionless (no request.jwt.claims), through app.v176_evidence_pack, the same function
-- public.internal_claim_ai_firm_report_v176 calls for every scheduled/queued report.
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Proves:
--   F1 — SESSIONLESS access: with no auth session at all (auth.uid() is null throughout — no
--        super admin, no Google SSO claim, exactly what supabase/functions/ai-firm-reports/
--        index.ts's service-role worker looks like), app.v176_evidence_pack(...) still returns a
--        ci_opportunities section that is AVAILABLE (not in unavailable_sections) — proving the
--        v713 fix to app.ci_access_gate_v667 (the internal-drain arm) actually reaches the real
--        call site, not just the migration's own narrower smoke test.
--   F2 — POPULATION: findings.ranked contains one ASSOCIATION candidate (gateway_followthrough)
--        and at least two DIRECT_FACT candidates (contactability_gap, data_quality_coverage) —
--        both typed classes present from a single business, which is exactly what
--        validate.mjs's typedFindings needs to have anything to walk.
--   F3 — NEVER CAUSAL: no ranked candidate's evidence_class is 'CAUSAL', and the literal string
--        'CAUSAL' does not appear anywhere in the pack's text at all (same standard v696's B1).
--   F4 — findings.ranked/top_actions/abstentions are always arrays (never null), findings.
--        source_rpc names the spine, and evidence_completeness.findings_version = 'v713'.
--   F5 — ISOLATION (mutation -> red, in the same fail-alone shape v552's G2 already established
--        for the four sections beside this one): stubbing public.get_ci_opportunities_v1 to raise
--        loses ONLY the ci_opportunities section — findings.ranked collapses to '[]' and
--        unavailable_sections names it with a sqlstate (never sqlerrm) — while an independent
--        healthy section (consultant_brief) survives. Proves this fixture is not vacuously green:
--        break the wiring and F1/F2 above would fail, which is exactly what F5 demonstrates by
--        breaking it on purpose, inside this same rolled-back transaction.
--   F6 — GATE, directly: app.ci_access_gate_v667 admits the sessionless internal drain when (and
--        only when) it is open, proving the v713 gate fix in isolation from the rest of the pack.
--
-- =================================================================================================
-- SEEDING — reused from db/tests/executed/v696_corpus_spine_verdicts.sql's BIZ1 (itself reused
-- from v688), which documents the full derivation. Trimmed further than v696 already trimmed it:
-- PLAN_BIG/package_leakage and the H1 rhythm are dropped entirely — this fixture has no need of a
-- package-leakage DIRECT_FACT (contactability_gap and data_quality_coverage already give it two),
-- and return_probability_v681 (H1's only purpose there) is not read by anything this fixture
-- asserts. What is kept, byte-identical to v696: the business/branch/operational-recipe
-- scaffolding (workspace approval, subscription lifecycle, subscription, reporting contract
-- version — without every one of these, every gate refuses for a billing reason and the fixture
-- would pass vacuously), and the F1..F20 gateway-service funnel population (first visit d1, ALL
-- 20 return d1+10 = 100% firm baseline, 18/20 return d1+20) which is what makes
-- gateway_followthrough:svc_gw fire as ASSOCIATION — its own window-scoped (p_from=p_to=d1)
-- repeat rate is 0% against that 100% baseline. Zero consents recorded -> contactability_gap.
-- svc_gw never mapped to a taxonomy node -> data_quality_coverage. Both DIRECT_FACT, for free,
-- exactly as in v696 (no extra rows needed).
--
-- THE ONE DELIBERATE DIFFERENCE FROM v696/v688/v705: no request.jwt.claims is EVER set in this
-- fixture. Those fixtures call public.get_ci_opportunities_v1 directly as an authenticated
-- Google-SSO super admin to prove the SPINE's own contract. This fixture never calls that RPC
-- directly at all — it goes through app.v176_evidence_pack exactly as the sessionless production
-- drain does, which is the one shape this whole migration is about proving actually works.
--
-- =================================================================================================
-- LANDMINES HANDLED (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md; not re-discovered here)
-- =================================================================================================
--  * created_at pinned to occurred_at on every backdated row.
--  * counts_as_revenue / counts_as_visit are NEVER passed on insert.
--  * the operational recipe (workspace controls + subscription lifecycle + subscriptions +
--    reporting_contract_versions_v106 backdated) is required, or every gate refuses for a billing
--    reason and the whole fixture passes vacuously.
--  * a fresh business gets a customer_lifecycle_policies_v107 row automatically (trigger-seeded).
--  * public.benefit_registry has an immutability guard that refuses DELETE — this whole fixture
--    lives inside one transaction that is ROLLED BACK at the end, never a DELETE.
--  * app.v676_internal_drain_active() is transaction-local; F5/F6's temporary stub and the
--    isolation check must run BEFORE the rollback, in the same transaction the drain flag lives in.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v713$
declare
  biz      uuid := '00000000-0000-4000-8000-000000713001';
  br       uuid := '00000000-0000-4000-8000-000000713011';
  u_owner  uuid := '00000000-0000-4000-8000-000000713ee1';
  svc_gw   uuid := '00000000-0000-4000-8000-0000007130a1';

  d1       date := current_date - 200;

  pack     jsonb;
  cand     jsonb;
  row_c    jsonb;
  v_sections text;
begin
  ---------------------------------------------------------------------------
  -- operational recipe (reused verbatim from v696)
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v713-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v713 biz', 'zz-v713-biz',
     array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v713 biz main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v713 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v713 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v713 gateway service', 1000, 30);

  ---------------------------------------------------------------------------
  -- clients F1..F20
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000713' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v713 funnel ' || s from generate_series(1,20) s;

  ---------------------------------------------------------------------------
  -- FUNNEL: F1..F20 first visit at d1, ALL return at d1+10, 18 of 20 return at d1+20.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000713' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000713' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000713' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000713' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000713' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000713' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000713' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000713' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;   -- only 18 of 20
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000713' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,18) s;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS
  ---------------------------------------------------------------------------
  if (select coalesce(bool_and(s.counts_as_revenue) and bool_and(s.counts_as_visit), false)
        from public.sales s where s.business_id = biz and s.kind = 'service') is not true then
    insert into _fail values ('PRE-policy', 'a service sale did not resolve counts_as_revenue/visit true');
  end if;
  if current_setting('request.jwt.claims', true) is not null
     and current_setting('request.jwt.claims', true) <> '' then
    insert into _fail values ('PRE-session', 'a JWT claim is set — this fixture must run sessionless');
  end if;

  ---------------------------------------------------------------------------
  -- F0 — NESTLY v720: sessionless WITHOUT the drain open must now be refused. Before v720,
  -- app.v176_evidence_pack had no gate of its own and this call would have succeeded; this
  -- fixture used to rely on exactly that. Assert the refusal first, so a future regression that
  -- silently widens the gate back to "auth.uid() is null is enough" is caught here rather than
  -- only by the more elaborate access-boundary battery in v720_corpus_evidence_pack_grants.sql.
  ---------------------------------------------------------------------------
  begin
    perform app.v176_evidence_pack(biz, 'monthly', d1, d1);
    insert into _fail values ('F0-drain-required',
      'a sessionless call with the internal drain CLOSED still got a pack — nestly_v720''s gate is not being enforced');
  exception
    when sqlstate '42501' then null; -- expected
    when others then
      insert into _fail values ('F0-drain-required', format('refused with %s, expected 42501', sqlerrm));
  end;

  ---------------------------------------------------------------------------
  -- F1/F2/F3/F4 — THE CALL, sessionless, through the real production entry point.
  --
  -- NESTLY v720: app.v176_evidence_pack now gates on app.v676_internal_drain_active() for a
  -- sessionless caller (belt-and-braces alongside its owner-only ACL). The real production
  -- caller, public.internal_claim_ai_firm_report_v176, opens this window itself around its own
  -- call (see db/migrations/20260902_nestly_v720_evidence_pack_grants.sql step 2b) — this
  -- fixture calls app.v176_evidence_pack directly, one layer inside that worker, so it opens
  -- the SAME window the worker would, exactly as F6 below already does for app.ci_access_
  -- gate_v667.
  ---------------------------------------------------------------------------
  perform app.v676_open_internal_drain();
  pack := app.v176_evidence_pack(biz, 'monthly', d1, d1);
  perform app.v676_close_internal_drain();

  -- F1 — the ci_opportunities section is AVAILABLE, not withheld for an access reason.
  if exists (select 1 from jsonb_array_elements(pack->'evidence_completeness'->'unavailable_sections') u
              where u->>'section' = 'ci_opportunities') then
    insert into _fail values ('F1-available', format(
      'ci_opportunities was withheld even though the internal drain should have admitted it: %s',
      pack->'evidence_completeness'->'unavailable_sections'));
  end if;

  -- F2 — population: the two typed classes are both actually present.
  if not exists (select 1 from jsonb_array_elements(pack->'findings'->'ranked') c
                  where c->>'id' = 'gateway_followthrough:' || svc_gw::text
                    and c->>'evidence_class' = 'ASSOCIATION') then
    insert into _fail values ('F2-association', format(
      'gateway_followthrough:svc_gw (ASSOCIATION) was not found in findings.ranked: %s',
      pack->'findings'->'ranked'));
  end if;
  if not exists (select 1 from jsonb_array_elements(pack->'findings'->'ranked') c
                  where c->>'id' = 'contactability_gap' and c->>'evidence_class' = 'DIRECT_FACT') then
    insert into _fail values ('F2-direct-fact-1', 'contactability_gap (DIRECT_FACT) was not found in findings.ranked');
  end if;
  if not exists (select 1 from jsonb_array_elements(pack->'findings'->'ranked') c
                  where c->>'id' = 'data_quality_coverage' and c->>'evidence_class' = 'DIRECT_FACT') then
    insert into _fail values ('F2-direct-fact-2', 'data_quality_coverage (DIRECT_FACT) was not found in findings.ranked');
  end if;

  -- F3 — never CAUSAL, structurally and textually.
  for row_c in select c from jsonb_array_elements(pack->'findings'->'ranked') c loop
    if row_c->>'evidence_class' = 'CAUSAL' then
      insert into _fail values ('F3-causal', format('candidate %s claims CAUSAL', row_c->>'id'));
    end if;
    if row_c ? 'evidence_class' and row_c->>'evidence_class' not in ('DIRECT_FACT','ASSOCIATION') then
      insert into _fail values ('F3-class', format('candidate %s has evidence_class %s',
        row_c->>'id', row_c->>'evidence_class'));
    end if;
  end loop;
  if pack::text ~ 'CAUSAL' then
    insert into _fail values ('F3-text', 'the literal string CAUSAL appears in the pack text');
  end if;

  -- F4 — shape invariants.
  if jsonb_typeof(pack->'findings'->'ranked') is distinct from 'array'
     or jsonb_typeof(pack->'findings'->'top_actions') is distinct from 'array'
     or jsonb_typeof(pack->'findings'->'abstentions') is distinct from 'array' then
    insert into _fail values ('F4-shape', format('findings arrays are not all arrays: %s', pack->'findings'));
  end if;
  if (pack->'findings'->>'source_rpc') is distinct from 'public.get_ci_opportunities_v1' then
    insert into _fail values ('F4-source', format('source_rpc was %s', pack->'findings'->>'source_rpc'));
  end if;
  -- nestly_v738 bumped findings_version to 'v738' when it added report_sections/verdict_policy
  -- to `findings` (additive only) — findings_version is, by nestly_v713's own header, the field
  -- designed to move on a future findings-shape change, unlike contract_version below, which does
  -- not. F4-shape/F4-source above still hold unchanged.
  if (pack->'evidence_completeness'->>'findings_version') is distinct from 'v738' then
    insert into _fail values ('F4-version', format('findings_version was %s',
      pack->'evidence_completeness'->>'findings_version'));
  end if;
  -- existing keys, unchanged shape (v552/v179 contract) — this fixture must stay compatible with
  -- v552_gated_evidence_isolation.sql's own reads of the same pack.
  if pack->>'contract_version' is distinct from 'v176' then
    insert into _fail values ('F4-contract', format('contract_version moved: %s', pack->>'contract_version'));
  end if;
  if pack->'evidence_completeness'->>'insights_version' is distinct from 'v179' then
    insert into _fail values ('F4-insights-version', 'insights_version was disturbed');
  end if;
  if jsonb_typeof(pack->'account_opens'->'report_range') is distinct from 'object' then
    insert into _fail values ('F4-account-opens', 'account_opens.report_range regressed');
  end if;

  ---------------------------------------------------------------------------
  -- F5 — ISOLATION / mutation -> red. Stub the spine to fail; only ci_opportunities is lost.
  ---------------------------------------------------------------------------
  create or replace function public.get_ci_opportunities_v1(
    p_business uuid, p_from date, p_to date, p_branch uuid default null,
    p_as_of timestamptz default clock_timestamp(), p_extended boolean default false)
  returns jsonb language plpgsql as $stub$
  begin
    raise exception 'v713 fixture stub failure';
  end
  $stub$;

  perform app.v676_open_internal_drain();
  pack := app.v176_evidence_pack(biz, 'monthly', d1, d1);
  perform app.v676_close_internal_drain();

  if not exists (select 1 from jsonb_array_elements(pack->'evidence_completeness'->'unavailable_sections') u
                  where u->>'section' = 'ci_opportunities' and coalesce(u->>'sqlstate','') <> '') then
    insert into _fail values ('F5-isolation', format(
      'stubbing get_ci_opportunities_v1 did not name ci_opportunities with a sqlstate: %s',
      pack->'evidence_completeness'->'unavailable_sections'));
  end if;
  if jsonb_typeof(pack->'findings'->'ranked') is distinct from 'array'
     or jsonb_array_length(pack->'findings'->'ranked') <> 0 then
    insert into _fail values ('F5-collapse', format(
      'findings.ranked should collapse to [] when the section fails: %s', pack->'findings'->'ranked'));
  end if;
  if jsonb_typeof(pack->'consultant_brief') = 'null' then
    insert into _fail values ('F5-independent', 'an INDEPENDENT healthy section (consultant_brief) '
      'was lost when only ci_opportunities was stubbed to fail — isolation is broken');
  end if;
  if pack::text like '%v713 fixture stub failure%' then
    insert into _fail values ('F5-sqlerrm-leak', 'sqlerrm text leaked into the payload — only sqlstate may appear');
  end if;

  ---------------------------------------------------------------------------
  -- F6 — the access gate, directly: admits the drain when open, refuses when closed.
  ---------------------------------------------------------------------------
  perform app.v676_open_internal_drain();
  begin
    perform app.ci_access_gate_v667(biz);
  exception when others then
    insert into _fail values ('F6-open', format('ci_access_gate_v667 refused the open internal drain: %s', sqlerrm));
  end;
  perform app.v676_close_internal_drain();
  begin
    perform app.ci_access_gate_v667(biz);
    insert into _fail values ('F6-closed', 'ci_access_gate_v667 admitted a sessionless caller with the drain closed');
  exception when others then
    null; -- expected
  end;
end
$v713$;

select case when count(*)=0 then 'PASS — evidence pack carries typed findings, sessionless, isolated'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v713: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
