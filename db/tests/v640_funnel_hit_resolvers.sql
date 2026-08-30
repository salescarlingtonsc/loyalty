-- Rollback-only v640 acceptance suite: the slug/join-token funnel-hit resolvers
-- (follow-up to v637 — the public edge gateway holds a slug or a join token,
-- not a business id). Unresolvable input is a silent no-op; anon and
-- authenticated never get EXECUTE on either resolver (service-role only).
-- Run after the complete canonical chain through v640 in a disposable database.
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasea-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase A fixture',
    'phasea-'||substr(v_business::text,1,8),'test',true,
    array['dashboard','clients','sales','till','appointments','bookings','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase A Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-a rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.services(id,business_id,name,price_cents,duration_min,active)
  values (v_service,v_business,'Fixture Facial',8000,60,true);
  -- v620 entitlement gate: a workspace is operational only with an approved control
  -- row AND a live subscription (trialing or paid).
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  perform set_config('phasea.owner', v_owner::text, true);
  perform set_config('phasea.business', v_business::text, true);
  perform set_config('phasea.service', v_service::text, true);
end
$fixture$;

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end;
$$;
create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- v640. Slug resolver: hits, silent no-op on an unknown slug, EXECUTE posture
-- ---------------------------------------------------------------------------
do $v640$
declare
  v_business uuid := current_setting('phasea.business')::uuid;
  v_slug text;
begin
  perform pg_temp.as_postgres();
  select slug into v_slug from public.businesses where id = v_business;

  perform public.internal_public_funnel_hit_by_slug_v640(v_slug,'booking','page_view');
  perform public.internal_public_funnel_hit_by_slug_v640(v_slug,'booking','page_view');
  if (select hits from public.public_funnel_counters
       where business_id=v_business and surface='booking' and step='page_view') <> 2 then
    raise exception 'v640-1: slug resolver did not increment the counter to 2';
  end if;

  -- An unknown slug is a silent no-op: no new business, no counter row, no error.
  perform public.internal_public_funnel_hit_by_slug_v640(
    'phasea-unknown-slug-does-not-exist','booking','page_view');
  if exists (
    select 1 from public.public_funnel_counters c
     where c.business_id not in (select id from public.businesses)
  ) then
    raise exception 'v640-2: unknown slug produced an orphaned counter row';
  end if;

  if has_function_privilege('anon',
       'public.internal_public_funnel_hit_by_slug_v640(text,text,text)','execute') then
    raise exception 'v640-3: anon must not execute the slug funnel resolver';
  end if;
  if has_function_privilege('authenticated',
       'public.internal_public_funnel_hit_by_slug_v640(text,text,text)','execute') then
    raise exception 'v640-4: authenticated must not execute the slug funnel resolver';
  end if;
  if has_function_privilege('anon',
       'public.internal_public_funnel_hit_by_join_token_v640(text,text,text)','execute') then
    raise exception 'v640-5: anon must not execute the join-token funnel resolver';
  end if;
  if has_function_privilege('authenticated',
       'public.internal_public_funnel_hit_by_join_token_v640(text,text,text)','execute') then
    raise exception 'v640-6: authenticated must not execute the join-token funnel resolver';
  end if;

  raise notice 'v640 OK: slug/join-token funnel-hit resolvers';
end
$v640$;

reset role;
rollback;
