-- Nestly v271 — Programmes Overview needs a truthful "how many customers used it".
--
-- Owner (drawn on the Programmes screen): "for programme overview, i want a simple glance
-- (column) to see which ongoing programmes is live including details (start date, type, how many
-- programmes used by clients, etc)".
--
-- Start dates were already sourceable from tables the console can read directly
-- (loyalty_rewards.created_at, retention_programs.starts_on, business_customer_content_v95
-- .starts_at, membership_plans.created_at, referral_programs.created_at, and the earliest
-- published firm_config_versions row for the point system). Usage counts were NOT. A count of
-- DISTINCT customers cannot be produced by PostgREST — the browser would have to download every
-- points_ledger and loyalty_redemptions row and count them client-side, which is unbounded for a
-- busy tenant and would silently under-count the moment a page limit clipped the result. An
-- under-count rendered as a number is exactly the fabricated measurement the owner must never be
-- shown, so the aggregate is computed server-side, once, or not shown at all.
--
-- Every count is DISTINCT CLIENT, not row count: the question is "how many of my customers used
-- this", and one customer redeeming the same reward three times is one customer. Where a
-- programme genuinely has no usage record, this function returns SQL NULL rather than 0 — the UI
-- renders null as "Not tracked" and never as a zero that looks like a measurement. Two programmes
-- are null on purpose:
--   * promotions — a promotion is presentation (business_customer_content_v95). Nothing records a
--     customer redeeming one, so any number here would be invented.
--   * gift cards — gift_cards.purchaser_client_id is the BUYER, and a gift card is usually bought
--     for someone else. Counting purchasers as "customers who used the programme" would answer a
--     different question than the column asks.
--
-- Read-only, STABLE, SECURITY DEFINER. The authorisation matches
-- business_get_welcome_offer_v215 — the RPC that already backs a counter on this same screen —
-- so no new audience gains access to anything: firm owner, or a staff member with read access to
-- the loyalty module. Nothing here returns a customer identity; only counts leave the function.

begin;

create or replace function public.business_programme_usage_v271(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_point_customers int;
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

  -- The point system is "used" by a customer the moment they earn from it. Redemption is a
  -- separate programme (the rewards below), so it is deliberately not folded in here.
  select count(distinct client_id)::int into v_point_customers
    from public.points_ledger
   where business_id = p_business
     and entry_type = 'earn'
     and client_id is not null;

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
    'rewards', v_rewards,
    'retention', v_retention,
    'birthday', jsonb_build_object('started_at', v_birthday_started,
                                   'customers', coalesce(v_birthday_customers, 0)),
    'welcome', jsonb_build_object('customers', coalesce(v_welcome_customers, 0)),
    'referrals', jsonb_build_object('customers', coalesce(v_referral_customers, 0)),
    'memberships', v_memberships,
    -- null, not 0: nothing in this schema records a customer using a promotion or a gift card
    -- programme, and a zero would read as "measured, and nobody used it".
    'promotions', jsonb_build_object('customers', null),
    'gift_cards', jsonb_build_object('customers', null));
end
$function$;

revoke all on function public.business_programme_usage_v271(uuid) from public, anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated;

commit;
