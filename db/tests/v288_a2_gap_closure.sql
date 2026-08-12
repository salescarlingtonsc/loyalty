-- Rollback-only acceptance for V288 — audit A2 gap closure.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives.
--
-- ============================================================================================
-- CORRECTION (2026-08-12, first execution against production). This suite had never been run.
-- Three of its premises did not survive contact with the deployed database, and the file has been
-- rewritten to verify the DEPLOYED state rather than the state its author assumed (v285 precedent).
--
--   C1  THE FIXTURE FLIP WAS IMPOSSIBLE. The original borrowed a tenant and set
--       industry='bar' + enabled_modules WITHOUT 'appointments'. It cannot work:
--       trg_business_modules_dependency_guard runs app.resolve_module_dependencies() on every
--       write of enabled_modules, and that function force-adds 'appointments' AND 'services'
--       whenever 'bookings' is present. Verified against prod: EVERY tenant, including the one
--       real industry='bar' tenant and all five industry='fnb' tenants, carries 'appointments'.
--       There is therefore no such thing as a bookings-without-appointments business expressed
--       through enabled_modules. This suite now uses the REAL bar tenant, and makes appointments
--       genuinely absent the only way the platform supports — a platform_module_overrides_v94
--       firm override of mode='disabled'.
--
--   C2  THE PREMISE BEHIND HIGH 1 DOES NOT HOLD IN PRODUCTION, AND V288 DOES NOT CLOSE IT.
--       Because of C1 the real bar tenant HAS appointments entitled, so
--       app.business_has_appointments_module_v288 returns TRUE for it and V288's new condition
--       never skips anything — the change is behaviour-preserving, not gap-closing.
--       And when appointments IS genuinely absent, confirm STILL fails 42501: the confirm path
--       calls public.book_appointment_smart_v47, whose own wrapper unconditionally demands
--       require_branch_module_v94(...,'appointments','rw'). Section 8 pinned that as the deployed
--       truth. SUPERSEDED by V290, which makes that gate conditional too; section 8 is now a
--       positive assertion and this suite therefore requires V290 to be applied.
--
--   C3  MEDIUM 15 WAS ALREADY CLOSED BY V285. The original asserted that
--       bar_save_bottle_product_v278 DROPS name and price on update. The deployed v278 does not:
--       nestly_v285_a4_gap_closure (applied 2026-08-12 03:40, ~1h before v288) had already
--       rewritten its update branch to the same coalesce form. bar_save_bottle_product_v288 is
--       therefore a behavioural duplicate of the deployed v278. Section 6 now asserts what v288
--       actually does, and records that v278 does the same.
--
--   C5  SECTION 8 REUSED SECTION 2's SLOT (found 2026-08-12 when §8 was first run against a
--       database with V290 applied). §2 confirms an appointment at v_start; §8 confirming at the
--       SAME time takes book_appointment_smart_v47's staff-conflict branch, which calls
--       public.suggest_appointment_staff_v47 — a SEPARATE 'appointments','r' gate outside V290's
--       scope. §8 now uses its own free slot, v_start8.
--
--   C6  staff_decide_booking_request_v73 returns outcome / actual_status / appointment_id, never a
--       'status' key, so §8's assertion could not have passed even with the gate closed.
--
--   C4  SCAFFOLDING. The real bar tenant has NO branch_hours and NO staff_hours rows, so
--       app.staff_free_for_appointment_v47 refuses every slot and confirm returns
--       'scheduling_conflict' for reasons unrelated to authorisation. Both are seeded here (and
--       rolled back) so the authorisation path is what is being measured. This is itself a live
--       finding: that tenant cannot confirm any booking today.
--       platform_module_overrides_v94.reason is NOT NULL and must be supplied.
-- ============================================================================================
--
-- What this proves, in order:
--   1  HARD BAR GATING comes FIRST on both new bottle RPCs: a genuine, fully authorised owner of
--      a NON-bar business is refused with 42501 before any other check runs.
--   2  A SEATED SECTOR CONFIRMS ITS OWN BOOKINGS end to end, and decline still works.
--   3  THE APPOINTMENTS BOUNDARY IS NOT LOST WHERE THE SECTOR HAS ONE — including where the
--      platform grants it READ-ONLY, which must still refuse a confirm with 42501.
--   4  REMOVE IS THE MIS-PARK EXIT: one write, one 'status' evidence row naming the actor and the
--      from/to, replay is duplicate_ignored, 'removed' is terminal in both directions, and an
--      EXPIRED bottle may be removed without mis-recording a retrieval.
--   5  AN EXPIRED BOTTLE IS REVIVABLE by extend_bottle_v275.
--   6  THE CATALOGUE ROW CAN BE CORRECTED by v288 (name+size+price, null means unchanged), and
--      v278 remains deployed and callable for the Add path.
--   7  anon and PUBLIC hold no EXECUTE on either new RPC; authenticated holds both; the app-schema
--      helper is exposed to nobody.
--   8  CLOSED BY V290 (was the C2 KNOWN OPEN): with appointments genuinely absent, confirm now
--      SUCCEEDS. 20260812_nestly_v290_server_debt_closure made the residual
--      book_appointment_smart_v47 gates conditional and put the bookings boundary in their place.
--
-- Runner note: this is ONE statement so it can be executed through a single-statement client. It
-- ends in `raise exception 'V288_RESULT ALL PASS -- %'`, which rolls the whole thing back.

