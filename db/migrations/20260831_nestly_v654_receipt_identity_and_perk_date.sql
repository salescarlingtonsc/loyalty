/* nestly_v654 — two owner findings from the 2026-08-30 review, both of them about a screen
   telling the truth it already had.

   (1) THE PROFILE SAVE HAS BEEN REFUSING EVERY UEN SINCE v79 (owner photo 6: a receipt with no
       company name and no UEN — "company UEN and company name was not shown here. even after i
       input it"). businesses.registration_number carries a partial unique index over the
       expression app.normalized_business_identity_v79(registration_number). An index expression is
       evaluated as the CALLING role, and that function was granted to postgres only, so the moment
       an owner typed a UEN into Business Profile their whole save came back
       "42501: permission denied for function normalized_business_identity_v79" and nothing
       persisted — not the UEN, not the legal name, not the bio they typed in the same form. A save
       that did not touch registration_number stayed HOT and worked, which is why this looked like
       "only these two fields don't save".
       Proven against production before writing this: the same UPDATE as the owner's own role
       raises 42501 with a registration_number in it and returns 1 row without one.
       The fix is the grant. The function is a pure immutable normaliser over one text value — it
       reads no table and reveals nothing — and every role that can reach the index already has to
       be able to evaluate it. The receipt renderer needs no change: app-business.js already prints
       the legal name and "Reg. no." when the columns are set. They were never set.

   (2) A SPENT TIER PERK NOW SAYS WHEN IT WENT (owner photos 4 and 5: "Tiering Points already
       reached but no voucher to scan" / "I didnt use any voucher why it says i used this month").
       Production showed the perks WERE issued — eight times from the till on 20 Aug — so the card
       was right and simply could not prove it. last_used_at is the latest issue inside the SAME
       period the count is taken over, so it can never point at a use from a previous window, and
       it is null for a perk with no limit or no use. Nothing else about the payload moves.

   Rollback suite: db/tests/v654_receipt_identity_and_perk_date.sql */
begin;

grant execute on function app.normalized_business_identity_v79(text) to authenticated, service_role;

create or replace function public.customer_get_tier_benefits_v501(p_business_slug text)
 returns jsonb
 language plpgsql
 stable security definer
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
      /* nestly_v654: the same lateral, so the date and the count can never describe different
         windows. Null when the perk has no use in this period — the client then prints exactly
         what it printed before. */
      'last_used_at', used.last_in_period,
      'remaining', case when b.limit_count is null then null
                        else greatest(0, b.limit_count - used.count_in_period) end,
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
      select count(*)::integer as count_in_period,
             max(i.issued_at) as last_in_period
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

-- Restate the live ACL verbatim ({postgres,authenticated,service_role}=X/postgres).
revoke all on function public.customer_get_tier_benefits_v501(text) from public, anon;
grant execute on function public.customer_get_tier_benefits_v501(text) to authenticated, service_role;

commit;
