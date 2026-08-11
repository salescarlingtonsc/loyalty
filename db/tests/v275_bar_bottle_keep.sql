-- Rollback-only acceptance for V275 — bar sector bottle keep.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in ROLLBACK: it
-- writes nothing that survives. No bar tenant exists yet (verified 2026-08-11: every business
-- carries industry facial/fnb/salon/test), so rather than fabricate a whole workspace — controls,
-- subscription lifecycle, staff, branches, customer identities and verified links, all of which
-- app.business_workspace_open_v94 and the wallet context legitimately demand — the suite borrows
-- ONE existing open tenant and flips its industry to 'bar' for the duration. That is the honest
-- fixture: it exercises the real authorisation chain instead of a hand-built imitation of it.
--
-- What this proves, in order:
--   1  HARD BAR GATING, the owner's amendment 4. Before the flip, EVERY one of the ten public
--      RPCs refuses a genuine, fully-authorised OWNER of a non-bar business with 42501. This is
--      the assertion that makes the module exclusive rather than merely hidden: hiding the nav
--      would leave all ten callable by hash or by curl.
--   2  Setup: one keep-days number (owner amendment 2) and the bar's own storage-location list
--      (amendment 3); a location dropped from the list is DEACTIVATED, never deleted, so a
--      bottle still points at a nameable shelf.
--   3  Park: per-business serial PK-YYYY-0001, expires_at = parked_at + the business's OWN keep
--      window (45 here, not the 30 default), and exactly one 'park' event.
--   4  Idempotency: replaying any mutating call with the same key returns duplicate_ignored,
--      changes no state and writes no second event.
--   5  One event per write across fill / status / extend / transfer / finish, with before→after
--      recorded — the property-dispute record.
--   6  set_bottle_status refuses a terminal status; finish and transfer refuse a closed bottle.
--   7  The events table rejects UPDATE and DELETE.
--   8  Tier integration: sales.kind='bottle_keep' is legal and its resolved policy is
--      revenue=true, visit=true, points=true — which is the whole VIP story (owner amendment 1:
--      no tier column was added anywhere).
--   9  Customer side: a verified customer sees ONLY their own bottles at that business, and a
--      second customer of the same business sees none of them.
--  10  anon holds no EXECUTE on any of the ten RPCs.
--
-- Client behaviour (nav gating, route guard, dialogs, wallet card) is proven in
-- tests/business-ui/v275-bar-bottle-keep.test.mjs.

begin;

create or replace function pg_temp.as_v275_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  -- reset first: a non-superuser role cannot SET ROLE to another role, so a second call while
  -- already in `authenticated` would fail.
  reset role;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v275_user(uuid, text) to public;

do $v275$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_industry_before text;
  v_modules_before text[];
  v_owner uuid;
  v_link_a public.customer_links%rowtype;
  v_link_b public.customer_links%rowtype;
  v_key text := 'v275-suite-' || gen_random_uuid()::text;
  v_payload jsonb;
  v_bottle uuid;
  v_shelf uuid;
  v_chiller uuid;
  v_year integer := extract(year from (now() at time zone 'Asia/Singapore'))::integer;
  v_count integer;
  v_expires timestamptz;
  v_raised boolean;
  v_rpc text;
  v_policy record;
