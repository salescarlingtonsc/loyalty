-- Customer wallet / rewards page — END TO END, 2026-09-08.
--
-- Walks the wallet the way a customer does, as the REAL customer principal (auth.uid set from
-- their own customer_identities row), then checks the one thing this surface has broken on
-- repeatedly: that the customer and the counter are reading the same number.
--
--   the wallet loads      customer_get_wallet()            -> one card per linked business
--   the programme card    customer_list_programmes_v89()   -> balance, model, unit
--   what to do next       customer_get_business_actions_v89(business)
--   AGREEMENT             app.customer_live_loyalty_v384  ==  app.v666_till_customer_card
--                         ==  app.client_points_balance_v409, for EVERY linked customer on the
--                         WHOLE ESTATE, not just the tenant in front of us
--   earning               a real till sale moves the customer's own wallet
--   redemption            redeeming drops BOTH sides together, and readiness follows
--
-- WHY THESE ASSERTIONS. The wallet's failure mode is never "it does not load" — it is two
-- readers of the same money disagreeing. The ledger has several pots, and readers have been
-- migrated to pot scope one at a time: the till once showed 855 where the customer saw 97
-- (v312/v381), business KPI readers summed every pot (v460), and the customer's own wallet
-- readers were only scoped in v813. A test that reads one side and finds a number proves
-- nothing; every balance assertion here is a COMPARISON between the two surfaces that must
-- agree, plus the canonical function both are supposed to derive from.
--
-- Readiness is asserted the same way and for the same reason: v145 forbids the browser from
-- deciding whether a reward is ready, so the server's answer to staff and the server's answer
-- to the customer have to be the same answer.
--
--   supabase db query --linked -f db/tests/v820_customer_wallet_end_to_end.sql

begin;

do $suite$
declare
  c_biz     constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner   constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_branch  constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_service constant uuid := '274204da-ad83-4e3b-b7f5-30681788079d';  -- SGD 88.00
  v_user    uuid;
  v_client  uuid;
  v_modules text[];
  v_wallet  jsonb;
  v_progs   jsonb;
  v_actions jsonb;
  v_card    jsonb;
  v_eval    jsonb;
  v_before  integer;
  v_after   integer;
  v_till    integer;
  v_canon   integer;
  v_got     integer;
  v_rbiz    uuid;
  v_rclient uuid;
  v_ruser   uuid;
  v_ruser_staff uuid;
  v_reward  uuid;
  v_rbranch uuid;
  v_rslug   text;
  v_rmodules text[];
  v_txt     text;
  n         integer := 0;
