-- Rollback-only nestly_v688 acceptance: opening a WhatsApp conversation clears its unread count,
-- and only a staff member of that business with support WRITE can do it.
--
-- WHAT THE BUG WAS (audit finding F101). public.support_conversations_v530.unread_count was set
-- back to 0 in exactly one place — app.support_reply_v535, as a side effect of SENDING a reply —
-- and the table carries a SELECT-only RLS policy, so no client could write the column either. A
-- conversation that needed no reply therefore kept its "N new" pill forever.
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself:
--   1. A signed-in user who is not staff of the business is refused 42501 and the count stands.
--   2. Another business's staff member is refused 42501 and the count stands — the guard is
--      app.can_module_write, copied from app.support_reply_v535.
--   3. Business A's owner naming business B's conversation gets 42704, and B's row is untouched:
--      business_id is in the predicate, so a guessed id matches nothing.
--   4. The owner of the business clears its own conversation: {status:'ok', cleared:3},
--      unread_count is 0 and updated_at has been moved to now().
--   5. Clearing an already-read conversation reports cleared:0 and writes NO row — updated_at,
--      which the inbox sorts on, is left exactly where it was.
--   6. The RPC is not reachable anonymously and IS reachable by signed-in staff.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v688_support_mark_read.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v688_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v688_out to public;

create or replace function pg_temp.as_v688_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v688_system() to public;

create or replace function pg_temp.as_v688_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v688_user(uuid,text) to public;

