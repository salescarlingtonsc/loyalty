-- Acceptance suite for nestly_v599 -- "the browser roles lose the writes nothing in the product uses".
--
-- Runs against PATCHED production inside begin/rollback; nothing persists. It applies nothing:
-- the migration db/migrations/20260829_nestly_v599_browser_write_boundaries.sql must already be
-- applied when this runs. Against an UNPATCHED database it is expected to FAIL -- that is the
-- point of it.
--
-- Every behavioural assertion runs as the REAL `authenticated` role with request.jwt.claims set
-- to a real login, never as the MCP superuser: a rolled-back suite that keeps superuser rights
-- bypasses both the table GRANTs and RLS and would report green on an untouched database.
--
-- The properties under test:
--   A. reward_grants   -- a direct browser UPDATE is refused outright, and the four write verbs
--                         are gone from both browser roles, while SELECT survives.
--   B. notifications   -- a direct browser UPDATE is refused even for an OWNER (the strongest
--                         member there is), and the sanctioned SECURITY DEFINER read-state path
--                         still marks a notification read.
--   C. resources       -- an owner may still create and edit; a plain approved member may not.
--   D. SEC-09 ACL      -- anon EXECUTE is gone from the seven audited functions and authenticated
--                         EXECUTE survives on them; authenticated EXECUTE is gone from the four
--                         server-internal functions while service_role keeps it.

begin;

create temp table _r(id text primary key, ok boolean, detail text) on commit drop;
grant all on _r to authenticated;

do $fixture$
declare
  v_biz uuid;
  v_owner uuid;
  v_member uuid;
  v_notif_biz uuid;
  v_notif_owner uuid;
  v_notif uuid;
  v_grant uuid;
begin
  -- a business that has BOTH an owner login and a plain approved member, for the C contrast
  select st.business_id into v_biz
  from public.staff st
  where st.active and st.access_state='approved' and st.user_id is not null
  group by st.business_id
  having bool_or(st.role='owner') and bool_or(st.role <> 'owner')
  order by st.business_id
  limit 1;

  if v_biz is null then
    raise exception 'v599 suite: no business has both an owner login and a plain member login';
  end if;

  select user_id into v_owner from public.staff
   where business_id=v_biz and role='owner' and active and access_state='approved' and user_id is not null
   limit 1;
  select user_id into v_member from public.staff
   where business_id=v_biz and role <> 'owner' and active and access_state='approved' and user_id is not null
   limit 1;

  -- a real notification plus an owner login of ITS business. Notification read-state is
  -- business-wide (there is no recipient column), so the owner is the strongest legitimate
  -- actor available and the right subject for "even this identity cannot UPDATE directly".
  select n.id, n.business_id into v_notif, v_notif_biz
  from public.notifications n
  where exists (select 1 from public.staff s
                 where s.business_id=n.business_id and s.role='owner' and s.active
                   and s.access_state='approved' and s.user_id is not null)
  order by n.created_at desc
  limit 1;

  if v_notif is null then
    raise exception 'v599 suite: no notification exists in a business with an owner login';
  end if;

  select user_id into v_notif_owner from public.staff
   where business_id=v_notif_biz and role='owner' and active and access_state='approved' and user_id is not null
   limit 1;

  select id into v_grant from public.reward_grants order by granted_at desc limit 1;

  perform set_config('test.biz',         v_biz::text,        true);
  perform set_config('test.owner',       v_owner::text,      true);
  perform set_config('test.member',      v_member::text,     true);
  perform set_config('test.notif',       v_notif::text,      true);
  perform set_config('test.notif_biz',   v_notif_biz::text,  true);
  perform set_config('test.notif_owner', v_notif_owner::text,true);
  perform set_config('test.grant',       coalesce(v_grant::text,''), true);
end
$fixture$;

