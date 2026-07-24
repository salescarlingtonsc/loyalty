-- Rollback-only v66b suite: v_program_rules_all must be SECURITY INVOKER, without breaking the real
-- (SECURITY DEFINER RPC) consumer path. Run after the chain through v66b in a disposable rehearsal DB.
-- Proves:
--   (1) structural: reloption security_invoker=true present; the in-body owner-or-SA WHERE predicate
--       is still in the definition (v66b changed only the reloption);
--   (2) DIRECT reads by API roles are now DENIED OUTRIGHT (42501): birthday_program_versions has no
--       authenticated table grant, so the invoker privilege check fails for any direct view read —
--       for a plain tenant owner AND for a super admin (grants are role-based). This is the deliberate
--       fail-closed outcome documented in the migration header;
--   (3) RPC parity: get_programs_overview (SECURITY DEFINER — the sanctioned consumer) still returns
--       the points_loyalty rule for owner A, unaffected by the invoker flip.
-- Config/DDL only: zero value writes, sv_authority untouched. The including txn owns BEGIN/ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v66b(p_uid uuid, p_role text)
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
grant execute on function pg_temp.as_v66b(uuid,text) to authenticated, anon;

do $v66b$
declare
  A uuid; B uuid; A_owner uuid; B_owner uuid; v_reloptions text; v_def text;
  n int; ov jsonb; v_auth text;
begin
  reset role;
  select id into A from public.businesses where name='Pristine chain fixture A';
  select id into B from public.businesses where name='Pristine chain fixture B';
  if A is null or B is null then raise exception 'need pristine fixtures A and B'; end if;
  select user_id into A_owner from public.staff where business_id=A and role='owner' and user_id is not null limit 1;
  select user_id into B_owner from public.staff where business_id=B and role='owner' and user_id is not null limit 1;

  -- (1) structural: reloption + predicate both present
  select coalesce(array_to_string(c.reloptions,','),'') into v_reloptions
    from pg_class c join pg_namespace n2 on n2.oid=c.relnamespace
    where n2.nspname='public' and c.relname='v_program_rules_all';
  assert position('security_invoker=true' in v_reloptions) > 0,
    'v_program_rules_all must carry security_invoker=true, got ['||v_reloptions||']';
  v_def := pg_get_viewdef('public.v_program_rules_all'::regclass, true);
  assert v_def ilike '%is_salon_owner%' and v_def ilike '%is_super_admin%',
    'the in-body owner-or-SA predicate must remain in the view definition';

  -- (2a) DIRECT read as plain owner A -> denied outright (privilege check on underlying tables)
  perform pg_temp.as_v66b(A_owner,'authenticated');
  begin
    select count(*) into n from public.v_program_rules_all where business_id=A;
    raise exception 'direct read as plain owner unexpectedly succeeded (%)', n;
  exception when others then
    assert sqlstate='42501', 'direct owner read must be 42501, got '||sqlstate;
  end;
  -- (2b) DIRECT read as super admin (fixture owner B) -> also denied (grants are role-based)
  perform pg_temp.as_v66b(B_owner,'authenticated');
  begin
    select count(*) into n from public.v_program_rules_all where business_id=A;
    raise exception 'direct read as super admin unexpectedly succeeded (%)', n;
  exception when others then
    assert sqlstate='42501', 'direct SA read must be 42501, got '||sqlstate;
  end;

  -- (3) RPC parity: the SECURITY DEFINER consumer still returns the loyalty rule for owner A
  perform pg_temp.as_v66b(A_owner,'authenticated');
  ov := public.get_programs_overview(A);
  assert jsonb_typeof(ov->'legacy_programs')='array', 'overview must return a legacy_programs array';
  assert exists (select 1 from jsonb_array_elements(ov->'legacy_programs') r
                  where r->>'source_engine'='points_loyalty'),
    'get_programs_overview must still surface the points_loyalty rule after the invoker flip';

  -- safety: authority untouched
  reset role;
  select state into v_auth from public.sv_authority where business_id=A and asset='stored_value';
  assert coalesce(v_auth,'unbuilt') = 'unbuilt', 'authority must stay unbuilt, got '||coalesce(v_auth,'null');

  raise notice 'V66B SUITE PASS (all assertions)';
end $v66b$;
rollback;
