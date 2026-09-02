-- Rollback-only nestly_v686 acceptance: only the owner can permanently delete a service, and a
-- mapped service is retired rather than destroyed.
--
-- WHAT THE BUG WAS (audit finding F068). public.business_manage_catalogue_item_v660 is SECURITY
-- DEFINER, so RLS — and therefore policy services_delete_v636, which had narrowed raw DELETE on
-- public.services to role='owner' one day earlier — never applied to the DELETE it runs. Its only
-- authorisation check was app.can_module_write(business,'services'), which every approved staff
-- member holds by default (staff.modules NULL = full access). Any teammate could permanently
-- destroy a service. Separately, the retire-vs-delete reference count ignored
-- public.service_canonical_map (no FK: a delete strands the Phase C mapping) and
-- public.service_products from the service side (ON DELETE CASCADE: a delete silently takes the
-- consumption recipe with it), so a mapped-but-unsold service counted as zero-referenced.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--   1. The staff member genuinely HOLDS services write (app.can_module_write is true), so the
--      refusal that follows is about ownership and nothing else.
--   2. That staff member's delete of an unreferenced service is refused with 42501 and the
--      service is still there afterwards.
--   3. The same staff member can still RETIRE a referenced service — the everyday path is
--      untouched, and only the permanent act was narrowed.
--   4. The owner deletes an unreferenced service: action='delete' and the row is gone.
--   5. The owner's delete of a service that is only referenced by a canonical mapping RETIRES it
--      instead: action='retire', used_by counts the mapping, the row survives, active=false and
--      retired_at is set. Before v682 this service was hard-deleted.
--   6. The same holds for a service whose only reference is a service_products recipe.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v686_service_delete_owner_only_rpc.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v682_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v682_out to public;

create or replace function pg_temp.as_v682_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v682_system() to public;

create or replace function pg_temp.as_v682_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v682_user(uuid,text) to public;

