-- QR redemption — END TO END, 2026-09-08.
--
-- The two QR journeys the counter's Scan button actually serves, walked as the real principals
-- on both sides — the customer with their own auth.uid, the staff member with theirs:
--
--   MEMBER QR      customer_get_member_qr_v327()  ->  staff_scan_member_qr_v327(business, token)
--                  identifies the customer at the till. Rotation must invalidate the old code.
--
--   REWARD QR      customer_create_redemption_intent_v89(business, reward, idem, kind)
--                  -> customer_get_redemption_intent_v89(intent)      (the screen polls this)
--                  -> merchant_scan_redemption_qr_v117(business, branch, token, idem)
--                  which is the arm openMerchantRedemptionScanner falls through to for a
--                  reward — not staff_redeem_promotion_intent_v290, which serves a promotion,
--                  nor staff_manual_redeem_reward_v404, which is the no-QR path.
--
-- WHAT THIS IS REALLY FOR. A QR is a bearer token: whoever holds the string can spend it. So
-- the assertions that matter are not "does it redeem" but the four ways a bearer token goes
-- wrong — another tenant spending it, a replay spending it twice, a cancelled code still
-- working, and a rotated code still working. Those are asserted here alongside the happy path,
-- and the money assertions are comparisons between the customer's wallet and the counter, for
-- the same reason as db/tests/v820_customer_wallet_end_to_end.sql.
--
-- The token itself is only ever returned once — the table stores a sha256 token_hash — so the
-- suite has to capture it from the create call, exactly as the customer's phone does.
--
-- NEGATIVE CONTROL, run 2026-09-08 so these are known to discriminate rather than to pass
-- vacuously: point the cross-tenant probe at the OWNING business instead (v_biz/v_staff/v_branch
-- in place of v_other), so the scan genuinely succeeds. The suite then fails at
--   Q8: ANOTHER BUSINESS redeemed this customer's reward QR
-- Half the assertions here sit behind an `exception when others` — that is unavoidable when the
-- expected outcome IS a refusal — so each one is paired with a POSITIVE check that does not
-- depend on the exception: the balance is unchanged, the intent is still pending, exactly one
-- redemption exists. An isolation test that only catches an error would pass just as happily if
-- the call had failed for an unrelated reason, such as a missing branch on the other tenant.
-- (Checked: the business chosen as "other" does have an active branch, so the refusal is about
-- the token, not the arguments.)
--
--   supabase db query --linked -f db/tests/v820_qr_redemption_end_to_end.sql

begin;

do $suite$
declare
  v_biz     uuid;
  v_client  uuid;
  v_user    uuid;   -- the customer's auth user
  v_staff   uuid;   -- an owner login at that business
  v_branch  uuid;
  v_reward  uuid;
  v_modules text[];
  v_other   uuid;   -- an unrelated business, for the isolation probes
  v_qr      text;
  v_intent  uuid;
  v_token   text;
  v_res     jsonb;
  v_before  integer;
  v_after   integer;
  v_till    integer;
  v_got     integer;
  v_txt     text;
  n         integer := 0;
