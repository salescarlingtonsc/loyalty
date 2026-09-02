-- NESTLY v689 -- the merchant arm of the Customer Intelligence gate joins the same three
-- authorities the client and the revenue-truth reader already require.
--
-- THE GAP (docs/qa/CI-REASSESSMENT-2026-09-01.md, check 91). app.ci_access_gate_v667's merchant
-- arm is
--
--     app.is_salon_member(p_business) and app.can_module(p_business, 'reports')
--
-- byte-equivalent to the old v650 gate, on purpose (the v667 header explains why: it wanted no
-- caller that worked before v667 to stop working). But every other authority over this same
-- capability has moved on since v650 and none of them agrees with it any more:
--
--   * the client (app/app-core.js) puts 'customerintel' in FINANCE_MODULES and roleCanUseModule
--     requires view_finance for anything in that set -- a role without view_finance never even
--     shows the module;
--   * nestly_v573 gates public.get_revenue_truth_v106, the actual number this capability reports,
--     on app.has_perm(business,'view_finance') AND app.can_module(business,'customerintel');
--   * nestly_v523 (owner ruling 2026-08-26) rewrote app.staff_module_perms_at_v115 so that
--     'customerintel' resolves 'r'/'rw' only for a role holding view_finance, specifically so
--     that "a module visible in the rail" would not be "one that fails on open" -- the two
--     authorities were made to say the same thing on that day.
--
-- The server gate is the odd one out, and it is the LOOSER one, not the stricter one: it admits
-- any member holding the ordinary 'reports' module, which every enabled-modules role gets
-- (app.role_perms never withholds 'reports' itself; view_finance is a separate permission layered
-- on top). 'customerintel' can additionally be granted per-staff through staff.modules /
-- staff.module_perms, which app.can_module reads directly -- it never consults app.role_perms or
-- app.has_perm -- so a frontdesk or staff member holding that per-staff grant but no view_finance
-- permission reached every CI reader through the old gate. That is a caller every other authority
-- in this codebase (the client, v573, v523) already refuses.
--
-- THE FIX. Change exactly the merchant arm's two conjuncts to three:
--
--     app.is_salon_member(p_business)
--       and app.can_module(p_business, 'customerintel')
--       and app.has_perm(p_business, 'view_finance')
--
-- 'reports' becomes 'customerintel' (the module this capability actually is, matching v523's own
-- staff_module_perms_at_v115 change and v573's gate on get_revenue_truth_v106) and view_finance is
-- required explicitly rather than assumed, because app.can_module does not check it. The platform
-- arm (app.v176_can_read_firm_report -- super admin or assigned consultant) and the
-- branch-ownership validation below it are untouched: neither authority above says anything about
-- the platform path, and nothing in the gap concerns branch scope.
--
-- MINIMALITY. Proven mechanically, the v668 pattern: capture app.ci_access_gate_v667's live body
-- with pg_get_functiondef before this migration touches it, assert the exact merchant-arm clause
-- is present in the expected shape, then after the replace assert the new body equals the old one
-- with that clause (and its accompanying doc-comment note) substituted for the new ones and
-- nothing else moved. Any other drift rolls the migration back rather than silently widening or
-- narrowing something this migration was not about.
--
-- ACL: restated verbatim. app.ci_access_gate_v667 has never been callable by anon or
-- authenticated -- every caller reaches it only through the six SECURITY DEFINER readers it gates.
--
-- PROVEN BY: db/tests/executed/v667_ci_access_boundaries.sql. B1 (firm A's owner, who under this
-- migration must hold customerintel AND view_finance to be admitted -- both true for that fixture
-- role, now that firm A's enabled_modules carries 'customerintel') still passes; B1b is unchanged
-- (a member with neither module was always refused). B1c is new -- a member who holds
-- 'customerintel' in their per-staff allowlist but whose ROLE does not carry view_finance must
-- still be refused with 42501, which is exactly the caller this migration closes.
--
-- ROLLBACK: re-apply the v667-shape merchant arm, i.e. restore 'reports' in place of
-- 'customerintel' and drop the view_finance conjunct (and the v689 doc-comment note). The block
-- below prints the pre-change definition into a temp table for exactly that purpose.

begin;

-- ---------------------------------------------------------------------------
-- 1 . Capture the live definition, and refuse to run against a shape we do not
--     recognise. A silent no-op here would look exactly like a successful fix.
-- ---------------------------------------------------------------------------
create temp table _v689_before(def text) on commit drop;

do $pre$
declare v_n integer;
begin
  insert into _v689_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app'
     and p.proname = 'ci_access_gate_v667';

  select count(*) into v_n from _v689_before;
  if v_n <> 1 then
    raise exception 'v689: expected exactly one app.ci_access_gate_v667, found %', v_n;
  end if;

  if position($qz$          or (app.is_salon_member(p_business)                          -- merchant: exactly the v650 path
              and app.can_module(p_business, 'reports'))$qz$ in (select def from _v689_before)) = 0 then
    raise exception
      'v689: the reports-gated merchant arm is not present in the expected shape -- stop and '
      're-read before shipping';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 2 . The same function, with the merchant arm's two conjuncts widened to
--     three, and nothing else moved.
-- ---------------------------------------------------------------------------
create or replace function app.ci_access_gate_v667(p_business uuid, p_branch uuid default null)
returns void
language plpgsql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  /* A UNION, deliberately, because two authorities are both live and they disagree:
       - docs/product/PRODUCT-TRUTH.md:228 (written 2026-08-02) calls Customer Intelligence a
         platform/consulting capability and not a self-service owner module;
       - nestly_v523 (2026-08-26, TWENTY-FOUR DAYS LATER) records an owner ruling that the
         module "follows entitlement again" and removed the hand-placed override so it would
         "resolve exactly like every other one".
     The later ruling should win, but PRODUCT-TRUTH has not been updated to match and the
     v523 ruling is NOT actually in force (see the note below). Picking either side alone
     would silently overrule an owner; admitting both regresses nobody and leaves the
     decision where it belongs. The merchant arm is byte-equivalent to the v650 gate, so no
     caller that worked before this migration stops working.

     WHAT THIS MIGRATION DOES NOT FIX, on purpose: v523 removed the override from
     app.staff_module_perms_at_v115 but NOT from app.effective_platform_module_mode_v94,
     which still answers 'disabled' / 'global_platform_only_policy' for 'customerintel'.
     v537 then re-pointed the capability gate at that resolver. Net effect today:
     app.can_module(b,'customerintel') is false for EVERY caller including an entitled
     owner, so the owner's 2026-08-26 ruling never took effect, and v573's gating of
     public.get_revenue_truth_v106 on that module makes revenue truth unreachable for every
     merchant role. Completing v523 changes what merchants can see and is an owner decision,
     not a defect fix to fold into an access-boundary migration. Recorded, not fixed.

     v689: the note above is now history, not a live gap — nestly_v668 completed v523's
     resolver-side fix, so app.can_module(b,'customerintel') means what v523 always said it
     would. That made the merchant arm's remaining looseness visible: it was still asking for
     'reports', a module every role gets, instead of 'customerintel' with the view_finance
     permission the client (FINANCE_MODULES / roleCanUseModule), v573's revenue-truth gate and
     v523's own staff_module_perms_at_v115 all already require. app.can_module reads
     staff.modules / staff.module_perms directly and never consults app.role_perms, so a
     'reports'-only test left a per-staff customerintel grant unguarded by any finance
     permission at all. Fixed here; see docs/qa/CI-REASSESSMENT-2026-09-01.md, check 91. */
  if auth.uid() is null
     or not (
          app.v176_can_read_firm_report(p_business)                    -- platform: SA or assigned consultant
          or (app.is_salon_member(p_business)                          -- merchant: v689 -- customerintel + view_finance
              and app.can_module(p_business, 'customerintel')
              and app.has_perm(p_business, 'view_finance'))
        ) then
    raise exception 'customer intelligence access is required'
      using errcode = '42501';
  end if;
  -- A branch that is not this firm's is refused, never ignored.
  if p_branch is not null
     and not exists (select 1 from public.branches br
                      where br.id = p_branch and br.business_id = p_business) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
end;
$$;
revoke all on function app.ci_access_gate_v667(uuid,uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3 . Prove the diff is the diff that was intended.
-- ---------------------------------------------------------------------------
do $post$
declare
  v_before   text;
  v_after    text;
  v_expected text;
  -- The exact clause being replaced, as it stands in the live body (v667).
  v_clause constant text := $qa$          or (app.is_salon_member(p_business)                          -- merchant: exactly the v650 path
              and app.can_module(p_business, 'reports'))$qa$;
  -- And the clause that takes its place, character for character with section 2.
  v_replacement constant text := $qb$          or (app.is_salon_member(p_business)                          -- merchant: v689 -- customerintel + view_finance
              and app.can_module(p_business, 'customerintel')
              and app.has_perm(p_business, 'view_finance'))$qb$;
  -- The doc-comment anchor inside the function body's leading comment block.
  v_note_before constant text := $qc$     not a defect fix to fold into an access-boundary migration. Recorded, not fixed. */$qc$;
  -- The same anchor plus the v689 note, present only in the new definition.
  v_note_after constant text := $qd$     not a defect fix to fold into an access-boundary migration. Recorded, not fixed.

     v689: the note above is now history, not a live gap — nestly_v668 completed v523's
     resolver-side fix, so app.can_module(b,'customerintel') means what v523 always said it
     would. That made the merchant arm's remaining looseness visible: it was still asking for
     'reports', a module every role gets, instead of 'customerintel' with the view_finance
     permission the client (FINANCE_MODULES / roleCanUseModule), v573's revenue-truth gate and
     v523's own staff_module_perms_at_v115 all already require. app.can_module reads
     staff.modules / staff.module_perms directly and never consults app.role_perms, so a
     'reports'-only test left a per-staff customerintel grant unguarded by any finance
     permission at all. Fixed here; see docs/qa/CI-REASSESSMENT-2026-09-01.md, check 91. */$qd$;
begin
  select def into v_before from _v689_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app'
     and p.proname = 'ci_access_gate_v667';

  if position(v_clause in v_before) = 0 then
    raise exception
      'v689: the merchant-arm clause was not found in the live body in the expected shape; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;
  if position(v_note_before in v_before) = 0 then
    raise exception
      'v689: the comment anchor was not found in the live body in the expected shape; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;

  v_expected := replace(replace(v_before, v_note_before, v_note_after), v_clause, v_replacement);

  if v_after <> v_expected then
    raise exception
      'v689: the new definition differs from the old one by more than the merchant arm and its '
      'doc note -- the platform arm and branch validation must not move. Old:%  %New:%  %',
      E'\n', v_expected, E'\n', v_after;
  end if;

  -- The old two-conjunct clause is gone from the CODE.
  if position(v_clause in v_after) > 0 then
    raise exception 'v689: the reports-gated merchant arm did not clear';
  end if;
end
$post$;

commit;
