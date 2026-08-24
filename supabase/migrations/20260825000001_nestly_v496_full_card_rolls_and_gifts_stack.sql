-- nestly_v496 — a full stamp card rolls the moment its owner looks at it, and earned gifts STACK
-- (owner, photos 1 + 2, 2026-08-25: "when 15 stamps are accumulated - the customer should see the
--  new card (fresh 15 empty stamp card)"; "the rewards that have yet to claim must stay in
--  customer reward - until it expires if any"; "if there are any unused rewards, when there are
--  more stamps coming in and the same rewards is achieved, it should show quantity = 2 - and able
--  to redeem twice ... able to stack". Sol review bypassed on the owner's explicit instruction.)
--
-- WHAT v489 LEFT OPEN. v489's rollover fires from an AFTER INSERT trigger on public.sales — the
-- next sale rolls the card. But the owner's photo 1 is the gap: Devi M sits on 17 stamps against
-- a 15-slot card with NO new sale, so the customer stares at the old full card until they next
-- buy. Nothing else was wrong — the close itself (app.stamp_complete_full_cycle_v489) is correct
-- and idempotent. So this migration adds the missing TRIGGER MOMENT, not a second engine:
-- public.customer_rollover_full_stamp_card_v496 is a customer-callable door onto the same v489
-- close, invoked by the wallet the moment it draws a full card. Every guard is the engine's own:
-- the v480 shared lock, the ON CONFLICT idempotency, the pinned-config requirement.
--
-- STACKING, and where it was broken twice:
--   * app.reward_availability_v432 ranked every instance of a reward and then kept ONE row
--     (partition by reward_id ... rn = 1). A gift earned on the closed card AND again on the open
--     one showed once. The function gains a `quantity` column — the count of instances that are
--     'available_at_counter' across the open card and every closed-cycle survivor — appended LAST
--     so the five callers, all of which read named columns (verified against production), keep
--     their meaning. Return-type change forces DROP + CREATE; the ACL is restated after.
--   * app.redeem_reward_core preferred the CURRENT cycle whenever the open card's filled count
--     covered the slot — even when that cycle's claim already existed — so a second redemption of
--     a stacked gift died on the unique violation ("already been claimed on this card") instead
--     of falling through to the survivor instance. The current-cycle path now stands aside when
--     its claim row exists. And the survivor pick flips DESC→ASC: with stacking real, the oldest
--     instance is consumed first, because under the v464 rule it is the one that expires first.
--   * app.customer_ready_reward_count_v465 counted DISTINCT rewards; the pill now sums quantity
--     so "N rewards ready" and the wallet's Available list agree about instances. choose_one is
--     deliberately untouched: two instances of the SAME gift are not a choice between gifts.
--   * public.customer_get_reward_catalog passes quantity through to the wallet.
--
-- Patched in place: each live definition is read, its anchors asserted (verified unique against
-- production first), replaced, re-executed. A later rewrite of any clause aborts this migration
-- instead of silently shipping part of it.

begin;

-- ============================================================================================
-- 1. app.reward_availability_v432 learns `quantity` (instances claimable now, per reward)
-- ============================================================================================

do $do$
declare
  v_src text;
  v_old_returns constant text := 'reward_expires_at timestamp with time zone, availability text)';
  v_new_returns constant text := 'reward_expires_at timestamp with time zone, availability text, quantity integer)';
  v_old_outer constant text := 'ranked.reward_expires_at,
         ranked.availability
  from (';
  v_new_outer constant text := 'ranked.reward_expires_at,
         ranked.availability, ranked.quantity
  from (';
  v_old_window constant text := ') as rn
    from (';
  v_new_window constant text := ') as rn,
      sum(case when rows.availability = $q$available_at_counter$q$ then 1 else 0 end)
        over (partition by rows.reward_id)::integer as quantity
    from (';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432' limit 1;
  if v_src is null then
    raise exception 'v496: app.reward_availability_v432 not found' using errcode = 'XX001';
  end if;
  if position(v_old_returns in v_src) = 0
     or position(v_old_outer in v_src) = 0
     or position(v_old_window in v_src) = 0 then
    raise exception 'v496: reward_availability_v432 no longer matches its expected shape; '
      'refusing to ship half a quantity column' using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old_returns, v_new_returns);
  v_src := replace(v_src, v_old_outer, v_new_outer);
  v_src := replace(v_src, v_old_window,
    replace(v_new_window, '$q$available_at_counter$q$', '''available_at_counter'''));
  -- The return type grows, so CREATE OR REPLACE would refuse; the DROP fails loud if any hard
  -- dependency (a view) has appeared since the caller inventory was taken.
  drop function app.reward_availability_v432(uuid, uuid, timestamp with time zone);
  execute v_src;
end
$do$;

-- The DROP discarded the old ACL and CREATE granted PUBLIC by default; restate owner-only.
revoke all on function app.reward_availability_v432(uuid, uuid, timestamp with time zone) from public, anon, authenticated;

-- ============================================================================================
-- 2. app.redeem_reward_core — a claimed current-cycle instance stands aside for a survivor,
--    and survivors are consumed oldest-first (they expire first under v464)
-- ============================================================================================

do $do$
declare
  v_src text;
  v_old_ok constant text := 'and v_version.cost_points<=v_stamp_slots and v_stamp_filled>=v_version.cost_points;';
  v_new_ok constant text := 'and v_version.cost_points<=v_stamp_slots and v_stamp_filled>=v_version.cost_points;
    -- v496: an instance already claimed on THIS cycle must not shadow a survivor instance on a
    -- closed one — without this, the second redemption of a stacked gift dies on the unique
    -- violation instead of reaching the survivor path below.
    if v_current_ok and exists (select 1 from public.stamp_milestone_claims claim
        where claim.business_id=p_business and claim.client_id=p_client
          and claim.programme_id=v_reward.programme_id
          and claim.cycle_index=v_cycle_index and claim.reward_id=p_reward) then
      v_current_ok := false;
    end if;';
  v_old_pick constant text := 'order by sc.cycle_index desc limit 1;';
  v_new_pick constant text := 'order by sc.cycle_index asc limit 1;';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core' limit 1;
  if v_src is null then
    raise exception 'v496: app.redeem_reward_core not found' using errcode = 'XX001';
  end if;
  if position(v_old_ok in v_src) = 0 or position(v_old_pick in v_src) = 0 then
    raise exception 'v496: redeem_reward_core no longer matches its expected shape; '
      'refusing to ship stacking whose second redemption cannot settle' using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old_ok, v_new_ok);
  v_src := replace(v_src, v_old_pick, v_new_pick);
  execute v_src;
end
$do$;

-- ============================================================================================
-- 3. app.customer_ready_reward_count_v465 counts INSTANCES, not distinct rewards
-- ============================================================================================

do $do$
declare
  v_src text;
  v_old_cols constant text := 'select core.cost_points, core.unit';
  v_new_cols constant text := 'select core.cost_points, core.unit, core.quantity';
  v_old_count constant text := 'select (select count(*)::integer from claimable),';
  v_new_count constant text := 'select (select coalesce(sum(claimable.quantity), 0)::integer from claimable),';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'customer_ready_reward_count_v465' limit 1;
  if v_src is null then
    raise exception 'v496: app.customer_ready_reward_count_v465 not found' using errcode = 'XX001';
  end if;
  if position(v_old_cols in v_src) = 0 or position(v_old_count in v_src) = 0 then
    raise exception 'v496: customer_ready_reward_count_v465 no longer matches its expected shape'
      using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old_cols, v_new_cols);
  v_src := replace(v_src, v_old_count, v_new_count);
  execute v_src;
end
$do$;

-- ============================================================================================
-- 4. public.customer_get_reward_catalog carries quantity to the wallet
-- ============================================================================================

do $do$
declare
  v_src text;
  v_old constant text := '''availability'', core.availability,';
  v_new constant text := '''availability'', core.availability,
    ''quantity'', core.quantity,';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog' limit 1;
  if v_src is null then
    raise exception 'v496: public.customer_get_reward_catalog not found' using errcode = 'XX001';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'v496: customer_get_reward_catalog no longer matches its expected shape'
      using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old, v_new);
  execute v_src;
end
$do$;

-- ============================================================================================
-- 5. The customer's door onto the v489 close — called by the wallet when it draws a full card
-- ============================================================================================

create or replace function public.customer_rollover_full_stamp_card_v496(p_business_slug text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_prog record;
  v_rolled integer := 0;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  -- The engine's own guards do all the work: the v480 shared lock, the full-card check, the
  -- pinned-config requirement and the ON CONFLICT idempotency. A card that is not full returns
  -- rolled=0 after one progress read; a replay closes nothing twice.
  for v_prog in
    select spine.id
      from public.business_programmes spine
     where spine.business_id = v_context.business_id
       and spine.active
       and spine.kind = 'stamps'
     order by spine.sort, spine.id
  loop
    v_rolled := v_rolled
      + coalesce(app.stamp_complete_full_cycle_v489(v_context.business_id, v_context.client_id, v_prog.id), 0);
  end loop;
  return jsonb_build_object('rolled', v_rolled);
end;
$function$;

revoke all on function public.customer_rollover_full_stamp_card_v496(text) from public, anon;
grant execute on function public.customer_rollover_full_stamp_card_v496(text) to authenticated;

commit;
