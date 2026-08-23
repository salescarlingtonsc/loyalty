-- nestly_v468 — the programme analytics count USES, not people (owner photo 4, 2026-08-23).
--
-- THE MARK. On Rewards & Offer -> Overview the owner circled "Customers used, by category" and
-- wrote: "It should be number of times, not how many customers used. It can be same customer but
-- multiple times used." A salon's best customer redeeming the same gift five times read as "1",
-- which is the opposite of what a category chart is for — it flattened exactly the behaviour the
-- programmes exist to produce.
--
-- WHAT CHANGES. Every figure this function already computes as count(distinct client_id) gains a
-- twin computed as count(*) over the IDENTICAL event set, published as 'uses' beside the existing
-- 'customers'. Nothing is removed and nothing is renamed:
--   * additive, so every current reader keeps working unchanged and this migration can land before
--     the frontend that reads it;
--   * the two numbers are answered from one scan of one predicate, so "3 uses by 2 customers" can
--     never be a pair of figures that disagree about which events they describe;
--   * the honesty rule from v271/v273 is preserved exactly — a programme the firm has never set up
--     returns null for BOTH figures, never a zero it did not measure. The four "is it set up"
--     probes are hoisted into booleans so the gate is evaluated once rather than once per figure.
--
-- WHAT "A USE" MEANS, PER CATEGORY. Deliberately, it is the same event the de-duplicated figure
-- was already counting, counted per occurrence instead of per person:
--   rewards      one redemption row            memberships  one membership started
--   bring-back   one redeemed grant            birthday     one birthday redemption
--   retention    one legacy reward grant       welcome      one redeemed welcome offer
--   referrals    one qualified referral        point/stamp  one earn entry on the ledger
-- Note for the earning engines: this counts LEDGER ENTRIES, not units. A customer holding 764
-- stamps earned them over ~22 visits, so "22 uses" is the number of times the card was used, which
-- is the question asked. promotions and gift_cards stay null for both: nothing in the schema
-- records a customer using a promotion (the v271 gap, still open, still admitted rather than faked).
--
-- v271 NOW DELEGATES. business_programme_usage_v271 was a byte-for-byte copy of v386 minus the
-- window predicates — two 7KB bodies that had to be edited in lockstep forever, and this migration
-- would have been the third time. db/tests/v386 check 03 already asserts "v386 unbounded IS v271
-- by contract"; that contract is now enforced by construction instead of by transcription. v271's
-- payload gains the 'window' key (both bounds null), which is additive.
--
-- REVERSIBLE. Both objects are CREATE OR REPLACE FUNCTION over existing signatures; no table, no
-- column, no data is touched, and db/tests/v468_programme_usage_counts.sql restores the prior
-- behavioural assertions. Grants below restate the live proacl verbatim
-- (postgres, authenticated, service_role — never anon).

begin;

