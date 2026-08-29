-- Rollback-only acceptance for NESTLY v623 — cross-tenant customer PII reads are capped,
-- reasoned, and audited.
--
-- Proves, at the server boundary only:
--   · exactly ONE platform_list_enterprise_customers_v82 exists (the 10-argument overload is
--     dropped, so PostgREST named-argument calls cannot go ambiguous);
--   · the page-size ceiling is 200, not 500;
--   · a read scoped to exactly one business needs no reason but is still audited;
--   · any broader read — the export shape — is refused without a reason of >= 8 characters;
--   · every accepted read writes PLATFORM_PII_READ_V623 with actor, scope, counts and reason.
--
-- Self-contained fixtures (gen_random_uuid), audit evidence measured as a DELTA, and one
-- transaction that ends in rollback — safe to run against production.
begin;

create or replace function pg_temp.as_v623_session(
  p_uid uuid,
  p_method text default 'password',
  p_role text default 'authenticated'
) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then
    return;
  end if;
  if p_role is not null then
    execute format('set local role %I',p_role);
  end if;
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',p_uid,
      'role',coalesce(p_role,'authenticated'),
      'amr',jsonb_build_array(
        jsonb_build_object('method',p_method,'timestamp',1756500000)
      ),
      'app_metadata',case when p_method='oauth'
        then jsonb_build_object(
          'provider','google','providers',jsonb_build_array('email','google'))
        else jsonb_build_object(
          'provider','email','providers',jsonb_build_array('email')) end
    )::text,
    true
  );
end
$fn$;
grant execute on function pg_temp.as_v623_session(uuid,text,text) to public;

do $v623_main$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_biz_one uuid:=gen_random_uuid();
  v_biz_two uuid:=gen_random_uuid();
  v_reason text:='v623 security audit test '||substr(gen_random_uuid()::text,1,8);
  v_audit_before bigint;
  v_audit_after bigint;
  v_result jsonb;
  v_message text;
begin
  reset role;

  -- D1 · one overload only, and it carries the reason parameter.
  if (
    select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='platform_list_enterprise_customers_v82'
  )<>1 then
    raise exception 'v623 D1: platform_list_enterprise_customers_v82 is not a single overload';
  end if;
  if (
    select p.pronargs from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='platform_list_enterprise_customers_v82'
  )<>11 then
    raise exception 'v623 D2: the enterprise customer reader does not take a reason';
  end if;

  -- D3 · the PII door is never anon-callable.
  if has_function_privilege(
       'anon',
       'public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text)',
       'EXECUTE') then
    raise exception 'v623 D3: the enterprise customer reader is anon-callable';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v623-super-'||substr(v_super::text,1,8)||'@example.test'),
    (v_owner,'v623-owner-'||substr(v_owner::text,1,8)||'@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v623-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v623 fixture'
  );

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values
    (v_biz_one,'V623 PII fixture one','v623-one-'||substr(v_biz_one::text,1,8),'test',
      array['dashboard','clients','sales','loyalty','retention','reports']),
    (v_biz_two,'V623 PII fixture two','v623-two-'||substr(v_biz_two::text,1,8),'test',
      array['dashboard','clients','sales','loyalty','retention','reports']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_biz_one,v_owner,'owner','V623 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values
    (v_biz_one,'Primary',true,true),
    (v_biz_two,'Primary',true,true);
  insert into public.clients(business_id,full_name,phone)
  values
    (v_biz_one,'V623 Customer One','+6598230001'),
    (v_biz_two,'V623 Customer Two','+6598230002');

  select count(*) into v_audit_before
    from public.audit_log where action='PLATFORM_PII_READ_V623';

  -- D4 · a tenant owner never reaches cross-tenant PII.
  perform pg_temp.as_v623_session(v_owner,'password');
  begin
    perform public.platform_list_enterprise_customers_v82(
      p_businesses=>array[v_biz_one],p_limit=>50
    );
    raise exception 'v623 D4: a tenant owner read cross-tenant customer PII';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v623_session(v_super,'oauth');

  -- D5 · the page-size ceiling dropped to 200.
  begin
    perform public.platform_list_enterprise_customers_v82(
      p_businesses=>array[v_biz_one],p_limit=>500
    );
    raise exception 'v623 D5: a 500-row PII page was accepted';
  exception when sqlstate '22023' then
    get stacked diagnostics v_message=message_text;
    if v_message not like '%200%' then
      raise exception 'v623 D6: the page-size refusal does not name the 200 ceiling: %',v_message;
    end if;
  end;

  -- D7 · a broad (export-shaped) read without a stated reason is refused.
  begin
    perform public.platform_list_enterprise_customers_v82(
      p_businesses=>array[v_biz_one,v_biz_two],p_limit=>50
    );
    raise exception 'v623 D7: a reasonless multi-firm PII export was accepted';
  exception when sqlstate '22023' then
    get stacked diagnostics v_message=message_text;
    if v_message not like '%reason%' then
      raise exception 'v623 D8: the broad-read refusal does not name the reason: %',v_message;
    end if;
  end;

  -- D9 · the same read with a stated reason succeeds.
  v_result:=public.platform_list_enterprise_customers_v82(
    p_businesses=>array[v_biz_one,v_biz_two],p_limit=>50,p_reason=>v_reason
  );
  if v_result->'customers' is null
     or (v_result#>>'{pagination,limit}')::integer<>50 then
    raise exception 'v623 D9: the reasoned PII read returned no page: %',v_result;
  end if;

  -- D10 · a single-firm support read needs no reason.
  v_result:=public.platform_list_enterprise_customers_v82(
    p_businesses=>array[v_biz_one],p_limit=>50
  );
  if v_result->'customers' is null then
    raise exception 'v623 D10: a scoped single-firm read was refused';
  end if;

  reset role;

  -- D11 · both accepted reads left exactly one audit row each — no more, no fewer.
  select count(*) into v_audit_after
    from public.audit_log where action='PLATFORM_PII_READ_V623';
  if v_audit_after-v_audit_before<>2 then
    raise exception 'v623 D11: expected 2 new PII audit rows, saw %',v_audit_after-v_audit_before;
  end if;

  -- D12 · the export row carries the stated reason and the actor.
  if not exists(
    select 1 from public.audit_log log_row
    where log_row.action='PLATFORM_PII_READ_V623'
      and log_row.detail->>'reason'=v_reason
      and log_row.actor=v_super
      and log_row.entity='clients'
      and (log_row.detail->>'limit')::integer=50
      and log_row.detail->'total_customers' is not null
  ) then
    raise exception 'v623 D12: the reasoned export left no complete audit evidence';
  end if;

  -- D13 · the scoped support read is audited too, against the firm it looked at.
  if not exists(
    select 1 from public.audit_log log_row
    where log_row.action='PLATFORM_PII_READ_V623'
      and log_row.business_id=v_biz_one
      and log_row.actor=v_super
      and log_row.detail->>'reason' is null
  ) then
    raise exception 'v623 D13: the scoped single-firm read left no audit evidence';
  end if;

  perform pg_temp.as_v623_session(null);
  raise notice 'v623 PII read audit suite: ALL PASS';
end
$v623_main$;

reset role;
rollback;
