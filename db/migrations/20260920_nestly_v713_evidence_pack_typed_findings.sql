-- NESTLY v713 — the AI firm-report evidence pack gets its first evidence_class-bearing objects.
--
-- ===========================================================================================
-- THE DEFECT (section-D refuter, check 17). validate.mjs's typed-verdict rules — V10
-- (CAUSAL_BINDING) and V10b (ASSOCIATION_MARKER) — key on ANY plain object anywhere in the
-- evidence pack carrying its own string `evidence_class` (typedFindings, readPack's recursive
-- walk; supabase/functions/ai-firm-reports/validate.mjs). That machinery is generic and correct.
-- But app.v176_evidence_pack — the ONLY function that ever builds the object index.ts sends the
-- model (supabase/functions/ai-firm-reports/index.ts imports assembleUserPrompt/validateNarrative
-- from ./validate.mjs and calls them against report.evidence, which comes from the
-- ai_firm_reports_v176 row that public.internal_claim_ai_firm_report_v176 populated from
-- app.v176_evidence_pack at claim time) — has NEVER carried one. Grepped, not assumed: its five
-- top-level sections (scope, sales, insights [app.v179_business_insights], account_opens,
-- consultant_brief/catalogue_affinity/recommendations [the v94 platform-control-intelligence
-- RPCs], evidence_completeness) contain zero occurrences of the string `evidence_class` anywhere
-- in their defining SQL. Meanwhile public.get_ci_opportunities_v1 — the "consultant spine" nine
-- other migrations this session (v678..v712) have been hardening — has computed a typed,
-- ASSOCIATION/DIRECT_FACT-tagged `ranked` array (with `pattern`, `impact`, `evidence_class`) all
-- along, and was never wired into the pack. So V10/V10b have been proven ONLY against the
-- synthetic packs tests/ai-reports fixtures hand-build (contract_version stubs, no live RPC
-- behind them) — never once against a pack this codebase can actually produce. A validator that
-- only ever sees its own test's fixtures is unverified in the one place it matters.
--
-- THE FIX. app.v176_gated_evidence gains a FIFTH gated section, `ci_opportunities`, calling
-- public.get_ci_opportunities_v1 in its own try/catch exactly like the four sections beside it
-- (one failure costs one section, never the whole pack — the v552/v676 discipline, unchanged).
-- app.v176_evidence_pack surfaces it under a new top-level `findings` key (`ranked`,
-- `top_actions`, `abstentions` — the spine's own vocabulary, passed through untouched) plus
-- `evidence_completeness.findings_version`. Both edits are purely additive: no existing key's
-- shape or value changes, so tests/ai-reports/*.test.mjs's existing pack fixtures and
-- db/tests/executed/v552_gated_evidence_isolation.sql (which reads the pack by key, never by
-- exact-equality on the whole object) are untouched. `contract_version` stays 'v176' — it is the
-- external identity of this pack shape that three test files already pin a literal 'v176' against
-- (grepped) — the pack's OWN version bump lives in the new `findings_version` key instead,
-- exactly the way `insights_version` already sits beside it rather than replacing
-- `contract_version` when v179 added the `insights` block.
--
-- THE SECOND DEFECT THIS EXPOSED, found while wiring the call, not assumed: get_ci_opportunities_
-- v1's own gate — app.ci_access_gate_v667 — is `if auth.uid() is null or not (...) then raise`.
-- Since the sessionless drain (auth.uid() is always null there — v676's own header: "a background
-- worker with no user session") never sets a JWT claim, calling it from app.v176_gated_evidence
-- would ALWAYS 42501 before this migration, in every real production report, making `findings`
-- permanently empty and the whole point of this migration moot: the pack would still never carry
-- a live evidence_class object, only a section that always says "unavailable". The other four
-- gated RPCs already solved exactly this — app.platform_firm_report_access_v94 and
-- public.platform_customer_account_opens_v175 both check app.v676_internal_drain_active() as
-- their first arm (grepped in both live bodies, below). app.ci_access_gate_v667 never got that
-- arm because it predates v676 (v667, 2026-09-01) and nothing has called it from a sessionless
-- context until now. This migration adds the identical arm, in the identical place a human
-- caller's path already occupies (auth.uid() is not null wraps the two existing arms unchanged),
-- so no merchant or platform caller's behaviour moves by one byte — proved below by anchored
-- extract-and-diff plus a roundtrip-equality check, the same standard the four-arm additions
-- below hold themselves to.
--
-- SHAPE OF THE ARGUMENT AGAINST FORGERY: app.v676_internal_drain_active() reads a table with NO
-- grants to any role, reachable only from inside a SECURITY DEFINER chain rooted at
-- app.v176_gated_evidence (itself revoked from public/anon/authenticated/service_role) — the same
-- authority v676 already proved cannot be set_config'd into existence by a guessing attacker
-- (db/migrations/20260920_nestly_v676_internal_drain_authority.sql, verification 6.3). Adding a
-- FOURTH caller of that same boolean does not weaken it; it is read-only everywhere it is used.
--
-- WHAT THIS MIGRATION DOES NOT DO. It does not touch public.get_ci_opportunities_v1 itself (v712,
-- 20260920_nestly_v712_spine_wording_closures.sql, is in flight in a sibling session per this
-- session's own instructions) or validate.mjs (owned by another agent). validate.mjs needs no
-- change at all: typedFindings already walks the WHOLE pack looking for any object with its own
-- `evidence_class` — see the JSON-path note in this migration's closing comment for exactly where
-- those objects now live, so the validator's owner can point a `readPack`/fixture assertion at it
-- with no further plumbing.
--
-- ANCHORED EXTRACT-AND-DIFF, the pattern established by v668/v690/v695/v696/v705/v712: every edit
-- below captures the LIVE pg_get_functiondef text, asserts its anchor occurs EXACTLY ONCE (a
-- drifted anchor raises rather than silently patching the wrong thing or nothing at all),
-- executes the literal modified DDL, then re-captures the new definition and asserts that
-- reversing the substitution reproduces the original byte-for-byte — proof that nothing besides
-- the intended text moved.

begin;

-- =============================================================================================
-- 1 · app.ci_access_gate_v667 — the sessionless internal drain becomes a recognised caller,
--     exactly the arm v676 already gave the four RPCs beside it.
-- =============================================================================================
do $v713_gate$
declare
  v_def  text;
  v_new  text;
  v_after text;
  v_roundtrip text;
  v_count integer;
  v_anchor constant text := $anchor$  if auth.uid() is null
     or not (
          app.v176_can_read_firm_report(p_business)                    -- platform: SA or assigned consultant
          or (app.is_salon_member(p_business)                          -- merchant: v689 -- customerintel + view_finance
              and app.can_module(p_business, 'customerintel')
              and app.has_perm(p_business, 'view_finance'))
        ) then
    raise exception 'customer intelligence access is required'
      using errcode = '42501';
  end if;$anchor$;
  v_new_text constant text := $newt$  if not (
          app.v676_internal_drain_active()                             -- internal: nestly_v713 —
                                                                         -- the sessionless evidence
                                                                         -- drain (v676's authority)
          or (auth.uid() is not null and (
                app.v176_can_read_firm_report(p_business)                    -- platform: SA or assigned consultant
                or (app.is_salon_member(p_business)                          -- merchant: v689 -- customerintel + view_finance
                    and app.can_module(p_business, 'customerintel')
                    and app.has_perm(p_business, 'view_finance'))
              ))
        ) then
    raise exception 'customer intelligence access is required'
      using errcode = '42501';
  end if;$newt$;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_access_gate_v667(uuid,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v713: app.ci_access_gate_v667(uuid,uuid) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
  if v_count <> 1 then
    raise exception 'v713: ci_access_gate_v667 access-check anchor occurs % times (expected 1) — '
      'live body drifted from what this migration expects', v_count;
  end if;

  v_new := replace(v_def, v_anchor, v_new_text);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.ci_access_gate_v667(uuid,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new_text, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v713: ci_access_gate_v667 changed by more than the internal-drain arm'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
end
$v713_gate$;

-- =============================================================================================
-- 2 · app.v176_gated_evidence — a fifth gated section, ci_opportunities, alongside the existing
--     four. Three anchors: the declare block (new v_ci variable), the try/catch section itself
--     (inserted right after account_opens_report's, same fail-alone shape), and the return object
--     (one new key, ci_opportunities).
-- =============================================================================================
do $v713_evidence$
declare
  v_def  text;
  v_new  text;
  v_after text;
  v_roundtrip text;
  v_count integer;

  v_anchor_decl constant text := $decl$  v_unavailable jsonb := '[]'::jsonb;$decl$;
  v_new_decl constant text := $newd$  v_unavailable jsonb := '[]'::jsonb;
  v_ci jsonb;$newd$;

  v_anchor_section constant text := $sec$  begin
    v_opens := public.platform_customer_account_opens_v175(p_business, p_from, v_to_effective);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','account_opens_report','sqlstate', sqlstate);
  end;$sec$;
  v_new_section constant text := $news$  begin
    v_opens := public.platform_customer_account_opens_v175(p_business, p_from, v_to_effective);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','account_opens_report','sqlstate', sqlstate);
  end;
  /* NESTLY v713 (check 17, evidence half): the one section that gives this pack a live
     evidence_class-bearing object. Non-extended call (p_extended default false) — the base
     contract already tags every ranked candidate's evidence_class, so nothing more is needed to
     satisfy validate.mjs's typedFindings. Gated and fail-alone like the four sections above it. */
  begin
    v_ci := public.get_ci_opportunities_v1(p_business, p_from, v_to_effective);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','ci_opportunities','sqlstate', sqlstate);
  end;$news$;

  v_anchor_return constant text := $ret$    'account_opens_report', v_opens,
    'account_opens_range', pg_catalog.jsonb_build_object(
      'requested_to', p_to,
      'effective_to', v_to_effective,
      'clamped', v_to_effective < p_to
    )
  );$ret$;
  v_new_return constant text := $newr$    'account_opens_report', v_opens,
    'account_opens_range', pg_catalog.jsonb_build_object(
      'requested_to', p_to,
      'effective_to', v_to_effective,
      'clamped', v_to_effective < p_to
    ),
    'ci_opportunities', v_ci
  );$newr$;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_gated_evidence(uuid,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v713: app.v176_gated_evidence(uuid,date,date) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_decl, ''))) / greatest(length(v_anchor_decl), 1);
  if v_count <> 1 then
    raise exception 'v713: v176_gated_evidence declare anchor occurs % times (expected 1)', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_section, ''))) / greatest(length(v_anchor_section), 1);
  if v_count <> 1 then
    raise exception 'v713: v176_gated_evidence section anchor occurs % times (expected 1)', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_return, ''))) / greatest(length(v_anchor_return), 1);
  if v_count <> 1 then
    raise exception 'v713: v176_gated_evidence return anchor occurs % times (expected 1)', v_count;
  end if;

  v_new := replace(v_def, v_anchor_decl, v_new_decl);
  v_new := replace(v_new, v_anchor_section, v_new_section);
  v_new := replace(v_new, v_anchor_return, v_new_return);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.v176_gated_evidence(uuid,date,date)')) into v_after;
  v_roundtrip := replace(v_after, v_new_decl, v_anchor_decl);
  v_roundtrip := replace(v_roundtrip, v_new_section, v_anchor_section);
  v_roundtrip := replace(v_roundtrip, v_new_return, v_anchor_return);
  if v_roundtrip <> v_def then
    raise exception 'v713: v176_gated_evidence changed by more than the ci_opportunities addition'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
