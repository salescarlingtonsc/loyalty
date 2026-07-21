-- Rollback-only v37b retention versioning and taxonomy suite.
-- Run after v37b in a disposable rehearsal database.
begin;

create temporary table v37b_rls_context(owner_id uuid, hidden_program_id uuid) on commit drop;
grant select on v37b_rls_context to authenticated;

create or replace function pg_temp.as_v37_principal(p_uid uuid,p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if p_role='anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
  elsif p_role='authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub',p_uid::text,true);
    perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  else
    raise exception 'unsupported v37 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v37_principal(uuid,text) to authenticated,anon;

do $v37b_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid;
  v_base uuid; v_draft uuid; v_changed uuid; v_rollback uuid; v_repeat uuid; v_label_draft uuid; v_disable uuid;
  v_tax uuid; v_program uuid; v_hash text; v_result jsonb; v_grant uuid;
  v_active_tax uuid; v_hidden_draft uuid; v_hidden_program uuid;
  v_manager uuid:=gen_random_uuid(); v_nonstaff uuid:=gen_random_uuid();
  v_other_owner uuid:=gen_random_uuid(); v_other_business uuid; v_other_draft uuid; v_actor uuid;
  v_original_label text; v_program_payload jsonb; v_rule public.retention_program_versions%rowtype;
