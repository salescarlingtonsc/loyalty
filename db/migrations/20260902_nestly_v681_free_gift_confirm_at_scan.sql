-- NESTLY v681 — a scanned gift that needs no purchase is offered for confirmation, not filed away.
--
-- OWNER RULING (2026-09-02, keypad screenshot with "Scan" circled):
--   "when redeeming free gift - without any requirements to spend > after scan should pop up to
--    ask to confirm redeeming the said gifts. (using points to redeem or benefits to issue
--    gifts) - staff press yes / no.
--    unless the rewards requires purchases - example (20% off whole bill / 1 item) - then it
--    will be the usual process."
--
-- WHERE THIS LANDS. v666 made the keypad's Scan IDENTIFY rather than spend: the QR opens the
-- sale on its owner, a metered discount perk is staged onto the bill (v665), and everything else
-- is left sitting on the Rewards tab behind a Give button. That is right for a reward the till
-- has to price, and it is a detour for a gift that needs no purchase at all — the counter has
-- just scanned the customer's own QR for a free item, and is then told to go and find the same
-- gift again on another tab.
--
-- WHAT THIS ADDS, AND ONLY THIS. staff_scan_gift_qr_to_till_v666 is still a pure read. It gains
-- three descriptive fields so the till can ask the counter a yes/no question instead of guessing:
--
--   min_spend_cents  the quoted minimum spend carried on the intent (0 = none).
--   benefit_kind     for a tier perk, the benefit's own kind (discount_pct | free_item | custom).
--   settle_now       true only when NO purchase is required to hand this gift over:
--                      * welcome / bring-back / referral with quoted_min_spend_cents = 0, and
--                      * a tier perk whose benefit is not a discount_pct.
--
-- settle_now and stageable are mutually exclusive by construction: stageable is discount_pct
-- only, settle_now excludes discount_pct. A gift with a minimum spend, and a percentage discount
-- off a bill, both keep the exact flow they have today — ring the sale up, then apply or scan
-- from the receipt.
--
-- THE ANSWER IS ADVICE, NOT AUTHORITY. Nothing here settles anything, and the till's Yes still
-- goes through staff_scan_gift_qr_v515, which re-reads the intent `for update`, re-checks the
-- period, and routes to the redeemer that owns each gift kind's own permission and quota rules.
-- If this function said settle_now on a gift the redeemer refuses, the redeemer still refuses —
-- a wrong answer here can only cost the counter a message, never a voucher.
--
-- min_spend_cents is reported for every kind because the intent stores it for every kind; it is
-- non-zero today only for a welcome gift, which is the one gift the customer's own screens
-- already describe with a minimum spend.

begin;

create or replace function public.staff_scan_gift_qr_to_till_v666(p_business uuid, p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_stageable boolean := false;
  v_settle_now boolean := false;
  v_benefit_kind text := null;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  -- The authority that opens a sale on a customer, which is all this does.
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode = '42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    return jsonb_build_object('status','invalid','message','This is not a Peekaa reward QR.');
  end if;

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token);
  -- Every refusal is SOFT. staff_scan_gift_qr_v515 owns the wording for an unknown, expired or
  -- already-used QR; the caller falls through to it rather than this function inventing a second
  -- vocabulary for the same three states.
  if not found then
    return jsonb_build_object('status','invalid','message','This reward QR is not from this business.');
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= now() then
    return jsonb_build_object('status','not_pending','gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;

  -- Stageable means "the pricing kernel can put this on a bill" — the same test
  -- staff_stage_gift_qr_v665 applies, asked here so the till knows whether to stage or to point
  -- staff at the Give buttons. It is deliberately the only place this screen decides that.
  if v_intent.gift_kind = 'tier_perk' then
    select * into v_benefit from public.tier_benefits_v365
     where id = v_intent.benefit_id and business_id = p_business
       and deleted_at is null and active;
    v_stageable := found
      and v_benefit.benefit_kind = 'discount_pct'
      and coalesce(v_benefit.discount_percent,0) > 0
      and v_benefit.limit_count is not null;
    if found then
      v_benefit_kind := v_benefit.benefit_kind;
      -- v681: a free item or a written perk is handed over; only a percentage needs a bill.
      v_settle_now := v_benefit.benefit_kind <> 'discount_pct';
    end if;
  else
    -- v681: welcome / bring-back / referral. Only a quoted minimum spend makes one of these wait
    -- for a sale — staff_redeem_welcome_offer_v215 asks for a qualifying sale if and only if
    -- min_spend_cents > 0, and the bring-back and referral redeemers take no sale at all.
    v_settle_now := coalesce(v_intent.quoted_min_spend_cents,0) = 0;
  end if;

  return app.v666_till_customer_card(p_business, v_intent.client_id)
         || jsonb_build_object(
              'gift_kind', v_intent.gift_kind,
              'gift_label', v_intent.quoted_label,
              'benefit_id', v_intent.benefit_id,
              'benefit_kind', v_benefit_kind,
              'min_spend_cents', coalesce(v_intent.quoted_min_spend_cents,0),
              'settle_now', v_settle_now,
              'stageable', v_stageable);
end
$function$;

-- Grants restated verbatim from the live proacl for the function replaced.
revoke all on function public.staff_scan_gift_qr_to_till_v666(uuid,text) from public, anon;
grant execute on function public.staff_scan_gift_qr_to_till_v666(uuid,text) to authenticated;

commit;
