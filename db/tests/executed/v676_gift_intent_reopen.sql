-- Rollback-only acceptance for nestly_v676 — re-tapping "Show QR at counter" reopens the QR.
-- Run: supabase db query --linked -f db/tests/v676_gift_intent_reopen.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Audit F048 (client) / F056 (server): a customer who closed the gift QR sheet by any route
-- except "Cancel redemption" left a live pending intent behind; the next tap carried a fresh
-- idempotency key, missed the v665 replay branch, survived the stand-down (which only expires
-- rows already past expires_at) and violated customer_gift_intents_v515_open_uk with 23505,
-- so the customer was locked out of their own gift for up to 15 minutes.
--
--   01  a re-tap with a DIFFERENT key returns the SAME intent, token and expiry — one row
--   02  the rule stays one pending QR per GIFT, not per customer: another gift still mints
--   03  the reopened token is the one the counter scans; it redeems the real grant
--   04  a redeemed gift is not reopened — the customer is refused at mint, not handed a dead QR
--   05  an EXPIRED pending row is still stood down, and the re-tap mints a genuinely new QR
--   06  a CANCELLED intent is never reopened — cancelling then re-tapping mints a fresh QR
--   07  the same key twice still replays (the v665 branch this change must not disturb)
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v676_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v676_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v676-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_tier uuid := gen_random_uuid();
  v_benefit uuid := gen_random_uuid();
  v_grant uuid;
  v_key_a uuid := gen_random_uuid();
  v_key_b uuid := gen_random_uuid();
  v_key_c uuid;
  v_perk_intent uuid;
  v_a jsonb; v_b jsonb; v_c jsonb; v_n integer; v_err text; v_status text;
