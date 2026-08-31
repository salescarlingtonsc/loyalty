-- Rollback-only v665 acceptance suite (owner ruling 2026-08-31, photos 1-5).
--
-- SECTION 1 — the allowance comes back when a perk is handed back.
--   S1-T1  Issuing spends the allowance: the till reads remaining 0 and claimable_now false.
--   S1-T2  The pricing authority refuses a perk whose allowance is gone.
--   S1-T3  Reversing restores it: remaining 1, claimable again, and the kernel prices it again.
--   S1-T4  The reversal is evidence — actor, reason and label are recorded, and audit_log has it.
--   S1-T5  Replaying the same idempotency key returns the first reversal, not a second one.
--   S1-T6  Reversing the same issue twice is refused.
--   S1-T7  A reason under 10 characters is refused.
--   S1-T8  The idempotency key that issued a since-reversed perk can issue again (partial index).
--   S1-T9  A staff member without refund_sales is refused — proved from the real role.
--
-- SECTION 2 — a redeemed welcome gift goes back to the customer.
--   S2-T1  Reversing restores status 'granted' and clears every redemption field.
--   S2-T2  The $0 sale is deliberately left standing, and the reversal remembers its id.
--   S2-T3  The workflow list reports the gift, its sale and who may reverse it.
--
-- SECTION 3 — staging a scanned discount perk spends the QR, not the allowance.
--   S3-T1  A metered discount QR stages: the intent completes and NO issue row is written.
--   S3-T2  A free-item perk is not stageable — it is a hand-over, and keeps the v515 path.
--   S3-T3  A QR belonging to another customer is refused rather than quietly applied.
--   S3-T4  An already-used QR is not stageable, so the caller falls through to v515's wording.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v665_evidence(test text, detail text) on commit drop;

do $v665$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';   -- Jess Salon
  v_owner uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab'; -- its owner's auth user
  v_pct uuid := '99add802-c233-43b6-ab81-f6158ff18985';   -- Gold "10% off", discount_pct, 1/month
  v_item uuid := '396a19d4-5790-4396-9671-b1d185f34fc5';  -- Gold "Free Free Hair Wax", free_item
  v_cut uuid := '864f3390-5a42-43ec-85f8-d568eca7c52e';   -- Hair Cut (Director), 60.00
  v_client uuid; v_other uuid; v_branch uuid;
  v_issue uuid; v_issue2 uuid; v_key uuid := gen_random_uuid();
  v_rev_key uuid := gen_random_uuid();
  v_res jsonb; v_plan jsonb; v_eff jsonb; v_benefit jsonb;
  v_grant uuid; v_sale uuid; v_status text;
  v_period text; v_intent uuid; v_token text; v_count integer;
  v_identity uuid; v_customer_user uuid;
