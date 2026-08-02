-- V138 rollback-only acceptance. Run after the canonical chain through V138
-- in a disposable database. It proves exact-reward draft continuity,
-- optimistic concurrency, tenant authorization, eligibility preservation and
-- the no-publish boundary.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v138_user(
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
grant execute on function pg_temp.as_v138_user(uuid,text)
  to authenticated,anon;

do $v138$
declare
  business_a uuid;
  business_b uuid;
  owner_a uuid;
  owner_b uuid;
  active_before uuid;
  draft_id uuid;
  draft_hash text;
  source_config uuid;
  source_hash text;
  published_before uuid;
  source_reward uuid := gen_random_uuid();
  unrelated_reward uuid := gen_random_uuid();
  source_retention uuid := gen_random_uuid();
  source_birthday uuid := gen_random_uuid();
  source_version uuid;
  taxonomy_id uuid;
  service_a uuid;
  matrix_referrer uuid := gen_random_uuid();
  matrix_referred uuid := gen_random_uuid();
  matrix_referral uuid := gen_random_uuid();
  matrix_plan uuid;
  matrix_memberships_before integer;
  matrix_sales_before integer;
  retention_manager uuid:=gen_random_uuid();
  oauth_new_user uuid:=gen_random_uuid();
  oauth_other_user uuid:=gen_random_uuid();
  oauth_email_user uuid:=gen_random_uuid();
  oauth_token uuid:=gen_random_uuid();
  oauth_expired_token uuid:=gen_random_uuid();
  oauth_idempotency uuid:=gen_random_uuid();
  oauth_expired_idempotency uuid:=gen_random_uuid();
  shared_draft uuid;
  result jsonb;
  replay jsonb;
  denied boolean;
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
  select active_config_version_id into active_before
    from public.businesses where id=business_a;
  if business_a is null or business_b is null
     or owner_a is null or owner_b is null or active_before is null then
    raise exception 'V138 pristine tenant fixtures are incomplete';
  end if;

  perform pg_temp.as_v138_user(owner_a);
  draft_id := (public.create_loyalty_config_draft(
    business_a,active_before,'v138-stale-reward-continuity'
  )::jsonb->>'version_id')::uuid;

  -- Reproduce the legacy/stale state seen by the owner: the published reward is
  -- newer than this editable draft, so the clicked reward is absent from it.
  reset role;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(business_a,'Signature radiance facial',16800,75,true)
  returning id into service_a;
  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,
    current_config_version_id
  ) values(
    unrelated_reward,business_a,'Unrelated draft benefit',
    'Unrelated draft benefit','Unrelated draft benefit','manual_item',
    900,0,300,false,2,draft_id
  );
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort
  ) values(
    unrelated_reward,business_a,draft_id,'Unrelated draft benefit',
    'Unrelated draft benefit','manual_item',900,0,300,true,2
  );
  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,description,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort,
    current_config_version_id
  ) values(
    source_reward,business_a,'Published facial reward','Published facial reward',
    'Published facial reward','Synthetic V138 published source reward',
    'manual_item',500,0,400,true,7,active_before
  );
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,
    description,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,sort
  ) values(
    source_reward,business_a,active_before,'Published facial reward',
    'Published facial reward','Synthetic V138 published source reward',
    'manual_item',500,0,400,true,7
  ) returning id into source_version;
  insert into public.loyalty_reward_services(
    reward_version_id,reward_id,business_id,service_id
  ) values(source_version,source_reward,business_a,service_a);
  select id into taxonomy_id from public.firm_reward_taxonomy
   where business_id=business_a and active and fulfillment_kind='free_item'
   order by sort,id limit 1;
  if taxonomy_id is null then
    raise exception 'V138 retention taxonomy fixture is unavailable';
  end if;
  perform pg_temp.as_v138_user(owner_a);
  source_config:=(public.create_loyalty_config_draft(
    business_a,active_before,'v138-published-programme-source'
  )::jsonb->>'version_id')::uuid;
  select snapshot_hash into source_hash from public.firm_config_versions
   where id=source_config;
  perform public.save_retention_program_draft(
    source_config,source_retention,jsonb_build_object(
      'name','Published return facial','active',true,'goal_visits',2,
      'period_days',45,'starts_on',current_date,
      'reward_taxonomy_id',taxonomy_id,'manual_item','LED mask add-on','sort',3,
      'customer_description','Return within 45 days',
      'staff_description','Offer after the qualifying visit'
    ),source_hash
  );
  select snapshot_hash into source_hash from public.firm_config_versions
   where id=source_config;
  perform public.save_birthday_program_draft(
    source_config,source_birthday,jsonb_build_object(
      'active',true,'customer_label','Birthday glow',
      'customer_description','Enjoy a birthday facial saving',
      'customer_terms','One use in the birthday window',
      'fulfillment_kind','discount_pct','discount_percent',15,
      'window_days_before',7,'window_days_after',7,'sort',4
    ),source_hash
  );
  perform public.publish_loyalty_config(source_config);
  reset role;
  published_before:=source_config;
  perform app.refresh_loyalty_config_snapshot(draft_id);
  select snapshot_hash into draft_hash
    from public.firm_config_versions where id=draft_id;

  perform pg_temp.as_v138_user(owner_a);
  result := public.ensure_published_reward_in_draft_v138(
    draft_id,source_reward,draft_hash
  );
  assert (result->>'reward_id')::uuid=source_reward
     and (result->>'config_version_id')::uuid=draft_id
     and not (result->>'published')::boolean
     and not (result->>'replayed')::boolean,
    'first continuity call must add only the selected unpublished draft reward';
  reset role;
  assert (select count(*) from public.loyalty_reward_versions
           where config_version_id=draft_id and reward_id=source_reward)=1,
    'selected published reward was not materialized exactly once';
  assert (select count(*) from public.loyalty_reward_versions
           where config_version_id=draft_id and reward_id=unrelated_reward)=1,
    'unrelated draft reward was removed or overwritten';
  assert (select count(*) from public.loyalty_reward_services s
           join public.loyalty_reward_versions v on v.id=s.reward_version_id
          where v.config_version_id=draft_id and v.reward_id=source_reward
            and s.service_id=service_a)=1,
    'selected reward eligibility was not preserved';
  assert (select status from public.firm_config_versions where id=draft_id)='draft'
     and (select active_config_version_id from public.businesses where id=business_a)=published_before,
    'continuity function published or changed the active configuration';

  perform pg_temp.as_v138_user(owner_a);
  -- Simulate a committed first request whose HTTP response was lost: retry the
  -- exact operation with the OLD hash, not the response hash.
  replay := public.ensure_published_reward_in_draft_v138(
    draft_id,source_reward,draft_hash
  );
  assert (replay->>'replayed')::boolean
     and (replay->>'reward_version_id')=(result->>'reward_version_id'),
    'same reward retry must return the existing draft version';
  reset role;
  assert (select count(*) from public.audit_log
           where business_id=business_a and action='MATERIALIZE_REWARD_DRAFT'
             and entity_id=source_reward)=1,
    'idempotent replay must not duplicate the materialization audit';

  draft_hash:=result->>'snapshot_hash';
  perform pg_temp.as_v138_user(owner_a);
  result:=public.ensure_published_retention_in_draft_v138(
    draft_id,source_retention,draft_hash
  );
  replay:=public.ensure_published_retention_in_draft_v138(
    draft_id,source_retention,draft_hash
  );
  assert (result->>'program_id')::uuid=source_retention
     and (replay->>'replayed')::boolean,
    'Bring-back continuity or old-hash lost-response replay failed';
  reset role;
  assert (select count(*) from public.retention_program_versions
           where config_version_id=draft_id and program_id=source_retention)=1,
    'published Bring-back rule was not materialized exactly once';

  draft_hash:=result->>'snapshot_hash';
  perform pg_temp.as_v138_user(owner_a);
  result:=public.ensure_published_birthday_in_draft_v138(
    draft_id,source_birthday,draft_hash
  );
  replay:=public.ensure_published_birthday_in_draft_v138(
    draft_id,source_birthday,draft_hash
  );
  assert (result->>'program_id')::uuid=source_birthday
     and (replay->>'replayed')::boolean,
    'birthday continuity or old-hash lost-response replay failed';
  reset role;
  assert (select count(*) from public.birthday_program_versions
           where config_version_id=draft_id and program_id=source_birthday)=1,
    'published birthday benefit was not materialized exactly once';
  assert (select count(*) from public.audit_log where business_id=business_a
           and action in('MATERIALIZE_RETENTION_DRAFT','MATERIALIZE_BIRTHDAY_DRAFT'))=2,
    'programme continuity audits were missing or duplicated';

  -- The two non-versioned Grow families have real OFF execution boundaries as
  -- well. A disabled referral programme cannot turn a pending referral into a
  -- reward when a sale arrives, and an inactive membership plan cannot create
  -- either a membership or its financial sale. Existing history is retained;
  -- OFF blocks only new customer-facing actions.
  reset role;
  assert (select enabled_modules @> array['referrals','memberships']
            from public.businesses where id=business_a),
    'V138 full-service fixture lacks referral or membership entitlement';
  insert into public.clients(id,business_id,full_name,referral_code)
  values
    (matrix_referrer,business_a,'V138 matrix referrer','V138REF1'),
    (matrix_referred,business_a,'V138 matrix referred','V138REF2');
  insert into public.referrals(
    id,business_id,referrer_client_id,referred_client_id,status
  ) values(matrix_referral,business_a,matrix_referrer,matrix_referred,'pending');

  perform pg_temp.as_v138_user(owner_a);
  result:=public.save_referral_program(business_a,false,700,1000);
  assert not (result->>'enabled')::boolean,
    'owner could not switch the referral programme off';
  reset role;
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note)
  values(business_a,matrix_referred,'quick_sale',2000,statement_timestamp(),
    'V138 disabled referral visibility matrix');
  assert (select status from public.referrals where id=matrix_referral)='pending'
     and not exists(select 1 from public.credit_ledger
       where business_id=business_a and client_id=matrix_referrer
         and entry_type='referral_reward'),
    'disabled referral programme created a customer reward';

  perform pg_temp.as_v138_user(owner_a);
  result:=public.save_membership_plan(
    business_a,null,'V138 paused customer plan',9900,'monthly',1000,5,true
  );
  matrix_plan:=(result->>'plan_id')::uuid;
  perform public.save_membership_plan(
    business_a,matrix_plan,'V138 paused customer plan',9900,'monthly',1000,5,false
  );
  reset role;
  select count(*) into matrix_memberships_before from public.memberships
   where business_id=business_a and client_id=matrix_referred;
  select count(*) into matrix_sales_before from public.sales
   where business_id=business_a and client_id=matrix_referred and kind='membership';
  perform pg_temp.as_v138_user(owner_a);
  denied:=false;
  begin
    perform public.enroll_membership_v41(
      business_a,matrix_referred,matrix_plan,gen_random_uuid()
    );
  exception when others then denied:=true;
  end;
  assert denied,'inactive membership plan accepted a new enrolment';
  reset role;
  assert (select count(*) from public.memberships
           where business_id=business_a and client_id=matrix_referred)=matrix_memberships_before
     and (select count(*) from public.sales
           where business_id=business_a and client_id=matrix_referred and kind='membership')=matrix_sales_before,
    'inactive membership attempt left partial customer or financial state';

  perform pg_temp.as_v138_user(owner_a);
  denied:=false;
  begin
    perform public.ensure_published_reward_in_draft_v138(
      draft_id,gen_random_uuid(),'stale-v138-snapshot'
    );
  exception when serialization_failure then denied:=true;
  end;
  assert denied,'stale snapshot was allowed to mutate the draft';

  perform pg_temp.as_v138_user(owner_b);
  denied:=false;
  begin
    perform public.ensure_published_reward_in_draft_v138(
      draft_id,source_reward,null
    );
  exception when insufficient_privilege then denied:=true;
  end;
  assert denied,'cross-tenant owner edited tenant A draft';

  perform pg_temp.as_v138_user(null,'anon');
  begin
    perform public.ensure_published_reward_in_draft_v138(
      draft_id,source_reward,null
    );
    raise exception 'V138 anon unexpectedly materialized a reward';
  exception when insufficient_privilege then null;
  end;

  -- Reproduce the exact entitlement edge from the owner report: this owner can
  -- write retention but the platform has disabled Loyalty. The neutral Grow
  -- hub must still create/replay one unpublished shared draft, while a manager,
  -- cross-tenant owner and anonymous caller are denied.
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',retention_manager,
    'authenticated','authenticated',
    'v138-retention-manager-'||retention_manager::text||'@example.test','',now(),now(),now()
  );
  insert into public.staff(
    business_id,user_id,role,full_name,active,module_perms
  ) values(
    business_a,retention_manager,'manager','V138 retention manager',true,
    '{"retention":"rw"}'::jsonb
  );
  perform pg_temp.as_v138_user(owner_b);
  perform public.platform_set_module_overrides_v105(
    business_a,null,
    jsonb_build_array(
      jsonb_build_object('module','loyalty','mode','disabled','expected_version',null),
      jsonb_build_object('module','retention','mode','rw','expected_version',null)
    ),
    'V138 retention-only owner acceptance'
  );
  perform pg_temp.as_v138_user(owner_a);
  assert not app.can_module_write(business_a,'loyalty')
     and app.can_module_write(business_a,'retention'),
    'V138 failed to reproduce retention-only owner authority';
  result:=public.create_grow_config_draft_v138(
    business_a,published_before,'grow_retention_edit'
  );
  shared_draft:=(result->>'version_id')::uuid;
  assert shared_draft is not null and not (result->>'replayed')::boolean
     and not (result->>'published')::boolean,
    'retention-only owner did not create one unpublished Grow draft';
  replay:=public.create_grow_config_draft_v138(
    business_a,published_before,'grow_retention_edit'
  );
  assert (replay->>'version_id')::uuid=shared_draft
     and (replay->>'replayed')::boolean,
    'retention-only Grow draft exact replay created another draft';
  reset role;
  assert (select count(*) from public.firm_config_versions
           where business_id=business_a and based_on_version_id=published_before
             and status='draft')=1
     and (select count(*) from public.audit_log
           where business_id=business_a and action='CREATE_GROW_DRAFT'
             and entity_id=shared_draft)=1
     and (select active_config_version_id from public.businesses where id=business_a)=published_before,
    'retention-only draft duplicated, lost audit evidence or changed published truth';
  perform pg_temp.as_v138_user(retention_manager);
  begin
    perform public.create_grow_config_draft_v138(
      business_a,published_before,'grow_retention_edit'
    );
    raise exception 'V138 manager unexpectedly created a Grow draft';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_v138_user(owner_b);
  begin
    perform public.create_grow_config_draft_v138(
      business_a,published_before,'grow_retention_edit'
    );
    raise exception 'V138 cross-tenant owner unexpectedly created a Grow draft';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_v138_user(null,'anon');
  begin
    perform public.create_grow_config_draft_v138(
      business_a,published_before,'grow_retention_edit'
    );
    raise exception 'V138 anon unexpectedly created a Grow draft';
  exception when insufficient_privilege then null;
  end;

  reset role;
  assert has_function_privilege(
    'authenticated',
    'public.ensure_published_reward_in_draft_v138(uuid,uuid,text)',
    'execute'
  ),'V138 authenticated execute grant is missing';
  assert not has_function_privilege(
    'anon',
    'public.ensure_published_reward_in_draft_v138(uuid,uuid,text)',
    'execute'
  ),'V138 anon must not execute exact-reward continuity';
  assert has_function_privilege(
    'authenticated','public.create_grow_config_draft_v138(uuid,uuid,text)','execute'
  ) and not has_function_privilege(
    'anon','public.create_grow_config_draft_v138(uuid,uuid,text)','execute'
  ),'V138 shared Grow draft grants are not authenticated-only';
  assert has_function_privilege(
    'authenticated',
    'public.ensure_published_retention_in_draft_v138(uuid,uuid,text)',
    'execute'
  ) and has_function_privilege(
    'authenticated',
    'public.ensure_published_birthday_in_draft_v138(uuid,uuid,text)',
    'execute'
  ),'V138 authenticated programme-continuity grants are missing';
  assert not has_function_privilege(
    'anon','public.ensure_published_retention_in_draft_v138(uuid,uuid,text)','execute'
  ) and not has_function_privilege(
    'anon','public.ensure_published_birthday_in_draft_v138(uuid,uuid,text)','execute'
  ),'V138 anon must not execute programme continuity';

  -- Google OAuth admission: ordinary sign-in is checkbox-free but only an
  -- existing active business persona is admitted. New-account signup must
  -- consume one server-recorded, current, exact-version legal acceptance.
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',oauth_new_user,
     'authenticated','authenticated','v138-google-new@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',oauth_other_user,
     'authenticated','authenticated','v138-google-other@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',oauth_email_user,
     'authenticated','authenticated','v138-email-only@example.test','',now(),now(),now());
  insert into auth.identities(provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values
    ('v138-owner-a-google',owner_a,jsonb_build_object('sub','v138-owner-a-google','email','owner-a@example.test'),'google',now(),now(),now()),
    ('v138-new-google',oauth_new_user,jsonb_build_object('sub','v138-new-google','email','v138-google-new@example.test'),'google',now(),now(),now()),
    ('v138-other-google',oauth_other_user,jsonb_build_object('sub','v138-other-google','email','v138-google-other@example.test'),'google',now(),now(),now()),
    ('v138-email-only',oauth_email_user,jsonb_build_object('sub','v138-email-only','email','v138-email-only@example.test'),'email',now(),now(),now());

  perform pg_temp.as_v138_user(owner_a);
  result:=public.complete_business_google_oauth_v138('signin',null);
  assert (result->>'admitted')::boolean and result->>'intent'='signin'
     and not (result->>'legal_recorded')::boolean,
    'existing Google business login was not admitted without a signup checkbox';

  perform pg_temp.as_v138_user(oauth_new_user);
  begin
    perform public.complete_business_google_oauth_v138('signin',null);
    raise exception 'new Google identity unexpectedly entered through sign-in';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.complete_business_google_oauth_v138('signup',gen_random_uuid()::text);
    raise exception 'forged Google signup callback unexpectedly passed';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v138_user(null,'anon');
  begin
    perform public.begin_business_google_oauth_signup_v138(
      gen_random_uuid()::text,gen_random_uuid(),'2026-08-02',
      '2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
      '2026-08-02','67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',false
    );
    raise exception 'unchecked Google signup unexpectedly created a consent attempt';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.begin_business_google_oauth_signup_v138(
      gen_random_uuid()::text,gen_random_uuid(),'2026-08-02',repeat('0',64),
      '2026-08-02','67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',true
    );
    raise exception 'wrong legal hash unexpectedly created a consent attempt';
  exception when sqlstate '22023' then null;
  end;
  result:=public.begin_business_google_oauth_signup_v138(
    oauth_token::text,oauth_idempotency,'2026-08-02',
    '2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
    '2026-08-02','67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',true
  );
  assert (result->>'accepted')::boolean and not (result->>'replayed')::boolean,
    'valid Google signup consent attempt was not recorded';
  replay:=public.begin_business_google_oauth_signup_v138(
    oauth_token::text,oauth_idempotency,'2026-08-02',
    '2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
    '2026-08-02','67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',true
  );
  assert (replay->>'replayed')::boolean,
    'same consent preflight did not replay idempotently';
  perform public.begin_business_google_oauth_signup_v138(
    oauth_expired_token::text,oauth_expired_idempotency,'2026-08-02',
    '2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8',
    '2026-08-02','67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c',true
  );
  reset role;
  update app.business_google_oauth_attempts_v138
     set accepted_at=now()-interval '31 minutes',expires_at=now()-interval '1 minute'
   where idempotency_key=oauth_expired_idempotency;
  perform pg_temp.as_v138_user(oauth_new_user);
  begin
    perform public.complete_business_google_oauth_v138('signup',oauth_expired_token::text);
    raise exception 'expired Google signup consent unexpectedly passed';
  exception when sqlstate '42501' then null;
  end;
  result:=public.complete_business_google_oauth_v138('signup',oauth_token::text);
  assert (result->>'admitted')::boolean and (result->>'legal_recorded')::boolean
     and not (result->>'replayed')::boolean,
    'consented Google signup did not record legal admission';
  replay:=public.complete_business_google_oauth_v138('signup',oauth_token::text);
  assert (replay->>'replayed')::boolean,
    'lost-response Google signup retry did not replay its one legal event';
  perform pg_temp.as_v138_user(oauth_other_user);
  begin
    perform public.complete_business_google_oauth_v138('signup',oauth_token::text);
    raise exception 'another Google user consumed the bound consent attempt';
  exception when sqlstate '42501' then null;
  end;
  perform pg_temp.as_v138_user(oauth_email_user);
  begin
    perform public.complete_business_google_oauth_v138('signin',null);
    raise exception 'non-Google identity unexpectedly passed Google admission';
  exception when sqlstate '42501' then null;
  end;

  reset role;
  assert (select count(*) from app.business_account_legal_acceptances_v138
      where auth_user_id=oauth_new_user and source='google_oauth_signup'
        and terms_version='2026-08-02'
        and terms_sha256='2e31dbece128befd9b504034505ba93e93069dc9cd7782a66974431740d330c8'
        and privacy_version='2026-08-02'
        and privacy_sha256='67e51a7c59a214a4df43fd533835d528034f0d20884f72244e25e0e0bf928c5c')=1,
    'Google signup did not preserve exactly one current Terms/Privacy acceptance';
  assert has_function_privilege(
    'anon','public.begin_business_google_oauth_signup_v138(text,uuid,text,text,text,text,boolean)','execute'
  ) and not has_function_privilege(
    'authenticated','public.begin_business_google_oauth_signup_v138(text,uuid,text,text,text,text,boolean)','execute'
  ),'Google signup consent preflight grants are not anon-only';
  assert has_function_privilege(
    'authenticated','public.complete_business_google_oauth_v138(text,text)','execute'
  ) and not has_function_privilege(
    'anon','public.complete_business_google_oauth_v138(text,text)','execute'
  ),'Google callback admission grants are not authenticated-only';
  assert not has_table_privilege('anon','app.business_google_oauth_attempts_v138','select')
     and not has_table_privilege('authenticated','app.business_account_legal_acceptances_v138','select'),
    'private Google consent evidence tables leaked browser access';

  raise notice 'V138 AUTH GROW CLOSURE SUITE PASS';
end
$v138$;

rollback;
