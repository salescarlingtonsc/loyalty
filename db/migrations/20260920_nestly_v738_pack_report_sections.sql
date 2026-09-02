-- NESTLY v738 — app.v176_evidence_pack's `findings` object gains report_sections + verdict_policy.
--
-- ===========================================================================================
-- THE DEFECT (refuter, executed). nestly_v713 wired the consultant spine's typed ranked/
-- top_actions/abstentions arrays into app.v176_evidence_pack's `findings` key, and nestly_v735
-- made the underlying app.v176_gated_evidence call run the spine in EXTENDED mode
-- (p_extended=>true) so those arrays are no longer permanently empty in production. But the
-- extended-mode payload public.get_ci_opportunities_v1 returns also carries two more top-level
-- keys that ONLY exist in extended mode — `report_sections` (nestly_v688, checks 22/79: the
-- ranked candidates bucketed into strengths/change/unnoticed_behaviour/leakage/margin/segments/
-- failures, a human-skimmable summary) and, from the base result carried through unconditionally,
-- `verdict_policy` (nestly_v696, check 17: {classes:['DIRECT_FACT','ASSOCIATION'],
-- causal_claims:'never'} — the fixed statement of what an evidence_class tag on a ranked
-- candidate does and does not assert). app.v176_evidence_pack's `findings` object
-- (nestly_v713, re-emitted by nestly_v720's internal-gate insertion, untouched by nestly_v735)
-- copies exactly three keys from `v_gated->'ci_opportunities'` — ranked, top_actions,
-- abstentions — and drops report_sections and verdict_policy on the floor. Grepped, not assumed:
-- supabase/functions/ai-firm-reports/validate.mjs's assembleUserPrompt calls
-- `JSON.stringify(report.evidence, null, 2)` on the WHOLE pack with no key allowlist, so whatever
-- app.v176_evidence_pack does not put in `findings` never reaches the model at all — the human-
-- skim summary and the fixed disclosure of what the typed tags mean are silently unavailable to
-- the narrative generator, even though the spine has computed both correctly since nestly_v688/
-- nestly_v696 and nestly_v735 made them reachable through this exact call path.
--
-- THE FIX. `findings` gains two more pass-through keys, both additive — no existing key's shape
-- or value changes:
--   `report_sections` — coalesced from `v_gated->'ci_opportunities'->'report_sections'` with a
--     fallback identical in shape to nestly_v688's own stale-evidence-branch default (the same
--     seven keys, six empty arrays plus the margin-unavailable object) for the case where the
--     ci_opportunities section itself is unavailable (a caught exception in
--     app.v176_gated_evidence, per nestly_v713's own try/catch) or ran in a mode that never set
--     it — `findings.report_sections` is therefore ALWAYS the seven-key object, never null,
--     exactly like `findings.ranked`/`top_actions`/`abstentions` are always arrays.
--   `verdict_policy` — coalesced from `v_gated->'ci_opportunities'->'verdict_policy'` with a
--     fallback of the identical literal nestly_v696 hardcodes into every call
--     (`get_ci_opportunities_v1` sets this key unconditionally, before the base/extended branch
--     point — the only way it is ever absent from `v_gated->'ci_opportunities'` is the section
--     being unavailable outright, in which case the fallback states the same fixed, business-
--     independent policy rather than surfacing null).
-- `evidence_completeness.findings_version` bumps from 'v713' to 'v738' — the pack's own version
-- marker for this key's shape, exactly the discipline nestly_v713 established when it introduced
-- the marker (never bumping `contract_version`, which stays the external identity three test
-- files already pin a literal 'v176' against).
--
-- WHAT THIS MIGRATION DOES NOT DO. It does not touch public.get_ci_opportunities_v1,
-- app.v176_gated_evidence, app.ci_access_gate_v667, or
-- supabase/functions/ai-firm-reports/validate.mjs or index.ts. On the JS side: validate.mjs's
-- assembleUserPrompt already stringifies the entire `report.evidence` object with no key
-- allowlist (confirmed by reading the live file, not assumed) — findings.report_sections and
-- findings.verdict_policy reach the model's prompt automatically, the moment this migration adds
-- them to the pack, with zero JS change owed. typedFindings' recursive walk (V10/V10b) is
-- similarly generic; report_sections' values are id-string arrays (or the margin object) with no
-- `evidence_class` field of their own, so this addition does not create any NEW typed-verdict
-- surface for the validator to reason about — it only makes the human-summary and policy-
-- disclosure keys visible to the narrative the model writes.
--
-- Re-emit lineage: app.v176_evidence_pack's LIVE body at apply time is nestly_v713's `findings`
-- assembly with nestly_v720's internal-gate insertion applied on top (confirmed: neither
-- nestly_v721 nor nestly_v725, both of which discuss this function in their own "what this
-- migration does not touch" sections, nor nestly_v735, which edits app.v176_gated_evidence's call
-- line but never app.v176_evidence_pack itself, changes any text in the region this migration
-- edits). Anchored, comment-free replace-equality, the pattern established by
-- v668/v690/v695/v696/v705/v712/v713/v720/v735: the live pg_get_functiondef text is captured,
-- each anchor is asserted to occur EXACTLY ONCE, the literal modified DDL is executed, then the
-- new definition is re-captured and reversing the substitution is required to reproduce the
-- captured original byte-for-byte.
--
-- Proven by db/tests/executed/v738_corpus_pack_report_sections.sql.
-- ===========================================================================================

