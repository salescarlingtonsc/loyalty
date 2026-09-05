-- EXECUTED acceptance fixture for nestly_v773
-- (db/migrations/20261005_nestly_v773_rewards_same_at_every_branch.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v773 --migrated-only
--
-- Owner ruling 2026-09-05: rewards are the same at every branch.
--
-- ASSERTIONS (rolled back):
--   F1  with an override row present for a branch, app.resolve_loyalty_branch_config still
--       answers the FIRM earn rate and source 'firm_default' for that branch.
--   F2  save_loyalty_branch_override_draft refuses with 22023 and names the ruling.
--   F3  copying a branch reports loyalty_overrides 0 and writes no override row.
begin;

do $v773$
declare
  v_business uuid; v_branch uuid; v_version uuid; v_row record; v_ok boolean := false;
  v_owner uuid := gen_random_uuid(); v_now timestamptz := date_trunc('second', now());
  v_to uuid; v_result jsonb; v_count integer;
begin
  /* Own tenant: business, owner, subscription, open workspace, a configuration version with a
     points programme (the v102 seed shape), and its first branch. */
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V773 tenant','v773-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard','loyalty'])
  returning id into v_business;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v773-'||substr(v_owner::text,1,8)||'@example.test','',v_now,v_now,v_now);
  insert into public.staff(business_id,user_id,role,active,access_state) values (v_business,v_owner,'owner',true,'approved');
  insert into public.subscriptions(business_id,status,currency,base_price_cents,included_seats,per_seat_price_cents,
    billing_provider,billing_cadence,payment_status,provider_subscription_id,current_period_end)
  values (v_business,'active','SGD',118800,1,0,'razorpay','annual','paid','sub_v773fixture',v_now + interval '300 days')
  on conflict (business_id) do update set status='active', payment_status='paid', current_period_end=v_now + interval '300 days';
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
  values (v_business,'approved',v_now,'v773 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=v_now, decision_reason='v773 fixture';
  v_version := gen_random_uuid();
  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
  values (v_version,v_business,1,'draft','manual',md5('v773-programme'),v_owner);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text, true);
  insert into public.loyalty_program_versions(config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
  values (v_version,v_business,'points','classic',true,2,50,500,'points_earned','none');
  select id into v_branch from public.branches where business_id = v_business order by created_at limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name,is_default,active) values (v_business,'V773 main',true,true) returning id into v_branch;
  end if;

  -- An override that, before v773, would have won: 999 points per dollar.
  insert into public.loyalty_branch_overrides(config_version_id,business_id,branch_id,active,earn_points_per_dollar)
  values (v_version, v_business, v_branch, true, 999)
  on conflict do nothing;

  -- F1
  select * into v_row from app.resolve_loyalty_branch_config(v_business, v_branch, v_version);
  if v_row.source is distinct from 'firm_default' then
    raise exception 'F1: source is % instead of firm_default', v_row.source;
  end if;
  if v_row.earn_points_per_dollar = 999 then
    raise exception 'F1: the branch override still wins (earn %)', v_row.earn_points_per_dollar;
  end if;
  if v_row.earn_points_per_dollar <> 2 then
    raise exception 'F1: earn % is not the firm rate', v_row.earn_points_per_dollar;
  end if;

  -- F2
  begin
    perform public.save_loyalty_branch_override_draft(v_version, v_branch, '{"earn_points_per_dollar":5}'::jsonb, null);
  exception when others then
    if sqlstate <> '22023' or position('same at every branch' in sqlerrm) = 0 then
      raise exception 'F2: refused with %/% instead of 22023 naming the ruling', sqlstate, sqlerrm;
    end if;
    v_ok := true;
  end;
  if not v_ok then raise exception 'F2: the override writer did not refuse'; end if;

  -- F3 (as the owner, the way the branch page calls it)
  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  insert into public.branches(business_id,name,is_default,active) values (v_business,'V773 new',false,false) returning id into v_to;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text, true);

  v_result := public.business_copy_branch_settings_v202(v_business, v_branch, v_to);
  if coalesce((v_result->>'loyalty_overrides')::integer, -1) <> 0 then
    raise exception 'F3: copy reported loyalty_overrides=%', v_result->>'loyalty_overrides';
  end if;
  select count(*) into v_count from public.loyalty_branch_overrides where branch_id = v_to;
  if v_count <> 0 then raise exception 'F3: % override row(s) written for the new branch', v_count; end if;

  raise notice 'v773 corpus: F1-F3 passed';
end
$v773$;

rollback;
