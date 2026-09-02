-- EXECUTED acceptance fixture for db/migrations/20260920_nestly_v738_pack_report_sections.sql:
-- app.v176_evidence_pack's `findings` object gains report_sections + verdict_policy, additive,
-- alongside the ranked/top_actions/abstentions nestly_v713/v735 already wired through.
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md):
--   LC_ALL=C node scripts/db-tests/run.mjs --filter=v738_corpus --migrated-only
--
-- ORACLE / SEED. app.seed_golden_business_v682 (db/migrations/20260902_nestly_v682_golden_
-- corpus.sql) provisions one fully-operational 'fnb' business — real sales, a default branch,
-- enabled_modules including 'customerintel', an owner staff row with view_finance — the same
-- oracle db/tests/executed/v731_reconciliation_report.sql and v682_golden_reconciliation.sql use,
-- reused here rather than a bespoke seed so this fixture's claims are proven against a business
-- shape another fixture has already independently reconciled, not one hand-picked to make the new
-- keys easy to find.
--
-- Proves:
--   H1 — SESSIONLESS, exactly as public.internal_claim_ai_firm_report_v176 calls it (no
--        request.jwt.claims ever set for the pack call, drain opened/closed around it):
--        findings.report_sections is present, is a jsonb OBJECT, and its key set is EXACTLY the
--        seven fixed keys (change/failures/leakage/margin/segments/strengths/
--        unnoticed_behaviour — nestly_v688's own literal jsonb_build_object order); every key
--        except margin holds a jsonb array (possibly empty); margin holds nestly_v688's own
--        unavailable object ({status:'unavailable', reason:'no COGS/cost-of-goods field on
--        services or sales in this schema'}). findings.verdict_policy is present, is an object,
--        and states causal_claims='never' over classes=['DIRECT_FACT','ASSOCIATION'] — the fixed,
--        business-independent policy nestly_v696 hardcodes. evidence_completeness.
--        findings_version = 'v738'.
--   H2 — ONLY ADDITIVE: findings.ranked, findings.top_actions and findings.abstentions from the
--        H1 pack are byte-identical (jsonb equality) to the SAME three keys read straight off a
--        direct, non-pack call to public.get_ci_opportunities_v1(..., p_extended=>true) — proving
--        this migration changed nothing about what nestly_v713/v735 already wired through, only
--        added the two new keys. The same direct call's report_sections/verdict_policy are also
--        checked jsonb-equal to the pack's — proving pass-through fidelity, not a re-derivation.
--   H3 — FALLBACK SHAPE, not merely "present when healthy": with public.get_ci_opportunities_v1
--        stubbed to raise (the identical isolation technique nestly_v713/v735's own fixtures
--        use), the ci_opportunities section becomes unavailable (named in
--        evidence_completeness.unavailable_sections with a sqlstate) and findings.ranked/
--        top_actions/abstentions collapse to '[]' exactly as nestly_v713/v735 already proved —
--        but findings.report_sections is STILL the full seven-key object (the coalesce fallback
--        this migration adds) and findings.verdict_policy is STILL the fixed policy object (the
--        other coalesce fallback), never null and never absent. Every OTHER section (sales,
--        insights, account_opens, consultant_brief) survives untouched, re-proving nestly_v552's
--        fail-alone discipline at this call site is undisturbed.
--
-- MUTATION-CHECKED (2026-09-02, this session, --filter=v738_corpus --migrated-only), two ways:
--   (1) The migration's `verdict_policy` key was deleted from v_new_findings (report_sections
--       left in place) and the migration's own APPLY-TIME verify block caught it before this
--       fixture ever ran: `ERROR: v738: findings has no verdict_policy key at all: {...}` — the
--       migration refused to apply with the regression present, exactly as its own H1-shaped
--       verification is designed to.
--   (2) The whole migration file was removed (simulating the pre-nestly_v738 tree — `findings`
--       still nestly_v713/v735's three-key shape) and this fixture was run unmodified against
--       that database: it failed with 14 assertions, including
--         H1-report-sections-missing: findings has no report_sections key at all: {...}
--         H1-verdict-policy: findings has no verdict_policy key at all: {...}
--         H1-findings-version: evidence_completeness.findings_version is missing or wrong:
--           {"findings_version": "v713", ...}
--       Restoring the migration file reproduced PASS in both cases. Together these prove neither
--       the migration's own verify block nor this fixture is vacuous: each genuinely detects the
--       regression nestly_v738 exists to fix.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v738$
declare
  v_owner uuid := '00000000-0000-4000-8000-000000738001';
  v_sa    uuid := '00000000-0000-4000-8000-000000738002';
  v_payload jsonb;
  v_biz   uuid;
  v_branch uuid;
  v_from  date;
  v_to    date;

  v_pack       jsonb;
  v_direct_ext jsonb;
  v_pack_stub  jsonb;
  v_sections   text[];
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v738-owner@example.test'),
    (v_sa,    'zz-v738-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v738-sa@example.test') on conflict do nothing;

  -----------------------------------------------------------------------------
  -- SEED. Owner session while the golden corpus is provisioned (v731's own pattern).
  -----------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  begin
    v_payload := app.seed_golden_business_v682(738001, 'fnb', v_owner);
  exception when others then
    insert into _fail values ('SEED', format('seed_golden_business_v682 raised %s', sqlerrm));
    return;
  end;

  v_biz    := (v_payload->>'business_id')::uuid;
  v_branch := (v_payload->>'branch_id')::uuid;
  v_from   := (v_payload->>'window_from')::date;
  v_to     := least((v_payload->>'window_to')::date, current_date - 1);

  if not app.has_perm(v_biz, 'view_finance') then
    insert into _fail values ('PRE', 'seeded owner lacks view_finance; every call below is vacuous');
    return;
  end if;

  -----------------------------------------------------------------------------
  -- H2 (captured first, healthy) -- direct extended call, owner session (has_perm(view_finance)
  -- + customerintel, ci_access_gate_v667's merchant arm), the same window app.v176_evidence_pack
  -- resolves internally (v_to_effective = least(p_to, today) = p_to here since p_to is already in
  -- the past).
  -----------------------------------------------------------------------------
  begin
    v_direct_ext := public.get_ci_opportunities_v1(v_biz, v_from, v_to, null, clock_timestamp(), true);
  exception when others then
    insert into _fail values ('H2-direct-call', format('get_ci_opportunities_v1 raised %s', sqlerrm));
    return;
  end;

  -----------------------------------------------------------------------------
  -- H1 -- through app.v176_evidence_pack, SESSIONLESS: no request.jwt.claims is ever set for this
  -- call, exactly the production shape public.internal_claim_ai_firm_report_v176 uses.
  -----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '', true);

  perform app.v676_open_internal_drain();
  begin
    v_pack := app.v176_evidence_pack(v_biz, 'monthly', v_from, v_to);
  exception when others then
    perform app.v676_close_internal_drain();
    insert into _fail values ('H1-pack-call', format('app.v176_evidence_pack raised %s', sqlerrm));
    return;
  end;
  perform app.v676_close_internal_drain();

  if not (v_pack->'findings' ? 'report_sections') then
    insert into _fail values ('H1-report-sections-missing', format(
      'findings has no report_sections key at all: %s', v_pack->'findings'));
  end if;
  if jsonb_typeof(v_pack->'findings'->'report_sections') is distinct from 'object' then
    insert into _fail values ('H1-report-sections-type', format(
      'findings.report_sections is not an object: %s', v_pack->'findings'->'report_sections'));
  end if;

  select array_agg(k order by k) into v_sections
    from jsonb_object_keys(v_pack->'findings'->'report_sections') k;
  if v_sections is distinct from array['change','failures','leakage','margin','segments',
                                        'strengths','unnoticed_behaviour'] then
    insert into _fail values ('H1-report-sections-keys', format(
      'findings.report_sections has the wrong key set: %s', v_sections));
  end if;

  if jsonb_typeof(v_pack->'findings'->'report_sections'->'margin') is distinct from 'object'
     or (v_pack->'findings'->'report_sections'->'margin'->>'status') is distinct from 'unavailable'
  then
    insert into _fail values ('H1-margin-shape', format(
      'findings.report_sections.margin is not the unavailable object: %s',
      v_pack->'findings'->'report_sections'->'margin'));
  end if;
  if jsonb_typeof(v_pack->'findings'->'report_sections'->'strengths') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'change') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'unnoticed_behaviour') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'leakage') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'segments') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'failures') is distinct from 'array'
  then
    insert into _fail values ('H1-report-sections-values', format(
      'findings.report_sections has a non-array/non-margin value: %s', v_pack->'findings'->'report_sections'));
  end if;

  if not (v_pack->'findings' ? 'verdict_policy') then
    insert into _fail values ('H1-verdict-policy', format(
      'findings has no verdict_policy key at all: %s', v_pack->'findings'));
  end if;
  if jsonb_typeof(v_pack->'findings'->'verdict_policy') is distinct from 'object'
     or (v_pack->'findings'->'verdict_policy'->>'causal_claims') is distinct from 'never'
     or (select array_agg(x order by x) from jsonb_array_elements_text(v_pack->'findings'->'verdict_policy'->'classes') x)
         is distinct from array['ASSOCIATION','DIRECT_FACT']
  then
    insert into _fail values ('H1-verdict-policy-shape', format(
      'findings.verdict_policy is missing or malformed: %s', v_pack->'findings'->'verdict_policy'));
  end if;

  if (v_pack->'evidence_completeness'->>'findings_version') is distinct from 'v738' then
    insert into _fail values ('H1-findings-version', format(
      'evidence_completeness.findings_version is missing or wrong: %s', v_pack->'evidence_completeness'));
  end if;

  -----------------------------------------------------------------------------
  -- H2 -- pass-through fidelity: the pack's four spine-derived keys equal the direct call's,
  -- proving nestly_v738 copies verbatim rather than re-deriving.
  -----------------------------------------------------------------------------
  if (v_pack->'findings'->'ranked') is distinct from (v_direct_ext->'ranked') then
    insert into _fail values ('H2-ranked-mismatch', 'findings.ranked != direct extended call ranked');
  end if;
  if (v_pack->'findings'->'top_actions') is distinct from (v_direct_ext->'top_actions') then
    insert into _fail values ('H2-top-actions-mismatch', 'findings.top_actions != direct extended call top_actions');
  end if;
  if (v_pack->'findings'->'abstentions') is distinct from (v_direct_ext->'abstentions') then
    insert into _fail values ('H2-abstentions-mismatch', 'findings.abstentions != direct extended call abstentions');
  end if;
  if (v_pack->'findings'->'report_sections') is distinct from (v_direct_ext->'report_sections') then
    insert into _fail values ('H2-report-sections-mismatch',
      'findings.report_sections != direct extended call report_sections');
  end if;
  if (v_pack->'findings'->'verdict_policy') is distinct from (v_direct_ext->'verdict_policy') then
    insert into _fail values ('H2-verdict-policy-mismatch',
      'findings.verdict_policy != direct extended call verdict_policy');
  end if;

  -----------------------------------------------------------------------------
  -- H3 -- ISOLATION + FALLBACK SHAPE: stub get_ci_opportunities_v1 to raise (nestly_v713/v735's
  -- own technique). The section collapses; the two new keys fall back to their fixed default
  -- shape rather than vanishing or going null.
  -----------------------------------------------------------------------------
  create or replace function public.get_ci_opportunities_v1(
    p_business uuid, p_from date, p_to date, p_branch uuid default null,
    p_as_of timestamptz default clock_timestamp(), p_extended boolean default false)
  returns jsonb language plpgsql as $stub$
  begin
    raise exception 'v738 fixture stub failure';
  end
  $stub$;

  perform app.v676_open_internal_drain();
  begin
    v_pack_stub := app.v176_evidence_pack(v_biz, 'monthly', v_from, v_to);
  exception when others then
    perform app.v676_close_internal_drain();
    insert into _fail values ('H3-pack-call', format('app.v176_evidence_pack raised %s', sqlerrm));
    return;
  end;
  perform app.v676_close_internal_drain();

  if not exists (select 1 from jsonb_array_elements(v_pack_stub->'evidence_completeness'->'unavailable_sections') u
                  where u->>'section' = 'ci_opportunities' and coalesce(u->>'sqlstate','') <> '') then
    insert into _fail values ('H3-isolation-not-named', format(
      'stubbing get_ci_opportunities_v1 did not name ci_opportunities with a sqlstate: %s',
      v_pack_stub->'evidence_completeness'->'unavailable_sections'));
  end if;
  if jsonb_typeof(v_pack_stub->'findings'->'ranked') is distinct from 'array'
     or jsonb_array_length(v_pack_stub->'findings'->'ranked') <> 0 then
    insert into _fail values ('H3-ranked-not-collapsed', format(
      'findings.ranked should collapse to [] when the section fails: %s', v_pack_stub->'findings'->'ranked'));
  end if;

  select array_agg(k order by k) into v_sections
    from jsonb_object_keys(v_pack_stub->'findings'->'report_sections') k;
  if v_sections is distinct from array['change','failures','leakage','margin','segments',
                                        'strengths','unnoticed_behaviour'] then
    insert into _fail values ('H3-fallback-sections-keys', format(
      'findings.report_sections fallback has the wrong key set: %s', v_sections));
  end if;
  if jsonb_typeof(v_pack_stub->'findings'->'report_sections'->'strengths') is distinct from 'array'
     or jsonb_array_length(v_pack_stub->'findings'->'report_sections'->'strengths') <> 0 then
    insert into _fail values ('H3-fallback-sections-nonempty', format(
      'findings.report_sections fallback strengths should be an empty array: %s',
      v_pack_stub->'findings'->'report_sections'->'strengths'));
  end if;
  if (v_pack_stub->'findings'->'report_sections'->'margin'->>'status') is distinct from 'unavailable' then
    insert into _fail values ('H3-fallback-margin', format(
      'findings.report_sections fallback margin is not the unavailable object: %s',
      v_pack_stub->'findings'->'report_sections'->'margin'));
  end if;

  if not (v_pack_stub->'findings' ? 'verdict_policy')
     or jsonb_typeof(v_pack_stub->'findings'->'verdict_policy') is distinct from 'object'
     or (v_pack_stub->'findings'->'verdict_policy'->>'causal_claims') is distinct from 'never'
  then
    insert into _fail values ('H3-fallback-verdict-policy', format(
      'findings.verdict_policy fallback is missing or malformed when the section fails: %s',
      v_pack_stub->'findings'->'verdict_policy'));
  end if;

  if v_pack_stub->'sales' is null or v_pack_stub->'insights' is null
     or v_pack_stub->'account_opens' is null or v_pack_stub->'consultant_brief' is null then
    insert into _fail values ('H3-other-sections-lost', format(
      'sections beside ci_opportunities were lost when only it was stubbed to fail: %s', v_pack_stub));
  end if;
end;
$v738$;

select case when count(*)=0
       then 'PASS — app.v176_evidence_pack findings carries report_sections + verdict_policy, '
            'additively, with a fixed fallback shape when the section is unavailable'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v738: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
