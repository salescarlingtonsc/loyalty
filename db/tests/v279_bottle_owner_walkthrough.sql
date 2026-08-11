-- Rollback-only acceptance for V279 — the owner's walkthrough of the live bottle keep module.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives. It borrows one existing open tenant and flips its industry to 'bar' for
-- the duration, exactly as db/tests/v275_bar_bottle_keep.sql and db/tests/v278_bottle_keep_parity.sql
-- do, so the real authorisation chain is exercised rather than a hand-built imitation of it.
--
-- What this proves, in order:
--   1  HARD BAR GATING still holds for both NEW RPCs: a genuine, fully authorised owner of a
--      NON-bar business is refused with 42501, before any other check.
--   2  RE-ENTRY IS GONE FROM EVERY READ AND WRITE. The shared projection and the customer read no
--      longer publish reentry_limit at all, and park_bottle_v278 — handed a re-entry limit of 4 by
--      a stale client — stores NULL. The column itself survives, because bottles parked before
--      today carry real values.
--   3  RETRIEVED IS TERMINAL. stored -> retrieved is allowed; retrieved -> called, retrieved ->
--      at_table and retrieved -> stored are ALL refused by the server, not merely unbuttoned. The
--      transition function agrees with the RPC.
--   4  THE THREE TABS. 'storage' is the three floor states as one answer, 'retrieved' and
--      'expired' are themselves, and a retrieved bottle leaves the customer's wallet card the way
--      a finished one does.
--   5  BATCH QUANTITY IS ONE INTENTION. Parking 3 writes 3 bottles with 3 consecutive serials and
--      3 evidence rows; replaying the SAME key returns duplicate_ignored with the SAME three
--      bottles and writes nothing more. Out-of-range quantities are refused.
--   6  CAPACITY IS ENFORCED, INCLUDING THE BATCH EDGE. With 2 free slots, a batch of 3 is refused
--      WHOLE (nothing is parked), a batch of 2 succeeds, and the next single park is refused. The
--      V275 and V278 park paths hold the same guard, so the till cannot walk around it.
--   7  anon holds no EXECUTE on either new RPC — and neither does PUBLIC.
--
-- Client behaviour is proven in tests/business-ui/v279-bottle-owner-walkthrough.test.mjs.
--
-- CORRECTIONS applied after the first real execution against production (2026-08-11). This file had
-- never been run before that; every change below is marked inline with "CORRECTION":
--   a  The verified-link probe did not require auth_user_id, so the customer read could have been
--      handed a link it cannot authenticate as.
--   b  Step 4 expired "the latest STORED bottle", but by that point the only bottle the suite had
--      parked was already retrieved — the UPDATE matched zero rows and the Expired-tab assertion
--      was vacuously true. A second bottle is now parked and expired by id.
--   c  The customer read swallowed ANY failure into an empty list, so a broken read would have
--      satisfied the two "must not appear" assertions. It now fails loudly, and a witness bottle
--      keeps the wallet list non-empty so the exclusions mean something.
--   d  park_bottle_v275's re-entry retirement was never exercised (only the v278 path was).
--   e  Serials were asserted DISTINCT but not CONTIGUOUS, and the capacity refusals were not
--      checked for being the capacity refusal rather than some other error.

begin;

create or replace function pg_temp.as_v279_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  reset role;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v279_user(uuid, text) to public;

do $v279$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_industry_before text;
  v_modules_before text[];
  v_owner uuid;
  v_link public.customer_links%rowtype;
  v_client uuid;
  v_shelf uuid;
  v_bottle uuid;
  v_payload jsonb;
  v_replay jsonb;
  v_key text;
  v_rpc text;
  v_raised boolean;
  v_count integer;
  v_before integer;
  v_status text;
  v_capacity integer;
  v_bottle_b uuid;      -- CORRECTION b/d: the second probe bottle, parked via the V275 path
  v_msg text;           -- CORRECTION e: the refusal text, so we can prove WHICH refusal it was
  v_min integer;
  v_max integer;
  v_cust_ok boolean;    -- CORRECTION c: did the customer read actually run?
