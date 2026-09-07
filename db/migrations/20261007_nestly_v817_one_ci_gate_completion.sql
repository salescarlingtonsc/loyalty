-- NESTLY v817 — one Customer Intelligence gate, completion: the three functions v721 left behind.
--
-- OWNER RULING TO IMPLEMENT: every Customer Intelligence entry point uses the ONE shared gate
-- app.ci_access_gate_v667 (which asks app.can_module(business,'customerintel') for merchants and
-- admits the platform arm — the assigned consultant and the super admin — exactly as the ~30
-- sibling CI functions do). Converting the three functions below deliberately admits the platform
-- arm to them as well. That is the ruling, not a side effect to be worked around.
--
-- WHY THIS EXISTS. nestly_v721 closed CI-100-CHECKLIST checks 91 and 95 for
-- public.get_customer_intelligence_v83, but its own header (line "WHAT THIS MIGRATION DOES NOT
-- TOUCH") scoped the fix to exactly two functions. Three more still carry their own,
-- hand-written, merchant-only guard instead of calling the shared gate:
--
--   * public.create_customer_intelligence_export_v83  — has_perm(view_finance) AND
--     can_module(customerintel), no platform arm at all.
--   * public.get_customer_intelligence_export_page_v83 — the SAME two-part check, folded into a
--     three-part `or` alongside its own can_see_branch, all raising one message
--     ('export_scope_no_longer_permitted').
--   * public.get_revenue_truth_v106 — admits app.is_super_admin() OUTRIGHT (so a real-session
--     super admin was never refused here) but has no concept of the assigned consultant at all,
--     which is the OTHER half of the platform arm every sibling CI reader recognises.
--
-- PROVEN, not assumed, against the live production engine (gadpooereceldfpfxsod), read-only,
-- rolled back: as the real super admin principal (a `set local role authenticated` session
-- carrying the Google-OAuth claim shape app.is_super_admin() requires), calling
-- public.create_customer_intelligence_export_v83 raised 42501 while the already-converted sibling
-- public.get_customer_intelligence_v83 served the identical caller for the identical firm in the
-- same transaction. That is the "implemented-but-route-blocked ambiguity" CI-100-CHECKLIST check
-- 91 exists to close, on the one function of these three where a super admin (not just the
-- consultant) already proves it. db/tests/executed/v817_one_ci_gate_completion.sql S0/S0b
-- reproduce this proof as part of the acceptance suite so it survives past this migration's own
-- header.
--
-- THE FIX. The extract-and-diff pattern nestly_v668/v689/v713/v714/v721 established: capture the
-- LIVE pg_get_functiondef text, assert the anchor occurs EXACTLY ONCE, execute the literal
-- modified DDL, then re-capture and assert that reversing the substitution reproduces the
-- original byte-for-byte. Comment-free anchors, because a live body carries no migration-authored
-- comments to match against.
--
--   1. create_customer_intelligence_export_v83 — the private
--      `has_perm(view_finance) or not can_module(customerintel)` block is replaced by
--      `perform app.ci_access_gate_v667(p_business, p_branch);`. This function already takes
--      p_branch (nestly_v83's own signature), so the shared gate's branch-existence and (since
--      v721) branch-restriction checks apply for free. Nothing else in the body is touched.
--
--   2. get_customer_intelligence_export_page_v83 — the reader resolves p_business/p_branch from
--      the export row (v_export.business_id / v_export.branch_id), not from its own parameters,
--      so the substitution mirrors that: the has_perm/can_module half of the combined `or` is
--      replaced by `perform app.ci_access_gate_v667(v_export.business_id, v_export.branch_id);`,
--      and the reader's own pre-existing can_see_branch half is KEPT as a second, separate check
--      (same message, 'export_scope_no_longer_permitted') rather than deleted — this is "keep
--      every other refusal" applied literally. That second check is then widened by exactly the
--      pattern nestly_v721 used for get_customer_intelligence_v83's own can_see_branch check: OR
--      app.v176_can_read_firm_report(v_export.business_id) beside it. Without that widening, the
--      entitlement half would admit the platform arm and the branch-visibility half would refuse
--      them one line later — check 91's own failure mode, reintroduced by this migration instead
--      of closed by it, for a consultant who holds no public.staff row for the firm at all
--      (app.can_see_branch has no concept of them; see nestly_v721's header for the identical
--      argument made about v83). A merchant caller is unaffected: app.v176_can_read_firm_report is
--      false for all of them, so the check collapses back to exactly app.can_see_branch, unchanged.
--
--   3. get_revenue_truth_v106 — the `is_super_admin() or (has_perm and can_module)` block is
--      replaced by `perform app.ci_access_gate_v667(p_business, p_branch);` (this function already
--      validates p_to > p_from and auth.uid() is not null before this point; both untouched). The
--      reader's own can_see_branch check immediately below is widened the same way, for the same
--      reason, admitting the assigned consultant beside the super admin it already covered via
--      app.is_super_admin() before this migration (app.can_see_branch's own super-admin branch
--      already covered the SA half; the consultant half is what this migration adds here).
--
-- ESTATE SCAN, in-transaction: after both extract-and-diff blocks, a do $verify$ block scans
-- EVERY live function whose name contains 'customer_intelligence' or 'revenue_truth' (pg_proc,
-- not a hand-typed list) and fails the migration if any of them still contains an inline
-- `can_module(` call while its body does not also mention `ci_access_gate_v667` — an estate
-- assertion, not a list of the three names above, so a fourth stray guard introduced later would
-- be caught by the same rule rather than requiring a v818.
--
-- ACLs. No signature changes anywhere in this migration (unlike v667, which had to drop-and-
-- recreate for a new default parameter); every edit here is a same-signature CREATE OR REPLACE via
-- `execute`, which does not touch privileges. Restated anyway, explicitly, not assumed: anon holds
-- no execute on any of the three, authenticated and service_role do, matching what was live before
-- this migration (verified against production immediately before writing this migration).
--
-- WHAT THIS MIGRATION DOES NOT TOUCH. app.ci_access_gate_v667 itself (unchanged since v721 — this
-- migration only adds NEW callers of it); get_customer_intelligence_v83 and every other CI reader
-- already on the shared gate; docs/qa/CI-100-CHECKLIST.md is not re-scored here — that is a
-- separate audit pass, not a migration concern.
--
-- PROVEN BY: db/tests/executed/v817_one_ci_gate_completion.sql.
--
-- ROLLBACK: re-apply the pre-v817 bodies captured in this migration's own v_def / v_expected
-- roundtrips (the anchors above are exact), i.e. restore each function's private
-- has_perm/can_module (and, for the two with their own branch check, the un-widened
-- can_see_branch) gate in place of the `perform app.ci_access_gate_v667(...)` call.

begin;

-- ============================================================================================
-- 1 · public.create_customer_intelligence_export_v83 — private gate replaced by the shared one.
-- ============================================================================================
do $v817_export$
declare
  v_def       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  v_anchor constant text := $anchor1$  if not app.has_perm(p_business,'view_finance')
     or not app.can_module(p_business,'customerintel') then
    raise exception 'view_finance_required' using errcode='42501';
  end if;$anchor1$;
  v_new_text constant text := $newt1$  perform app.ci_access_gate_v667(p_business, p_branch);$newt1$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)'
  )) into v_def;
  if v_def is null then
    raise exception 'v817: public.create_customer_intelligence_export_v83(uuid,uuid,date,date) not found';
  end if;

  if position('app.ci_access_gate_v667' in v_def) > 0 then
    raise notice 'v817: create_customer_intelligence_export_v83 already converted, skipping';
  else
    v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
    if v_count <> 1 then
      raise exception 'v817: create_customer_intelligence_export_v83 private-gate anchor occurs % '
        'times (expected 1) — live body drifted from what this migration expects (re-extract with '
        'pg_get_functiondef rather than guessing)', v_count;
    end if;

    v_new := replace(v_def, v_anchor, v_new_text);
    execute v_new;

    select pg_get_functiondef(to_regprocedure(
      'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)'
    )) into v_after;
    v_roundtrip := replace(v_after, v_new_text, v_anchor);
    if v_roundtrip <> v_def then
      raise exception 'v817: create_customer_intelligence_export_v83 changed by more than the '
        'intended substitution'
        using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
    end if;
    if position('app.ci_access_gate_v667' in v_after) = 0 then
      raise exception 'v817: the shared gate call did not land in create_customer_intelligence_export_v83';
    end if;
    if position('view_finance_required' in v_after) > 0 then
      raise exception 'v817: the old private gate is still present in create_customer_intelligence_export_v83';
    end if;
  end if;
