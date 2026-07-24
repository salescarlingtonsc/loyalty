-- Rollback-only v65a hardening suite. Run after the chain through v65a in a disposable rehearsal DB.
-- Covers directive P2.5: complete idempotency hashes (same key + changed field -> conflict; identical
-- request -> exact replay, no duplicate rows), typed plan_id/int4/empty-category validation, the plan
-- display-name contract, and zero value/authority side-effects. The including txn owns BEGIN/ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v65a(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if p_role='anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_v65a(uuid,text) to authenticated, anon;

do $v65a$
declare
  A uuid; A_owner uuid;
  d uuid; d2 uuid; d3 uuid; res jsonb; pub jsonb; cres jsonb; ures jsonb; r jsonb;
  plan uuid; ver1 uuid; ver2 uuid; ver1_snap text;
  pk uuid := gen_random_uuid(); dk uuid := gen_random_uuid(); rk uuid := gen_random_uuid(); ak uuid := gen_random_uuid();
  v_moves int; v_lots int; v_auth text; n int;
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  if A is null then raise exception 'need pristine fixture A'; end if;
  select count(*) into v_moves from public.sv_lot_movements where business_id=A;
  select count(*) into v_lots  from public.sv_lots where business_id=A;

  perform pg_temp.as_v65a(A_owner,'authenticated');

  ---------------------------------------------------------------- 2. malformed plan_id -> typed 22023
  begin perform public.create_sv_plan_draft(A, '{"plan_id":"not-a-uuid"}'::jsonb, gen_random_uuid());
    raise exception 'malformed plan_id accepted'; exception when others then assert sqlstate='22023','plan_id 22023 got '||sqlstate; end;
  ---------------------------------------------------------------- 4a. cents beyond int4 -> typed 22023 (not 22003)
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":9999999999}'::jsonb, gen_random_uuid());
    raise exception 'oversized price accepted'; exception when others then assert sqlstate='22023','int4 22023 got '||sqlstate; end;
  ---------------------------------------------------------------- 4b. whitespace-only category array -> typed rejection
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":100,"eligible_service_categories":["  "," "]}'::jsonb, gen_random_uuid());
    raise exception 'blank category accepted'; exception when others then assert sqlstate='22023','blank cat 22023 got '||sqlstate; end;

  ---------------------------------------------------------------- publishable draft (Alpha)
  res := public.create_sv_plan_draft(A, jsonb_build_object(
    'customer_facing_name','Alpha','price_cents',10000,'bonus_cents',1000,'customer_terms','1 year, no cash out'), gen_random_uuid());
  d := (res->>'draft_id')::uuid;

  ---------------------------------------------------------------- 1a. publish same key + same request -> exact replay, no dup
  pub := public.publish_sv_plan_version(A, d, 0, pk, 'r1');
  ver1 := (pub->>'version_id')::uuid; plan := (pub->>'plan_id')::uuid;
  r := public.publish_sv_plan_version(A, d, 0, pk, 'r1');            -- identical -> replay original result
  assert (r->>'version_id')::uuid = ver1, 'publish identical replay same version';
  select count(*) into n from public.sv_plan_versions where plan_id=plan and business_id=A; assert n=1, 'exactly one version';
  select count(*) into n from public.sv_plan_operations where business_id=A and op_type='publish' and idempotency_key=pk; assert n=1, 'one publish op';
  select count(*) into n from public.audit_log where business_id=A and action='SV_PLAN_PUBLISHED' and entity_id=ver1; assert n=1, 'one publish audit';

  ---------------------------------------------------------------- 1b/1c. publish same key + changed field -> conflict
  begin perform public.publish_sv_plan_version(A, d, 0, pk, 'r2');   -- changed override reason
    raise exception 'changed reason not conflicted'; exception when others then assert sqlstate='22023','publish reason conflict'; end;
  begin perform public.publish_sv_plan_version(A, d, 5, pk, 'r1');   -- changed expected_revision
    raise exception 'changed revision not conflicted'; exception when others then assert sqlstate='22023','publish revision conflict'; end;

  ---------------------------------------------------------------- 3. rename: clone Alpha -> Beta, sv_plans.name tracks; ver1 immutable
  select md5(pv::text) into ver1_snap from public.sv_plan_versions pv where id=ver1;
  cres := public.clone_sv_plan_version_to_draft(A, ver1, gen_random_uuid());
  d2 := (cres->>'draft_id')::uuid;
  ures := public.update_sv_plan_draft(A, d2, '{"customer_facing_name":"Beta"}'::jsonb, (cres->>'revision')::int);
  pub := public.publish_sv_plan_version(A, d2, (ures->>'revision')::int, gen_random_uuid(), null);
  ver2 := (pub->>'version_id')::uuid;
  assert (select name from public.sv_plans where id=plan) = 'Beta', 'sv_plans.name tracks latest version';
  assert exists(select 1 from public.audit_log where business_id=A and action='SV_PLAN_RENAMED' and entity_id=plan
    and detail->>'old_name'='Alpha' and detail->>'new_name'='Beta'), 'rename audit old/new';
  assert (select md5(pv::text) from public.sv_plan_versions pv where id=ver1) = ver1_snap, 'ver1 snapshot byte-unchanged by rename';
  assert (select customer_facing_name from public.sv_plan_versions where id=ver2) = 'Beta', 'ver2 carries Beta';
  assert (select customer_facing_name from public.sv_plan_versions where id=ver1) = 'Alpha', 'ver1 still Alpha (immutable)';

  ---------------------------------------------------------------- 1d. discard same key + changed reason -> conflict; identical -> replay
  res := public.create_sv_plan_draft(A, '{"customer_facing_name":"tmp","price_cents":100}'::jsonb, gen_random_uuid());
  d3 := (res->>'draft_id')::uuid;
  r := public.discard_sv_plan_draft(A, d3, (res->>'revision')::int, dk, 'dr1');
  assert (r->>'discarded')::boolean, 'discarded';
  begin perform public.discard_sv_plan_draft(A, d3, (res->>'revision')::int, dk, 'dr2');
    raise exception 'discard changed reason not conflicted'; exception when others then assert sqlstate='22023','discard reason conflict'; end;
  r := public.discard_sv_plan_draft(A, d3, (res->>'revision')::int, dk, 'dr1');   -- identical -> replay
  assert (r->>'discarded')::boolean, 'discard identical replay';
  select count(*) into n from public.sv_plan_operations where business_id=A and op_type='discard' and idempotency_key=dk; assert n=1, 'one discard op';

  ---------------------------------------------------------------- 1e/1f. retire + reactivate same key + changed reason -> conflict
  r := public.retire_sv_plan(A, plan, 'rr1 end promo', rk);
  assert not (r->>'active')::boolean, 'retired';
  begin perform public.retire_sv_plan(A, plan, 'rr2 different', rk);
    raise exception 'retire changed reason not conflicted'; exception when others then assert sqlstate='22023','retire reason conflict'; end;
  r := public.reactivate_sv_plan(A, plan, 'ar1 back', ak);
  assert (r->>'active')::boolean, 'reactivated';
  begin perform public.reactivate_sv_plan(A, plan, 'ar2 different', ak);
    raise exception 'reactivate changed reason not conflicted'; exception when others then assert sqlstate='22023','reactivate reason conflict'; end;
  -- exactly one status event per real transition (created + retired + active = 3); conflicts wrote none
  select count(*) into n from public.sv_plan_status_events where business_id=A and plan_id=plan; assert n=3, 'three status events, got '||n;

  ---------------------------------------------------------------- SAFETY: zero value moved, authority unchanged
  reset role;
  assert (select count(*) from public.sv_lot_movements where business_id=A) = v_moves, 'no movements written';
  assert (select count(*) from public.sv_lots where business_id=A) = v_lots, 'no lots written';
  select state into v_auth from public.sv_authority where business_id=A and asset='stored_value';
  assert v_auth = 'unbuilt', 'authority stayed unbuilt, got '||coalesce(v_auth,'null');

  raise notice 'V65A SUITE PASS (all assertions)';
end $v65a$;
rollback;