begin
  -- Act as the owner for every RPC below: auth.uid() reads the request JWT, so this is the same
  -- identity the browser would present, not a postgres superuser shortcut.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  if v_branch is null then raise exception 'FIXTURE: Jess Salon has no active branch'; end if;

  -- A client who has actually reached Gold, and a second one to prove the wrong-customer refusal.
  select c.id into v_client from public.clients c
   where c.business_id=v_biz
     and coalesce((app.v365_client_tier(v_biz, c.id)).threshold,-1)
         >= (select t.threshold from public.loyalty_tiers t
              join public.tier_benefits_v365 b on b.tier_id=t.id where b.id=v_pct)
   limit 1;
  if v_client is null then raise exception 'FIXTURE: no client has reached the Gold tier'; end if;
  select c.id into v_other from public.clients c
   where c.business_id=v_biz and c.id <> v_client limit 1;
  if v_other is null then raise exception 'FIXTURE: need a second client'; end if;

  -- Start from a clean allowance for this period so the counts below mean what they say.
  update public.tier_benefit_issues_v365 set reversed_at=now()
   where business_id=v_biz and client_id=v_client and benefit_id in (v_pct, v_item)
     and reversed_at is null;

  -- ===========================================================================================
  -- SECTION 1
  -- ===========================================================================================
  v_res := public.staff_issue_tier_benefit_v365(v_biz, v_client, v_pct, v_branch, v_key);
  if v_res->>'status' <> 'issued' then raise exception 'S1-T1 issue failed: %', v_res; end if;
  v_issue := (v_res->>'issue_id')::uuid;
  if (v_res->>'remaining')::int <> 0 then
    raise exception 'S1-T1 expected remaining 0 after issuing, got %', v_res->>'remaining'; end if;

  select b into v_benefit
    from jsonb_array_elements(public.staff_tier_benefits_for_client_v365(v_biz,v_client)->'benefits') b
   where (b->>'benefit_id')::uuid = v_pct;
  if (v_benefit->>'remaining')::int <> 0 or (v_benefit->>'claimable_now')::boolean then
    raise exception 'S1-T1 the till still offers a spent perk: %', v_benefit; end if;
  insert into v665_evidence values('S1-T1','issuing spends the allowance; the till stops offering it');

  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut,'qty',1)),
    null, v_pct);
  if v_plan->>'status' <> 'tier_benefit_used_up' then
    raise exception 'S1-T2 the kernel priced a spent perk: %', v_plan->>'status'; end if;
  insert into v665_evidence values('S1-T2','the pricing authority refuses a spent perk');

  v_res := public.staff_reverse_gift_redemption_v665(v_biz,'tier_perk',v_issue,
    'wrong customer scanned at the counter', v_rev_key);
  if v_res->>'status' <> 'completed' or (v_res->>'replayed')::boolean then
    raise exception 'S1-T3 reversal did not complete: %', v_res; end if;

  select b into v_benefit
    from jsonb_array_elements(public.staff_tier_benefits_for_client_v365(v_biz,v_client)->'benefits') b
   where (b->>'benefit_id')::uuid = v_pct;
  if (v_benefit->>'remaining')::int <> 1 or not (v_benefit->>'claimable_now')::boolean then
    raise exception 'S1-T3 the allowance did not come back: %', v_benefit; end if;

  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut,'qty',1)),
    null, v_pct);
  if v_plan->>'status' <> 'ok' then
    raise exception 'S1-T3 the kernel still refuses a restored perk: %', v_plan; end if;
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is null or (v_eff->>'amount_cents')::int <> 600 then
    raise exception 'S1-T3 expected 600 off a 6000 bill, got %', v_eff; end if;
  insert into v665_evidence values('S1-T3','reversing returns the allowance to every reader');

  if not exists (select 1 from public.gift_redemption_reversals_v665
                  where issue_id=v_issue and business_id=v_biz and reversed_by=v_owner
                    and reason='wrong customer scanned at the counter') then
    raise exception 'S1-T4 no evidence row was written'; end if;
  if not exists (select 1 from public.audit_log
                  where business_id=v_biz and action='GIFT_REDEMPTION_REVERSED_V665'
                    and (detail->>'target_id')::uuid=v_issue) then
    raise exception 'S1-T4 the reversal was not audited'; end if;
  insert into v665_evidence values('S1-T4','who reversed it, why, and an audit_log entry');

  v_res := public.staff_reverse_gift_redemption_v665(v_biz,'tier_perk',v_issue,
    'wrong customer scanned at the counter', v_rev_key);
  if not (v_res->>'replayed')::boolean then
    raise exception 'S1-T5 the same key did not replay: %', v_res; end if;
  select count(*) into v_count from public.gift_redemption_reversals_v665 where issue_id=v_issue;
  if v_count <> 1 then raise exception 'S1-T5 a replay wrote a second reversal'; end if;
  insert into v665_evidence values('S1-T5','a replayed key returns the first reversal');

  begin
    perform public.staff_reverse_gift_redemption_v665(v_biz,'tier_perk',v_issue,
      'a second attempt at the same issue', gen_random_uuid());
    raise exception 'S1-T6 reversing twice was allowed';
  exception when sqlstate '22023' then
    insert into v665_evidence values('S1-T6','an already-reversed issue cannot be reversed again');
  end;

  begin
    perform public.staff_reverse_gift_redemption_v665(v_biz,'tier_perk',v_issue,'oops',
      gen_random_uuid());
    raise exception 'S1-T7 a short reason was accepted';
  exception when sqlstate '22023' then
    insert into v665_evidence values('S1-T7','a reason under 10 characters is refused');
  end;

  -- The partial idempotency index: the key that issued the reversed perk must work again.
  v_res := public.staff_issue_tier_benefit_v365(v_biz, v_client, v_pct, v_branch, v_key);
  if v_res->>'status' <> 'issued' then
    raise exception 'S1-T8 a reversed issue held its idempotency key hostage: %', v_res; end if;
  v_issue2 := (v_res->>'issue_id')::uuid;
  if v_issue2 = v_issue then raise exception 'S1-T8 the same row was returned'; end if;
  insert into v665_evidence values('S1-T8','a reversed issue does not block a later re-issue');

  -- ===========================================================================================
  -- SECTION 2 — a welcome gift
  -- ===========================================================================================
  select id, redeemed_sale_id into v_grant, v_sale from public.welcome_offer_grants_v215
   where business_id=v_biz and status='redeemed' limit 1;
  if v_grant is null then
    -- Build one inside the transaction rather than skipping the section.
    delete from public.welcome_offer_grants_v215 where business_id=v_biz and client_id=v_other;
    insert into public.welcome_offer_grants_v215(business_id,client_id,min_spend_cents,
      reward_catalog_kind,reward_label,status)
    values(v_biz,v_other,0,'service','Hair Cut (Director)','granted') returning id into v_grant;
    v_res := public.staff_redeem_welcome_offer_v215(v_biz,v_other,v_branch,null,
      'v665-suite-'||v_grant::text);
    if v_res->>'status' <> 'completed' then
      raise exception 'S2 fixture: welcome redemption failed: %', v_res; end if;
    v_sale := (v_res->>'sale_id')::uuid;
  end if;

  v_res := public.staff_reverse_gift_redemption_v665(v_biz,'welcome',v_grant,
    'redeemed against the wrong visit', gen_random_uuid());
  if v_res->>'status' <> 'completed' then
    raise exception 'S2-T1 welcome reversal failed: %', v_res; end if;
  select status into v_status from public.welcome_offer_grants_v215 where id=v_grant;
  if v_status <> 'granted' then raise exception 'S2-T1 status is % not granted', v_status; end if;
  if exists (select 1 from public.welcome_offer_grants_v215
              where id=v_grant and (redeemed_at is not null or redeemed_sale_id is not null
                or redeemed_by is not null or redeem_idempotency_key is not null)) then
    raise exception 'S2-T1 redemption fields were left behind'; end if;
  insert into v665_evidence values('S2-T1','a redeemed welcome gift is available to the customer again');

  if v_sale is not null then
    if not exists (select 1 from public.sales where id=v_sale) then
      raise exception 'S2-T2 the $0 sale was destroyed'; end if;
    if not exists (select 1 from public.gift_redemption_reversals_v665
                    where grant_id=v_grant and redeemed_sale_id=v_sale) then
      raise exception 'S2-T2 the reversal forgot the sale it undid'; end if;
  end if;
  insert into v665_evidence values('S2-T2','the $0 sale stands, and the reversal remembers it');

  select g into v_benefit
    from jsonb_array_elements(
      public.staff_gift_reversal_workflows_v665(v_biz,null,200)->'gifts') g
   where (g->>'id')::uuid = v_grant;
  if v_benefit is null then raise exception 'S2-T3 the gift is missing from the workflow list'; end if;
  if v_benefit->>'gift_kind' <> 'welcome' or v_benefit->>'reversed_at' is null then
    raise exception 'S2-T3 the list does not show it as reversed: %', v_benefit; end if;
  if (v_benefit->>'can_reverse')::boolean then
    raise exception 'S2-T3 an already-reversed gift is still offered for reversal'; end if;
  insert into v665_evidence values('S2-T3','the workflow list reports the gift and its state');

  -- ===========================================================================================
  -- SECTION 3 — staging
  -- ===========================================================================================
  select ci.id, ci.auth_user_id into v_identity, v_customer_user
    from public.customer_identities ci
    join public.customer_links l on l.identity_id=ci.id and l.business_id=v_biz
                                and l.client_id=v_client and l.state='verified'
   where ci.status='active' limit 1;
  if v_identity is null then
    raise exception 'FIXTURE: the Gold client has no verified customer link, so no QR can exist';
  end if;

  -- Reset the allowance the S1 re-issue spent, so the perk is mintable.
  update public.tier_benefit_issues_v365 set reversed_at=now()
   where id=v_issue2;
  -- customer_gift_intents_v515_open_uk allows ONE live QR per gift per customer, so any real one
  -- this customer is holding right now would collide with the fixtures minted below.
  update public.customer_gift_intents_v515 set status='expired'
   where business_id=v_biz and client_id=v_client and status='pending';

  v_period := app.v365_period_key('month', now());
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_pct,'10% off',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_pct::text), now()+interval '15 minutes')
  returning id into v_intent;

  v_res := public.staff_stage_gift_qr_v665(v_biz, v_client, v_token);
  if v_res->>'status' <> 'staged' then raise exception 'S3-T1 staging failed: %', v_res; end if;
  if (v_res->>'benefit_id')::uuid <> v_pct then raise exception 'S3-T1 staged the wrong perk'; end if;
  select count(*) into v_count from public.tier_benefit_issues_v365
   where benefit_id=v_pct and client_id=v_client and period_key=v_period and reversed_at is null;
  if v_count <> 0 then
    raise exception 'S3-T1 staging spent the allowance (% live issues)', v_count; end if;
  select status into v_status from public.customer_gift_intents_v515 where id=v_intent;
  if v_status <> 'completed' then raise exception 'S3-T1 the QR is still live after staging'; end if;
  insert into v665_evidence values('S3-T1','a scanned discount QR is spent; the allowance is not');

  -- A free-item perk: not a price, so not stageable.
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_item, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_item,'Free Free Hair Wax',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_item::text), now()+interval '15 minutes');
  v_res := public.staff_stage_gift_qr_v665(v_biz, v_client, v_token);
  if v_res->>'status' <> 'not_stageable' or v_res->>'reason' <> 'not_a_metered_discount' then
    raise exception 'S3-T2 a free item was staged: %', v_res; end if;
  insert into v665_evidence values('S3-T2','a free-item perk keeps the settle-on-scan path');

  v_res := public.staff_stage_gift_qr_v665(v_biz, v_other, v_token);
  if v_res->>'status' <> 'wrong_customer' then
    raise exception 'S3-T3 another customer''s QR was accepted: %', v_res; end if;
  insert into v665_evidence values('S3-T3','a QR belonging to somebody else is refused');

  -- The intent staged in S3-T1 is completed, so a second scan must fall through to v515.
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid());
  v_res := public.staff_stage_gift_qr_v665(v_biz, v_client, v_token);
  if v_res->>'status' <> 'not_stageable' or v_res->>'reason' <> 'unknown_token' then
    raise exception 'S3-T4 an unknown token was not refused softly: %', v_res; end if;
  insert into v665_evidence values('S3-T4','an unknown QR falls through to v515 for its wording');
end
$v665$;

-- ===============================================================================================
-- S1-T9 — the authority, proved from a role that genuinely lacks refund_sales.
-- ===============================================================================================
do $v665perm$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  v_user uuid; v_issue uuid;
begin
  select s.user_id into v_user from public.staff s
   where s.business_id=v_biz and s.active and s.user_id is not null
     and not ('refund_sales' = any(app.role_perms(s.role))) limit 1;
  if v_user is null then
    insert into v665_evidence values('S1-T9','skipped — every active staff member holds refund_sales');
    return;
  end if;
  select id into v_issue from public.tier_benefit_issues_v365
   where business_id=v_biz and reversed_at is null limit 1;
  if v_issue is null then
    insert into v665_evidence values('S1-T9','skipped — no live issue to attempt');
    return;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  begin
    perform public.staff_reverse_gift_redemption_v665(v_biz,'tier_perk',v_issue,
      'an unauthorised attempt', gen_random_uuid());
    raise exception 'S1-T9 a staff member without refund_sales reversed a perk';
  exception when sqlstate '42501' then
    insert into v665_evidence values('S1-T9','reversing needs refund_sales, proved from the real role');
  end;
end
$v665perm$;

select * from v665_evidence order by test;
rollback;