begin;

do $v738_pack$
declare
  v_def  text;
  v_new  text;
  v_after text;
  v_roundtrip text;
  v_count integer;

  v_anchor_findings constant text := $af$    'findings', pg_catalog.jsonb_build_object(
      'source_rpc', 'public.get_ci_opportunities_v1',
      'ranked', coalesce(v_gated->'ci_opportunities'->'ranked', '[]'::jsonb),
      'top_actions', coalesce(v_gated->'ci_opportunities'->'top_actions', '[]'::jsonb),
      'abstentions', coalesce(v_gated->'ci_opportunities'->'abstentions', '[]'::jsonb)
    ),$af$;
  v_new_findings constant text := $nf$    'findings', pg_catalog.jsonb_build_object(
      'source_rpc', 'public.get_ci_opportunities_v1',
      'ranked', coalesce(v_gated->'ci_opportunities'->'ranked', '[]'::jsonb),
      'top_actions', coalesce(v_gated->'ci_opportunities'->'top_actions', '[]'::jsonb),
      'abstentions', coalesce(v_gated->'ci_opportunities'->'abstentions', '[]'::jsonb),
      'report_sections', coalesce(v_gated->'ci_opportunities'->'report_sections',
        pg_catalog.jsonb_build_object(
          'strengths', '[]'::jsonb, 'change', '[]'::jsonb, 'unnoticed_behaviour', '[]'::jsonb,
          'leakage', '[]'::jsonb,
          'margin', pg_catalog.jsonb_build_object('status', 'unavailable',
            'reason', 'no COGS/cost-of-goods field on services or sales in this schema'),
          'segments', '[]'::jsonb, 'failures', '[]'::jsonb)),
      'verdict_policy', coalesce(v_gated->'ci_opportunities'->'verdict_policy',
        pg_catalog.jsonb_build_object('classes', jsonb_build_array('DIRECT_FACT', 'ASSOCIATION'),
          'causal_claims', 'never'))
    ),$nf$;

  v_anchor_version constant text := $av$      'insights_version', 'v179',
      'findings_version', 'v713'
    )$av$;
  v_new_version constant text := $nv$      'insights_version', 'v179',
      'findings_version', 'v738'
    )$nv$;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v738: app.v176_evidence_pack(uuid,text,date,date) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_findings, ''))) / greatest(length(v_anchor_findings), 1);
  if v_count <> 1 then
    raise exception 'v738: v176_evidence_pack findings anchor occurs % times (expected 1) — '
      'live body drifted from what this migration expects', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_version, ''))) / greatest(length(v_anchor_version), 1);
  if v_count <> 1 then
    raise exception 'v738: v176_evidence_pack findings_version anchor occurs % times (expected 1) — '
      'live body drifted from what this migration expects', v_count;
  end if;

  v_new := replace(v_def, v_anchor_findings, v_new_findings);
  v_new := replace(v_new, v_anchor_version, v_new_version);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)')) into v_after;
  v_roundtrip := replace(v_after, v_new_findings, v_anchor_findings);
  v_roundtrip := replace(v_roundtrip, v_new_version, v_anchor_version);
  if v_roundtrip <> v_def then
    raise exception 'v738: v176_evidence_pack changed by more than the report_sections/verdict_policy/findings_version addition'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
end
$v738_pack$;

-- Live surface restated verbatim — CREATE OR REPLACE preserves whatever ACL is already sitting
-- there (owner-only, no anon/authenticated/service_role EXECUTE, restated explicitly by
-- nestly_v720); this just says so rather than leaving it implicit.
revoke execute on function app.v176_evidence_pack(uuid, text, date, date)
  from public, anon, authenticated, service_role;

