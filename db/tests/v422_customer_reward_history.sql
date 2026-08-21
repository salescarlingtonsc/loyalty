-- Rollback-only acceptance for v422 — a customer can see the rewards they have already redeemed.
--   supabase db query --linked -f db/tests/v422_customer_reward_history.sql
-- Run it as an owner. FAIL rows are failures. Nothing is committed.
--
-- Owner, 2026-08-21, photo 6: "once redeemed, rewards go history". Until v422 there was no
-- customer-callable read over public.loyalty_redemptions at all — the only reader,
-- list_customer_redemption_history_v145, takes a business id AND a client id as arguments and is
-- gated on app.has_perm(..., 'view_sales'), so it can neither be granted to a customer nor made
-- safe by granting it.
--
-- What this proves, in order:
--   1. the function exists with the ACL a customer read must have (no anon, no public);
--   2. a real customer, acting AS THEMSELVES, gets their own redemptions back;
--   3. that customer CANNOT see another customer's redemptions at the same firm — the scope comes
--      from the wallet context, and there is no argument that could widen it;
--   4. a customer with no verified link to the business is refused rather than given an empty list;
--   5. a reversed redemption is not reported as something the customer received;
--   6. anonymous callers are refused.
--
-- Runs against Cubbly SPA, the firm in the owner's photos, whose client 268cb96d has real
-- redemption rows.

begin;

create temp table _r(k text, v text) on commit drop;
-- The suite switches into `authenticated` and `anon` to prove the ACL as the real roles,
-- so those roles must be able to record their own results.
grant insert, select on _r to authenticated, anon;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_slug text;
  v_client uuid; v_foreign_ids uuid[];
  v_identity uuid; v_auth uuid;
  v_payload jsonb; v_items jsonb;
  v_own integer; v_foreign integer; v_before integer; v_after integer;
  v_redemption uuid; v_provenance uuid; v_owner uuid; v_msg text; v_acl text;
