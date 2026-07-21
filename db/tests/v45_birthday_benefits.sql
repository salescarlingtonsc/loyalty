-- C45 executable rollback-only acceptance suite. Run only on a disposable
-- database after the C45 migration; every fixture row and temporary feature
-- flag change is rolled back. It deliberately uses synthetic identities only.
begin;

create or replace function pg_temp.as_c45_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void
language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end;
$$;
grant execute on function pg_temp.as_c45_user(uuid,text) to public;

create or replace function pg_temp.expect_c45_denied(
  p_sql text,
  p_label text,
  p_sqlstate text default '42501'
) returns void language plpgsql as $$
declare v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    if v_state = p_sqlstate then return; end if;
    raise exception '% returned SQLSTATE %, expected %',p_label,v_state,p_sqlstate;
  end;
  raise exception '% unexpectedly succeeded',p_label;
end;
$$;
grant execute on function pg_temp.expect_c45_denied(text,text,text) to public;

do $c45$
declare
  v_business uuid; v_slug text; v_owner uuid; v_owner_staff uuid; v_branch uuid;
  v_customer uuid:=gen_random_uuid(); v_identity uuid:=gen_random_uuid(); v_client uuid:=gen_random_uuid();
  v_loyalty_r uuid:=gen_random_uuid(); v_loyalty_rw uuid:=gen_random_uuid(); v_denied uuid:=gen_random_uuid();
  v_foreign uuid:=gen_random_uuid(); v_loyalty_r_staff uuid; v_loyalty_rw_staff uuid; v_foreign_business uuid;
  v_draft uuid; v_program uuid:=gen_random_uuid(); v_hash text; v_saved jsonb; v_replay jsonb;
  v_benefit jsonb; v_activated jsonb; v_activated_replay jsonb; v_redeemed jsonb; v_reversed jsonb; v_staff_benefit jsonb;
  v_activation_key uuid:=gen_random_uuid();
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_ledger_before integer; v_ledger_after integer;
  v_calendar_year integer; v_calendar_year_tz integer;
  v_calendar_from timestamptz; v_calendar_until timestamptz;
  v_calendar_from_tz timestamptz; v_calendar_until_tz timestamptz;
