-- Rollback-only v682 acceptance suite (owner ruling 2026-09-02, follow-up to v681).
--
--   T1  A 'custom' (free-text) perk does NOT offer settle_now, and is not stageable either — it
--       goes back to the Rewards tab's Give button. Jess Salon's own custom perk is literally
--       labelled "10% off 1 item", which is the owner's example of a reward that needs a bill.
--   T2  A free_item perk still offers settle_now: v681's rule survives, narrowed not removed.
--   T3  A metered percentage perk still stages and still refuses settle_now.
--   T4  A welcome gift with no minimum spend still offers settle_now (unchanged by v682).
--   T5  Asking still spends nothing — the intents stay pending, no allowance moved.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v682_evidence(test text, detail text) on commit drop;

do $v682$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';   -- Jess Salon
  v_owner uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab'; -- its owner's auth user
  v_custom uuid := '4f9f40fb-ab86-4730-86af-8e69c5dba0b3'; -- Gold "10% off 1 item", benefit_kind custom
  v_pct uuid := '99add802-c233-43b6-ab81-f6158ff18985';   -- Gold "10% off", discount_pct, 1/month
  v_item uuid := '396a19d4-5790-4396-9671-b1d185f34fc5';  -- Gold "Free Free Hair Wax", free_item
  v_client uuid; v_identity uuid; v_customer_user uuid;
  v_period text; v_token text; v_res jsonb; v_count integer; v_before integer; v_status text;
  v_welcome_grant uuid := gen_random_uuid();
  v_intent_custom uuid;
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

  update public.customer_gift_intents_v515 set status='expired'
   where business_id=v_biz and client_id=v_client and status='pending';

  v_period := app.v365_period_key('month', now());
  /* This client may legitimately have used one of these perks already this period, so T5 measures
     the DELTA across the scans rather than asserting an empty table. */
  select count(*) into v_before from public.tier_benefit_issues_v365
   where benefit_id in (v_custom, v_item, v_pct) and client_id=v_client and period_key=v_period
     and reversed_at is null;

  -- T1 — the custom perk ------------------------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_custom, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_custom,'10% off 1 item',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_custom::text), now()+interval '15 minutes')
  returning id into v_intent_custom;

  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if v_res->>'status' <> 'found' then raise exception 'T1 the custom-perk QR did not resolve: %', v_res; end if;
  if v_res->>'benefit_kind' <> 'custom' then
    raise exception 'T1 the fixture is not a custom perk any more: %', v_res; end if;
  if (v_res->>'settle_now')::boolean then
    raise exception 'T1 a written perk must not be offered as a no-purchase gift: %', v_res; end if;
  if (v_res->>'stageable')::boolean then
    raise exception 'T1 a custom perk is not stageable either: %', v_res; end if;
  insert into v682_evidence values('T1','a written perk is neither settled on sight nor staged');

  -- T2 — the free item still settles ---------------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_item, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_item,'Free Free Hair Wax',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_item::text), now()+interval '15 minutes');
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean is not true or v_res->>'benefit_kind' <> 'free_item' then
    raise exception 'T2 a free item must still offer settle_now: %', v_res; end if;
  insert into v682_evidence values('T2','a free item still offers the yes/no hand-over');

  -- T3 — the percentage discount is untouched --------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_pct,'10% off',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_pct::text), now()+interval '15 minutes');
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean or (v_res->>'stageable')::boolean is not true then
    raise exception 'T3 a percentage discount must still stage and never settle: %', v_res; end if;
  insert into v682_evidence values('T3','a percentage discount still stages onto the bill');

  -- T4 — the welcome gift is untouched ----------------------------------------------------------------
  v_token := app.v89_redemption_token(v_identity, v_biz, 'welcome_v515', v_welcome_grant, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,grant_id,quoted_label,quoted_min_spend_cents,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'welcome',v_welcome_grant,'Free coffee',0,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':welcome:'||v_welcome_grant::text), now()+interval '15 minutes');
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if (v_res->>'settle_now')::boolean is not true then
    raise exception 'T4 a no-spend welcome gift must still offer settle_now: %', v_res; end if;
  insert into v682_evidence values('T4','a no-spend welcome gift is unchanged by this narrowing');

  -- T5 — nothing was spent -----------------------------------------------------------------------------
  select status into v_status from public.customer_gift_intents_v515 where id=v_intent_custom;
  if v_status <> 'pending' then raise exception 'T5 asking the question spent the QR (now %)', v_status; end if;
  select count(*) into v_count from public.tier_benefit_issues_v365
   where benefit_id in (v_custom, v_item, v_pct) and client_id=v_client and period_key=v_period
     and reversed_at is null;
  if v_count <> v_before then
    raise exception 'T5 asking the question burned an allowance (% -> %)', v_before, v_count; end if;
  insert into v682_evidence values('T5','a look still spends nothing — intents pending, allowances intact');
end
$v682$;

select * from v682_evidence order by test;
rollback;
