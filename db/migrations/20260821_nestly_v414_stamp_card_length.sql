-- nestly_v414 — the stamp card the owner sets is the stamp card the customer gets.
--
-- OWNER, 2026-08-21 (photo 2). The whole "Stamp reward levels" table struck through and replaced
-- by a drawing of the card itself: fifteen numbered circles with gifts on 5, 10 and 15, a "+" to
-- carry on, a "settings" bubble, "can edit to have gifts every 5 stamps or every other number of
-- stamps", and "then click pop-up to design reward, add reward photo / etc".
-- Owner rulings on the follow-up questions: the card RESETS and the same gifts come round again
-- ("but I want to have an option to add more gifts if I want to. so moving forward will be based
-- on the new settings"), there is NO second page, and the default is one gift every 5 stamps with
-- the firm free to add, edit or delete a gift at any stamp number.
--
-- The looping half of that ruling ALREADY WORKS and is deliberately untouched: public.stamp_cycles
-- closes a cycle when the final milestone is claimed, app.stamp_progress_v323 reports
-- `filled = net - closed`, and the milestone list is read live, so the next round of the card
-- follows whatever the owner has since changed. Nothing about cycling needed building.
--
-- Building the editor the owner drew surfaced two server faults underneath it. Both are fixed
-- here because they are the same story from two sides: what the Stamp Card page shows the owner
-- is not what the engine and the customer app actually use.

begin;

-- ------------------------------------------------------------------------------------------
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO, AND WHY. (Reported to the owner as a question.)
-- ------------------------------------------------------------------------------------------
-- Building the editor surfaced a second fault: business_update_reward_v326 writes only
-- public.loyalty_rewards, while the customer's card and the claim path read a gift's NAME and
-- COST off public.loyalty_reward_versions, joined on businesses.active_config_version_id:
--     customer_get_stamp_card_v323 -> join public.loyalty_reward_versions rv
--                                       on rv.config_version_id = b.active_config_version_id
--     app.redeem_reward_core       -> select rv.* into v_version from public.loyalty_reward_versions rv
--                                       join public.businesses b on b.active_config_version_id = rv.config_version_id
-- Cubbly SPA shows the consequence today: "Free Lotion" reads 10 stamps in the editor and 5 in
-- the version row the customer's card is built from.
--
-- The obvious fix — mirror the edit onto the active version row — was WRITTEN, RUN against
-- production inside a rolled-back transaction, AND REJECTED BY THE DATABASE:
--     ERROR 23001 published reward configuration is immutable
--     CONTEXT app.reward_version_immutable_guard() ... BEFORE DELETE OR UPDATE
--             ON public.loyalty_reward_versions
-- That guard is deliberate, not an obstacle: a published version row is a frozen catalogue entry,
-- and business_delete_reward_v326 says so in its own comment — it syncs only an OPEN DRAFT's row
-- and notes that the redeem paths read active/paused off loyalty_rewards directly. So mutable
-- state (active, paused) lives on the live row by design, while the PRICE and NAME a customer was
-- shown are frozen with the version that published them.
--
-- Making an inline edit reach customers therefore means publishing a new config version, not
-- writing over a published one — a change to how this whole surface works, and a product decision
-- about whether a firm may re-price a gift a customer is already part-way to earning. That is the
-- owner's call, so nothing here touches it, and no row is backfilled: healing Cubbly's gift to 10
-- stamps on a card whose stamp_target is 5 would make it UNCLAIMABLE where today it is claimable
-- at 5. Part 2's guard reads the VERSION's cost_points precisely because that is the number
-- app.redeem_reward_core compares against.

-- ============================================================================================
-- 2. THE CARD HAD NO LENGTH THE OWNER COULD SET.
-- ============================================================================================
-- loyalty_programs.stamp_target IS the card length: app.stamp_progress_v323 returns it as `slots`,
-- and app.redeem_reward_core refuses a claim outright —
--     if v_version.cost_points > v_stamp_slots then
--       raise exception 'this gift sits past the end of the stamp card'
-- — as well as closing the cycle once a claim lands at or beyond it.
--
-- Only the SETUP WIZARD ever wrote stamp_target (derived from the last milestone at publish time,
-- frenly v322 R5). The Stamp Card page, where a firm actually adds a level day to day, calls
-- business_create_reward_v326 and never touches the target. A level added there past the current
-- length is created, listed, previewed, counted — and can never be claimed by anybody.
--
-- A NEW function rather than three more parameters on business_set_earning_rule_v359, because
-- adding a parameter creates a SECOND function keyed on the new argument list rather than
-- replacing the first — which is exactly how v378/v379 produced the twin overloads that took
-- every promotion save down until nestly_v410 dropped them. One name, one signature, no overload.
--
-- IT REFUSES TO STRAND A GIFT. Shortening the card below a live gift recreates the bug above from
-- the other direction, so the shrink is refused and the gift in the way is NAMED. Lengthening is
-- always allowed: it can only make an unreachable gift reachable. Nothing here edits, moves or
-- deletes a gift — what to do with the one named is the caller's decision.

create or replace function public.business_set_stamp_card_length_v414(
  p_business uuid, p_stamps integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_spine uuid;
  v_blocker record;
  v_row public.loyalty_programs%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_stamps is null or p_stamps < 1 or p_stamps > 100 then
    raise exception 'a stamp card must be between 1 and 100 stamps long' using errcode='22023';
  end if;

  select id into v_spine from public.business_programmes
   where business_id = p_business and kind = 'stamps';
  if v_spine is null then
    raise exception 'this business is not running a stamp card' using errcode='XX001';
  end if;

  /* The redeemability test app.redeem_reward_core itself applies, asked BEFORE the write rather
     than after a customer is standing at the counter. It reads the VERSION row joined to the
     firm's active config version — the same row the claim path resolves — because that, and not
     loyalty_rewards.cost_points, is the number the refusal compares against. */
  select rv.customer_name as name, rv.cost_points as stamps into v_blocker
    from public.loyalty_reward_versions rv
    join public.businesses b on b.active_config_version_id = rv.config_version_id
    join public.loyalty_rewards r on r.id = rv.reward_id
   where rv.business_id = p_business
     and rv.programme_id = v_spine
     and coalesce(rv.active, true)
     and coalesce(r.active, true)
     and not coalesce(r.paused, false)
     and rv.cost_points > p_stamps
   order by rv.cost_points desc
   limit 1;
  if found then
    raise exception '% needs % stamps, so a % stamp card would put it out of reach. Move or remove that gift first.',
      coalesce(v_blocker.name,'A gift'), v_blocker.stamps, p_stamps
      using errcode='23514';
  end if;

  update public.loyalty_programs
     set stamp_target = p_stamps
   where business_id = p_business
  returning * into v_row;
  if not found then
    raise exception 'this business has no loyalty programme row' using errcode='XX001';
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'stamp_card.length_set', 'loyalty_programs', p_business,
    jsonb_build_object('stamp_target', v_row.stamp_target));

  return jsonb_build_object('status','ok','stamp_target', v_row.stamp_target);
end $$;

revoke all on function public.business_set_stamp_card_length_v414(uuid,integer) from public, anon;
grant execute on function public.business_set_stamp_card_length_v414(uuid,integer) to authenticated;

comment on function public.business_set_stamp_card_length_v414(uuid,integer) is
  'v414: set the stamp card length (loyalty_programs.stamp_target) from the Stamp Card page. '
  'Refuses a length that would put a live gift past the end of the card, which '
  'app.redeem_reward_core rejects at claim time.';

commit;