begin
  -- ================================ FIXTURE ================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V676 Acceptance', v_slug, array['loyalty','clients','till','sales'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner,'authenticated','authenticated',
          'zz-v676-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000', v_cust,'authenticated','authenticated',
          'zz-v676-c-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner,'owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch, v_biz, 'V676 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v676', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id) values (v_biz) on conflict do nothing;

  perform pg_temp.as_v676_user(v_owner);
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, earn_points_per_dollar)
  values (v_biz, false, 'classic','points','draft', 1);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points',true,'tiers',true), gen_random_uuid());

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client, v_biz, 'V676 Customer','+65 9676 1001');
  insert into public.customer_identities(id,auth_user_id,status) values (v_identity,v_cust,'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- a welcome gift with NO minimum spend, so a scan needs no sale
  insert into public.business_welcome_offers_v215(business_id, active, reward_label,
    reward_catalog_kind, reward_catalog_id, custom_label, min_spend_cents, expiry_days)
  values (v_biz, true, 'V676 Free Drink','custom',null,'V676 Free Drink',0,30);
  perform app.issue_welcome_offer_v215(v_biz, v_client);
  select id into v_grant from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_client;

  -- a metered tier perk the customer has reached
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values (v_tier, v_biz, 'V676 Gold', 0, 1, 1);
  insert into public.tier_benefits_v365(id,business_id,tier_id,label,limit_count,limit_period,
                                        sort,active,benefit_kind,discount_percent)
  values (v_benefit, v_biz, v_tier, '50% off — 1 per month', 1, 'month', 1, true, 'discount_pct', 50);

  -- ================ 01  THE RE-TAP REOPENS, IT DOES NOT COLLIDE ================
  -- The customer taps, closes the sheet without cancelling, and taps again. The second tap
  -- carries a brand-new key, exactly as the app mints it.
  perform pg_temp.as_v676_user(v_cust);
  v_a := public.customer_create_gift_intent_v515(v_biz,'welcome',v_grant,v_key_a);
  v_b := public.customer_create_gift_intent_v515(v_biz,'welcome',v_grant,v_key_b);
  select count(*) into v_n from public.customer_gift_intents_v515
   where business_id=v_biz and client_id=v_client and gift_kind='welcome';
  insert into _r values('01_retap_reopens_same_qr',
    case when v_a->>'status'='pending'
          and v_b->>'intent_id' = v_a->>'intent_id'
          and v_b->>'qr_token'  = v_a->>'qr_token'
          and v_b->>'expires_at'= v_a->>'expires_at'
          and (v_b->>'replayed')::boolean and v_n=1
      then 'PASS a re-tap under a new key returned the same pending QR, and only one row exists'
      else 'FAIL rows='||v_n||' a='||coalesce(v_a::text,'null')||' b='||coalesce(v_b::text,'null') end);

  -- ================ 02  ONE PENDING QR PER GIFT, NOT PER CUSTOMER ================
  -- The welcome QR above is still pending. A DIFFERENT gift must still mint its own.
  v_c := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  select count(*) into v_n from public.customer_gift_intents_v515
   where business_id=v_biz and client_id=v_client and status='pending';
  insert into _r values('02_other_gift_still_mints',
    case when v_c->>'status'='pending' and coalesce((v_c->>'replayed')::boolean,true)=false and v_n=2
      then 'PASS a second gift minted its own QR — the rule is per gift, not per customer'
      else 'FAIL pending_rows='||v_n||' perk='||coalesce(v_c::text,'null') end);

  -- ================ 03  THE REOPENED TOKEN IS A REAL, SCANNABLE QR ================
  perform pg_temp.as_v676_user(v_owner);
  v_c := public.staff_scan_gift_qr_v515(v_biz, v_branch, v_b->>'qr_token', null, gen_random_uuid());
  select status into v_status from public.welcome_offer_grants_v215 where id=v_grant;
  insert into _r values('03_reopened_token_scans',
    case when v_c->>'status'='completed' and v_status='redeemed'
      then 'PASS the counter scanned the reopened token and it redeemed the real grant'
      else 'FAIL scan='||coalesce(v_c->>'status','null')||' grant='||coalesce(v_status,'null') end);

  -- ================ 04  A REDEEMED GIFT IS NOT REOPENED ================
  -- That intent is 'completed' now, so the reopen lookup (pending only) must not see it and the
  -- eligibility check must refuse: no QR for a gift that has already been given.
  perform pg_temp.as_v676_user(v_cust);
  v_err := '';
  begin
    perform public.customer_create_gift_intent_v515(v_biz,'welcome',v_grant,gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('04_redeemed_gift_not_reopened',
    case when v_err like '%not available%'
      then 'PASS a spent gift is refused at mint rather than reopened as a dead QR'
      else 'FAIL '||coalesce(nullif(v_err,''),'a QR was minted for an already redeemed gift') end);

  -- ================ 05  AN EXPIRED PENDING ROW IS STILL STOOD DOWN ================
  -- now() is frozen for this whole rollback-only transaction (transaction_timestamp semantics),
  -- and customer_gift_intents_v515_expiry_check requires expires_at > created_at, which also
  -- defaults to that same frozen now() — so an UPDATE can never backdate expires_at into the
  -- past relative to "now" as the RPC sees it. app.v515_gift_intent_guard fires only on
  -- UPDATE/DELETE (before delete or update — never insert), so instead: cancel the live pending
  -- intent through the real RPC (frees customer_gift_intents_v515_open_uk), then INSERT a
  -- synthetic already-lapsed PENDING row copying its provenance columns, with an explicit past
  -- created_at/expires_at pair that satisfies the check constraint (expires_at > created_at) and
  -- is still <= the frozen now() the stand-down UPDATE inside the RPC compares against.
  select id into v_perk_intent from public.customer_gift_intents_v515
   where business_id=v_biz and client_id=v_client and gift_kind='tier_perk' and status='pending';
  perform public.customer_cancel_gift_intent_v515(v_perk_intent, gen_random_uuid());
  insert into public.customer_gift_intents_v515(
    id, business_id, identity_id, auth_user_id, client_id, gift_kind, grant_id, benefit_id,
    quoted_label, quoted_min_spend_cents, quoted_period_key, quoted_terms,
    token_hash, idempotency_key, request_hash, status, expires_at, created_at)
  select gen_random_uuid(), business_id, identity_id, auth_user_id, client_id, gift_kind, grant_id,
    benefit_id, quoted_label, quoted_min_spend_cents, quoted_period_key, quoted_terms,
    app.v89_sha256(gen_random_uuid()::text), gen_random_uuid(), request_hash,
    'pending', now() - interval '1 minute', now() - interval '20 minutes'
  from public.customer_gift_intents_v515
  where id = v_perk_intent
  returning id into v_perk_intent;
  v_b := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  select status into v_status from public.customer_gift_intents_v515 where id = v_perk_intent;
  insert into _r values('05_expired_row_stood_down',
    case when (v_b->>'intent_id')::uuid <> v_perk_intent
          and coalesce((v_b->>'replayed')::boolean,true) = false
          and v_status='expired'
      then 'PASS a lapsed QR is expired and the re-tap minted a genuinely new one'
      else 'FAIL old='||coalesce(v_status,'null')||' new='||coalesce(v_b::text,'null') end);

  -- ================ 06  A CANCELLED INTENT IS NEVER REOPENED ================
  perform public.customer_cancel_gift_intent_v515((v_b->>'intent_id')::uuid, gen_random_uuid());
  v_c := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  select status into v_status from public.customer_gift_intents_v515
   where id = (v_b->>'intent_id')::uuid;
  insert into _r values('06_cancelled_not_reopened',
    case when v_status='cancelled' and v_c->>'intent_id' <> v_b->>'intent_id'
          and coalesce((v_c->>'replayed')::boolean,true) = false
      then 'PASS cancelling really cancels; the next tap mints a fresh QR'
      else 'FAIL cancelled='||coalesce(v_status,'null')||' next='||coalesce(v_c::text,'null') end);

  -- ================ 07  THE SAME KEY STILL REPLAYS (v665 branch intact) ================
  -- With no pending row in the way, the first call MINTS and the second REPLAYS on the key.
  perform public.customer_cancel_gift_intent_v515((v_c->>'intent_id')::uuid, gen_random_uuid());
  v_key_c := gen_random_uuid();
  v_a := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,v_key_c);
  v_b := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,v_key_c);
  insert into _r values('07_same_key_still_replays',
    case when coalesce((v_a->>'replayed')::boolean,true)=false
          and v_b->>'qr_token' = v_a->>'qr_token'
          and v_b->>'intent_id' = v_a->>'intent_id'
          and (v_b->>'replayed')::boolean
      then 'PASS the original same-key replay is untouched'
      else 'FAIL a='||coalesce(v_a::text,'null')||' b='||coalesce(v_b::text,'null') end);
end $$;

select * from _r order by k;
rollback;
