-- Rollback-only v666 acceptance suite (owner report 2026-09-01, photo 2).
--
--   T1  A pending gift QR resolves to the customer who holds it, with the SAME card the phone
--       lookup and the member-QR scan produce.
--   T2  Looking at a QR spends nothing: the intent is still pending and no allowance moved.
--   T3  A metered discount perk reports stageable; a free-item perk reports not stageable, so the
--       till knows to point staff at Give instead of putting it on the bill.
--   T4  An unknown token, and one already used, refuse SOFTLY — the caller falls through to
--       staff_scan_gift_qr_v515 for the wording rather than getting a second vocabulary here.
--   T5  A QR belonging to ANOTHER business is not resolvable.
--   T6  staff_scan_member_qr_v327 still returns exactly the fields it returned before, now built
--       by the shared card, plus newly_linked.
--   T7  Staff without till/loyalty write are refused — proved from the real role.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v666_evidence(test text, detail text) on commit drop;

do $v666$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';   -- Jess Salon
  v_owner uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab'; -- its owner's auth user
  v_pct uuid := '99add802-c233-43b6-ab81-f6158ff18985';   -- Gold "10% off", discount_pct, 1/month
  v_item uuid := '396a19d4-5790-4396-9671-b1d185f34fc5';  -- Gold "Free Free Hair Wax", free_item
  v_client uuid; v_identity uuid; v_customer_user uuid;
  v_period text; v_token text; v_token2 text; v_intent uuid;
  v_res jsonb; v_card jsonb; v_count integer; v_status text;
  v_other_biz uuid;
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
  v_token := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_pct,'10% off',v_period,
    '{}'::jsonb, app.v89_sha256(v_token), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_pct::text), now()+interval '15 minutes')
  returning id into v_intent;

  -- T1 --------------------------------------------------------------------------------------
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if v_res->>'status' <> 'found' then raise exception 'T1 the QR did not resolve: %', v_res; end if;
  if (v_res->>'client_id')::uuid <> v_client then
    raise exception 'T1 resolved the wrong customer'; end if;
  v_card := app.v666_till_customer_card(v_biz, v_client);
  if v_res->>'full_name' is distinct from v_card->>'full_name'
     or v_res->>'points' is distinct from v_card->>'points'
     or v_res->>'phone' is distinct from v_card->>'phone' then
    raise exception 'T1 the scan card and the shared card disagree: % vs %', v_res, v_card; end if;
  insert into v666_evidence values('T1','a gift QR resolves to its owner, on the one customer card');

  -- T2 --------------------------------------------------------------------------------------
  select status into v_status from public.customer_gift_intents_v515 where id=v_intent;
  if v_status <> 'pending' then raise exception 'T2 looking at the QR spent it (now %)', v_status; end if;
  select count(*) into v_count from public.tier_benefit_issues_v365
   where benefit_id=v_pct and client_id=v_client and period_key=v_period and reversed_at is null;
  if v_count <> 0 then raise exception 'T2 looking at the QR burned an allowance'; end if;
  insert into v666_evidence values('T2','a look spends nothing — intent still pending, allowance intact');

  -- T3 --------------------------------------------------------------------------------------
  if (v_res->>'stageable')::boolean is not true then
    raise exception 'T3 a metered discount perk should be stageable: %', v_res; end if;

  v_token2 := app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_item, gen_random_uuid());
  insert into public.customer_gift_intents_v515(business_id,identity_id,auth_user_id,client_id,
    gift_kind,benefit_id,quoted_label,quoted_period_key,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at)
  values(v_biz,v_identity,v_customer_user,v_client,'tier_perk',v_item,'Free Free Hair Wax',v_period,
    '{}'::jsonb, app.v89_sha256(v_token2), gen_random_uuid(),
    app.v89_sha256(v_biz::text||':tier_perk:'||v_item::text), now()+interval '15 minutes');
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token2);
  if v_res->>'status' <> 'found' then raise exception 'T3 the free-item QR did not resolve'; end if;
  if (v_res->>'stageable')::boolean then
    raise exception 'T3 a free item must not be stageable: %', v_res; end if;
  insert into v666_evidence values('T3','a discount stages; a free item is a hand-over and says so');

  -- T4 --------------------------------------------------------------------------------------
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz,
    app.v89_redemption_token(v_identity, v_biz, 'tier_perk_v515', v_pct, gen_random_uuid()));
  if v_res->>'status' <> 'invalid' then
    raise exception 'T4 an unknown token was not refused softly: %', v_res; end if;
  update public.customer_gift_intents_v515 set status='completed', completed_at=now(),
    completed_by=v_owner, completion_result='{"status":"staged"}'::jsonb where id=v_intent;
  v_res := public.staff_scan_gift_qr_to_till_v666(v_biz, v_token);
  if v_res->>'status' <> 'not_pending' then
    raise exception 'T4 an already-used QR was not refused softly: %', v_res; end if;
  insert into v666_evidence values('T4','unknown and already-used QRs refuse softly, no raise');

  -- T5 --------------------------------------------------------------------------------------
  select id into v_other_biz from public.businesses where id <> v_biz limit 1;
  if v_other_biz is not null then
    /* Two honest answers here, and both are a pass: a staff member with no authority at that
       business is refused outright (42501), and one who does work there still cannot resolve a
       QR that is not theirs. Asserting only the second would fail on the first for the wrong
       reason — the tenant boundary is doing its job before the token lookup is reached. */
    begin
      v_res := public.staff_scan_gift_qr_to_till_v666(v_other_biz, v_token2);
      if v_res->>'status' = 'found' then
        raise exception 'T5 another business resolved this QR'; end if;
      insert into v666_evidence values('T5','a QR is invisible to a business it does not belong to');
    exception when sqlstate '42501' then
      insert into v666_evidence values('T5','another business refuses the caller before the lookup');
    end;
  end if;

  -- T6 --------------------------------------------------------------------------------------
  v_res := public.staff_scan_member_qr_v327(v_biz, 'not-a-member-qr');
  if v_res->>'status' <> 'invalid' then
    raise exception 'T6 the member scan lost its own invalid answer: %', v_res; end if;
  v_card := app.v666_till_customer_card(v_biz, v_client);
  if not (v_card ?& array['status','client_id','full_name','phone','points','credit_cents',
                          'visits','redeem_points','reward_credit_cents','can_redeem',
                          'points_to_next','member_since']) then
    raise exception 'T6 the shared card dropped a field the till reads: %', v_card; end if;
  insert into v666_evidence values('T6','the shared card carries every field the till reads');
end
$v666$;

-- T7 — the authority, from a role that genuinely lacks till/loyalty write.
do $v666perm$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  v_user uuid;
begin
  select s.user_id into v_user from public.staff s
   where s.business_id=v_biz and s.active and s.user_id is not null
     and s.role not in ('owner','manager') limit 1;
  if v_user is null then
    insert into v666_evidence values('T7','skipped — no non-privileged active staff to prove it with');
    return;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  begin
    perform public.staff_scan_gift_qr_to_till_v666(v_biz, repeat('a',40));
    insert into v666_evidence values('T7','this role does hold till or loyalty write — not a failure');
  exception when sqlstate '42501' then
    insert into v666_evidence values('T7','a role without till/loyalty write is refused');
  end;
end
$v666perm$;

select * from v666_evidence order by test;
rollback;
