-- Rollback-only acceptance for LOYALTY-BOUNDARY-001.
-- Run after the canonical chain through v143 in a disposable local database.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v143_user(p_uid uuid)
returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role','authenticated'
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v143_user(uuid) to public;

do $v143_effective_boundaries$
declare
  v_business uuid;
  v_owner uuid;
  v_outsider uuid;
  v_customer uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_client uuid;
  v_defaults_draft uuid;
  v_clone_draft uuid;
  v_draft uuid;
  v_paused_draft uuid;
  v_current_tier uuid:=gen_random_uuid();
  v_future_tier uuid:=gen_random_uuid();
  v_ended_tier uuid:=gen_random_uuid();
  v_paused_tier uuid:=gen_random_uuid();
  v_result jsonb;
  v_first_defaults jsonb;
  v_replayed_defaults jsonb;
  v_defaults_key uuid:=gen_random_uuid();
  v_fresh_key uuid:=gen_random_uuid();
  v_defaults_hash text;
  v_denied boolean:=false;
  v_now timestamptz:=statement_timestamp();
begin
  select business.id,staff.user_id into v_business,v_owner
  from public.businesses business
  join public.staff staff on staff.business_id=business.id and staff.role='owner'
  where business.created_at='2000-01-01 00:00:00+00'
  order by staff.created_at limit 1;
  select user_id into v_outsider from public.super_admins
  where user_id<>v_owner order by created_at limit 1;
  select id into v_client from public.clients
  where business_id=v_business and email='pristine-a@example.test';
  if v_business is null or v_owner is null or v_outsider is null or v_client is null then
    raise exception 'v143 pristine fixture identities are missing';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,phone_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_customer,
    'authenticated','authenticated','v143-customer-'||v_customer::text||'@example.test',
    '+6580000143','',now(),now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',gen_random_uuid()::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    current_setting('app.customer_link_insert_id')::uuid,v_business,v_identity,
    v_customer,v_client,'verified','firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  perform pg_temp.as_v143_user(v_owner);
  v_defaults_draft:=(public.create_loyalty_config_draft(
    v_business,(select active_config_version_id from public.businesses where id=v_business),
    'v143-default-tier-atomicity'
  )::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_defaults_hash from public.firm_config_versions
  where id=v_defaults_draft;
  v_first_defaults:=public.add_recommended_loyalty_tiers_v143(
    v_business,v_defaults_draft,'visits',v_defaults_hash,v_defaults_key
  );
  if v_first_defaults->>'status'<>'draft_ready'
     or v_first_defaults->>'published'<>'false'
     or (select count(*) from public.loyalty_tier_versions
         where config_version_id=v_defaults_draft)<>3 then
    raise exception 'recommended tiers were not one unpublished three-row transaction: %',v_first_defaults;
  end if;
  v_replayed_defaults:=public.add_recommended_loyalty_tiers_v143(
    v_business,v_defaults_draft,'visits',v_defaults_hash,v_defaults_key
  );
  if v_replayed_defaults is distinct from v_first_defaults then
    raise exception 'lost-response retry did not replay byte-equivalent result';
  end if;
  if (select count(*) from public.loyalty_tier_versions
      where config_version_id=v_defaults_draft)<>3 then
    raise exception 'exact retry duplicated tier rows';
  end if;
  reset role;
  if (select count(*) from app.loyalty_tier_default_operations_v143
      where business_id=v_business and actor_id=v_owner)<>1 then
    raise exception 'exact retry duplicated private operation evidence';
  end if;
  perform pg_temp.as_v143_user(v_owner);
  v_result:=public.add_recommended_loyalty_tiers_v143(
    v_business,v_defaults_draft,'visits',
    (select snapshot_hash from public.firm_config_versions where id=v_defaults_draft),
    v_fresh_key
  );
  if v_result->>'status'<>'existing_tiers'
     or (select count(*) from public.loyalty_tier_versions
         where config_version_id=v_defaults_draft)<>3 then
    raise exception 'fresh stale-tab key duplicated existing default tiers: %',v_result;
  end if;
  begin
    perform public.add_recommended_loyalty_tiers_v143(
      v_business,v_defaults_draft,'spend',v_defaults_hash,v_defaults_key
    );
    raise exception 'same tier-default key accepted changed basis';
  exception when sqlstate '22023' then null;
  end;

  v_draft:=(public.create_loyalty_config_draft(
    v_business,(select active_config_version_id from public.businesses where id=v_business),
    'v143-effective-boundaries'
  )::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'active',true,'kind','points','loyalty_model','points_tiers',
    'tier_basis','visits'
  ),null);
  perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
    'id',v_current_tier,'name','Glow','threshold',0,'points_multiplier',1.1,
    'perk_note',E'Priority booking\nGlow Facial (500 points)',
    'active',true,'effective_from',v_now-interval '1 day','expires_at',v_now+interval '1 day'
  ),null);
  perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
    'id',v_future_tier,'name','Radiance','threshold',1,'points_multiplier',1.25,
    'active',true,'effective_from',v_now+interval '1 hour','expires_at',v_now+interval '2 days'
  ),null);
  perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
    'id',v_ended_tier,'name','Silver July','threshold',2,'points_multiplier',1.5,
    'active',true,'effective_from',v_now-interval '2 days','expires_at',v_now
  ),null);
  perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
    'id',v_paused_tier,'name','Paused VIP','threshold',3,'points_multiplier',2,
    'active',false
  ),null);

  begin
    perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
      'name','Invalid','threshold',4,'points_multiplier',2,
      'effective_from',v_now+interval '1 day','expires_at',v_now
    ),null);
    raise exception 'invalid tier window persisted';
  exception when sqlstate '22023' then null;
  end;

  reset role;
  perform pg_temp.as_v143_user(v_outsider);
  begin
    perform public.save_loyalty_tier_draft_v143(v_draft,jsonb_build_object(
      'id',v_current_tier,'name','Forged','threshold',0,'points_multiplier',9
    ),null);
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'non-owner changed a tier window';end if;
  v_denied:=false;
  begin
    perform public.add_recommended_loyalty_tiers_v143(
      v_business,v_defaults_draft,'visits',null,gen_random_uuid()
    );
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied
     or (select count(*) from public.loyalty_tier_versions
         where config_version_id=v_defaults_draft)<>3 then
    raise exception 'non-owner default-tier attempt mutated the draft';
  end if;

  reset role;
  perform pg_temp.as_v143_user(v_owner);
  perform public.publish_loyalty_config(v_draft);
  if (select count(*) from public.loyalty_tiers where business_id=v_business)<>3 then
    raise exception 'published tier projection did not retain exact active inventory';
  end if;
  if exists(select 1 from public.loyalty_tiers where id=v_future_tier
      and effective_from<=v_now) then
    raise exception 'future tier boundary was not persisted';
  end if;
  if exists(select 1 from public.loyalty_tiers where id=v_ended_tier
      and expires_at>v_now) then
    raise exception 'ended tier exclusive boundary was not persisted';
  end if;

  v_clone_draft:=(public.create_loyalty_config_draft(
    v_business,(select active_config_version_id from public.businesses where id=v_business),
    'v143-window-clone'
  )::jsonb->>'version_id')::uuid;
  if exists(
    select 1
    from public.loyalty_tier_versions published
    join public.loyalty_tier_versions cloned
      on cloned.tier_id=published.tier_id
     and cloned.config_version_id=v_clone_draft
    where published.config_version_id=v_draft
      and (cloned.effective_from is distinct from published.effective_from
        or cloned.expires_at is distinct from published.expires_at)
  ) or (select count(*) from public.loyalty_tier_versions
        where config_version_id=v_clone_draft)<>(
          select count(*) from public.loyalty_tier_versions
          where config_version_id=v_draft
        ) then
    raise exception 'later draft did not preserve published tier effective boundaries';
  end if;

  reset role;
  perform pg_temp.as_v143_user(v_customer);
  v_result:=public.customer_get_effective_tier_v143(v_business);
  if v_result#>>'{tier,current,id}' is distinct from v_current_tier::text then
    raise exception 'future tier affected the customer before its boundary: %',v_result;
  end if;
  if v_result::text like '%Radiance%' then
    raise exception 'future tier affected the customer before its boundary';
  end if;
  if v_result::text like '%Silver July%' then
    raise exception 'ended tier affected the customer at its exclusive boundary';
  end if;
  if v_result#>'{tier,current,benefits}' is distinct from
     '["Priority booking","Glow Facial (500 points)"]'::jsonb then
    raise exception 'current tier benefits were not projected separately: %',v_result;
  end if;

  reset role;
  perform pg_temp.as_v143_user(v_owner);
  v_paused_draft:=(public.create_loyalty_config_draft(
    v_business,(select active_config_version_id from public.businesses where id=v_business),
    'v143-disabled-loyalty'
  )::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_paused_draft,jsonb_build_object('active',false),null);
  perform public.publish_loyalty_config(v_paused_draft);

  reset role;
  perform pg_temp.as_v143_user(v_customer);
  v_denied:=false;
  begin
    perform public.customer_get_effective_tier_v143(v_business);
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then
    raise exception 'disabled Loyalty exposed effective tier progress';
  end if;
end
$v143_effective_boundaries$;

rollback;