begin
  select b.enabled_modules into v_modules from public.businesses b where b.id = c_biz;

  -- A customer of this tenant who is actually signed up: an identity, a verified link, points.
  select l.auth_user_id, l.client_id into v_user, v_client
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
   where l.business_id = c_biz and l.state = 'verified'
     and app.client_points_balance_v409(l.business_id, l.client_id) > 0
   order by app.client_points_balance_v409(l.business_id, l.client_id) desc
   limit 1;
  if v_user is null then
    raise exception 'W0: no signed-up customer with points to walk the wallet as';
  end if;

  -- ==================================================================== THE WALLET LOADS
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  n := n + 1;
  v_wallet := public.customer_get_wallet();
  if v_wallet is null or jsonb_typeof(v_wallet) <> 'array' then
    raise exception 'W%: customer_get_wallet did not return a wallet', n;
  end if;

  n := n + 1;
  if not exists (select 1 from jsonb_array_elements(v_wallet) card
                  where card->'business'->>'slug' = 'kky-demo') then
    raise exception 'W%: the business the customer has joined is missing from their wallet', n;
  end if;

  -- Every card must carry a loyalty block; a card with no loyalty is the "wallet loaded but
  -- shows nothing" failure the customer actually experiences.
  n := n + 1;
  select count(*)::integer into v_got from jsonb_array_elements(v_wallet) card
   where card->'loyalty' is null or jsonb_typeof(card->'loyalty') <> 'object';
  if v_got <> 0 then
    raise exception 'W%: % wallet card(s) carry no loyalty block', n, v_got;
  end if;

  n := n + 1;
  v_progs := public.customer_list_programmes_v89();
  if v_progs is null or jsonb_array_length(coalesce(v_progs->'programmes','[]'::jsonb)) < 1 then
    raise exception 'W%: the rewards page lists no programme for a joined customer', n;
  end if;

  n := n + 1;
  v_actions := public.customer_get_business_actions_v89(c_biz);
  if v_actions is null then
    raise exception 'W%: the business actions read returned nothing', n;
  end if;

  reset role;
  perform set_config('request.jwt.claims', '', true);

  -- =================================================== THE CUSTOMER AND THE COUNTER AGREE
  -- The tenant in the screenshots first, then the whole estate.
  n := n + 1;
  v_card := app.customer_live_loyalty_v384(c_biz, v_client, v_modules, now());
  v_before := (v_card->>'balance')::integer;
  v_till := (app.v666_till_customer_card(c_biz, v_client)->>'points')::integer;
  v_canon := app.client_points_balance_v409(c_biz, v_client);
  if v_before is distinct from v_till or v_before is distinct from v_canon then
    raise exception 'W%: wallet=%, till=%, canonical=% for one customer — three readers, three answers',
      n, v_before, v_till, v_canon;
  end if;

  -- Estate-wide. Pot-scoping regressions have never been confined to one tenant, and a reader
  -- migrated for one business and not another is exactly how they have shipped before.
  n := n + 1;
  select count(*)::integer into v_got
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
    join public.businesses b on b.id = l.business_id
   where l.state = 'verified'
     and (app.customer_live_loyalty_v384(l.business_id, l.client_id, b.enabled_modules, now())->>'balance')::integer
         is distinct from (app.v666_till_customer_card(l.business_id, l.client_id)->>'points')::integer;
  if v_got <> 0 then
    raise exception 'W%: % linked customer(s) estate-wide see a different balance from the counter', n, v_got;
  end if;

  n := n + 1;
  select count(*)::integer into v_got
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
    join public.businesses b on b.id = l.business_id
   where l.state = 'verified'
     and (app.customer_live_loyalty_v384(l.business_id, l.client_id, b.enabled_modules, now())->>'balance')::integer
         is distinct from app.client_points_balance_v409(l.business_id, l.client_id);
  if v_got <> 0 then
    raise exception 'W%: % wallet balance(s) estate-wide disagree with the canonical balance', n, v_got;
  end if;

  -- The wallet's own two internal figures must agree with each other as well. A batch/ledger
  -- split is how an expiring balance silently drifts from a spendable one.
  n := n + 1;
  if (v_card->>'batch_balance')::integer is distinct from (v_card->>'ledger_balance')::integer then
    raise exception 'W%: the wallet''s batch balance (%) and ledger balance (%) disagree',
      n, v_card->>'batch_balance', v_card->>'ledger_balance';
  end if;

  -- ============================================ WHAT IS SWITCHED ON REACHES THE CUSTOMER
  -- v393's failure was that customers NEVER received tier data while the workspace showed it,
  -- and it survived because the test fixtures supplied the tier the server did not. So this
  -- asks the question the other way round: for every business that has tiers RUNNING and tiers
  -- CONFIGURED, every linked customer's wallet must actually carry a tier block. ÉLAN has tiers
  -- off and legitimately shows none, which is why this is estate-wide and not tenant-local.
  n := n + 1;
  select count(*)::integer into v_got
    from public.customer_links l
    join public.businesses b on b.id = l.business_id
    join public.business_programmes p
      on p.business_id = b.id and p.kind = 'tiers' and p.active
   where l.state = 'verified'
     and exists (select 1 from public.loyalty_tiers t where t.business_id = b.id)
     and jsonb_typeof(coalesce(
           app.customer_live_loyalty_v384(l.business_id, l.client_id, b.enabled_modules, now())->'tier',
           'null'::jsonb)) = 'null';
  if v_got <> 0 then
    raise exception 'W%: % customer(s) of a business running tiers get no tier in their wallet', n, v_got;
  end if;

  -- The same question for stamp cards.
  n := n + 1;
  select count(*)::integer into v_got
    from public.customer_links l
    join public.businesses b on b.id = l.business_id
    join public.business_programmes p
      on p.business_id = b.id and p.kind = 'stamps' and p.active
   where l.state = 'verified'
     and (app.customer_live_loyalty_v384(l.business_id, l.client_id, b.enabled_modules, now())->>'model')
         is distinct from 'stamps';
  if v_got <> 0 then
    raise exception 'W%: % customer(s) of a business running a stamp card do not get the stamp model', n, v_got;
  end if;

  -- ========================================================== EARNING REACHES THE WALLET
  -- A real sale at the till, through the RPC pair the Record sale button uses, must move the
  -- number the customer is looking at.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  perform public.record_cart_sale(c_biz, v_client, c_branch, null, 'cash',
    'wallet-e2e-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb);
  reset role;
  perform set_config('request.jwt.claims', '', true);

  v_after := (app.customer_live_loyalty_v384(c_biz, v_client, v_modules, now())->>'balance')::integer;
  if v_after <= v_before then
    raise exception 'W%: an SGD 88 sale did not move the customer''s wallet (% -> %)', n, v_before, v_after;
  end if;

  -- and the counter must move by exactly the same amount, at the same moment.
  n := n + 1;
  v_till := (app.v666_till_customer_card(c_biz, v_client)->>'points')::integer;
  if v_till is distinct from v_after then
    raise exception 'W%: after earning, the wallet says % and the counter says %', n, v_after, v_till;
  end if;

  -- The customer's own read of it, as themselves, agrees too — not just the helper underneath.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  select (card->'loyalty'->>'balance')::integer into v_got
    from jsonb_array_elements(public.customer_get_wallet()) card
   where card->'business'->>'slug' = 'kky-demo';
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got is distinct from v_after then
    raise exception 'W%: the customer''s own wallet read says % where the server says %', n, v_got, v_after;
  end if;

  -- ================================================================ REDEEMING, END TO END
  -- Redeem at the threshold the business actually configured, rather than editing the reward:
  -- loyalty_rewards is VERSIONED config, so lowering points_cost on the row would not reach the
  -- customer at all (the published version wins) and the test would prove nothing. So pick a
  -- customer the SERVER already says can redeem — on whichever tenant that is, which also takes
  -- this leg beyond the one business in the screenshots.
  select l.business_id, l.client_id, l.auth_user_id
    into v_rbiz, v_rclient, v_ruser
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
   where l.state = 'verified'
     and (app.v666_till_customer_card(l.business_id, l.client_id)->>'can_redeem')::boolean
   order by app.client_points_balance_v409(l.business_id, l.client_id) desc
   limit 1;

  if v_rbiz is null then
    raise exception 'W%: nobody on the estate can currently redeem, so the redemption leg cannot run', n;
  end if;

  select r.id into v_reward
    from public.loyalty_rewards r
   where r.business_id = v_rbiz
     and coalesce(r.active, true) and not coalesce(r.paused, false)
     and r.withdrawn_at is null
   order by r.cost_points
   limit 1;
  if v_reward is null then
    raise exception 'W%: the server says this customer can redeem but the business has no active reward', n;
  end if;

  -- redeem_reward demands loyalty write on THAT business, so act as its own owner.
  select st.user_id into v_ruser_staff
    from public.staff st
   where st.business_id = v_rbiz and st.role = 'owner' and st.user_id is not null and st.active
   limit 1;
  if v_ruser_staff is null then
    raise exception 'W%: no owner login to redeem as on the chosen business', n;
  end if;

  select b.enabled_modules into v_rmodules from public.businesses b where b.id = v_rbiz;
  /* Resolve the slug HERE, not inside the customer-impersonated block below: a customer cannot
     read public.businesses under their own RLS, so the sub-select would silently return NULL and
     the comparison would pass against nothing. */
  select b2.slug into v_rslug from public.businesses b2 where b2.id = v_rbiz;
  select br.id into v_rbranch from public.branches br
   where br.business_id = v_rbiz and br.active
   order by br.is_default desc, br.created_at limit 1;
  v_before := (app.customer_live_loyalty_v384(v_rbiz, v_rclient, v_rmodules, now())->>'balance')::integer;

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ruser_staff, 'role', 'authenticated')::text, true);
  /* staff_manual_redeem_reward_v404 is the RPC the app actually calls — redeem_reward itself
     carries no `authenticated` grant, so driving it would prove a path no staff member can take. */
  perform public.staff_manual_redeem_reward_v404(
    v_rbiz, v_rclient, v_reward, 1, v_rbranch, 'other', 'wallet end-to-end suite',
    'wallet-e2e-' || gen_random_uuid()::text);
  reset role;
  perform set_config('request.jwt.claims', '', true);

  -- Both sides drop, together, to the same number.
  n := n + 1;
  v_got := (app.customer_live_loyalty_v384(v_rbiz, v_rclient, v_rmodules, now())->>'balance')::integer;
  v_till := (app.v666_till_customer_card(v_rbiz, v_rclient)->>'points')::integer;
  if v_got >= v_before then
    raise exception 'W%: redeeming did not reduce the balance (% -> %)', n, v_before, v_got;
  end if;
  n := n + 1;
  if v_got is distinct from v_till then
    raise exception 'W%: after redeeming, the wallet says % and the counter says %', n, v_got, v_till;
  end if;

  -- and the customer, reading their OWN wallet as themselves, sees the same drop.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ruser, 'role', 'authenticated')::text, true);
  select (card->'loyalty'->>'balance')::integer into v_till
    from jsonb_array_elements(public.customer_get_wallet()) card
   where (card->'business'->>'slug') = v_rslug;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_till is distinct from v_got then
    raise exception 'W%: after redeeming, the customer''s own wallet still says % where the server says %',
      n, v_till, v_got;
  end if;

  -- The redemption left the audit trail the ledger requires: a redemption row, its provenance,
  -- and the negative points entry that paid for it. (reward_grants is the RETENTION table and is
  -- deliberately not what a points redemption writes — checking it would have passed vacuously
  -- on an unrelated row, or failed for the wrong reason, which is what the first draft did.)
  n := n + 1;
  select count(*)::integer into v_got
    from public.loyalty_redemptions r
   where r.business_id = v_rbiz and r.client_id = v_rclient
     and r.redeemed_at >= now() - interval '5 minutes';
  if v_got < 1 then
    raise exception 'W%: redeeming recorded no loyalty_redemptions row', n;
  end if;

  n := n + 1;
  select count(*)::integer into v_got
    from public.points_ledger pl
   where pl.business_id = v_rbiz and pl.client_id = v_rclient
     and pl.points < 0 and pl.created_at >= now() - interval '5 minutes';
  if v_got < 1 then
    raise exception 'W%: redeeming wrote no negative points entry — the balance moved with nothing paying for it', n;
  end if;

  raise notice 'customer wallet end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
