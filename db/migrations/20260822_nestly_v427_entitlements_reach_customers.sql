-- nestly_v427 — an entitlement the server granted must reach the customer who earned it.
--
-- THE GAP THIS CLOSES (go-live audit, 2026-08-22).
-- Three engines issue a real, redeemable entitlement to a named customer, entirely server-side:
--   * welcome_offer_grants_v215   — app.issue_welcome_offer_v215, on the customer joining;
--   * bringback_grants_v361       — app.issue_bringback_for_business_v361, on the daily sweep;
--   * referral_grants_v420        — on a referral qualifying (both sides, since v421).
-- Every one of them is invisible to the person who earned it. The ONLY reader over those three
-- tables is staff_get_customer_entitlements_v102, which is gated on till/sales/packages module
-- READ and takes a business id and a client id as arguments — a staff-side call, and one that
-- cannot be granted to a customer without letting any caller ask about any client at any firm.
-- So the product's position today is: we quietly owe the customer a free coffee, we tell the
-- counter about it, and we never tell the customer. A voucher nobody knows they hold is not a
-- reward; it is a liability with no marketing value.
--
-- WHAT THIS MIGRATION IS.
--   1. public.customer_get_entitlements_v427 — the customer's own read over exactly those three
--      grant tables, resolved through the wallet context, scoped to their own client row.
--   2. public.customer_get_reward_history_v422 — extended so a REDEEMED grant also appears in
--      the customer's "History" tab. Additive: every key v422 already returned is still returned.
--   3. public.business_programme_usage_v271 / _v386 — the bring-back figure now comes from the
--      v361 engine that actually issues bring-back vouchers, not from the legacy retention engine.
--   4. public.business_set_welcome_offer_v215 — owner-only, matching the UI.
--
-- WHAT THIS MIGRATION IS NOT.
-- It does not issue, redeem, expire, or write anything. All four functions it touches are reads
-- except the welcome-offer writer, whose only change is who may call it. The canonical state of an
-- entitlement is the grant row, and the only things that move it are the three staff_redeem_*
-- RPCs. There is deliberately no second opinion here about whether a customer "deserves" an
-- entitlement: the grant row exists or it does not.
--
-- THE RULE BEHIND THE SHAPE (owner-locked, 2026-08-22): the customer must read the SAME rows the
-- counter redeems. grant exists -> customer sees it -> staff redeems it -> canonical state
-- updates -> history reflects it. Nothing in the browser is allowed to compute eligibility; that
-- is the v145 rule and it is why this is a server read rather than three client-side table reads.
--
-- NO MODULE GATE, DELIBERATELY. customer_get_stamp_card_v323 checks `'loyalty' = any(enabled_
-- modules)` because a stamp card is a PROGRAMME — turning the programme off means there is no
-- card. A grant is not a programme; it is a promise already made to a named person, and the till
-- will still honour it (staff_redeem_bringback_v361 and its siblings never consult the module
-- list). Hiding an entitlement the counter would still pay out is the one failure mode worse than
-- showing it: the customer stops coming in for something we were going to give them anyway. The
-- wallet-context gate still applies in full — authenticated session, ACTIVE identity, the
-- customer_wallet platform feature, and a VERIFIED link to this business — because that is
-- identity, not eligibility.

begin;