end
$v713_evidence$;

-- =============================================================================================
-- 3 · app.v176_evidence_pack — surface the new gated section as a top-level `findings` key, and
--     record the addition in evidence_completeness. Two anchors.
-- =============================================================================================
do $v713_pack$
declare
  v_def  text;
  v_new  text;
  v_after text;
  v_roundtrip text;
  v_count integer;

  v_anchor_findings constant text := $af$    'consultant_brief', v_gated->'consultant_brief',
    'catalogue_affinity', v_gated->'catalogue_affinity',
    'recommendations', v_gated->'recommendations',
    'evidence_completeness', pg_catalog.jsonb_build_object($af$;
  v_new_findings constant text := $nf$    'consultant_brief', v_gated->'consultant_brief',
    'catalogue_affinity', v_gated->'catalogue_affinity',
    'recommendations', v_gated->'recommendations',
    /* NESTLY v713 (check 17): the spine's typed candidates, additive, so V10/V10b (validate.mjs)
       have a real production object to walk instead of only ever seeing one in a synthetic test
       fixture. Passed through untouched — 'ranked'/'top_actions'/'abstentions' are the spine's own
       vocabulary (public.get_ci_opportunities_v1), never re-derived here. */
    'findings', pg_catalog.jsonb_build_object(
      'source_rpc', 'public.get_ci_opportunities_v1',
      'ranked', coalesce(v_gated->'ci_opportunities'->'ranked', '[]'::jsonb),
      'top_actions', coalesce(v_gated->'ci_opportunities'->'top_actions', '[]'::jsonb),
      'abstentions', coalesce(v_gated->'ci_opportunities'->'abstentions', '[]'::jsonb)
    ),
    'evidence_completeness', pg_catalog.jsonb_build_object($nf$;

  v_anchor_version constant text := $av$      'revenue_definition',
        'per-sale v10.1 policy snapshot (counts_as_revenue)',
      'insights_version', 'v179'
    )$av$;
  v_new_version constant text := $nv$      'revenue_definition',
        'per-sale v10.1 policy snapshot (counts_as_revenue)',
      'insights_version', 'v179',
      'findings_version', 'v713'
    )$nv$;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v713: app.v176_evidence_pack(uuid,text,date,date) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_findings, ''))) / greatest(length(v_anchor_findings), 1);
  if v_count <> 1 then
    raise exception 'v713: v176_evidence_pack findings-insertion anchor occurs % times (expected 1)', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_version, ''))) / greatest(length(v_anchor_version), 1);
  if v_count <> 1 then
    raise exception 'v713: v176_evidence_pack findings_version anchor occurs % times (expected 1)', v_count;
  end if;

  v_new := replace(v_def, v_anchor_findings, v_new_findings);
  v_new := replace(v_new, v_anchor_version, v_new_version);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)')) into v_after;
  v_roundtrip := replace(v_after, v_new_findings, v_anchor_findings);
  v_roundtrip := replace(v_roundtrip, v_new_version, v_anchor_version);
  if v_roundtrip <> v_def then
    raise exception 'v713: v176_evidence_pack changed by more than the findings/findings_version addition'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