comment on function app.v176_evidence_pack(uuid, text, date, date) is
  'nestly_v176/v179/v690/v713/v720/v738: assembles the AI firm-report evidence pack. Owner-only '
  'ACL (no anon/authenticated/public EXECUTE, restated by nestly_v720) plus an internal gate '
  '(nestly_v720): callable only by the sessionless internal drain, a reader '
  'app.v176_can_read_firm_report already approves (super admin / assigned consultant), or the '
  'firm''s own view_finance-permitted staff (app.has_perm(business,''view_finance'')). '
  '`findings` (nestly_v713, extended by nestly_v738) additively carries report_sections and '
  'verdict_policy alongside ranked/top_actions/abstentions, always as fixed-shape objects, '
  'never null.';

-- ===========================================================================================
-- Verification, executed rather than asserted. The scratch business is discarded via SAVEPOINT/
-- ROLLBACK TO SAVEPOINT, not DELETE — same reason nestly_v713/v720/v735's own verification does,
-- an immutability-guard trigger on rows a fresh business seeds refuses DELETE.
-- ===========================================================================================
savepoint v738_verify;

do $verify$
declare
  v_biz uuid := '00000000-0000-4000-8000-0000000738fa';
  v_pack jsonb;
  v_keys text[];
begin
  if pg_catalog.has_function_privilege('anon', 'app.v176_evidence_pack(uuid,text,date,date)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.v176_evidence_pack(uuid,text,date,date)', 'execute')
     or pg_catalog.has_function_privilege('service_role', 'app.v176_evidence_pack(uuid,text,date,date)', 'execute')
  then
    raise exception 'v738: a non-owner role can execute app.v176_evidence_pack directly';
  end if;

  insert into public.businesses (id, name, slug) values (v_biz, 'ZZ v738 verify', 'zz-v738-verify')
    on conflict (id) do nothing;

  perform app.v676_open_internal_drain();
  begin
    v_pack := app.v176_evidence_pack(v_biz, 'monthly', app.sg_today() - 35, app.sg_today() - 5);
  exception when others then
    perform app.v676_close_internal_drain();
    raise exception 'v738: app.v176_evidence_pack raised on a thin business: %', sqlerrm;
  end;
  perform app.v676_close_internal_drain();

  if not (v_pack->'findings' ? 'report_sections') then
    raise exception 'v738: findings has no report_sections key at all: %', v_pack->'findings';
  end if;
  if jsonb_typeof(v_pack->'findings'->'report_sections') is distinct from 'object' then
    raise exception 'v738: findings.report_sections is not an object: %', v_pack->'findings'->'report_sections';
  end if;

  select array_agg(k order by k) into v_keys
    from jsonb_object_keys(v_pack->'findings'->'report_sections') k;
  if v_keys is distinct from array['change','failures','leakage','margin','segments',
                                    'strengths','unnoticed_behaviour'] then
    raise exception 'v738: findings.report_sections has the wrong key set: %', v_keys;
  end if;

  if jsonb_typeof(v_pack->'findings'->'report_sections'->'margin') is distinct from 'object'
     or (v_pack->'findings'->'report_sections'->'margin'->>'status') is distinct from 'unavailable'
  then
    raise exception 'v738: findings.report_sections.margin is not the unavailable object: %',
      v_pack->'findings'->'report_sections'->'margin';
  end if;
  if jsonb_typeof(v_pack->'findings'->'report_sections'->'strengths') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'change') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'unnoticed_behaviour') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'leakage') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'segments') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'report_sections'->'failures') is distinct from 'array'
  then
    raise exception 'v738: findings.report_sections has a non-array/non-margin value: %',
      v_pack->'findings'->'report_sections';
  end if;

  if not (v_pack->'findings' ? 'verdict_policy') then
    raise exception 'v738: findings has no verdict_policy key at all: %', v_pack->'findings';
  end if;
  if jsonb_typeof(v_pack->'findings'->'verdict_policy') is distinct from 'object'
     or (v_pack->'findings'->'verdict_policy'->>'causal_claims') is distinct from 'never'
  then
    raise exception 'v738: findings.verdict_policy is missing or malformed: %', v_pack->'findings'->'verdict_policy';
  end if;

  if jsonb_typeof(v_pack->'findings'->'ranked') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'top_actions') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'abstentions') is distinct from 'array' then
    raise exception 'v738: findings.ranked/top_actions/abstentions regressed: %', v_pack->'findings';
  end if;

  if (v_pack->'evidence_completeness'->>'findings_version') is distinct from 'v738' then
    raise exception 'v738: evidence_completeness.findings_version is missing or wrong: %',
      v_pack->'evidence_completeness';
  end if;
end
$verify$;

rollback to savepoint v738_verify;

commit;