end
$v817_export$;

-- ============================================================================================
-- 2 · public.get_customer_intelligence_export_page_v83 — entitlement half replaced by the
--     shared gate; the reader's own branch-visibility half is kept, widened for the platform arm.
-- ============================================================================================
do $v817_page$
declare
  v_def       text;
  v_mid       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  v_anchor constant text := $anchor2$  if not app.has_perm(v_export.business_id,'view_finance')
     or not app.can_module(v_export.business_id,'customerintel')
     or not app.can_see_branch(v_export.business_id,v_export.branch_id) then
    raise exception 'export_scope_no_longer_permitted' using errcode='42501';
  end if;$anchor2$;
  v_new_text constant text := $newt2$  perform app.ci_access_gate_v667(v_export.business_id, v_export.branch_id);
  if not (app.v176_can_read_firm_report(v_export.business_id) or app.can_see_branch(v_export.business_id,v_export.branch_id)) then
    raise exception 'export_scope_no_longer_permitted' using errcode='42501';
  end if;$newt2$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)'
  )) into v_def;
  if v_def is null then
    raise exception 'v817: public.get_customer_intelligence_export_page_v83(uuid,integer,integer) not found';
  end if;

  if position('app.ci_access_gate_v667' in v_def) > 0 then
    raise notice 'v817: get_customer_intelligence_export_page_v83 already converted, skipping';
  else
    v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
    if v_count <> 1 then
      raise exception 'v817: get_customer_intelligence_export_page_v83 anchor occurs % times '
        '(expected 1) — live body drifted from what this migration expects (re-extract with '
        'pg_get_functiondef rather than guessing)', v_count;
    end if;

    v_new := replace(v_def, v_anchor, v_new_text);
    execute v_new;

    select pg_get_functiondef(to_regprocedure(
      'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)'
    )) into v_after;
    v_roundtrip := replace(v_after, v_new_text, v_anchor);
    if v_roundtrip <> v_def then
      raise exception 'v817: get_customer_intelligence_export_page_v83 changed by more than the '
        'intended substitution'
        using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
    end if;
    if position('app.ci_access_gate_v667' in v_after) = 0 then
      raise exception 'v817: the shared gate call did not land in get_customer_intelligence_export_page_v83';
    end if;
    if position('app.can_module' in v_after) > 0 then
      raise exception 'v817: an inline can_module call is still present in '
        'get_customer_intelligence_export_page_v83';
    end if;
    if position('app.v176_can_read_firm_report(v_export.business_id) or app.can_see_branch' in v_after) = 0 then
      raise exception 'v817: the branch-visibility widening did not land in '
        'get_customer_intelligence_export_page_v83';
    end if;
  end if;
