-- nestly_v474 — staff and customer read the same stamp number.
--
-- OWNER, 2026-08-23: "why it shows 15 stamps in record sale but customer view shows 5 out of 10
-- stamps? it is way too messy. I need it to standardise"
--
-- Both numbers were true and neither was a bug. They are different QUANTITIES wearing the same
-- word:
--   * Record sale said "15 stamps" — lookup_client_by_phone -> app.client_points_balance_v409,
--     the programme POT: every stamp ever earned minus redemptions.
--   * The customer said "5 of 10" — app.stamp_progress_v323, position on THE CARD IN THEIR HAND:
--     15 earned minus 10 already consumed by a completed card, on a 10-slot card.
--
-- Traced on the owner's own customer (Steven Lim at QA Kopi Lab): pot 15, closed_slots 10,
-- filled 5, slots 10. Exactly the two figures in the screenshots.
--
-- THE STANDARD: the customer's card wins. Staff and customer talk across a counter, so the
-- number staff quote has to be the number on the customer's phone. Neither staff read knew the
-- stamp card existed — staff_get_customer_actionable_loyalty_v145 returns points_balance and
-- lookup_client_by_phone returns points, and both are the pot. They now carry the card beside it.
--
-- WHAT IS DELIBERATELY NOT DONE:
--   * The pot is not removed and points_balance/points do not change meaning. They are the
--     ledger balance, they are what redemption arithmetic is done against, and several callers
--     read them. This ADDS the card; it does not redefine the balance. The browser chooses which
--     to print, and the pot survives in the payload as stamp_card.pot for anywhere that genuinely
--     wants a lifetime figure — the receipt's "Total stamps earned to date" is one.
--   * Points businesses are untouched: stamp_card is null unless the live model is stamps, and
--     for points the pot IS the balance the customer sees, so there was never a discrepancy.
--   * No new RPC. Adding a third read that staff have to call in step with the other two is how
--     surfaces drift apart in the first place; the two reads that already answer "where does this
--     customer stand" answer it completely now.
--
-- BOTH FUNCTIONS ARE PATCHED IN PLACE rather than restated. staff_get_customer_actionable_loyalty_v145
-- is a ~7.9KB CTE chain this change touches one line of, and restating it here would make this
-- migration the authority on 200 lines it has no opinion about. Each patch asserts its own marker
-- and aborts if the source has moved, so a silent no-op is impossible.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. THE CUSTOMER PROFILE'S READ.
--
-- The card is resolved by a correlated subquery over app.stamp_progress_v323, which is the SAME
-- function customer_get_stamp_card_v323 serves the customer from — so the two surfaces cannot
-- report different positions on the same card. It is STABLE and SECURITY DEFINER, and this caller
-- is SECURITY DEFINER too, so no grant changes.
--
-- `filled` is clamped into the card the way the customer's own renderer clamps it, and the
-- overflow is published separately as `carried` rather than being thrown away: a customer holding
-- more stamps than one card can show is a real state (it is what the customer app's "N already
-- counted toward your next card" line says), and staff being unable to see it would be a new
-- discrepancy in place of the one this migration closes.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    'points_balance', loyalty_balance.units,$marker$;
  v_new constant text := $marker$    'points_balance', loyalty_balance.units,
    -- nestly_v474: the card the customer is holding, from the same function their own app reads.
    -- Null unless this firm actually runs stamps, so a points firm is byte-identical to before.
    'stamp_card', (
      select case when program.loyalty_model = 'stamps' and coalesce(sp.slots,0) > 0
        then jsonb_build_object(
          'slots',   sp.slots,
          'filled',  least(greatest(coalesce(sp.filled,0),0), sp.slots),
          'carried', greatest(coalesce(sp.filled,0) - sp.slots, 0),
          'ready',   sp.ready,
          'pot',     sp.net_stamps)
        else null end
      from app.stamp_progress_v323(p_business, p_client) sp),$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_get_customer_actionable_loyalty_v145';
  if v_src is null then
    raise exception 'staff_get_customer_actionable_loyalty_v145 is missing' using errcode='42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'staff_get_customer_actionable_loyalty_v145 no longer has the points_balance line this migration patches'
      using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- ---------------------------------------------------------------------------------------------
-- 2. THE TILL'S READ.
--
-- Same object, same shape, json rather than jsonb only because this function returns json and its
-- payload is assembled with json_build_object. `c` is the clients row the function has already
-- selected, and `lp` the active loyalty_programs row it has already read — no extra lookups.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    'points',v_points,'credit_cents',v_credit,'visits',v_visits,$marker$;
  v_new constant text := $marker$    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'stamp_card',(
      select case when lp.loyalty_model = 'stamps' and coalesce(sp.slots,0) > 0
        then json_build_object(
          'slots',   sp.slots,
          'filled',  least(greatest(coalesce(sp.filled,0),0), sp.slots),
          'carried', greatest(coalesce(sp.filled,0) - sp.slots, 0),
          'ready',   sp.ready,
          'pot',     sp.net_stamps)
        else null end
      from app.stamp_progress_v323(p_business, c.id) sp),$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'lookup_client_by_phone';
  if v_src is null then
    raise exception 'lookup_client_by_phone is missing' using errcode='42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'lookup_client_by_phone no longer has the points line this migration patches'
      using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- Signatures unchanged, so CREATE OR REPLACE (via the patched definition) preserved the grants.
-- Restated from the live proacl per the repo's preflight rule.
revoke all on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) to authenticated, service_role;
revoke all on function public.lookup_client_by_phone(uuid,text) from public, anon;
grant execute on function public.lookup_client_by_phone(uuid,text) to authenticated, service_role;

commit;
