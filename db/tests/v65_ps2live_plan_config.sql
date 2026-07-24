-- Rollback-only v65 PS-2 LIVE Increment 1 (top-up plan configuration) suite.
-- Run after the chain through v65 in a disposable rehearsal database. The including transaction owns
-- BEGIN/ROLLBACK; nothing commits. Covers directive Sec 15:
--   retirement without mutating versions; reactivation lifecycle; zero-price typed rejection;
--   aggressive-paid override; guardrail edit; unknown config key; malformed JSON types; JSON-null
--   clearing; array canonicalisation; cross-tenant eligibility; inactive references; stale-editor
--   conflict; one-draft-one-version; clone-to-draft; discard; retired-plan publish denial;
--   purchase-window pair; impossible max-balance blocker; full read-shape round trip; double-click
--   idempotency; and zero sv lots/movements/authority change from every configuration action.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v65(p_uid uuid, p_role text)
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
grant execute on function pg_temp.as_v65(uuid,text) to authenticated, anon;

do $v65$
declare
  A uuid; A_owner uuid; B uuid; B_owner uuid;
  A_svc1 uuid; A_svc2 uuid; A_svc_inactive uuid; B_svc uuid;
  d uuid; d2 uuid; res jsonb; prev jsonb; pub jsonb; plans jsonb; ver uuid; ver_snapshot text;
  k uuid; v_rev int; v_moves int; v_lots int; v_auth text; v_plan uuid; ok boolean;
