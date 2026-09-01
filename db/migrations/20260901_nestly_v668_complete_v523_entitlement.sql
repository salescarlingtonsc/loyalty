-- NESTLY v668 — the 2026-08-26 owner ruling on Customer Intelligence actually takes effect.
--
-- WHAT v523 RULED. nestly_v523 (owner ruling 2026-08-26, recorded in that migration's own
-- header) finishes the Customer Intelligence module and puts it back on NORMAL entitlement:
-- "this removes the override and lets the module resolve exactly like every other one — a
-- business that is not entitled still does not get it." This migration executes that recorded
-- ruling. It is not a new policy decision.
--
-- WHAT v523 MISSED. The hand-placed 'customerintel' -> 'disabled' override existed in TWO
-- resolvers, and v523 removed it from only one:
--
--   * app.staff_module_perms_at_v115 — removed by v523.                      (done)
--   * app.effective_platform_module_mode_v94 — NOT removed.                  (this migration)
--
-- The second one is the canonical resolver. Its live body (v94's, patched by v219 to drop the
-- twin 'inventory' short-circuit) still opens with
--
--     if p_module='customerintel' then
--       return query select 'disabled'::text,'global_platform_only_policy'::text,null::bigint;
--       return;
--     end if;
--
-- ahead of branch_override -> firm_override -> sector_entitlement. app.can_module reaches it
-- through app.can_module_read_at_v94 -> app.staff_module_mode_v94 (v184), which consults the
-- platform mode BEFORE it looks at staff.role — so not even an owner passes. nestly_v537 then
-- re-pointed app.capability_state_v518 at the same resolver, and its header names this exact
-- consequence as acceptable "while that policy stands". The policy no longer stands.
--
-- PROBE EVIDENCE (docs/qa/CI-REASSESSMENT-2026-09-01.md, defect D1; re-verified here). Against
-- the migrated cluster, for a fully operational business with 'customerintel' present in
-- enabled_modules and app.has_perm(business,'view_finance') = true:
--
--     app.can_module(business,'customerintel')  ->  false
--
-- i.e. the entitlement could be held and still bought nothing. Downstream, nestly_v573 gated
-- public.get_revenue_truth_v106 on that module, so revenue truth — the same known_revenue the
-- Dashboard, Business Insights and the P&L accrual tile display — was unreachable for EVERY
-- merchant role and answerable only to a super admin. db/tests/executed/v106_corpus_revenue_truth
-- .sql recorded that as a suspected defect and failed all six of its assertions on it.
--
-- WHAT THIS MIGRATION CHANGES. Exactly one thing: the customerintel short-circuit leaves
-- app.effective_platform_module_mode_v94. The resolution order is untouched — branch_override,
-- then firm_override, then sector_entitlement, in that order, with the same 'inherit' handling
-- and the same version bookkeeping. The proof is mechanical rather than asserted: the block
-- below captures pg_get_functiondef BEFORE the replacement and, after it, requires the new
-- definition to equal the old one with the short-circuit swapped for a comment of identical
-- intent. Any other drift raises and rolls the migration back.
--
-- WHAT IT DOES NOT CHANGE, deliberately:
--
--   * app.v32_customer_wallet_context (live definition: nestly_v233) inlines the same
--     branch/firm/entitlement resolution for the CUSTOMER wallet and carries its own
--     `case when key.module_key='customerintel' then 'disabled'` clause. It is a customer-facing
--     payload, not the merchant capability path, and 'customerintel' is a back-office module a
--     wallet has no use for. Removing it there would change what a customer's wallet reports
--     without unlocking anything, so it is recorded here and left alone.
--   * The clause also appears in the v233 and v246 bodies of app.staff_module_perms_at_v115.
--     Both are superseded — v523 is the live definition of that function — so there is nothing
--     to patch.
--   * app.staff_module_mode_v94's own `p_module='inventory'` short-circuit was already removed
--     by nestly_v184. Nothing about 'inventory' is touched here.
--   * No entitlement is granted to anybody. A business whose enabled_modules (or platform
--     override) does not carry 'customerintel' still resolves to 'disabled', and the v523
--     view_finance filter still keeps the module away from roles without that permission.
--
-- SHIPPING ALONGSIDE — PRODUCT-TRUTH. docs/product/PRODUCT-TRUTH.md still carried the
-- 2026-08-02 line "Customer Intelligence is a Peekaa platform/consulting capability, not a
-- self-service owner module", which the 2026-08-26 ruling supersedes and which nestly_v667's
-- header flags as an active contradiction. That bullet is rewritten in the same change to state
-- the entitlement rule, keeping the true half: consultants and super admins can additionally
-- generate it for assigned firms. Leaving the doc as it was would leave the next reader with two
-- live authorities that disagree, which is how v667's first draft nearly reversed an owner.
--
-- PROVEN BY: db/tests/executed/v667_ci_access_boundaries.sql assertion B8 (an entitled firm's
-- owner resolves customerintel to true; an unentitled firm's owner still resolves it to false)
-- and by db/tests/executed/v106_corpus_revenue_truth.sql, whose six revenue-truth assertions go
-- from all-red to all-green with no change to any expected number.
--
-- ROLLBACK: re-apply the v219-shape body, i.e. restore the four removed lines. The block below
-- prints the pre-change definition into a temp table for exactly that purpose.

begin;

-- ---------------------------------------------------------------------------
-- 1 · Capture the live definition, and refuse to run against a shape we do not
--     recognise. A silent no-op here would look exactly like a successful fix.
-- ---------------------------------------------------------------------------
create temp table _v668_before(def text) on commit drop;

do $pre$
declare v_n integer;
begin
  insert into _v668_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app'
     and p.proname = 'effective_platform_module_mode_v94';

  select count(*) into v_n from _v668_before;
  if v_n <> 1 then
    raise exception 'v668: expected exactly one app.effective_platform_module_mode_v94, found %', v_n;
  end if;

  if position('global_platform_only_policy' in (select def from _v668_before)) = 0 then
    raise exception
      'v668: the customerintel short-circuit is already absent — stop and re-read before shipping';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 2 · The same function, with the short-circuit removed and nothing else moved.
--     The body below is the live one verbatim (v94 as patched by v219) except
--     that the four-line customerintel block is replaced by the v668 comment.
-- ---------------------------------------------------------------------------
create or replace function app.effective_platform_module_mode_v94(
  p_business uuid,p_branch uuid,p_module text
)
returns table(mode text,source text,version bigint)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_row public.platform_module_overrides_v94%rowtype;
  v_inherit_version bigint;
begin
  -- v219: the blanket inventory disable is gone. Products now follow the business's own
  -- enabled_modules like every other module, via the sector_entitlement branch below.
  -- v668: and so does customerintel. The clause that stood here returned
  -- 'disabled'/'global_platform_only_policy' ahead of every override and the entitlement, so
  -- app.can_module(b,'customerintel') was false for every caller including an entitled owner,
  -- and the owner ruling recorded in nestly_v523 never took effect. Resolution order is
  -- unchanged: branch_override, then firm_override, then sector_entitlement.
  if p_branch is not null then
    select * into v_row
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
      and override_row.branch_scope=p_branch
      and override_row.module_key=p_module;
    if found and v_row.mode<>'inherit' then
      return query select v_row.mode,'branch_override'::text,v_row.version;
      return;
    elsif found then
      v_inherit_version:=v_row.version;
    end if;
  end if;
  select * into v_row
  from public.platform_module_overrides_v94 override_row
  where override_row.business_id=p_business
    and override_row.branch_scope is null
    and override_row.module_key=p_module;
  if found and v_row.mode<>'inherit' then
    return query select v_row.mode,'firm_override'::text,v_row.version;
    return;
  elsif found then
    v_inherit_version:=greatest(
      coalesce(v_inherit_version,0),v_row.version
    );
  end if;
  return query
  select case when p_module=any(business.enabled_modules)
      then 'rw' else 'disabled' end,
    'sector_entitlement'::text,
    v_inherit_version
  from public.businesses business
  where business.id=p_business;
end
$$;

/* Restated verbatim from the v94 definition that created this function. It has never been
   callable by anon or authenticated — every caller reaches it through a SECURITY DEFINER
   wrapper (app.staff_module_mode_v94, app.business_module_enabled_at_v117,
   app.capability_state_v518) — so there is no grant to restate, only the revoke. */
revoke all on function app.effective_platform_module_mode_v94(uuid,uuid,text)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 3 · Prove the diff is the diff that was intended.
-- ---------------------------------------------------------------------------
do $post$
declare
  v_before   text;
  v_after    text;
  v_expected text;
  /* The exact four lines being removed, as they stand in the live body. */
  v_clause constant text :=
E'  if p_module=\'customerintel\' then
    return query select \'disabled\'::text,\'global_platform_only_policy\'::text,null::bigint;
    return;
  end if;
';
  /* And the comment that takes their place, character for character with section 2. */
  v_comment constant text :=
E'  -- v668: and so does customerintel. The clause that stood here returned
  -- \'disabled\'/\'global_platform_only_policy\' ahead of every override and the entitlement, so
  -- app.can_module(b,\'customerintel\') was false for every caller including an entitled owner,
  -- and the owner ruling recorded in nestly_v523 never took effect. Resolution order is
  -- unchanged: branch_override, then firm_override, then sector_entitlement.
';
begin
  select def into v_before from _v668_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app'
     and p.proname = 'effective_platform_module_mode_v94';

  if position(v_clause in v_before) = 0 then
    raise exception
      'v668: the customerintel short-circuit was not found in the live body in the expected shape; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;

  v_expected := replace(v_before, v_clause, v_comment);

  if v_after <> v_expected then
    raise exception
      'v668: the new definition differs from the old one by more than the customerintel '
      'short-circuit — the resolution order must not move. Old:%  %New:%  %',
      E'\n', v_expected, E'\n', v_after;
  end if;

  /* The short-circuit is gone from the CODE. The phrase survives only inside the replacement
     comment, which is why this checks the executable clause rather than the string. */
  if position(v_clause in v_after) > 0 then
    raise exception 'v668: the short-circuit did not clear';
  end if;
end
$post$;

commit;
