-- V127 rollback-only acceptance. Run after the canonical chain through V127
-- in a disposable database. It proves the published birthday reader is the
-- only browser path: owner and Loyalty-read manager receive tenant-scoped
-- programme copy, denied/cross-tenant/anon callers fail, and the underlying
-- table plus draft writers remain closed.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v127_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v127_user(uuid,text)
  to authenticated, anon;

do $v127$
declare
  business_a uuid;
  business_b uuid;
  owner_a uuid;
  owner_b uuid;
  manager_read uuid:=gen_random_uuid();
  manager_denied uuid:=gen_random_uuid();
  draft_id uuid;
  programme_id uuid:=gen_random_uuid();
  snapshot_hash text;
  overview jsonb;
begin
  reset role;
  select id into business_a from public.businesses
   where name='Pristine chain fixture A';
  select id into business_b from public.businesses
   where name='Pristine chain fixture B';
  select user_id into owner_a from public.staff
   where business_id=business_a and role='owner' and active limit 1;
  select user_id into owner_b from public.staff
   where business_id=business_b and role='owner' and active limit 1;
  if business_a is null or business_b is null or owner_a is null or owner_b is null then
    raise exception 'V127 pristine tenant fixtures are incomplete';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',manager_read,
      'authenticated','authenticated','v127-reader-'||manager_read::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',manager_denied,
      'authenticated','authenticated','v127-denied-'||manager_denied::text||'@example.test','',now(),now(),now());
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (business_a,manager_read,'manager','V127 Loyalty reader',true,
      array['loyalty'],'{"loyalty":"r"}'::jsonb),
    (business_a,manager_denied,'manager','V127 denied manager',true,
      array['dashboard'],'{}'::jsonb);

  -- Publish one synthetic birthday rule through the existing owner-only draft
  -- path. This creates no customer, entitlement, redemption or outbound data.
  perform pg_temp.as_v127_user(owner_a);
  draft_id:=(public.create_loyalty_config_draft(
    business_a,null,'v127-birthday-reader-suite'
  )::jsonb->>'version_id')::uuid;
  select version.snapshot_hash into snapshot_hash
    from public.firm_config_versions version where version.id=draft_id;
  perform public.save_birthday_program_draft(
    draft_id,programme_id,jsonb_build_object(
      'active',true,
      'customer_label','Birthday Glow',
      'customer_description','Synthetic published overview benefit',
      'customer_terms','Synthetic acceptance only',
      'fulfillment_kind','discount_pct',
      'discount_percent',20,
      'window_days_before',7,
      'window_days_after',7,
      'sort',0
    ),snapshot_hash
  );
  perform public.publish_loyalty_config(draft_id);

  overview:=public.get_active_birthday_program(business_a);
  assert overview->>'status'='published',
    'owner must receive the published birthday status';
  assert (overview->>'as_of')::timestamptz is not null,
    'overview must carry the authoritative server as-of timestamp';
  assert overview#>>'{programs,0,customer_label}'='Birthday Glow',
    'owner must receive the exact published birthday copy';

  perform pg_temp.as_v127_user(manager_read);
  overview:=public.get_active_birthday_program(business_a);
  assert overview#>>'{programs,0,customer_label}'='Birthday Glow',
    'Loyalty-read manager must receive the same published copy';
  assert not (overview::text ~* 'birth_date|client_id|identity_id|entitlement'),
    'published programme JSON must not expose customer birthday data';
  begin
    perform public.get_birthday_program_draft(draft_id);
    raise exception 'V127 Loyalty-read manager unexpectedly received birthday draft access';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from public.birthday_program_versions;
    raise exception 'V127 manager direct birthday table read unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_v127_user(manager_denied);
  begin
    perform public.get_active_birthday_program(business_a);
    raise exception 'V127 denied manager unexpectedly read birthday programme';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_v127_user(owner_b);
  begin
    perform public.get_active_birthday_program(business_a);
    raise exception 'V127 cross-tenant owner unexpectedly read tenant A';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_v127_user(null,'anon');
  begin
    perform public.get_active_birthday_program(business_a);
    raise exception 'V127 anon unexpectedly executed birthday reader';
  exception when insufficient_privilege then null;
  end;

  reset role;
  assert not has_table_privilege(
    'authenticated','public.birthday_program_versions','select'
  ),'V127 must not grant authenticated SELECT on birthday_program_versions';
  assert has_function_privilege(
    'authenticated','public.get_active_birthday_program(uuid)','execute'
  ),'V127 authenticated reader RPC execute grant is missing';
  assert not has_function_privilege(
    'anon','public.get_active_birthday_program(uuid)','execute'
  ),'V127 anon must not execute the published birthday reader';

  raise notice 'V127 REWARDS OVERVIEW BIRTHDAY READER SUITE PASS';
end
$v127$;

rollback;
