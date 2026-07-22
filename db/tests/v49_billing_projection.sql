-- Rollback-only v49 billing projection authorization and ACL suite.
-- Run after the complete canonical chain through v49. Synthetic rows never commit.
begin;

create temporary table pg_temp.v49_fixture(
  business_id uuid primary key,
  other_business_id uuid not null,
  owner_id uuid not null,
  member_id uuid not null,
  inactive_id uuid not null,
  other_owner_id uuid not null
) on commit drop;

do $v49_fixture$
declare
  v_business uuid;
  v_other_business uuid;
  v_owner uuid := gen_random_uuid();
  v_member uuid := gen_random_uuid();
  v_inactive uuid := gen_random_uuid();
  v_other_owner uuid := gen_random_uuid();
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated','v49-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_member,'authenticated','authenticated','v49-member-'||substr(v_member::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_inactive,'authenticated','authenticated','v49-inactive-'||substr(v_inactive::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other_owner,'authenticated','authenticated','v49-other-'||substr(v_other_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V49 synthetic billing','v49-billing-'||substr(v_owner::text,1,8),'test',array['dashboard'])
  returning id into v_business;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V49 synthetic other tenant','v49-other-'||substr(v_other_owner::text,1,8),'test',array['dashboard'])
  returning id into v_other_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values
    (v_business,v_owner,'owner','V49 Owner',true),
    (v_business,v_member,'staff','V49 Member',true),
    (v_business,v_inactive,'owner','V49 Inactive Owner',false),
    (v_business,null,'staff','V49 Roster Only',true),
    (v_other_business,v_other_owner,'owner','V49 Other Tenant Owner',true);

  insert into public.subscriptions(
    business_id,status,currency,base_price_cents,included_seats,per_seat_price_cents
  ) values (v_business,'active','SGD',2500,1,3000)
  on conflict (business_id) do update set
    status=excluded.status,
    currency=excluded.currency,
    base_price_cents=excluded.base_price_cents,
    included_seats=excluded.included_seats,
    per_seat_price_cents=excluded.per_seat_price_cents;

  insert into pg_temp.v49_fixture values(
    v_business,v_other_business,v_owner,v_member,v_inactive,v_other_owner
  );
end
$v49_fixture$;

grant select on pg_temp.v49_fixture to public;

create or replace function pg_temp.as_v49_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v49_user(uuid,text) to public;

create or replace function pg_temp.expect_v49_error(
  p_sql text,
  p_label text,
  p_sqlstate text default '42501'
)
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_sqlstate then
    raise exception '% failed with %, expected %: %',p_label,sqlstate,p_sqlstate,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v49_error(text,text,text) to public;

do $v49_acl$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.get_business_billing_v49(uuid)'::regprocedure)
    into v_definition;
  if position('SECURITY DEFINER' in upper(v_definition))=0
     or position('SET search_path TO ''pg_catalog'', ''public'', ''app'', ''pg_temp''' in v_definition)=0 then
    raise exception 'v49 billing projection must be SECURITY DEFINER with a pinned search_path';
  end if;
  if has_function_privilege('anon','public.get_business_billing_v49(uuid)'::regprocedure,'execute')
     or not has_function_privilege('authenticated','public.get_business_billing_v49(uuid)'::regprocedure,'execute') then
    raise exception 'v49 billing projection ACL is not authenticated-only';
  end if;
  if has_function_privilege('authenticated','app.billable_seats(uuid)'::regprocedure,'execute') then
    raise exception 'v49 exposed the private billable seat helper';
  end if;
end
$v49_acl$;

do $v49_owner_allowed$
declare
  f pg_temp.v49_fixture%rowtype;
  v_result jsonb;
  v_key_count integer;
begin
  select * into f from pg_temp.v49_fixture;
  perform pg_temp.as_v49_user(f.owner_id);
  v_result:=public.get_business_billing_v49(f.business_id);
  if v_result->>'business_id'<>f.business_id::text
     or (v_result->>'billable_seats')::integer<>2
     or (v_result->>'extra_seats')::integer<>1
     or (v_result->>'monthly_total_cents')::bigint<>5500 then
    raise exception 'owner billing projection mismatch: %',v_result;
  end if;
  select count(*) into v_key_count from jsonb_object_keys(v_result);
  if v_key_count<>12 or not v_result ?& array[
    'business_id','status','currency','base_price_cents','included_seats',
    'per_seat_price_cents','billable_seats','extra_seats','monthly_total_cents',
    'trial_ends_at','current_period_start','current_period_end'
  ] then
    raise exception 'billing projection is not the finite v49 allowlist: %',v_result;
  end if;

end
$v49_owner_allowed$;

reset role;
do $v49_non_owner_denied$
declare f pg_temp.v49_fixture%rowtype;
begin
  select * into f from pg_temp.v49_fixture;
  perform pg_temp.as_v49_user(f.member_id);
  perform pg_temp.expect_v49_error(
    format('select public.get_business_billing_v49(%L)',f.business_id),
    'active same-business non-owner billing read'
  );
end
$v49_non_owner_denied$;

reset role;
do $v49_inactive_denied$
declare f pg_temp.v49_fixture%rowtype;
begin
  select * into f from pg_temp.v49_fixture;
  perform pg_temp.as_v49_user(f.inactive_id);
  perform pg_temp.expect_v49_error(
    format('select public.get_business_billing_v49(%L)',f.business_id),
    'inactive owner billing read'
  );
end
$v49_inactive_denied$;

reset role;
do $v49_cross_business_denied$
declare f pg_temp.v49_fixture%rowtype;
begin
  select * into f from pg_temp.v49_fixture;
  perform pg_temp.as_v49_user(f.other_owner_id);
  perform pg_temp.expect_v49_error(
    format('select public.get_business_billing_v49(%L)',f.business_id),
    'active owner from another business billing read'
  );
end
$v49_cross_business_denied$;

reset role;
do $v49_anon_denied$
declare f pg_temp.v49_fixture%rowtype;
begin
  select * into f from pg_temp.v49_fixture;
  perform pg_temp.as_v49_user(null,'anon');
  perform pg_temp.expect_v49_error(
    format('select public.get_business_billing_v49(%L)',f.business_id),
    'anonymous billing read'
  );
end
$v49_anon_denied$;

reset role;
do $v49_done$
begin
  raise notice 'v49 billing projection suite: ALL PASS';
end
$v49_done$;
rollback;