-- A minimal operational tenant: approved workspace, unpaused subscription, the services and
-- inventory modules on, one owner and one ordinary staff member (modules NULL = full access,
-- which is exactly the default that made the bug reachable), and a default branch both are on.
create or replace function pg_temp.v682_tenant(
  p_business uuid, p_owner uuid, p_staff_user uuid
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
  v_staff uuid;
  v_branch uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v682-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_staff_user,'authenticated','authenticated',
          'v682-staff-'||substr(p_staff_user::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business,'V682 Catalogue','v682-catalogue-'||substr(p_business::text,1,8),
          'retail','SGD',
          array['dashboard','clients','sales','services','inventory','appointments']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v682 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V682 Owner',true,'approved')
  returning id into v_owner_staff;
  /* modules left NULL on purpose: full access is what an invited teammate gets by default, and
     it is the exact configuration that could destroy a service before v682. */
  insert into public.staff(business_id,user_id,role,full_name,active,access_state,modules)
  values (p_business,p_staff_user,'staff','V682 Staff',true,'approved',null)
  returning id into v_staff;

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V682 Main',true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,v_branch),(p_business,v_staff,v_branch);
end
$$;
grant execute on function pg_temp.v682_tenant(uuid,uuid,uuid) to public;

do $v682_test$
declare
  bA uuid := gen_random_uuid();
  oA uuid := gen_random_uuid();
  uS uuid := gen_random_uuid();
  svcFree uuid := gen_random_uuid();
  svcFree2 uuid := gen_random_uuid();
  svcMapped uuid := gen_random_uuid();
  svcRecipe uuid := gen_random_uuid();
  svcUsed uuid := gen_random_uuid();
  prodA uuid := gen_random_uuid();
  cliA uuid := gen_random_uuid();
  v_node text;
  v_res json;
  v_row public.services%rowtype;
  v_ok boolean;
  v_err text;
begin
  perform pg_temp.as_v682_system();
  perform pg_temp.v682_tenant(bA,oA,uS);

  insert into public.services(id,business_id,name,price_cents,duration_min)
  values (svcFree,   bA,'V682 Unreferenced',   5000,60),
         (svcFree2,  bA,'V682 Unreferenced 2', 5000,60),
         (svcMapped, bA,'V682 Mapped',         6000,60),
         (svcRecipe, bA,'V682 Recipe',         7000,60),
         (svcUsed,   bA,'V682 Booked',         8000,60);
  insert into public.products(id,business_id,name,retail_price_cents)
  values (prodA,bA,'V682 Consumable',900);

  -- svcMapped is referenced ONLY by the canonical mapping; svcRecipe ONLY by a recipe row.
  select n.node_key into v_node
    from public.taxonomy_nodes n where n.version_no = 1
   order by n.level desc, n.node_key limit 1;
  insert into public.service_canonical_map(business_id,service_id,node_key,version_no,method,mapped_by)
  values (bA,svcMapped,v_node,1,'owner_chosen',oA);
  insert into public.service_products(service_id,product_id,qty) values (svcRecipe,prodA,1);

  -- svcUsed is referenced the ordinary way, so it is the retire path everyone may take.
  insert into public.clients(id,business_id,full_name) values (cliA,bA,'V682 Client');
  insert into public.appointments(business_id,client_id,service_id,starts_at,ends_at,status)
  values (bA,cliA,svcUsed,now()+interval '3 days',now()+interval '3 days 1 hour','booked');

  -- ------------------------------------------------------------------ 1. the staff member really has services write
  perform pg_temp.as_v682_user(uS);
  if app.can_module_write(bA,'services') then
    insert into v682_out values (1,'the staff member holds services write (so the refusal is about ownership)','PASS');
  else
    insert into v682_out values (1,'the staff member holds services write (so the refusal is about ownership)',
      'FAIL - can_module_write is false, the rest of this suite would prove nothing');
  end if;

  -- ------------------------------------------------------------------ 2. staff cannot hard-delete
  v_err := null;
  begin
    perform public.business_manage_catalogue_item_v660(bA,'service',svcFree,'delete');
  exception when others then
    v_err := sqlstate;
  end;
  perform pg_temp.as_v682_system();
  select * into v_row from public.services where id = svcFree;
  if v_err = '42501' and v_row.id is not null then
    insert into v682_out values (2,'staff with services write is REFUSED (42501) a hard delete and the service survives','PASS');
  else
    insert into v682_out values (2,'staff with services write is REFUSED (42501) a hard delete and the service survives',
      format('FAIL - sqlstate=%s service_present=%s',coalesce(v_err,'<none>'),v_row.id is not null));
  end if;

  -- ------------------------------------------------------------------ 3. staff CAN still retire
  perform pg_temp.as_v682_user(uS);
  v_err := null;
  begin
    select public.business_manage_catalogue_item_v660(bA,'service',svcUsed,'delete') into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v682_system();
  select * into v_row from public.services where id = svcUsed;
  if v_err is null and (v_res->>'action') = 'retire'
     and v_row.id is not null and v_row.active = false and v_row.retired_at is not null then
    insert into v682_out values (3,'staff can still RETIRE a referenced service — the everyday path is untouched','PASS');
  else
    insert into v682_out values (3,'staff can still RETIRE a referenced service — the everyday path is untouched',
      format('FAIL - sqlstate=%s result=%s',coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. the owner deletes an unreferenced service
  perform pg_temp.as_v682_user(oA);
  v_err := null;
  begin
    select public.business_manage_catalogue_item_v660(bA,'service',svcFree,'delete') into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v682_system();
  select exists(select 1 from public.services where id = svcFree) into v_ok;
  if v_err is null and (v_res->>'action') = 'delete' and (v_res->>'used_by') = '0' and not v_ok then
    insert into v682_out values (4,'the OWNER hard-deletes an unreferenced service','PASS');
  else
    insert into v682_out values (4,'the OWNER hard-deletes an unreferenced service',
      format('FAIL - sqlstate=%s result=%s still_present=%s',
             coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_ok));
  end if;

  -- ------------------------------------------------------------------ 5. a mapped service is retired, not destroyed
  perform pg_temp.as_v682_user(oA);
  v_err := null;
  begin
    select public.business_manage_catalogue_item_v660(bA,'service',svcMapped,'delete') into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v682_system();
  select * into v_row from public.services where id = svcMapped;
  if v_err is null and (v_res->>'action') = 'retire' and (v_res->>'used_by')::int >= 1
     and v_row.id is not null and v_row.active = false and v_row.retired_at is not null
     and exists (select 1 from public.service_canonical_map
                  where business_id = bA and service_id = svcMapped) then
    insert into v682_out values (5,'the owner''s delete of a MAPPED service retires it and the mapping survives','PASS');
  else
    insert into v682_out values (5,'the owner''s delete of a MAPPED service retires it and the mapping survives',
      format('FAIL - sqlstate=%s result=%s present=%s active=%s',
             coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),
             v_row.id is not null,v_row.active));
  end if;

  -- ------------------------------------------------------------------ 6. a service with a recipe is retired too
  perform pg_temp.as_v682_user(oA);
  v_err := null;
  begin
    select public.business_manage_catalogue_item_v660(bA,'service',svcRecipe,'delete') into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v682_system();
  select * into v_row from public.services where id = svcRecipe;
  if v_err is null and (v_res->>'action') = 'retire'
     and v_row.id is not null and v_row.active = false
     and exists (select 1 from public.service_products where service_id = svcRecipe) then
    insert into v682_out values (6,'the owner''s delete of a service with a consumption recipe retires it','PASS');
  else
    insert into v682_out values (6,'the owner''s delete of a service with a consumption recipe retires it',
      format('FAIL - sqlstate=%s result=%s',coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 7. the product branch is unchanged
  perform pg_temp.as_v682_user(uS);
  v_err := null;
  begin
    select public.business_manage_catalogue_item_v660(bA,'product',prodA,'delete') into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v682_system();
  if v_err is null and (v_res->>'action') = 'retire' then
    insert into v682_out values (7,'the PRODUCT branch is unchanged: staff still reach it and the recipe retires it','PASS');
  else
    insert into v682_out values (7,'the PRODUCT branch is unchanged: staff still reach it and the recipe retires it',
      format('FAIL - sqlstate=%s result=%s',coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 8. a second unreferenced service, deleted by the owner
  perform pg_temp.as_v682_user(oA);
  select public.business_manage_catalogue_item_v660(bA,'service',svcFree2,'delete') into v_res;
  perform pg_temp.as_v682_system();
  if (v_res->>'action') = 'delete'
     and exists (select 1 from public.audit_log
                  where business_id = bA and entity_id = svcFree2 and action = 'service.delete') then
    insert into v682_out values (8,'the hard delete is still recorded in audit_log as service.delete','PASS');
  else
    insert into v682_out values (8,'the hard delete is still recorded in audit_log as service.delete',
      format('FAIL - result=%s',coalesce(v_res::text,'<null>')));
  end if;
end
$v682_test$;

select seq, step, outcome from v682_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v682_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v682_out;
  if v_all <> 8 then
    raise exception 'nestly_v686: % of 8 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v686: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v682_gate$;

rollback;