-- ============================================================================================
-- 1. THE CUSTOMER'S OWN ENTITLEMENTS
-- ============================================================================================
-- Identity, business and client all come from app.v32_customer_wallet_context. Nothing about WHO
-- is being asked about is taken from an argument, so there is no shape of this call that names
-- someone else's client row — the same construction customer_get_reward_history_v422 and
-- customer_get_stamp_card_v323 already use.
--
-- STATUS IS DERIVED, NEVER WRITTEN. A grant whose expires_at has passed still carries
-- status='granted' in the table until someone tries to redeem it (the staff_redeem_* functions
-- flip it to 'expired' at that moment). This function is STABLE and must not write, so it derives
-- the state the customer should see: a lapsed grant is reported in `history` as 'expired' and
-- never offered as active. That matches staff_get_customer_entitlements_v102, which withholds an
-- expired grant rather than offering it and then refusing it at the counter.
--
-- ALL BRING-BACK GRANTS, NOT THE FIRST. The till reader takes `limit 1` on bring-back and on
-- referral because it drives a single banner. A customer may genuinely hold one grant per active
-- campaign, and each is separately redeemable (staff_redeem_bringback_v361 takes an explicit
-- p_grant). Showing the customer only one of two vouchers they hold would be a lie of omission,
-- so this returns every active grant and lets the surface decide what to feature.
create or replace function public.customer_get_entitlements_v427(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_active jsonb;
  v_history jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  with granted as (
    -- One row per entitlement the three engines can have issued to THIS client at THIS business.
    -- The three tables do not share a shape, so each branch normalises to the same columns and
    -- carries its own kind-specific field (min spend / away days / which side of a referral).
    select 'welcome'::text          as source,
           welcome.id               as id,
           welcome.reward_label     as label,
           welcome.status           as stored_status,
           welcome.granted_at       as granted_at,
           welcome.expires_at       as expires_at,
           welcome.redeemed_at      as redeemed_at,
           welcome.min_spend_cents  as min_spend_cents,
           null::integer            as away_days,
           null::text               as beneficiary
      from public.welcome_offer_grants_v215 welcome
     where welcome.business_id = v_context.business_id
       and welcome.client_id   = v_context.client_id
    union all
    select 'bringback',
           bringback.id, bringback.reward_label, bringback.status,
           bringback.granted_at, bringback.expires_at, bringback.redeemed_at,
           null::integer, bringback.away_days, null::text
      from public.bringback_grants_v361 bringback
     where bringback.business_id = v_context.business_id
       and bringback.client_id   = v_context.client_id
    union all
    select 'referral',
           referral.id, referral.reward_label, referral.status,
           referral.granted_at, referral.expires_at, referral.redeemed_at,
           null::integer, null::integer, referral.beneficiary
      from public.referral_grants_v420 referral
     where referral.business_id = v_context.business_id
       and referral.client_id   = v_context.client_id
  ), shaped as (
    select entitlement.*,
           case
             when entitlement.stored_status = 'redeemed' then 'redeemed'
             when entitlement.stored_status = 'expired'  then 'expired'
             when entitlement.expires_at is not null
              and entitlement.expires_at <= now()        then 'expired'
             when entitlement.stored_status = 'granted'  then 'active'
             -- A status this build does not know about is NOT shown as claimable. The check
             -- constraint allows only three values today; a future fourth must fail closed.
             else 'other'
           end as state
      from granted entitlement
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',              active_row.id,
               'source',          active_row.source,
               'label',           active_row.label,
               'status',          'active',
               'granted_at',      active_row.granted_at,
               'expires_at',      active_row.expires_at,
               'redeemed_at',     null,
               'min_spend_cents', active_row.min_spend_cents,
               'away_days',       active_row.away_days,
               'beneficiary',     active_row.beneficiary,
               'instructions',    'Show this at the counter and staff will apply it.')
             -- Soonest to lapse first; an entitlement with no expiry sorts last because it is
             -- never the one the customer needs to be warned about.
             order by (active_row.expires_at is null), active_row.expires_at,
                      active_row.granted_at, active_row.id)
        from shaped active_row
       where active_row.state = 'active'), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',              past_row.id,
               'source',          past_row.source,
               'label',           past_row.label,
               'status',          past_row.state,
               'granted_at',      past_row.granted_at,
               'expires_at',      past_row.expires_at,
               'redeemed_at',     past_row.redeemed_at,
               'min_spend_cents', past_row.min_spend_cents,
               'away_days',       past_row.away_days,
               'beneficiary',     past_row.beneficiary,
               'instructions',    null)
             order by past_row.sort_at desc, past_row.id desc)
        from (
          select shaped.*,
                 coalesce(shaped.redeemed_at, shaped.expires_at, shaped.granted_at) as sort_at
            from shaped
           where shaped.state in ('redeemed', 'expired')
           order by coalesce(shaped.redeemed_at, shaped.expires_at, shaped.granted_at) desc,
                    shaped.id desc
           limit 50
        ) past_row), '[]'::jsonb)
    into v_active, v_history;

  return jsonb_build_object(
    'contract',     'v427',
    'business_id',  v_context.business_id,
    'as_of',        now(),
    'active',       v_active,
    'active_count', jsonb_array_length(v_active),
    'history',      v_history);
end
$function$;

-- The exact ACL every other customer_get_* read on this surface carries. anon is refused
-- explicitly: this is a customer's own entitlement list and there is no anonymous form of it.
revoke all on function public.customer_get_entitlements_v427(text) from public, anon;
grant execute on function public.customer_get_entitlements_v427(text) to authenticated, service_role;