end
$v817_page$;

-- ============================================================================================
-- 3 · public.get_revenue_truth_v106 — entitlement replaced by the shared gate; the reader's own
--     branch-visibility check is kept, widened for the platform arm.
-- ============================================================================================
do $v817_revtruth$
declare
  v_def       text;
  v_mid       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  v_anchor constant text := $anchor3$  if not (app.is_super_admin()
          or (app.has_perm(p_business, 'view_finance')
              and app.can_module(p_business, 'customerintel'))) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;$anchor3$;
  v_new_text constant text := $newt3$  perform app.ci_access_gate_v667(p_business, p_branch);$newt3$;
  v_anchor_bv constant text := $anchorbv3$  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;$anchorbv3$;
  v_new_bv constant text := $newbv3$  if not (app.v176_can_read_firm_report(p_business) or app.can_see_branch(p_business, p_branch)) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;$newbv3$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)'
  )) into v_def;
  if v_def is null then
    raise exception 'v817: public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz) not found';
  end if;

  if position('app.ci_access_gate_v667' in v_def) > 0 then
    raise notice 'v817: get_revenue_truth_v106 already converted, skipping';
  else
    v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
    if v_count <> 1 then
      raise exception 'v817: get_revenue_truth_v106 entitlement anchor occurs % times (expected 1) '
        '— live body drifted from what this migration expects (re-extract with pg_get_functiondef '
        'rather than guessing)', v_count;
    end if;
    v_count := (length(v_def) - length(replace(v_def, v_anchor_bv, ''))) / greatest(length(v_anchor_bv), 1);
    if v_count <> 1 then
      raise exception 'v817: get_revenue_truth_v106 branch-visibility anchor occurs % times '
        '(expected 1) — live body drifted from what this migration expects (re-extract with '
        'pg_get_functiondef rather than guessing)', v_count;
    end if;

    v_mid := replace(v_def, v_anchor, v_new_text);
    v_new := replace(v_mid, v_anchor_bv, v_new_bv);
    execute v_new;

    select pg_get_functiondef(to_regprocedure(
      'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)'
    )) into v_after;
    v_roundtrip := replace(replace(v_after, v_new_bv, v_anchor_bv), v_new_text, v_anchor);
    if v_roundtrip <> v_def then
      raise exception 'v817: get_revenue_truth_v106 changed by more than the two intended '
        'substitutions'
        using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
    end if;
    if position('app.ci_access_gate_v667' in v_after) = 0 then
      raise exception 'v817: the shared gate call did not land in get_revenue_truth_v106';
    end if;
    if position('finance permission required' in v_after) > 0 then
      raise exception 'v817: the old private gate is still present in get_revenue_truth_v106';
    end if;
    if position('app.v176_can_read_firm_report(p_business) or app.can_see_branch' in v_after) = 0 then
      raise exception 'v817: the branch-visibility widening did not land in get_revenue_truth_v106';
    end if;
  end if;
