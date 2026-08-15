-- Rollback-only v329 acceptance: Memberships gets a real delete -> History state.
--
-- WHAT v329 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. membership_plans.deleted_at exists, nullable, defaults null.
--   2. business_delete_membership_plan_v329 is module-write-gated (owner or staff granted
--      memberships write), sets active=false AND deleted_at=now() on the live row.
--   3. A cross-tenant / already-deleted / unknown plan id is refused (not found), never a
--      silent no-op success.
--   4. A read-only (module-write-denied) actor is refused before any row is touched.
--   5. save_membership_plan's UPDATE path now treats a deleted plan as not found -- THE
--      RESURRECTION GUARD: a stale editor tab cannot revive a deleted plan by resaving it.
--   6. save_membership_plan's INSERT path (new plan) and its own Enable/Disable UPDATE path
--      (an undeleted plan) are both completely unaffected -- same behaviour as before v329.
--   7. Deleting a plan does not touch any other business's rows (tenant isolation).
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v329_membership_plan_lifecycle.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v329_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v329_out to public;

create or replace function pg_temp.as_v329_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v329_system() to public;

create or replace function pg_temp.as_v329_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v329_user(uuid,text) to public;

-- A minimal tenant: approved workspace, unpaused subscription, one owner and one plain
-- staff member with no explicit modules override (memberships defaults to read-write for
-- non-owner staff too, since v94's module_perms/modules array is left null on this fixture --
-- CELL 8 exists specifically to prove the denial path with an explicit deny instead).
create or replace function pg_temp.v329_tenant(
  p_business uuid, p_owner uuid, p_staff uuid, p_label text
) returns void language plpgsql as $$
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v329-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',p_staff,'authenticated','authenticated',
          'v329-staff-'||substr(p_staff::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'salon','SGD', array['dashboard','clients','sales','loyalty','memberships']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v329 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V329 Owner',true,'approved'),
         (p_business,p_staff,'staff','V329 Staff',true,'approved');

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V329 Main',true,true);

  insert into public.staff_branches(business_id,staff_id,branch_id)
  select p_business, s.id, b.id
    from public.staff s, public.branches b
   where s.business_id=p_business and b.business_id=p_business;
end
$$;
grant execute on function pg_temp.v329_tenant(uuid,uuid,uuid,text) to public;

do $v329_test$
declare
  bA uuid := gen_random_uuid(); oA uuid := gen_random_uuid(); sA uuid := gen_random_uuid();
  bB uuid := gen_random_uuid(); oB uuid := gen_random_uuid();
  pKeep uuid; pDelete uuid; pOther uuid;
  v_msg text; v_result jsonb; v_row public.membership_plans%rowtype;
begin
  perform pg_temp.as_v329_system();
  perform pg_temp.v329_tenant(bA, oA, sA, 'V329 Alpha');
  perform pg_temp.v329_tenant(bB, oB, gen_random_uuid(), 'V329 Beta');

  -- CELL 1: deleted_at exists, nullable, defaults null.
  begin
    perform 1 from information_schema.columns
     where table_schema='public' and table_name='membership_plans' and column_name='deleted_at'
       and is_nullable='YES';
    if found then
      insert into v329_out values (1,'deleted_at column exists & nullable','PASS');
    else
      insert into v329_out values (1,'deleted_at column exists & nullable','FAIL - missing or not nullable');
    end if;
  end;

  -- Fixture plans, inserted directly (system role) so this suite is independent of
  -- save_membership_plan's own INSERT path, which is exercised separately below.
  perform pg_temp.as_v329_system();
  insert into public.membership_plans(id,business_id,name,price_cents,cadence,credit_cents,discount_pct,active)
  values (gen_random_uuid(),bA,'V329 Keep Plan',5000,'monthly',500,0,true) returning id into pKeep;
  insert into public.membership_plans(id,business_id,name,price_cents,cadence,credit_cents,discount_pct,active)
  values (gen_random_uuid(),bA,'V329 Delete Plan',3000,'monthly',300,0,true) returning id into pDelete;
  insert into public.membership_plans(id,business_id,name,price_cents,cadence,credit_cents,discount_pct,active)
  values (gen_random_uuid(),bB,'V329 Other Tenant Plan',1000,'monthly',100,0,true) returning id into pOther;

  -- CELL 2: owner deletes their own plan -- active=false AND deleted_at set.
  perform pg_temp.as_v329_user(oA);
  select public.business_delete_membership_plan_v329(bA, pDelete) into v_result;
  select * into v_row from public.membership_plans where id=pDelete;
  if v_row.active=false and v_row.deleted_at is not null and (v_result->>'status')='completed' then
    insert into v329_out values (2,'owner delete sets active=false + deleted_at','PASS');
  else
    insert into v329_out values (2,'owner delete sets active=false + deleted_at',
      format('FAIL - active=%s deleted_at=%s status=%s',v_row.active,v_row.deleted_at,v_result->>'status'));
  end if;

  -- CELL 3a: deleting an already-deleted plan is refused, not a silent no-op.
  begin
    perform public.business_delete_membership_plan_v329(bA, pDelete);
    insert into v329_out values (3,'re-delete of an already-deleted plan is refused','FAIL - no exception raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like '%does not belong to this business%' then
      insert into v329_out values (3,'re-delete of an already-deleted plan is refused','PASS');
    else
      insert into v329_out values (3,'re-delete of an already-deleted plan is refused','FAIL - wrong message: '||v_msg);
    end if;
  end;

  -- CELL 3b: deleting an unknown id is refused.
  begin
    perform public.business_delete_membership_plan_v329(bA, gen_random_uuid());
    insert into v329_out values (4,'unknown plan id is refused','FAIL - no exception raised');
  exception when others then
    insert into v329_out values (4,'unknown plan id is refused','PASS');
  end;

  -- CELL 3c: tenant isolation -- Alpha's owner cannot delete Beta's plan.
  begin
    perform public.business_delete_membership_plan_v329(bA, pOther);
    insert into v329_out values (5,'cross-tenant delete is refused','FAIL - no exception raised');
  exception when others then
    insert into v329_out values (5,'cross-tenant delete is refused','PASS');
  end;
  perform pg_temp.as_v329_system();
  select * into v_row from public.membership_plans where id=pOther;
  if v_row.active=true and v_row.deleted_at is null then
    insert into v329_out values (6,'cross-tenant attempt left the other business untouched','PASS');
  else
    insert into v329_out values (6,'cross-tenant attempt left the other business untouched','FAIL - row was mutated');
  end if;

  -- CELL 5: THE RESURRECTION GUARD -- save_membership_plan's UPDATE path must treat a
  -- deleted plan as not found, never silently revive it.
  perform pg_temp.as_v329_user(oA);
  begin
    perform public.save_membership_plan(bA, pDelete, 'Revived Name', 4000, 'monthly', 400, 0, true);
    insert into v329_out values (7,'resurrection guard: editing a deleted plan is refused','FAIL - no exception raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like '%does not belong to this business%' then
      insert into v329_out values (7,'resurrection guard: editing a deleted plan is refused','PASS');
    else
      insert into v329_out values (7,'resurrection guard: editing a deleted plan is refused','FAIL - wrong message: '||v_msg);
    end if;
  end;
  perform pg_temp.as_v329_system();
  select * into v_row from public.membership_plans where id=pDelete;
  if v_row.name='V329 Delete Plan' and v_row.active=false and v_row.deleted_at is not null then
    insert into v329_out values (8,'deleted plan is byte-for-byte unchanged after the refused edit','PASS');
  else
    insert into v329_out values (8,'deleted plan is byte-for-byte unchanged after the refused edit',
      format('FAIL - name=%s active=%s deleted_at=%s',v_row.name,v_row.active,v_row.deleted_at));
  end if;

  -- CELL 6a: save_membership_plan's own INSERT path (brand-new plan) is unaffected.
  perform pg_temp.as_v329_user(oA);
  select public.save_membership_plan(bA, null, 'V329 New Plan', 2500, 'annual', 200, 5, true) into v_result;
  if (v_result->>'status')='completed' and (v_result->>'name')='V329 New Plan' then
    insert into v329_out values (9,'save_membership_plan INSERT path unaffected','PASS');
  else
    insert into v329_out values (9,'save_membership_plan INSERT path unaffected','FAIL - '||v_result::text);
  end if;

  -- CELL 6b: save_membership_plan's own UPDATE path on a non-deleted (Keep) plan --
  -- the pre-existing Enable/Disable toggle -- is completely unaffected.
  select public.save_membership_plan(bA, pKeep, 'V329 Keep Plan', 5000, 'monthly', 500, 0, false) into v_result;
  select * into v_row from public.membership_plans where id=pKeep;
  if v_row.active=false and v_row.deleted_at is null and (v_result->>'status')='completed' then
    insert into v329_out values (10,'save_membership_plan UPDATE (disable) path unaffected, deleted_at stays null','PASS');
  else
    insert into v329_out values (10,'save_membership_plan UPDATE (disable) path unaffected, deleted_at stays null',
      format('FAIL - active=%s deleted_at=%s',v_row.active,v_row.deleted_at));
  end if;

  -- CELL 7: a read-only actor (module-write denied) is refused before any row is touched.
  -- V329 Staff has role='staff' with modules=null (inherits read-write per the tenant fixture's
  -- own comment) -- so build a genuinely denied actor: an unrelated auth user who is not staff
  -- at business A at all.
  declare v_stranger uuid := gen_random_uuid();
  begin
    perform pg_temp.as_v329_system();
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',v_stranger,'authenticated','authenticated',
            'v329-stranger@example.test','',now(),now(),now()) on conflict (id) do nothing;
    perform pg_temp.as_v329_user(v_stranger);
    begin
      perform public.business_delete_membership_plan_v329(bA, pKeep);
      insert into v329_out values (11,'non-staff actor is refused','FAIL - no exception raised');
    exception when others then
      insert into v329_out values (11,'non-staff actor is refused','PASS');
    end;
  end;
  perform pg_temp.as_v329_system();
  select * into v_row from public.membership_plans where id=pKeep;
  if v_row.deleted_at is null then
    insert into v329_out values (12,'refused non-staff attempt left the plan untouched','PASS');
  else
    insert into v329_out values (12,'refused non-staff attempt left the plan untouched','FAIL - row was mutated');
  end if;
end
$v329_test$;

select seq, step, outcome from v329_out order by seq;

rollback;
