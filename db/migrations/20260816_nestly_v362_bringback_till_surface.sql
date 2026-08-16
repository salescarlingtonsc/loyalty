-- V362: surface a held bring-back voucher at the till.
--
-- V361 built the module: campaigns, the nightly issue sweep, grants, and
-- public.staff_redeem_bringback_v361. What it did NOT do is tell the till a voucher exists — so a
-- customer could hold one and no member of staff would ever see it. This closes that.
--
-- It extends public.staff_get_customer_entitlements_v102, which is the ONE read the till already
-- makes for a looked-up customer (it is where packages, vouchers and the v215 welcome offer all
-- ride). Adding a second round-trip for this would be a second thing to keep in sync.
--
-- The patch technique is v215's own, verbatim in spirit: read the live function definition, splice
-- in the new declare + return, and re-execute it. It is guarded three ways — a no-op if the key is
-- already present (idempotent re-run), a raise if either anchor is missing (so a drifted function
-- fails loudly instead of being silently left unpatched), and a post-check that proves the change
-- landed rather than trusting the replace.
--
-- Only ONE grant is returned, the oldest live one, matching how v215 returns a single welcome
-- offer: the till shows one free item at a time, and staff_redeem_bringback_v361 re-checks
-- everything anyway (expiry, ownership, branch, already-redeemed) so this read is a hint, never
-- the authority.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run first; see VERIFICATION below).

do $hook$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'staff_get_customer_entitlements_v102';
  if d is null then
    raise exception 'v362: staff_get_customer_entitlements_v102 not found';
  end if;

  if position('bringback_grants_v361' in d) = 0 then
    n := replace(d, E'\ndeclare\n', E'\ndeclare\n  v_bringback jsonb;\n');
    if n = d then raise exception 'v362: entitlements declare anchor not found'; end if;
    d := n;

    -- NB: the live return is split across TWO lines (v215's own splice left it that way), so the
    -- anchor must match the wrapped form. A single-line anchor raised "return anchor not found" on
    -- the first dry run — which is exactly what the guard is for: it failed loudly instead of
    -- leaving the function silently unpatched.
    n := replace(d,
      E'return jsonb_build_object(''packages'',v_packages,''vouchers'',v_vouchers,\n    ''welcome_offer'',v_welcome);',
      'select jsonb_build_object('
      ||'''grant_id'',bb.id,'
      ||'''reward_label'',bb.reward_label,'
      ||'''away_days'',bb.away_days,'
      ||'''expires_at'',bb.expires_at) into v_bringback '
      ||'from public.bringback_grants_v361 bb '
      ||'where bb.business_id=p_business and bb.client_id=p_client '
      ||'and bb.status=''granted'' '
      ||'and (bb.expires_at is null or bb.expires_at>now()) '
      ||'order by bb.granted_at limit 1; '
      ||'return jsonb_build_object(''packages'',v_packages,''vouchers'',v_vouchers,''welcome_offer'',v_welcome,''bringback_offer'',v_bringback);');
    if n = d then raise exception 'v362: entitlements return anchor not found'; end if;
    execute n;
  end if;

  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = 'staff_get_customer_entitlements_v102'
         and position('bringback_grants_v361' in pg_get_functiondef(p.oid)) > 0) <> 1 then
    raise exception 'v362: entitlements patch did not land';
  end if;
end $hook$;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod:
--   1. before the patch the entitlements payload has no 'bringback_offer' key; after it, the key
--      is present and null for a customer holding no voucher.
--   2. with a granted voucher issued to a real Cubbly client, the payload returns that grant's
--      id/reward_label/away_days/expires_at.
--   3. the existing 'packages', 'vouchers' and 'welcome_offer' keys are unchanged in the same
--      payload — the splice adds a key, it does not rewrite the others.
--   4. re-running the whole DO block is a no-op (the position() guard), so this migration is
--      idempotent.
