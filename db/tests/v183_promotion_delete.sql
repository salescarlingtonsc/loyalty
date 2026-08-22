-- Rollback-only acceptance for V183 promotion delete/retire.
--   supabase db query --linked -f db/tests/v183_promotion_delete.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- REWRITTEN BY nestly_v454. The previous version of this file read pg_get_functiondef and asserted
-- that the source text mentioned content_type='offer', both v104 write guards and `v_mode :=
-- 'retired'`. Every one of those assertions was true of a function that raised 42703 on every call
-- (it wrote audit_log.meta, a column that does not exist), so this suite was green for sixteen days
-- while End and Delete were completely inert for every merchant. v412 then repaired the module gate
-- in response to an owner report and this suite still could not tell anyone the feature was broken.
-- Nothing below inspects source text: every check calls the RPC as a real authenticated owner and
-- asserts what it did to the database.
--
--   01  a live offer RETIRES: active=false, ends_at pulled back, version bumped, row KEPT
--   02  a draft offer DELETES: the row and its branch scopes and copy are gone
--   03  the optimistic-concurrency check still refuses a stale expected_version
--   04  a non-owner with no packages/loyalty write is refused, and changes nothing
--   05  an offer belonging to another firm is not found (tenant isolation)

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v183_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v183_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_other_biz uuid := gen_random_uuid();
  v_live uuid := gen_random_uuid();
  v_draft uuid := gen_random_uuid();
  v_stale uuid := gen_random_uuid();
  v_foreign uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_res json;
  v_txt text;
  v_row public.business_customer_content_v95%rowtype;
  v_n int;
  v_version bigint;
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v183-owner@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_outsider, 'authenticated', 'authenticated',
          'v183-outsider@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules)
  values (v_biz, 'V183 Firm', 'v183-' || substr(v_biz::text, 1, 8), array['loyalty']),
         (v_other_biz, 'V183 Other Firm', 'v183o-' || substr(v_other_biz::text, 1, 8),
          array['loyalty']);
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'V183 Owner', true);

  -- Without an approved, unpaused workspace every module resolves to 'disabled' and the RPC
  -- refuses before it ever reaches the work. That refusal used to look like a passing test.
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v183 fixture'),
         (v_other_biz, 'approved', v_owner, now(), 'v183 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false), (v_other_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  insert into public.branches(id, business_id, name) values (v_branch, v_biz, 'V183 Main');

  perform set_config('app.v104_promotion_write', 'on', true);
  insert into public.business_customer_content_v95(
    id, business_id, content_type, active, display_order, starts_at, ends_at, metadata)
  values
    (v_live,    v_biz,       'offer', true,  1, now() - interval '1 day', now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb),
    (v_draft,   v_biz,       'offer', false, 2, null,                     now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb),
    (v_stale,   v_biz,       'offer', false, 3, null,                     now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb),
    (v_foreign, v_other_biz, 'offer', true,  1, null,                     now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb);
  insert into public.promotion_branch_scopes_v155(business_id, promotion_id, branch_id)
  values (v_biz, v_draft, v_branch);
  perform set_config('app.v104_promotion_write', '', true);

  perform set_config('app.v104_promotion_copy_write', 'on', true);
  insert into public.business_localized_copy_v95(business_id, entity_type, entity_id, locale, name)
  values (v_biz, 'offer', v_draft, 'en', 'V183 Draft');
  perform set_config('app.v104_promotion_copy_write', '', true);

  --------------------------------------------------------------- 1 - retire a live offer
  perform pg_temp.as_v183_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_live, null);
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_res := null;
  end;
  reset role;
  insert into _r values('01_retire_receipt',
    case when v_txt is not null then 'FAIL retiring a live offer raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'mode' = 'retired' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select * into v_row from public.business_customer_content_v95 where id = v_live;
  insert into _r values('01_retire_row_kept',
    case when v_row.id is null then 'FAIL a published offer was ERASED; reports lose it'
         when v_row.active then 'FAIL the offer is still active'
         when v_row.ends_at > now() then 'FAIL ends_at was not pulled back: ' || v_row.ends_at
         when v_row.version <= 1 then 'FAIL version was not bumped: ' || v_row.version
         else 'PASS kept, inactive, ends_at=' || v_row.ends_at || ', version=' || v_row.version end);

  select detail into v_txt from public.audit_log
   where business_id = v_biz and entity_id = v_live and action = 'promotion.retired';
  insert into _r values('01_retire_audit',
    case when v_txt is null then 'FAIL no promotion.retired row in audit_log.detail'
         else 'PASS detail=' || v_txt end);

  --------------------------------------------------------------- 2 - delete a draft offer
  perform pg_temp.as_v183_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_draft, null);
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_res := null;
  end;
  reset role;
  insert into _r values('02_delete_receipt',
    case when v_txt is not null then 'FAIL deleting a draft raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'mode' = 'deleted' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select (select count(*) from public.business_customer_content_v95 where id = v_draft)
       + (select count(*) from public.promotion_branch_scopes_v155 where promotion_id = v_draft)
       + (select count(*) from public.business_localized_copy_v95
           where entity_type = 'offer' and entity_id = v_draft)
    into v_n;
  insert into _r values('02_delete_leaves_nothing',
    case when v_n = 0 then 'PASS the draft, its branch scope and its copy are all gone'
         else 'FAIL ' || v_n || ' row(s) survived the delete' end);

  select detail into v_txt from public.audit_log
   where business_id = v_biz and entity_id = v_draft and action = 'promotion.deleted';
  insert into _r values('02_delete_audit',
    case when v_txt is null then 'FAIL no promotion.deleted row in audit_log.detail'
         else 'PASS detail=' || v_txt end);

  ------------------------------------------------------- 3 - optimistic concurrency guard
  select version into v_version from public.business_customer_content_v95 where id = v_stale;
  perform pg_temp.as_v183_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_stale, v_version + 5);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('03_stale_version_refused',
    case when v_txt like '40001%' then 'PASS ' || v_txt
         else 'FAIL a stale expected_version must be refused; got ' || v_txt end);
  select count(*) into v_n from public.business_customer_content_v95 where id = v_stale;
  insert into _r values('03_stale_version_changes_nothing',
    case when v_n = 1 then 'PASS the offer survived the refused call'
         else 'FAIL the refused call deleted the offer anyway' end);

  --------------------------------------------------------------- 4 - permission is enforced
  perform pg_temp.as_v183_user(v_outsider);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_stale, null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('04_outsider_refused',
    case when v_txt like '42501%' then 'PASS ' || v_txt
         else 'FAIL a user with no staff row must be refused; got ' || v_txt end);
  select count(*) into v_n from public.business_customer_content_v95 where id = v_stale;
  insert into _r values('04_outsider_changes_nothing',
    case when v_n = 1 then 'PASS the offer survived the refused call'
         else 'FAIL the refused call deleted the offer anyway' end);

  ---------------------------------------------------------------- 5 - tenant isolation
  perform pg_temp.as_v183_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_foreign, null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('05_foreign_offer_not_found',
    case when v_txt like '42704%' then 'PASS ' || v_txt
         else 'FAIL another firm''s offer must not be reachable; got ' || v_txt end);
  select count(*) into v_n from public.business_customer_content_v95
   where id = v_foreign and active;
  insert into _r values('05_foreign_offer_untouched',
    case when v_n = 1 then 'PASS the other firm''s offer is still live'
         else 'FAIL the other firm''s offer was modified' end);
end
$$;

select k, v from _r order by k;

rollback;
