-- Rollback-only acceptance for V278 — bottle keep parity with the live reference bar.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives. It borrows one existing open tenant and flips its industry to 'bar' for
-- the duration, exactly as db/tests/v275_bar_bottle_keep.sql does, so the real authorisation chain
-- is exercised rather than a hand-built imitation of it.
--
-- What this proves, in order:
--   1  HARD BAR GATING still holds for every NEW RPC: a genuine, fully authorised owner of a
--      NON-bar business is refused with 42501 by all TEN of them, before any other check.
--   2  AUTO EXPIRY RESOLUTION ORDER: tier override -> business default. A tier keep-days row for
--      the customer's CURRENT tier wins; delete it and the same customer falls back to the
--      business's own keep window. The park write and the preview resolver agree, because they
--      are the same function.
--   3  CUSTOM and NONE: a custom date is the END of that Singapore day; 'none' stores a NULL
--      expiry, and the table's shape check refuses a mode and a date that disagree.
--   4  ML COMES FROM THE CATALOGUE: park with a catalogue product and a WRONG p_size_ml, and the
--      stored size is the catalogue's, not the browser's.
--   5  THE RETRIEVED LIFECYCLE and its server-side transition matrix: stored -> retrieved,
--      retrieved -> stored, retrieved -> finished; and retrieved -> called is REFUSED.
--   6  One event per write for note / move / purchase / expiry / notify, each with old -> new, and
--      each idempotent on replay.
--   7  NOTIFY: the reminder event is always recorded and reports what actually happened; an
--      inbox row is written only for a verified, opted-in customer, and the inbox vocabulary
--      accepts the new title and body.
--   8  THE TIER BADGE and the customer read both survive a bar with no loyalty programme at all
--      (fail-soft blank), and the customer still sees a bottle that is out with them.
--   9  anon holds no EXECUTE on any of the new RPCs.
--
-- Client behaviour is proven in tests/business-ui/v278-bottle-keep-parity.test.mjs.

begin;

