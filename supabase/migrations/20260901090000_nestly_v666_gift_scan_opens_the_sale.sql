-- nestly_v666 — a gift QR scanned at the keypad opens the sale instead of burning the voucher.
--
-- OWNER REPORT (2026-09-01, photo 2): "when i press scan on vouchers - it does nothing but used
-- up the customer's voucher. it did not auto enter customer number".
--
-- WHAT WAS WRONG, AND IT WAS v665'S OWN GAP. v665 taught the till to STAGE a scanned tier perk
-- onto the open bill instead of settling it, but wired that only into the two scanners that live
-- INSIDE a sale (#tEntitlementScan and #tGiftScanV392) — the ones reachable after a customer has
-- already been found. The Record sale screen opens on the PHONE KEYPAD, and its "Scan" button
-- (#tScanRedemption) was left on the pre-v665 path: a gift QR fell through to
-- staff_scan_gift_qr_v515, which settled it on sight, and the scanner's onComplete then called
-- resetToStart(). So the one scan a counter actually reaches first spent the customer's voucher
-- and returned to an empty keypad — no customer, no sale, nothing to show for it. That is exactly
-- the behaviour the owner asked to be removed, surviving in the one place it was most visible.
--
-- THE RULE THIS SETTLES: a gift QR scanned at the keypad IDENTIFIES, it does not spend. It
-- resolves whose QR it is, opens the sale on that customer, and leaves the reward to be applied
-- (a discount perk, through v665's staging) or handed over (everything else, through the Give
-- buttons already on the Rewards tab). Nothing about it is consumed by being looked at.
--
-- WHY A READ-ONLY FUNCTION AND NOT A WIDENED SCANNER. staff_scan_gift_qr_v515 settles, and
-- staff_stage_gift_qr_v665 spends the QR. Neither can answer "whose is this?" without also doing
-- its own job, and the keypad needs the answer BEFORE it has a cart to put anything in. So this
-- adds a third, STABLE function that only reads. Staging still happens in exactly one place —
-- the till calls staff_stage_gift_qr_v665 once the customer is on screen — so there is no second
-- writer and no second answer to "was this QR used".
--
-- ONE CUSTOMER CARD, NOT TWO. The keypad's phone lookup, its member-QR scan and now its gift-QR
-- scan all put the same object on screen. Two of them built it independently, which is how they
-- start disagreeing about a balance. app.v666_till_customer_card is now the single builder, and
-- staff_scan_member_qr_v327 is re-created to call it — byte-for-byte the same payload it
-- returned before, plus its own newly_linked flag, which only the provisioning path knows.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The one customer card the till shows, wherever the customer came from.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v666_till_customer_card(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_client public.clients%rowtype;
  v_points integer;
  v_credit integer;
  v_visits integer;
  lp record;
begin
  select * into v_client from public.clients
   where id = p_client and business_id = p_business;
  if not found then
    return jsonb_build_object('status','invalid','message','This customer is not in this business.');
  end if;

  v_points := app.client_points_balance_v409(p_business, v_client.id);
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=v_client.id;
  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=v_client.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;

  return jsonb_build_object(
    'status','found','client_id',v_client.id,'full_name',v_client.full_name,
    'phone',v_client.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',v_client.created_at);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 2. Whose QR is this? A pure read — it settles nothing and stages nothing.
-- ---------------------------------------------------------------------------------------------
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
  end if;

  return app.v666_till_customer_card(p_business, v_intent.client_id)
         || jsonb_build_object(
              'gift_kind', v_intent.gift_kind,
              'gift_label', v_intent.quoted_label,
              'benefit_id', v_intent.benefit_id,
              'stageable', v_stageable);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 3. The member-QR scan, live definition, now sharing the one customer card.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staff_scan_member_qr_v327(p_business uuid, p_member_qr text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_token text;
  v_hash text;
  v_identity public.customer_identities%rowtype;
  v_link public.customer_links%rowtype;
  v_client public.clients%rowtype;
  v_actor uuid := auth.uid();
  v_display_name text;
  v_link_id uuid;
  v_created boolean := false;
  v_points integer;
  v_credit integer;
  v_visits integer;
  lp record;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_write(p_business, 'clients') then
    raise exception 'clients write and create-sales authorization is required'
      using errcode='42501';
  end if;

  v_token := btrim(coalesce(p_member_qr,''));
  if v_token like 'nestly:member:%' then
    v_token := substring(v_token from length('nestly:member:')+1);
  end if;
  if v_token !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status','invalid','message','This QR is not a Peekaa member code.');
  end if;
  v_hash := app.v89_sha256(v_token);

  perform pg_advisory_xact_lock(hashtextextended('v327:scan:'||p_business::text||':'||v_hash,0));

  select * into v_identity from public.customer_identities
   where qr_token_hash = v_hash for share;
  if not found or v_identity.status <> 'active' then
    return jsonb_build_object('status','invalid','message','This member QR is no longer active.');
  end if;

  select * into v_link from public.customer_links
   where business_id=p_business and identity_id=v_identity.id and state='verified'
   order by created_at desc limit 1
   for update;

  if found then
    select * into v_client from public.clients where id=v_link.client_id and business_id=p_business;
  else
    select coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''), 'Peekaa Member')
      into v_display_name
      from auth.users u where u.id=v_identity.auth_user_id;

    perform set_config('app.first_acquired_via','qr_scan_provisioned',true);
    insert into public.clients (business_id, full_name)
    values (p_business, v_display_name)
    returning * into v_client;

    -- nestly_v513: an app member scanning in at a business they had not joined is auto-provisioned
    -- here — that is a sign-up.
    perform app.issue_welcome_offer_v215(p_business, v_client.id);

    v_link_id := gen_random_uuid();
    perform set_config('app.customer_link_insert_id', v_link_id::text, true);
    insert into public.customer_links (
      id, business_id, identity_id, auth_user_id, client_id, state,
      verification_method, verified_at
    ) values (
      v_link_id, p_business, v_identity.id, v_identity.auth_user_id, v_client.id, 'verified',
      'qr_scan', now()
    )
    returning * into v_link;
    perform set_config('app.customer_link_insert_id', '', true);
    v_created := true;

    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business, v_actor, 'AUTO_PROVISION_CLIENT_FROM_MEMBER_QR_V327',
      'clients', v_client.id, jsonb_build_object('identity_id', v_identity.id, 'link_id', v_link.id));
  end if;

  -- nestly_v666: the customer card this returns is now built by app.v666_till_customer_card, so
  -- the gift-QR scan below it cannot answer "who is this and what do they hold" differently.
  -- Byte-for-byte the same object as before, plus newly_linked, which only this path knows.
  return app.v666_till_customer_card(p_business, v_client.id)
         || jsonb_build_object('newly_linked', v_created);
end $function$
;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants. Restated verbatim from the live proacl for what is replaced; explicit for the new.
-- ---------------------------------------------------------------------------------------------
revoke all on function app.v666_till_customer_card(uuid,uuid) from public, anon, authenticated;

revoke all on function public.staff_scan_gift_qr_to_till_v666(uuid,text) from public, anon;
grant execute on function public.staff_scan_gift_qr_to_till_v666(uuid,text) to authenticated;

revoke all on function public.staff_scan_member_qr_v327(uuid,text) from public, anon;
grant execute on function public.staff_scan_member_qr_v327(uuid,text) to authenticated, service_role;

commit;
