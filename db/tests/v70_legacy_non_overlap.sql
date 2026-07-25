-- Rollback-only v70 LEGACY NON-OVERLAP suite. Run after the complete canonical chain through v70
-- in a disposable rehearsal database. The including transaction owns BEGIN/ROLLBACK; nothing commits.
--
-- Contract: docs/design/ps2/PS2_LIVE_V70_LEGACY_NON_OVERLAP_CONTRACT.md.
--
-- WHAT IT PROVES
--   PART 0  static catalog truth on the APPLIED chain: every v70 function is definer + pinned +
--           correctly revoked; both issue_gift_card overloads carry the non-overlap guard; the two
--           new tables have RLS, zero browser DML and an immutable guard; sv_reconciliation_snapshots
--           gained acknowledged_cents; the discrepancy vocabulary gained acknowledgement_drift.
--   PART 1  section 1 non-overlap: on a LIVE business both issue_gift_card overloads refuse with
--           sv_live_legacy_issue_blocked and mutate nothing; a NON-live business still issues; and
--           REDEMPTION of an already-issued card keeps working on the live business (don't-strand).
--   PART 2  section 2 acknowledgement + reconciliation netting - the kopi-tiam 5000c pilot-readiness
--           proof: blocked -> acknowledge exactly 5000c -> clean -> full v69 readiness passes; then
--           BOTH drift directions (a new card grows it, a partial redemption shrinks it, incl. to
--           zero) re-dirty as acknowledgement_drift; re-acknowledging the new amount re-cleans; and
--           an off-by-one acknowledgement (4999c against 5000c) does NOT net (amount-specific).
--   PART 3  the acknowledgement + classification mechanisms: auth (owner/super-admin vs frontdesk/
--           anon), validation, append-only immutability, browser-DML denial; and the inventory RPC.
--   PART 4  no value moved: acknowledging and reconciling leave gift_cards byte-identical and write
--           no sv_lot_movements; kopi tiam's card is intact at 5000c across the acknowledgement.
--
-- The snapshot ordering tie-break is (captured_at desc, id desc); every snapshot written inside ONE
-- transaction shares now(), so superseded snapshots are aged by a minute (the v69 house pattern) to
-- keep "latest snapshot" deterministic. Production cannot reach that tie (each run is its own txn).

begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v70(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if p_role = 'anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  elsif p_role = 'postgres' then
    execute 'reset role';
  elsif p_role = 'authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  else
    raise exception 'unsupported v70 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v70(uuid, text) to authenticated, anon;

-- Age every snapshot for a business EXCEPT the one to keep, so readiness reads the kept one.
create or replace function pg_temp.v70_pin_snapshot(p_business uuid, p_keep uuid)
returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_reconciliation_snapshots disable trigger sv_reconciliation_snapshots_immutable_guard;
  update public.sv_reconciliation_snapshots
     set captured_at = captured_at - interval '1 minute'
   where business_id = p_business and id <> p_keep;
  alter table public.sv_reconciliation_snapshots enable trigger sv_reconciliation_snapshots_immutable_guard;
end $$;
grant execute on function pg_temp.v70_pin_snapshot(uuid, uuid) to authenticated;

-- Force an authority state (the v63/v64/v68a/v69 shim; ONLY the one named guard is suspended).
create or replace function pg_temp.v70_force_state(p_business uuid, p_state text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state = p_state where business_id = p_business and asset = 'stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
grant execute on function pg_temp.v70_force_state(uuid, text) to authenticated;

do $v70_test$
declare
  v_owner_k uuid := gen_random_uuid(); v_biz_k uuid; v_gc_k uuid;
  v_owner_l uuid := gen_random_uuid(); v_biz_l uuid; v_gc_l_code text; v_client_l uuid;
  v_sa uuid := gen_random_uuid();
  v_fd uuid := gen_random_uuid(); v_fd_staff uuid;
  v_res jsonb; v_res2 jsonb;
  v_snap uuid;
  v_md5_gc text; v_md5_gc2 text;
  v_gc_count_before int; v_gc_count_after int;
  v_mv_before int; v_mv_after int;
  v_prosecdef boolean; v_cfg text[]; v_def text;
  v_disc jsonb; v_drift jsonb;
  v_conname text; v_condef text;
  v_ack_id uuid;
begin
  -- ============================ FIXTURES ============================
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_owner_k,'authenticated','authenticated','v70-k-'||v_owner_k::text||'@ex.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner_l,'authenticated','authenticated','v70-l-'||v_owner_l::text||'@ex.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated','v70-sa-'||v_sa::text||'@ex.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_fd,'authenticated','authenticated','v70-fd-'||v_fd::text||'@ex.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note) values(v_sa,'v70-sa@ex.test','v70 rollback-only super admin');

  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_biz_k := (public.create_business('v70 kopi tiam','v70k-'||replace(v_owner_k::text,'-',''),'test',
    array['dashboard','clients','sales','loyalty','giftcards'])::jsonb->>'id')::uuid;
  perform pg_temp.as_v70(v_owner_l,'authenticated');
  v_biz_l := (public.create_business('v70 live cafe','v70l-'||replace(v_owner_l::text,'-',''),'test',
    array['dashboard','clients','sales','loyalty','giftcards'])::jsonb->>'id')::uuid;

  -- a frontdesk staff member on K (for negative-auth tests) + a client on L (for redemption).
  reset role;
  insert into public.staff(business_id,user_id,role,active,created_at)
  values (v_biz_k,v_fd,'frontdesk',true,now()) returning id into v_fd_staff;
  insert into public.clients(business_id,full_name,email,phone)
  values (v_biz_l,'v70 live client','v70-lc@ex.test','+6590009999') returning id into v_client_l;

  -- ============================ PART 0: static catalog ============================
  reset role;
  -- 0a. new functions are SECURITY DEFINER with a pinned search_path.
  for v_def in select unnest(array[
    'app.sv_legacy_issue_guard(uuid,text)',
    'public.acknowledge_legacy_value(uuid,text,bigint,text)',
    'public.get_legacy_acknowledgements(uuid,text)',
    'public.classify_legacy_business(uuid,text,text)',
    'public.get_legacy_value_inventory(uuid)'])
  loop
    select p.prosecdef, p.proconfig into v_prosecdef, v_cfg
      from pg_proc p where p.oid = v_def::regprocedure;
    if not v_prosecdef then raise exception 'v70-0a: % is not SECURITY DEFINER', v_def; end if;
    if not (v_cfg @> array['search_path=pg_catalog, public, app, pg_temp']
         or v_cfg @> array['search_path=public']) then
      raise exception 'v70-0a: % has no pinned search_path: %', v_def, v_cfg; end if;
  end loop;

  -- 0b. browser ACLs: helper is browser-invisible; the RPCs are authenticated-only (not anon).
  if has_function_privilege('authenticated','app.sv_legacy_issue_guard(uuid,text)','execute')
     or has_function_privilege('anon','app.sv_legacy_issue_guard(uuid,text)','execute') then
    raise exception 'v70-0b: sv_legacy_issue_guard must not be browser-executable'; end if;
  if not has_function_privilege('authenticated','public.acknowledge_legacy_value(uuid,text,bigint,text)','execute')
     or has_function_privilege('anon','public.acknowledge_legacy_value(uuid,text,bigint,text)','execute') then
    raise exception 'v70-0b: acknowledge_legacy_value ACL wrong'; end if;
  if not has_function_privilege('authenticated','public.classify_legacy_business(uuid,text,text)','execute')
     or has_function_privilege('anon','public.classify_legacy_business(uuid,text,text)','execute') then
    raise exception 'v70-0b: classify_legacy_business ACL wrong'; end if;
  if not has_function_privilege('authenticated','public.get_legacy_value_inventory(uuid)','execute')
     or has_function_privilege('anon','public.get_legacy_value_inventory(uuid)','execute') then
    raise exception 'v70-0b: get_legacy_value_inventory ACL wrong'; end if;
  -- issue_gift_card: 5-arg authenticated-executable, 4-arg REVOKED from authenticated and anon.
  if not has_function_privilege('authenticated','public.issue_gift_card(uuid,integer,uuid,text,uuid)','execute') then
    raise exception 'v70-0b: 5-arg issue_gift_card must stay authenticated-executable'; end if;
  if has_function_privilege('authenticated','public.issue_gift_card(uuid,integer,uuid,text)','execute')
     or has_function_privilege('anon','public.issue_gift_card(uuid,integer,uuid,text)','execute') then
    raise exception 'v70-0b: 4-arg issue_gift_card must stay browser-revoked'; end if;

  -- 0c. both overloads carry the guard; run_sv_reconciliation nets the acknowledgement.
  v_def := pg_get_functiondef('public.issue_gift_card(uuid,integer,uuid,text,uuid)'::regprocedure);
  if position('sv_legacy_issue_guard' in v_def) = 0 then raise exception 'v70-0c: 5-arg missing guard'; end if;
  v_def := pg_get_functiondef('public.issue_gift_card(uuid,integer,uuid,text)'::regprocedure);
  if position('sv_legacy_issue_guard' in v_def) = 0 then raise exception 'v70-0c: 4-arg missing guard'; end if;
  v_def := pg_get_functiondef('public.run_sv_reconciliation(uuid)'::regprocedure);
  if position('sv_legacy_acknowledgements' in v_def) = 0 or position('acknowledgement_drift' in v_def) = 0 then
    raise exception 'v70-0c: run_sv_reconciliation does not net the acknowledgement'; end if;

  -- 0d. new tables: RLS on, no browser DML, immutable guard present.
  if not (select relrowsecurity from pg_class where oid='public.sv_legacy_acknowledgements'::regclass)
     or not (select relrowsecurity from pg_class where oid='public.sv_legacy_classifications'::regclass) then
    raise exception 'v70-0d: a new legacy table lacks RLS'; end if;
  if has_table_privilege('authenticated','public.sv_legacy_acknowledgements','insert')
     or has_table_privilege('authenticated','public.sv_legacy_classifications','insert')
     or has_table_privilege('anon','public.sv_legacy_acknowledgements','select') then
    raise exception 'v70-0d: a new legacy table has a browser write / anon-read privilege'; end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.sv_legacy_acknowledgements'::regclass
                  and tgname='sv_legacy_acknowledgements_immutable_guard' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.sv_legacy_classifications'::regclass
                  and tgname='sv_legacy_classifications_immutable_guard' and not tgisinternal) then
    raise exception 'v70-0d: a new legacy table lacks its immutable guard'; end if;

  -- 0e. acknowledged_cents column + widened discrepancy vocabulary.
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='sv_reconciliation_snapshots'
                    and column_name='acknowledged_cents') then
    raise exception 'v70-0e: sv_reconciliation_snapshots missing acknowledged_cents'; end if;
  select c.conname, pg_get_constraintdef(c.oid) into v_conname, v_condef
    from pg_constraint c where c.conrelid='public.sv_reconciliation_discrepancies'::regclass
     and c.contype='c' and pg_get_constraintdef(c.oid) like '%category%';
  if position('acknowledgement_drift' in v_condef)=0 then
    raise exception 'v70-0e: discrepancy category CHECK missing acknowledgement_drift'; end if;

  -- ============================ PART 1: non-overlap refusals + redemption ============================
  -- Non-live issuance succeeds on L; the card will later be redeemed on the live business.
  perform pg_temp.as_v70(v_owner_l,'authenticated');
  v_res := public.issue_gift_card(v_biz_l, 4000, null, null, gen_random_uuid());
  if (v_res->>'status') <> 'completed' then raise exception 'v70-1: non-live issuance failed: %', v_res; end if;
  v_gc_l_code := v_res->>'code';

  -- Force L live and count gift cards before the refused attempts.
  perform pg_temp.v70_force_state(v_biz_l,'live');
  reset role;
  select count(*) into v_gc_count_before from public.gift_cards where business_id=v_biz_l;

  -- 5-arg issue refused when live.
  perform pg_temp.as_v70(v_owner_l,'authenticated');
  begin
    perform public.issue_gift_card(v_biz_l, 2000, null, null, gen_random_uuid());
    raise exception 'v70-1: 5-arg issue_gift_card was NOT blocked on a live business';
  exception when sqlstate '22023' then
    if position('sv_live_legacy_issue_blocked' in sqlerrm)=0 then raise exception 'v70-1: wrong 5-arg error: %', sqlerrm; end if;
  end;
  -- 4-arg overload refused when live. It is browser-revoked, so run as postgres to bypass the ACL,
  -- but set the owner's JWT claim so auth.uid()/is_salon_member pass and execution reaches the guard.
  reset role;
  perform set_config('request.jwt.claim.sub', v_owner_l::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner_l,'role','authenticated')::text, true);
  begin
    perform public.issue_gift_card(v_biz_l, 2000, null, null);
    raise exception 'v70-1: 4-arg issue_gift_card was NOT blocked on a live business';
  exception when sqlstate '22023' then
    if position('sv_live_legacy_issue_blocked' in sqlerrm)=0 then raise exception 'v70-1: wrong 4-arg error: %', sqlerrm; end if;
  end;
  -- The refusals mutated nothing.
  reset role;
  select count(*) into v_gc_count_after from public.gift_cards where business_id=v_biz_l;
  if v_gc_count_before <> v_gc_count_after then raise exception 'v70-1: a refused issuance created a gift card'; end if;

  -- Redemption of the already-issued card STILL works on the live business (don't-strand).
  perform pg_temp.as_v70(v_owner_l,'authenticated');
  v_res := public.redeem_gift_card_v41(v_biz_l, v_gc_l_code, v_client_l, 1000)::jsonb;
  reset role;
  if (select balance_cents from public.gift_cards where business_id=v_biz_l and code=v_gc_l_code) <> 3000 then
    raise exception 'v70-1: redemption on a live business did not reduce the balance to 3000'; end if;

  -- rev-2 (v69 review D1): stored value now permits only ONE live business platform-wide. PART 1's
  -- non-overlap refusals are proven, so release L from 'live' before the PART 2 readiness proof -
  -- otherwise L's liveness (correctly) blocks K with sv_pilot_already_live, which would mask the
  -- thing PART 2 exists to prove: that acknowledgement netting makes K's reconciliation CLEAN and its
  -- readiness pass. This is a suite-setup fix; no v70 migration bytes change.
  perform pg_temp.v70_force_state(v_biz_l,'shadow_testing');

  -- ============================ PART 2: acknowledgement + netting (kopi 5000c) ============================
  -- K enters shadow_testing and holds one active $50 legacy card.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','begin shadow testing');
  reset role;
  insert into public.gift_cards(business_id,code,initial_cents,balance_cents,status)
  values (v_biz_k,'V70-KOPI-1',5000,5000,'active') returning id into v_gc_k;
  -- Baseline sv_lot_movements: no v70 path (nor any direct edit below) may ever create one.
  select count(*) into v_mv_before from public.sv_lot_movements where business_id=v_biz_k;

  -- (A) pre-acknowledgement reconciliation is BLOCKED with a missing_in_studio for the $50 card.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v70-2A: expected blocked, got %', v_res; end if;
  if (v_res->>'legacy_total_cents')::int <> 5000 then raise exception 'v70-2A: legacy total not 5000'; end if;
  if (v_res->>'acknowledged_cents') is not null then raise exception 'v70-2A: acknowledged_cents should be null pre-ack'; end if;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res2 := public.preview_sv_cutover(v_biz_k);
  if position('sv_reconciliation_unclean' in (v_res2->'blocking_codes')::text)=0 then
    raise exception 'v70-2A: preview missing sv_reconciliation_unclean'; end if;

  -- (B) acknowledge EXACTLY 5000c.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res := public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,
    'owner ruling 2026-07-26: pilot legacy card honoured to extinction');
  if (v_res->>'acknowledged_cents')::int <> 5000 then raise exception 'v70-2B: acknowledgement did not record 5000'; end if;

  -- (C) after acknowledgement, reconciliation is CLEAN and readiness loses sv_reconciliation_unclean.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','remediate via acknowledgement');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'clean' then raise exception 'v70-2C: expected CLEAN after exact ack, got %', v_res; end if;
  if (v_res->>'discrepancy_count')::int <> 0 then raise exception 'v70-2C: discrepancy_count not 0'; end if;
  if (v_res->>'acknowledged_cents')::int <> 5000 then raise exception 'v70-2C: snapshot acknowledged_cents not 5000'; end if;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res2 := public.preview_sv_cutover(v_biz_k);
  if position('sv_reconciliation_unclean' in (v_res2->'blocking_codes')::text)<>0 then
    raise exception 'v70-2C: sv_reconciliation_unclean should be gone after ack'; end if;

  -- (D) FULL v69 readiness passes: super-admin designates K; automation is scheduled on the chain.
  perform pg_temp.as_v70(v_sa,'authenticated');
  perform public.set_sv_cutover_designation(v_biz_k,true,'v70 pilot readiness proof designation');
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res2 := public.preview_sv_cutover(v_biz_k);
  if (v_res2->>'ready')::boolean is not true then
    raise exception 'v70-2D: readiness did not pass after acknowledgement: %', v_res2->'blocking_codes'; end if;

  -- (E) DRIFT UP - a NEW card grows the outstanding total to 6000 vs acknowledged 5000 -> re-dirty.
  reset role;
  insert into public.gift_cards(business_id,code,initial_cents,balance_cents,status)
  values (v_biz_k,'V70-KOPI-2',1000,1000,'active');
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','drift-up test');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v70-2E: expected blocked on drift up'; end if;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res2 := public.get_sv_reconciliation(v_biz_k);
  select d into v_drift from jsonb_array_elements(v_res2->'discrepancies') d
    where d->>'category'='acknowledgement_drift';
  if v_drift is null then raise exception 'v70-2E: no acknowledgement_drift row on drift up'; end if;
  if (v_drift->>'delta_cents')::int <> 1000 then raise exception 'v70-2E: drift delta not +1000 (got %)', v_drift->>'delta_cents'; end if;
  if (v_drift->'detail'->>'direction') <> 'legacy_exceeds_acknowledgement' then raise exception 'v70-2E: wrong direction'; end if;

  -- (F) DRIFT DOWN - void the new card and PARTIAL-REDEEM the first to 3000 -> total 3000 vs 5000.
  reset role;
  update public.gift_cards set balance_cents=0, status='void' where business_id=v_biz_k and code='V70-KOPI-2';
  update public.gift_cards set balance_cents=3000 where business_id=v_biz_k and code='V70-KOPI-1';
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','drift-down test');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v70-2F: expected blocked on drift down'; end if;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res2 := public.get_sv_reconciliation(v_biz_k);
  select d into v_drift from jsonb_array_elements(v_res2->'discrepancies') d
    where d->>'category'='acknowledgement_drift';
  if v_drift is null or (v_drift->>'delta_cents')::int <> -2000 then
    raise exception 'v70-2F: drift delta not -2000 (got %)', coalesce(v_drift->>'delta_cents','<none>'); end if;
  if (v_drift->'detail'->>'direction') <> 'acknowledgement_exceeds_legacy' then raise exception 'v70-2F: wrong direction'; end if;

  -- (G) DRIFT TO ZERO - the card is fully redeemed; ack 5000 now exceeds outstanding 0 -> still dirty.
  reset role;
  update public.gift_cards set balance_cents=0, status='redeemed' where business_id=v_biz_k and code='V70-KOPI-1';
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','drift-to-zero test');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v70-2G: over-acknowledged (0 outstanding) must stay blocked'; end if;

  -- (H) RE-ACKNOWLEDGE the new amount (0) -> clean again (acknowledgement is a specific statement).
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.acknowledge_legacy_value(v_biz_k,'stored_value',0,'re-acknowledge: card redeemed to extinction');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','remediate via re-acknowledgement');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'clean' then raise exception 'v70-2H: expected clean after re-ack to 0'; end if;

  -- (I) AMOUNT-SPECIFIC: restore the card to 5000, acknowledge 4999 (off by one) -> NOT clean.
  reset role;
  update public.gift_cards set balance_cents=5000, status='active' where business_id=v_biz_k and code='V70-KOPI-1';
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.acknowledge_legacy_value(v_biz_k,'stored_value',4999,'deliberately off-by-one acknowledgement');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','off-by-one test');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v70-2I: 4999 must NOT net 5000 (amount-specific)'; end if;
  -- and 5000 exactly nets again.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'re-acknowledge the exact 5000');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','re-clean');
  v_res := public.run_sv_reconciliation(v_biz_k);
  perform pg_temp.v70_pin_snapshot(v_biz_k,(v_res->>'snapshot_id')::uuid);
  if (v_res->>'reconciliation_status') <> 'clean' then raise exception 'v70-2I: exact 5000 must net clean'; end if;

  -- ============================ PART 3: mechanism auth / validation / immutability ============================
  -- acknowledge_legacy_value: super-admin may acknowledge; frontdesk and anon may not.
  perform pg_temp.as_v70(v_sa,'authenticated');
  perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'super-admin may acknowledge legacy value');
  perform pg_temp.as_v70(v_fd,'authenticated');
  begin perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'frontdesk must be refused here');
    raise exception 'v70-3: frontdesk was allowed to acknowledge'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v70(null,'anon');
  begin perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'anon must be refused here');
    raise exception 'v70-3: anon was allowed to acknowledge'; exception when others then null; end;
  -- validation: short reason, negative cents.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  begin perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'short');
    raise exception 'v70-3: short reason accepted'; exception when sqlstate '22023' then null; end;
  begin perform public.acknowledge_legacy_value(v_biz_k,'stored_value',-1,'negative amount must be refused');
    raise exception 'v70-3: negative cents accepted'; exception when sqlstate '22023' then null; end;

  -- append-only immutability + browser-DML denial on sv_legacy_acknowledgements.
  reset role;
  select id into v_ack_id from public.sv_legacy_acknowledgements where business_id=v_biz_k order by created_at desc, id desc limit 1;
  begin update public.sv_legacy_acknowledgements set acknowledged_cents=1 where id=v_ack_id;
    raise exception 'v70-3: acknowledgement UPDATE was allowed'; exception when sqlstate '23001' then null; end;
  begin delete from public.sv_legacy_acknowledgements where id=v_ack_id;
    raise exception 'v70-3: acknowledgement DELETE was allowed'; exception when sqlstate '23001' then null; end;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  begin insert into public.sv_legacy_acknowledgements(business_id,asset,acknowledged_cents,reason)
        values (v_biz_k,'stored_value',1,'browser insert must be denied');
    raise exception 'v70-3: browser INSERT into acknowledgements was allowed'; exception when sqlstate '42501' then null; end;

  -- classify_legacy_business: super-admin only; owner refused; invalid value refused; records a row.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  begin perform public.classify_legacy_business(v_biz_k,'pilot','owner must not classify their own legacy');
    raise exception 'v70-3: owner was allowed to classify'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v70(v_sa,'authenticated');
  begin perform public.classify_legacy_business(v_biz_k,'bogus','invalid classification value here');
    raise exception 'v70-3: invalid classification accepted'; exception when sqlstate '22023' then null; end;
  v_res := public.classify_legacy_business(v_biz_k,'pilot','kopi tiam is the pilot; honour to extinction');
  if (v_res->>'classification') <> 'pilot' then raise exception 'v70-3: classification not recorded'; end if;
  -- classification is append-only.
  reset role;
  begin update public.sv_legacy_classifications set classification='qa_reset' where business_id=v_biz_k;
    raise exception 'v70-3: classification UPDATE allowed'; exception when sqlstate '23001' then null; end;

  -- inventory RPC: owner sees own; super-admin sees platform-wide; a non-member is refused.
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  v_res := public.get_legacy_value_inventory(v_biz_k);
  if jsonb_array_length(v_res) <> 1 then raise exception 'v70-3: owner inventory should return exactly their business'; end if;
  if (v_res->0->>'classification') <> 'pilot' then raise exception 'v70-3: inventory classification not surfaced'; end if;
  if (v_res->0->>'gift_card_total_cents')::int <> 5000 then raise exception 'v70-3: inventory gift_card_total not 5000'; end if;
  begin perform public.get_legacy_value_inventory(null);
    raise exception 'v70-3: non-super-admin allowed platform-wide inventory'; exception when sqlstate '42501' then null; end;
  begin perform public.get_legacy_value_inventory(v_biz_l);
    raise exception 'v70-3: owner_k allowed to read another business inventory'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v70(v_sa,'authenticated');
  v_res := public.get_legacy_value_inventory(null);
  if jsonb_array_length(v_res) < 2 then raise exception 'v70-3: super-admin platform inventory should include K and L'; end if;

  -- ============================ PART 4: no value moved ============================
  -- Bracket ONE acknowledge+reconcile pair with a gift_cards md5 to prove v70's functions move no
  -- legacy value (the drift edits above were deliberate direct SQL, not v70 paths).
  reset role;
  select md5(coalesce(string_agg(g::text,'|' order by g.id),'')) into v_md5_gc
    from public.gift_cards g where g.business_id=v_biz_k;
  perform pg_temp.as_v70(v_owner_k,'authenticated');
  perform public.acknowledge_legacy_value(v_biz_k,'stored_value',5000,'part 4 no-value-moved bracket');
  perform public.set_sv_authority_state(v_biz_k,'stored_value','shadow_testing','part 4 bracket');
  v_res := public.run_sv_reconciliation(v_biz_k);
  reset role;
  select md5(coalesce(string_agg(g::text,'|' order by g.id),'')) into v_md5_gc2
    from public.gift_cards g where g.business_id=v_biz_k;
  if v_md5_gc <> v_md5_gc2 then
    raise exception 'v70-4: acknowledge_legacy_value / run_sv_reconciliation mutated gift_cards (moved value)'; end if;
  -- No sv_lot_movements were EVER created for K across the whole suite (started at, and stays at, the baseline).
  select count(*) into v_mv_after from public.sv_lot_movements where business_id=v_biz_k;
  if v_mv_after <> v_mv_before then raise exception 'v70-4: a v70 path created sv_lot_movements (moved value)'; end if;
  -- kopi tiam's card is intact at 5000c.
  if (select balance_cents from public.gift_cards where business_id=v_biz_k and code='V70-KOPI-1') <> 5000 then
    raise exception 'v70-4: the pilot $50 card is not intact at 5000c'; end if;

  raise notice 'V70 SUITE PASS';
end
$v70_test$;

rollback;
