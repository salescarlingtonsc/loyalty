-- Rollback-only acceptance for Nestly v258 — a recommended draft must not silently pause a
-- live programme. Run in a disposable database after the canonical chain, once with the
-- migration NOT applied (expected: the first assertion fails, reproducing the owner's report)
-- and once with 20260809_nestly_v258_recommended_draft_inherits_live_status.sql applied
-- (expected: every assertion passes).
begin;

create or replace function pg_temp.as_v258_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v258_user(uuid,text) to public;

do $v258_test$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_config uuid:=gen_random_uuid();
  v_slug text:='v258-glow-'||substr(v_business::text,1,8);
  v_result jsonb;
  v_draft uuid;
  v_draft_active boolean;
  v_live_active boolean;
  v_live_status text;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
  ('00000000-0000-0000-0000-000000000000',v_super,'authenticated','authenticated',
   'v258-super@example.test','',now(),now(),now()),
  ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
   'v258-owner@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules,is_synthetic)
  values(v_business,'V258 Glow Atelier',v_slug,'facial',
         array['dashboard','clients','loyalty'],true);
  -- Every loyalty RPC is gated on app.business_workspace_open_v94, which reads these two
  -- rows. Both are created by a trigger on the business insert, so they are UPDATEd here, and
  -- the check constraint on the controls row requires a decided_by/decided_at pair alongside
  -- 'approved'. Without this the suite fails 42501 before it can test anything.
  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_super,decided_at=now(),
         decision_reason='v258 rollback-only acceptance'
   where business_id=v_business;
  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false
   where business_id=v_business;
  if not app.business_workspace_open_v94(v_business) then
    raise exception 'v258: fixture workspace is not open - the suite would fail for the wrong reason';
  end if;

  insert into public.staff(business_id,user_id,full_name,role,active)
  values(v_business,v_owner,'V258 Owner','owner',true);

  -- A LIVE, ACTIVE programme: exactly the state the owner had before pressing "publish".
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,published_at,created_by,snapshot_hash
  ) values(v_config,v_business,1,'published','v258_seed',now(),v_owner,
           md5('v258-seed-'||v_config::text));
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode
  ) values(v_config,v_business,'points','points_tiers',true,1,100,0,'visits','none');
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode,
    current_config_version_id
  ) values(v_business,'points',true,'points_tiers','published',1,100,0,'visits','none',v_config);
  update public.businesses set active_config_version_id=v_config where id=v_business;

  perform pg_temp.as_v258_user(v_owner);

  -- 1. The recommendation must carry the live Active flag into its draft.
  v_result:=public.generate_retention_recommendation(
    v_business,'v258-acceptance-key-0001')::jsonb;
  v_draft:=(v_result->>'draft_config_version_id')::uuid;
  if v_draft is null then
    raise exception 'v258: recommendation returned no draft: %',v_result;
  end if;
  select active into v_draft_active
    from public.loyalty_program_versions
   where config_version_id=v_draft;
  if v_draft_active is distinct from true then
    raise exception
      'v258 FAIL: recommended draft is Paused (%) while the live programme is Active — this is the owner''s "published, but still paused"',
      v_draft_active;
  end if;

  -- 2. Publishing that draft must leave the programme Active AND published. This half already
  --    held before v258: publish_loyalty_config copies the draft's own flag, which is precisely
  --    why a draft born Paused published a pause nobody chose.
  perform public.publish_loyalty_config(v_draft);
  select active,configuration_status into v_live_active,v_live_status
    from public.loyalty_programs where business_id=v_business;
  if v_live_active is distinct from true or v_live_status<>'published' then
    raise exception 'v258 FAIL: publish produced active=% status=%',v_live_active,v_live_status;
  end if;

  reset role;

  -- 3. Publishing is still faithful in the other direction: a draft the owner deliberately
  --    sets to Paused must publish Paused. v258 must not invent an "always active" rule.
  perform pg_temp.as_v258_user(v_owner);
  v_result:=public.create_loyalty_config_draft(v_business,null,'v258_manual')::jsonb;
  v_draft:=(v_result->>'version_id')::uuid;
  -- The 3-argument signature: the 2-argument overload is internal and not granted to
  -- authenticated, so calling it here would fail 42501 rather than test anything.
  perform public.save_loyalty_config_draft(
    v_draft,jsonb_build_object('active',false),null::text);
  perform public.publish_loyalty_config(v_draft);
  select active,configuration_status into v_live_active,v_live_status
    from public.loyalty_programs where business_id=v_business;
  if v_live_active is distinct from false or v_live_status<>'published' then
    raise exception
      'v258 FAIL: a deliberately paused draft must publish paused, got active=% status=%',
      v_live_active,v_live_status;
  end if;
  reset role;

  raise notice 'v258 acceptance passed';
end
$v258_test$;

rollback;