begin
  reset role;
  select b.id,b.slug,s.user_id,s.id,br.id
    into v_business,v_slug,v_owner,v_owner_staff,v_branch
    from public.businesses b
    join public.staff s on s.business_id=b.id and s.role='owner' and s.active
    join public.branches br on br.business_id=b.id and br.active
   where 'loyalty'=any(coalesce(b.enabled_modules,'{}'::text[]))
   order by b.created_at,s.created_at,br.is_default desc,br.created_at
   limit 1;
  if v_business is null or v_owner is null or v_branch is null then
    raise exception 'C45 suite requires one active synthetic/disposable owner business with loyalty enabled';
  end if;

  -- Executable SG calendar contract. The observed date is never based on the
  -- connection timezone: Feb 29 maps to Feb 28 in a non-leap year, remains
  -- Feb 29 in a leap year, SG midnight is stable under another session zone,
  -- and a December birthday window can cross into January.
  if app.c45_observed_birthday(date '2000-02-29',2025) <> date '2025-02-28'
     or app.c45_observed_birthday(date '2000-02-29',2024) <> date '2024-02-29' then
    raise exception 'C45 Feb 29 observed-birthday calendar rule failed';
  end if;
  if exists(select 1 from app.c45_birthday_window(date '2000-01-01',0,0,'2024-12-31 15:59:59+00'::timestamptz)) then
    raise exception 'C45 SG midnight opened before 00:00 Asia/Singapore';
  end if;
  select birthday_year,valid_from,valid_until into v_calendar_year,v_calendar_from,v_calendar_until
    from app.c45_birthday_window(date '2000-01-01',0,0,'2025-01-01 00:00:00+08'::timestamptz);
  if v_calendar_year <> 2025 or v_calendar_from <> '2025-01-01 00:00:00+08'::timestamptz
     or v_calendar_until <> '2025-01-02 00:00:00+08'::timestamptz then
    raise exception 'C45 SG midnight window was not exact';
  end if;
  perform set_config('TimeZone','America/Los_Angeles',true);
  select birthday_year,valid_from,valid_until into v_calendar_year_tz,v_calendar_from_tz,v_calendar_until_tz
    from app.c45_birthday_window(date '2000-01-01',0,0,'2025-01-01 00:00:00+08'::timestamptz);
  if (v_calendar_year_tz,v_calendar_from_tz,v_calendar_until_tz)
       is distinct from (v_calendar_year,v_calendar_from,v_calendar_until) then
    raise exception 'C45 SG midnight window inherited the session timezone';
  end if;
  perform set_config('TimeZone','UTC',true);
  select birthday_year,valid_from,valid_until into v_calendar_year,v_calendar_from,v_calendar_until
    from app.c45_birthday_window(date '2000-02-29',0,0,'2025-02-28 12:00:00+08'::timestamptz);
  if v_calendar_year <> 2025 or v_calendar_from <> '2025-02-28 00:00:00+08'::timestamptz
     or v_calendar_until <> '2025-03-01 00:00:00+08'::timestamptz then
    raise exception 'C45 non-leap Feb 29 window failed';
  end if;
  select birthday_year,valid_from,valid_until into v_calendar_year,v_calendar_from,v_calendar_until
    from app.c45_birthday_window(date '2000-02-29',0,0,'2024-02-29 12:00:00+08'::timestamptz);
  if v_calendar_year <> 2024 or v_calendar_from <> '2024-02-29 00:00:00+08'::timestamptz
     or v_calendar_until <> '2024-03-01 00:00:00+08'::timestamptz then
    raise exception 'C45 leap-year Feb 29 window failed';
  end if;
  select birthday_year,valid_from,valid_until into v_calendar_year,v_calendar_from,v_calendar_until
    from app.c45_birthday_window(date '2000-12-31',0,2,'2025-01-01 12:00:00+08'::timestamptz);
  if v_calendar_year <> 2024 or v_calendar_from <> '2024-12-31 00:00:00+08'::timestamptz
     or v_calendar_until <> '2025-01-03 00:00:00+08'::timestamptz then
    raise exception 'C45 December/January birthday window failed';
  end if;

  -- Default off remains a catalog invariant before this rollback fixture turns
  -- the gate on locally. Raw C45 tables remain RLS/ACL closed to browsers.
  if not exists(select 1 from app.platform_feature_flags where feature_key='customer_birthday_benefits' and enabled=false) then
    raise exception 'C45 default off feature gate is missing';
  end if;
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                where n.nspname='public' and c.relname='customer_birthday_entitlements' and c.relrowsecurity)
     or has_table_privilege('authenticated','public.customer_birthday_entitlements','select')
     or has_function_privilege('authenticated','app.reverse_customer_birthday_benefit_redemption(uuid,text,uuid)','execute') then
    raise exception 'C45 RLS/ACL closure failed';
  end if;
  -- Each public staff path and the private reversal seam must fail closed
  -- before authorization, client discovery, or row access while the flag is
  -- off. Random IDs deliberately prove that no existing customer data is
  -- needed to obtain the feature-not-supported response.
  perform pg_temp.as_c45_user(v_owner);
  begin
    perform public.staff_get_customer_birthday_benefit(v_business,gen_random_uuid());
    raise exception 'C45 disabled staff birthday reader unexpectedly succeeded';
  exception when feature_not_supported then null;
  end;
  begin
    perform public.redeem_customer_birthday_benefit(v_business,gen_random_uuid(),v_branch,gen_random_uuid());
    raise exception 'C45 disabled birthday redemption unexpectedly succeeded';
  exception when feature_not_supported then null;
  end;
  begin
    perform public.reverse_customer_birthday_benefit_for_client(v_business,gen_random_uuid(),'synthetic correction',gen_random_uuid());
    raise exception 'C45 disabled public birthday reversal unexpectedly succeeded';
  exception when feature_not_supported then null;
  end;
  reset role;
  begin
    perform app.reverse_customer_birthday_benefit_redemption(gen_random_uuid(),'synthetic correction',gen_random_uuid());
    raise exception 'C45 disabled private birthday reversal unexpectedly succeeded';
  exception when feature_not_supported then null;
  end;
  update app.platform_feature_flags set enabled=true,changed_at=statement_timestamp()
   where feature_key in ('customer_identity','customer_claims','customer_wallet','customer_birthday_benefits');
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_owner_staff,v_branch) on conflict do nothing;

  -- Role matrix: loyalty-r can read the counter-safe projection only,
  -- loyalty-rw can perform the branch-scoped counter redemption, a missing
  -- loyalty key is denied, and a foreign owner/anon cannot cross the tenant.
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_loyalty_r,'authenticated','authenticated','c45-loyalty-r-'||v_loyalty_r::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_loyalty_rw,'authenticated','authenticated','c45-loyalty-rw-'||v_loyalty_rw::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_denied,'authenticated','authenticated','c45-denied-'||v_denied::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign,'authenticated','authenticated','c45-foreign-'||v_foreign::text||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values(v_business,v_loyalty_r,'manager','C45 loyalty-r staff',true,array['loyalty'],'{"loyalty":"r"}'::jsonb)
  returning id into v_loyalty_r_staff;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values(v_business,v_loyalty_rw,'manager','C45 loyalty-rw staff',true,array['loyalty'],'{"loyalty":"rw"}'::jsonb)
  returning id into v_loyalty_rw_staff;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values(v_business,v_denied,'manager','C45 denied staff',true,array['loyalty'],'{}'::jsonb);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_loyalty_rw_staff,v_branch) on conflict do nothing;
  perform pg_temp.as_c45_user(v_foreign);
  v_foreign_business:=(public.create_business(
    'C45 foreign matrix '||substr(v_foreign::text,1,8),
    'c45-foreign-'||substr(v_foreign::text,1,8),
    'test',array['dashboard','clients','sales','loyalty']
  )::jsonb->>'id')::uuid;
  reset role;
  if v_foreign_business is null then raise exception 'C45 foreign matrix business was not created'; end if;

  -- Owner draft/hash/replay/conflict/publish. The rule is explicit and typed;
  -- no starter programme, outbound provider, outbox, inbox, or notification
  -- work is introduced by this fixture.
  perform pg_temp.as_c45_user(v_owner);
  v_draft:=(public.create_loyalty_config_draft(v_business,null,'c45-rollback-suite')::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object('active',true));
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_saved:=public.save_birthday_program_draft(v_draft,v_program,jsonb_build_object(
    'active',true,'customer_label','C45 rollback birthday item','customer_description','Synthetic manual birthday benefit',
    'customer_terms','Synthetic only','fulfillment_kind','free_item','manual_item','Synthetic item',
    'window_days_before',0,'window_days_after',0,'sort',0
  ),v_hash);
  v_replay:=public.save_birthday_program_draft(v_draft,v_program,jsonb_build_object(
    'active',true,'customer_label','C45 rollback birthday item','customer_description','Synthetic manual birthday benefit',
    'customer_terms','Synthetic only','fulfillment_kind','free_item','manual_item','Synthetic item',
    'window_days_before',0,'window_days_after',0,'sort',0
  ),v_hash);
  if coalesce((v_saved->>'replayed')::boolean,true) or not coalesce((v_replay->>'replayed')::boolean,false) then
    raise exception 'C45 draft exact replay failed: %, %',v_saved,v_replay;
  end if;
  begin
    perform public.save_birthday_program_draft(v_draft,v_program,jsonb_build_object(
      'active',true,'customer_label','changed','customer_description','Synthetic manual birthday benefit',
      'customer_terms','Synthetic only','fulfillment_kind','free_item','manual_item','Synthetic item',
      'window_days_before',0,'window_days_after',0,'sort',0
    ),v_hash);
    raise exception 'C45 changed draft replay unexpectedly succeeded';
  exception when serialization_failure then null;
  end;
  perform public.publish_loyalty_config(v_draft);
  reset role;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
    'c45-'||v_customer::text||'@example.test','',now(),now(),now());
  insert into public.clients(id,business_id,full_name) values(v_client,v_business,'C45 rollback customer');
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_identity::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values(v_identity,v_customer,'C45 rollback customer',(timezone('Asia/Singapore',statement_timestamp()))::date);
  insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(v_business,v_identity,v_customer,v_client,'verified','phone_claim',now());

  -- Participation is separately default-off and rejects a nullable request;
  -- it is not marketing consent. SG current date makes an explicit current
  -- window; the helper separately covers Asia/Singapore cross-year and Feb 29.
  -- The DOB remains private: customer and counter JSON below are inspected for
  -- every sensitive key rather than copying it into entitlement or audit data.
  perform pg_temp.as_c45_user(v_customer);
  if coalesce((public.customer_get_birthday_participation()->>'opted_in')::boolean,true) then
    raise exception 'C45 participation was not default off';
  end if;
  begin
    perform public.customer_set_birthday_participation(null,gen_random_uuid());
    raise exception 'C45 nullable participation unexpectedly succeeded';
  exception when invalid_parameter_value then null;
  end;
  perform public.customer_set_birthday_participation(true,gen_random_uuid());
  v_benefit:=public.customer_get_birthday_benefit(v_slug);
  if v_benefit->>'status'<>'ready_to_activate' or v_benefit::text ~* '(birth_date|birthday_year|identity_id|client_id|program_id|config_version_id|savings|cost)' then
    raise exception 'C45 customer benefit was not safe/current-window: %',v_benefit;
  end if;
  v_activated:=public.customer_activate_birthday_benefit(v_slug,v_activation_key);
  v_activated_replay:=public.customer_activate_birthday_benefit(v_slug,v_activation_key);
  if v_activated is distinct from v_activated_replay then raise exception 'C45 activation exact replay failed'; end if;
  reset role;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_business and client_id=v_client order by activated_at desc limit 1;
  if app.c45_safe_birthday_entitlement(v_entitlement,v_entitlement.valid_until)->>'status'<>'expired' then
    raise exception 'C45 half-open expiry boundary failed';
  end if;
  v_benefit:=app.c45_customer_birthday_benefit_for_context(
    v_business,v_client,v_identity,(timezone('Asia/Singapore',statement_timestamp()))::date,v_entitlement.valid_until
  );
  if v_benefit->>'status'<>'expired' or not (v_benefit ? 'validity') then
    raise exception 'C45 customer effective expiry projection failed: %',v_benefit;
  end if;
  if app.c45_staff_safe_birthday_entitlement(v_entitlement,v_entitlement.valid_until)->>'status'<>'expired'
     or app.c45_staff_safe_birthday_entitlement(v_entitlement,v_entitlement.valid_until) ? 'validity' then
    raise exception 'C45 staff-safe effective expiry projection leaked a validity window';
  end if;

  -- The staff matrix is executable under real authenticated/anon roles. Read
  -- access alone exposes only a counter-safe projection; write access is
  -- needed for the branch-scoped redemption; reversal remains owner-only.
  perform pg_temp.as_c45_user(v_loyalty_r);
  v_staff_benefit:=public.staff_get_customer_birthday_benefit(v_business,v_client);
  if v_staff_benefit->>'status'<>'available'
     or v_staff_benefit::text ~* '"(validity|available_from|available_until|valid_from|valid_until|birth_date|dob|birthday_year|observed_date|identity_id|client_id|program_id|config_version_id|description|terms)"' then
    raise exception 'C45 loyalty-r reader was not a staff-safe available projection: %',v_staff_benefit;
  end if;
  perform pg_temp.expect_c45_denied(format(
    'select public.redeem_customer_birthday_benefit(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
    v_business,v_client,v_branch,gen_random_uuid()
  ),'C45 loyalty-r redemption');

  perform pg_temp.as_c45_user(v_denied);
  perform pg_temp.expect_c45_denied(format(
    'select public.staff_get_customer_birthday_benefit(%L::uuid,%L::uuid)',v_business,v_client
  ),'C45 denied staff reader');
  perform pg_temp.expect_c45_denied(format(
    'select public.redeem_customer_birthday_benefit(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
    v_business,v_client,v_branch,gen_random_uuid()
  ),'C45 denied staff redemption');

  perform pg_temp.as_c45_user(v_foreign);
  perform pg_temp.expect_c45_denied(format(
    'select public.staff_get_customer_birthday_benefit(%L::uuid,%L::uuid)',v_business,v_client
  ),'C45 foreign owner reader');
  perform pg_temp.expect_c45_denied(format(
    'select public.redeem_customer_birthday_benefit(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
    v_business,v_client,v_branch,gen_random_uuid()
  ),'C45 foreign owner redemption');

  perform pg_temp.as_c45_user(null,'anon');
  perform pg_temp.expect_c45_denied(format(
    'select public.staff_get_customer_birthday_benefit(%L::uuid,%L::uuid)',v_business,v_client
  ),'C45 anon reader');

  perform pg_temp.as_c45_user(v_owner);
  v_staff_benefit:=public.staff_get_customer_birthday_benefit(v_business,v_client);
  if v_staff_benefit->>'status'<>'available' then raise exception 'C45 owner reader lost same-business visibility'; end if;

  select (select count(*) from public.credit_ledger where business_id=v_business and client_id=v_client)
       + (select count(*) from public.points_ledger where business_id=v_business and client_id=v_client)
    into v_ledger_before;
  perform pg_temp.as_c45_user(v_loyalty_rw);
  v_redeemed:=public.redeem_customer_birthday_benefit(v_business,v_client,v_branch,gen_random_uuid());
  if v_redeemed->>'status'<>'redeemed' then raise exception 'C45 loyalty-rw manual counter redemption failed: %',v_redeemed; end if;
  perform pg_temp.expect_c45_denied(format(
    'select public.reverse_customer_birthday_benefit_for_client(%L::uuid,%L::uuid,%L,%L::uuid)',
    v_business,v_client,'synthetic non-owner correction',gen_random_uuid()
  ),'C45 loyalty-rw owner-only reversal');
  perform pg_temp.as_c45_user(v_owner);
  v_reversed:=public.reverse_customer_birthday_benefit_for_client(v_business,v_client,'synthetic correction',gen_random_uuid());
  if v_reversed->>'status'<>'reversed' then raise exception 'C45 owner-only client-scoped reversal failed: %',v_reversed; end if;
  select (select count(*) from public.credit_ledger where business_id=v_business and client_id=v_client)
       + (select count(*) from public.points_ledger where business_id=v_business and client_id=v_client)
    into v_ledger_after;
  if v_ledger_before<>v_ledger_after then raise exception 'C45 birthday flow touched money/points ledger'; end if;
end;
$c45$;

rollback;