-- ============================================================================================
-- 2. REDEEMED GRANTS JOIN THE CUSTOMER'S HISTORY
-- ============================================================================================
-- v422 answered "what have I already claimed here?" over public.loyalty_redemptions alone. None
-- of the three grant engines writes that table — staff_redeem_welcome_offer_v215,
-- staff_redeem_bringback_v361 and staff_redeem_referral_v420 each write a $0 sale and stamp the
-- grant row — so the free coffee a customer actually collected at the counter vanished the moment
-- it was handed over. It is now listed beside the points rewards.
--
-- ADDITIVE. Every key v422 already returned on a redemption row is returned unchanged; `source`
-- is new on every row so the surface can tell a points redemption from a granted entitlement, and
-- `sale_id` is new so a receipt can be found. The client renderer reads reward_name, redeemed_at,
-- consumes_balance, points_spent and image_ref, all of which are present on both row kinds.
--
-- ONLY REDEEMED. An EXPIRED grant is not a claimed reward and must not appear under a tab whose
-- empty state reads "Nothing claimed yet. Rewards you redeem show up here." Expired entitlements
-- live in customer_get_entitlements_v427's own `history` array, where they are labelled as such.
--
-- points_spent 0 / consumes_balance false is the literal truth: a granted entitlement costs the
-- customer nothing, and the renderer already suppresses the cost line when consumes_balance is
-- not true (the v323 stamp-milestone case). fulfillment_kind is null rather than borrowed: these
-- rows are not loyalty_redemptions and carry no taxonomy.
create or replace function public.customer_get_reward_history_v422(
  p_business_slug text,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- Identity, business and client all come from here. Nothing about WHO is being asked about is
  -- taken from an argument.
  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(item order by redeemed_at desc, id desc), '[]'::jsonb)
    into v_items
    from (
      select claimed.id, claimed.redeemed_at, claimed.item
        from (
          select redemption.id,
                 redemption.redeemed_at,
                 jsonb_build_object(
                   'id', redemption.id,
                   'source', 'reward',
                   'reward_name', redemption.reward_name,
                   'redeemed_at', redemption.redeemed_at,
                   -- The cost is printed back to the customer in the unit they paid in. A
                   -- stamp-card milestone is claimed without consuming a balance (v323), so
                   -- points_spent is 0 on those rows and the client prints no cost line rather
                   -- than "0 points".
                   'points_spent', redemption.points_spent,
                   'consumes_balance', redemption.consumes_balance,
                   'fulfillment_kind', redemption.fulfillment_kind,
                   -- image_ref is read from the snapshot the redemption itself stored, not from
                   -- the live reward: a gift whose photo the firm has since changed should appear
                   -- in history as the thing the customer actually received.
                   'image_ref', nullif(redemption.reward_snapshot->>'image_ref', ''),
                   'sale_id', null
                 ) as item
            from public.loyalty_redemptions redemption
           where redemption.business_id = v_context.business_id
             and redemption.client_id = v_context.client_id
             and not exists (
               select 1
                 from public.loyalty_redemption_reversals reversal
                where reversal.business_id = redemption.business_id
                  and reversal.redemption_id = redemption.id
             )

          union all

          -- nestly_v427: the three granted entitlements, once the counter has actually handed
          -- them over. A grant with status='redeemed' always has redeemed_at set — the
          -- <table>_redeem_shape check constraint enforces it — so the ordering key is never null.
          select welcome.id, welcome.redeemed_at,
                 jsonb_build_object(
                   'id', welcome.id, 'source', 'welcome',
                   'reward_name', welcome.reward_label,
                   'redeemed_at', welcome.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', welcome.redeemed_sale_id)
            from public.welcome_offer_grants_v215 welcome
           where welcome.business_id = v_context.business_id
             and welcome.client_id = v_context.client_id
             and welcome.status = 'redeemed'
             and welcome.redeemed_at is not null

          union all

          select bringback.id, bringback.redeemed_at,
                 jsonb_build_object(
                   'id', bringback.id, 'source', 'bringback',
                   'reward_name', bringback.reward_label,
                   'redeemed_at', bringback.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', bringback.redeemed_sale_id)
            from public.bringback_grants_v361 bringback
           where bringback.business_id = v_context.business_id
             and bringback.client_id = v_context.client_id
             and bringback.status = 'redeemed'
             and bringback.redeemed_at is not null

          union all

          select referral.id, referral.redeemed_at,
                 jsonb_build_object(
                   'id', referral.id, 'source', 'referral',
                   'reward_name', referral.reward_label,
                   'redeemed_at', referral.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', referral.redeemed_sale_id)
            from public.referral_grants_v420 referral
           where referral.business_id = v_context.business_id
             and referral.client_id = v_context.client_id
             and referral.status = 'redeemed'
             and referral.redeemed_at is not null
        ) claimed
       -- The limit is applied to the MERGED list, not per source: a customer with 60 points
       -- redemptions and one free coffee last week must still see the coffee.
       order by claimed.redeemed_at desc, claimed.id desc
       limit v_limit
    ) as recent;

  return jsonb_build_object(
    'contract', 'v422',
    'business_id', v_context.business_id,
    'items', v_items
  );
end
$function$;

revoke all on function public.customer_get_reward_history_v422(text, integer) from public, anon;
grant execute on function public.customer_get_reward_history_v422(text, integer) to authenticated, service_role;

-- ============================================================================================
-- 3. THE BUSINESS-SIDE BRING-BACK FIGURE COMES FROM THE ENGINE THAT ISSUES BRING-BACKS
-- ============================================================================================
-- The `retention` array in both usage RPCs counted public.reward_grants rows against
-- public.retention_programs. That is the LEGACY retention engine — it pays on visit FREQUENCY
-- ("3 visits in 30 days"), which is the opposite question from "this customer stopped coming".
-- v361 is the canonical bring-back (owner ruling, 2026-08-22), it has its own campaigns and its
-- own grants, and it was contributing nothing to the number on the Rewards overview.
--
-- HOW THE ARRAY CHANGES. It now carries BOTH kinds of row, each labelled with `source`:
--   * one row per bringback_campaigns_v361 campaign — `program_id` is the campaign id;
--   * one row per legacy retention_programs row — unchanged definition, unchanged figure.
-- Keeping the legacy rows is not hedging. The owner ruling keeps historical reward_grants data
-- queryable for audit, and the browser is a separate deploy from the database: between this
-- migration landing and the front end switching its own list read from retention_programs to
-- bringback_campaigns_v361, the Overview table looks up counts by whichever id it happens to
-- hold. A row it does not recognise is inert (the lookup is a Map keyed by id), and a row that is
-- missing prints "Not tracked" — so carrying both is the only ordering-independent answer. Ids
-- from two different tables cannot collide, so nothing is ever double-counted.
--
-- WHAT COUNTS AS "USED", FOR v361. Redeemed, not granted. app.issue_bringback_for_business_v361
-- grants to EVERY customer who has been away long enough, on a daily sweep — counting grants
-- would report the whole lapsed book as having "used" the programme the day it was switched on.
-- This is the same rule the welcome offer in this very function already states: "Granted is not
-- used." The legacy rows keep their historical all-grants definition so the audit figure the
-- owner has been reading does not silently move under them.
--
-- `bringback` is added as a top-level alias holding only the v361 rows, so the front end can name
-- what it means instead of relying on a key called `retention`. Both functions gain it, which is
-- what keeps db/tests/v386 check 03 (unbounded v386 must equal v271, exactly) true.
create or replace function public.business_programme_usage_v271(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_point_customers int;
  v_points_programme_v310 uuid;
  v_stamps_programme_v310 uuid;
  v_stamp_customers_v310 int;
  v_rewards jsonb;
  v_bringback jsonb;
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
       and client_id is not null;
  else
    select count(distinct ledger.client_id)::int into v_point_customers
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310;
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
       and ledger.programme_id = v_stamps_programme_v310;
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
    ) used on true
   where reward.business_id = p_business;

  -- nestly_v427: the canonical bring-back engine. Soft-deleted campaigns are INCLUDED — the
  -- lookup is by id, an unrecognised row is inert, and a retired campaign's historical figure is
  -- exactly what a History view would need.
  select coalesce(jsonb_agg(jsonb_build_object(
           'program_id', campaign.id,
           'campaign_id', campaign.id,
           'source', 'bringback_v361',
           'customers', coalesce(used.customers, 0))
         order by campaign.away_days, campaign.id), '[]'::jsonb)
    into v_bringback
    from public.bringback_campaigns_v361 campaign
    left join lateral (
      select count(distinct grant_row.client_id)::int customers
        from public.bringback_grants_v361 grant_row
       where grant_row.business_id = p_business
         and grant_row.campaign_id = campaign.id
         and grant_row.client_id is not null
         and grant_row.status = 'redeemed'
    ) used on true
   where campaign.business_id = p_business;

  -- The legacy retention engine, definition unchanged, kept queryable for audit.
  select v_bringback || coalesce(jsonb_agg(jsonb_build_object(
           'program_id', program.id,
           'source', 'retention_legacy',
           'customers', coalesce(used.customers, 0))
         order by program.id), '[]'::jsonb)
    into v_retention
    from public.retention_programs program
    left join lateral (
      select count(distinct grant_row.client_id)::int customers
        from public.reward_grants grant_row
       where grant_row.business_id = p_business
         and grant_row.program_id = program.id
         and grant_row.client_id is not null
    ) used on true
   where program.business_id = p_business;

  select min(created_at) into v_birthday_started
    from public.birthday_programs where business_id = p_business;

  -- Reversal rows share this table with the original redemption; `active` is what distinguishes a
  -- redemption that still stands from one that was undone. Counting both would report a customer
  -- as having used a benefit that was taken back.
  select count(distinct client_id)::int into v_birthday_customers
    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null;

  -- Granted is not used. Only a redeemed welcome offer means the customer actually received it.
  select count(distinct client_id)::int into v_welcome_customers
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null;

  -- The referrer is the customer the programme rewarded, and only a qualified referral pays out.
  select count(distinct referrer_client_id)::int into v_referral_customers
    from public.referrals
   where business_id = p_business
     and qualified_at is not null
     and referrer_client_id is not null;

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
    ) used on true
   where plan.business_id = p_business;

  return jsonb_build_object(
    'status', 'ok',
    'as_of', now(),
    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0)),
    'stamp_card', jsonb_build_object('customers', case when exists(
                                       select 1 from public.loyalty_programs programme_v310
                                        where programme_v310.business_id = p_business
                                          and programme_v310.loyalty_model = 'stamps')
                                     then coalesce(v_stamp_customers_v310, 0) else null end),
    'rewards', v_rewards,
    'retention', v_retention,
    -- nestly_v427: the same v361 rows under a name that says what they are.
    'bringback', v_bringback,
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

revoke all on function public.business_programme_usage_v271(uuid) from public, anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated, service_role;

create or replace function public.business_programme_usage_v386(
  p_business uuid,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
  v_bringback jsonb;
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

  -- nestly_v427: the canonical bring-back engine. Windowed on redeemed_at, because redemption is
  -- what "used" means here (see the v271 note); the welcome offer beside it windows the same way.
  select coalesce(jsonb_agg(jsonb_build_object(
           'program_id', campaign.id,
           'campaign_id', campaign.id,
           'source', 'bringback_v361',
           'customers', coalesce(used.customers, 0))
         order by campaign.away_days, campaign.id), '[]'::jsonb)
    into v_bringback
    from public.bringback_campaigns_v361 campaign
    left join lateral (
      select count(distinct grant_row.client_id)::int customers
        from public.bringback_grants_v361 grant_row
       where grant_row.business_id = p_business
         and grant_row.campaign_id = campaign.id
         and grant_row.client_id is not null
         and grant_row.status = 'redeemed'
       and (v_from is null or grant_row.redeemed_at >= v_from)
       and (v_to is null or grant_row.redeemed_at < v_to)
    ) used on true
   where campaign.business_id = p_business;

  -- The legacy retention engine, definition and window unchanged, kept queryable for audit.
  select v_bringback || coalesce(jsonb_agg(jsonb_build_object(
           'program_id', program.id,
           'source', 'retention_legacy',
           'customers', coalesce(used.customers, 0))
         order by program.id), '[]'::jsonb)
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
    -- nestly_v427: the same v361 rows under a name that says what they are.
    'bringback', v_bringback,
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

revoke all on function public.business_programme_usage_v386(uuid, date, date) from public, anon;
grant execute on function public.business_programme_usage_v386(uuid, date, date) to authenticated, service_role;

-- ============================================================================================
-- 4. THE WELCOME OFFER IS OWNER-ONLY, AS THE UI ALREADY SAYS
-- ============================================================================================
-- The reward configuration surface is owner-only in the front end, but this writer admitted
-- anyone holding module WRITE on 'loyalty' — a manager could set the firm's welcome offer, change
-- what it costs the firm, and switch it on, through a direct RPC call, with no screen offering it.
-- The stricter of the two is the honest one: the permission a function enforces should be the
-- permission the product claims. Only the authorization line changes; every validation, the
-- upsert, the audit row and the returned payload are byte-identical to the v215 body in
-- production today.
--
-- Reading the welcome offer is untouched (business_get_welcome_offer_v215), so a manager whose
-- till needs to know what the offer is can still read it, and staff_redeem_welcome_offer_v215
-- still redeems it on its own create_sales permission. Only CONFIGURING it narrows.
create or replace function public.business_set_welcome_offer_v215(
  p_business uuid,
  p_active boolean,
  p_min_spend_cents integer,
  p_reward_catalog_kind text,
  p_reward_catalog_id uuid,
  p_expiry_days integer default null,
  p_custom_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_label text;
  v_custom text := nullif(btrim(coalesce(p_custom_label,'')),'');
  v_row public.business_welcome_offers_v215%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  -- nestly_v427: owner-only. Was `app.is_salon_owner(p_business) or
  -- app.can_module_write(p_business,'loyalty')`.
  if not app.is_salon_owner(p_business) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;
  if p_reward_catalog_kind is null or p_reward_catalog_kind not in ('service','product','custom') then
    raise exception 'reward_catalog_kind must be service, product or custom' using errcode='22023';
  end if;
  if coalesce(p_min_spend_cents,0) < 0 or coalesce(p_min_spend_cents,0) > 100000000 then
    raise exception 'min_spend_cents out of range' using errcode='22023';
  end if;
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'expiry_days must be between 1 and 3650' using errcode='22023';
  end if;

  if p_reward_catalog_kind = 'custom' then
    if v_custom is null or char_length(v_custom) > 120 then
      raise exception 'welcome_offer_custom_label_required' using errcode='22023';
    end if;
    v_label := v_custom;
  else
    if p_reward_catalog_kind = 'service' then
      select name into v_label from public.services
      where id = p_reward_catalog_id and business_id = p_business and active;
    else
      select name into v_label from public.products
      where id = p_reward_catalog_id and business_id = p_business and active;
    end if;
    if v_label is null then
      raise exception 'welcome_offer_item_unavailable' using errcode='22023';
    end if;
  end if;

  insert into public.business_welcome_offers_v215 as offer(
    business_id, active, min_spend_cents, reward_catalog_kind,
    reward_catalog_id, custom_label, reward_label, expiry_days, updated_by, updated_at
  ) values (
    p_business, coalesce(p_active,false), coalesce(p_min_spend_cents,0),
    p_reward_catalog_kind, case when p_reward_catalog_kind='custom' then null else p_reward_catalog_id end,
    v_custom, v_label, p_expiry_days, v_actor, now()
  )
  on conflict (business_id) do update set
    active = excluded.active,
    min_spend_cents = excluded.min_spend_cents,
    reward_catalog_kind = excluded.reward_catalog_kind,
    reward_catalog_id = excluded.reward_catalog_id,
    custom_label = excluded.custom_label,
    reward_label = excluded.reward_label,
    expiry_days = excluded.expiry_days,
    version = offer.version + 1,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'WELCOME_OFFER_SET_V215',
          'business_welcome_offers_v215', p_business, jsonb_build_object(
    'active', v_row.active, 'min_spend_cents', v_row.min_spend_cents,
    'reward_catalog_kind', v_row.reward_catalog_kind,
    'reward_catalog_id', v_row.reward_catalog_id,
    'reward_label', v_row.reward_label, 'expiry_days', v_row.expiry_days,
    'version', v_row.version));

  return jsonb_build_object(
    'status','ok','active',v_row.active,'min_spend_cents',v_row.min_spend_cents,
    'reward_catalog_kind',v_row.reward_catalog_kind,
    'reward_catalog_id',v_row.reward_catalog_id,
    'custom_label',v_row.custom_label,
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version);
end
$function$;

revoke all on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text) from public, anon;
grant execute on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text) to authenticated, service_role;

-- ============================================================================================
-- 5. THE LEGACY RETENTION WRITERS ARE LEFT ALONE, ON PURPOSE
-- ============================================================================================
-- save_retention_program_draft, create_retention_campaign, issue_campaign_offer,
-- business_delete_retention_program_v332 and ensure_published_retention_in_draft_v138 are all
-- still reachable from the live front end (app/app.js calls every one of them), and no other
-- database function calls any of them. Dropping or gating one here would break a screen the owner
-- can still open today, and PL/pgSQL resolves names at run time, so the failure would be silent
-- until someone pressed the button. They stay exactly as they are until the front end retires
-- their surface; this migration only stops the READ side from reporting their engine's numbers as
-- the bring-back figure. issue_campaign_offer in particular belongs to the Playbooks feature, not
-- to bring-back rules, and is out of scope entirely.

commit;