begin
  reset role;
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s where s.role='owner' and s.active and s.user_id is not null
   order by s.created_at limit 1;
  if v_business is null then raise exception 'v37b suite requires an active owner'; end if;
  perform pg_temp.as_v37_principal(v_owner,'authenticated');
  select id into v_client from public.clients where business_id=v_business order by created_at limit 1;
  if v_client is null then
    insert into public.clients(business_id,full_name) values(v_business,'v37b client') returning id into v_client;
  end if;
  select id into v_branch from public.branches where business_id=v_business and active order by is_default desc,created_at limit 1;
  if v_branch is null then raise exception 'v37b suite requires an active branch'; end if;
  select active_config_version_id into v_base from public.businesses where id=v_business;
  if v_base is null then raise exception 'v37b suite requires a published configuration'; end if;

  if exists(
    select 1 from public.retention_programs rp
     where rp.current_config_version_id is not null
       and not exists(
         select 1 from public.retention_program_versions rv
          where rv.program_id=rp.id and rv.business_id=rp.business_id
            and rv.config_version_id=rp.current_config_version_id
            and rv.name=rp.name and rv.active=rp.active
            and rv.goal_visits=rp.goal_visits and rv.period_days=rp.period_days
            and rv.starts_on=rp.starts_on and rv.reward_taxonomy_id=rp.reward_taxonomy_id
       )
  ) then raise exception 'legacy live retention behavior was not backfilled exactly'; end if;
  if exists(
    select 1 from public.retention_programs rp
     where (select count(*) from public.retention_program_versions rv
             where rv.program_id=rp.id and rv.business_id=rp.business_id)
           <> (select count(*) from public.firm_config_versions fv
                where fv.business_id=rp.business_id)
  ) then raise exception 'pre-v37 live retention was not backfilled into every historical config version'; end if;
  if exists(select 1 from public.reward_grants
    where retention_program_version_id is null or period_start is null or period_end is null) then
    raise exception 'historical grant retention version/window backfill is incomplete';
  end if;

  if has_table_privilege('authenticated','public.retention_programs','insert')
     or has_table_privilege('authenticated','public.retention_programs','update')
     or has_table_privilege('authenticated','public.retention_programs','delete')
     or has_table_privilege('authenticated','public.firm_reward_taxonomy','insert')
     or has_table_privilege('authenticated','public.firm_reward_taxonomy','update')
     or has_table_privilege('authenticated','public.firm_reward_taxonomy','delete') then
    raise exception 'browser roles retain direct live retention/taxonomy writes';
  end if;
  if has_function_privilege('authenticated','app.seed_firm_reward_taxonomy()','execute')
     or has_function_privilege('anon','app.seed_firm_reward_taxonomy()','execute') then
    raise exception 'future-business taxonomy seed trigger is browser executable';
  end if;

  v_result:=public.save_reward_taxonomy(v_business,null,jsonb_build_object(
    'label','v37b credit '||substr(md5(clock_timestamp()::text),1,8),
    'fulfillment_kind','credit','active',true,'sort',9010));
  v_tax:=(v_result->>'id')::uuid; v_original_label:=v_result->>'label';
  begin
    perform public.save_reward_taxonomy(v_business,v_tax,jsonb_build_object('fulfillment_kind','free_item'));
    raise exception 'taxonomy fulfillment kind was mutable';
  exception when restrict_violation then null; end;

  v_result:=public.create_loyalty_config_draft(v_business,v_base,'v37b_initial')::jsonb;
  v_draft:=(v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_program:=gen_random_uuid();
  v_program_payload:=jsonb_build_object(
    'name','v37b return visit','active',true,'goal_visits',1,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_tax,'credit_cents',111,
    'sort',10,'customer_description','A safe versioned return reward',
    'staff_description','Test-only retained rule');
  v_result:=public.save_retention_program_draft(v_draft,v_program,v_program_payload,v_hash);
  if v_result->>'snapshot_hash'=v_hash then raise exception 'retention edit did not refresh the configuration hash'; end if;
  v_result:=public.save_retention_program_draft(v_draft,v_program,v_program_payload,v_hash);
  if coalesce((v_result->>'replayed')::boolean,false) is not true
     or (select count(*) from public.retention_program_versions where program_id=v_program and config_version_id=v_draft)<>1 then
    raise exception 'lost-response retry created a duplicate retention identity/version';
  end if;
  begin
    perform public.save_retention_program_draft(v_draft,v_program,jsonb_build_object('goal_visits',2),v_hash);
    raise exception 'changed stale retention retry unexpectedly succeeded';
  exception when serialization_failure then null; end;

  perform public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'v37b before publish','v37b-pre-'||substr(md5(clock_timestamp()::text),1,10),true);
  if exists(select 1 from public.reward_grants where program_id=v_program) then
    raise exception 'draft retention edit affected visit processing before publish';
  end if;

  perform public.publish_loyalty_config(v_draft);
  perform public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'v37b after publish','v37b-post-'||substr(md5(clock_timestamp()::text),1,10),true);
  select id into v_grant from public.reward_grants where program_id=v_program and client_id=v_client;
  if v_grant is null then raise exception 'published retention rule did not issue a grant'; end if;
  if (select (config_version_id,retention_program_version_id,reward_label,fulfillment_kind,reward_value::integer)
        from public.reward_grants where id=v_grant)
     is distinct from row(v_draft,(select id from public.retention_program_versions where program_id=v_program and config_version_id=v_draft),v_original_label,'credit'::text,111::integer) then
    raise exception 'grant did not snapshot the exact retention version and taxonomy behavior';
  end if;
  if (select (period_start,period_end) from public.reward_grants where id=v_grant)
     is distinct from row(current_date::timestamptz,(current_date+30)::timestamptz) then
    raise exception 'grant did not snapshot its exact real-world half-open period';
  end if;

  v_result:=public.create_loyalty_config_draft(v_business,v_draft,'v37b_changed')::jsonb;
  v_changed:=(v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_changed;
  perform public.save_retention_program_draft(v_changed,v_program,jsonb_build_object('goal_visits',99),v_hash);
  perform public.publish_loyalty_config(v_changed);
  if (select goal_visits from public.retention_programs where id=v_program)<>99 then
    raise exception 'published retention compatibility projection was not advanced';
  end if;

  v_result:=public.create_loyalty_config_draft(v_business,v_draft,'v37b_rollback')::jsonb;
  v_rollback:=(v_result->>'version_id')::uuid;
  if v_rollback=v_draft or (select based_on_version_id from public.firm_config_versions where id=v_rollback)<>v_draft then
    raise exception 'rollback did not create a new version based on immutable history';
  end if;
  perform public.publish_loyalty_config(v_rollback);
  if (select goal_visits from public.retention_programs where id=v_program)<>1
     or (select active_config_version_id from public.businesses where id=v_business)<>v_rollback
     or (select status from public.firm_config_versions where id=v_draft)<>'superseded' then
    raise exception 'rollback-as-new-version did not restore retention behavior while preserving history';
  end if;
  perform public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'v37b after rollback','v37b-rollback-'||substr(md5(clock_timestamp()::text),1,10),true);
  if (select count(*) from public.reward_grants where program_id=v_program and client_id=v_client)<>1
     or (select count(*) from public.credit_ledger where business_id=v_business and client_id=v_client and reference='retention reward: v37b return visit' and amount_cents=111)<>1 then
    raise exception 'rollback publication reminted an overlapping stable-program reward or credit';
  end if;

  v_result:=public.create_loyalty_config_draft(v_business,v_draft,'v37b_repeat_rollback')::jsonb;
  v_repeat:=(v_result->>'version_id')::uuid;
  perform public.publish_loyalty_config(v_repeat);
  perform public.record_quick_sale(v_business,100,'cash',v_client,v_owner_staff,v_branch,
    'v37b after repeat rollback','v37b-repeat-'||substr(md5(clock_timestamp()::text),1,10),true);
  if (select count(*) from public.reward_grants where program_id=v_program and client_id=v_client)<>1
     or (select count(*) from public.credit_ledger where business_id=v_business and client_id=v_client and reference='retention reward: v37b return visit' and amount_cents=111)<>1 then
    raise exception 'repeated identical publication reminted the same real retention window';
  end if;

  v_result:=public.create_loyalty_config_draft(v_business,v_draft,'v37b_label_open_before_rename')::jsonb;
  v_label_draft:=(v_result->>'version_id')::uuid;
  perform public.save_reward_taxonomy(v_business,v_tax,jsonb_build_object('label',v_original_label||' renamed','sort',9020));
  if (select reward_label from public.reward_grants where id=v_grant)<>v_original_label
     or (select reward_snapshot->>'reward_label' from public.reward_grants where id=v_grant)<>v_original_label then
    raise exception 'taxonomy rename rewrote historical grant evidence';
  end if;
  if not exists(select 1 from jsonb_array_elements(public.get_retention_config_draft(v_label_draft)->'programs') p
    where (p->>'program_id')::uuid=v_program and p->>'reward_label'=v_original_label||' renamed') then
    raise exception 'already-open draft did not resolve the live renamed taxonomy label';
  end if;
  perform public.publish_loyalty_config(v_label_draft);
  reset role;
  insert into public.sales(business_id,branch_id,staff_id,client_id,kind,amount_cents,occurred_at,note)
  values(v_business,v_branch,v_owner_staff,v_client,'quick_sale',100,current_date+interval '31 days','v37b non-overlapping future window');
  perform pg_temp.as_v37_principal(v_owner,'authenticated');
  if (select count(*) from public.reward_grants where program_id=v_program and client_id=v_client)<>2
     or not exists(select 1 from public.reward_grants where program_id=v_program and client_id=v_client
       and period_start=(current_date+30)::timestamptz and period_end=(current_date+60)::timestamptz
       and reward_label=v_original_label||' renamed')
     or (select count(*) from public.credit_ledger where business_id=v_business and client_id=v_client and reference='retention reward: v37b return visit' and amount_cents=111)<>2 then
    raise exception 'non-overlapping later window did not grant once with the live renamed taxonomy label';
  end if;
  begin
    update public.reward_grants set period_end=period_end+interval '1 day' where id=v_grant;
    raise exception 'member rewrote immutable retention grant window';
  exception when restrict_violation then null; end;
  begin
    update public.reward_grants set client_id=gen_random_uuid() where id=v_grant;
    raise exception 'member retargeted immutable retention grant customer';
  exception when restrict_violation then null; end;
  update public.reward_grants set status='redeemed' where id=v_grant;
  if (select status from public.reward_grants where id=v_grant)<>'redeemed' then
    raise exception 'intended retention grant status transition was blocked';
  end if;
  begin
    perform public.save_reward_taxonomy(v_business,v_tax,jsonb_build_object('active',false));
    raise exception 'live taxonomy retirement should require a replacement or disabled rule';
  exception when check_violation then null; end;

  v_result:=public.create_loyalty_config_draft(v_business,v_label_draft,'v37b_disable')::jsonb;
  v_disable:=(v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_disable;
  perform public.save_retention_program_draft(v_disable,v_program,jsonb_build_object('active',false),v_hash);
  perform public.publish_loyalty_config(v_disable);
  perform public.save_reward_taxonomy(v_business,v_tax,jsonb_build_object('active',false));
  begin
    select snapshot_hash into v_hash from public.firm_config_versions where id=v_disable;
    perform public.save_retention_program_draft(v_disable,v_program,jsonb_build_object('active',true),v_hash);
    raise exception 'published retention version was mutable';
  exception when insufficient_privilege then null; end;

  v_result:=public.create_loyalty_config_draft(v_business,v_disable,'v37b_retired_rejection')::jsonb;
  v_hidden_draft:=(v_result->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_hidden_draft;
  begin
    perform public.save_retention_program_draft(v_hidden_draft,v_program,jsonb_build_object('active',true),v_hash);
    raise exception 'retired taxonomy was selectable by a new active draft';
  exception when invalid_parameter_value then null; end;

  select id into v_active_tax from public.firm_reward_taxonomy
   where business_id=v_business and fulfillment_kind='credit' and active order by sort,id limit 1;
  v_hidden_program:=gen_random_uuid();
  perform public.save_retention_program_draft(v_hidden_draft,v_hidden_program,jsonb_build_object(
    'name','v37b hidden draft identity','active',false,'goal_visits',3,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_active_tax,'credit_cents',77),v_hash);
  if (select current_config_version_id from public.retention_programs where id=v_hidden_program) is not null then
    raise exception 'new draft identity was incorrectly marked as published';
  end if;

  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated','v37b-manager-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_nonstaff,'authenticated','authenticated','v37b-customer-'||substr(v_nonstaff::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other_owner,'authenticated','authenticated','v37b-other-'||substr(v_other_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_manager,'manager','v37b manager',true);
  perform pg_temp.as_v37_principal(v_other_owner,'authenticated');
  v_result:=public.create_business('v37b other business','v37b-other-'||substr(v_other_owner::text,1,8),'test',array['loyalty','retention'])::jsonb;
  v_other_business:=(v_result->>'id')::uuid;
  select current_config_version_id into v_other_draft from public.loyalty_programs where business_id=v_other_business;
  if (select count(*) from public.firm_reward_taxonomy where business_id=v_other_business and active)<>3
     or (select count(distinct fulfillment_kind) from public.firm_reward_taxonomy where business_id=v_other_business and active)<>3 then
    raise exception 'future business did not receive exactly one starter taxonomy per controlled kind';
  end if;

  foreach v_actor in array array[v_manager,v_nonstaff,v_other_owner] loop
    perform pg_temp.as_v37_principal(v_actor,'authenticated');
    begin perform public.get_retention_config_draft(v_hidden_draft); raise exception 'non-owner read retention draft';
    exception when insufficient_privilege then null; end;
    begin perform public.save_retention_program_draft(v_hidden_draft,v_program,jsonb_build_object('active',false),v_hash); raise exception 'non-owner saved retention draft';
    exception when insufficient_privilege then null; end;
    begin perform public.save_reward_taxonomy(v_business,v_active_tax,jsonb_build_object('sort',99)); raise exception 'non-owner edited taxonomy';
    exception when insufficient_privilege then null; end;
  end loop;
  perform pg_temp.as_v37_principal(null,'anon');
  begin perform public.get_retention_config_draft(v_hidden_draft); raise exception 'anon read retention draft';
  exception when insufficient_privilege then null; end;
  begin perform public.save_retention_program_draft(v_hidden_draft,v_program,jsonb_build_object('active',false),v_hash); raise exception 'anon saved retention draft';
  exception when insufficient_privilege then null; end;
  begin perform public.save_reward_taxonomy(v_business,v_active_tax,jsonb_build_object('sort',99)); raise exception 'anon edited taxonomy';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_v37_principal(v_owner,'authenticated');
  begin perform public.get_retention_config_draft(v_other_draft); raise exception 'unrelated owner read cross-business retention draft';
  exception when insufficient_privilege then null; end;
  begin perform public.save_retention_program_draft(v_other_draft,gen_random_uuid(),jsonb_build_object('active',false),v_hash); raise exception 'unrelated owner saved cross-business retention draft';
  exception when insufficient_privilege then null; end;

  reset role;
  insert into v37b_rls_context values(v_manager,v_hidden_program);

  if not has_function_privilege('authenticated','public.get_retention_config_draft(uuid)','execute')
     or not has_function_privilege('authenticated','public.save_retention_program_draft(uuid,uuid,jsonb,text)','execute')
     or not has_function_privilege('authenticated','public.save_reward_taxonomy(uuid,uuid,jsonb)','execute')
     or has_function_privilege('anon','public.get_retention_config_draft(uuid)','execute')
     or has_function_privilege('anon','public.save_retention_program_draft(uuid,uuid,jsonb,text)','execute')
     or has_function_privilege('anon','public.save_reward_taxonomy(uuid,uuid,jsonb)','execute') then
    raise exception 'v37b RPC ACL contract is incorrect';
  end if;
  raise notice 'v37b versioned retention/taxonomy suite: ALL PASS';
end $v37b_test$;

reset role;
select pg_temp.as_v37_principal(owner_id,'authenticated') from v37b_rls_context;
do $v37b_member_rls$
declare v_owner uuid; v_hidden uuid;
begin
  select owner_id,hidden_program_id into v_owner,v_hidden from v37b_rls_context;
  if exists(select 1 from public.retention_programs where id=v_hidden) then
    raise exception 'member RLS exposed a draft-only retention identity before publish';
  end if;
end $v37b_member_rls$;
reset role;

rollback;
