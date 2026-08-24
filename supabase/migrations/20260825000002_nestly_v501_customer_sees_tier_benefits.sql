-- nestly_v501 — a tier benefit reaches the customer who earned it
-- (owner, 2026-08-25, photo 1: "it shows 20% discount once per month. but the rewards did not land
--  on customer view - they should see that reward and redeem it (with qrcode) or business and
--  redeem for them like a typical rewards - nothing new"; and "since it is monthly rewards - it
--  will expire by end of month". Sol review bypassed on the owner's standing instruction.)
--
-- WHAT WAS ALREADY TRUE, and is deliberately not rebuilt here:
--   * tier_benefits_v365 holds the perk, tier_benefit_issues_v365 is its issuance ledger, and the
--     allowance is counted per app.v365_period_key — which is already a CALENDAR key in
--     Asia/Singapore ('YYYY-MM' for a monthly perk). So "it will expire by end of month" is what
--     the engine has always done: the allowance resets at the month boundary and an unused month
--     is gone. Nothing about the counting changes.
--   * The counter already works end to end. public.staff_tier_benefits_for_client_v365 lists a
--     client's perks with their remaining count and public.staff_issue_tier_benefit_v365 hands one
--     over, both wired into Record sale. Staff pull the customer up by scanning their member QR,
--     and the perk is right there.
--
-- WHAT WAS MISSING was exactly one thing: the CUSTOMER could not see it. Every tier-benefit
-- reader in the codebase is a staff reader — verified against production before writing this —
-- so the owner's 20%-off perk existed, was countable, was issuable, and appeared to its owner
-- only as a sentence on the tier ladder. This adds the customer's read and nothing else. There is
-- no new redemption path, no second issuance route and no new ledger: the perk is still handed
-- over by staff at the counter through the v365 RPC that already exists, which is the "nothing
-- new" the owner asked for.
--
-- THE READ MIRRORS THE STAFF READ, CLAUSE FOR CLAUSE — the same tier resolution, the same
-- at-or-below-threshold predicate, the same paused/deleted/effective-window filters, the same
-- period key, the same claimable_now and blocked_reason. That is deliberate and it is the whole
-- safety argument: if the two ever disagreed, the customer would be promised a perk the counter
-- refuses, which is precisely the contradiction v495 was written to kill. Anything this function
-- reports claimable, staff_issue_tier_benefit_v365 will accept.
--
-- PERIOD END. app.v501_period_ends_at is the honest deadline for a periodic perk: the instant the
-- current allowance window closes in Asia/Singapore. 'ever' has no deadline and returns null
-- rather than inventing one. It is derived from the SAME period vocabulary v365_period_key uses,
-- so a perk can never print a deadline that disagrees with the window it is counted in.

begin;

-- ============================================================================================
-- 1. When does the current allowance window close?
-- ============================================================================================

create or replace function app.v501_period_ends_at(p_period text, p_at timestamp with time zone)
 returns timestamp with time zone
 language sql
 immutable
 set search_path to 'pg_catalog', 'pg_temp'
as $function$
  -- Computed in Asia/Singapore and handed back as an instant, matching v365_period_key's own
  -- timezone. 'ever' is unlimited-in-time and says so with null.
  select case coalesce(p_period,'month')
    when 'ever' then null::timestamptz
    when 'day' then (date_trunc('day', timezone('Asia/Singapore',p_at)) + interval '1 day')
                    at time zone 'Asia/Singapore'
    when 'week' then (date_trunc('week', timezone('Asia/Singapore',p_at)) + interval '1 week')
                    at time zone 'Asia/Singapore'
    when 'year' then (date_trunc('year', timezone('Asia/Singapore',p_at)) + interval '1 year')
                    at time zone 'Asia/Singapore'
    else (date_trunc('month', timezone('Asia/Singapore',p_at)) + interval '1 month')
         at time zone 'Asia/Singapore'
  end
$function$;

revoke all on function app.v501_period_ends_at(text, timestamp with time zone) from public, anon, authenticated;

-- ============================================================================================
-- 2. The customer's own read
-- ============================================================================================

create or replace function public.customer_get_tier_benefits_v501(p_business_slug text)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_tier public.loyalty_tiers%rowtype;
  v_birthday boolean;
  v_rows jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  -- Fail CLOSED and quietly: a business with loyalty switched off, or no tier programme running,
  -- returns an empty list rather than an error. The wallet renders nothing for it, exactly as it
  -- does today, instead of showing the customer a retry card for a section they may have no rows
  -- in (the v429 entitlements rule).
  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  if not exists (
    select 1 from public.business_programmes spine
     where spine.business_id = v_context.business_id and spine.kind = 'tiers' and spine.active
  ) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;

  v_tier := app.v365_client_tier(v_context.business_id, v_context.client_id);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(v_context.client_id, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id', b.id,
      'tier_id', b.tier_id,
      'tier_label', t.name,
      'label', b.label,
      'benefit_kind', b.benefit_kind,
      'discount_percent', b.discount_percent,
      'item_label', coalesce((select p.name from public.products p where p.id = b.product_id), b.item_label),
      'limit_count', b.limit_count,
      'limit_period', b.limit_period,
      'sentence', app.v365_benefit_sentence(b.label, b.limit_count, b.limit_period),
      'used', used.count_in_period,
      'remaining', case when b.limit_count is null then null
                        else greatest(0, b.limit_count - used.count_in_period) end,
      -- The owner's second point: a monthly perk expires with its month. Null for an 'ever'
      -- perk, which has no window to fall out of.
      'period_ends_at', case when b.limit_count is null then null
                             else app.v501_period_ends_at(b.limit_period, now()) end,
      'claimable_now', (b.limit_period <> 'birthday_month' or v_birthday)
        and (b.limit_count is null or used.count_in_period < b.limit_count),
      'blocked_reason', case
        when b.limit_period = 'birthday_month' and not v_birthday then 'not_birthday_month'
        when b.limit_count is not null and used.count_in_period >= b.limit_count then 'used_up'
        else null end
    ) order by t.threshold desc, b.sort, b.id), '[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period
        from public.tier_benefit_issues_v365 i
       where i.benefit_id = b.id and i.client_id = v_context.client_id
         and i.period_key = app.v365_period_key(b.limit_period, now())
    ) used
   where b.business_id = v_context.business_id
     and b.deleted_at is null and b.active
     and coalesce(t.paused, false) = false and t.deleted_at is null
     and t.threshold <= v_tier.threshold
     and (t.effective_from is null or t.effective_from <= statement_timestamp())
     and (t.expires_at is null or t.expires_at > statement_timestamp());

  return jsonb_build_object(
    'status','ok',
    'tier', jsonb_build_object('id', v_tier.id, 'label', v_tier.name, 'threshold', v_tier.threshold),
    'in_birthday_month', v_birthday,
    'benefits', v_rows);
end;
$function$;

revoke all on function public.customer_get_tier_benefits_v501(text) from public, anon;
grant execute on function public.customer_get_tier_benefits_v501(text) to authenticated;

commit;
