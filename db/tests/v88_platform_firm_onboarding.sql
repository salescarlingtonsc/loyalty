-- Rollback-only v88 unified platform firm-onboarding acceptance evidence.
begin;

create or replace function pg_temp.as_v88_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v88_user(uuid,text) to public;

do $v88$
declare
  v_sa uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_owner_phone text:='+659'||substr(
    regexp_replace(v_owner::text,'[^0-9]','','g')||'0000000',1,7);
  v_business uuid:=gen_random_uuid();
  v_converted_business uuid:=gen_random_uuid();
  v_company uuid:=gen_random_uuid();
  v_converted_company uuid:=gen_random_uuid();
  v_late_company uuid:=gen_random_uuid();
  v_late_prospect uuid:=gen_random_uuid();
  v_prospect uuid:=gen_random_uuid();
  v_converted_prospect uuid:=gen_random_uuid();
  v_result jsonb;
  v_page_one jsonb;
  v_page_two_before jsonb;
  v_page_two_after jsonb;
  v_attention jsonb;
  v_item jsonb;
  v_after_updated_at timestamptz;
  v_after_id uuid;
  v_snapshot timestamptz:=date_trunc('second',clock_timestamp());
begin
  if to_regprocedure(
    'public.platform_list_firm_onboarding_v88(jsonb,timestamp with time zone,integer,timestamp with time zone,uuid)'
  ) is null or to_regprocedure(
    'public.platform_list_firm_attention_v88(timestamp with time zone,integer,integer,uuid)'
  ) is null then
    raise exception 'v88 platform firm readers are missing';
  end if;
  if has_function_privilege('authenticated',
    'app.platform_firm_rows_v88(timestamp with time zone)','EXECUTE') then
    raise exception 'private v88 row source is browser executable';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,phone_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v88-sa-'||substr(v_sa::text,1,8)||'@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v88-out-'||substr(v_outsider::text,1,8)||'@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'boss-v88@example.test',v_owner_phone,'',now(),now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v88-sa-'||substr(v_sa::text,1,8)||'@example.test','v88 rollback fixture');

  -- A website-created firm has no CRM prospect and must still appear terminal.
  insert into public.businesses(id,name,slug,created_at)
  values(v_business,'V88 Website Firm','v88-website-'||substr(v_business::text,1,8),
    v_snapshot-interval '20 days');
  insert into public.staff(business_id,user_id,role,full_name,created_at)
  values(v_business,v_owner,'owner','V88 Website Boss',v_snapshot-interval '20 days');

  -- An unattended prospect provides deterministic stale-attention evidence.
  insert into public.sme_companies(
    id,legal_name,trading_name,registration_number,industry,email,phone,created_at,updated_at
  ) values(v_company,'V88 Stale Pte Ltd','V88 Stale','V88-UEN-STALE','retail',
    'company-v88@example.test','81112222',
    v_snapshot-interval '20 days',v_snapshot-interval '20 days');
  insert into public.sme_prospects(
    id,company_id,current_stage_key,next_action_at,stage_entered_at,created_at,updated_at
  ) values(v_prospect,v_company,'new_lead',v_snapshot-interval '2 days',
    v_snapshot-interval '20 days',v_snapshot-interval '20 days',
    v_snapshot-interval '20 days');
  insert into public.sme_prospect_contacts(
    prospect_id,full_name,email,phone,is_primary,created_at,updated_at
  ) values(v_prospect,'V88 Prospect Boss','prospect-v88@example.test','82223333',true,
    v_snapshot-interval '20 days',v_snapshot-interval '20 days');

  -- Both conversion links identify one firm row, never a prospect/business duplicate.
  insert into public.sme_companies(
    id,legal_name,trading_name,registration_number,industry,created_at,updated_at
  ) values(v_converted_company,'V88 Converted Pte Ltd','V88 Converted',
    'V88-UEN-CONVERTED','food_beverage',v_snapshot-interval '10 days',
    v_snapshot-interval '10 days');
  insert into public.sme_prospects(
    id,company_id,current_stage_key,stage_entered_at,created_at,updated_at
  ) values(v_converted_prospect,v_converted_company,'account_created',
    v_snapshot-interval '10 days',v_snapshot-interval '10 days',
    v_snapshot-interval '10 days');
  insert into public.businesses(
    id,name,slug,source_prospect_id,onboarding_started_at,created_at
  ) values(v_converted_business,'V88 Converted Firm',
    'v88-converted-'||substr(v_converted_business::text,1,8),
    v_converted_prospect,v_snapshot-interval '9 days',v_snapshot-interval '10 days');
  update public.sme_prospects set
    converted_business_id=v_converted_business,converted_at=v_snapshot-interval '9 days',
    converted_by=v_sa
  where id=v_converted_prospect;

  perform pg_temp.as_v88_user(v_sa);
  v_result:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',null,100,null,null
  );
  reset role;
  v_snapshot:=(v_result->>'snapshot_at')::timestamptz;
  if (v_result->>'total_count')::integer<>3
     or jsonb_array_length(v_result->'items')<>3 then
    raise exception 'v88 unified reader duplicated or omitted a fixture firm: %',v_result;
  end if;
  select value into v_item from jsonb_array_elements(v_result->'items')
    where value->>'business_id'=v_business::text;
  if v_item->>'lane_key'<>'case_won'
     or v_item->>'onboarding_status'<>'not_started'
     or v_item->>'boss_name'<>'V88 Website Boss'
     or v_item->>'boss_email'<>'boss-v88@example.test'
     or v_item->>'boss_phone'<>v_owner_phone then
    raise exception 'website firm/contact did not map through the SA reader: %',v_item;
  end if;
  select value into v_item from jsonb_array_elements(v_result->'items')
    where value->>'prospect_id'=v_prospect::text;
  if v_item->>'lane_key'<>'inbox' or v_item->>'attention_severity'<>'critical'
     or (v_item->>'attention_due')::boolean<>true
     or (v_item->>'days_unattended')::integer<14 then
    raise exception 'deterministic stale-attention contract failed: %',v_item;
  end if;
  if (v_result#>>'{attention_summary,due}')::integer<1
     or not (v_result?'snapshot_expires_at') then
    raise exception 'v88 summary/cursor envelope is incomplete';
  end if;

  -- Freeze page one/two, mutate every mutable source represented by the
  -- projection, then prove the same cursor returns byte-identical page content.
  perform pg_temp.as_v88_user(v_sa);
  v_page_one:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',v_snapshot,1,null,null
  );
  reset role;
  v_after_updated_at:=(v_page_one#>>'{next_cursor,updated_at}')::timestamptz;
  v_after_id:=(v_page_one#>>'{next_cursor,id}')::uuid;
  if v_after_updated_at is null or v_after_id is null then
    raise exception 'v88 first page did not produce a complete cursor';
  end if;
  perform pg_temp.as_v88_user(v_sa);
  v_page_two_before:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',v_snapshot,1,v_after_updated_at,v_after_id
  );
  reset role;

  update public.businesses
  set name='MUTATED Website Firm',activated_at=clock_timestamp()
  where id=v_business;
  update public.sme_prospects
  set current_stage_key='lost',updated_at=clock_timestamp()
  where id=v_prospect;
  update public.sme_companies
  set trading_name='MUTATED Stale',email='mutated-v88@example.test',
    updated_at=clock_timestamp()
  where id=v_company;
  update public.sme_prospect_contacts
  set full_name='MUTATED Prospect Boss',phone='89999999',updated_at=clock_timestamp()
  where prospect_id=v_prospect and is_primary;
  insert into public.sme_companies(
    id,legal_name,trading_name,registration_number,industry,created_at,updated_at
  ) values(v_late_company,'V88 Late Pte Ltd','V88 Late','V88-UEN-LATE','retail',
    v_snapshot-interval '1 day',v_snapshot-interval '1 day');
  insert into public.sme_prospects(
    id,company_id,current_stage_key,stage_entered_at,created_at,updated_at
  ) values(v_late_prospect,v_late_company,'new_lead',
    v_snapshot-interval '1 day',v_snapshot-interval '1 day',
    v_snapshot-interval '1 day');

  perform pg_temp.as_v88_user(v_sa);
  v_page_two_after:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',v_snapshot,1,v_after_updated_at,v_after_id
  );
  v_result:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',v_snapshot,100,null,null
  );
  reset role;
  if v_page_two_after is distinct from v_page_two_before then
    raise exception 'v88 snapshot page changed after source mutations';
  end if;
  if (v_result->>'total_count')::integer<>3
     or exists(select 1 from jsonb_array_elements(v_result->'items') item
       where item->>'prospect_id'=v_late_prospect::text) then
    raise exception 'v88 snapshot membership changed after capture';
  end if;
  select value into v_item from jsonb_array_elements(v_result->'items')
    where value->>'business_id'=v_business::text;
  if v_item->>'name'<>'V88 Website Firm'
     or v_item->>'onboarding_status'<>'not_started' then
    raise exception 'v88 frozen website content/status drifted after activation';
  end if;

  perform pg_temp.as_v88_user(v_sa);
  v_attention:=public.platform_list_firm_attention_v88(v_snapshot,100,null,null);
  reset role;
  if not exists(select 1 from jsonb_array_elements(v_attention->'items') item
      where item->>'prospect_id'=v_prospect::text)
     or exists(select 1 from jsonb_array_elements(v_attention->'items') item
      where item->>'business_id' in (v_business::text,v_converted_business::text)) then
    raise exception 'v88 attention queue included a terminal firm or omitted stale work';
  end if;

  -- A new first-page request deliberately creates a new snapshot and must see
  -- the post-capture changes which the old token correctly hid.
  perform pg_temp.as_v88_user(v_sa);
  v_result:=public.platform_list_firm_onboarding_v88(
    '{"search":"V88"}',null,100,null,null
  );
  reset role;
  if (v_result->>'total_count')::integer<>4
     or not exists(select 1 from jsonb_array_elements(v_result->'items') item
       where item->>'prospect_id'=v_late_prospect::text)
     or not exists(select 1 from jsonb_array_elements(v_result->'items') item
       where item->>'prospect_id'=v_prospect::text and item->>'lane_key'='closed')
  then
    raise exception 'a fresh v88 snapshot did not see post-capture mutations';
  end if;
  select value into v_item from jsonb_array_elements(v_result->'items')
    where value->>'business_id'=v_business::text;
  if v_item->>'name'<>'MUTATED Website Firm'
     or v_item->>'onboarding_status'<>'activated' then
    raise exception 'fresh v88 snapshot did not reflect website activation evidence';
  end if;

  begin
    perform pg_temp.as_v88_user(v_outsider);
    perform public.platform_list_firm_onboarding_v88('{}',v_snapshot,10,null,null);
    reset role;
    raise exception 'non-SA executed the v88 firm reader';
  exception when insufficient_privilege then
    reset role;
  end;
end
$v88$;

rollback;
