-- nestly_v422 — a customer can see the rewards they have already redeemed.
--
-- OWNER, 2026-08-21, photo 6 (the customer's Rewards screen), two marks on one control:
--   * "Available" / "History" written as a pair of tabs over "Your rewards";
--   * "only show redeemable rewards after customer achieve the reward" and
--     "once redeemed, rewards go history".
--
-- The first half of that is a client change (the Available tab keeps only what
-- customer_get_reward_catalog already marks claimable). The second half has nowhere to read from:
-- public.loyalty_redemptions is the row written every time a reward is actually handed over, and
-- the only reader over it is list_customer_redemption_history_v145 — a BUSINESS-side function
-- gated on app.has_perm(..., 'view_sales'). A customer holds no such permission and must not: it
-- takes a business id and a client id as arguments, so exposing it would let any caller ask about
-- any client at any firm. This adds the customer's own view of the same table.
--
-- WHAT IT IS NOT. It does not write, it does not reverse, and it does not decide anything about
-- eligibility — app.redeem_reward_core remains the only thing that turns a reward into a
-- redemption. It answers exactly one question: "what have I already claimed here?"
--
-- SCOPE AND ISOLATION. The caller is resolved through app.v32_customer_wallet_context, the same
-- gate every other customer_* read on this surface uses: it requires an authenticated session, an
-- ACTIVE customer identity, the customer_wallet platform feature, and a verified link between that
-- identity and this business. The business and client ids therefore come from the CONTEXT, never
-- from an argument — there is no shape of this call that can name someone else's client row.
--
-- REVERSALS. public.loyalty_redemption_reversals is joined so a redemption the counter took back
-- is not shown to the customer as something they still received. A reversed row is dropped rather
-- than labelled: the customer never saw it as "claimed" in the first place if it was reversed the
-- same day, and a list that says "Free Lotion — reversed" invites a conversation the app cannot
-- help with. The business-side reader (v145) keeps showing reversals, because that IS its job.

begin;

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
      select redemption.id,
             redemption.redeemed_at,
             jsonb_build_object(
               'id', redemption.id,
               'reward_name', redemption.reward_name,
               'redeemed_at', redemption.redeemed_at,
               -- The cost is printed back to the customer in the unit they paid in. A stamp-card
               -- milestone is claimed without consuming a balance (v323), so points_spent is 0 on
               -- those rows and the client prints no cost line rather than "0 points".
               'points_spent', redemption.points_spent,
               'consumes_balance', redemption.consumes_balance,
               'fulfillment_kind', redemption.fulfillment_kind,
               -- image_ref is read from the snapshot the redemption itself stored, not from the
               -- live reward: a gift whose photo the firm has since changed should appear in
               -- history as the thing the customer actually received.
               'image_ref', nullif(redemption.reward_snapshot->>'image_ref', '')
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
       order by redemption.redeemed_at desc, redemption.id desc
       limit v_limit
    ) as recent;

  return jsonb_build_object(
    'contract', 'v422',
    'business_id', v_context.business_id,
    'items', v_items
  );
end
$function$;

-- The exact ACL every other customer_get_* read on this surface carries. anon is refused
-- explicitly: this is a customer's own claim history and there is no anonymous form of it.
revoke all on function public.customer_get_reward_history_v422(text, integer) from public, anon;
grant execute on function public.customer_get_reward_history_v422(text, integer) to authenticated, service_role;

commit;
