-- Rollback-only v28 tenant, retirement and immutable-snapshot suite.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v28_test$
declare
  v_business uuid; v_owner uuid; v_client uuid; v_type uuid; v_program uuid; v_grant uuid;
  v_base uuid; v_draft uuid; v_retired_draft uuid; v_hash text; v_result jsonb;
begin
  select s.business_id, s.user_id into v_business, v_owner
    from public.staff s
   where s.role = 'owner' and s.active and s.user_id is not null
   order by s.created_at limit 1;
  select c.id into v_client from public.clients c
   where c.business_id = v_business order by c.created_at limit 1;
  if v_business is null or v_client is null then
    raise exception 'v28 suite requires an active owner and customer';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  v_result:=public.save_reward_taxonomy(v_business,null,jsonb_build_object(
    'label','Test credit','fulfillment_kind','credit','active',true));
  v_type:=(v_result->>'id')::uuid;
  select active_config_version_id into v_base from public.businesses where id=v_business;
  v_draft:=(public.create_loyalty_config_draft(v_business,v_base,'v28-full-head')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_program:=gen_random_uuid();
  perform public.save_retention_program_draft(v_draft,v_program,jsonb_build_object(
    'name','v28 test','active',false,'goal_visits',1,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_type,'credit_cents',500),v_hash);
  perform public.publish_loyalty_config(v_draft);
  if (select reward_type from public.retention_programs where id=v_program) <> 'credit' then
    raise exception 'taxonomy did not derive the machine fulfillment kind';
  end if;

  insert into public.reward_grants(
    business_id,program_id,client_id,period_index,reward_type,reward_value
  ) values (v_business,v_program,v_client,0,'free_item',500)
  returning id into v_grant;
  if (select (reward_label,fulfillment_kind) from public.reward_grants where id=v_grant)
     is distinct from row('Test credit'::text,'credit'::text) then
    raise exception 'grant did not snapshot taxonomy';
  end if;
  perform public.save_reward_taxonomy(v_business,v_type,jsonb_build_object('label','Renamed credit'));
  if (select reward_label from public.reward_grants where id=v_grant) <> 'Test credit' then
    raise exception 'taxonomy rename rewrote historical grant';
  end if;

  begin
    perform public.save_reward_taxonomy(v_business,v_type,jsonb_build_object('fulfillment_kind','free_item'));
    raise exception 'machine fulfillment kind was mutable';
  exception when restrict_violation then null;
  end;
  perform public.save_reward_taxonomy(v_business,v_type,jsonb_build_object('active',false));
  v_retired_draft:=(public.create_loyalty_config_draft(v_business,v_draft,'v28-retired')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_retired_draft;
  begin
    perform public.save_retention_program_draft(v_retired_draft,gen_random_uuid(),jsonb_build_object(
      'name','retired type test','active',true,'goal_visits',1,'period_days',30,
      'starts_on',current_date,'reward_taxonomy_id',v_type,'credit_cents',500),v_hash);
    raise exception 'retired reward type was selectable';
  exception when others then
    if sqlerrm = 'retired reward type was selectable' then raise; end if;
  end;
  raise notice 'v28 reward taxonomy suite: ALL PASS';
end $v28_test$;

rollback;
