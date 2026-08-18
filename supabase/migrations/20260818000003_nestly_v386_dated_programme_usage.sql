-- Nestly v386 — "filter by date" on Customers who used each programme.
--
-- Owner markup 2026-08-17, photo 7: "filter by date" drawn across the usage table, and
-- "down here can put analytics by graph / chart comparison" beneath it. Neither was
-- expressible: business_programme_usage_v271 takes only p_business and answers for all time.
--
-- This is v271 with a window, and nothing else. Same authorization, same shape, same honesty
-- rule (a programme the schema cannot measure answers null, never 0). Every count is bounded
-- on the timestamp of the EVENT that made the customer a user of that programme:
--
--   point system / stamp card   points_ledger.created_at       (the earn)
--   gifts                       loyalty_redemptions.redeemed_at (the claim)
--   bring-back                  reward_grants.granted_at        (the grant reaching them)
--   birthday                    customer_birthday_redemptions.created_at
--   welcome offer               welcome_offer_grants_v215.redeemed_at (granted is not used)
--   referrals                   referrals.qualified_at          (only a qualified referral pays)
--   memberships                 memberships.started_at          (the enrolment)
--
-- Both bounds are optional and NULL means unbounded, so a call with neither returns exactly
-- what v271 returns today — the resting card does not change, and a firm that never touches
-- the filter sees the same all-time figures it always did.
--
-- Windows are half-open [from 00:00 SGT, to+1 day 00:00 SGT). Singapore days, because "17 Aug"
-- must mean the whole of the 17th here and not a slice of it in whatever zone the browser is in.
--
-- v271 is left in place and still granted: it is the published contract a client running the
-- previous deploy is still calling, and this function does not replace it.
--
-- Safety: read-only, additive, no table touched. STABLE SECURITY DEFINER exactly as v271 is,
-- and it returns counts only — no customer identity leaves this function.

begin;

