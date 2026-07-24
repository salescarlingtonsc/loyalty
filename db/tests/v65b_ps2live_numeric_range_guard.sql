-- Rollback-only v65b suite: numeric-safe integer range guard. Run after the chain through v65b in a
-- disposable rehearsal DB. Proves every out-of-int4-range integer -> typed 22023 (never raw 22003),
-- in-range values keep current behaviour, on BOTH the price/bonus and nullable-int cast sites, with
-- zero value/authority side effects. The including txn owns BEGIN/ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v65b(p_uid uuid, p_role text)
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
grant execute on function pg_temp.as_v65b(uuid,text) to authenticated, anon;

do $v65b$
declare
  A uuid; A_owner uuid; res jsonb; v_moves int; v_lots int; v_auth text; v_state text;
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  if A is null then raise exception 'need pristine fixture A'; end if;
  select count(*) into v_moves from public.sv_lot_movements where business_id=A;
  select count(*) into v_lots  from public.sv_lots where business_id=A;
  perform pg_temp.as_v65b(A_owner,'authenticated');

  -- in-range: int4 max accepted where otherwise valid
  res := public.create_sv_plan_draft(A, '{"customer_facing_name":"max","price_cents":2147483647}'::jsonb, gen_random_uuid());
  assert (res->>'price_cents')::bigint = 2147483647, 'int4 max accepted';

  -- int4_max + 1 -> 22023 (price path)
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":2147483648}'::jsonb, gen_random_uuid());
    raise exception '2147483648 accepted'; exception when others then assert sqlstate='22023','2147483648 -> '||sqlstate; end;

  -- below int4 min -> 22023 (negative guard, never overflow)
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":-2147483649}'::jsonb, gen_random_uuid());
    raise exception '-2147483649 accepted'; exception when others then assert sqlstate='22023','-2147483649 -> '||sqlstate; end;

  -- bigint_max + 1 -> 22023 (the fix: used to be raw 22003) on the PRICE path
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":9223372036854775808}'::jsonb, gen_random_uuid());
    raise exception 'bigint+1 price accepted'; exception when others then assert sqlstate='22023','bigint+1 price MUST be 22023 not '||sqlstate; end;

  -- bigint_max + 1 -> 22023 on the NULLABLE-INT path (max_balance_cents), proving both cast sites are numeric-safe
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":100,"max_balance_cents":9223372036854775808}'::jsonb, gen_random_uuid());
    raise exception 'bigint+1 max_balance accepted'; exception when others then assert sqlstate='22023','bigint+1 max_balance MUST be 22023 not '||sqlstate; end;

  -- arbitrarily larger integer -> 22023
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":99999999999999999999999999999999}'::jsonb, gen_random_uuid());
    raise exception 'huge int accepted'; exception when others then assert sqlstate='22023','huge int MUST be 22023 not '||sqlstate; end;

  -- also on a positive-only nullable field (paid_expiry_days) beyond bigint -> 22023
  begin perform public.create_sv_plan_draft(A, '{"customer_facing_name":"x","price_cents":100,"paid_expiry_days":9223372036854775808}'::jsonb, gen_random_uuid());
    raise exception 'bigint+1 expiry accepted'; exception when others then assert sqlstate='22023','bigint+1 expiry MUST be 22023 not '||sqlstate; end;

  -- SAFETY: zero value moved, authority unchanged
  reset role;
  assert (select count(*) from public.sv_lot_movements where business_id=A) = v_moves, 'no movements';
  assert (select count(*) from public.sv_lots where business_id=A) = v_lots, 'no lots';
  select state into v_auth from public.sv_authority where business_id=A and asset='stored_value';
  assert v_auth = 'unbuilt', 'authority stayed unbuilt, got '||coalesce(v_auth,'null');

  raise notice 'V65B SUITE PASS (all assertions)';
end $v65b$;
rollback;
