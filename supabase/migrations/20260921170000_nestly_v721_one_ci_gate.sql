-- NESTLY v721 — one Customer Intelligence gate, and it actually enforces branch isolation.
--
-- Closes docs/qa/CI-100-CHECKLIST.md checks 91 and 95, both raised by the refuter's executed
-- findings against the live engine (pg_get_functiondef, not the migration source — the two
-- functions below have each been re-emitted since they were first written: app.ci_access_gate_v667
-- by nestly_v713 (the sessionless internal-drain arm), public.get_customer_intelligence_v83 by
-- nestly_v714 (the visit-day basis). Both extract-and-diff blocks below anchor on THOSE live
-- bodies, not the v667/v573 source, or the anchor assertion would raise a false "drifted" alarm
-- against a body that has, correctly, already moved.
--
-- ============================================================================================
-- CHECK 91 — one supported Customer Intelligence surface, no implemented-but-route-blocked
-- ambiguity.
--
-- THE DEFECT. public.get_customer_intelligence_v83 never called app.ci_access_gate_v667 at all.
-- It carries its own, second, hand-written gate:
--
--     if not app.has_perm(p_business,'view_finance')
--        or not app.can_module(p_business,'customerintel') then
--       raise exception 'view_finance_required' using errcode='42501';
--     end if;
--
-- which is the MERCHANT arm only — nestly_v667's platform arm (app.v176_can_read_firm_report:
-- super admin or the firm's assigned consultant) has no counterpart here at all. So the exact two
-- populations PRODUCT-TRUTH.md:443 and nestly_v667's own header name as entitled to Customer
-- Intelligence for an assigned firm — the assigned consultant, and the super admin reading through
-- a real platform session — are refused by THIS reader while being served by every other CI
-- reader (get_ci_acquisition_v1, get_ci_category_mix_v1, get_ci_category_customers_v1,
-- get_ci_funnel_v1, get_ci_contactability_v1, get_ci_engagement_v1), which all call
-- app.ci_access_gate_v667 and have done since nestly_v667. That is precisely the
-- "implemented-but-route-blocked ambiguity" check 91 forbids: one capability, two gates, two
-- different answers for the same caller.
--
-- THE FIX. Delete the duplicate gate. public.get_customer_intelligence_v83 now calls
--
--     perform app.ci_access_gate_v667(p_business, p_branch);
--
-- and nothing else for ENTITLEMENT — one authority, matching the six siblings. THE SECOND
-- ARGUMENT IS p_branch, NOT null, and that is worth a full paragraph because the obvious other
-- choice (null, on the theory that this reader already validates branch on its own immediately
-- below — see next section — so the shared gate need only judge entitlement here) was tried
-- first, in an earlier draft of this migration, and is provably wrong the moment check 95's
-- branch-restriction addition to the shared gate (below) exists beside it: that addition treats a
-- null p_branch as "this caller wants firm-wide figures" and refuses it for anyone who is not an
-- owner/admin/platform caller. Hard-coding null here would tell the shared gate EVERY call through
-- this reader is a firm-wide request, regardless of what branch the caller actually asked for —
-- so a branch-restricted employee reading their OWN assigned branch through v83 would be refused
-- unconditionally, on every call, forever, which is worse than the pre-v721 behaviour (correctly
-- served by this reader's own downstream check) and a straightforward regression. Proven, not
-- assumed: I1 in db/tests/executed/v721_corpus_one_ci_gate.sql — the bookkeeper reading THEIR OWN
-- assigned branch A2 — failed with 'branch-restricted staff must pass their branch' against the
-- null-argument draft. Passing the caller's real p_branch instead costs nothing for the platform
-- arm (the branch-restriction check excludes it outright, by identity, not by branch value — see
-- check 95 below) and for an owner/admin (app.can_see_branch is unconditional for them), and it is
-- what makes the shared gate's OWN branch checks agree with, rather than contradict, this reader's
-- pre-existing ones:
--
--     if p_branch is not null and not exists(select 1 from public.branches branch
--       where branch.id=p_branch and branch.business_id=p_business) then
--       raise exception 'branch_not_in_business' using errcode='22023';
--     end if;
--     if not app.can_see_branch(p_business,p_branch) then
--       raise exception 'branch_visibility_required' using errcode='42501';
--     end if;
--
-- (existing code since nestly_v573, unmoved by nestly_v650 or nestly_v714). Both of these now run
-- a SECOND TIME after checks the shared gate already performed with the same p_branch and the same
-- answer — redundant, not contradictory, and left in place rather than deleted: this migration
-- touches exactly two functions, and simplifying this reader's own body beyond the two anchored
-- substitutions below is a separate, optional cleanup this migration does not take on.
--
-- THE FOLLOW-ON DEFECT THIS EXPOSED, found by executing the fixture, not assumed: even with
-- p_branch (not null) reaching the shared gate correctly, this reader's own second check —
-- app.can_see_branch(p_business, p_branch) — still has no concept of the platform arm's OTHER
-- member, the assigned consultant, who reads through app.v176_can_read_firm_report and holds no
-- staff row for the firm at all (app.can_see_branch, nestly_v17, only ever recognises a
-- public.staff row or a super admin). So the moment the entitlement gate above stopped refusing
-- the consultant, THIS check took over and refused them instead — 'branch_visibility_required'
-- rather than the old 'view_finance_required', same caller, same result, the exact
-- "implemented-but-route-blocked ambiguity" check 91 exists to close, just moved one line down. (A
-- super admin was never affected: app.can_see_branch's own second branch, `when
-- app.is_super_admin() then true`, already covers them — this is a consultant-only gap.) Proven
-- this way rather than reasoned about in the abstract: G1 in
-- db/tests/executed/v721_corpus_one_ci_gate.sql failed with exactly this error before the fix
-- below was added.
--
-- FIX, second half: widen this reader's own branch-visibility check by the same platform
-- authority the entitlement gate already trusts —
--
--     if not (app.v176_can_read_firm_report(p_business) or app.can_see_branch(p_business,p_branch)) then
--       raise exception 'branch_visibility_required' using errcode='42501';
--     end if;
--
-- A super admin or the firm's assigned consultant now bypasses branch visibility entirely, which
-- is correct for both: neither is ever a branch-restricted employee, and a REAL foreign branch id
-- is still caught earlier by the unchanged branch_not_in_business existence check just above this
-- one (and, now, by the shared gate's own unchanged branch-existence check too). A merchant caller
-- (owner, manager, or a restricted employee like nestly_v721's bookkeeper fixture) is completely
-- unaffected — app.v176_can_read_firm_report is false for all of them, so the check collapses back
-- to exactly app.can_see_branch(p_business, p_branch), byte-identical to before this migration.
--
-- Net effect: the assigned consultant and a real-session super admin are now served by
-- get_customer_intelligence_v83 exactly as they are by every sibling reader, for the SAME branch
-- (or firm-wide) argument they actually passed; an owner or manager holding customerintel +
-- view_finance sees no change at all (the merchant arm is byte-identical to what this reader
-- already required, and so is its own branch check for every merchant caller, including a
-- branch-restricted employee reading their own branch); and a caller who satisfies neither arm
-- still gets 42501, now with the shared gate's message ('customer intelligence access is
-- required') instead of the old, reader-private 'view_finance_required' — a behaviour change in
-- wording only, for a caller who was always refused.
--
-- ============================================================================================
-- CHECK 95 — branch isolation: restricted staff cannot substitute business-wide history or
-- another branch when access fails.
--
-- THE DEFECT. app.ci_access_gate_v667's branch check, since nestly_v667, has only ever asked one
-- question: does p_branch belong to p_business? It never asks whether THIS caller may see THAT
-- branch, and it never refuses a null (firm-wide) p_branch from a caller who is not entitled to
-- firm-wide figures at all. So a bookkeeper (or any non-owner/admin role) assigned to exactly one
-- branch via public.staff_branches could:
--
--   * pass p_branch = <a DIFFERENT branch of the same firm> and be served that branch's figures
--     (the existence check only confirms the branch is real and belongs to the firm — never that
--     it belongs to THIS caller's assignment), and
--   * pass p_branch = null and be served firm-wide figures, substituting the whole business's
--     history for the one branch they actually work.
--
-- Every CI reader gated only by app.ci_access_gate_v667 inherited both holes. (It never affected
-- public.get_customer_intelligence_v83, which already carries app.can_see_branch(p_business,
-- p_branch) directly, in its own body — see check 91 above; that is a second reason this
-- migration's check-91 fix passes p_branch=null to the shared gate rather than reusing it for
-- branch scope on THIS reader.)
--
-- THE FIX. app.can_see_branch(p_business, p_branch) already exists (nestly_v17/v94) and already
-- answers exactly this, for BOTH cases in one predicate: it resolves true unconditionally for an
-- owner, an admin-class role, or a super admin (nestly_v17: "can_see_branch(business, NULL) =
-- owner/admin/super-admin only"), and for every other role only when public.staff_branches holds
-- an EXACT (business_id, staff_id, branch_id) assignment row (nestly_v327's own discipline for
-- that table) matching p_branch — which a null p_branch can never satisfy for a restricted role.
-- So a single new check, added to the merchant arm only —
--
--     if auth.uid() is not null
--        and not app.v176_can_read_firm_report(p_business)
--        and not app.can_see_branch(p_business, p_branch) then
--       raise exception 'branch-restricted staff must pass their branch' using errcode = '42501';
--     end if;
--
-- — closes both holes for every branch-scoped CI reader at once, at the one place they all share.
-- The condition deliberately excludes:
--   * the sessionless internal drain (nestly_v713; auth.uid() is null there, so the first conjunct
--     already fails) — a background worker with no session is not a branch-restricted employee;
--   * the platform arm, app.v176_can_read_firm_report (super admin or the firm's assigned
--     consultant) — neither holds a public.staff row for this firm at all, so app.can_see_branch
--     would (correctly, but irrelevantly) refuse them too; the header's own ruling for this check
--     is that owners/managers and the platform arm are unaffected, and this exclusion is what
--     makes that literally true rather than accidentally true.
-- An owner or admin-class merchant role is unaffected in practice (app.can_see_branch resolves
-- true for them regardless of p_branch), which is the "owners/managers... unaffected" half of the
-- same ruling.
--
-- Refuse, not scope: the header gave two options for the null-branch case and this migration picks
-- refuse — a restricted employee asking for firm-wide figures gets 42501 naming the reason, never
-- a silent narrowing to "their branch only", which would be a different answer to the question
-- they actually asked and the same misleading-output failure mode nestly_v667 already refused to
-- accept for a foreign branch id.
--
-- ============================================================================================
-- WHAT THIS MIGRATION DOES NOT TOUCH. app.v176_evidence_pack / app.v176_gated_evidence (nestly_v720
-- is in flight on that function in a sibling session per this session's own instructions) — this
-- migration's app.ci_access_gate_v667 edit is additive to the gate's OWN body only, and
-- v176_gated_evidence's existing calls into the gate (via get_ci_opportunities_v1, per nestly_v713)
-- are unaffected in shape, only in outcome for a caller who was already merchant-arm-gated and
-- branch-restricted. Nothing in public.get_ci_category_mix_v1, get_ci_category_customers_v1,
-- get_ci_acquisition_v1, get_ci_funnel_v1, get_ci_contactability_v1 or get_ci_engagement_v1 is
-- edited — they already call the shared gate and inherit this fix for free, which is the entire
-- point of a single gate.
--
-- ANCHORED EXTRACT-AND-DIFF, the pattern established by v668/v689/v713/v714: every edit below
-- captures the LIVE pg_get_functiondef text, asserts its anchor occurs EXACTLY ONCE, executes the
-- literal modified DDL, then re-captures the new definition and asserts that reversing the
-- substitution reproduces the original byte-for-byte.
--
-- PROVEN BY: db/tests/executed/v721_corpus_one_ci_gate.sql.
--
-- ROLLBACK: re-apply the pre-v721 bodies captured in this migration's own v_def / v_expected
-- roundtrip (the anchors printed above are exact), i.e. drop the branch-restriction if-block from
-- app.ci_access_gate_v667 and restore public.get_customer_intelligence_v83's private
-- view_finance_required gate in place of the perform call.

begin;

-- ============================================================================================
-- 1 · app.ci_access_gate_v667 — the merchant arm gains branch enforcement (check 95).
-- ============================================================================================
do $v721_gate$
declare
  v_def       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  -- The exact live block since nestly_v713 (drain arm + platform arm + merchant arm, unchanged
  -- since v689 inside it), verbatim.
  v_anchor constant text := $anchor$  if not (
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
  end if;$anchor$;
  -- Same block, plus one new if-statement immediately after it. Nothing inside the anchor moves.
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
  end if;
  -- v721 (check 95): the merchant arm is scoped further -- a branch-restricted employee must
  -- actually be assigned the branch they ask for, and may not substitute firm-wide history by
  -- omitting p_branch. app.can_see_branch(business, NULL) already resolves true only for an
  -- owner/admin/super-admin (nestly_v17/v94), so this one predicate covers both the
  -- p_branch-is-not-null case (must be assigned, nestly_v327's exact staff_branches match) and
  -- the p_branch-is-null case (must be unrestricted) in one call. The sessionless internal drain
  -- (auth.uid() is null there) and the platform arm (super admin / assigned consultant, neither of
  -- whom holds a staff row for this firm) are excluded on purpose -- neither is a branch-restricted
  -- employee, and this exclusion is what makes "owners/managers and the platform arm unaffected"
  -- literally true rather than accidentally true.
  if auth.uid() is not null
     and not app.v176_can_read_firm_report(p_business)
     and not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch-restricted staff must pass their branch'
      using errcode = '42501';
  end if;$newt$;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_access_gate_v667(uuid,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v721: app.ci_access_gate_v667(uuid,uuid) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
  if v_count <> 1 then
    raise exception 'v721: ci_access_gate_v667 access-check anchor occurs % times (expected 1) — '
      'live body drifted from what this migration expects (re-extract with pg_get_functiondef '
      'rather than guessing)', v_count;
  end if;

  v_new := replace(v_def, v_anchor, v_new_text);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.ci_access_gate_v667(uuid,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new_text, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v721: ci_access_gate_v667 changed by more than the intended branch-restriction '
      'addition'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
  if position('app.can_see_branch' in v_after) = 0 then
    raise exception 'v721: the branch-restriction check did not land';
  end if;
  if position('branch-restricted staff must pass their branch' in v_after) = 0 then
    raise exception 'v721: the clear-reason refusal message did not land';
  end if;
end
$v721_gate$;

-- ============================================================================================
-- 2 · public.get_customer_intelligence_v83 — the private gate is replaced by the shared one
--     (check 91).
-- ============================================================================================
do $v721_ci83$
declare
  v_def       text;
  v_mid       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  -- Patch 1: the private entitlement gate is replaced by the shared authority (check 91).
  v_anchor constant text := $anchor2$  if not app.has_perm(p_business,'view_finance')
     or not app.can_module(p_business,'customerintel') then
    raise exception 'view_finance_required' using errcode='42501';
  end if;$anchor2$;
  v_new_text constant text := $newt2$  perform app.ci_access_gate_v667(p_business, p_branch);$newt2$;
  -- Patch 2: the reader's own pre-existing branch-visibility check is widened to admit the same
  -- platform arm the shared gate now admits -- otherwise a consultant served by patch 1 is
  -- refused one line later by app.can_see_branch, which has no concept of them at all (found by
  -- executing the fixture; see the migration header for the full account).
  v_anchor_bv constant text := $anchorbv$  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'branch_visibility_required' using errcode='42501';
  end if;$anchorbv$;
  v_new_bv constant text := $newbv$  if not (app.v176_can_read_firm_report(p_business) or app.can_see_branch(p_business,p_branch)) then
    raise exception 'branch_visibility_required' using errcode='42501';
  end if;$newbv$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'
  )) into v_def;
  if v_def is null then
    raise exception 'v721: public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,'
      'timestamptz,timestamptz,uuid) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
  if v_count <> 1 then
    raise exception 'v721: ci83 private-gate anchor occurs % times (expected 1) — live body '
      'drifted from what this migration expects (re-extract with pg_get_functiondef rather than '
      'guessing)', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_bv, ''))) / greatest(length(v_anchor_bv), 1);
  if v_count <> 1 then
    raise exception 'v721: ci83 branch-visibility anchor occurs % times (expected 1) — live body '
      'drifted from what this migration expects (re-extract with pg_get_functiondef rather than '
      'guessing)', v_count;
  end if;

  v_mid := replace(v_def, v_anchor, v_new_text);
  v_new := replace(v_mid, v_anchor_bv, v_new_bv);
  execute v_new;

  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'
  )) into v_after;
  v_roundtrip := replace(replace(v_after, v_new_bv, v_anchor_bv), v_new_text, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v721: get_customer_intelligence_v83 changed by more than the two intended '
      'substitutions'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
  if position('app.ci_access_gate_v667' in v_after) = 0 then
    raise exception 'v721: the shared gate call did not land';
  end if;
  if position('view_finance_required' in v_after) > 0 then
    raise exception 'v721: the old private gate is still present';
  end if;
  if position('app.v176_can_read_firm_report(p_business) or app.can_see_branch' in v_after) = 0 then
    raise exception 'v721: the branch-visibility widening did not land';
  end if;
end
$v721_ci83$;

-- ============================================================================================
-- 3 · No grant was loosened by either same-signature CREATE OR REPLACE above — asserted, not
--     assumed (the v713 discipline).
-- ============================================================================================
do $v721_acl$
begin
  if pg_catalog.has_function_privilege('anon', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('service_role', 'app.ci_access_gate_v667(uuid,uuid)', 'execute')
  then
    raise exception 'v721: a non-owner role can execute app.ci_access_gate_v667 directly';
  end if;
  if not pg_catalog.has_function_privilege('authenticated',
      'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)',
      'execute')
  then
    raise exception 'v721: authenticated lost execute on get_customer_intelligence_v83 -- a '
      'CREATE OR REPLACE with the same signature must not narrow the ACL';
  end if;
end
$v721_acl$;

commit;