-- =============================================================== A. reward_grants (SEC-01)
do $grants$
declare
  v_grant text := current_setting('test.grant');
  v_rows int;
  v_read int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.owner'), 'role','authenticated')::text, true);
  set local role authenticated;

  -- A1: the exact exposure the audit measured -- flipping a grant's status straight over REST.
  --     With the table grant gone this is refused at privilege level, before RLS is consulted,
  --     so it is refused for EVERY tenant and every row, not merely for rows this actor cannot see.
  begin
    if v_grant <> '' then
      update public.reward_grants set status='redeemed' where id = v_grant::uuid;
    else
      update public.reward_grants set status='redeemed' where false;
    end if;
    get diagnostics v_rows = row_count;
    insert into _r values ('A1_direct_update_refused', false,
      'UPDATE was permitted -- rows_updated='||v_rows);
  exception when insufficient_privilege then
    insert into _r values ('A1_direct_update_refused', true, 'update refused with 42501');
  end;

  -- A2: forging a grant outright is refused too (there was never an INSERT policy, but the
  --     table grant existed; both are gone now).
  begin
    insert into public.reward_grants(business_id, client_id, status)
      values (current_setting('test.biz')::uuid, null, 'granted');
    insert into _r values ('A2_direct_insert_refused', false, 'INSERT succeeded -- it must not');
  exception
    when insufficient_privilege then
      insert into _r values ('A2_direct_insert_refused', true, 'insert refused with 42501');
    when others then
      -- any other error also means the row was not created by a browser role; record which
      insert into _r values ('A2_direct_insert_refused', true, 'insert refused with '||sqlstate);
  end;

  -- A3: deleting the evidence is refused.
  begin
    delete from public.reward_grants where false;
    insert into _r values ('A3_direct_delete_refused', false, 'DELETE was permitted');
  exception when insufficient_privilege then
    insert into _r values ('A3_direct_delete_refused', true, 'delete refused with 42501');
  end;

  -- A4: the READ must survive -- grants_select and reward_grants_sa_read are untouched.
  select count(*) into v_read from public.reward_grants;
  insert into _r values ('A4_select_preserved', true,
    'reward_grants rows still selectable by an owner: '||v_read);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$grants$;

-- ------------------------------------------------- A5/A6: effective ACL, both browser roles
do $grant_acl$
declare
  v_bad text;
begin
  select string_agg(r||'.'||v, ', ') into v_bad
  from unnest(array['anon','authenticated']) r,
       unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) v
  where has_table_privilege(r, 'public.reward_grants', v);
  insert into _r values ('A5_no_write_verbs_remain', v_bad is null,
    coalesce('still held: '||v_bad, 'anon and authenticated hold none of INSERT/UPDATE/DELETE/TRUNCATE'));

  insert into _r values ('A6_select_grant_preserved',
    has_table_privilege('authenticated','public.reward_grants','SELECT')
      and has_table_privilege('anon','public.reward_grants','SELECT'),
    'authenticated SELECT='||has_table_privilege('authenticated','public.reward_grants','SELECT')::text
      ||' anon SELECT='||has_table_privilege('anon','public.reward_grants','SELECT')::text);

  -- the SELECT policies named in the brief must still exist, and no UPDATE policy may remain
  insert into _r values ('A7_select_policies_intact',
    (select count(*) from pg_policies
      where schemaname='public' and tablename='reward_grants'
        and policyname in ('grants_select','reward_grants_sa_read')) = 2
    and not exists (select 1 from pg_policies
      where schemaname='public' and tablename='reward_grants' and cmd in ('UPDATE','ALL')),
    (select coalesce(string_agg(policyname||':'||cmd, ', '), 'none') from pg_policies
      where schemaname='public' and tablename='reward_grants'));
end
$grant_acl$;

-- ================================================================ B. notifications
do $notif$
declare
  v_notif uuid := current_setting('test.notif')::uuid;
  v_rows int;
  v_title_before text;
  v_title_after text;
  v_read_after timestamptz;
  v_visible int;