end
$v817_revtruth$;

-- ============================================================================================
-- 4 · ESTATE SCAN — every function named 'customer_intelligence' or 'revenue_truth' must call
--     the shared gate wherever it still mentions can_module inline. Not a list of three names:
--     a fourth stray guard introduced later is caught by the same rule.
-- ============================================================================================
do $v817_estate$
declare
  r record;
  v_def text;
  v_bad text[] := '{}';
begin
  for r in
    select p.oid, n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public','app')
       and p.prokind = 'f'
       and (p.proname like '%customer_intelligence%' or p.proname like '%revenue_truth%')
  loop
    v_def := pg_get_functiondef(r.oid);
    if position('can_module(' in v_def) > 0
       and position('ci_access_gate_v667' in v_def) = 0
    then
      v_bad := v_bad || (r.nspname || '.' || r.proname || '(' || r.args || ')');
    end if;
  end loop;
  if array_length(v_bad, 1) > 0 then
    raise exception 'v817: % Customer Intelligence / revenue truth function(s) still carry an '
      'inline can_module( guard without calling the shared gate app.ci_access_gate_v667: %',
      array_length(v_bad, 1), array_to_string(v_bad, ', ');
  end if;
end
$v817_estate$;

-- ============================================================================================
-- 5 · ACLs restated, not assumed — same-signature CREATE OR REPLACE does not change privileges,
--     but this asserts the estate matches what was live in production before this migration.
-- ============================================================================================
revoke all on function public.create_customer_intelligence_export_v83(uuid,uuid,date,date) from public, anon;
grant execute on function public.create_customer_intelligence_export_v83(uuid,uuid,date,date) to authenticated, service_role;

revoke all on function public.get_customer_intelligence_export_page_v83(uuid,integer,integer) from public, anon;
grant execute on function public.get_customer_intelligence_export_page_v83(uuid,integer,integer) to authenticated, service_role;

revoke all on function public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

do $v817_acl$
begin
  if pg_catalog.has_function_privilege('anon',
      'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)', 'execute')
     or pg_catalog.has_function_privilege('anon',
      'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)', 'execute')
     or pg_catalog.has_function_privilege('anon',
      'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)', 'execute')
  then
    raise exception 'v817: anon can execute one of the three converted functions directly';
  end if;
  if not (
    pg_catalog.has_function_privilege('authenticated',
      'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)', 'execute')
    and pg_catalog.has_function_privilege('authenticated',
      'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)', 'execute')
    and pg_catalog.has_function_privilege('authenticated',
      'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)', 'execute')
  ) then
    raise exception 'v817: authenticated lost execute on one of the three converted functions -- '
      'a same-signature CREATE OR REPLACE must not narrow the ACL';
  end if;
end
$v817_acl$;

commit;
