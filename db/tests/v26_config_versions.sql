-- Rollback-only v26 version publication and event-stamp suite.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v26_test$
declare
  v_business uuid; v_owner uuid; v_program public.loyalty_programs%rowtype;
  v_prior uuid; v_draft uuid; v_result json; v_sale uuid; v_reversal json; v_reversal_sale uuid;
begin
  select s.business_id,s.user_id into v_business,v_owner from public.staff s
   where s.role='owner' and s.active and s.user_id is not null order by s.created_at limit 1;
  if v_business is null then raise exception 'v26 suite requires an active owner'; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  select * into v_program from public.loyalty_programs where business_id=v_business;
  select active_config_version_id into v_prior from public.businesses where id=v_business;
  if v_program.active and v_prior is null then raise exception 'active program lacks active version'; end if;

  v_result:=public.create_loyalty_config_draft(v_business,v_program.current_config_version_id,'v26_test');
  v_draft:=(v_result->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'active',true,'loyalty_model','classic','redeem_points',321,'reward_credit_cents',654
  ));
  perform public.publish_loyalty_config(v_draft);
  if (select active_config_version_id from public.businesses where id=v_business) is distinct from v_draft then
    raise exception 'publish did not move active pointer';
  end if;
  if (select redeem_points from public.loyalty_programs where business_id=v_business) <> 321 then
    raise exception 'compatibility projection did not receive published typed values';
  end if;
  begin
    update public.loyalty_program_versions set redeem_points=999 where config_version_id=v_draft;
    raise exception 'published typed row was mutable';
  exception when restrict_violation then null;
  end;

  insert into public.sales(business_id,kind,amount_cents,occurred_at)
  values(v_business,'retail',100,now()) returning id into v_sale;
  if (select config_version_id from public.sales where id=v_sale) is distinct from v_draft then
    raise exception 'sale did not stamp the published version';
  end if;
  v_reversal:=public.reverse_sale(v_business,v_sale,'v26 version inheritance','v26-reverse-key');
  v_reversal_sale:=(v_reversal->>'reversal_sale_id')::uuid;
  if (select config_version_id from public.sales where id=v_reversal_sale) is distinct from v_draft then
    raise exception 'reversal did not inherit source config version';
  end if;

  if has_function_privilege('anon','public.publish_loyalty_config(uuid)','execute') then
    raise exception 'publish RPC is anon executable';
  end if;
  if has_table_privilege('authenticated','public.loyalty_programs','INSERT')
     or has_table_privilege('authenticated','public.loyalty_programs','UPDATE')
     or has_table_privilege('authenticated','public.loyalty_programs','DELETE')
     or exists (
       select 1 from pg_policy p
        where p.polrelid='public.loyalty_programs'::regclass
          and p.polcmd in ('a','w','d')
     ) then
    raise exception 'live loyalty projection can bypass immutable publication';
  end if;
  if has_table_privilege('authenticated','public.loyalty_tiers','INSERT')
     or has_table_privilege('authenticated','public.loyalty_tiers','UPDATE')
     or has_table_privilege('authenticated','public.loyalty_tiers','DELETE') then
    raise exception 'live tier multipliers can bypass immutable publication';
  end if;
  raise notice 'v26 config versions suite: ALL PASS';
end $v26_test$;

rollback;
