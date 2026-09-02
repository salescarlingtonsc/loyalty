-- Rollback-only v681 acceptance suite (owner ruling 2026-09-02, keypad "Scan" screenshot).
--
--   T1  A free-item tier perk answers settle_now=true (and stays not stageable), so the till can
--       ask the counter to confirm handing it over.
--   T2  A metered percentage perk answers settle_now=false and stageable=true — the usual
--       process: it goes on the bill, it is not handed over on sight.
--   T3  A welcome gift with NO minimum spend answers settle_now=true and min_spend_cents=0.
--   T4  The SAME welcome gift with a minimum spend answers settle_now=false — it waits for the
--       sale, exactly as staff_redeem_welcome_offer_v215 requires.
--   T5  Answering the question still spends nothing: the intents stay pending, no allowance moved.
--   T6  settle_now and stageable are never both true, and the customer card is intact.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v681_evidence(test text, detail text) on commit drop;

do $v681$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';   -- Jess Salon
  v_owner uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab'; -- its owner's auth user
  v_pct uuid := '99add802-c233-43b6-ab81-f6158ff18985';   -- Gold "10% off", discount_pct, 1/month
  v_item uuid := '396a19d4-5790-4396-9671-b1d185f34fc5';  -- Gold "Free Free Hair Wax", free_item
  v_client uuid; v_identity uuid; v_customer_user uuid;
  v_period text; v_token text; v_res jsonb; v_count integer; v_status text;
  v_welcome_grant uuid := gen_random_uuid();
  v_intent_item uuid; v_intent_pct uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select ci.id, ci.auth_user_id, l.client_id into v_identity, v_customer_user, v_client
    from public.customer_identities ci
    join public.customer_links l on l.identity_id=ci.id and l.business_id=v_biz
                                and l.state='verified'
   where ci.status='active' limit 1;
  if v_identity is null then
    raise exception 'FIXTURE: Jess Salon has no verified customer link, so no QR can exist';
  end if;

  -- customer_gift_intents_v515_open_uk allows one live QR per gift per customer.
  update public.customer_gift_intents_v515 set status='expired'
   where business_id=v_biz and client_id=v_client and status='pending';

  v_period := app.v365_period_key('month', now());

  -- T1 — free item -----------------------------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_item, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_item,'Free Free Hair Wax',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_item::text), now()+interval '15 minutes')
  returning id into v_intent_item;

  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if v_res->>'status' <> 'found' then raise exception 'T1 the free-item QR did not resolve: %', v_res; end if;
  if (v_res->>'settle_now')::boolean is not true then
    raise exception 'T1 a free item needs no purchase and must offer settle_now: %', v_res; end if;
  if (v_res->>'stageable')::boolean then
    raise exception 'T1 a free item must not be stageable: %', v_res; end if;
  if v_res->>'benefit_kind' <> 'free_item' then
    raise exception 'T1 benefit_kind was not reported: %', v_res; end if;
  insert into v681_evidence values('T1','a free-item perk offers a yes/no hand-over at the scan');

  -- T2 — percentage discount --------------------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_pct,'10% off',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_pct::text), now()+interval '15 minutes')
  returning id into v_intent_pct;

  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean then
    raise exception 'T2 a percentage discount requires a purchase and must not settle on sight: %', v_res; end if;
  if (v_res->>'stageable')::boolean is not true then
    raise exception 'T2 a metered discount perk should still be stageable: %', v_res; end if;
  insert into v681_evidence values('T2','a percentage discount keeps the usual bill-first process');

  -- T3 — welcome gift, no minimum spend ---------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'welcome_v515', v_welcome_grant, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,grant_id,quoted_label,quoted_min_spend_cents,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'welcome',v_welcome_grant,'Free coffee',0,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':welcome:'||v_welcome_grant::text), now()+interval '15 minutes');

  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean is not true then
    raise exception 'T3 a welcome gift with no minimum spend must offer settle_now: %', v_res; end if;
  if (v_res->>'min_spend_cents') <> '0' then
    raise exception 'T3 min_spend_cents was not reported as zero: %', v_res; end if;
  insert into v681_evidence values('T3','a no-spend welcome gift offers a yes/no hand-over');

  -- T4 — the same gift, with a minimum spend -----------------------------------------------------
  update public.customer_gift_intents_v515 set status='expired'
   where business_id=v_biz and client_id=v_client and status='pending' and gift_kind='welcome';
  v_welcome_grant := gen_random_uuid();
  v_token := app.v89_redemption_token(v_identity, v_biz, 'welcome_v515', v_welcome_grant, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,grant_id,quoted_label,quoted_min_spend_cents,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'welcome',v_welcome_grant,'Free coffee over $20',2000,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':welcome:'||v_welcome_grant::text), now()+interval '15 minutes');

  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean then
    raise exception 'T4 a min-spend welcome gift must wait for the sale: %', v_res; end if;
  if (v_res->>'min_spend_cents') <> '2000' then
    raise exception 'T4 the quoted minimum spend was not reported: %', v_res; end if;
  if (v_res->>'stageable')::boolean then
    raise exception 'T4 a welcome gift is never stageable: %', v_res; end if;
  insert into v681_evidence values('T4','a min-spend welcome gift still waits for a qualifying sale');

  -- T5 — asking spends nothing --------------------------------------------------------------------
  select status into v_status from public.customer_gift_intents_v515 where id=v_intent_item;
  if v_status <> 'pending' then raise exception 'T5 asking the question spent the QR (now %)', v_status; end if;
  select count(*) into v_count from public.tier_benefit_issues_v365
   where benefit_id in (v_item, v_pct) and client_id=v_client and period_key=v_period
     and reversed_at is null;
  if v_count <> 0 then raise exception 'T5 asking the question burned an allowance'; end if;
  insert into v681_evidence values('T5','a look still spends nothing — intents pending, allowances intact');

  -- T6 — the two answers never overlap, and the card is intact -------------------------------------
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean and (v_res->>'stageable')::boolean then
    raise exception 'T6 settle_now and stageable must be mutually exclusive: %', v_res; end if;
  if not (v_res ?& array['status','client_id','full_name','phone','points','credit_cents',
                         'visits','gift_kind','gift_label','benefit_id','benefit_kind',
                         'min_spend_cents','settle_now','stageable']) then
    raise exception 'T6 the scan payload dropped a field the till reads: %', v_res; end if;
  insert into v681_evidence values('T6','settle_now and stageable never both true; card fields intact');
end
$v681$;

select * from v681_evidence order by test;
rollback;