-- A minimal operational tenant: approved workspace, unpaused subscription, the support module on,
-- one owner (modules NULL = full access, the invited teammate default) and a default branch.
create or replace function pg_temp.v688_tenant(
  p_business uuid, p_owner uuid, p_label text
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
  v_branch uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v688-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business,'V688 '||p_label,'v688-'||substr(p_business::text,1,8),
          'retail','SGD',
          array['dashboard','clients','sales','services','support']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v688 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V688 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V688 Main '||p_label,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,v_branch);
end
$$;
grant execute on function pg_temp.v688_tenant(uuid,uuid,text) to public;

do $v688_test$
declare
  bA uuid := gen_random_uuid();
  oA uuid := gen_random_uuid();
  bB uuid := gen_random_uuid();
  oB uuid := gen_random_uuid();
  uCustomer uuid := gen_random_uuid();
  convA uuid := gen_random_uuid();
  convB uuid := gen_random_uuid();
  v_past timestamptz := now() - interval '1 day';
  v_res jsonb;
  v_err text;
  v_unread integer;
  v_updated timestamptz;
begin
  perform pg_temp.as_v688_system();
  perform pg_temp.v688_tenant(bA,oA,'Alpha');
  perform pg_temp.v688_tenant(bB,oB,'Beta');

  -- A signed-in person who is staff of NEITHER business: an ordinary customer account.
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',uCustomer,'authenticated','authenticated',
          'v688-customer-'||substr(uCustomer::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  -- One routed, open conversation per tenant, each carrying unread inbound messages and an
  -- updated_at deliberately in the past so a write to it is visible.
  insert into public.support_conversations_v530(
    id,business_id,channel,customer_phone_norm,state,routing_source,handoff_state,
    opened_at,last_inbound_at,service_window_expires_at,unread_count,created_at,updated_at)
  values (convA,bA,'whatsapp','81860001','open','entry_token','unassigned',
          v_past,v_past,now()+interval '12 hours',3,v_past,v_past),
         (convB,bB,'whatsapp','81860002','open','entry_token','unassigned',
          v_past,v_past,now()+interval '12 hours',2,v_past,v_past);

  -- ------------------------------------------------------------------ 1. a non-staff customer is refused
  perform pg_temp.as_v688_user(uCustomer);
  v_err := null;
  begin
    select public.business_support_mark_read_v688(bA,convA) into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v688_system();
  select unread_count into v_unread from public.support_conversations_v530 where id = convA;
  if v_err = '42501' and v_unread = 3 then
    insert into v688_out values (1,'a signed-in non-staff user is REFUSED (42501) and the count stands','PASS');
  else
    insert into v688_out values (1,'a signed-in non-staff user is REFUSED (42501) and the count stands',
      format('FAIL - sqlstate=%s unread=%s',coalesce(v_err,'<none>'),v_unread));
  end if;

  -- ------------------------------------------------------------------ 2. another tenant's staff is refused
  perform pg_temp.as_v688_user(oB);
  v_err := null;
  begin
    select public.business_support_mark_read_v688(bA,convA) into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v688_system();
  select unread_count into v_unread from public.support_conversations_v530 where id = convA;
  if v_err = '42501' and v_unread = 3 then
    insert into v688_out values (2,'another business''s owner is REFUSED (42501) and the count stands','PASS');
  else
    insert into v688_out values (2,'another business''s owner is REFUSED (42501) and the count stands',
      format('FAIL - sqlstate=%s unread=%s',coalesce(v_err,'<none>'),v_unread));
  end if;

  -- ------------------------------------------------------------------ 3. a conversation id from another tenant
  perform pg_temp.as_v688_user(oA);
  v_err := null;
  begin
    select public.business_support_mark_read_v688(bA,convB) into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v688_system();
  select unread_count into v_unread from public.support_conversations_v530 where id = convB;
  if v_err = '42704' and v_unread = 2 then
    insert into v688_out values (3,'a conversation id belonging to another business is 42704 and untouched','PASS');
  else
    insert into v688_out values (3,'a conversation id belonging to another business is 42704 and untouched',
      format('FAIL - sqlstate=%s other_unread=%s',coalesce(v_err,'<none>'),v_unread));
  end if;

  -- ------------------------------------------------------------------ 4. the owner clears its own conversation
  perform pg_temp.as_v688_user(oA);
  v_err := null;
  begin
    select public.business_support_mark_read_v688(bA,convA) into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v688_system();
  select unread_count, updated_at into v_unread, v_updated
    from public.support_conversations_v530 where id = convA;
  if v_err is null and (v_res->>'status') = 'ok' and (v_res->>'cleared') = '3'
     and v_unread = 0 and v_updated = now() then
    insert into v688_out values (4,'the owner clears the thread: cleared=3, unread_count=0, updated_at moved','PASS');
  else
    insert into v688_out values (4,'the owner clears the thread: cleared=3, unread_count=0, updated_at moved',
      format('FAIL - sqlstate=%s result=%s unread=%s updated_moved=%s',
             coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_unread,v_updated = now()));
  end if;

  -- ------------------------------------------------------------------ 5. re-opening an already-read thread writes nothing
  -- updated_at is pushed back into the past first, so "no write" is observable rather than
  -- indistinguishable from the write assertion 4 just made.
  update public.support_conversations_v530 set updated_at = v_past where id = convA;
  perform pg_temp.as_v688_user(oA);
  v_err := null;
  begin
    select public.business_support_mark_read_v688(bA,convA) into v_res;
  exception when others then
    v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v688_system();
  select unread_count, updated_at into v_unread, v_updated
    from public.support_conversations_v530 where id = convA;
  if v_err is null and (v_res->>'cleared') = '0' and v_unread = 0 and v_updated = v_past then
    insert into v688_out values (5,'re-opening an already-read thread reports cleared=0 and writes no row','PASS');
  else
    insert into v688_out values (5,'re-opening an already-read thread reports cleared=0 and writes no row',
      format('FAIL - sqlstate=%s result=%s unread=%s updated_at_churned=%s',
             coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_unread,v_updated <> v_past));
  end if;

  -- ------------------------------------------------------------------ 6. the grants
  perform pg_temp.as_v688_system();
  if not exists (select 1 from information_schema.routine_privileges
                  where routine_schema='public' and routine_name='business_support_mark_read_v688'
                    and grantee in ('anon','PUBLIC'))
     and exists (select 1 from information_schema.routine_privileges
                  where routine_schema='public' and routine_name='business_support_mark_read_v688'
                    and grantee='authenticated') then
    insert into v688_out values (6,'the RPC is not anonymous and is reachable by signed-in staff','PASS');
  else
    insert into v688_out values (6,'the RPC is not anonymous and is reachable by signed-in staff',
      'FAIL - the grant set is wrong');
  end if;
end
$v688_test$;

select seq, step, outcome from v688_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v688_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v688_out;
  if v_all <> 6 then
    raise exception 'nestly_v688: % of 6 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v688: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v688_gate$;

rollback;
