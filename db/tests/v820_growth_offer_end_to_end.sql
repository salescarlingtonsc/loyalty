-- The growth arm — MINT, SCAN, SETTLE, END TO END, 2026-09-08.
--
-- db/tests/v820_scanner_arms_end_to_end.sql walked five of the six scanner arms and left this
-- one HALF-WALKED, because public.growth_entitlements_v108 holds ZERO rows across the entire
-- estate: an entitlement is only ever written at the end of a real campaign delivery chain
-- (recommendation -> execution -> execution_member -> delivery -> entitlement), and nobody has
-- ever run one. This file closes that gap by fabricating the minimal valid chain by hand,
-- entirely inside a rolled-back transaction, then walking the real RPCs on top of it exactly as
-- the product does:
--
--   customer_get_growth_offers_v108(business)              the customer's offer list
--   customer_prepare_growth_offer_qr_v108(entitlement, idem) mints the bearer QR (only a sha256
--                                                            hash is ever stored — the token
--                                                            itself is returned once, exactly
--                                                            like a reward QR)
--   redeem_growth_offer_v108(business, token, sale, idem)   the counter's Scan button, growth arm
--
-- WHY EACH FABRICATED ROW IS THE WAY IT IS (every table below has a `growth_v108_guard_status`
-- or `_immutable` trigger blocking DELETE, but none block a same-transaction INSERT — this is
-- not bypassing a write guard, it is exercising the shape the guards themselves require):
--
--   growth_recommendations_v108   one row. status='accepted'. Every jsonb column has a
--                                 `jsonb_typeof(...) = 'object'|'array'` check and nothing else
--                                 reads its contents on the redemption path, so each is the
--                                 emptiest value that satisfies its own check ('{}'/'[]').
--                                 recommendation_type/success_metric/recommended_channel are
--                                 fixed by CHECK to a single literal each — there is no choice.
--   growth_recommendation_members_v108  one row, eligible=true, for the test customer. This
--                                 feeds app.v113_guard_growth_execution_identity's identity-
--                                 snapshot check on the execution insert below: eligible count
--                                 must equal the distinct *effective* client count, which is 1
--                                 either way since this customer has no merge history.
--   growth_executions_v108       one row, status='running', branch_id pinned to the SAME branch
--                                 the qualifying sale is later recorded at. governed_copy is the
--                                 single most constrained value in the fixture: a 9-key object
--                                 whose title/body/cta/eligibility/conditions/locked_facts must
--                                 all cross-reference the row's own scalar columns exactly (see
--                                 growth_executions_v108_check) — get one field wrong and this
--                                 INSERT fails, not the RPC under test.
--   growth_execution_members_v108  one row, assignment='treatment', linking back to the
--                                 recommendation member. app.v113_canonicalize_execution_member
--                                 rewrites client_id to its own effective-client resolution on
--                                 insert; harmless here since there is nothing to resolve.
--   growth_deliveries_v108       one row, delivery_status='queued' — NOT 'delivered'. This is a
--                                 real finding, not a fixture shortcut: inserting a treatment
--                                 delivery already marked 'delivered' is not actually possible.
--                                 app.v110_prepare_delivery_insert fires BEFORE INSERT and, for
--                                 assignment='treatment' with delivery_status='delivered', force-
--                                 rewrites it back to 'queued' and clears delivered_at — every
--                                 direct insert of a "delivered" treatment row is silently
--                                 downgraded to queued. Advancing it queued -> delivering ->
--                                 delivered is only possible by UPDATE, and even that is refused
--                                 by app.v110_guard_delivery_update unless the session GUC
--                                 `app.growth_delivery_v110_transition` is 'on' (the lifecycle
--                                 service's own marker). Since redeem_growth_offer_v108 never
--                                 reads delivery_status at all, 'queued' is sufficient for this
--                                 walk — but it means the growth arm has never been exercised
--                                 with a delivery in a state that actually claims to have been
--                                 delivered. Flagged in the report; not fixed here (out of scope
--                                 for a test file, and touching the lifecycle service is a
--                                 production change).
--   growth_entitlements_v108     one row, status='issued', value_cents=500 (the $5 the header of
--                                the redeemer's own receipt reports), issued 30 minutes before
--                                the transaction and expiring in a day — safely inside the
--                                execution's started_at/ends_at window so the redemption
--                                function's own timing guard (sale must fall between
--                                greatest(issued_at,started_at) and least(expires_at,ends_at))
--                                has real margin either side.
--
-- THE MONEY CHECK. redeem_growth_offer_v108 does not touch credit_ledger or any wallet at all —
-- it only flips growth_entitlements_v108.status to 'redeemed', stamps redeemed_sale_id, and
-- appends one growth_entitlement_events_v108 row with the receipt in `detail`. There is no
-- second ledger write to double-check against; the receipt IS the record, and G8 below asserts
-- there is exactly one 'redeemed' event for the entitlement even after a replay. (This is worth
-- restating in the report: a "$5 credit" offer that never reaches the credit ledger is either a
-- deliberate design where the discount is applied elsewhere, or a real gap — the redeemer's own
-- receipt claims a value_cents but nothing spends it.)
--
-- NEGATIVE CONTROL, run 2026-09-08: copy this file, point the G5 cross-tenant probe at the
-- OWNING business (v_biz/v_staff in place of v_other/v_ostaff) while keeping the real sale, so
-- the call genuinely succeeds instead of being refused for an unrelated reason (a null sale
-- would fail anyway, for "no qualifying sale", which would prove nothing — this is why G4
-- creates the real sale BEFORE the isolation probe, not after). Result: the suite fails at
--   G5: ANOTHER BUSINESS redeemed this customer's growth offer
-- confirming the refusal in the real suite is about tenant isolation, not an incidental argument
-- mismatch. Every refusal below that sits behind `exception when others` (G5, G9) is paired with
-- a positive check that does not depend on the exception firing (G6, G8) — an isolation test
-- that only catches an error would pass just as happily if the call had failed for some other
-- reason.
--
--   supabase db query --linked -f db/tests/v820_growth_offer_end_to_end.sql

begin;

do $suite$
declare
  v_biz       uuid;
  v_other     uuid;
  v_ostaff    uuid;
  v_obranch   uuid;
  v_client    uuid;
  v_user      uuid;
  v_identity  uuid;
  v_link      uuid;
  v_staff     uuid;
  v_branch    uuid;
  v_service   uuid;
  v_reco      uuid;
  v_reco_mem  uuid;
  v_exec      uuid;
  v_exec_mem  uuid;
  v_delivery  uuid;
  v_entitlement uuid;
  v_now       timestamptz := now();
  v_dedupe    text;
  v_reqhash   text;
  v_gov       jsonb;
  v_res       jsonb;
  v_token     text;
  v_intent    uuid;
  v_eval      jsonb;
  v_sale      uuid;
  v_status    text;
  v_got       integer;
  n integer := 0;
begin
  -- An unrelated tenant with a real owner login and a live branch, so the isolation probe is a
  -- well-formed call refused on the TOKEN/TENANT, not on its arguments.
  select b.id, st.user_id, br.id into v_other, v_ostaff, v_obranch
    from public.businesses b
    join public.staff st on st.business_id = b.id and st.role = 'owner' and st.active and st.user_id is not null
    join public.branches br on br.business_id = b.id and br.active
   limit 1;
  if v_other is null then
    raise exception 'G0: no second tenant to test isolation against';
  end if;

  -- A verified customer whose business has an owner login, an active branch, and a priced
  -- service — everything the till-path sale creation in G4 needs.
  select l.business_id, l.client_id, l.auth_user_id, l.identity_id, l.id
    into v_biz, v_client, v_user, v_identity, v_link
    from public.customer_links l
    join public.customer_identities ci on ci.id = l.identity_id and ci.status = 'active'
   where l.state = 'verified'
     and l.business_id <> v_other
     and exists (select 1 from public.staff st where st.business_id = l.business_id
                   and st.role = 'owner' and st.active and st.user_id is not null)
     and exists (select 1 from public.branches br where br.business_id = l.business_id and br.active)
     and exists (select 1 from public.services sv where sv.business_id = l.business_id
                   and coalesce(sv.active, true) and sv.price_cents > 0)
   limit 1;
  if v_biz is null then
    raise exception 'G0: no verified customer with a usable business to walk the growth arm with';
  end if;

  select st.user_id into v_staff from public.staff st
   where st.business_id = v_biz and st.role = 'owner' and st.active and st.user_id is not null limit 1;
  select br.id into v_branch from public.branches br
   where br.business_id = v_biz and br.active order by br.is_default desc limit 1;
  select sv.id into v_service from public.services sv
   where sv.business_id = v_biz and coalesce(sv.active, true) and sv.price_cents > 0 limit 1;

  v_dedupe  := encode(extensions.digest(('growth-e2e-' || gen_random_uuid()::text)::bytea, 'sha256'), 'hex');
  v_reqhash := encode(extensions.digest(('growth-e2e-req-' || gen_random_uuid()::text)::bytea, 'sha256'), 'hex');

  -- ============================================================ FABRICATE THE GROWTH CHAIN
  -- recommendation -> recommendation_member -> execution -> execution_member -> delivery ->
  -- entitlement. See the header for why each row is shaped the way it is.
  insert into public.growth_recommendations_v108(
    business_id, branch_id, recommendation_type, policy_version,
    generated_at, valid_until, observation_start, observation_end,
    comparison_start, comparison_end, finding, supporting_evidence,
    baseline, opportunity, expected_incremental_revenue, expected_incremental_gross_profit,
    confidence, assumptions, recommended_action, recommended_channel, recommended_offer,
    estimated_cost_cents, audience_size, excluded_size, frequency_cap_days,
    approval_required, success_metric, attribution_window_days, holdout_percent,
    stop_conditions, status, suppression_reasons, data_freshness_at, data_coverage,
    dedupe_key, created_by
  ) values (
    v_biz, v_branch, 'lapsed_high_value_bring_back', 'v820-e2e-fixture-1',
    v_now - interval '2 hours', v_now + interval '1 day',
    v_now - interval '90 days', v_now - interval '30 days',
    v_now - interval '180 days', v_now - interval '90 days',
    'fabricated fixture for db/tests/v820_growth_offer_end_to_end.sql', '[]'::jsonb,
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, null,
    '{}'::jsonb, '[]'::jsonb, '{}'::jsonb, 'in_app', '{}'::jsonb,
    500, 1, 0, 30,
    true, 'incremental_completed_purchase_revenue', 14, 20,
    '{}'::jsonb, 'accepted', '[]'::jsonb, v_now, '{}'::jsonb,
    v_dedupe, v_staff
  ) returning id into v_reco;

  insert into public.growth_recommendation_members_v108(
    recommendation_id, business_id, client_id, eligible, exclusion_reason,
    prior_visits, last_visit_at, cadence_days, lapse_days,
    average_transaction_cents, historical_revenue_cents, evidence
  ) values (
    v_reco, v_biz, v_client, true, null,
    5, v_now - interval '45 days', 14, 45,
    2000, 10000, '{}'::jsonb
  ) returning id into v_reco_mem;

  v_gov := jsonb_build_object(
    'schema', 'nestly.growth_offer_copy', 'version', 1,
    'title', 'A little something for you', 'body', 'Come back and enjoy $5 on us.',
    'cta_label', 'Redeem now', 'cta_destination', 'customer_growth_offer_qr',
    'eligibility', jsonb_build_object('business_id', v_biz, 'branch_id', v_branch),
    'conditions', jsonb_build_object('expires_at', v_now + interval '1 day', 'timezone', 'Asia/Singapore'),
    'locked_facts', jsonb_build_object(
      'template_id', 'simple_saving', 'offer_value_cents', 500,
      'currency', 'SGD', 'expires_at', v_now + interval '1 day', 'timezone', 'Asia/Singapore'
    )
  );

  insert into public.growth_executions_v108(
    recommendation_id, business_id, branch_id, channel, offer_type, offer_value_cents,
    offer_label, currency, offer_timezone, offer_expires_at,
    governed_copy_schema, governed_copy_version, governed_copy,
    budget_cap_cents, holdout_percent, attribution_window_days, minimum_arm_size,
    status, approved_by, approved_at, started_at, ends_at,
    idempotency_key, request_hash
  ) values (
    v_reco, v_biz, v_branch, 'in_app', 'credit_cents', 500,
    'simple_saving', 'SGD', 'Asia/Singapore', v_now + interval '1 day',
    'nestly.growth_offer_copy', 1, v_gov,
    100000, 20, 14, 3,
    'running', v_staff, v_now - interval '1 hour', v_now - interval '1 hour', v_now + interval '2 days',
    gen_random_uuid(), v_reqhash
  ) returning id into v_exec;

  insert into public.growth_execution_members_v108(
    execution_id, business_id, client_id, assignment, assignment_score,
    assignment_rank, recommendation_member_id
  ) values (
    v_exec, v_biz, v_client, 'treatment',
    encode(extensions.digest(('assign-' || v_client::text)::bytea, 'sha256'), 'hex'),
    1, v_reco_mem
  ) returning id into v_exec_mem;

  insert into public.growth_deliveries_v108(
    execution_id, execution_member_id, business_id, client_id, identity_id, link_id,
    assignment, channel, delivery_status, suppression_reason,
    title, body, estimated_cost_cents
  ) values (
    v_exec, v_exec_mem, v_biz, v_client, v_identity, v_link,
    'treatment', 'in_app', 'queued', null,
    v_gov->>'title', v_gov->>'body', 500
  ) returning id into v_delivery;

  insert into public.growth_entitlements_v108(
    delivery_id, execution_id, business_id, client_id, identity_id,
    entitlement_type, value_cents, estimated_cost_cents, status,
    issued_at, expires_at
  ) values (
    v_delivery, v_exec, v_biz, v_client, v_identity,
    'credit_cents', 500, 500, 'issued',
    v_now - interval '30 minutes', v_now + interval '1 day'
  ) returning id into v_entitlement;

  -- ================================================================ G1: LIST THE OFFER
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_get_growth_offers_v108(v_biz)::jsonb;
  reset role; perform set_config('request.jwt.claims', '', true);
  select count(*)::integer into v_got
    from jsonb_array_elements(coalesce(v_res->'offers', '[]'::jsonb)) o
   where (o->>'entitlement_id')::uuid = v_entitlement;
  if v_got <> 1 then
    raise exception 'G%: customer_get_growth_offers_v108 did not list the fabricated entitlement (%)',
      n, left(v_res::text, 400);
  end if;

  -- ================================================================ G2: MINT THE QR
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_prepare_growth_offer_qr_v108(v_entitlement, gen_random_uuid())::jsonb;
  reset role; perform set_config('request.jwt.claims', '', true);
  v_token := coalesce(v_res->>'token', v_res->>'qr_token');
  v_intent := nullif(v_res->>'intent_id', '')::uuid;
  if v_token is null then
    raise exception 'G%: the growth offer QR came back with no token (%)', n, left(v_res::text, 300);
  end if;

  -- ================================================== G3: MINTING DOES NOT CHANGE STATUS
  n := n + 1;
  select status into v_status from public.growth_entitlements_v108 where id = v_entitlement;
  if v_status <> 'issued' then
    raise exception 'G%: minting the QR changed the entitlement status to %', n, v_status;
  end if;

  -- ============================================================ G4: A REAL QUALIFYING SALE
  -- Staged before the isolation probe so the cross-tenant call below is refused on the
  -- TOKEN/TENANT, not because it was handed a null sale — see the negative control in the
  -- header, which points this exact call at the owning business and watches it succeed.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_eval := public.evaluate_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_service, 'qty', 1)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  v_res := public.record_cart_sale(v_biz, v_client, v_branch, null, 'cash',
    'growth-e2e-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_service, 'qty', 1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims', '', true);
  v_sale := nullif(v_res->>'sale_id', '')::uuid;
  if v_sale is null then
    raise exception 'G%: record_cart_sale did not return a sale_id (%)', n, left(v_res::text, 300);
  end if;

  -- ============================================ G5/G6: CROSS-TENANT CANNOT SPEND THE QR
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ostaff, 'role', 'authenticated')::text, true);
    perform public.redeem_growth_offer_v108(v_other, v_token, v_sale, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims', '', true);
    raise exception 'G%: ANOTHER BUSINESS redeemed this customer''s growth offer', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims', '', true);
    if sqlerrm like 'G%ANOTHER BUSINESS%' then raise; end if;
  end;
  n := n + 1;
  select status into v_status from public.growth_entitlements_v108 where id = v_entitlement;
  if v_status <> 'issued' then
    raise exception 'G%: the cross-tenant growth redemption attempt still changed the entitlement (%)',
      n, v_status;
  end if;

  -- ======================================================== G7: THE OWNING BUSINESS REDEEMS
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_res := public.redeem_growth_offer_v108(v_biz, v_token, v_sale, gen_random_uuid())::jsonb;
  reset role; perform set_config('request.jwt.claims', '', true);
  select status into v_status from public.growth_entitlements_v108 where id = v_entitlement;
  if v_status <> 'redeemed' then
    raise exception 'G%: redeeming the growth offer did not settle the entitlement (status=%)', n, v_status;
  end if;
  if (select redeemed_sale_id from public.growth_entitlements_v108 where id = v_entitlement) <> v_sale then
    raise exception 'G%: the entitlement recorded the wrong sale as its redemption', n;
  end if;

  -- =============================================== G8: REPLAY DOES NOT REDEEM TWICE
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    perform public.redeem_growth_offer_v108(v_biz, v_token, v_sale, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims', '', true);
  exception when others then
    reset role; perform set_config('request.jwt.claims', '', true);
  end;
  select count(*)::integer into v_got from public.growth_entitlement_events_v108
   where entitlement_id = v_entitlement and event_type = 'redeemed';
  if v_got <> 1 then
    raise exception 'G%: REPLAYING THE SAME GROWTH OFFER QR recorded % redemption events, expected 1',
      n, v_got;
  end if;

  -- ============================================================= G9: UNKNOWN TOKEN REFUSED
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    perform public.redeem_growth_offer_v108(v_biz, 'not-a-real-growth-token', v_sale, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims', '', true);
    raise exception 'G%: the growth redeemer ACCEPTED a token that does not exist', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims', '', true);
    if sqlerrm like 'G%ACCEPTED a token%' then raise; end if;
  end;

  raise notice 'growth offer end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
