-- nestly_v475 — the stamp card stops advertising a gift the counter refuses.
--
-- Found while answering the owner's "why the stamp card portion is not scrollable? ... my next
-- rewards is number 7" (2026-08-23). Their card showed a gift badge on stamp 7 and the caption
-- "Next available Reward: Free Espresso Shot" — for a gift whose loyalty_rewards row is
-- active=false. The catalogue, the reward list and the till all correctly refuse it; only the
-- crowns card still promised it.
--
-- THE CAUSE. public.customer_get_stamp_card_v323 builds its milestone list from
-- loyalty_reward_versions alone, filtered on rv.active and the v416-pinned config version. It
-- never consults the LIVE loyalty_rewards row. app.reward_availability_v432 — which is what every
-- other surface reads — additionally requires `live.active and not live.paused`. So switching a
-- gift off removed it from every list except the one the customer is actually looking at.
--
-- The version row and the live row answer different questions and BOTH matter: the version says
-- "what did this card promise when it was started" (v416's whole point — a customer mid-card keeps
-- the deal they started under), the live row says "is this gift still on offer at all". A gift the
-- owner has switched off is not on offer to anybody, on any card, so it must leave the card too.
-- Pricing and naming still come from the pinned version, untouched.
--
-- MEASURED against the owner's own customer before applying: the milestone list goes from
-- [Free Espresso Shot (7, switched off), Free Kopi Set (10, live)] to [Free Kopi Set (10)] —
-- which is exactly what app.reward_availability_v432 already returns for the same pair.
--
-- CUSTOMER-VISIBLE: a badge disappears from an open card. That is the point. The alternative is a
-- card that keeps pointing at a gift the counter will refuse, which is worse than a card that
-- changes. Nothing about the customer's PROGRESS moves — the slots, the stamps and the pinned
-- earning rule are untouched.
--
-- Patched in place: this is a ~9KB function and this change is one predicate. The patch asserts
-- its own marker and aborts if the source has moved, so a silent no-op is impossible.

begin;

do $outer$
declare
  v_src text;
  v_old constant text := $marker$     where b.id = v_context.business_id
       and rv.programme_id = v_progress.programme_id
  ) rung;$marker$;
  v_new constant text := $marker$     where b.id = v_context.business_id
       and rv.programme_id = v_progress.programme_id
       -- nestly_v475: the LIVE row must still be on offer. The pinned version keeps deciding the
       -- gift's name, slot and price (v416: a customer mid-card keeps the deal they started
       -- under); this only asks whether the owner has since switched the gift off entirely. Same
       -- predicate app.reward_availability_v432 applies, so the card can no longer promise
       -- something the counter, the catalogue and the reward list all refuse.
       and exists (select 1 from public.loyalty_rewards live
                    where live.id = rv.reward_id
                      and live.business_id = b.id
                      and live.active
                      and not coalesce(live.paused, false))
  ) rung;$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_stamp_card_v323';
  if v_src is null then
    raise exception 'customer_get_stamp_card_v323 is missing' using errcode='42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'customer_get_stamp_card_v323 no longer has the milestone join this migration patches'
      using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- Signature unchanged; grants restated from the live proacl per the repo's preflight rule.
revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

commit;
