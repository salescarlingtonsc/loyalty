-- Rollback-only acceptance for nestly_v515 — every gift a customer holds carries a QR.
-- Run: supabase db query --linked -f db/tests/v515_a_qr_on_every_gift.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Owner ruling (2026-08-25, photo 2): "all rewards and gifts must have a qrcode tagged to it for
-- customer to press and let business scan." Before this, only point/stamp catalogue rewards had a
-- QR; the four GIVEN things (welcome, bring-back, referral, tier perk) were staff-only.
--
--   01  a welcome gift mints a QR, and a replay of the same key returns the SAME token, one row
--   02  staff scanning it redeems the real grant; a second scan replays instead of double-giving
--   03  a tier perk with "1 per month" mints, scans, and consumes exactly ONE allowance —
--       and a second scan of the same token does not burn a second one
--   04  once spent for the period, a fresh mint is refused at mint time
--   05  an UNLIMITED automatic perk gets NO QR (owner ruling: checkout already applies it)
--   06  the intent table is unreachable from the browser role, and its provenance is immutable
--   07  a stranger cannot mint a QR against someone else's gift
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v515_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v515_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v515-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_tier uuid := gen_random_uuid();
  v_benefit uuid := gen_random_uuid();
  v_auto uuid := gen_random_uuid();
  v_grant uuid;
  v_idem uuid := gen_random_uuid();
  v_a jsonb; v_b jsonb; v_n integer; v_err text; v_tok text; v_tok2 text;
