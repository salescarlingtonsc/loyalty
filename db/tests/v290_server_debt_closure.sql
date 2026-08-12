-- Rollback-only acceptance for V290 — server-side debt closure.
--
-- ============================================================================================
-- CORRECTIONS (2026-08-12, first execution against production; the migration was applied as
-- nestly_v290_server_debt_closure at 20260812050515). This suite had never been run. Five of its
-- premises did not survive contact with the deployed database. Each fix is marked CORRECTION
-- inline; none of them weakens an assertion, and two of them strengthen one that could not
-- previously fail. Final line: V290_RESULT ALL PASS.
--
--   S1  public.services has no created_at column.
--   S2  Cubbly has NO non-owner member, so section 1's behavioural probe — the only part that
--       proves the DELETE path, which is the entire point of the section — silently skipped.
--       A member is now seeded inside the rolled-back transaction.
--   S3  staff_decide_booking_request_v73 returns outcome / actual_status / appointment_id and has
--       no 'status' key, so sections 2 (here) and 8 (v288) could not have passed as written even
--       with the gate closed.
--   S4  Cubbly's OWNER IS the platform superadmin, so the superadmin-only negative in section 6
--       was unprovable with that actor. Negative now uses an unprivileged member; the positive
--       half was added.
--   S5  Section 7 never proved the negative half of the staff gate; a non-staff redeem probe was
--       added.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives. It is ONE statement so it can be executed through a single-statement
-- client, and ends in `raise exception 'V290_RESULT ALL PASS -- %'`.
--
-- What this proves, in order:
--   1  staff_services IS NO LONGER MEMBER-WRITABLE. The single `for all` policy is gone; there are
--      four per-command policies; SELECT tests membership and INSERT/UPDATE/DELETE test ownership.
--      Behaviourally: a non-owner member's DELETE of a colleague's service assignment removes zero
--      rows, where before V290 it removed the row.
--   2  THE V288 KNOWN OPEN IS CLOSED. With appointments genuinely absent (a firm-scope
--      platform_module_overrides_v94 disable, the only way the platform supports it — see V288 C1),
--      a bar owner can now CONFIRM a booking request end to end. Section 8 of
--      db/tests/v288_a2_gap_closure.sql pinned this as failing 42501; it is now a positive
--      assertion, and that file's section 8 has been rewritten to match.
--   3  THE APPOINTMENTS BOUNDARY IS NOT LOST where the sector HAS appointments: with the override
--      removed, a member without appointments write is still refused 42501.
--   4  A CORRECTED SALE NAMES ITS CORRECTION. staff_get_reversal_workflows emits
--      correction_sale_id / corrected_sale_id / correction_role beside the keys it already emitted,
--      and a real v84 correction chain (created and rolled back here) resolves all three roles.
--   5  ONE CALL COUNTS THE BUCKETS. staff_customer_bucket_counts_v290 agrees exactly with
--      staff_list_customers_v155's own totals for every bucket, including the new 'all_inactive',
--      under the identical scope; a caller without customer read is refused 42501.
--   6  ⚖️ ERASURE ANONYMISES AND REFUSES. Owner-only; refused while credit is outstanding;
--      anonymises in place; idempotent; leaves the ledger rows untouched and still joinable.
--   7  THE PROMOTION INTENT LIFECYCLE. Customer creates one, replay returns the same, staff redeem
--      marks it redeemed once, a second attempt says already_redeemed with when, and an expired
--      intent is refused as expired.
--   8  GRANTS. anon and PUBLIC hold no EXECUTE on any new RPC; authenticated holds all four; the
--      three new tables carry RLS with no policy and no browser-role grant.

begin;