begin
  select title into v_title_before from public.notifications where id = v_notif;
  perform set_config('test.title_before', v_title_before, true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.notif_owner'), 'role','authenticated')::text, true);
  set local role authenticated;

  -- B1: the integrity half of the defect -- rewriting a notification's title/body/reference.
  --     Notification click-through routes off ref_table/ref_id, so a forged reference
  --     redirects a colleague's approve/reject action.
  begin
    update public.notifications
       set title='v599 suite forgery', body='v599', ref_table='sales', ref_id=gen_random_uuid()
     where id = v_notif;
    get diagnostics v_rows = row_count;
    insert into _r values ('B1_direct_update_refused', false,
      'UPDATE was permitted -- rows_updated='||v_rows);
  exception when insufficient_privilege then
    insert into _r values ('B1_direct_update_refused', true, 'update refused with 42501');
  end;

  -- B2: and the read-state half, attempted directly rather than through the RPC
  begin
    update public.notifications set read_at = now() where id = v_notif;
    insert into _r values ('B2_direct_read_state_update_refused', false, 'UPDATE was permitted');
  exception when insufficient_privilege then
    insert into _r values ('B2_direct_read_state_update_refused', true, 'update refused with 42501');
  end;

  -- B3: the SANCTIONED path still works. mark_notification_read is SECURITY DEFINER and gated on
  --     app.is_salon_member(business_id), so it is unaffected by the browser grant being gone.
  perform public.mark_notification_read(v_notif);
  select read_at, title into v_read_after, v_title_after
    from public.notifications where id = v_notif;
  insert into _r values ('B3_sanctioned_read_state_path_works', v_read_after is not null,
    'read_at after mark_notification_read = '||coalesce(v_read_after::text,'null'));

  -- B4: nothing else about the row moved
  insert into _r values ('B4_content_unchanged',
    v_title_after is not distinct from current_setting('test.title_before'),
    'title still '||coalesce(v_title_after,'null'));

  -- B5: mark-all still works too (the bell's other button)
  perform public.mark_all_notifications_read(current_setting('test.notif_biz')::uuid);
  select count(*) into v_rows from public.notifications
   where business_id = current_setting('test.notif_biz')::uuid and read_at is null;
  insert into _r values ('B5_sanctioned_mark_all_works', v_rows = 0,
    'unread remaining after mark_all = '||v_rows);

  -- B6: the read must survive
  select count(*) into v_visible from public.notifications
   where business_id = current_setting('test.notif_biz')::uuid;
  insert into _r values ('B6_select_preserved', v_visible > 0,
    'notifications visible to the owner: '||v_visible);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$notif$;

do $notif_acl$
declare
  v_bad text;
begin
  select string_agg(r||'.'||v, ', ') into v_bad
  from unnest(array['anon','authenticated']) r,
       unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) v
  where has_table_privilege(r, 'public.notifications', v);
  insert into _r values ('B7_no_write_verbs_remain', v_bad is null,
    coalesce('still held: '||v_bad, 'anon and authenticated hold none of INSERT/UPDATE/DELETE/TRUNCATE'));

  insert into _r values ('B8_no_update_policy_remains',
    not exists (select 1 from pg_policies
      where schemaname='public' and tablename='notifications' and cmd in ('UPDATE','ALL'))
    and (select count(*) from pg_policies
      where schemaname='public' and tablename='notifications'
        and policyname in ('notifications_select','notifications_sa_read')) = 2,
    (select coalesce(string_agg(policyname||':'||cmd, ', '), 'none') from pg_policies
      where schemaname='public' and tablename='notifications'));
end
$notif_acl$;

-- ==================================================================== C. resources
do $res_owner$
declare
  v_biz uuid := current_setting('test.biz')::uuid;
  v_id uuid;
  v_rows int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.owner'), 'role','authenticated')::text, true);
  set local role authenticated;

  insert into public.resources(business_id, name) values (v_biz, 'v599 suite probe')
    returning id into v_id;
  insert into _r values ('C1_owner_insert_allowed', v_id is not null,
    'owner created resource '||coalesce(v_id::text,'null'));
  perform set_config('test.resource', v_id::text, true);

  update public.resources set name='v599 suite probe (edited)' where id = v_id;
  get diagnostics v_rows = row_count;
  insert into _r values ('C2_owner_update_allowed', v_rows = 1, 'owner rows_updated='||v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$res_owner$;

do $res_member$
declare
  v_biz uuid := current_setting('test.biz')::uuid;
  v_id uuid := current_setting('test.resource')::uuid;
  v_rows int;
  v_read int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.member'), 'role','authenticated')::text, true);
  set local role authenticated;

  -- C3: the exposure resources_all granted -- any active member could create a resource
  begin
    insert into public.resources(business_id, name) values (v_biz, 'v599 suite member probe');
    insert into _r values ('C3_member_insert_refused', false, 'INSERT succeeded -- it must not');
  exception when insufficient_privilege then
    insert into _r values ('C3_member_insert_refused', true, 'insert refused with 42501');
  end;

  -- C4: ...and rename or deactivate one (USING alone governs UPDATE and DELETE)
  update public.resources set name='v599 member rename', active=false where id = v_id;
  get diagnostics v_rows = row_count;
  insert into _r values ('C4_member_update_refused', v_rows = 0, 'member rows_updated='||v_rows);

  delete from public.resources where id = v_id;
  get diagnostics v_rows = row_count;
  insert into _r values ('C5_member_delete_refused', v_rows = 0, 'member rows_deleted='||v_rows);

  -- C6: the member READ is deliberately retained
  select count(*) into v_read from public.resources where business_id = v_biz;
  insert into _r values ('C6_member_select_preserved', v_read > 0,
    'resources visible to the member: '||v_read);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$res_member$;

do $res_shape$
declare
  v_bad text;
begin
  insert into _r values ('C7_no_permissive_all_policy_remains',
    not exists (select 1 from pg_policies
      where schemaname='public' and tablename='resources' and cmd='ALL'
        and coalesce(qual,'') not like '%is_super_admin%'),
    (select coalesce(string_agg(policyname||':'||cmd, ', '), 'none') from pg_policies
      where schemaname='public' and tablename='resources'));

  select string_agg('anon.'||v, ', ') into v_bad
  from unnest(array['INSERT','UPDATE','DELETE','TRUNCATE','SELECT']) v
  where has_table_privilege('anon', 'public.resources', v);
  insert into _r values ('C8_anon_holds_nothing', v_bad is null,
    coalesce('still held: '||v_bad, 'anon holds no privilege on resources'));
end
$res_shape$;

-- ============================================================== D. SEC-09 function ACL
do $sec09$
declare
  v_bad text;
begin
  -- D1: the seven audited functions -- anon EXECUTE gone, authenticated EXECUTE retained
  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.get_workspace_locale_preference_v97()',
    'public.set_workspace_locale_preference_v97(text,bigint)',
    'public.business_get_catalogue_media_versions_v158(uuid)',
    'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)',
    'public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)',
    'public.business_request_manual_payment_v542(uuid,uuid,text,text)',
    'public.business_get_manual_payment_request_v542(uuid)'
  ]) f
  where has_function_privilege('anon', f, 'EXECUTE');
  insert into _r values ('D1_anon_execute_revoked', v_bad is null,
    coalesce('anon still executes: '||v_bad, 'all seven refuse anon'));

  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.get_workspace_locale_preference_v97()',
    'public.set_workspace_locale_preference_v97(text,bigint)',
    'public.business_get_catalogue_media_versions_v158(uuid)',
    'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)',
    'public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)',
    'public.business_request_manual_payment_v542(uuid,uuid,text,text)',
    'public.business_get_manual_payment_request_v542(uuid)'
  ]) f
  where not has_function_privilege('authenticated', f, 'EXECUTE');
  insert into _r values ('D2_authenticated_execute_retained', v_bad is null,
    coalesce('authenticated lost: '||v_bad, 'all seven still callable by authenticated'));

  -- D3: the four server-internal functions -- no browser role executes them any more
  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.create_business(text,text,text,text[])',
    'app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)',
    'app.live_balance_programme_v381(uuid)',
    'app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid)'
  ]) f
  where has_function_privilege('anon', f, 'EXECUTE')
     or has_function_privilege('authenticated', f, 'EXECUTE');
  insert into _r values ('D3_server_internal_browser_execute_revoked', v_bad is null,
    coalesce('a browser role still executes: '||v_bad, 'none is callable by anon or authenticated'));

  -- D4: ...while the server keeps them (they are live through nested definer callers)
  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.create_business(text,text,text,text[])',
    'app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)',
    'app.live_balance_programme_v381(uuid)',
    'app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid)'
  ]) f
  where not has_function_privilege('service_role', f, 'EXECUTE');
  insert into _r values ('D4_service_role_execute_retained', v_bad is null,
    coalesce('service_role lost: '||v_bad, 'service_role still executes all four'));
end
$sec09$;

select id, case when ok then 'PASS' else 'FAIL' end as result, detail from _r order by id;

rollback;