CREATE OR REPLACE FUNCTION public.business_programme_usage_v386(p_business uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  -- The window, resolved once. Singapore day boundaries, half-open [from, to+1day): the same
  -- convention every other dated read in this product uses, so "17 Aug" means the whole of the
  -- 17th in Singapore and never a slice of it in the browser's zone.
  v_from timestamptz := case when p_from is null then null
                             else (p_from::text || ' 00:00:00+08')::timestamptz end;
  v_to   timestamptz := case when p_to is null then null
                             else ((p_to + 1)::text || ' 00:00:00+08')::timestamptz end;
  v_point_customers int;
  v_points_programme_v310 uuid;
  v_stamps_programme_v310 uuid;
  v_stamp_customers_v310 int;
  v_rewards jsonb;
  v_retention jsonb;
  v_birthday_started timestamptz;
  v_birthday_customers int;
  v_welcome_customers int;
  v_referral_customers int;
  v_memberships jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_business is null then
    raise exception 'business required' using errcode = '22023';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business, 'loyalty')) then
    raise exception 'programme overview authorization required' using errcode = '42501';
  end if;
  -- A backwards window is a mistake, not an empty result: answering 0 for it would let the page
  -- report "nobody used this" when nobody was ever asked.
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'the From date is after the To date' using errcode = '22023';
  end if;

  -- The point system is "used" by a customer the moment they earn from it. Redemption is a
  -- separate programme (the rewards below), so it is deliberately not folded in here.
  select spine.id into v_points_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme_v310 is null then
    select count(distinct client_id)::int into v_point_customers
      from public.points_ledger
     where business_id = p_business
       and entry_type = 'earn'
       and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);
  else
    select count(distinct ledger.client_id)::int into v_point_customers
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to);
  end if;

  select spine.id into v_stamps_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'stamps';
  if v_stamps_programme_v310 is not null then
    select count(distinct ledger.client_id)::int into v_stamp_customers_v310
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_stamps_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'reward_id', reward.id,
           'customers', coalesce(used.customers, 0))), '[]'::jsonb)
    into v_rewards
    from public.loyalty_rewards reward
    left join lateral (
      select count(distinct redemption.client_id)::int customers
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.reward_id = reward.id
         and redemption.client_id is not null
       and (v_from is null or redemption.redeemed_at >= v_from)
       and (v_to is null or redemption.redeemed_at < v_to)
    ) used on true
   where reward.business_id = p_business;

  -- A bring-back reward reaches a customer as a reward_grant; the grant is the only durable
  -- evidence that the programme did anything for that person.
  select coalesce(jsonb_agg(jsonb_build_object(
           'program_id', program.id,
           'customers', coalesce(used.customers, 0))), '[]'::jsonb)
    into v_retention
    from public.retention_programs program
    left join lateral (
      select count(distinct grant_row.client_id)::int customers
        from public.reward_grants grant_row
       where grant_row.business_id = p_business
         and grant_row.program_id = program.id
         and grant_row.client_id is not null
       and (v_from is null or grant_row.granted_at >= v_from)
       and (v_to is null or grant_row.granted_at < v_to)
    ) used on true
   where program.business_id = p_business;

  select min(created_at) into v_birthday_started
    from public.birthday_programs where business_id = p_business;

  -- Reversal rows share this table with the original redemption; `active` is what distinguishes a
  -- redemption that still stands from one that was undone. Counting both would report a customer
  -- as having used a benefit that was taken back.
  select count(distinct client_id)::int into v_birthday_customers
    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);

  -- Granted is not used. Only a redeemed welcome offer means the customer actually received it.
  select count(distinct client_id)::int into v_welcome_customers
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null
       and (v_from is null or redeemed_at >= v_from)
       and (v_to is null or redeemed_at < v_to);

  -- The referrer is the customer the programme rewarded, and only a qualified referral pays out.
  select count(distinct referrer_client_id)::int into v_referral_customers
    from public.referrals
   where business_id = p_business
     and qualified_at is not null
     and referrer_client_id is not null
       and (v_from is null or qualified_at >= v_from)
       and (v_to is null or qualified_at < v_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id', plan.id,
           'customers', coalesce(used.customers, 0))), '[]'::jsonb)
    into v_memberships
    from public.membership_plans plan
    left join lateral (
      select count(distinct member.client_id)::int customers
        from public.memberships member
       where member.business_id = p_business
         and member.plan_id = plan.id
         and member.client_id is not null
       and (v_from is null or member.started_at >= v_from)
       and (v_to is null or member.started_at < v_to)
    ) used on true
   where plan.business_id = p_business;

  return jsonb_build_object(
    'status', 'ok',
    'as_of', now(),
    -- Echoed so the card labels its figures with the window the SERVER used, not the one the
    -- inputs happen to be showing after an edit the owner has not applied yet.
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0)),
    'stamp_card', jsonb_build_object('customers', case when exists(
                                       select 1 from public.loyalty_programs programme_v310
                                        where programme_v310.business_id = p_business
                                          and programme_v310.loyalty_model = 'stamps')
                                     then coalesce(v_stamp_customers_v310, 0) else null end),
    'rewards', v_rewards,
    'retention', v_retention,
    'birthday', jsonb_build_object('started_at', v_birthday_started,
                                   'customers', case when exists(
                                     select 1 from public.birthday_programs v273_exists
                                      where v273_exists.business_id = p_business)
                                     then coalesce(v_birthday_customers, 0) else null end),
    'welcome', jsonb_build_object('customers', case when exists(
                                     select 1 from public.business_welcome_offers_v215 v273_exists
                                      where v273_exists.business_id = p_business)
                                     then coalesce(v_welcome_customers, 0) else null end),
    'referrals', jsonb_build_object('customers', case when exists(
                                     select 1 from public.referral_programs v273_exists
                                      where v273_exists.business_id = p_business)
                                     then coalesce(v_referral_customers, 0) else null end),
    'memberships', v_memberships,
    -- null, not 0: nothing in this schema records a customer using a promotion or a gift card
    -- programme, and a zero would read as "measured, and nobody used it".
    'promotions', jsonb_build_object('customers', null),
    'gift_cards', jsonb_build_object('customers', null));
end
$function$;

-- v271's live proacl restated verbatim, and the same for the new overload: no client role but
-- `authenticated` may call it, and it is never reachable anonymously.
revoke all on function public.business_programme_usage_v386(uuid, date, date) from public, anon;
grant execute on function public.business_programme_usage_v386(uuid, date, date) to authenticated;

revoke all on function public.business_programme_usage_v271(uuid) from public, anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated;

comment on function public.business_programme_usage_v386(uuid, date, date) is
  'v386: business_programme_usage_v271 with an optional Singapore-day window. NULL bounds mean
   unbounded, so a call with neither argument is identical to v271.';

commit;
