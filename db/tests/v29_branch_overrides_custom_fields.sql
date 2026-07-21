-- Rollback-only v29 branch override and typed custom-field suite.
-- Run after v26, v27, v28, and v29 in a rehearsal database.
begin;

do $v29_test$
declare
  v_business uuid;
  v_owner uuid;
  v_branch uuid;
  v_other_business uuid;
  v_other_branch uuid;
  v_client uuid;
  v_base uuid;
  v_draft uuid;
  v_cloned_draft uuid;
  v_field uuid;
  v_sensitive_field uuid;
  v_option uuid;
  v_result json;
  v_resolved record;
  v_hash_before text;
  v_hash_after text;
  v_value text;
begin
  select s.business_id, s.user_id
    into v_business, v_owner
    from public.staff s
   where s.role = 'owner' and s.active and s.user_id is not null
   order by s.created_at
   limit 1;
  if v_business is null then
    raise exception 'v29 suite requires an active owner';
  end if;
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );

  select b.id into v_branch
    from public.branches b
   where b.business_id = v_business
   order by b.is_default desc, b.created_at
   limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name, is_default, active)
    values (v_business, 'v29 branch fixture', true, true)
    returning id into v_branch;
  end if;
  select c.id into v_client
    from public.clients c
   where c.business_id = v_business
   order by c.created_at
   limit 1;
  if v_client is null then
    insert into public.clients(business_id, full_name)
    values (v_business, 'v29 client fixture')
    returning id into v_client;
  end if;
  select coalesce(b.active_config_version_id, lp.current_config_version_id)
    into v_base
    from public.businesses b
    join public.loyalty_programs lp on lp.business_id = b.id
   where b.id = v_business;
  if v_base is null then
    raise exception 'v29 suite requires a config version';
  end if;

  v_result := public.create_loyalty_config_draft(v_business, v_base, 'v29_test');
  v_draft := (v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash_before
    from public.firm_config_versions where id = v_draft;

  insert into public.loyalty_branch_overrides(
    config_version_id, business_id, branch_id, active,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days
  ) values (
    v_draft, v_business, v_branch, false,
    2.5, 100, 'fixed', 14
  );
  select snapshot_hash into v_hash_after
    from public.firm_config_versions where id = v_draft;
  if v_hash_after is null or v_hash_after = v_hash_before then
    raise exception 'branch override did not change the configuration snapshot hash';
  end if;

  select * into v_resolved
    from app.resolve_loyalty_branch_config(v_business, v_branch, v_draft);
  if v_resolved.source <> 'branch_override'
     or v_resolved.active is distinct from false
     or v_resolved.earn_points_per_dollar <> 2.5
     or v_resolved.stamp_per_cents <> 100
     or v_resolved.expiry_mode <> 'fixed'
     or v_resolved.expiry_days <> 14 then
    raise exception 'branch resolver did not apply explicit branch precedence';
  end if;
  if v_resolved.redeem_points is distinct from (
       select redeem_points from public.loyalty_program_versions where config_version_id = v_draft
     ) then
    raise exception 'unsupported redeem override leaked into the resolver';
  end if;

  v_result := public.create_business(
    'v29 other tenant',
    'v29-' || substr(md5(clock_timestamp()::text), 1, 16),
    'other', array['loyalty']
  );
  v_other_business := (v_result->>'id')::uuid;
  select id into v_other_branch
    from public.branches
   where business_id = v_other_business and is_default
   limit 1;
  begin
    insert into public.loyalty_branch_overrides(
      config_version_id, business_id, branch_id, active
    ) values (v_draft, v_business, v_other_branch, true);
    raise exception 'cross-tenant branch override unexpectedly succeeded';
  exception when foreign_key_violation then
    null;
  end;

  perform public.publish_loyalty_config(v_draft);
  begin
    update public.loyalty_branch_overrides
       set active = true
     where config_version_id = v_draft and branch_id = v_branch;
    raise exception 'published branch override was mutable';
  exception when restrict_violation then
    null;
  end;

  v_result := public.create_loyalty_config_draft(v_business, v_draft, 'v29_clone_test');
  v_cloned_draft := (v_result->>'version_id')::uuid;
  if not exists (
    select 1 from public.loyalty_branch_overrides
     where config_version_id = v_cloned_draft
       and business_id = v_business
       and branch_id = v_branch
       and active is false
       and earn_points_per_dollar = 2.5
  ) then
    raise exception 'draft creation did not clone branch overrides';
  end if;

  v_result := public.create_client_field_definition(
    v_business,
    'preference',
    'Preference',
    'select',
    'operational',
    jsonb_build_array(
      jsonb_build_object('option_key', 'VIP', 'option_label', 'VIP customer'),
      jsonb_build_object('option_key', 'regular', 'option_label', 'Regular customer')
    )
  );
  v_field := (v_result->>'id')::uuid;
  if (v_result->>'options_created')::integer <> 2 then
    raise exception 'atomic field RPC did not report both options';
  end if;
  select id into v_option
    from public.client_field_options
   where business_id = v_business and field_definition_id = v_field
     and option_key = 'vip';

  begin
    perform public.create_client_field_definition(
      v_business,
      'atomic_failure',
      'Atomic failure',
      'select',
      'operational',
      jsonb_build_array(
        jsonb_build_object('option_key', 'ok', 'option_label', 'OK'),
        jsonb_build_object('option_key', 'bad', 'option_label', repeat('x', 121))
      )
    );
    raise exception 'invalid field option unexpectedly succeeded';
  exception when check_violation then
    null;
  end;
  if exists (
    select 1 from public.client_field_definitions
     where business_id = v_business and field_key = 'atomic_failure'
  ) then
    raise exception 'atomic field RPC left a partial definition after option failure';
  end if;

  insert into public.client_field_values(
    business_id, client_id, field_definition_id, select_value
  ) values (v_business, v_client, v_field, 'VIP');
  select select_value into v_value
    from public.client_field_values
   where business_id = v_business and client_id = v_client
     and field_definition_id = v_field;
  if v_value <> 'vip' then
    raise exception 'select value was not normalized';
  end if;

  begin
    update public.client_field_definitions set field_key = 'changed' where id = v_field;
    raise exception 'field key was mutable';
  exception when restrict_violation then null;
  end;
  begin
    update public.client_field_definitions set value_type = 'text' where id = v_field;
    raise exception 'field value type was mutable after a value existed';
  exception when restrict_violation then null;
  end;
  begin
    update public.client_field_definitions set classification = 'sensitive' where id = v_field;
    raise exception 'field classification was mutable after a value existed';
  exception when restrict_violation then null;
  end;
  begin
    update public.client_field_options set option_key = 'premium' where id = v_option;
    raise exception 'select option identity was mutable after a value existed';
  exception when restrict_violation then null;
  end;
  begin
    insert into public.client_field_values(
      business_id, client_id, field_definition_id, text_value
    ) values (v_business, v_client, v_field, 'wrong type');
    raise exception 'wrong typed value unexpectedly succeeded';
  exception when check_violation then null;
  end;

  v_result := public.create_client_field_definition(
    v_business, 'medical_note', 'Medical note', 'text', 'sensitive'
  );
  v_sensitive_field := (v_result->>'id')::uuid;
  insert into public.client_field_values(
    business_id, client_id, field_definition_id, text_value
  ) values (v_business, v_client, v_sensitive_field, 'restricted');
  begin
    update public.client_field_definitions
       set classification = 'operational'
     where id = v_sensitive_field;
    raise exception 'sensitive classification was weakened after values existed';
  exception when restrict_violation then null;
  end;

  if has_table_privilege('anon', 'public.client_field_values', 'select')
     or has_table_privilege('anon', 'public.client_field_definitions', 'select')
     or has_table_privilege('anon', 'public.loyalty_branch_overrides', 'select') then
    raise exception 'anon retained raw v29 table access';
  end if;
  if not has_table_privilege('authenticated', 'public.client_field_values', 'select')
     or not has_table_privilege('authenticated', 'public.client_field_definitions', 'select') then
    raise exception 'owner raw access grant is missing';
  end if;
  if position('resolve_loyalty_branch_config' in
       pg_get_functiondef('app.on_sale_recorded()'::regprocedure)) = 0 then
    raise exception 'sale earning trigger does not consume the branch resolver';
  end if;
  if has_function_privilege('anon', 'app.resolve_loyalty_branch_config(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'app.resolve_loyalty_branch_config(uuid,uuid,uuid)', 'execute') then
    raise exception 'branch resolver is externally executable';
  end if;
  raise notice 'v29 branch/custom-field suite: ALL PASS';
end $v29_test$;

rollback;
