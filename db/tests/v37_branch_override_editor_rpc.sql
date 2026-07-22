-- Rollback-only v37 branch override editor RPC suite. Run after v29 and v37
-- in a rehearsal database.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v37_test$
declare
  v_business uuid;
  v_owner uuid;
  v_branch uuid;
  v_base uuid;
  v_draft uuid;
  v_result jsonb;
  v_hash text;
  v_hash_after text;
  v_resolved record;
begin
  select s.business_id, s.user_id into v_business, v_owner
    from public.staff s
   where s.role = 'owner' and s.active and s.user_id is not null
   order by s.created_at
   limit 1;
  if v_business is null then
    raise exception 'v37 suite requires an active owner';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select id into v_branch
    from public.branches
   where business_id = v_business
   order by is_default desc, created_at
   limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name, is_default, active)
    values (v_business, 'v37 branch', true, true)
    returning id into v_branch;
  end if;

  select coalesce(b.active_config_version_id, lp.current_config_version_id)
    into v_base
    from public.businesses b
    join public.loyalty_programs lp on lp.business_id = b.id
   where b.id = v_business;

  v_result := public.create_loyalty_config_draft(v_business, v_base, 'v37_test')::jsonb;
  v_draft := (v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash
    from public.firm_config_versions
   where id = v_draft;

  execute 'set local role authenticated';
  begin
    insert into public.loyalty_branch_overrides(
      config_version_id, business_id, branch_id, active
    ) values (v_draft, v_business, v_branch, false);
    raise exception 'authenticated raw branch override insert unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
  reset role;

  v_result := public.save_loyalty_branch_override_draft(
    v_draft,
    v_branch,
    jsonb_build_object(
      'active', false,
      'earn_points_per_dollar', 2.5,
      'stamp_per_cents', 100,
      'expiry_mode', 'fixed',
      'expiry_days', 14
    ),
    v_hash
  )::jsonb;
  v_hash_after := v_result->>'snapshot_hash';

  if v_hash_after is null or v_hash_after = v_hash then
    raise exception 'branch override RPC did not update the snapshot hash';
  end if;

  select * into v_resolved
    from app.resolve_loyalty_branch_config(v_business, v_branch, v_draft);
  if v_resolved.source <> 'branch_override'
     or v_resolved.active is distinct from false
     or v_resolved.earn_points_per_dollar <> 2.5
     or v_resolved.stamp_per_cents <> 100
     or v_resolved.expiry_mode <> 'fixed'
     or v_resolved.expiry_days <> 14 then
    raise exception 'branch override RPC did not save resolver-visible values';
  end if;

  begin
    perform public.save_loyalty_branch_override_draft(
      v_draft,
      v_branch,
      jsonb_build_object('active', true),
      v_hash
    );
    raise exception 'stale branch override hash unexpectedly succeeded';
  exception when serialization_failure then null;
  end;

  if not exists (
    select 1 from public.loyalty_branch_overrides
     where config_version_id = v_draft
       and business_id = v_business
       and branch_id = v_branch
       and active is false
  ) then
    raise exception 'stale save changed the branch override row';
  end if;

  v_result := public.remove_loyalty_branch_override_draft(v_draft, v_branch, v_hash_after)::jsonb;
  if exists (
    select 1 from public.loyalty_branch_overrides
     where config_version_id = v_draft
       and branch_id = v_branch
  ) then
    raise exception 'remove override RPC did not delete the draft row';
  end if;

  if has_table_privilege('authenticated', 'public.loyalty_branch_overrides', 'insert')
     or has_table_privilege('authenticated', 'public.loyalty_branch_overrides', 'update')
     or has_table_privilege('authenticated', 'public.loyalty_branch_overrides', 'delete')
     or not has_function_privilege('authenticated', 'public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.remove_loyalty_branch_override_draft(uuid,uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text)', 'execute')
     or has_function_privilege('anon', 'public.remove_loyalty_branch_override_draft(uuid,uuid,text)', 'execute') then
    raise exception 'v37 branch override ACL contract is incorrect';
  end if;

  raise notice 'v37 branch override editor RPC suite: ALL PASS';
end $v37_test$;

rollback;