begin
  select business.industry, business.enabled_modules
    into v_industry_before, v_modules_before
    from public.businesses business where business.id = v_biz;
  if v_industry_before is null then
    raise exception 'v279: fixture tenant % not found', v_biz;
  end if;
  if v_industry_before = 'bar' then
    raise exception 'v279: fixture tenant is already a bar - pick a non-bar tenant for the gate test';
  end if;

  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   limit 1;
  if v_owner is null then
    raise exception 'v279: fixture needs an approved owner';
  end if;

  -- CORRECTION a: the customer read authenticates AS the linked auth user, so a verified link with
  -- a null auth_user_id would make step 4 untestable rather than failing it.
  select * into v_link from public.customer_links link
   where link.business_id = v_biz and link.state = 'verified' and link.unlinked_at is null
     and link.auth_user_id is not null
   order by link.created_at limit 1;
  if v_link.id is null then
    raise exception 'v279: fixture needs a verified customer link with an auth user';
  end if;
  v_client := v_link.client_id;

  -- 1. HARD BAR GATING on both new surfaces, BEFORE the industry flip.
  foreach v_rpc in array array[
    'select public.bar_save_setup_v279($1, 30, 500, ''[]''::jsonb)',
    'select public.park_bottles_v279($1, null, ''x'', null, null, 100, null, null, null, ''auto'', null, ''none'', null, null, 1, ''k'')'
  ] loop
    v_raised := false;
    perform pg_temp.as_v279_user(v_owner);
    begin
      execute v_rpc using v_biz;
    exception when insufficient_privilege then
      v_raised := true;
    when others then
      reset role;
      raise exception 'v279: % raised % instead of 42501 for a non-bar owner', v_rpc, sqlstate;
    end;
    reset role;
    if not v_raised then
      raise exception 'v279: % did NOT refuse a non-bar business', v_rpc;
    end if;
  end loop;
  raise notice 'v279 [1] OK - both new RPCs refuse a non-bar business with 42501';

  -- Flip the fixture to a bar for the rest of the suite. V75's
  -- app.business_sector_modules_guard_v75 refuses any change to industry/enabled_modules for a
  -- business carrying a sector assignment; its own documented escape hatch is a session GUC naming
  -- the business being synced. Open it for the flip and shut it again immediately.
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);
  update public.businesses
     set industry = 'bar',
         enabled_modules = (select array_agg(distinct value)
                              from unnest(coalesce(v_modules_before, '{}'::text[]) || array['bottles','clients','sales']) value)
   where id = v_biz;
  perform set_config('app.sector_entitlement_sync', '', true);

  insert into public.bar_bottle_settings (business_id, keep_days, storage_capacity)
  values (v_biz, 20, 10000)
  on conflict (business_id) do update set keep_days = 20, storage_capacity = 10000;

  insert into public.bar_storage_locations (business_id, name, active, sort)
  values (v_biz, 'V279 Shelf A', true, 1) returning id into v_shelf;

  -- The setup save carries the capacity, owner-gated, and reads back what it wrote.
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.bar_save_setup_v279(v_biz, 20, 9000,
    jsonb_build_array(jsonb_build_object('id', v_shelf::text, 'name', 'V279 Shelf A')));
  reset role;
  if (v_payload->>'storage_capacity')::integer <> 9000 then
    raise exception 'v279: the setup save did not store the capacity (got %)',
      v_payload->>'storage_capacity';
  end if;
  if (v_payload->>'in_storage') is null then
    raise exception 'v279: the setup read must report how many bottles are in storage';
  end if;
  v_raised := false;
  perform pg_temp.as_v279_user(v_owner);
  begin
    perform public.bar_save_setup_v279(v_biz, 20, 0,
      jsonb_build_array(jsonb_build_object('id', v_shelf::text, 'name', 'V279 Shelf A')));
  exception when others then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v279: a capacity of 0 must be refused';
  end if;
  raise notice 'v279 [1b] OK - bar_save_setup_v279 stores and bounds the storage capacity';

  -- 2. RE-ENTRY IS GONE. A stale client still sends p_reentry_limit; the server ignores it.
  v_key := 'v279-reentry-' || gen_random_uuid()::text;
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.park_bottle_v278(v_biz, v_client, 'V279 re-entry probe', null, 700, 100,
    v_shelf, 4, null, null, 'auto', null, 'none', null, null, v_key);
  reset role;
  v_bottle := (v_payload->'bottle'->>'id')::uuid;
  if (select bottle.reentry_limit from public.bar_bottles bottle where bottle.id = v_bottle) is not null then
    raise exception 'v279: park_bottle_v278 still stored a re-entry limit';
  end if;
  if v_payload->'bottle' ? 'reentry_limit' then
    raise exception 'v279: the shared projection still publishes reentry_limit';
  end if;
  -- The column survives, because history is not edited to tidy a form.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'bar_bottles'
                    and column_name = 'reentry_limit') then
    raise exception 'v279: bar_bottles.reentry_limit must be KEPT, only stopped being read';
  end if;
  raise notice 'v279 [2] OK - re-entry is accepted and ignored, published nowhere, column kept';

  -- CORRECTION e: the honest capacity edge is a bar with exactly ONE bottle on a two-slot shelf
  -- being asked for three. It must refuse all three, and it must refuse them for the CAPACITY
  -- reason. Run it here, while in-storage is provably 1, then restore the roomy capacity.
  if app.bar_in_storage_count_v279(v_biz) <> 1 then
    raise exception 'v279: expected exactly 1 bottle in storage at the capacity edge, found %',
      app.bar_in_storage_count_v279(v_biz);
  end if;
  update public.bar_bottle_settings set storage_capacity = 2 where business_id = v_biz;
  select count(*) into v_before from public.bar_bottles bottle where bottle.business_id = v_biz;
  v_msg := null;
  perform pg_temp.as_v279_user(v_owner);
  begin
    perform public.park_bottles_v279(v_biz, v_client, 'V279 cap probe', null, 700, 100, v_shelf,
      null, null, 'auto', null, 'none', null, null, 3, 'v279-capb-' || gen_random_uuid()::text);
  exception when others then
    v_msg := sqlerrm;
  end;
  reset role;
  if v_msg is null then
    raise exception 'v279: a batch of 3 into capacity 2 with 1 used was NOT refused';
  end if;
  if position('Storage is full' in v_msg) = 0 then
    raise exception 'v279: the capacity refusal did not name the wall: %', v_msg;
  end if;
  if (select count(*) from public.bar_bottles bottle where bottle.business_id = v_biz) <> v_before then
    raise exception 'v279: the refused batch parked rows anyway - it must be refused WHOLE';
  end if;
  update public.bar_bottle_settings set storage_capacity = 9000 where business_id = v_biz;
  raise notice 'v279 [2b] OK - capacity 2 with 1 stored refuses a batch of 3 whole (%)', v_msg;

  -- CORRECTION d: the V275 park path retires re-entry too, and was never exercised. It also leaves
  -- a bottle on the shelf, which step 4 needs in order to have something real to expire.
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.park_bottle_v275(v_biz, v_client, 'V279 v275 re-entry probe', null, 700, 100,
    v_shelf, 7, null, null, 'v279-p275-' || gen_random_uuid()::text);
  reset role;
  v_bottle_b := coalesce(nullif(v_payload->'bottle'->>'id', ''), nullif(v_payload->>'id', ''))::uuid;
  if v_bottle_b is null then
    raise exception 'v279: could not read the bottle id back from park_bottle_v275: %', v_payload;
  end if;
  if (select bottle.reentry_limit from public.bar_bottles bottle where bottle.id = v_bottle_b) is not null then
    raise exception 'v279: park_bottle_v275 still stored a re-entry limit';
  end if;
  if app.bar_bottle_json_v275((select b from public.bar_bottles b where b.id = v_bottle_b)) ? 'reentry_limit' then
    raise exception 'v279: bar_bottle_json_v275 still emits reentry_limit';
  end if;
  raise notice 'v279 [2c] OK - park_bottle_v275 also ignores re-entry and the projection omits it';

  -- 3. RETRIEVED IS TERMINAL.
  if not app.bar_status_transition_allowed_v279('stored', 'retrieved') then
    raise exception 'v279: a stored bottle must be able to be sent out';
  end if;
  foreach v_status in array array['stored', 'called', 'at_table', 'retrieved'] loop
    if app.bar_status_transition_allowed_v279('retrieved', v_status) then
      raise exception 'v279: retrieved -> % must be impossible', v_status;
    end if;
  end loop;

  v_key := 'v279-retrieve-' || gen_random_uuid()::text;
  perform pg_temp.as_v279_user(v_owner);
  perform public.set_bottle_status_v275(v_biz, v_bottle, 'retrieved', v_key);
  reset role;
  if (select bottle.status from public.bar_bottles bottle where bottle.id = v_bottle) <> 'retrieved' then
    raise exception 'v279: the bottle did not reach retrieved';
  end if;
  foreach v_status in array array['called', 'at_table', 'stored'] loop
    v_raised := false;
    perform pg_temp.as_v279_user(v_owner);
    begin
      perform public.set_bottle_status_v275(v_biz, v_bottle, v_status,
        'v279-after-' || v_status || '-' || gen_random_uuid()::text);
    exception when others then
      v_raised := true;
    end;
    reset role;
    if not v_raised then
      raise exception 'v279: retrieved -> % was NOT refused by the server', v_status;
    end if;
  end loop;
  raise notice 'v279 [3] OK - retrieved is terminal: nothing transitions out of it';

  -- 4. THE THREE TABS, and the customer card.
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.list_bar_bottles_v275(v_biz, null, 'retrieved', null, null, null, 200);
  reset role;
  if not exists (select 1 from jsonb_array_elements(v_payload->'items') entry
                  where (entry->>'id')::uuid = v_bottle) then
    raise exception 'v279: the Retrieved tab does not list a retrieved bottle';
  end if;
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.list_bar_bottles_v275(v_biz, null, 'storage', null, null, null, 200);
  reset role;
  if exists (select 1 from jsonb_array_elements(v_payload->'items') entry
              where (entry->>'id')::uuid = v_bottle) then
    raise exception 'v279: the Storage tab must not list a retrieved bottle';
  end if;
  if exists (select 1 from jsonb_array_elements(v_payload->'items') entry
              where entry->>'status' not in ('stored', 'called', 'at_table')) then
    raise exception 'v279: the Storage tab must be exactly the three floor states';
  end if;
  if (v_payload->>'storage_capacity') is null or (v_payload->>'in_storage') is null then
    raise exception 'v279: the list read must carry the capacity gauge';
  end if;

  -- An expired bottle answers the third tab. CORRECTION b: expire a bottle we hold the id of and
  -- assert it LANDS in the tab. The original picked "the latest stored bottle" by subquery, which
  -- at this point in the suite matched nothing (the only parked bottle was already retrieved), so
  -- the UPDATE touched zero rows and the assertion below could never fail.
  update public.bar_bottles set status = 'expired' where id = v_bottle_b;
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.list_bar_bottles_v275(v_biz, null, 'expired', null, null, null, 200);
  reset role;
  if not exists (select 1 from jsonb_array_elements(v_payload->'items') entry
                  where (entry->>'id')::uuid = v_bottle_b) then
    raise exception 'v279: the Expired tab did not list the bottle just expired';
  end if;
  if exists (select 1 from jsonb_array_elements(v_payload->'items') entry
              where entry->>'status' <> 'expired') then
    raise exception 'v279: the Expired tab must be exactly the expired bottles';
  end if;

  -- CORRECTION c: a WITNESS bottle still on the shelf for the same customer, so the two exclusion
  -- assertions below cannot pass merely because the wallet card came back empty.
  perform pg_temp.as_v279_user(v_owner);
  perform public.park_bottles_v279(v_biz, v_client, 'V279 wallet witness', null, 700, 100, v_shelf,
    null, null, 'auto', null, 'none', null, null, 1, 'v279-wit-' || gen_random_uuid()::text);
  reset role;

  v_cust_ok := true;
  perform pg_temp.as_v279_user(v_link.auth_user_id);
  begin
    v_payload := public.customer_get_bottles_v275(
      (select business.slug from public.businesses business where business.id = v_biz));
  exception when others then
    v_cust_ok := false;
    v_msg := sqlerrm;
    v_payload := jsonb_build_object('items', '[]'::jsonb);
  end;
  reset role;
  -- CORRECTION c: the original swallowed ANY failure into an empty list, so a customer read that
  -- was broken outright would have satisfied both assertions below. Fail loudly instead.
  if not v_cust_ok then
    raise exception 'v279: the customer wallet read itself failed: %', v_msg;
  end if;
  if jsonb_array_length(v_payload->'items') < 1 then
    raise exception 'v279: the wallet witness bottle is missing - the exclusions would be vacuous';
  end if;
  if exists (select 1 from jsonb_array_elements(v_payload->'items') entry
              where (entry->>'id')::uuid in (v_bottle, v_bottle_b)) then
    raise exception 'v279: a retrieved or expired bottle must leave the customer wallet card';
  end if;
  if exists (select 1 from jsonb_array_elements(v_payload->'items') entry
              where entry ? 'reentry_limit') then
    raise exception 'v279: the customer read still publishes reentry_limit';
  end if;
  raise notice 'v279 [4] OK - Storage / Retrieved / Expired are three clean answers';

  -- 5. BATCH QUANTITY IS ONE INTENTION.
  select count(*) into v_before from public.bar_bottles bottle where bottle.business_id = v_biz;
  v_key := 'v279-batch-' || gen_random_uuid()::text;
  perform pg_temp.as_v279_user(v_owner);
  v_payload := public.park_bottles_v279(v_biz, v_client, 'V279 batch bottle', null, 700, 100,
    v_shelf, null, null, 'auto', null, 'none', 'Batch of three', null, 3, v_key);
  reset role;
  if (v_payload->>'count')::integer <> 3 or jsonb_array_length(v_payload->'bottles') <> 3 then
    raise exception 'v279: parking 3 did not return 3 bottles';
  end if;
  select count(*) into v_count from public.bar_bottles bottle where bottle.business_id = v_biz;
  if v_count <> v_before + 3 then
    raise exception 'v279: parking 3 wrote % rows, expected 3', v_count - v_before;
  end if;
  select count(distinct entry->>'serial_code') into v_count
    from jsonb_array_elements(v_payload->'bottles') entry;
  if v_count <> 3 then
    raise exception 'v279: a batch must give every bottle its own serial';
  end if;
  -- CORRECTION e: distinct is not enough. A physical shelf run is CONTIGUOUS, and contiguity is
  -- what proves the batch allocated one range under the settings-row lock rather than three
  -- independent serials that merely happened not to collide.
  select min(bottle.serial_seq), max(bottle.serial_seq)
    into v_min, v_max
    from public.bar_bottles bottle
   where bottle.id in (select (entry->>'id')::uuid
                         from jsonb_array_elements(v_payload->'bottles') entry);
  if v_max - v_min <> 2 then
    raise exception 'v279: a batch of 3 must take 3 CONTIGUOUS serials, got % .. %', v_min, v_max;
  end if;
  select count(*) into v_count from public.bar_bottle_events event
   where event.business_id = v_biz
     and left(event.idem_key, length(v_key) + 1) = v_key || '#';
  if v_count <> 3 then
    raise exception 'v279: a batch of 3 wrote % evidence rows, expected 3', v_count;
  end if;

  perform pg_temp.as_v279_user(v_owner);
  v_replay := public.park_bottles_v279(v_biz, v_client, 'V279 batch bottle', null, 700, 100,
    v_shelf, null, null, 'auto', null, 'none', 'Batch of three', null, 3, v_key);
  reset role;
  if v_replay->>'status' <> 'duplicate_ignored' then
    raise exception 'v279: replaying a batch key must answer duplicate_ignored (got %)',
      v_replay->>'status';
  end if;
  if (select count(*) from public.bar_bottles bottle where bottle.business_id = v_biz) <> v_before + 3 then
    raise exception 'v279: replaying a batch key parked more bottles';
  end if;
  if (select array_agg(entry->>'id' order by entry->>'serial_code')
        from jsonb_array_elements(v_payload->'bottles') entry)
     is distinct from
     (select array_agg(entry->>'id' order by entry->>'serial_code')
        from jsonb_array_elements(v_replay->'bottles') entry) then
    raise exception 'v279: the replay returned a different batch';
  end if;

  foreach v_count in array array[0, 21] loop
    v_raised := false;
    perform pg_temp.as_v279_user(v_owner);
    begin
      perform public.park_bottles_v279(v_biz, v_client, 'V279 bad quantity', null, 700, 100,
        v_shelf, null, null, 'auto', null, 'none', null, null, v_count,
        'v279-qty-' || v_count::text || '-' || gen_random_uuid()::text);
    exception when others then
      v_raised := true;
    end;
    reset role;
    if not v_raised then
      raise exception 'v279: a quantity of % must be refused', v_count;
    end if;
  end loop;
  raise notice 'v279 [5] OK - a batch is one intention: 3 rows, 3 serials, 3 events, replay-safe';

  -- 6. CAPACITY, INCLUDING THE BATCH EDGE.
  v_capacity := app.bar_in_storage_count_v279(v_biz) + 2;
  update public.bar_bottle_settings set storage_capacity = v_capacity where business_id = v_biz;
  select count(*) into v_before from public.bar_bottles bottle where bottle.business_id = v_biz;

  v_raised := false;
  perform pg_temp.as_v279_user(v_owner);
  begin
    perform public.park_bottles_v279(v_biz, v_client, 'V279 over capacity', null, 700, 100,
      v_shelf, null, null, 'auto', null, 'none', null, null, 3,
      'v279-cap-batch-' || gen_random_uuid()::text);
  exception when others then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v279: a batch of 3 into 2 free slots must be refused';
  end if;
  if (select count(*) from public.bar_bottles bottle where bottle.business_id = v_biz) <> v_before then
    raise exception 'v279: the refused batch parked bottles anyway - it must be refused WHOLE';
  end if;

  perform pg_temp.as_v279_user(v_owner);
  perform public.park_bottles_v279(v_biz, v_client, 'V279 last two', null, 700, 100,
    v_shelf, null, null, 'auto', null, 'none', null, null, 2,
    'v279-cap-fill-' || gen_random_uuid()::text);
  reset role;
  if app.bar_in_storage_count_v279(v_biz) <> v_capacity then
    raise exception 'v279: the bar should now be exactly full';
  end if;

  -- Every park path holds the same guard, so the till cannot walk around it.
  foreach v_rpc in array array[
    'select public.park_bottles_v279($1, $2, ''V279 full'', null, 700, 100, null, null, null, ''auto'', null, ''none'', null, null, 1, $3)',
    'select public.park_bottle_v278($1, $2, ''V279 full'', null, 700, 100, null, null, null, null, ''auto'', null, ''none'', null, null, $3)',
    'select public.park_bottle_v275($1, $2, ''V279 full'', null, 700, 100, null, null, null, null, $3)'
  ] loop
    v_msg := null;
    perform pg_temp.as_v279_user(v_owner);
    begin
      execute v_rpc using v_biz, v_client, 'v279-full-' || gen_random_uuid()::text;
    exception when others then
      v_msg := sqlerrm;
    end;
    reset role;
    if v_msg is null then
      raise exception 'v279: % parked a bottle into a full bar', v_rpc;
    end if;
    -- CORRECTION e: "it raised something" is not "capacity stopped it". Name the refusal.
    if position('Storage is full' in v_msg) = 0 then
      raise exception 'v279: % refused for the wrong reason: %', v_rpc, v_msg;
    end if;
  end loop;
  raise notice 'v279 [6] OK - capacity refuses the whole batch, and every park path holds it';

  -- 7. anon holds no EXECUTE on either new RPC.
  foreach v_rpc in array array[
    'public.bar_save_setup_v279(uuid, integer, integer, jsonb)',
    'public.park_bottles_v279(uuid, uuid, text, uuid, integer, integer, uuid, uuid, uuid, text, date, text, text, date, integer, text)'
  ] loop
    if not has_function_privilege('authenticated', v_rpc, 'execute') then
      raise exception 'v279: authenticated cannot execute %', v_rpc;
    end if;
    if has_function_privilege('anon', v_rpc, 'execute') then
      raise exception 'v279: anon can execute %', v_rpc;
    end if;
    -- CORRECTION e: anon alone is not the whole matrix. A create-from-scratch replay would inherit
    -- PostgreSQL's default EXECUTE-to-PUBLIC, which no anon check would ever notice. A NULL proacl
    -- IS the default grant, so it counts as PUBLIC holding EXECUTE.
    if (select (p.proacl is null)
                or exists (select 1 from unnest(p.proacl) acl where acl::text like '=%X%')
          from pg_proc p where p.oid = v_rpc::regprocedure) then
      raise exception 'v279: PUBLIC still holds EXECUTE on %', v_rpc;
    end if;
  end loop;
  raise notice 'v279 [7] OK - authenticated yes, anon no, PUBLIC no, on both new RPCs';

  raise notice 'v279: ALL CHECKS PASSED (rolling back)';
end
$v279$;

rollback;