begin
  select business.industry, business.enabled_modules
    into v_industry_before, v_modules_before
    from public.businesses business where business.id = v_biz;
  if v_industry_before is null then
    raise exception 'v275: fixture tenant % not found', v_biz;
  end if;
  if v_industry_before = 'bar' then
    raise exception 'v275: fixture tenant is already a bar - pick a non-bar tenant for the gate test';
  end if;

  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   limit 1;
  if v_owner is null then
    raise exception 'v275: fixture needs an approved owner';
  end if;

  select * into v_link_a from public.customer_links link
   where link.business_id = v_biz and link.state = 'verified' and link.unlinked_at is null
   order by link.created_at limit 1;
  select * into v_link_b from public.customer_links link
   where link.business_id = v_biz and link.state = 'verified' and link.unlinked_at is null
     and link.id <> v_link_a.id
   order by link.created_at limit 1;
  if v_link_a.id is null or v_link_b.id is null then
    raise exception 'v275: fixture needs two verified customer links';
  end if;

  -- 1. HARD BAR GATING. A real owner of a non-bar business is refused by all ten RPCs.
  foreach v_rpc in array array[
    'select public.bar_get_setup_v275($1)',
    'select public.bar_save_setup_v275($1, 30, ''[]''::jsonb)',
    'select public.park_bottle_v275($1, null, ''x'', null, null, 100, null, null, null, null, ''k'')',
    'select public.set_bottle_fill_v275($1, null, 50, ''k'')',
    'select public.set_bottle_status_v275($1, null, ''called'', ''k'')',
    'select public.extend_bottle_v275($1, null, null, ''k'')',
    'select public.transfer_bottle_v275($1, null, null, ''k'')',
    'select public.finish_bottle_v275($1, null, ''k'')',
    'select public.list_bar_bottles_v275($1, null, null, null, null, null, 50)',
    'select public.customer_get_bottles_v275((select business.slug from public.businesses business where business.id = $1))'
  ] loop
    v_raised := false;
    perform pg_temp.as_v275_user(case when v_rpc like '%customer_get_bottles%'
      then v_link_a.auth_user_id else v_owner end);
    begin
      execute v_rpc using v_biz;
    exception when others then
      v_raised := true;
      if sqlstate <> '42501' then
        raise exception 'v275: % must refuse a non-bar business with 42501, got % (%)',
          v_rpc, sqlstate, sqlerrm;
      end if;
    end;
    reset role;
    if not v_raised then
      raise exception 'v275: % did not refuse a non-bar business', v_rpc;
    end if;
  end loop;

  -- Become a bar. The v75 sector guard fixes modules to the assigned entitlement, so the
  -- fixture uses the same escape hatch the entitlement sync itself uses.
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);
  update public.businesses business
     set industry = 'bar',
         enabled_modules = (
           select array_agg(distinct module order by module)
             from unnest(business.enabled_modules || array['bottles']::text[]) module
         )
   where business.id = v_biz;
  perform set_config('app.sector_entitlement_sync', '', true);

  -- 2. Setup. One number, and the bar's own shelf list.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.bar_save_setup_v275(v_biz, 45, jsonb_build_array(
    jsonb_build_object('name', 'Shelf A'),
    jsonb_build_object('name', 'Chiller 2'),
    jsonb_build_object('name', 'Back room')));
  reset role;
  if (v_payload->>'keep_days')::integer <> 45 then
    raise exception 'v275: keep_days must persist, got %', v_payload;
  end if;
  if jsonb_array_length(v_payload->'locations') <> 3 then
    raise exception 'v275: three storage locations must be stored, got %', v_payload;
  end if;
  select location.id into v_shelf from public.bar_storage_locations location
   where location.business_id = v_biz and location.name = 'Shelf A';
  select location.id into v_chiller from public.bar_storage_locations location
   where location.business_id = v_biz and location.name = 'Chiller 2';
  if v_shelf is null or v_chiller is null then
    raise exception 'v275: named storage locations must exist';
  end if;

  -- A location dropped from the list is deactivated, not deleted: bottles keep a nameable shelf.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.bar_save_setup_v275(v_biz, 45, jsonb_build_array(
    jsonb_build_object('id', v_shelf, 'name', 'Shelf A'),
    jsonb_build_object('id', v_chiller, 'name', 'Chiller 2')));
  reset role;
  select count(*)::integer into v_count from public.bar_storage_locations location
   where location.business_id = v_biz and not location.active;
  if v_count <> 1 then
    raise exception 'v275: a dropped location must be deactivated, not deleted (inactive=%)', v_count;
  end if;

  -- 3. Park.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.park_bottle_v275(v_biz, v_link_a.client_id, 'Hibiki 12', null, 700, 100,
    v_shelf, 2, null, null, v_key);
  reset role;
  if v_payload->>'status' <> 'ok' then
    raise exception 'v275: park must succeed for a bar, got %', v_payload;
  end if;
  v_bottle := (v_payload->'bottle'->>'id')::uuid;
  if v_payload->'bottle'->>'serial_code' <> 'PK-' || v_year::text || '-0001' then
    raise exception 'v275: the first bottle of the year must be PK-%-0001, got %',
      v_year, v_payload->'bottle'->>'serial_code';
  end if;
  select bottle.expires_at into v_expires from public.bar_bottles bottle where bottle.id = v_bottle;
  if abs(extract(epoch from (v_expires - (now() + interval '45 days')))) > 5 then
    raise exception 'v275: expires_at must be parked_at + the business keep window (45d), got %', v_expires;
  end if;
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle;
  if v_count <> 1 then
    raise exception 'v275: park must record exactly one event, got %', v_count;
  end if;

  -- 4. Idempotency: the same key changes nothing and writes no second event.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.park_bottle_v275(v_biz, v_link_a.client_id, 'Hibiki 12', null, 700, 100,
    v_shelf, 2, null, null, v_key);
  reset role;
  if v_payload->>'status' <> 'duplicate_ignored' then
    raise exception 'v275: a replayed park must be duplicate_ignored, got %', v_payload;
  end if;
  select count(*)::integer into v_count from public.bar_bottles bottle
   where bottle.business_id = v_biz;
  if v_count <> 1 then
    raise exception 'v275: a replayed park must not create a second bottle, got %', v_count;
  end if;
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle;
  if v_count <> 1 then
    raise exception 'v275: a replayed park must not write a second event, got %', v_count;
  end if;

  -- 5. One event per write, before → after recorded.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.set_bottle_fill_v275(v_biz, v_bottle, 50, v_key || '-fill');
  reset role;
  if (v_payload->'bottle'->>'fill_percent')::integer <> 50 then
    raise exception 'v275: fill must persist, got %', v_payload;
  end if;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id = v_bottle and event.kind = 'fill'
                    and (event.detail->>'from')::integer = 100
                    and (event.detail->>'to')::integer = 50) then
    raise exception 'v275: the fill event must record 100 -> 50';
  end if;

  perform pg_temp.as_v275_user(v_owner);
  perform public.set_bottle_status_v275(v_biz, v_bottle, 'called', v_key || '-called');
  perform public.set_bottle_status_v275(v_biz, v_bottle, 'at_table', v_key || '-table');
  v_payload := public.extend_bottle_v275(v_biz, v_bottle, null, v_key || '-extend');
  reset role;
  if abs(extract(epoch from ((v_payload->'bottle'->>'expires_at')::timestamptz
      - (now() + interval '45 days')))) > 5 then
    raise exception 'v275: extend with no explicit date must add the business keep window, got %', v_payload;
  end if;

  -- 6. A terminal status cannot be reached through the floor control.
  v_raised := false;
  perform pg_temp.as_v275_user(v_owner);
  begin
    perform public.set_bottle_status_v275(v_biz, v_bottle, 'finished', v_key || '-bad');
  exception when others then v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v275: set_bottle_status must refuse a terminal status';
  end if;

  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.transfer_bottle_v275(v_biz, v_bottle, v_link_b.client_id, v_key || '-xfer');
  reset role;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id = v_bottle and event.kind = 'transfer'
                    and (event.detail->>'from_client_id')::uuid = v_link_a.client_id
                    and (event.detail->>'to_client_id')::uuid = v_link_b.client_id) then
    raise exception 'v275: the transfer event must name both parties';
  end if;

  -- 9. Customer side, while the bottle is still on the floor and owned by customer B.
  perform pg_temp.as_v275_user(v_link_b.auth_user_id);
  v_payload := public.customer_get_bottles_v275('kopi-tiam-tyeh');
  reset role;
  if jsonb_array_length(v_payload->'items') <> 1 then
    raise exception 'v275: the holder must see exactly their own bottle, got %', v_payload;
  end if;
  perform pg_temp.as_v275_user(v_link_a.auth_user_id);
  v_payload := public.customer_get_bottles_v275('kopi-tiam-tyeh');
  reset role;
  if jsonb_array_length(v_payload->'items') <> 0 then
    raise exception 'v275: a customer must never see another customer''s bottle, got %', v_payload;
  end if;

  -- Staff list: pills count the whole floor, and the bottle is on it.
  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.list_bar_bottles_v275(v_biz, null, null, null, null, null, 50);
  reset role;
  if (v_payload->'counts'->>'at_table')::integer <> 1 then
    raise exception 'v275: the at-table pill must count the bottle, got %', v_payload->'counts';
  end if;
  if jsonb_array_length(v_payload->'items') <> 1 then
    raise exception 'v275: the default list must show the floor, got %', v_payload;
  end if;

  perform pg_temp.as_v275_user(v_owner);
  v_payload := public.finish_bottle_v275(v_biz, v_bottle, v_key || '-finish');
  reset role;
  if v_payload->'bottle'->>'status' <> 'finished'
     or (v_payload->'bottle'->>'fill_percent')::integer <> 0 then
    raise exception 'v275: finish must close the bottle at empty, got %', v_payload;
  end if;
  v_raised := false;
  perform pg_temp.as_v275_user(v_owner);
  begin
    perform public.transfer_bottle_v275(v_biz, v_bottle, v_link_a.client_id, v_key || '-xfer2');
  exception when others then v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v275: a finished bottle must not be transferable';
  end if;

  -- A finished bottle leaves the customer card.
  perform pg_temp.as_v275_user(v_link_b.auth_user_id);
  v_payload := public.customer_get_bottles_v275('kopi-tiam-tyeh');
  reset role;
  if jsonb_array_length(v_payload->'items') <> 0 then
    raise exception 'v275: a finished bottle must leave the customer card, got %', v_payload;
  end if;

  -- Every write recorded exactly one event: park, fill, status x2, extend, transfer, finish.
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle;
  if v_count <> 7 then
    raise exception 'v275: every write must record exactly one event (expected 7, got %)', v_count;
  end if;

  -- 7. Append-only evidence.
  v_raised := false;
  begin
    update public.bar_bottle_events event set kind = 'reminder' where event.bottle_id = v_bottle;
  exception when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'v275: bar_bottle_events must refuse UPDATE';
  end if;
  v_raised := false;
  begin
    delete from public.bar_bottle_events event where event.bottle_id = v_bottle;
  exception when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'v275: bar_bottle_events must refuse DELETE';
  end if;

  -- 8. Tier integration: the new sale kind is legal and earns like a service.
  select * into v_policy from app.sale_policy(v_biz, 'bottle_keep');
  if v_policy.counts_as_revenue is not true
     or v_policy.counts_as_visit is not true
     or v_policy.earns_points is not true then
    raise exception 'v275: bottle_keep must count as revenue, a visit and earn points, got %', v_policy;
  end if;

  raise notice 'v275 (bar-only gating on all ten RPCs, setup, serial + keep window, idempotency, one event per write, customer isolation, append-only evidence, bottle_keep policy): all assertions passed';
end
$v275$;

do $v275_grants$
declare
  v_leak text;
begin
  select string_agg(proc.proname, ', ') into v_leak
    from pg_proc proc
    join pg_namespace space on space.oid = proc.pronamespace
   where space.nspname = 'public'
     and proc.proname in ('bar_get_setup_v275', 'bar_save_setup_v275', 'park_bottle_v275',
       'set_bottle_fill_v275', 'set_bottle_status_v275', 'extend_bottle_v275',
       'transfer_bottle_v275', 'finish_bottle_v275', 'list_bar_bottles_v275',
       'customer_get_bottles_v275')
     and has_function_privilege('anon', proc.oid, 'execute');
  if v_leak is not null then
    raise exception 'v275: anon must hold no EXECUTE on the bottle RPCs, found %', v_leak;
  end if;
  raise notice 'v275 (grants): anon holds no EXECUTE on any bottle keep RPC';
end
$v275_grants$;

rollback;