begin
  -- ================================ FIXTURE ================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V515 Acceptance', v_slug, array['loyalty','clients','till','sales'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner,'authenticated','authenticated',
          'zz-v515-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000', v_cust,'authenticated','authenticated',
          'zz-v515-c-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000', v_stranger,'authenticated','authenticated',
          'zz-v515-s-'||substr(v_stranger::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner,'owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch, v_biz, 'V515 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v515', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v515_user(v_owner);
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, earn_points_per_dollar)
  values (v_biz, false, 'classic','points','draft', 1);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points',true,'tiers',true), gen_random_uuid());

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client, v_biz, 'V515 Customer','+65 9515 1001');
  insert into public.customer_identities(id,auth_user_id,status) values (v_identity,v_cust,'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- a welcome gift with NO minimum spend, so a scan needs no sale
  insert into public.business_welcome_offers_v215(business_id, active, reward_label,
    reward_catalog_kind, reward_catalog_id, custom_label, min_spend_cents, expiry_days)
  values (v_biz, true, 'V515 Free Drink','custom',null,'V515 Free Drink',0,30);
  perform app.issue_welcome_offer_v215(v_biz, v_client);
  select id into v_grant from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_client;

  -- a tier the customer is in, with a metered perk and an unlimited automatic one
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values (v_tier, v_biz, 'V515 Gold', 0, 1, 1);
  insert into public.tier_benefits_v365(id,business_id,tier_id,label,limit_count,limit_period,
                                        sort,active,benefit_kind,discount_percent)
  values (v_benefit, v_biz, v_tier, '50% off — 1 per month', 1, 'month', 1, true, 'discount_pct', 50),
         (v_auto,    v_biz, v_tier, '10% off always',        null,'month', 2, true, 'discount_pct', 10);

  -- ================ 01  MINT + REPLAY ================
  perform pg_temp.as_v515_user(v_cust);
  v_a := public.customer_create_gift_intent_v515(v_biz,'welcome',v_grant,v_idem);
  v_b := public.customer_create_gift_intent_v515(v_biz,'welcome',v_grant,v_idem);
  v_tok := v_a->>'qr_token';
  select count(*) into v_n from public.customer_gift_intents_v515
   where business_id=v_biz and client_id=v_client and gift_kind='welcome';
  insert into _r values('01_mint_and_replay',
    case when v_a->>'status'='pending' and v_tok is not null
          and v_b->>'qr_token' = v_tok and (v_b->>'replayed')::boolean and v_n=1
      then 'PASS a welcome gift mints one QR; the same key replays the same token'
      else 'FAIL rows='||v_n||' a='||coalesce(v_a::text,'null')||' b='||coalesce(v_b::text,'null') end);

  -- ================ 02  STAFF SCAN + REPLAY ================
  perform pg_temp.as_v515_user(v_owner);
  v_a := public.staff_scan_gift_qr_v515(v_biz, v_branch, v_tok, null, gen_random_uuid());
  select status into v_err from public.welcome_offer_grants_v215 where id=v_grant;
  v_b := public.staff_scan_gift_qr_v515(v_biz, v_branch, v_tok, null, gen_random_uuid());
  select count(*) into v_n from public.welcome_offer_grants_v215
   where id=v_grant and status='redeemed';
  insert into _r values('02_scan_redeems_and_replays',
    case when v_a->>'status'='completed' and v_err='redeemed'
          and (v_b->>'replayed')::boolean and v_n=1
      then 'PASS staff scanning the QR redeemed the real grant; a second scan replayed'
      else 'FAIL scan='||coalesce(v_a->>'status','null')||' grant='||coalesce(v_err,'null')
           ||' replay='||coalesce(v_b->>'replayed','null') end);

  -- ================ 03  TIER PERK: ONE ALLOWANCE ================
  perform pg_temp.as_v515_user(v_cust);
  v_a := public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  v_tok2 := v_a->>'qr_token';
  perform pg_temp.as_v515_user(v_owner);
  v_b := public.staff_scan_gift_qr_v515(v_biz, v_branch, v_tok2, null, gen_random_uuid());
  perform public.staff_scan_gift_qr_v515(v_biz, v_branch, v_tok2, null, gen_random_uuid());
  select count(*) into v_n from public.tier_benefit_issues_v365
   where benefit_id=v_benefit and client_id=v_client;
  insert into _r values('03_perk_consumes_exactly_one',
    case when v_b->>'status'='completed' and v_n=1
      then 'PASS the monthly perk was issued once; a second scan of the same QR burned nothing'
      else 'FAIL scan='||coalesce(v_b->>'status','null')||' issues='||v_n end);

  -- ================ 04  SPENT FOR THE PERIOD -> REFUSED AT MINT ================
  perform pg_temp.as_v515_user(v_cust);
  v_err := '';
  begin
    perform public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('04_spent_perk_refused_at_mint',
    case when v_err like '%used this perk%'
      then 'PASS once the month is spent the customer is refused a QR, not handed a dead one'
      else 'FAIL '||coalesce(nullif(v_err,''),'the mint succeeded') end);

  -- ================ 05  UNLIMITED AUTO PERK GETS NO QR ================
  v_err := '';
  begin
    perform public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_auto,gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('05_auto_perk_has_no_qr',
    case when v_err like '%applied automatically%'
      then 'PASS an unlimited perk keeps its automatic application and offers no QR'
      else 'FAIL '||coalesce(nullif(v_err,''),'a QR was minted for an unmetered perk') end);

  -- ================ 06  TABLE IS SEALED, PROVENANCE IMMUTABLE ================
  v_err := '';
  begin
    update public.customer_gift_intents_v515 set gift_kind='referral'
     where business_id=v_biz and gift_kind='welcome';
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('06_provenance_immutable',
    case when v_err like '%immutable%' then 'PASS the provenance tuple cannot be rewritten'
         else 'FAIL '||coalesce(nullif(v_err,''),'the update succeeded') end);
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema='public' and table_name='customer_gift_intents_v515'
     and grantee in ('anon','authenticated');
  insert into _r values('06_sealed_from_browser',
    case when v_n=0 then 'PASS the browser roles hold no grant on the intent table'
         else 'FAIL '||v_n||' grants to anon/authenticated' end);

  -- ================ 07  A STRANGER CANNOT MINT ================
  perform pg_temp.as_v515_user(v_stranger);
  v_err := '';
  begin
    perform public.customer_create_gift_intent_v515(v_biz,'tier_perk',v_benefit,gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('07_stranger_refused',
    case when v_err like '%verified customer link%'
      then 'PASS an unlinked session cannot mint a QR against this business'
      else 'FAIL '||coalesce(nullif(v_err,''),'the stranger minted a QR') end);
end $$;

select * from _r order by k;
rollback;