CREATE OR REPLACE FUNCTION public.business_programme_usage_v386(p_business uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from timestamptz := case when p_from is null then null
                             else (p_from::text || ' 00:00:00+08')::timestamptz end;
  v_to   timestamptz := case when p_to is null then null
                             else ((p_to + 1)::text || ' 00:00:00+08')::timestamptz end;
  v_point_customers int;
  v_point_uses_v468 int;
  v_points_programme_v310 uuid;
  v_stamps_programme_v310 uuid;
  v_stamp_customers_v310 int;
  v_stamp_uses_v468 int;
  v_rewards jsonb;
  v_bringback jsonb;
  v_retention jsonb;
  v_birthday_started timestamptz;
  v_birthday_customers int;
  v_birthday_uses_v468 int;
  v_welcome_customers int;
  v_welcome_uses_v468 int;
  v_referral_customers int;
  v_referral_uses_v468 int;
  v_memberships jsonb;
  /* V468: each of these gated a 'customers' figure with an inline EXISTS. The figure now has a
     'uses' twin gated by the SAME condition, so the probe is hoisted to a boolean rather than
     written — and re-planned — twice. See [[sql-inlining-repeated-evaluation]]: an inlined
     sub-select in this codebase has bitten us before by being evaluated per reference. */
  v_stamp_card_live_v468 boolean;
  v_birthday_live_v468 boolean;
  v_welcome_live_v468 boolean;
  v_referrals_live_v468 boolean;
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
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'the From date is after the To date' using errcode = '22023';
  end if;

  select spine.id into v_points_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme_v310 is null then
    select count(distinct client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
      from public.points_ledger
     where business_id = p_business
       and entry_type = 'earn'
       and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);
  else
    select count(distinct ledger.client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
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
    select count(distinct ledger.client_id)::int, count(*)::int into v_stamp_customers_v310, v_stamp_uses_v468
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
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))), '[]'::jsonb)
    into v_rewards
    from public.loyalty_rewards reward
    left join lateral (
      select count(distinct redemption.client_id)::int customers, count(*)::int uses
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.reward_id = reward.id
         and redemption.client_id is not null
       and (v_from is null or redemption.redeemed_at >= v_from)
       and (v_to is null or redemption.redeemed_at < v_to)
    ) used on true
   where reward.business_id = p_business;

  select coalesce(jsonb_agg(jsonb_build_object(
           'program_id', campaign.id,
           'campaign_id', campaign.id,
           'source', 'bringback_v361',
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))
         order by campaign.away_days, campaign.id), '[]'::jsonb)
    into v_bringback
    from public.bringback_campaigns_v361 campaign
    left join lateral (
      select count(distinct grant_row.client_id)::int customers, count(*)::int uses
        from public.bringback_grants_v361 grant_row
       where grant_row.business_id = p_business
         and grant_row.campaign_id = campaign.id
         and grant_row.client_id is not null
         and grant_row.status = 'redeemed'
       and (v_from is null or grant_row.redeemed_at >= v_from)
       and (v_to is null or grant_row.redeemed_at < v_to)
    ) used on true
   where campaign.business_id = p_business;

  select v_bringback || coalesce(jsonb_agg(jsonb_build_object(
           'program_id', program.id,
           'source', 'retention_legacy',
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))
         order by program.id), '[]'::jsonb)
    into v_retention
    from public.retention_programs program
    left join lateral (
      select count(distinct grant_row.client_id)::int customers, count(*)::int uses
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

  select count(distinct client_id)::int, count(*)::int into v_birthday_customers, v_birthday_uses_v468
    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);

  select count(distinct client_id)::int, count(*)::int into v_welcome_customers, v_welcome_uses_v468
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null
       and (v_from is null or redeemed_at >= v_from)
       and (v_to is null or redeemed_at < v_to);

  select count(distinct referrer_client_id)::int, count(*)::int into v_referral_customers, v_referral_uses_v468
    from public.referrals
   where business_id = p_business
     and qualified_at is not null
     and referrer_client_id is not null
       and (v_from is null or qualified_at >= v_from)
       and (v_to is null or qualified_at < v_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id', plan.id,
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))), '[]'::jsonb)
    into v_memberships
    from public.membership_plans plan
    left join lateral (
      select count(distinct member.client_id)::int customers, count(*)::int uses
        from public.memberships member
       where member.business_id = p_business
         and member.plan_id = plan.id
         and member.client_id is not null
       and (v_from is null or member.started_at >= v_from)
       and (v_to is null or member.started_at < v_to)
    ) used on true
   where plan.business_id = p_business;

  /* V468 BUG FIX, found while adding 'uses'. The stamp figure is COMPUTED from the spine
     (business_programmes.kind='stamps' — see v_stamp_customers_v310 above), but this gate asked a
     different question of a different table: loyalty_programs.loyalty_model. On the demo tenant
     those disagree — spine kinds 'points,referral,stamps,tiers', declared model 'classic' — so a
     stamp card with three real earn entries on the ledger had its measured figure discarded and
     reported as "Not tracked". The honesty rule (v271/v273) says never show a zero you did not
     measure; it does NOT license hiding a number you did measure. Gate and measurement now read
     the same source, so they cannot disagree again. A business with no stamps spine still gets
     null, which is the case the rule was written for. */
  v_stamp_card_live_v468 := v_stamps_programme_v310 is not null;
  v_birthday_live_v468 := exists(select 1 from public.birthday_programs v273_exists
                                  where v273_exists.business_id = p_business);
  v_welcome_live_v468 := exists(select 1 from public.business_welcome_offers_v215 v273_exists
                                 where v273_exists.business_id = p_business);
  v_referrals_live_v468 := exists(select 1 from public.referral_programs v273_exists
                                   where v273_exists.business_id = p_business);

  return jsonb_build_object(
    'status', 'ok',
    'as_of', now(),
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0),
                                       'uses', coalesce(v_point_uses_v468, 0)),
    'stamp_card', jsonb_build_object('customers', case when v_stamp_card_live_v468
                                     then coalesce(v_stamp_customers_v310, 0) else null end,
                                     'uses', case when v_stamp_card_live_v468
                                     then coalesce(v_stamp_uses_v468, 0) else null end),
    'rewards', v_rewards,
    'retention', v_retention,
    'bringback', v_bringback,
    'birthday', jsonb_build_object('started_at', v_birthday_started,
                                   'customers', case when v_birthday_live_v468
                                     then coalesce(v_birthday_customers, 0) else null end,
                                   'uses', case when v_birthday_live_v468
                                     then coalesce(v_birthday_uses_v468, 0) else null end),
    'welcome', jsonb_build_object('customers', case when v_welcome_live_v468
                                     then coalesce(v_welcome_customers, 0) else null end,
                                  'uses', case when v_welcome_live_v468
                                     then coalesce(v_welcome_uses_v468, 0) else null end),
    'referrals', jsonb_build_object('customers', case when v_referrals_live_v468
                                     then coalesce(v_referral_customers, 0) else null end,
                                    'uses', case when v_referrals_live_v468
                                     then coalesce(v_referral_uses_v468, 0) else null end),
    'memberships', v_memberships,
    'promotions', jsonb_build_object('customers', null, 'uses', null),
    'gift_cards', jsonb_build_object('customers', null, 'uses', null));
end
$function$
;

CREATE OR REPLACE FUNCTION public.business_programme_usage_v271(p_business uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  select public.business_programme_usage_v386(p_business, null, null);
$function$;

revoke all on function public.business_programme_usage_v386(uuid, date, date) from public, anon;
grant execute on function public.business_programme_usage_v386(uuid, date, date) to authenticated, service_role;
revoke all on function public.business_programme_usage_v271(uuid) from public, anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated, service_role;

commit;