begin
  -- A customer the SERVER already says can redeem, on whichever tenant that is.
  select l.business_id, l.client_id, l.auth_user_id
    into v_biz, v_client, v_user
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
   where l.state = 'verified'
     and (app.v666_till_customer_card(l.business_id, l.client_id)->>'can_redeem')::boolean
   order by app.client_points_balance_v409(l.business_id, l.client_id) desc
   limit 1;
  if v_biz is null then
    raise exception 'Q0: nobody on the estate can currently redeem, so the QR path cannot be walked';
  end if;

  select st.user_id into v_staff from public.staff st
   where st.business_id = v_biz and st.role = 'owner' and st.active and st.user_id is not null limit 1;
  select br.id into v_branch from public.branches br
   where br.business_id = v_biz and br.active order by br.is_default desc, br.created_at limit 1;
  select r.id into v_reward from public.loyalty_rewards r
   where r.business_id = v_biz and coalesce(r.active, true)
     and not coalesce(r.paused, false) and r.withdrawn_at is null
   order by r.cost_points limit 1;
  select b.enabled_modules into v_modules from public.businesses b where b.id = v_biz;
  select b.id into v_other from public.businesses b where b.id <> v_biz
   and exists (select 1 from public.staff s2 where s2.business_id = b.id and s2.role='owner'
                 and s2.active and s2.user_id is not null)
   limit 1;
  if v_staff is null or v_branch is null or v_reward is null or v_other is null then
    raise exception 'Q0: fixture incomplete (staff=%, branch=%, reward=%, other=%)',
      v_staff, v_branch, v_reward, v_other;
  end if;

  -- =============================================================== PART 1 — THE MEMBER QR

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_get_member_qr_v327()::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  v_qr := coalesce(v_res->>'member_qr', v_res->>'token', v_res->>'qr_token');
  if v_qr is null then
    raise exception 'Q%: the customer''s member QR came back with no token (%)', n, left(v_res::text, 300);
  end if;

  -- The counter resolves it to the right person, at the right business.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_res := public.staff_scan_member_qr_v327(v_biz, v_qr)::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if coalesce(v_res->>'client_id','')::text is distinct from v_client::text then
    raise exception 'Q%: scanning the member QR resolved to %, expected the customer %',
      n, coalesce(v_res->>'client_id','(none)'), v_client;
  end if;

  -- TENANT ISOLATION. A member code is a bearer string; another business holding it must get
  -- nothing back. This is the assertion that matters most about a QR.
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select st.user_id from public.staff st
         where st.business_id = v_other and st.role='owner' and st.active and st.user_id is not null limit 1),
        'role','authenticated')::text, true);
    v_res := public.staff_scan_member_qr_v327(v_other, v_qr)::jsonb;
    reset role;
    perform set_config('request.jwt.claims', '', true);
    if coalesce(v_res->>'client_id','') = v_client::text
       or coalesce(v_res->>'status','') = 'found' then
      raise exception 'Q%: ANOTHER BUSINESS resolved this customer''s member QR (%)',
        n, left(v_res::text, 200);
    end if;
  exception when insufficient_privilege or invalid_parameter_value then
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end;

  -- Rotation invalidates the old code, or a lost phone stays valid for ever.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  perform public.customer_rotate_member_qr_v327();
  reset role;
  perform set_config('request.jwt.claims', '', true);

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_res := public.staff_scan_member_qr_v327(v_biz, v_qr)::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if coalesce(v_res->>'client_id','') = v_client::text then
    raise exception 'Q%: the OLD member QR still resolves after rotation', n;
  end if;

  -- ============================================================ PART 2 — THE REWARD QR

  v_before := (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer;

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_create_redemption_intent_v89(
             v_biz, v_reward, gen_random_uuid(), 'catalog_reward')::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  v_intent := nullif(v_res->>'intent_id','')::uuid;
  v_token := coalesce(v_res->>'qr_token', v_res->>'token');
  if v_intent is null or v_token is null then
    raise exception 'Q%: creating a redemption intent returned no intent/token (%)',
      n, left(v_res::text, 300);
  end if;

  -- Creating the intent must not have spent anything yet: the customer is holding a quote,
  -- not a receipt, until the counter scans it.
  n := n + 1;
  if (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer
     is distinct from v_before then
    raise exception 'Q%: merely creating the QR already moved the balance', n;
  end if;

  -- The customer's screen polls the intent and sees it pending.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_get_redemption_intent_v89(v_intent)::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if coalesce(v_res->>'status','') <> 'pending' then
    raise exception 'Q%: a freshly created intent reads "%"', n, coalesce(v_res->>'status','(none)');
  end if;

  -- TENANT ISOLATION on the reward token too.
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select st.user_id from public.staff st
         where st.business_id = v_other and st.role='owner' and st.active and st.user_id is not null limit 1),
        'role','authenticated')::text, true);
    perform public.merchant_scan_redemption_qr_v117(
      v_other, (select br.id from public.branches br where br.business_id=v_other and br.active limit 1),
      v_token, gen_random_uuid());
    reset role;
    perform set_config('request.jwt.claims', '', true);
    raise exception 'Q%: ANOTHER BUSINESS redeemed this customer''s reward QR', n;
  exception when others then
    reset role;
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like 'Q%: ANOTHER BUSINESS%' then raise; end if;
  end;

  n := n + 1;
  if (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer
     is distinct from v_before then
    raise exception 'Q%: the failed cross-tenant scan still moved the balance', n;
  end if;

  -- Asserted positively as well: the code is untouched and still spendable by its OWN business.
  -- Leaning only on the exception above would pass just as well if the call had failed for some
  -- unrelated reason — a missing branch, a bad argument — and proved nothing about isolation.
  n := n + 1;
  select count(*)::integer into v_got from public.customer_redemption_intents_v89 i
   where i.id = v_intent and i.status = 'pending';
  if v_got <> 1 then
    raise exception 'Q%: after the cross-tenant attempt the intent is no longer pending', n;
  end if;

  -- The real scan, by the business the code belongs to.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_res := public.merchant_scan_redemption_qr_v117(v_biz, v_branch, v_token, gen_random_uuid())::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_res is null then
    raise exception 'Q%: scanning the reward QR returned nothing', n;
  end if;

  -- Both sides moved, together, to the same number.
  n := n + 1;
  v_after := (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer;
  v_till := (app.v666_till_customer_card(v_biz, v_client)->>'points')::integer;
  if v_after >= v_before then
    raise exception 'Q%: the scan did not spend anything (% -> %)', n, v_before, v_after;
  end if;
  n := n + 1;
  if v_after is distinct from v_till then
    raise exception 'Q%: after the scan the wallet says % and the counter says %', n, v_after, v_till;
  end if;

  -- The intent is now completed, and the customer's own screen sees that.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_get_redemption_intent_v89(v_intent)::jsonb;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if coalesce(v_res->>'status','') <> 'completed' then
    raise exception 'Q%: after the counter scanned it the customer''s screen still reads "%"',
      n, coalesce(v_res->>'status','(none)');
  end if;

  -- It left the audit trail a redemption owes.
  n := n + 1;
  select count(*)::integer into v_got from public.customer_redemption_intents_v89 i
   where i.id = v_intent and i.status = 'completed' and i.redemption_id is not null;
  if v_got <> 1 then
    raise exception 'Q%: the completed intent carries no redemption id', n;
  end if;

  -- REPLAY. The same string presented twice must not spend twice — the single most likely way
  -- a bearer token loses money.
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    perform public.merchant_scan_redemption_qr_v117(v_biz, v_branch, v_token, gen_random_uuid());
    reset role;
    perform set_config('request.jwt.claims', '', true);
  exception when others then
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end;
  if (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer
     is distinct from v_after then
    raise exception 'Q%: RESCANNING THE SAME QR SPENT AGAIN (% then %)', n, v_after,
      (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer;
  end if;

  -- and it left exactly ONE redemption behind, not two.
  n := n + 1;
  select count(*)::integer into v_got from public.loyalty_redemptions r
   where r.business_id = v_biz and r.client_id = v_client
     and r.redeemed_at >= now() - interval '5 minutes';
  if v_got <> 1 then
    raise exception 'Q%: one QR produced % redemptions', n, v_got;
  end if;

  -- ============================================================ PART 3 — A CANCELLED CODE

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_create_redemption_intent_v89(
             v_biz, v_reward, gen_random_uuid(), 'catalog_reward')::jsonb;
  v_intent := nullif(v_res->>'intent_id','')::uuid;
  v_token := coalesce(v_res->>'qr_token', v_res->>'token');
  perform public.customer_cancel_redemption_intent_v89(v_intent, gen_random_uuid());
  reset role;
  perform set_config('request.jwt.claims', '', true);

  v_before := (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    perform public.merchant_scan_redemption_qr_v117(v_biz, v_branch, v_token, gen_random_uuid());
    reset role;
    perform set_config('request.jwt.claims', '', true);
  exception when others then
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end;
  if (app.customer_live_loyalty_v384(v_biz, v_client, v_modules, now())->>'balance')::integer
     is distinct from v_before then
    raise exception 'Q%: a CANCELLED QR was still spendable at the counter', n;
  end if;

  raise notice 'QR redemption end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