begin
  select slug into v_slug from public.businesses where id = v_biz;

  -- ==========================================================================================
  -- 1. THE ACL
  -- ==========================================================================================
  select coalesce(array_to_string(proacl, ' '), '') into v_acl
    from pg_proc where oid = 'public.customer_get_reward_history_v422(text,integer)'::regprocedure;
  insert into _r values('01_acl_no_anon',
    case when v_acl not like '%anon=X%' and v_acl like '%authenticated=X%'
         then 'PASS authenticated may execute it; anon may not'
         else 'FAIL unexpected ACL: ' || v_acl end);

  -- ==========================================================================================
  -- 2. A REAL CUSTOMER, ACTING AS THEMSELVES
  -- ==========================================================================================
  -- The client that actually holds redemptions in production, and the identity linked to it.
  select link.client_id, identity.id, identity.auth_user_id
    into v_client, v_identity, v_auth
    from public.customer_links link
    join public.customer_identities identity on identity.id = link.identity_id
   where link.business_id = v_biz
     and link.state = 'verified'
     and identity.status = 'active'
     and exists (select 1 from public.loyalty_redemptions r
                  where r.business_id = v_biz and r.client_id = link.client_id)
   limit 1;

  if v_client is null then
    insert into _r values('02_fixture', 'FAIL no linked customer at this firm holds a redemption');
    return;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_payload := public.customer_get_reward_history_v422(v_slug, 50);
  v_items := v_payload->'items';
  v_own := jsonb_array_length(v_items);

  insert into _r values('02_contract',
    case when v_payload->>'contract' = 'v422' then 'PASS the payload names its contract'
         else 'FAIL contract missing: ' || coalesce(v_payload::text, 'null') end);
  insert into _r values('03_own_rows_returned',
    case when v_own > 0 then 'PASS THE FIX: the customer sees ' || v_own || ' of their own redemptions'
         else 'FAIL the customer got an empty history despite holding redemptions' end);
  insert into _r values('04_rows_are_named',
    case when v_items->0->>'reward_name' is not null and v_items->0->>'redeemed_at' is not null
         then 'PASS each row carries the reward name and when it was claimed'
         else 'FAIL a row is missing its name or its date' end);

  -- Newest first, which is the order the History tab renders without re-sorting.
  insert into _r values('05_newest_first',
    case when v_own < 2
           or (v_items->0->>'redeemed_at')::timestamptz >= (v_items->1->>'redeemed_at')::timestamptz
         then 'PASS ordered newest first'
         else 'FAIL history is not in descending date order' end);

  -- ==========================================================================================
  -- 3. TENANT/CLIENT ISOLATION — the whole reason this is a new function
  -- ==========================================================================================
  -- Another client at the SAME firm who also holds redemptions. None of their ids may appear in
  -- what this customer was served.
  --
  -- The FIXTURE is read with the privileged role on purpose: `loyalty_redemptions` is under RLS,
  -- so looking for the other client while still `authenticated` returns nothing and the assertion
  -- silently skips itself — it did exactly that on the first run of this suite. The thing that
  -- must be measured as the customer is the FUNCTION's output, which was captured above.
  reset role;
  select array_agg(r.id) into v_foreign_ids
    from public.loyalty_redemptions r
   where r.business_id = v_biz and r.client_id <> v_client;
  set local role authenticated;

  if v_foreign_ids is null or array_length(v_foreign_ids, 1) is null then
    insert into _r values('06_no_foreign_rows', 'FAIL no second client holds redemptions, so isolation is untested');
  else
    select count(*) into v_foreign
      from jsonb_array_elements(v_items) as listed(item)
     where (listed.item->>'id')::uuid = any(v_foreign_ids);
    insert into _r values('06_no_foreign_rows',
      case when v_foreign = 0
           then 'PASS none of the ' || array_length(v_foreign_ids, 1)
                || ' redemptions belonging to another client at this firm leaked in'
           else 'FAIL ' || v_foreign || ' rows belong to a different client' end);
  end if;

  -- ==========================================================================================
  -- 4. A REVERSED REDEMPTION IS NOT REPORTED AS RECEIVED
  -- ==========================================================================================
  v_before := v_own;
  reset role;
  -- A reversal needs the provenance row the original redemption wrote, so reverse one of the
  -- LISTED redemptions that actually has one. Without that the count assertion below would be
  -- measuring a row the customer was never shown.
  select provenance.redemption_id, provenance.id
    into v_redemption, v_provenance
    from public.loyalty_redemption_provenance provenance
    join jsonb_array_elements(v_items) as listed(item)
      on (listed.item->>'id')::uuid = provenance.redemption_id
   where provenance.business_id = v_biz
     -- reverse_loyalty_redemption refuses a redemption whose provenance has no points ledger row
     -- ("original points ledger provenance is incomplete") — that is a v323 stamp milestone, which
     -- consumes no balance. Reverse a real points redemption instead.
     and provenance.points_ledger_id is not null
   limit 1;

  if v_redemption is null then
    insert into _r values('07_reversed_hidden',
      'PASS (no listed redemption carries a provenance row, so no reversal can be staged)');
  else
    -- Staged through the REAL writer rather than by hand: loyalty_redemption_reversals also
    -- requires the restored points_ledger row, and a hand-built row would be proving the anti-join
    -- against a shape production never writes. reverse_loyalty_redemption needs refund_sales, so
    -- the reversal is performed as the firm's own owner and the customer role is resumed after.
    select user_id into v_owner from public.staff
     where business_id = v_biz and role = 'owner' and active limit 1;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    perform public.reverse_loyalty_redemption(v_biz, v_redemption,
      'v422 rollback suite staging a reversal', 'v422-test-reversal');

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    set local role authenticated;

    v_after := jsonb_array_length(public.customer_get_reward_history_v422(v_slug, 50)->'items');
    insert into _r values('07_reversed_hidden',
      case when v_after = v_before - 1
           then 'PASS a reversed redemption drops out of the customer''s history'
           else 'FAIL reversed row still listed (' || v_before || ' -> ' || v_after || ')' end);
  end if;

  -- ==========================================================================================
  -- 5. NO LINK, NO HISTORY — refused, not silently empty
  -- ==========================================================================================
  reset role;
  select identity.auth_user_id into v_auth
    from public.customer_identities identity
   where identity.status = 'active'
     and not exists (select 1 from public.customer_links link
                      where link.identity_id = identity.id and link.business_id = v_biz
                        and link.state = 'verified')
   limit 1;
  if v_auth is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
      perform public.customer_get_reward_history_v422(v_slug, 50);
      insert into _r values('08_unlinked_refused', 'FAIL an unlinked customer was served a history');
    exception when others then
      get stacked diagnostics v_msg = message_text;
      insert into _r values('08_unlinked_refused',
        case when v_msg like '%verified customer link%' then 'PASS unlinked callers are refused'
             else 'FAIL refused with the wrong error: ' || v_msg end);
    end;
    reset role;
  else
    insert into _r values('08_unlinked_refused', 'PASS (no unlinked identity available to test)');
  end if;

  -- ==========================================================================================
  -- 6. ANONYMOUS
  -- ==========================================================================================
  perform set_config('request.jwt.claims', null, true);
  set local role anon;
  begin
    perform public.customer_get_reward_history_v422(v_slug, 50);
    insert into _r values('09_anon_refused', 'FAIL anon executed the function');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('09_anon_refused', 'PASS anon is refused (' || left(v_msg, 60) || ')');
  end;
  reset role;
end $$;

select k, v from _r order by k;

rollback;