do $v290$
declare
  v_log text := '';
  v_salon uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa'; -- Cubbly, REAL industry='facial'
  v_bar uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';   -- Bistro 999, REAL industry='bar'
  v_owner uuid; v_member uuid; v_barowner uuid;
  v_staff uuid; v_barstaff uuid; v_service uuid;
  v_branch uuid; v_barbranch uuid;
  v_client uuid; v_probe uuid; v_holder uuid; v_promotion uuid;
  v_identity uuid; v_custuser uuid; v_custclient uuid;
  v_request uuid; v_sale uuid; v_intent uuid;
  v_payload jsonb; v_second jsonb; v_counts jsonb; v_list jsonb;
  v_item jsonb;
  v_key uuid; v_text text; v_state text; v_msg text;
  v_raised boolean; v_seeded boolean := false; v_member_seeded boolean := false;
  v_count integer; v_before integer; v_auth integer; v_anon integer;
  v_start timestamptz; v_dow smallint;
begin
  execute $ddl$
    create or replace function pg_temp.as_v290_user(p_uid uuid, p_role text default 'authenticated')
    returns void language plpgsql as $f$
    begin
      reset role;
      execute format('set local role %I', p_role);
      perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
      perform set_config('request.jwt.claims',
        json_build_object('sub',p_uid,'role',p_role)::text, true);
    end $f$
  $ddl$;
  execute 'grant execute on function pg_temp.as_v290_user(uuid, text) to public';

  -- ---- fixture discovery ---------------------------------------------------------------------
  select staff_row.user_id into v_owner from public.staff staff_row
   where staff_row.business_id = v_salon and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved' limit 1;
  select staff_row.user_id into v_barowner from public.staff staff_row
   where staff_row.business_id = v_bar and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved' limit 1;
  select staff_row.id into v_barstaff from public.staff staff_row
   where staff_row.business_id = v_bar and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved' limit 1;
  select branch.id into v_branch from public.branches branch
   where branch.business_id = v_salon and branch.active
   order by branch.is_default desc, branch.created_at, branch.id limit 1;
  select branch.id into v_barbranch from public.branches branch
   where branch.business_id = v_bar and branch.active
   order by branch.is_default desc, branch.created_at, branch.id limit 1;
  -- CORRECTION (2026-08-12, first execution against production): public.services has NO created_at
  -- column. Order by id alone.
  select service.id into v_service from public.services service
   where service.business_id = v_salon and service.active
   order by service.id limit 1;
  if v_owner is null or v_barowner is null or v_branch is null
     or v_barbranch is null or v_service is null then
    raise exception 'v290: fixtures incomplete (owner %, bar owner %, branch %, bar branch %, service %)',
      v_owner, v_barowner, v_branch, v_barbranch, v_service;
  end if;

  -- ---- 1. staff_services is owner-write, member-read, per command -----------------------------
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='staff_services' and cmd='ALL';
  if v_count <> 0 then
    raise exception 'v290/1: staff_services still carries % FOR ALL policy(ies)', v_count;
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='staff_services'
     and policyname in ('staff_services_select','staff_services_insert',
       'staff_services_update','staff_services_delete');
  if v_count <> 4 then
    raise exception 'v290/1: expected 4 per-command staff_services policies, found %', v_count;
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='staff_services'
     and policyname in ('staff_services_insert','staff_services_update','staff_services_delete')
     and coalesce(qual,'') || coalesce(with_check,'') like '%is_salon_owner%';
  if v_count <> 3 then
    raise exception 'v290/1: the three write policies must all test ownership, found %', v_count;
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
    and tablename='staff_services' and policyname='staff_services_select'
    and qual like '%is_salon_member%') then
    raise exception 'v290/1: members must keep their read of staff_services';
  end if;

  -- Behavioural: a non-owner member deletes nothing.
  select staff_row.user_id into v_member from public.staff staff_row
   where staff_row.business_id = v_salon and staff_row.role <> 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
     and staff_row.user_id is not null limit 1;
  -- CORRECTION (2026-08-12): Cubbly carries NO non-owner member (verified: 0 rows), so the original
  -- would have taken the else-branch and SILENTLY SKIPPED the behavioural half of the assertion this
  -- section exists to make — the policy shape alone does not prove a member's DELETE removes nothing.
  -- Seed one inside the rolled-back transaction from an auth user that belongs to no tenant
  -- (qa-frenly-test@example.invalid), so the probe always runs and nothing survives.
  if v_member is null then
    insert into public.staff (business_id, user_id, role, full_name, active, access_state)
    values (v_salon, '4be3825c-464a-4fcb-b5aa-079721982f9e', 'staff',
      'V290 rolled-back member probe', true, 'approved')
    returning user_id into v_member;
    v_member_seeded := true;
  end if;
  select staff_row.id into v_staff from public.staff staff_row
   where staff_row.business_id = v_salon and staff_row.active
   order by staff_row.created_at limit 1;
  if v_member is null or v_staff is null then
    raise exception 'v290/1: no member fixture could be established';
  end if;
  insert into public.staff_services (business_id, staff_id, service_id)
  values (v_salon, v_staff, v_service)
  on conflict do nothing;
  perform pg_temp.as_v290_user(v_member);
  delete from public.staff_services target
   where target.business_id = v_salon and target.staff_id = v_staff
     and target.service_id = v_service;
  get diagnostics v_count = row_count;
  reset role;
  if v_count <> 0 then
    raise exception 'v290/1: a non-owner member still deleted % staff_services row(s)', v_count;
  end if;
  v_log := v_log || format(
    ' [1 policies split; a member DELETE removes 0 rows; member seeded=%s]', v_member_seeded);

  -- ---- 2. the V288 known-open residual gate is closed -----------------------------------------
  if position('business_has_appointments_module_v288' in pg_get_functiondef(
       'public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure)) = 0
     or position('business_has_appointments_module_v288' in pg_get_functiondef(
       'public.book_appointment_smart_v47_v94_base(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure)) = 0 then
    raise exception 'v290/2: the smart-booking wrapper and base must both carry the sector condition';
  end if;

  -- V288 C4 scaffolding: this tenant has no rota, so the scheduler would refuse every slot for
  -- reasons unrelated to authorisation.
  v_start := date_trunc('hour', now() at time zone 'Asia/Singapore' + interval '2 days')
             at time zone 'Asia/Singapore' + interval '1 hour';
  v_dow := extract(dow from (v_start at time zone 'Asia/Singapore'))::smallint;
  if not exists (select 1 from public.branch_hours hours
                  where hours.business_id=v_bar and hours.branch_id=v_barbranch
                    and hours.weekday=v_dow) then
    insert into public.branch_hours (business_id,branch_id,weekday,opens_at,closes_at)
    values (v_bar,v_barbranch,v_dow,'00:00','23:59');
  end if;
  if not exists (select 1 from public.staff_hours hours
                  where hours.business_id=v_bar and hours.staff_id=v_barstaff
                    and hours.weekday=v_dow) then
    insert into public.staff_hours (business_id,staff_id,weekday,starts_at,ends_at)
    values (v_bar,v_barstaff,v_dow,'00:00','23:59');
  end if;

  insert into public.platform_module_overrides_v94
    (business_id,branch_scope,module_key,mode,reason)
  values (v_bar,null,'appointments','disabled','v290 rolled-back sectorless probe');
  if app.business_has_appointments_module_v288(v_bar, v_barbranch) then
    raise exception 'v290/2: a disabled appointments override must make the helper report absent';
  end if;
  insert into public.booking_requests (business_id,name,phone,status,preferred_at)
  values (v_bar,'V290 sectorless confirm','81000292','new', v_start) returning id into v_request;
  perform pg_temp.as_v290_user(v_barowner);
  begin
    v_payload := public.staff_decide_booking_request_v73(v_bar, v_request, 'confirm', null);
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm; reset role;
    raise exception 'v290/2: an appointments-less sector still cannot confirm (% %)', v_state, v_msg;
  end;
  reset role;
  -- CORRECTION (2026-08-12): staff_decide_booking_request_v73 returns outcome / actual_status /
  -- appointment_id. It has NO 'status' key, so the original assertion could not have passed even
  -- with the gate closed. Assert on what it actually returns, and on the appointment it made.
  if coalesce(v_payload->>'actual_status','') <> 'confirmed'
     or coalesce(v_payload->>'outcome','') <> 'applied'
     or v_payload->>'appointment_id' is null then
    raise exception 'v290/2: confirm returned % instead of a confirmation', v_payload;
  end if;
  if not exists (select 1 from public.appointments appointment
                  where appointment.id = (v_payload->>'appointment_id')::uuid
                    and appointment.business_id = v_bar) then
    raise exception 'v290/2: the confirmation did not produce an appointment row';
  end if;
  v_log := v_log || format(
    ' [2 V288 KNOWN OPEN CLOSED: appointments-less confirm outcome=%s actual_status=%s]',
    v_payload->>'outcome', v_payload->>'actual_status');

  -- ---- 3. the boundary is not lost where the sector HAS appointments --------------------------
  delete from public.platform_module_overrides_v94 override_row
   where override_row.business_id = v_bar and override_row.branch_scope is null
     and override_row.module_key = 'appointments';
  if not app.business_has_appointments_module_v288(v_bar, v_barbranch) then
    raise exception 'v290/3: with the override removed the sector must carry appointments again';
  end if;
  insert into public.platform_module_overrides_v94
    (business_id,branch_scope,module_key,mode,reason)
  values (v_bar,null,'appointments','r','v290 read-only appointments probe');
  insert into public.booking_requests (business_id,name,phone,status,preferred_at)
  values (v_bar,'V290 readonly confirm','81000293','new', v_start) returning id into v_request;
  v_raised := false;
  perform pg_temp.as_v290_user(v_barowner);
  begin
    v_payload := public.staff_decide_booking_request_v73(v_bar, v_request, 'confirm', null);
  exception when others then v_raised := true; v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if not v_raised or v_state <> '42501' then
    raise exception 'v290/3: read-only appointments must still refuse a confirm (raised %, state %)',
      v_raised, v_state;
  end if;
  delete from public.platform_module_overrides_v94 override_row
   where override_row.business_id = v_bar and override_row.branch_scope is null
     and override_row.module_key = 'appointments';
  v_log := v_log || ' [3 read-only appointments still refuses confirm 42501]';

  -- ---- 4. a corrected sale names its correction ------------------------------------------------
  select client.id into v_client from public.clients client
   where client.business_id = v_salon order by client.created_at limit 1;
  if v_client is null then
    raise exception 'v290/4: the salon fixture needs at least one customer';
  end if;
  perform pg_temp.as_v290_user(v_owner);
  v_payload := public.record_quick_sale(
    p_business => v_salon, p_amount_cents => 4200, p_method => 'cash',
    p_client => v_client, p_staff => null, p_branch => v_branch, p_note => null,
    p_idempotency_key => 'v290-correction-source-probe', p_paid => false)::jsonb;
  v_sale := nullif(v_payload #>> '{sale,id}','')::uuid;
  if v_sale is null then
    reset role;
    raise exception 'v290/4: the correction fixture sale was not created (%)', v_payload;
  end if;
  v_payload := public.correct_quick_sale_amount_v84(
    v_salon, v_sale, 3900, 'v290-correction-probe-key', 'V290 rolled-back probe');
  v_list := public.staff_get_reversal_workflows(v_salon, v_client, 100, 'all');
  reset role;

  v_item := null;
  select item into v_item
    from jsonb_array_elements(v_list->'sales') item
   where item->>'id' = v_sale::text;
  if v_item is null then
    raise exception 'v290/4: the original sale is absent from the workflow reader';
  end if;
  if not (v_item ? 'correction_sale_id') or not (v_item ? 'corrected_sale_id')
     or not (v_item ? 'correction_role') or not (v_item ? 'correction_record_id') then
    raise exception 'v290/4: the correction keys are missing from the workflow item (%)', v_item;
  end if;
  if v_item->>'correction_role' <> 'original'
     or v_item->>'correction_sale_id' is distinct from (v_payload->>'replacement_sale_id')
     or v_item->>'corrected_sale_id' is not null then
    raise exception 'v290/4: the ORIGINAL row must name the replacement and nothing else (%)', v_item;
  end if;
  select item into v_item
    from jsonb_array_elements(v_list->'sales') item
   where item->>'id' = (v_payload->>'replacement_sale_id');
  if v_item is null or v_item->>'correction_role' <> 'replacement'
     or v_item->>'corrected_sale_id' is distinct from v_sale::text
     or v_item->>'correction_sale_id' is not null then
    raise exception 'v290/4: the REPLACEMENT row must name the original and nothing else (%)', v_item;
  end if;
  select item into v_item
    from jsonb_array_elements(v_list->'sales') item
   where item->>'id' = (v_payload->>'reversal_sale_id');
  if v_item is null or v_item->>'correction_role' <> 'reversal' then
    raise exception 'v290/4: the REVERSAL row must be named as part of the correction (%)', v_item;
  end if;
  if v_item->>'reversal_sale_id' is null then
    raise exception 'v290/4: an existing workflow key was lost by the splice (%)', v_item;
  end if;
  v_log := v_log || ' [4 all three correction roles resolve, existing keys intact]';

  -- ---- 5. one call counts the buckets, and agrees with the list --------------------------------
  perform pg_temp.as_v290_user(v_owner);
  v_counts := public.staff_customer_bucket_counts_v290(v_salon, null, 'all',
    array[]::uuid[], null);
  foreach v_text in array array['30_59','60_89','90_plus','never','all_inactive'] loop
    v_list := public.staff_list_customers_v155(v_salon, null, v_text, 'all',
      array[]::uuid[], null, 1, 0);
    if (v_counts #>> array['counts',v_text])::bigint
       is distinct from (v_list->>'total')::bigint then
      reset role;
      raise exception 'v290/5: bucket % counts % but the list totals %',
        v_text, v_counts #>> array['counts',v_text], v_list->>'total';
    end if;
  end loop;
  v_list := public.staff_list_customers_v155(v_salon, null, null, 'all',
    array[]::uuid[], null, 1, 0);
  if (v_counts #>> '{counts,total}')::bigint is distinct from (v_list->>'total')::bigint then
    reset role;
    raise exception 'v290/5: the unfiltered total disagrees (% vs %)',
      v_counts #>> '{counts,total}', v_list->>'total';
  end if;
  if (v_counts #>> '{counts,all_inactive}')::bigint
     is distinct from ((v_counts #>> '{counts,30_59}')::bigint
       + (v_counts #>> '{counts,60_89}')::bigint
       + (v_counts #>> '{counts,90_plus}')::bigint) then
    reset role;
    raise exception 'v290/5: all_inactive must be exactly the three windows (%)', v_counts;
  end if;
  reset role;
  v_raised := false;
  perform pg_temp.as_v290_user(v_barowner);
  begin
    v_counts := public.staff_customer_bucket_counts_v290(v_salon, null, 'all',
      array[]::uuid[], null);
  exception when others then v_raised := true; v_state := sqlstate;
  end;
  reset role;
  if not v_raised or v_state <> '42501' then
    raise exception 'v290/5: a foreign owner must be refused 42501 (raised %, state %)',
      v_raised, v_state;
  end if;
  v_log := v_log || ' [5 counts agree with v155 for all five buckets; foreign owner 42501]';

  -- ---- 6. ⚖️ erasure ---------------------------------------------------------------------------
  insert into public.clients (business_id, full_name, phone, email, notes, marketing_consent)
  values (v_salon, 'V290 Erasure Probe', '81000294', 'v290probe@example.invalid',
    'probe note', true)
  returning id into v_probe;

  v_raised := false;
  perform pg_temp.as_v290_user(v_member);
  begin
    v_payload := public.erase_client_v290(v_salon, v_probe, 'v290 probe', 'v290-erase-key-1');
  exception when others then v_raised := true; v_state := sqlstate;
  end;
  reset role;
  if not v_raised or v_state <> '42501' then
    raise exception 'v290/6: a non-owner must be refused 42501 (raised %, state %)',
      v_raised, v_state;
  end if;

  -- The refusal is probed against a REAL holding rather than a manufactured one: credit_ledger
  -- carries a write guard and bar_bottles is the one holdings table with a live row, so the
  -- fixture is read-only and the refusal is measured against production truth.
  select bottle.client_id into v_holder from public.bar_bottles bottle
   where bottle.business_id = v_bar and bottle.client_id is not null
     and bottle.status in ('stored','called','at_table','expired') limit 1;
  if v_holder is null then
    raise exception 'v290/6: the bar fixture needs one bottle still in storage';
  end if;
  perform pg_temp.as_v290_user(v_barowner);
  v_payload := public.erase_client_v290(v_bar, v_holder, 'v290 probe', 'v290-erase-holdings');
  reset role;
  if v_payload->>'status' <> 'refused'
     or v_payload->>'reason' <> 'holdings_outstanding'
     or (v_payload->>'bottles_in_storage')::integer < 1 then
    raise exception 'v290/6: a bottle still in storage must refuse the erasure (%)', v_payload;
  end if;

  perform pg_temp.as_v290_user(v_owner);
  v_payload := public.erase_client_v290(v_salon, v_probe, 'v290 probe', 'v290-erase-key-1');
  v_second := public.erase_client_v290(v_salon, v_probe, 'v290 probe', 'v290-erase-key-1');
  reset role;
  if v_payload->>'status' <> 'erased' then
    raise exception 'v290/6: erasure did not complete (%)', v_payload;
  end if;
  if v_second->>'status' <> 'duplicate_ignored'
     or v_second->>'erasure_id' is distinct from (v_payload->>'erasure_id') then
    raise exception 'v290/6: erasure is not idempotent (%)', v_second;
  end if;
  select client.full_name into v_text
    from public.clients client where client.id = v_probe;
  if v_text <> 'Erased customer' then
    raise exception 'v290/6: the name was not anonymised (%)', v_text;
  end if;
  if exists (select 1 from public.clients client
              where client.id = v_probe
                and (client.phone is not null or client.email is not null
                  or client.notes is not null or client.phone_norm is not null
                  or client.birth_date is not null or client.marketing_consent)) then
    raise exception 'v290/6: an identifying field survived the erasure';
  end if;
  if not exists (select 1 from public.clients client where client.id = v_probe) then
    raise exception 'v290/6: the customer row itself must survive, anonymised, so the
      append-only ledgers that reference it stay joinable';
  end if;
  if not exists (select 1 from public.client_erasures_v290 record
                  where record.client_id = v_probe and record.actor = v_owner) then
    raise exception 'v290/6: the erasure evidence row is missing';
  end if;
  if not exists (select 1 from public.audit_log entry
                  where entry.entity_id = v_probe and entry.action = 'CLIENT_ERASED_V290') then
    raise exception 'v290/6: the audit row is missing';
  end if;
  -- CORRECTION (2026-08-12): the original drove the superadmin-only NEGATIVE with v_owner, but
  -- Cubbly's OWNER IS the platform superadmin (leechuanseng.biz@gmail.com, public.super_admins), so
  -- the call legitimately succeeded and the assertion was unprovable as written. Drive the negative
  -- with a genuinely unprivileged workspace user, and assert the POSITIVE with the real superadmin —
  -- which is the half that actually proves the console reader works.
  v_raised := false;
  perform pg_temp.as_v290_user(v_member);
  begin
    v_payload := public.list_client_erasures_v290(v_salon, 10);
  exception when others then v_raised := true; v_state := sqlstate;
  end;
  reset role;
  if not v_raised or v_state <> '42501' then
    raise exception 'v290/6: the console reader must be superadmin-only (raised %, state %)',
      v_raised, v_state;
  end if;
  perform pg_temp.as_v290_user(v_owner);
  v_payload := public.list_client_erasures_v290(v_salon, 10);
  reset role;
  if v_payload->>'status' <> 'ok'
     or not exists (select 1 from jsonb_array_elements(v_payload->'items') listed
                     where listed->>'client_id' = v_probe::text) then
    raise exception 'v290/6: the superadmin reader must return the erasure (%)', v_payload;
  end if;
  v_log := v_log || ' [6 erasure: owner-only, refuses on holdings, anonymises, idempotent, ledger intact;'
    || ' reader 42501 for a member, ok for the superadmin]';

  -- ---- 7. the promotion intent lifecycle -------------------------------------------------------
  select link.identity_id, link.auth_user_id, link.client_id
    into v_identity, v_custuser, v_custclient
    from public.customer_links link
    join public.customer_identities identity
      on identity.id = link.identity_id and identity.status = 'active'
   where link.business_id = v_salon and link.state = 'verified'
   order by link.created_at limit 1;
  if v_identity is null then
    raise exception 'v290/7: the salon fixture needs one verified customer link';
  end if;
  select content.id into v_promotion from public.business_customer_content_v95 content
   where content.business_id = v_salon and content.content_type = 'offer'
     and content.active and content.branch_id is null
     and (content.starts_at is null or content.starts_at <= now())
     and content.ends_at > now()
   order by content.display_order, content.id limit 1;
  if v_promotion is null then
    insert into public.business_customer_content_v95
      (business_id, content_type, active, display_order, starts_at, ends_at, metadata)
    values (v_salon, 'offer', true, 900, now() - interval '1 day', now() + interval '7 days',
      jsonb_build_object('cta', jsonb_build_object('kind','counter')))
    returning id into v_promotion;
    v_seeded := true;
  end if;

  v_key := gen_random_uuid();
  perform pg_temp.as_v290_user(v_custuser);
  v_payload := public.customer_create_promotion_intent_v290(v_salon, v_promotion, v_key);
  v_second := public.customer_create_promotion_intent_v290(v_salon, v_promotion, v_key);
  reset role;
  if v_payload->>'status' <> 'pending' or coalesce(v_payload->>'qr_token','') = '' then
    raise exception 'v290/7: the intent was not created (%)', v_payload;
  end if;
  if v_second->>'intent_id' is distinct from (v_payload->>'intent_id')
     or v_second->>'replayed' <> 'true' then
    raise exception 'v290/7: an identical key must replay the same intent (%)', v_second;
  end if;
  v_intent := (v_payload->>'intent_id')::uuid;
  v_text := v_payload->>'qr_token';

  perform pg_temp.as_v290_user(v_owner);
  v_payload := public.staff_redeem_promotion_intent_v290(
    v_salon, v_text, v_branch, 'v290-promotion-redeem-1');
  v_second := public.staff_redeem_promotion_intent_v290(
    v_salon, v_text, v_branch, 'v290-promotion-redeem-1');
  v_counts := public.staff_redeem_promotion_intent_v290(
    v_salon, v_text, v_branch, 'v290-promotion-redeem-2');
  reset role;
  if v_payload->>'status' <> 'redeemed'
     or (v_payload->>'intent_id')::uuid <> v_intent then
    raise exception 'v290/7: the staff redemption did not complete (%)', v_payload;
  end if;
  if v_second->>'status' <> 'duplicate_ignored'
     or v_second->>'redemption_id' is distinct from (v_payload->>'redemption_id') then
    raise exception 'v290/7: the idempotency key must replay, not re-record (%)', v_second;
  end if;
  if v_counts->>'status' <> 'already_redeemed' or v_counts->>'redeemed_at' is null then
    raise exception 'v290/7: a second attempt must say already_redeemed with when (%)', v_counts;
  end if;
  select count(*) into v_count from public.promotion_redemptions_v290 record
   where record.intent_id = v_intent;
  if v_count <> 1 then
    raise exception 'v290/7: exactly one redemption row must exist, found %', v_count;
  end if;

  -- an expired intent is refused as expired, not accepted
  v_key := gen_random_uuid();
  perform pg_temp.as_v290_user(v_custuser);
  v_payload := public.customer_create_promotion_intent_v290(v_salon, v_promotion, v_key);
  reset role;
  update public.promotion_redemption_intents_v290 intent
     set expires_at = now() - interval '1 minute'
   where intent.id = (v_payload->>'intent_id')::uuid;
  perform pg_temp.as_v290_user(v_owner);
  v_second := public.staff_redeem_promotion_intent_v290(
    v_salon, v_payload->>'qr_token', v_branch, 'v290-promotion-redeem-3');
  reset role;
  if v_second->>'status' <> 'expired' then
    raise exception 'v290/7: an expired intent must be refused as expired (%)', v_second;
  end if;
  -- CORRECTION (2026-08-12): the original never proved the NEGATIVE half of the staff gate. A
  -- verified CUSTOMER holding neither sales nor loyalty write must be refused 42501 at the scanner.
  v_raised := false;
  v_key := gen_random_uuid();
  perform pg_temp.as_v290_user(v_custuser);
  begin
    v_payload := public.customer_create_promotion_intent_v290(v_salon, v_promotion, v_key);
    v_second := public.staff_redeem_promotion_intent_v290(
      v_salon, v_payload->>'qr_token', v_branch, 'v290-promotion-nonstaff');
  exception when others then v_raised := true; v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if not v_raised or v_state <> '42501' then
    raise exception 'v290/7: a non-staff caller must be refused 42501 (raised %, state %)',
      v_raised, v_state;
  end if;
  v_log := v_log || format(
    ' [7 intent lifecycle sound; non-staff redeem 42501 "%s"; offer fixture seeded=%s]',
    v_msg, v_seeded);

  -- ---- 8. grants and table ACLs ----------------------------------------------------------------
  select count(*) filter (where grantee='authenticated'),
         count(*) filter (where grantee in ('anon','PUBLIC'))
    into v_auth, v_anon
    from information_schema.role_routine_grants
   where specific_schema='public'
     and routine_name in ('staff_customer_bucket_counts_v290','erase_client_v290',
       'list_client_erasures_v290','customer_create_promotion_intent_v290',
       'staff_redeem_promotion_intent_v290');
  if v_auth <> 5 or v_anon <> 0 then
    raise exception 'v290/8: grants matrix wrong (authenticated %, anon/PUBLIC %)', v_auth, v_anon;
  end if;
  select count(*) into v_count from information_schema.role_table_grants
   where table_schema='public'
     and table_name in ('client_erasures_v290','promotion_redemption_intents_v290',
       'promotion_redemptions_v290')
     and grantee in ('anon','authenticated','PUBLIC');
  if v_count <> 0 then
    raise exception 'v290/8: the new tables must hold no browser-role grant, found %', v_count;
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public'
     and tablename in ('client_erasures_v290','promotion_redemption_intents_v290',
       'promotion_redemptions_v290');
  if v_count <> 0 then
    raise exception 'v290/8: the new tables must carry NO policy, found %', v_count;
  end if;
  select count(*) into v_count from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relrowsecurity
     and c.relname in ('client_erasures_v290','promotion_redemption_intents_v290',
       'promotion_redemptions_v290');
  if v_count <> 3 then
    raise exception 'v290/8: all three new tables must have RLS enabled, found %', v_count;
  end if;
  v_log := v_log || ' [8 authenticated=5, anon+PUBLIC=0, three deny-all tables]';

  raise exception 'V290_RESULT ALL PASS -- %', v_log;
end
$v290$;

rollback;
