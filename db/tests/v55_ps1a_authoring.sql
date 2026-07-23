-- Rollback-only v55 PS-1A authoring / projection / validation suite.
-- Run after v55 in a disposable rehearsal database. Asserts the PS-1A DB-side
-- acceptance criteria: adapter projection (no storage, 1:1 with native config,
-- every programme once), draft authoring never touches active legacy config,
-- publish refuses invalid rules atomically, allowlist / no-SQL / no-client-price
-- rejections, hash determinism, complexity limits, owner-only + cross-business
-- denial, truthful studio-rule state (never live), and seeded registry metadata.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v55_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v55 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v55_principal(uuid,text) to authenticated, anon;

do $v55_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid;
  v_biz_b uuid; v_owner_b uuid;
  v_base uuid; v_draft uuid; v_draft2 uuid; v_draft_b uuid; v_invalid uuid;
  v_hash text; v_hash_b text; v_result jsonb; v_valid jsonb;
  v_rule uuid; v_rule2 uuid; v_manager uuid := gen_random_uuid();
  v_h1 text; v_h2 text; v_h3 text; v_relkind "char";
  v_native jsonb; v_before text; v_after text; v_state text;
begin
  reset role;
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A'
   order by s.created_at limit 1;
  select s.business_id,s.user_id into v_biz_b,v_owner_b
    from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B'
   order by s.created_at limit 1;
  if v_business is null or v_biz_b is null then raise exception 'v55 suite requires both pristine fixture businesses'; end if;
  select id into v_client from public.clients where business_id=v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id=v_business and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id=v_business;
  if v_base is null then raise exception 'v55 suite requires a published configuration'; end if;

  -- ---- 1. Adapter view has NO storage (relkind='v'). ----
  select relkind into v_relkind from pg_class where relname='v_program_rules_all' and relnamespace='public'::regnamespace;
  if v_relkind is distinct from 'v' then raise exception 'v_program_rules_all is not a storage-free view (relkind=%)', v_relkind; end if;

  -- ---- 2. benefit_registry seeded per family with correct authorities. ----
  if (select count(*) from public.benefit_registry where business_id=v_business)<>10 then
    raise exception 'benefit_registry was not seeded with all 10 families';
  end if;
  if (select count(*) from public.benefit_registry where business_id=v_business and execution_authority='legacy_trigger' and cutover_status='legacy')<>6
     or (select count(*) from public.benefit_registry where business_id=v_business and execution_authority='studio_executor' and cutover_status='unbuilt')<>4 then
    raise exception 'benefit_registry authority/cutover split is wrong (expected 6 legacy + 4 studio-unbuilt)';
  end if;
  if not exists(select 1 from public.benefit_registry where business_id=v_business and source_engine='points_loyalty' and execution_authority='legacy_trigger' and cutover_status='legacy')
     or not exists(select 1 from public.benefit_registry where business_id=v_business and source_engine='stored_value' and execution_authority='studio_executor' and cutover_status='unbuilt') then
    raise exception 'benefit_registry family authorities do not match the PS-0 contract';
  end if;
  -- registry is append-only in PS-1A: no authority mutation.
  begin
    update public.benefit_registry set cutover_status='studio', execution_authority='studio_executor'
      where business_id=v_business and source_engine='referral';
    raise exception 'benefit_registry execution authority was mutable in PS-1A';
  exception when restrict_violation then null; end;

  -- ---- 3. Adapter equivalence: earn row is 1:1 with native config; every row carries native_config. ----
  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  select native_config into v_native from public.v_program_rules_all
   where business_id=v_business and source_engine='points_loyalty' and rule_key like 'points_loyalty:%' limit 1;
  if v_native is distinct from (select to_jsonb(lp) from public.loyalty_program_versions lp where lp.config_version_id=v_base) then
    raise exception 'earn adapter row is not byte-equivalent to native loyalty_program_versions';
  end if;
  if exists(select 1 from public.v_program_rules_all where business_id=v_business and native_config is null) then
    raise exception 'an adapter row is missing its native_config projection';
  end if;
  -- cross-tenant isolation: owner A never sees business B rows.
  if exists(select 1 from public.v_program_rules_all where business_id=v_biz_b) then
    raise exception 'adapter view leaked another tenant to owner A';
  end if;

  -- ---- 4. Overview: every legacy programme appears exactly once; no studio rules yet. ----
  v_result := public.get_programs_overview(v_business);
  if jsonb_array_length(v_result->'legacy_programs') <>
     (select count(distinct e->>'rule_key') from jsonb_array_elements(v_result->'legacy_programs') e) then
    raise exception 'a legacy programme appeared more than once in the overview';
  end if;
  if not exists(select 1 from jsonb_array_elements(v_result->'legacy_programs') e
      where e->>'source_engine'='points_loyalty' and e->>'when_event'='sale.completed') then
    raise exception 'the points earn programme is missing from the overview';
  end if;
  if jsonb_array_length(v_result->'studio_rules')<>0 then raise exception 'unexpected studio rules before any authoring'; end if;
  if jsonb_array_length(v_result->'registry')<>10 then raise exception 'overview registry is incomplete'; end if;

  -- ---- 5. Draft authoring never touches active legacy config (byte compare). ----
  reset role;
  v_before := md5(
    coalesce((select string_agg(to_jsonb(lp)::text,'' order by lp.id::text) from public.loyalty_programs lp where lp.business_id=v_business),'') ||
    coalesce((select string_agg(to_jsonb(lt)::text,'' order by lt.id::text) from public.loyalty_tiers lt where lt.business_id=v_business),'') ||
    coalesce((select string_agg(to_jsonb(rp)::text,'' order by rp.id::text) from public.retention_programs rp where rp.business_id=v_business),''));

  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  v_draft := (public.create_loyalty_config_draft(v_business,v_base,'v55_draft')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_rule := gen_random_uuid();
  v_valid := jsonb_build_object(
    'name','Bonus points on big sales','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','gte','value',5000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',50)));
  v_result := public.save_program_rule_draft(v_draft,v_rule,v_valid,v_hash);
  if coalesce((v_result->>'replayed')::boolean,false) then raise exception 'first save wrongly reported a replay'; end if;
  if (v_result->>'rule_hash') !~ '^[0-9a-f]{64}$' then raise exception 'rule_hash is malformed'; end if;
  if (v_result->>'snapshot_hash') = v_hash then raise exception 'saving a rule did not refresh the config snapshot hash'; end if;

  -- lost-response retry with the STALE (pre-save) hash but identical body -> replay, one row.
  v_result := public.save_program_rule_draft(v_draft,v_rule,v_valid,v_hash);
  if coalesce((v_result->>'replayed')::boolean,false) is not true
     or (select count(*) from public.program_rules where rule_id=v_rule and config_version_id=v_draft)<>1 then
    raise exception 'lost-response retry created a duplicate program rule';
  end if;
  -- stale hash + a materially changed body -> conflict.
  begin
    perform public.save_program_rule_draft(v_draft,v_rule,jsonb_build_object(
      'name','changed','when_event','sale.completed',
      'then_effects',jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',99))),v_hash);
    raise exception 'stale changed retry unexpectedly succeeded';
  exception when serialization_failure then null; end;

  -- an empty-effects rule is valid but incomplete.
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_rule2 := gen_random_uuid();
  perform public.save_program_rule_draft(v_draft,v_rule2,jsonb_build_object('name','Incomplete','when_event','sale.completed'),v_hash);

  reset role;
  v_after := md5(
    coalesce((select string_agg(to_jsonb(lp)::text,'' order by lp.id::text) from public.loyalty_programs lp where lp.business_id=v_business),'') ||
    coalesce((select string_agg(to_jsonb(lt)::text,'' order by lt.id::text) from public.loyalty_tiers lt where lt.business_id=v_business),'') ||
    coalesce((select string_agg(to_jsonb(rp)::text,'' order by rp.id::text) from public.retention_programs rp where rp.business_id=v_business),''));
  if v_before <> v_after then raise exception 'draft rule authoring mutated the active legacy configuration'; end if;
  if (select active_config_version_id from public.businesses where id=v_business) <> v_base then
    raise exception 'draft rule authoring advanced the active config version';
  end if;

  -- ---- 6. Truthful studio-rule state in a DRAFT version. ----
  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  v_result := public.get_program_rules_draft(v_draft);
  select e->>'execution_state' into v_state from jsonb_array_elements(v_result->'rules') e where (e->>'rule_id')::uuid=v_rule;
  if v_state<>'validated' then raise exception 'a valid draft rule with effects must report validated, got %', v_state; end if;
  select e->>'execution_state' into v_state from jsonb_array_elements(v_result->'rules') e where (e->>'rule_id')::uuid=v_rule2;
  if v_state<>'draft' then raise exception 'an empty-effects draft rule must report draft, got %', v_state; end if;
  if v_result->'allowlists'->'events' is null or jsonb_array_length(v_result->'allowlists'->'events')=0 then
    raise exception 'the draft editor did not return the allowlist vocabulary';
  end if;

  -- ---- 7. Publish compiles the rules; a published studio rule NEVER reports live/active. ----
  perform public.publish_loyalty_config(v_draft);
  v_result := public.get_programs_overview(v_business);
  select s->>'execution_state' into v_state from jsonb_array_elements(v_result->'studio_rules') s where (s->>'rule_id')::uuid=v_rule;
  if v_state<>'ready_for_activation' then raise exception 'a published studio rule must report ready_for_activation, got %', v_state; end if;
  if exists(select 1 from jsonb_array_elements(v_result->'studio_rules') s where s->>'execution_state' in ('live','active')) then
    raise exception 'a studio rule reported live/active - forbidden in PS-1A';
  end if;
  if not exists(select 1 from public.program_rules_compiled c
      join public.program_rules pr on pr.id=c.program_rule_id
     where pr.rule_id=v_rule and pr.config_version_id=v_draft) then
    raise exception 'publish did not compile the studio rule into the read surface';
  end if;

  -- ---- 8. Publish refuses an INVALID rule, atomically. ----
  v_invalid := (public.create_loyalty_config_draft(v_business,v_draft,'v55_invalid')::jsonb->>'version_id')::uuid;
  reset role;
  insert into public.program_rules(rule_id,config_version_id,business_id,schema_version,name,active,when_event,if_conditions,then_effects,rule_hash)
  values(gen_random_uuid(),v_invalid,v_business,1,'directly-injected invalid',true,'sale.completed',
    jsonb_build_array(jsonb_build_object('field','nonexistent_field','op','eq','value',1)),
    jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',10)),
    repeat('a',64));
  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  begin
    perform public.publish_loyalty_config(v_invalid);
    raise exception 'publish accepted a version containing an invalid program rule';
  exception when check_violation then null; end;
  if (select status from public.firm_config_versions where id=v_invalid)<>'draft'
     or (select active_config_version_id from public.businesses where id=v_business)<>v_draft then
    raise exception 'invalid-rule publish was not atomic (the version advanced anyway)';
  end if;

  -- ---- 9. Allowlist / no-SQL / no-client-price / complexity / catalog rejections. ----
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','nope.event'))->>'valid')::boolean then raise exception 'invalid event accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'if_conditions',jsonb_build_array(jsonb_build_object('field','bogus','op','eq','value',1))))->>'valid')::boolean then raise exception 'unknown condition field accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'if_conditions',jsonb_build_array(jsonb_build_object('field','amount_cents','op','like','value',1))))->>'valid')::boolean then raise exception 'invalid operator accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','referral.qualified',
      'then_effects',jsonb_build_array(jsonb_build_object('effect_type','tier_multiplier','multiplier',2))))->>'valid')::boolean then raise exception 'out-of-allowlist effect accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'during_schedule',jsonb_build_object('timezone','America/New_York')))->>'valid')::boolean then raise exception 'non-SGT schedule accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'using_stacking',jsonb_build_object('stackable','yes')))->>'valid')::boolean then raise exception 'malformed stacking accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'then_effects',jsonb_build_array(jsonb_build_object('effect_type','grant_credit','amount_cents',100,'price_cents',999))))->>'valid')::boolean then raise exception 'client-supplied price accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'then_effects',jsonb_build_array(jsonb_build_object('effect_type','display_perk','sql','drop table x'))))->>'valid')::boolean then raise exception 'SQL fragment accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'if_conditions',(select jsonb_agg(jsonb_build_object('field','amount_cents','op','gte','value',g)) from generate_series(1,11) g)))->>'valid')::boolean then raise exception 'over-limit condition count accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'then_effects',(select jsonb_agg(jsonb_build_object('effect_type','display_perk','note','n'||g)) from generate_series(1,9) g)))->>'valid')::boolean then raise exception 'over-limit effect count accepted'; end if;
  if (public.validate_program_rule(v_business,jsonb_build_object('when_event','sale.completed',
      'if_conditions',jsonb_build_array(jsonb_build_object('field','branch_id','op','eq','value',gen_random_uuid()))))->>'valid')::boolean then raise exception 'foreign catalog reference accepted'; end if;
  if not (public.validate_program_rule(v_business,v_valid)->>'valid')::boolean then raise exception 'a fully valid rule was rejected'; end if;

  -- ---- 10. Hash determinism (equivalent -> identical, different -> different). ----
  v_h1 := public.validate_program_rule(v_business,jsonb_build_object(
    'name','A','sort',1,'when_event','sale.completed',
    'if_conditions',jsonb_build_array(
      jsonb_build_object('field','amount_cents','op','gte','value',5000),
      jsonb_build_object('field','kind','op','eq','value','service')),
    'then_effects',jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',50))))->>'rule_hash';
  v_h2 := public.validate_program_rule(v_business,jsonb_build_object(
    'name','B-different-display-name','sort',9,'when_event','sale.completed',
    'if_conditions',jsonb_build_array(
      jsonb_build_object('field','kind','op','eq','value','service'),
      jsonb_build_object('field','amount_cents','op','gte','value',5000)),
    'then_effects',jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',50))))->>'rule_hash';
  if v_h1<>v_h2 then raise exception 'canonical-equivalent rules produced different hashes'; end if;
  v_h3 := public.validate_program_rule(v_business,jsonb_build_object(
    'when_event','sale.completed',
    'if_conditions',jsonb_build_array(
      jsonb_build_object('field','amount_cents','op','gte','value',6000),
      jsonb_build_object('field','kind','op','eq','value','service')),
    'then_effects',jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points',50))))->>'rule_hash';
  if v_h3=v_h1 then raise exception 'materially different rules produced identical hashes'; end if;

  -- ---- 11. Owner-only authoring: manager and anon denied. ----
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated',
         'v55-mgr-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active) values(v_business,v_manager,'manager','v55 manager',true);

  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  v_draft2 := (public.create_loyalty_config_draft(v_business,null,'v55_denial')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft2;

  perform pg_temp.as_v55_principal(v_manager,'authenticated');
  begin perform public.save_program_rule_draft(v_draft2,gen_random_uuid(),v_valid,v_hash); raise exception 'manager authored a program rule'; exception when insufficient_privilege then null; end;
  begin perform public.get_program_rules_draft(v_draft2); raise exception 'manager read a program rule draft'; exception when insufficient_privilege then null; end;
  begin perform public.delete_program_rule_draft(v_draft2,gen_random_uuid(),v_hash); raise exception 'manager deleted a program rule'; exception when insufficient_privilege then null; end;
  begin perform public.validate_program_rule(v_business,v_valid); raise exception 'manager ran the owner validator'; exception when insufficient_privilege then null; end;
  begin perform public.get_programs_overview(v_business); raise exception 'manager read the owner overview'; exception when insufficient_privilege then null; end;

  perform pg_temp.as_v55_principal(null,'anon');
  begin perform public.save_program_rule_draft(v_draft2,gen_random_uuid(),v_valid,v_hash); raise exception 'anon authored a program rule'; exception when insufficient_privilege then null; end;
  begin perform public.get_programs_overview(v_business); raise exception 'anon read the overview'; exception when insufficient_privilege then null; end;
  begin perform public.get_rule_allowlists(v_business); raise exception 'anon read the allowlists'; exception when insufficient_privilege then null; end;

  -- ---- 12. Cross-business denial. ----
  perform pg_temp.as_v55_principal(v_owner_b,'authenticated');
  v_draft_b := (public.create_loyalty_config_draft(v_biz_b,null,'v55_b')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash_b from public.firm_config_versions where id=v_draft_b;
  perform pg_temp.as_v55_principal(v_owner,'authenticated');
  begin perform public.save_program_rule_draft(v_draft_b,gen_random_uuid(),v_valid,v_hash_b); raise exception 'owner A authored on business B draft'; exception when insufficient_privilege then null; end;
  begin perform public.get_program_rules_draft(v_draft_b); raise exception 'owner A read business B draft'; exception when insufficient_privilege then null; end;
  begin perform public.get_programs_overview(v_biz_b); raise exception 'owner A read business B overview'; exception when insufficient_privilege then null; end;

  -- ---- 13. RPC / table ACL contract. ----
  if not has_function_privilege('authenticated','public.save_program_rule_draft(uuid,uuid,jsonb,text)','execute')
     or not has_function_privilege('authenticated','public.get_programs_overview(uuid)','execute')
     or not has_function_privilege('authenticated','public.validate_program_rule(uuid,jsonb)','execute')
     or has_function_privilege('anon','public.save_program_rule_draft(uuid,uuid,jsonb,text)','execute')
     or has_function_privilege('anon','public.get_programs_overview(uuid)','execute') then
    raise exception 'v55 RPC ACL contract is incorrect';
  end if;
  if has_table_privilege('authenticated','public.benefit_registry','insert')
     or has_table_privilege('authenticated','public.benefit_registry','update')
     or has_table_privilege('authenticated','public.program_rules','insert')
     or has_table_privilege('authenticated','public.program_rules_compiled','insert') then
    raise exception 'browser roles retain direct writes to studio tables';
  end if;

  raise notice 'v55 PS-1A authoring/projection/validation suite: ALL PASS';
end $v55_test$;

reset role;
rollback;