begin;

do $v288$
declare
  v_log text := '';
  v_bar uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';    -- Bistro 999, REAL industry='bar'
  v_nonbar uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa'; -- Cubbly,     REAL industry='facial'
  v_salon uuid;
  v_owner uuid; v_nbowner uuid; v_sowner uuid;
  v_staff uuid; v_branch uuid; v_sbranch uuid;
  v_client uuid; v_shelf uuid;
  v_bottle uuid; v_expired uuid; v_product uuid;
  v_request uuid; v_appointment uuid;
  v_payload jsonb; v_replay jsonb; v_detail jsonb;
  v_key text; v_rpc text; v_state text; v_msg text;
  v_raised boolean; v_has boolean; v_write boolean;
  v_count integer; v_before integer; v_auth integer; v_anon integer;
  v_name text; v_price integer; v_size integer;
  v_start timestamptz; v_start8 timestamptz; v_dow smallint;
begin
  -- CORRECTION (scaffolding): the original declared pg_temp.as_v288_user as a top-level statement
  -- in a begin/rollback script. This runner is one statement, so it is created inline.
  execute $ddl$
    create or replace function pg_temp.as_v288_user(p_uid uuid, p_role text default 'authenticated')
    returns void language plpgsql as $f$
    begin
      reset role;
      execute format('set local role %I', p_role);
      perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
      perform set_config('request.jwt.claims',
        json_build_object('sub',p_uid,'role',p_role)::text, true);
    end $f$
  $ddl$;
  execute 'grant execute on function pg_temp.as_v288_user(uuid, text) to public';

  -- ---- fixture discovery -------------------------------------------------------------------
  select business.industry into v_name from public.businesses business where business.id = v_bar;
  if v_name <> 'bar' then
    raise exception 'v288: fixture % must really be industry=bar (got %)', v_bar, v_name;
  end if;
  select business.industry into v_name from public.businesses business where business.id = v_nonbar;
  if v_name = 'bar' then
    raise exception 'v288: the gate fixture % must NOT be a bar', v_nonbar;
  end if;

  select staff_row.id, staff_row.user_id into v_staff, v_owner
    from public.staff staff_row
   where staff_row.business_id = v_bar and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved' limit 1;
  select staff_row.user_id into v_nbowner
    from public.staff staff_row
   where staff_row.business_id = v_nonbar and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved' limit 1;
  select client.id into v_client from public.clients client
   where client.business_id = v_bar order by client.created_at limit 1;
  select branch.id into v_branch from public.branches branch
   where branch.business_id = v_bar and branch.active
   order by branch.is_default desc, branch.created_at, branch.id limit 1;
  if v_owner is null or v_nbowner is null or v_client is null or v_branch is null then
    raise exception 'v288: fixtures incomplete (owner %, nonbar owner %, client %, branch %)',
      v_owner, v_nbowner, v_client, v_branch;
  end if;

  -- ---- 1. hard bar gating, before anything else ---------------------------------------------
  foreach v_rpc in array array[
    'select public.remove_bottle_v288($1, gen_random_uuid(), ''v288-gate'')',
    'select public.bar_save_bottle_product_v288($1, null, ''Gate probe'', 700, 1000)'
  ] loop
    v_raised := false;
    perform pg_temp.as_v288_user(v_nbowner);
    begin
      execute v_rpc using v_nonbar;
    exception when insufficient_privilege then v_raised := true;
    when others then
      reset role;
      raise exception 'v288: % raised % (%) instead of 42501 for a non-bar owner',
        v_rpc, sqlstate, sqlerrm;
    end;
    reset role;
    if not v_raised then
      raise exception 'v288: % did NOT refuse a non-bar business', v_rpc;
    end if;
  end loop;
  v_log := v_log || ' [1 non-bar owner refused 42501 on both new RPCs]';

  -- ---- 2. a seated sector confirms its own bookings ------------------------------------------
  -- CORRECTION C4: seed the rota this tenant does not have, or the scheduler refuses every slot.
  v_start := date_trunc('hour', now() at time zone 'Asia/Singapore' + interval '2 days')
             at time zone 'Asia/Singapore' + interval '1 hour';
  -- CORRECTION C5 (2026-08-12): section 8 must NOT reuse this slot. Section 2 confirms a real
  -- appointment at v_start for the only staff member this tenant has; a second confirm at the SAME
  -- time takes book_appointment_smart_v47's staff-conflict branch, which calls
  -- public.suggest_appointment_staff_v47 — a SEPARATE require_branch_module_v94(...,'appointments',
  -- 'r') gate that V290 neither touches nor claims to. Without this, section 8 fails
  -- 'branch_module_access_required:appointments:r' and misreports a closed gap as still open.
  v_start8 := v_start + interval '4 hours';
  v_dow := extract(dow from (v_start at time zone 'Asia/Singapore'))::smallint;
  if not exists (select 1 from public.branch_hours hours
                  where hours.business_id=v_bar and hours.branch_id=v_branch and hours.weekday=v_dow) then
    insert into public.branch_hours (business_id,branch_id,weekday,opens_at,closes_at)
    values (v_bar,v_branch,v_dow,'00:00','23:59');
  end if;
  if not exists (select 1 from public.staff_hours hours
                  where hours.business_id=v_bar and hours.staff_id=v_staff and hours.weekday=v_dow) then
    insert into public.staff_hours (business_id,staff_id,weekday,starts_at,ends_at)
    values (v_bar,v_staff,v_dow,'00:00','23:59');
  end if;

  -- CORRECTION C2: record what the helper actually says about a REAL bar tenant.
  v_has := app.business_has_appointments_module_v288(v_bar, v_branch);
  perform pg_temp.as_v288_user(v_owner);
  v_write := app.can_module_write(v_bar,'appointments');
  reset role;
  if not v_has or not v_write then
    raise exception 'v288: expected the real bar tenant to CARRY appointments (helper %, write %) - see C1',
      v_has, v_write;
  end if;

  insert into public.booking_requests (business_id, name, phone, status, preferred_at)
  values (v_bar, 'V288 confirm probe', '81000288', 'new', v_start)
  returning id into v_request;
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.staff_decide_booking_request_v73(v_bar, v_request, 'confirm', null);
  reset role;
  v_appointment := nullif(v_payload->>'appointment_id','')::uuid;
  select count(*) into v_count from public.appointments appointment
   where appointment.id = v_appointment and appointment.business_id = v_bar;
  if coalesce(v_payload->>'outcome','') <> 'applied' or v_appointment is null or v_count <> 1 then
    raise exception 'v288: the bar owner could not confirm (payload %)', v_payload::text;
  end if;

  insert into public.booking_requests (business_id, name, phone, status, preferred_at)
  values (v_bar, 'V288 decline probe', '81000289', 'new', v_start)
  returning id into v_request;
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.staff_decide_booking_request_v73(v_bar, v_request, 'decline', null);
  reset role;
  if coalesce(v_payload->>'outcome','') <> 'applied'
     or coalesce(v_payload->>'actual_status','') <> 'declined' then
    raise exception 'v288: decline regressed (payload %)', v_payload::text;
  end if;
  v_log := v_log || format(' [2 real bar tenant: confirm applied appt=%s, decline applied; helper_has_appts=t]',
    v_appointment);

  -- ---- 3. the boundary still bites where the sector has appointments -------------------------
  select business.id into v_salon from public.businesses business where business.industry='salon' limit 1;
  select staff_row.user_id into v_sowner from public.staff staff_row
   where staff_row.business_id=v_salon and staff_row.role='owner'
     and staff_row.active and staff_row.access_state='approved' limit 1;
  select branch.id into v_sbranch from public.branches branch
   where branch.business_id=v_salon and branch.active
   order by branch.is_default desc, branch.created_at, branch.id limit 1;
  -- CORRECTION C4: reason is NOT NULL.
  insert into public.platform_module_overrides_v94 (business_id,branch_scope,module_key,mode,reason)
  values (v_salon,null,'appointments','r','v288 rolled-back boundary probe');
  v_has := app.business_has_appointments_module_v288(v_salon, v_sbranch);
  insert into public.booking_requests (business_id,name,phone,status,preferred_at)
  values (v_salon,'V288 salon boundary','81000290','new', now()+interval '2 days')
  returning id into v_request;
  v_raised := false;
  perform pg_temp.as_v288_user(v_sowner);
  begin
    perform public.staff_decide_booking_request_v73(v_salon, v_request, 'confirm', null);
  exception when others then v_raised := true; v_state := sqlstate;
  end;
  reset role;
  if not v_has or not v_raised or v_state <> '42501' then
    raise exception 'v288: read-only appointments must still refuse confirm (has %, raised %, state %)',
      v_has, v_raised, v_state;
  end if;
  v_log := v_log || ' [3 salon with appointments=read-only still refuses confirm 42501]';

  -- ---- 4. remove is the mis-park exit --------------------------------------------------------
  insert into public.bar_storage_locations (business_id,name,active,sort)
  values (v_bar,'V288 Shelf',true,1) returning id into v_shelf;

  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.park_bottles_v279(v_bar, v_client, 'Hennessy VSOP mis-tag', null, 700, 100,
    v_shelf, null, null, 'auto', null, 'none', null, null, 1, 'v288-park-'||gen_random_uuid()::text);
  reset role;
  v_bottle := (v_payload->'bottle'->>'id')::uuid;
  if v_bottle is null then raise exception 'v288: the probe bottle was not parked'; end if;

  select count(*) into v_before from public.bar_bottle_events event where event.bottle_id=v_bottle;
  v_key := 'v288-remove-'||gen_random_uuid()::text;
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.remove_bottle_v288(v_bar, v_bottle, v_key);
  v_replay := public.remove_bottle_v288(v_bar, v_bottle, v_key);
  reset role;
  select count(*) into v_count from public.bar_bottle_events event where event.bottle_id=v_bottle;
  select event.detail into v_detail from public.bar_bottle_events event
   where event.bottle_id=v_bottle and event.kind='status' and event.detail->>'to'='removed';
  if coalesce(v_payload->'bottle'->>'status','') <> 'removed' then
    raise exception 'v288: remove must leave status removed (got %)', v_payload->'bottle'->>'status';
  end if;
  if coalesce(v_replay->>'status','') <> 'duplicate_ignored' then
    raise exception 'v288: a replayed key must be duplicate_ignored (got %)', v_replay->>'status';
  end if;
  if v_count <> v_before+1 then
    raise exception 'v288: remove must write exactly ONE evidence row (% -> %)', v_before, v_count;
  end if;
  if coalesce(v_detail->>'from','') <> 'stored' then
    raise exception 'v288: the evidence row must name the state it left (got %)', v_detail::text;
  end if;
  if not exists (select 1 from public.bar_bottle_events event
                  where event.bottle_id=v_bottle and event.detail->>'to'='removed'
                    and event.actor=v_owner) then
    raise exception 'v288: the evidence row must name the actor';
  end if;
  if exists (select 1 from public.bar_bottle_events event
              where event.bottle_id=v_bottle and event.detail->>'to'='retrieved') then
    raise exception 'v288: removing must NOT record a retrieval';
  end if;

  v_raised := false;
  perform pg_temp.as_v288_user(v_owner);
  begin perform public.remove_bottle_v288(v_bar, v_bottle, 'v288-again-'||gen_random_uuid()::text);
  exception when others then v_raised := true; end;
  reset role;
  if not v_raised then raise exception 'v288: an already-removed bottle must not be removed twice'; end if;
  v_raised := false;
  perform pg_temp.as_v288_user(v_owner);
  begin perform public.set_bottle_status_v275(v_bar, v_bottle, 'stored', 'v288-out-'||gen_random_uuid()::text);
  exception when others then v_raised := true; end;
  reset role;
  if not v_raised then raise exception 'v288: removed must be terminal - no transitions out'; end if;
  v_log := v_log || ' [4a stored->removed: one actor-named event, replay ignored, terminal both ways]';

  -- expired -> removed, and expired -> stored via extend
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.park_bottles_v279(v_bar, v_client, 'Macallan expired probe', null, 700, 100,
    v_shelf, null, null, 'auto', null, 'none', null, null, 1, 'v288-park-b-'||gen_random_uuid()::text);
  reset role;
  v_expired := (v_payload->'bottle'->>'id')::uuid;
  update public.bar_bottles bottle
     set status='expired', expires_at=now()-interval '1 day' where bottle.id=v_expired;

  -- ---- 5. an expired bottle is revivable -----------------------------------------------------
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.extend_bottle_v275(v_bar, v_expired, null, 'v288-extend-'||gen_random_uuid()::text);
  reset role;
  if coalesce(v_payload->'bottle'->>'status','') <> 'stored' then
    raise exception 'v288: extend must revive an expired bottle to stored (got %)',
      v_payload->'bottle'->>'status';
  end if;
  v_log := v_log || ' [5 expired revived to stored by extend]';

  update public.bar_bottles bottle set status='expired' where bottle.id=v_expired;
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.remove_bottle_v288(v_bar, v_expired, 'v288-rmexp-'||gen_random_uuid()::text);
  reset role;
  if coalesce(v_payload->'bottle'->>'status','') <> 'removed' then
    raise exception 'v288: an expired bottle must be removable (got %)', v_payload->'bottle'->>'status';
  end if;
  v_log := v_log || ' [4b expired bottle removed without a fake retrieval]';

  -- ---- 6. the catalogue row can be corrected -------------------------------------------------
  insert into public.products (business_id,name,retail_price_cents,size_ml,active)
  values (v_bar,'Chivas 12 (typo)',12000,700,true) returning id into v_product;

  perform pg_temp.as_v288_user(v_owner);
  perform public.bar_save_bottle_product_v288(v_bar, v_product, 'Chivas Regal 12', 750, 13500);
  reset role;
  select product.name, product.retail_price_cents, product.size_ml
    into v_name, v_price, v_size from public.products product where product.id=v_product;
  if v_name <> 'Chivas Regal 12' or v_price <> 13500 or v_size <> 750 then
    raise exception 'v288: v288 must apply name, price AND size (got %, %, %)', v_name, v_price, v_size;
  end if;
  perform pg_temp.as_v288_user(v_owner);
  perform public.bar_save_bottle_product_v288(v_bar, v_product, null, 1000, null);
  reset role;
  select product.name, product.retail_price_cents, product.size_ml
    into v_name, v_price, v_size from public.products product where product.id=v_product;
  if v_name <> 'Chivas Regal 12' or v_price <> 13500 or v_size <> 1000 then
    raise exception 'v288: a null name or price must leave the stored value alone (got %, %, %)',
      v_name, v_price, v_size;
  end if;

  -- CORRECTION C3: the DEPLOYED v278 already does the same thing (v285 fixed it). Assert that,
  -- rather than the original's inverted claim that v278 drops the name and price.
  perform pg_temp.as_v288_user(v_owner);
  perform public.bar_save_bottle_product_v278(v_bar, v_product, 'v278 rename', 800, 7777);
  reset role;
  select product.name, product.retail_price_cents, product.size_ml
    into v_name, v_price, v_size from public.products product where product.id=v_product;
  if v_name <> 'v278 rename' or v_price <> 7777 or v_size <> 800 then
    raise exception 'v288/C3: the deployed v278 was expected to apply all three too (got %, %, %)',
      v_name, v_price, v_size;
  end if;
  perform pg_temp.as_v288_user(v_owner);
  v_payload := public.bar_save_bottle_product_v278(v_bar, null, 'V278 add path', 700, 5000);
  reset role;
  if v_payload is null or not (v_payload ? 'products') then
    raise exception 'v288: the v278 add path must stay deployed and callable';
  end if;
  v_log := v_log || ' [6 v288 applies name+price+size, nulls unchanged; deployed v278 identical (C3) and still callable]';

  -- ---- 7. grants ------------------------------------------------------------------------------
  select count(*) filter (where grantee='authenticated'),
         count(*) filter (where grantee in ('anon','PUBLIC'))
    into v_auth, v_anon
    from information_schema.role_routine_grants
   where specific_schema='public'
     and routine_name in ('remove_bottle_v288','bar_save_bottle_product_v288');
  select count(*) into v_count from information_schema.role_routine_grants
   where specific_schema='app' and routine_name='business_has_appointments_module_v288'
     and grantee in ('anon','PUBLIC','authenticated');
  if v_auth <> 2 or v_anon <> 0 or v_count <> 0 then
    raise exception 'v288: grants matrix wrong (authenticated %, anon/PUBLIC %, helper %)',
      v_auth, v_anon, v_count;
  end if;
  v_log := v_log || ' [7 grants authenticated=2, anon+PUBLIC=0, app helper exposed to nobody]';

  -- ---- 8. CLOSED BY V290 (was KNOWN OPEN) ------------------------------------------------------
  -- This section used to pin the residual gap described in C2: with appointments genuinely absent,
  -- confirm still failed 42501 because public.book_appointment_smart_v47's own wrapper demanded
  -- require_branch_module_v94(...,'appointments','rw') unconditionally, and its base demanded
  -- app.can_module_write(...,'appointments'). db/migrations/20260812_nestly_v290_server_debt_closure
  -- makes both conditional on app.business_has_appointments_module_v288 and demands the BOOKINGS
  -- write boundary in their place, so the section is now the positive assertion its own comment
  -- asked for. The V290 suite (db/tests/v290_server_debt_closure.sql §2-§3) is the primary
  -- evidence; this is the V288 file refusing to keep claiming a gap that is closed.
  insert into public.platform_module_overrides_v94 (business_id,branch_scope,module_key,mode,reason)
  values (v_bar,null,'appointments','disabled','v288 rolled-back sectorless probe');
  v_has := app.business_has_appointments_module_v288(v_bar, v_branch);
  if v_has then
    raise exception 'v288: a disabled appointments override must make the helper report absent';
  end if;
  insert into public.booking_requests (business_id,name,phone,status,preferred_at)
  values (v_bar,'V288 sectorless confirm','81000291','new', v_start8) returning id into v_request;
  v_raised := false;
  perform pg_temp.as_v288_user(v_owner);
  begin
    v_payload := public.staff_decide_booking_request_v73(v_bar, v_request, 'confirm', null);
  exception when others then v_raised := true; v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if v_raised then
    raise exception 'v288/8: V290 should have closed this gap; confirm still raised % (%)',
      v_state, v_msg;
  end if;
  -- CORRECTION C6 (2026-08-12): staff_decide_booking_request_v73 returns outcome / actual_status /
  -- appointment_id and has NO 'status' key, so this assertion could not have passed even with the
  -- gate closed. Assert on what it actually returns, and on the appointment it actually made.
  if coalesce(v_payload->>'actual_status','') <> 'confirmed'
     or coalesce(v_payload->>'outcome','') <> 'applied'
     or v_payload->>'appointment_id' is null then
    raise exception 'v288/8: an appointments-less confirm returned % instead of a confirmation',
      v_payload;
  end if;
  if not exists (select 1 from public.appointments appointment
                  where appointment.id = (v_payload->>'appointment_id')::uuid
                    and appointment.business_id = v_bar) then
    raise exception 'v288/8: the confirmation produced no appointment row';
  end if;
  v_log := v_log || format(
    ' [8 CLOSED BY V290: appointments-less confirm outcome=%s actual_status=%s]',
    v_payload->>'outcome', v_payload->>'actual_status');

  raise exception 'V288_RESULT ALL PASS -- %', v_log;
end
$v288$;

rollback;