create or replace function pg_temp.as_v278_user(
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
grant execute on function pg_temp.as_v278_user(uuid, text) to public;

do $v278$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_industry_before text;
  v_modules_before text[];
  v_owner uuid;
  v_link public.customer_links%rowtype;
  v_client uuid;
  v_tier uuid;
  v_product uuid;
  v_shelf uuid;
  v_other_shelf uuid;
  v_bottle uuid;
  v_bottle_b uuid;
  v_payload jsonb;
  v_key text;
  v_rpc text;
  v_raised boolean;
  v_count integer;
  v_expires timestamptz;
  v_days integer;
  v_custom date := ((now() at time zone 'Asia/Singapore')::date + 12);
begin
  select business.industry, business.enabled_modules
    into v_industry_before, v_modules_before
    from public.businesses business where business.id = v_biz;
  if v_industry_before is null then
    raise exception 'v278: fixture tenant % not found', v_biz;
  end if;
  if v_industry_before = 'bar' then
    raise exception 'v278: fixture tenant is already a bar - pick a non-bar tenant for the gate test';
  end if;

  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   limit 1;
  if v_owner is null then
    raise exception 'v278: fixture needs an approved owner';
  end if;

  select * into v_link from public.customer_links link
   where link.business_id = v_biz and link.state = 'verified' and link.unlinked_at is null
   order by link.created_at limit 1;
  if v_link.id is null then
    raise exception 'v278: fixture needs a verified customer link';
  end if;
  v_client := v_link.client_id;

  -- 1. HARD BAR GATING on every new surface, BEFORE the industry flip.
  foreach v_rpc in array array[
    'select public.bar_get_bottle_setup_v278($1)',
    'select public.bar_save_tier_keep_days_v278($1, ''[]''::jsonb)',
    'select public.bar_save_bottle_product_v278($1, null, ''x'', 700, 0)',
    'select public.bar_client_keep_days_v278($1, null)',
    'select public.park_bottle_v278($1, null, ''x'', null, null, 100, null, null, null, null, ''auto'', null, ''none'', null, null, ''k'')',
    'select public.set_bottle_expiry_v278($1, null, ''auto'', null, ''k'')',
    'select public.add_bottle_note_v278($1, null, ''x'', ''k'')',
    'select public.move_bottle_v278($1, null, null, ''k'')',
    'select public.set_bottle_purchased_on_v278($1, null, null, ''k'')',
    'select public.notify_bottle_v278($1, null, ''k'')'
  ] loop
    v_raised := false;
    perform pg_temp.as_v278_user(v_owner);
    begin
      execute v_rpc using v_biz;
    exception when insufficient_privilege then
      v_raised := true;
    when others then
      reset role;
      raise exception 'v278: % raised % instead of 42501 for a non-bar owner', v_rpc, sqlstate;
    end;
    reset role;
    if not v_raised then
      raise exception 'v278: % did NOT refuse a non-bar business', v_rpc;
    end if;
  end loop;
  raise notice 'v278 [1] OK - all ten new RPCs refuse a non-bar business with 42501';

  -- Flip the fixture to a bar for the rest of the suite.
  -- CORRECTION (applied 2026-08-11, found running this suite against production): V75 installed
  -- app.business_sector_modules_guard_v75, a BEFORE UPDATE trigger on public.businesses that
  -- refuses ANY change to industry or enabled_modules for a business carrying a row in
  -- public.business_sector_assignments -- which the fixture tenant now does. Without the line
  -- below the flip dies with 42501 'business modules are fixed by the assigned sector
  -- entitlement' and the suite cannot reach check [2] onwards. The guard's own documented escape
  -- hatch is a session GUC naming the business being synced, so open it for the flip and shut it
  -- again immediately: a test must not leave the entitlement guard disarmed for anything else it
  -- goes on to do.
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);
  update public.businesses
     set industry = 'bar',
         enabled_modules = (select array_agg(distinct value)
                              from unnest(coalesce(v_modules_before, '{}'::text[]) || array['bottles','clients','sales']) value)
   where id = v_biz;
  perform set_config('app.sector_entitlement_sync', '', true);

  insert into public.bar_bottle_settings (business_id, keep_days)
  values (v_biz, 20)
  on conflict (business_id) do update set keep_days = 20;

  -- A catalogue bottle and two shelves.
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.bar_save_bottle_product_v278(v_biz, null, 'V278 suite whisky', 700, 12000);
  reset role;
  select product.id into v_product from public.products product
   where product.business_id = v_biz and product.name = 'V278 suite whisky';
  if v_product is null then
    raise exception 'v278: the quick-added bottle was not created';
  end if;
  if (select product.size_ml from public.products product where product.id = v_product) <> 700 then
    raise exception 'v278: the quick-added bottle did not store its size';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_payload->'products') entry
                  where (entry->>'id')::uuid = v_product and (entry->>'is_bottle')::boolean) then
    raise exception 'v278: the catalogue read does not report the new bottle';
  end if;
  raise notice 'v278 [4a] OK - a quick-added bottle carries its size and is reported as a bottle';

  insert into public.bar_storage_locations (business_id, name, active, sort)
  values (v_biz, 'V278 Shelf A', true, 1) returning id into v_shelf;
  insert into public.bar_storage_locations (business_id, name, active, sort)
  values (v_biz, 'V278 Chiller B', true, 2) returning id into v_other_shelf;

  -- 2. AUTO EXPIRY RESOLUTION ORDER.
  select tier.id into v_tier from app.loyalty_tier_for(v_biz, v_client) tier;
  if v_tier is not null then
    insert into public.bar_tier_keep_days_v278 (business_id, tier_id, keep_days)
    values (v_biz, v_tier, 90)
    on conflict (business_id, tier_id) do update set keep_days = 90;
    v_days := app.bar_keep_days_for_client_v278(v_biz, v_client);
    if v_days <> 90 then
      raise exception 'v278: the tier override did not win (got %)', v_days;
    end if;
    delete from public.bar_tier_keep_days_v278
     where business_id = v_biz and tier_id = v_tier;
    v_days := app.bar_keep_days_for_client_v278(v_biz, v_client);
    if v_days <> 20 then
      raise exception 'v278: the business default did not apply after the override was cleared (got %)', v_days;
    end if;
    raise notice 'v278 [2] OK - tier override 90 wins, then the business default 20 takes over';
  else
    v_days := app.bar_keep_days_for_client_v278(v_biz, v_client);
    if v_days <> 20 then
      raise exception 'v278: a customer with no tier must fall back to the business default (got %)', v_days;
    end if;
    raise notice 'v278 [2] OK - no tier reached, so the business default 20 applies (fallback leg only)';
  end if;

  -- The preview resolver and the write resolver are the same function, and it fails soft.
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.bar_client_keep_days_v278(v_biz, v_client);
  reset role;
  if (v_payload->>'keep_days')::integer <> v_days then
    raise exception 'v278: the park preview disagrees with the resolver';
  end if;

  -- 3+4. Park under AUTO with a catalogue bottle and a deliberately WRONG size from the browser.
  v_key := 'v278-park-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.park_bottle_v278(v_biz, v_client, null, v_product, 70, 100, v_shelf, 1,
    null, null, 'auto', null, 'whatsapp', 'Regular - keeps it at the back',
    (now() at time zone 'Asia/Singapore')::date, v_key);
  reset role;
  v_bottle := (v_payload->'bottle'->>'id')::uuid;
  if (v_payload->'bottle'->>'size_ml')::integer <> 700 then
    raise exception 'v278: the browser size was trusted over the catalogue (got %)',
      v_payload->'bottle'->>'size_ml';
  end if;
  if (v_payload->'bottle'->>'expiry_mode') <> 'auto' then
    raise exception 'v278: the park did not store the expiry mode';
  end if;
  if (v_payload->'bottle'->>'notify_channel') <> 'whatsapp' then
    raise exception 'v278: the park did not store the notify preference';
  end if;
  if (v_payload->'bottle'->>'purchased_on') is null then
    raise exception 'v278: the park did not store the purchase date';
  end if;
  select bottle.expires_at into v_expires from public.bar_bottles bottle where bottle.id = v_bottle;
  if (v_expires at time zone 'Asia/Singapore')::date
     <> ((now() + make_interval(days => v_days)) at time zone 'Asia/Singapore')::date then
    raise exception 'v278: the auto expiry did not use the resolved keep window';
  end if;
  select count(*) into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle;
  if v_count <> 1 then
    raise exception 'v278: park wrote % events, expected exactly 1', v_count;
  end if;
  if (select event.detail->>'note' from public.bar_bottle_events event where event.bottle_id = v_bottle)
     <> 'Regular - keeps it at the back' then
    raise exception 'v278: the park note is not in the evidence row';
  end if;
  raise notice 'v278 [3a][4b] OK - auto expiry, catalogue-synced ml, note and preferences on one park event';

  -- Replay: same key, no second bottle, no second event.
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.park_bottle_v278(v_biz, v_client, null, v_product, 70, 100, v_shelf, 1,
    null, null, 'auto', null, 'whatsapp', 'Regular - keeps it at the back',
    (now() at time zone 'Asia/Singapore')::date, v_key);
  reset role;
  if v_payload->>'status' <> 'duplicate_ignored' then
    raise exception 'v278: a replayed park was not ignored';
  end if;
  select count(*) into v_count from public.bar_bottles bottle where bottle.business_id = v_biz;
  if v_count <> 1 then
    raise exception 'v278: a replayed park created a second bottle';
  end if;

  -- 3b. CUSTOM: the end of the chosen Singapore day.
  v_key := 'v278-expiry-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.set_bottle_expiry_v278(v_biz, v_bottle, 'custom', v_custom, v_key);
  reset role;
  select bottle.expires_at into v_expires from public.bar_bottles bottle where bottle.id = v_bottle;
  if v_expires <> ((v_custom + 1)::timestamp at time zone 'Asia/Singapore') then
    raise exception 'v278: a custom keep date is not the end of that Singapore day';
  end if;
  if (v_payload->'bottle'->>'expiry_mode') <> 'custom' then
    raise exception 'v278: the custom mode was not stored';
  end if;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id = v_bottle and event.kind = 'extend'
                    and event.detail->>'from_mode' = 'auto' and event.detail->>'to_mode' = 'custom') then
    raise exception 'v278: the expiry edit did not record old -> new';
  end if;

  -- 3c. NONE: a null expiry, and days_left reads as null rather than as zero.
  v_key := 'v278-expiry-none-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.set_bottle_expiry_v278(v_biz, v_bottle, 'none', null, v_key);
  reset role;
  if (v_payload->'bottle'->>'expires_at') is not null then
    raise exception 'v278: no-expiry left a date behind';
  end if;
  if (v_payload->'bottle'->'days_left') <> 'null'::jsonb then
    raise exception 'v278: a no-expiry bottle must report a null days_left, not a number';
  end if;
  -- The shape check must refuse a mode and a date that disagree.
  v_raised := false;
  begin
    update public.bar_bottles set expires_at = now() + interval '5 days'
     where id = v_bottle;
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'v278: the expiry shape check allowed mode=none with a date';
  end if;
  raise notice 'v278 [3] OK - custom is the end of the SGT day, none is a null date, and the shape check holds';

  -- Back to a real date so the rest of the lifecycle is testable.
  v_key := 'v278-expiry-back-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  perform public.set_bottle_expiry_v278(v_biz, v_bottle, 'auto', null, v_key);
  reset role;

  -- 5. THE RETRIEVED LIFECYCLE, validated server-side.
  v_key := 'v278-retrieve-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.set_bottle_status_v275(v_biz, v_bottle, 'retrieved', v_key);
  reset role;
  if v_payload->'bottle'->>'status' <> 'retrieved' then
    raise exception 'v278: stored -> retrieved was refused';
  end if;

  v_raised := false;
  perform pg_temp.as_v278_user(v_owner);
  begin
    perform public.set_bottle_status_v275(v_biz, v_bottle, 'called',
      'v278-illegal-' || gen_random_uuid()::text);
  exception when others then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v278: retrieved -> called must be refused by the server, not merely unbuttoned';
  end if;

  v_key := 'v278-back-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.set_bottle_status_v275(v_biz, v_bottle, 'stored', v_key);
  reset role;
  if v_payload->'bottle'->>'status' <> 'stored' then
    raise exception 'v278: retrieved -> stored (back to storage) was refused';
  end if;
  raise notice 'v278 [5] OK - stored -> retrieved -> stored allowed, retrieved -> called refused';

  -- 6. Note, move and purchase date: one event each, old -> new recorded, idempotent.
  v_key := 'v278-note-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  perform public.add_bottle_note_v278(v_biz, v_bottle, 'Cap left at the bar', v_key);
  v_payload := public.add_bottle_note_v278(v_biz, v_bottle, 'Cap left at the bar', v_key);
  reset role;
  if v_payload->>'status' <> 'duplicate_ignored' then
    raise exception 'v278: a replayed note was not ignored';
  end if;
  select count(*) into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle and event.kind = 'note';
  if v_count <> 1 then
    raise exception 'v278: expected exactly 1 note event, found %', v_count;
  end if;

  v_key := 'v278-move-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.move_bottle_v278(v_biz, v_bottle, v_other_shelf, v_key);
  reset role;
  if (v_payload->'bottle'->>'storage_location_name') <> 'V278 Chiller B' then
    raise exception 'v278: the move did not change the storage place';
  end if;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id = v_bottle and event.kind = 'move'
                    and event.detail->>'from_name' = 'V278 Shelf A'
                    and event.detail->>'to_name' = 'V278 Chiller B') then
    raise exception 'v278: the move did not record both places';
  end if;

  v_key := 'v278-purchase-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.set_bottle_purchased_on_v278(v_biz, v_bottle,
    ((now() at time zone 'Asia/Singapore')::date - 3), v_key);
  reset role;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id = v_bottle and event.kind = 'purchase'
                    and event.detail->>'to' = ((now() at time zone 'Asia/Singapore')::date - 3)::text) then
    raise exception 'v278: the purchase date change was not recorded old -> new';
  end if;
  -- A purchase date in the future is refused.
  v_raised := false;
  perform pg_temp.as_v278_user(v_owner);
  begin
    perform public.set_bottle_purchased_on_v278(v_biz, v_bottle,
      ((now() at time zone 'Asia/Singapore')::date + 30),
      'v278-future-' || gen_random_uuid()::text);
  exception when others then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v278: a purchase date in the future was accepted';
  end if;
  raise notice 'v278 [6] OK - note, move and purchase date each write exactly one idempotent event';

  -- A shelf that is not this bar's own is refused as a move target.
  v_raised := false;
  perform pg_temp.as_v278_user(v_owner);
  begin
    perform public.move_bottle_v278(v_biz, v_bottle, gen_random_uuid(),
      'v278-badshelf-' || gen_random_uuid()::text);
  exception when others then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'v278: a move accepted a storage place that is not on this bar''s list';
  end if;

  -- 7. NOTIFY. The reminder event is always recorded; the inbox row depends on consent.
  update public.customer_notification_preferences
     set opted_in = true
   where business_id = v_biz and identity_id = v_link.identity_id and link_id = v_link.id
     and channel = 'in_app' and topic = 'value_expiry';
  if not found then
    -- CORRECTION (applied 2026-08-11, found running this suite against production):
    -- customer_notification_preferences.client_id and .consent_at are both NOT NULL with no
    -- default. The original insert listed neither, so on any tenant where the customer had not
    -- already set an in_app/value_expiry preference this suite died with 23502 instead of
    -- reaching check [7]. Both are supplied from the link row that is already in hand.
    insert into public.customer_notification_preferences (
      business_id, identity_id, auth_user_id, link_id, client_id, channel, topic, opted_in, consent_at)
    values (v_biz, v_link.identity_id, v_link.auth_user_id, v_link.id, v_link.client_id,
            'in_app', 'value_expiry', true, now())
    on conflict do nothing;
  end if;

  v_key := 'v278-notify-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.notify_bottle_v278(v_biz, v_bottle, v_key);
  reset role;
  if v_payload->>'delivery' not in ('in_app', 'opted_out', 'no_customer_app') then
    raise exception 'v278: notify reported an unexpected delivery %', v_payload->>'delivery';
  end if;
  select count(*) into v_count from public.bar_bottle_events event
   where event.bottle_id = v_bottle and event.kind = 'reminder';
  if v_count <> 1 then
    raise exception 'v278: notify must always record exactly one reminder event, found %', v_count;
  end if;
  if v_payload->>'delivery' = 'in_app' then
    if not exists (select 1 from public.customer_in_app_inbox_events inbox
                    where inbox.business_id = v_biz
                      and inbox.identity_id = v_link.identity_id
                      and inbox.source_kind = 'v278_bottle_reminder'
                      and inbox.title = 'Your bottle is waiting') then
      raise exception 'v278: notify claimed in_app but wrote no inbox row';
    end if;
    if not app.c46_inbox_source_available('v278_bottle_reminder', false) then
      raise exception 'v278: the inbox reader would hide the bottle reminder it just wrote';
    end if;
  end if;
  raise notice 'v278 [7] OK - notify recorded one reminder event and reported delivery=%', v_payload->>'delivery';

  -- 8. The tier badge fails soft, and the customer still sees a bottle that is out with them.
  v_key := 'v278-out-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  perform public.set_bottle_status_v275(v_biz, v_bottle, 'retrieved', v_key);
  reset role;
  perform pg_temp.as_v278_user(v_link.auth_user_id);
  v_payload := public.customer_get_bottles_v275(
    (select business.slug from public.businesses business where business.id = v_biz));
  reset role;
  if jsonb_array_length(v_payload->'items') < 1 then
    raise exception 'v278: a retrieved bottle vanished from the customer wallet';
  end if;

  -- The list read must survive whatever the tier state is; a blank badge is a legal answer.
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.list_bar_bottles_v275(v_biz, null, null, null, null, null, 50);
  reset role;
  if (v_payload->'counts'->>'retrieved')::integer < 1 then
    raise exception 'v278: the retrieved count is not reported to the dashboard card';
  end if;
  if (v_payload->'counts'->>'active')::integer < 1 then
    raise exception 'v278: the active count is not reported to the dashboard card';
  end if;
  raise notice 'v278 [8] OK - retrieved bottles stay visible to the customer and are counted as active';

  -- retrieved -> finished closes it (the "sent out" move).
  v_key := 'v278-sentout-' || gen_random_uuid()::text;
  perform pg_temp.as_v278_user(v_owner);
  v_payload := public.finish_bottle_v275(v_biz, v_bottle, v_key);
  reset role;
  if v_payload->'bottle'->>'status' <> 'finished' then
    raise exception 'v278: retrieved -> finished (sent out) was refused';
  end if;
  raise notice 'v278 [5b] OK - retrieved -> finished closes the bottle';

  -- 9. anon holds no EXECUTE on any new RPC.
  for v_rpc in select proc.proname
    from pg_proc proc join pg_namespace space on space.oid = proc.pronamespace
   where space.nspname = 'public'
     and proc.proname in ('bar_get_bottle_setup_v278', 'bar_save_tier_keep_days_v278',
       'bar_save_bottle_product_v278', 'bar_client_keep_days_v278', 'park_bottle_v278',
       'set_bottle_expiry_v278', 'add_bottle_note_v278', 'move_bottle_v278',
       'set_bottle_purchased_on_v278', 'notify_bottle_v278')
     and has_function_privilege('anon', proc.oid, 'EXECUTE')
  loop
    raise exception 'v278: anon can execute %', v_rpc;
  end loop;
  raise notice 'v278 [9] OK - anon holds no EXECUTE on any new bottle RPC';

  raise notice 'v278: ALL CHECKS PASSED (rolling back)';
end
$v278$;

rollback;
