-- nestly_v495 — a stopped programme's gifts are no longer OFFERED to the customer
-- (owner, photos A-E, 2026-08-24: "photo A shows 2 rewards but i am standing at 0 points";
--  "photo B shows 5 stamps required — but it is points/tier on and stamps reward is switched
--  off"; "photo E: when tries to redeem available rewards it shows not available. if not
--  available it should not be here in the first place". Sol review bypassed on the owner's
--  explicit instruction.)
--
-- THE CONTRADICTION, located: the customer redemption intent
-- (customer_create_redemption_intent_v89) contains the explicit law
--     if not exists(... spine.id = v_intent_programme and spine.active) then
--       raise exception 'this reward''s programme is not running right now'
-- while app.reward_availability_v432 LISTED those same gifts through two escapes:
--   * the final filter's rescue clause
--       or (rows.source = 'stamp_card' and rows.availability = 'available_at_counter')
--     which admitted an OPEN card's gifts on a stopped stamps programme, and
--   * the survivor arm's hardcoded `true as programme_active`, which admitted survivors of
--     CLOSED cycles regardless of the spine.
-- So the catalogue said "Ready to claim" with a Show QR button, the intent refused with
-- 'this reward''s programme is not running right now', and the customer met the toast in
-- photo E. The intent path is the law — it is what actually settles value — so availability
-- now states exactly what it will accept.
--
-- Every reader inherits the fix through the one function: customer_get_reward_catalog (the
-- wallet list and hero swipe), customer_get_business_actions_v89 (the Claim button),
-- app.customer_ready_reward_count_v465 (the "N rewards ready" pill and Home count),
-- customer_get_stamp_card_v323, and staff_get_customer_actionable_loyalty_v145 (the till's
-- actionable panel) — verified as the complete caller set against production before writing.
--
-- WHAT IS DELIBERATELY UNCHANGED:
--   * A RUNNING programme behaves exactly as before — open-card gifts, v464 expiry survivors
--     and v489 rollover survivors all keep listing, because the spine gate passes. Proven on
--     QA Kaya Toast (stamps ON): all three milestones still available_at_counter after apply.
--   * Nothing is destroyed by a stop: stamps are retained while a programme is off (the wallet
--     already says so) and every gift returns the moment the programme is switched back on.
--   * app.redeem_reward_core (the staff-assisted path) is untouched.
--
-- Patched in place: the live definition is read, both anchors asserted (verified unique
-- against production first), replaced, re-executed. A later rewrite of either clause aborts
-- this migration instead of silently shipping half of it.

begin;

do $do$
declare
  v_src text;
  v_old_arm2 constant text := 'true as programme_active';
  v_new_arm2 constant text := 'coalesce((select ss.active from stamps_spine ss), false) as programme_active';
  v_old_filter constant text := 'or (rows.source = ''stamp_card'' and rows.availability = ''available_at_counter'')';
  v_new_filter constant text := '-- v495: the rescue for a stopped programme''s open card is withdrawn; the intent path refuses those gifts, and a listed reward the counter refuses is worse than none';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432' limit 1;
  if v_src is null then
    raise exception 'v495: app.reward_availability_v432 not found' using errcode = 'XX001';
  end if;
  if position(v_old_arm2 in v_src) = 0 or position(v_old_filter in v_src) = 0 then
    raise exception 'v495: reward_availability_v432 no longer matches its expected shape; '
      'refusing to ship a half-patched availability filter' using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old_arm2, v_new_arm2);
  v_src := replace(v_src, v_old_filter, v_new_filter);
  execute v_src;
end
$do$;

revoke all on function app.reward_availability_v432(uuid, uuid, timestamp with time zone) from public, anon, authenticated;

commit;
