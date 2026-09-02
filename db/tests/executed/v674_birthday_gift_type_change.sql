-- Rollback-only v674 acceptance suite — a PUBLISHED birthday gift can change its type.
--
-- The whole point is that this runs the REAL owner path end to end: the same RPC the browser
-- calls (business_save_birthday_program_v424), as an `authenticated` principal, on a programme
-- that is already published — so the draft-clone trigger fires and hands
-- save_birthday_program_draft the previous kind's benefit column, which is exactly what used to
-- make the save impossible.
--
--   T1  A first birthday gift (discount_pct) publishes.  [the path that always worked]
--   T2  discount_pct -> free_item publishes, and the live row holds the item and NO discount.
--   T3  free_item -> discount_pct publishes, and the live row holds the discount and NO item.
--   T4  A same-kind edit (new percentage, new wording) still saves — the fix did not narrow it.
--   T5  A payload that names the OTHER kind's field is still refused with 22023.
--
-- Run against a database carrying the canonical chain through v674. Everything is inside one
-- transaction that rolls back; the fixture is synthetic.
begin;

create or replace function pg_temp.as_owner(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
end $$;
grant execute on function pg_temp.as_owner(uuid) to public;

create temporary table v674_evidence(test text, detail text) on commit drop;
-- the suite records evidence while acting as `authenticated`, not as the owner of the table
grant insert, select on v674_evidence to public;

do $v674$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_seed uuid := gen_random_uuid();
  v_res jsonb;
  v_program uuid;
  v_row public.birthday_program_versions%rowtype;
  v_active uuid;
begin
  reset role;

  -- ---------------------------------------------------------------- FIXTURE
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v674-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,is_synthetic,enabled_modules)
  values (v_business,'V674 birthday fixture '||substr(v_business::text,1,8),
          'v674-birthday-'||substr(v_business::text,1,8),'test',true,
          array['dashboard','clients','sales','loyalty']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','V674 rollback owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_business,'V674 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='v674 rollback acceptance fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  -- v620 entitlement gate: an operational workspace needs a live subscription.
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  -- A published loyalty configuration, so businesses.active_config_version_id is non-null and
  -- every later draft is based on it (which is what makes the clone trigger fire).
  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
  values (v_seed,v_business,1,'draft','manual',md5('v674-seed'),v_owner);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode
  ) values (v_seed,v_business,'points','classic',true,1,100,500,'points_earned','none');
  update public.firm_config_versions set status='published',published_at=clock_timestamp() where id=v_seed;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,current_config_version_id
  ) values (v_business,'points',true,'classic','published',v_seed);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_seed where id=v_business;
  perform set_config('app.v79_system_transition','',true);

  -- ---------------------------------------------------------------- T1 create
  perform pg_temp.as_owner(v_owner);
  v_res := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','Birthday treat','customer_description','A little something',
    'customer_terms','One per birthday','fulfillment_kind','discount_pct','discount_percent',10,
    'window_days_before',0,'window_days_after',0,'sort',0,'window_mode','days'
  ), 'v674-create-'||substr(v_business::text,1,8));
  if v_res->>'status' <> 'published' then raise exception 'T1 FAIL: status %', v_res->>'status'; end if;
  v_program := (v_res->>'program_id')::uuid;
  insert into v674_evidence values('T1','first gift published as discount_pct 10%');

  -- ---------------------------------------------------------------- T2 discount_pct -> free_item
  -- Exactly the payload the editor builds: one benefit key, the one for the NEW kind.
  v_res := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','Birthday treat','customer_description','A little something',
    'customer_terms','One per birthday','fulfillment_kind','free_item','manual_item','Slice of cake',
    'window_days_before',0,'window_days_after',0,'sort',0,'window_mode','days'
  ), 'v674-to-item-'||substr(v_business::text,1,8));
  if v_res->>'status' <> 'published' then raise exception 'T2 FAIL: status %', v_res->>'status'; end if;
  if (v_res->>'program_id')::uuid <> v_program then
    raise exception 'T2 FAIL: the switch created a second programme'; end if;
  select active_config_version_id into v_active from public.businesses where id=v_business;
  select * into v_row from public.birthday_program_versions
   where business_id=v_business and config_version_id=v_active and program_id=v_program;
  if v_row.fulfillment_kind <> 'free_item' then raise exception 'T2 FAIL: kind %', v_row.fulfillment_kind; end if;
  if v_row.discount_percent is not null then
    raise exception 'T2 FAIL: the old discount survived the switch (%)', v_row.discount_percent; end if;
  if v_row.manual_item <> 'Slice of cake' then raise exception 'T2 FAIL: item %', v_row.manual_item; end if;
  insert into v674_evidence values('T2','discount_pct -> free_item published, discount cleared');

  -- ---------------------------------------------------------------- T3 free_item -> discount_pct
  v_res := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','Birthday treat','customer_description','A little something',
    'customer_terms','One per birthday','fulfillment_kind','discount_pct','discount_percent',15,
    'window_days_before',0,'window_days_after',0,'sort',0,'window_mode','days'
  ), 'v674-to-pct-'||substr(v_business::text,1,8));
  if v_res->>'status' <> 'published' then raise exception 'T3 FAIL: status %', v_res->>'status'; end if;
  select active_config_version_id into v_active from public.businesses where id=v_business;
  select * into v_row from public.birthday_program_versions
   where business_id=v_business and config_version_id=v_active and program_id=v_program;
  if v_row.fulfillment_kind <> 'discount_pct' then raise exception 'T3 FAIL: kind %', v_row.fulfillment_kind; end if;
  if v_row.manual_item is not null then
    raise exception 'T3 FAIL: the old item survived the switch (%)', v_row.manual_item; end if;
  if v_row.discount_percent <> 15 then raise exception 'T3 FAIL: discount %', v_row.discount_percent; end if;
  insert into v674_evidence values('T3','free_item -> discount_pct published, item cleared');

  -- ---------------------------------------------------------------- T4 same-kind edit
  v_res := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
    'active',true,'customer_label','Birthday treat','customer_description','A bigger something',
    'customer_terms','One per birthday','fulfillment_kind','discount_pct','discount_percent',20,
    'window_days_before',0,'window_days_after',0,'sort',0,'window_mode','days'
  ), 'v674-same-kind-'||substr(v_business::text,1,8));
  if v_res->>'status' <> 'published' then raise exception 'T4 FAIL: status %', v_res->>'status'; end if;
  select active_config_version_id into v_active from public.businesses where id=v_business;
  select * into v_row from public.birthday_program_versions
   where business_id=v_business and config_version_id=v_active and program_id=v_program;
  if v_row.discount_percent <> 20 or v_row.customer_description <> 'A bigger something'
     or v_row.manual_item is not null then
    raise exception 'T4 FAIL: same-kind edit stored %/%/%',
      v_row.discount_percent, v_row.customer_description, v_row.manual_item; end if;
  insert into v674_evidence values('T4','same-kind edit still saves');

  -- ---------------------------------------------------------------- T5 self-contradicting payload
  -- The fix relaxes what is INHERITED, never what is ACCEPTED: a payload that names the other
  -- kind's field is still invalid.
  begin
    perform public.business_save_birthday_program_v424(v_business, jsonb_build_object(
      'active',true,'customer_label','Birthday treat','customer_description','A little something',
      'customer_terms','One per birthday','fulfillment_kind','free_item',
      'manual_item','Slice of cake','discount_percent',10,
      'window_days_before',0,'window_days_after',0,'sort',0,'window_mode','days'
    ), 'v674-contradiction-'||substr(v_business::text,1,8));
    raise exception 'T5 FAIL: free_item WITH a discount was accepted';
  exception when sqlstate '22023' then
    insert into v674_evidence values('T5','free_item carrying a discount is still refused (22023)');
  end;

  reset role;
end
$v674$;

select test, detail from v674_evidence order by test;

reset role;
rollback;