end
$v713_pack$;

-- =============================================================================================
-- 4 · Verification, executed rather than asserted. The scratch business 4.3 creates is
--     discarded via SAVEPOINT/ROLLBACK TO SAVEPOINT, not DELETE — a fresh business seeds rows
--     (e.g. public.benefit_registry) an immutability guard trigger refuses to ever delete, so a
--     savepoint is the only clean way to leave no trace of a migration-time verification row.
-- =============================================================================================
savepoint v713_verify;

do $verify$
declare
  v_biz uuid := '00000000-0000-4000-8000-0000000713fa';
  v_pack jsonb;
  v_gate_ok boolean;
begin
  -- 4.1 · No grant was loosened by the CREATE OR REPLACE above — ACLs survive a same-signature
  --       replace, but assert it rather than trust that Postgres behaves as documented.
  if pg_catalog.has_function_privilege('anon', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('service_role', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
  then
    raise exception 'v713: a non-owner role can execute app.ci_access_gate_v667 directly';
  end if;
  if pg_catalog.has_function_privilege('anon', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
     or pg_catalog.has_function_privilege('service_role', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
  then
    raise exception 'v713: a non-owner role can execute app.v176_gated_evidence directly';
  end if;

  -- 4.2 · The internal-drain arm actually opens ci_access_gate_v667, and closing the drain
  --       restores the refusal — proved directly against the gate, no business scaffolding
  --       needed since the gate's first arm never touches business rows.
  perform app.v676_open_internal_drain();
  begin
    perform app.ci_access_gate_v667(v_biz);
    v_gate_ok := true;
  exception when others then
    v_gate_ok := false;
  end;
  perform app.v676_close_internal_drain();
  if not v_gate_ok then
    raise exception 'v713: ci_access_gate_v667 still refuses the internal drain once it is open';
  end if;

  begin
    perform app.ci_access_gate_v667(v_biz);
    v_gate_ok := true;
  exception when others then
    v_gate_ok := false;
  end;
  if v_gate_ok then
    raise exception 'v713: ci_access_gate_v667 admits a sessionless caller with the drain closed';
  end if;

  -- 4.3 · Structural wiring end to end: a minimal business, sessionless (no request.jwt.claims —
  --       the real production shape, per v676/index.ts), through app.v176_evidence_pack. This
  --       business carries none of the workspace/subscription/reporting-contract scaffolding
  --       get_ci_opportunities_v1's own sub-readers need, so ci_opportunities is expected to
  --       come back unavailable here for an ordinary billing reason — that is fine; this checks
  --       the KEYS exist and are never-null-typed, not that this thin business promotes a
  --       candidate. db/tests/executed/v713_corpus_evidence_pack.sql proves the populated case.
  insert into public.businesses (id, name, slug) values (v_biz, 'ZZ v713 verify', 'zz-v713-verify')
    on conflict (id) do nothing;

  v_pack := app.v176_evidence_pack(v_biz, 'monthly', app.sg_today() - 35, app.sg_today() - 5);

  if not (v_pack ? 'findings') then
    raise exception 'v713: the evidence pack has no findings key at all';
  end if;
  if jsonb_typeof(v_pack->'findings'->'ranked') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'top_actions') is distinct from 'array'
     or jsonb_typeof(v_pack->'findings'->'abstentions') is distinct from 'array' then
    raise exception 'v713: findings.ranked/top_actions/abstentions are not arrays: %', v_pack->'findings';
  end if;
  if (v_pack->'findings'->>'source_rpc') is distinct from 'public.get_ci_opportunities_v1' then
    raise exception 'v713: findings.source_rpc is wrong: %', v_pack->'findings'->>'source_rpc';
  end if;
  if (v_pack->'evidence_completeness'->>'findings_version') is distinct from 'v713' then
    raise exception 'v713: evidence_completeness.findings_version is missing or wrong: %',
      v_pack->'evidence_completeness';
  end if;
  if not (v_pack->'evidence_completeness' ? 'unavailable_sections') then
    raise exception 'v713: evidence_completeness lost unavailable_sections';
  end if;
end
$verify$;

rollback to savepoint v713_verify;

commit;

-- ===========================================================================================
-- FOR THE VALIDATOR OWNER (validate.mjs is not touched by this migration — another agent owns
-- it). No change is required there: typedFindings already walks the WHOLE evidence pack looking
-- for any plain object carrying its own `evidence_class` in {'ASSOCIATION','DIRECT_FACT'}, with
-- no assumption about which key holds it. As of this migration the pack (app.v176_evidence_pack)
-- carries such objects at:
--
--   findings.ranked[]            -- every candidate the spine examined and promoted; each one
--                                    is exactly the object typedFindings wants: evidence_class,
--                                    pattern (its identifying text), impact.
--   findings.top_actions[]       -- a subset of the same objects (populated when the spine ran
--                                    in extended mode or hit its stale-evidence fallback; '[]'
--                                    otherwise — findings.ranked is the one always populated when
--                                    the section is available at all).
--
-- Neither array exists yet in tests/ai-reports/fixtures/golden-packs/ or the hand-built fixtures
-- inside tests/ai-reports/*.test.mjs — those still exercise V10/V10b against synthetic
-- evidence_class objects placed directly at the fixture's top level, which is a fine unit test of
-- the rule but proves nothing about whether a REAL pack ever reaches the validator with one. A
-- fixture pointed at findings.ranked (seeded via the same acceptance corpus this migration ships,
-- db/tests/executed/v713_corpus_evidence_pack.sql) would close that gap; that fixture wiring is
-- the validator owner's call, not made here.