begin
  ----------------------------------------------------------------- fixtures
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;
  if A is null or B is null then raise exception 'need pristine fixtures A + B'; end if;
  insert into public.services(business_id,name,price_cents,duration_min,active,category) values (A,'A Cut',5000,30,true,'Hair') returning id into A_svc1;
  insert into public.services(business_id,name,price_cents,duration_min,active,category) values (A,'A Colour',9000,60,true,'Hair') returning id into A_svc2;
  insert into public.services(business_id,name,price_cents,duration_min,active,category) values (A,'A Retired',3000,30,false,'Old') returning id into A_svc_inactive;
  insert into public.services(business_id,name,price_cents,duration_min,active,category) values (B,'B Cut',5000,30,true,'Hair') returning id into B_svc;
  select count(*) into v_moves from public.sv_lot_movements where business_id=A;
  select count(*) into v_lots  from public.sv_lots where business_id=A;

  perform pg_temp.as_v65(A_owner,'authenticated');

  ----------------------------------------------------------------- 6. unknown config key rejected
  begin perform public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','x','nope',1), gen_random_uuid());
    raise exception 'unknown-key not rejected'; exception when others then assert sqlstate='22023','unknown key ('||sqlstate||')'; end;
  ----------------------------------------------------------------- 7. malformed JSON types rejected
  begin perform public.create_sv_plan_draft(A, '{"price_cents":"abc"}'::jsonb, gen_random_uuid());
    raise exception 'string price not rejected'; exception when others then assert sqlstate='22023','string price'; end;
  begin perform public.create_sv_plan_draft(A, '{"topup_purchase_earns_points":1}'::jsonb, gen_random_uuid());
    raise exception 'numeric bool not rejected'; exception when others then assert sqlstate='22023','numeric bool'; end;
  begin perform public.create_sv_plan_draft(A, '{"price_cents":10.5}'::jsonb, gen_random_uuid());
    raise exception 'non-integer price not rejected'; exception when others then assert sqlstate='22023','non-integer price'; end;
  begin perform public.create_sv_plan_draft(A, '{"eligible_service_ids":[]}'::jsonb, gen_random_uuid());
    raise exception 'empty array not rejected'; exception when others then assert sqlstate='22023','empty array'; end;

  ----------------------------------------------------------------- create + array canonicalisation (9)
  res := public.create_sv_plan_draft(A, jsonb_build_object(
    'customer_facing_name','$100 pack','price_cents',10000,'bonus_cents',1000,'paid_expiry_days',365,
    'bonus_expiry_days',90,'customer_terms','Valid for 1 year. No cash out.','max_balance_cents',50000,
    'eligible_service_ids', jsonb_build_array(A_svc2::text, A_svc1::text, A_svc2::text)), gen_random_uuid());
  d := (res->>'draft_id')::uuid;
  assert (res->>'effective_discount_bps')::int = 909, 'disc 909 got '||(res->>'effective_discount_bps');
  -- dedupe (3 -> 2) + sorted ascending
  assert (select cardinality(eligible_service_ids)=2 from public.sv_plan_drafts where id=d), 'dedupe to 2';
  assert (select eligible_service_ids = (select array(select unnest(eligible_service_ids) order by 1)) from public.sv_plan_drafts where id=d), 'sorted';

  ----------------------------------------------------------------- 8. JSON-null clears nullable; non-nullable null errors
  v_rev := (res->>'revision')::int;
  res := public.update_sv_plan_draft(A, d, '{"paid_expiry_days":null}'::jsonb, v_rev);
  assert (res->>'paid_expiry_days') is null, 'paid_expiry cleared';
  v_rev := (res->>'revision')::int;
  begin perform public.update_sv_plan_draft(A, d, '{"price_cents":null}'::jsonb, v_rev);
    raise exception 'null price accepted'; exception when others then assert sqlstate='22023','null price'; end;

  ----------------------------------------------------------------- 12. stale-editor conflict
  begin perform public.update_sv_plan_draft(A, d, '{"bonus_cents":2000}'::jsonb, v_rev - 1);
    raise exception 'stale revision accepted'; exception when others then assert sqlstate='22023','stale revision'; end;
  res := public.update_sv_plan_draft(A, d, '{"bonus_cents":2000}'::jsonb, v_rev);  -- correct revision
  assert (res->>'effective_discount_bps')::int = 1667, 'disc 1667';
  v_rev := (res->>'revision')::int;

  ----------------------------------------------------------------- 11. preview separates errors/warnings; publishable
  prev := public.preview_sv_plan(A, d);
  assert (prev->>'publishable')::boolean = true, 'publishable true';
  assert jsonb_array_length(prev->'validation_errors') = 0, 'no errors';
  assert (prev->>'override_required')::boolean = false, 'no override at 16.67%';

  ----------------------------------------------------------------- publish + idempotency (21) + numbering
  k := gen_random_uuid();
  pub := public.publish_sv_plan_version(A, d, v_rev, k, null);
  ver := (pub->>'version_id')::uuid;
  assert (pub->>'version_no')::int = 1 and (pub->>'replayed')::boolean = false, 'first publish v1';
  -- same key -> idempotent envelope returns the identical original result (same version)
  pub := public.publish_sv_plan_version(A, d, v_rev, k, null);
  assert (pub->>'version_id')::uuid = ver, 'publish same-key idempotent';
  -- different key on an already-published draft -> draft-status replay flag, no new version
  pub := public.publish_sv_plan_version(A, d, v_rev, gen_random_uuid(), null);
  assert (pub->>'replayed')::boolean = true and (pub->>'version_id')::uuid = ver, 'already-published draft replays';
  select plan_id into v_plan from public.sv_plan_drafts where id=d;

  -- immutable version carries the full snapshot
  assert (select paid_expiry_days is null and bonus_expiry_days=90 and max_balance_cents=50000
                 and spend_order='proportional' and customer_terms is not null
          from public.sv_plan_versions where id=ver), 'version snapshot';
  select md5(pv::text) into ver_snapshot from public.sv_plan_versions pv where id=ver;   -- byte snapshot for later

  ----------------------------------------------------------------- 14. one draft cannot mint two versions
  reset role;
  begin
    insert into public.sv_plan_versions(business_id,plan_id,version_no,price_cents,bonus_cents,expiry_days,terms_snapshot,source_draft_id)
    values (A, v_plan, 99, 100, 0, null, '{}'::jsonb, d);
    raise exception 'second version from same draft accepted'; exception when others then assert sqlstate='23505','one-draft-one-version ('||sqlstate||')'; end;
  perform pg_temp.as_v65(A_owner,'authenticated');

  ----------------------------------------------------------------- 2. zero-price typed rejection (not raw CHECK)
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Free','price_cents',0,'bonus_cents',5000,'customer_terms','t'), gen_random_uuid());
  d2 := (res->>'draft_id')::uuid;
  prev := public.preview_sv_plan(A, d2);
  assert (prev->>'publishable')::boolean = false, 'zero-price not publishable';
  begin perform public.publish_sv_plan_version(A, d2, (res->>'revision')::int, gen_random_uuid(), null);
    raise exception 'zero-price published'; exception when others then assert sqlstate='22023','zero price typed'; end;

  ----------------------------------------------------------------- 18/19. window pair + impossible max-balance
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','P','price_cents',10000,'bonus_cents',0,'customer_terms','t','purchase_window_days',30), gen_random_uuid());
  prev := public.preview_sv_plan(A, (res->>'draft_id')::uuid);
  assert (prev->'validation_errors')::text ilike '%window%', 'window pair error';
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','P','price_cents',10000,'bonus_cents',2000,'customer_terms','t','max_balance_cents',500), gen_random_uuid());
  prev := public.preview_sv_plan(A, (res->>'draft_id')::uuid);
  assert (prev->'validation_errors')::text ilike '%maximum balance%', 'impossible max-balance error';

  ----------------------------------------------------------------- 10/11. cross-tenant + inactive eligibility
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','P','price_cents',10000,'bonus_cents',0,'customer_terms','t',
    'eligible_service_ids', jsonb_build_array(B_svc::text)), gen_random_uuid());
  prev := public.preview_sv_plan(A, (res->>'draft_id')::uuid);
  assert (prev->'validation_errors')::text ilike '%do not belong%', 'cross-tenant service error';
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','P','price_cents',10000,'bonus_cents',0,'customer_terms','t',
    'eligible_service_ids', jsonb_build_array(A_svc_inactive::text)), gen_random_uuid());
  prev := public.preview_sv_plan(A, (res->>'draft_id')::uuid);
  assert (prev->'validation_errors')::text ilike '%inactive%', 'inactive service error';

  ----------------------------------------------------------------- 4/5. guardrail edit + aggressive override
  perform public.set_sv_plan_guardrails(A, 2000, 4000, gen_random_uuid());
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Half','price_cents',5000,'bonus_cents',5000,'customer_terms','t'), gen_random_uuid());
  d2 := (res->>'draft_id')::uuid; v_rev := (res->>'revision')::int;
  prev := public.preview_sv_plan(A, d2);
  assert (prev->>'override_required')::boolean = true, 'override required at 50% vs 40% hard';
  begin perform public.publish_sv_plan_version(A, d2, v_rev, gen_random_uuid(), null);
    raise exception 'override missing accepted'; exception when others then assert sqlstate='22023','override required'; end;
  pub := public.publish_sv_plan_version(A, d2, v_rev, gen_random_uuid(), 'owner-approved launch loss-leader');
  assert (pub->>'override_applied')::boolean = true, 'override recorded';
  -- guardrail idempotency
  k := gen_random_uuid();
  assert public.set_sv_plan_guardrails(A, 1000, 5000, k) = public.set_sv_plan_guardrails(A, 1000, 5000, k), 'guardrail idempotent';
  begin perform public.set_sv_plan_guardrails(A, 9000, 3000, gen_random_uuid());
    raise exception 'warn>hard accepted'; exception when others then assert sqlstate='22023','warn<=hard'; end;

  ----------------------------------------------------------------- 1/3/15/17. retire w/o mutating version, clone, retired-publish denial, reactivate
  perform public.retire_sv_plan(A, v_plan, 'end of promo', gen_random_uuid());
  assert (select not active from public.sv_plans where id=v_plan), 'plan retired';
  assert (select md5(pv::text) from public.sv_plan_versions pv where id=ver) = ver_snapshot, 'version byte-unchanged by retire';
  assert exists(select 1 from public.sv_plan_status_events where plan_id=v_plan and new_status='retired'), 'retire event';
  -- clone the retired plan's version to a new draft, then publishing must be DENIED until reactivate
  res := public.clone_sv_plan_version_to_draft(A, ver, gen_random_uuid());
  d2 := (res->>'draft_id')::uuid;
  assert (res->>'plan_id')::uuid = v_plan, 'clone bound to plan';
  assert (res->>'customer_facing_name') = '$100 pack', 'clone copied config';
  begin perform public.publish_sv_plan_version(A, d2, (res->>'revision')::int, gen_random_uuid(), null);
    raise exception 'published under retired plan'; exception when others then assert sqlstate='22023','retired-plan publish denied'; end;
  perform public.reactivate_sv_plan(A, v_plan, 'promo returns', gen_random_uuid());
  assert (select active from public.sv_plans where id=v_plan), 'reactivated';
  pub := public.publish_sv_plan_version(A, d2, (res->>'revision')::int, gen_random_uuid(), null);
  assert (pub->>'version_no')::int = 2, 'second version after reactivate';

  ----------------------------------------------------------------- 16. discard
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','tmp','price_cents',100), gen_random_uuid());
  d2 := (res->>'draft_id')::uuid;
  perform public.discard_sv_plan_draft(A, d2, (res->>'revision')::int, gen_random_uuid(), 'not needed');
  begin perform public.update_sv_plan_draft(A, d2, '{"price_cents":200}'::jsonb, 0);
    raise exception 'edited discarded draft'; exception when others then assert sqlstate='22023' or sqlstate='restrict_violation', 'discarded frozen ('||sqlstate||')'; end;

  ----------------------------------------------------------------- 20. complete read shape + status history + guardrails
  plans := public.get_sv_plans(A);
  assert jsonb_array_length(plans->'plans') >= 1, 'plans listed';
  assert (plans->'guardrails'->>'hard_discount_bps')::int = 5000, 'guardrail in read';
  assert (select (v->>'customer_terms') is not null and (v ? 'refund_policy') and (v ? 'eligible_service_ids')
                 and (v ? 'topup_purchase_earns_points') and (v ? 'stored_value_spend_earns_points')
          from jsonb_array_elements(plans->'plans'->0->'versions') v limit 1), 'complete version shape';
  assert (select jsonb_array_length(p->'status_history') >= 1 from jsonb_array_elements(plans->'plans') p
          where (p->>'plan_id')::uuid = v_plan limit 1), 'status history present';

  ----------------------------------------------------------------- create/publish double-click idempotency (14/21)
  k := gen_random_uuid();
  assert public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','dup','price_cents',100), k)
       = public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','dup','price_cents',100), k), 'create idempotent';

  ----------------------------------------------------------------- owner-only + anon denial
  perform pg_temp.as_v65(gen_random_uuid(),'authenticated');
  begin perform public.create_sv_plan_draft(A,'{}'::jsonb,gen_random_uuid());
    raise exception 'non-owner allowed'; exception when others then assert sqlstate='42501','non-owner 42501'; end;
  perform pg_temp.as_v65(null,'anon');
  begin perform public.get_sv_plans(A); raise exception 'anon allowed';
    exception when others then assert sqlstate='42501','anon 42501'; end;

  ----------------------------------------------------------------- SAFETY: zero value + authority unchanged from all config actions
  reset role;
  assert (select count(*) from public.sv_lot_movements where business_id=A) = v_moves, 'no movements written';
  assert (select count(*) from public.sv_lots where business_id=A) = v_lots, 'no lots written';
  select state into v_auth from public.sv_authority where business_id=A and asset='stored_value';
  assert v_auth = 'unbuilt', 'authority stayed unbuilt, got '||coalesce(v_auth,'null');

  raise notice 'V65 SUITE PASS (all assertions)';
end $v65$;
rollback;
