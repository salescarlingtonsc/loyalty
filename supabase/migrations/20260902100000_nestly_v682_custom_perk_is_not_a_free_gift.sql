-- NESTLY v682 — a written ("custom") tier perk is not treated as a no-purchase free gift.
--
-- OWNER RULING (2026-09-02, follow-up to v681): "i think remove custom (because it would cause
-- issues in the future). those existing ones ignore it as it is a sample only."
--
-- WHAT v681 GOT TOO WIDE. v681 taught staff_scan_gift_qr_to_till_v666 to answer settle_now — may
-- the counter hand this gift over on a yes/no, with no bill involved. For a tier perk it said
-- "anything that is not a percentage discount", which swept in benefit_kind='custom': free text
-- the owner typed, which may perfectly well read "10% off your next colour" or "free item with
-- any $50 spend". Nothing in the row says whether money is required, so the server cannot
-- honestly promise it is not.
--
-- THE RULE NOW. A tier perk offers settle_now only when its benefit_kind is 'free_item' — the one
-- kind whose meaning is fixed by the schema rather than by prose. 'discount_pct' keeps the
-- staging path (v665/v666), and 'custom' returns to the pre-v681 behaviour: the customer is
-- opened on screen and the perk is handed over from the Rewards tab's Give button, where a human
-- reads the words before deciding. Welcome, bring-back and referral gifts are unchanged — their
-- purchase requirement is a real column (quoted_min_spend_cents), not prose.
--
-- NOTHING TO BACKFILL. settle_now is computed per scan and stored nowhere; no gift was mis-issued
-- by v681 (the redeemers each re-check their own predicate), so this is a pure narrowing of the
-- advice the till is given.

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
      -- v682 (owner ruling): ONLY a free_item. A 'custom' perk is free text that may itself
      -- demand a purchase, so the server refuses to promise it does not — it goes back to the
      -- Rewards tab's Give button, where a person reads the words first.
      v_settle_now := v_benefit.benefit_kind = 'free_item';
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
