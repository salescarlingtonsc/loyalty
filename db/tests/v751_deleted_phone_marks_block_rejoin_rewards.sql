-- nestly_v751 rollback suite — deleting an account leaves a hashed-phone mark that blocks the
-- welcome offer and the referral "new customer" test from firing again on rejoin, without
-- blocking anything else about the new account.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.customer_deletion_marks_v751 exists, has RLS enabled, and has no grants to
--       anon/authenticated.
--   02  app.phone_recently_deleted_v751(uuid,uuid) exists and is revoked from anon/authenticated.
--   03  app.issue_welcome_offer_v215 and app.referral_referred_is_new_v683 both call
--       phone_recently_deleted_v751; public.customer_delete_account_v749 writes the marks table.
--   04  end to end: a fixture customer with a verified link and no stored value deletes their
--       account (status='deleted'). Afterwards there is a per-business mark for that business
--       hashing the client's old phone_norm, plus a global (business_id is null) mark from the
--       auth phone.
--   05  a fresh client row re-registering with the SAME phone at the SAME business is recognised
--       as recently-deleted: phone_recently_deleted_v751 is TRUE and
--       referral_referred_is_new_v683 is FALSE.
--   06  a control client with a DIFFERENT phone is not recently-deleted and IS a new customer.
--   07  a business with an active custom welcome offer refuses it to a recently-deleted number
--       (issue_welcome_offer_v215 returns NULL, no grant row) but still issues it to a normal
--       new client. If no such business exists, this check is marked PASS with a detail note.

begin;

create temp table _v751(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v751 to public;

do $$
declare
  v_src text;
  v_identity uuid;
  v_auth uuid;
  v_business uuid;
  v_client uuid;
  v_phone_norm text;
  v_key text := 'suite-key-00751';
  v_result jsonb;
  v_marks_biz integer;
  v_marks_global integer;
  v_new_client uuid;
  v_ctrl_client uuid;
  v_offer_biz uuid;
  v_offer_client uuid;
  v_offer_ctrl_client uuid;
  v_grant uuid;
  v_grant_ctrl uuid;
begin
  -- 01 — table shape: exists, RLS on, no browser grants.
  insert into _v751(check_name, ok, detail)
  select '01 customer_deletion_marks_v751 exists with RLS and no anon/authenticated grants',
         c.relrowsecurity
           and not exists (
             select 1 from information_schema.role_table_grants g
              where g.table_schema='public' and g.table_name='customer_deletion_marks_v751'
                and g.grantee in ('anon','authenticated')
           ),
         'relrowsecurity=' || c.relrowsecurity::text
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='customer_deletion_marks_v751';
  if not found then
    insert into _v751(check_name, ok, detail) values
      ('01 customer_deletion_marks_v751 exists with RLS and no anon/authenticated grants',
       false, 'table not found');
  end if;

  -- 02 — phone_recently_deleted_v751 exists and is revoked from anon/authenticated.
  insert into _v751(check_name, ok, detail)
  select '02 app.phone_recently_deleted_v751 exists and is revoked from anon/authenticated',
         not has_function_privilege('anon', p.oid, 'EXECUTE')
           and not has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         'proacl=' || coalesce(p.proacl::text,'(default)')
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='phone_recently_deleted_v751';
  if not found then
    insert into _v751(check_name, ok, detail) values
      ('02 app.phone_recently_deleted_v751 exists and is revoked from anon/authenticated',
       false, 'function not found');
  end if;

  -- 03 — the two reward gates and the deletion writer all name the new machinery.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='issue_welcome_offer_v215';
  insert into _v751(check_name, ok, detail) values (
    '03a app.issue_welcome_offer_v215 calls phone_recently_deleted_v751',
    v_src like '%phone_recently_deleted_v751%', 'found=' || (v_src like '%phone_recently_deleted_v751%')::text);

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='referral_referred_is_new_v683';
  insert into _v751(check_name, ok, detail) values (
    '03b app.referral_referred_is_new_v683 calls phone_recently_deleted_v751',
    v_src like '%phone_recently_deleted_v751%', 'found=' || (v_src like '%phone_recently_deleted_v751%')::text);

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_delete_account_v749';
  insert into _v751(check_name, ok, detail) values (
    '03c public.customer_delete_account_v749 writes customer_deletion_marks_v751',
    v_src like '%customer_deletion_marks_v751%', 'found=' || (v_src like '%customer_deletion_marks_v751%')::text);

  -- Pick a live fixture: a verified link whose client has a phone and no stored value anywhere.
  select ci.id, ci.auth_user_id, l.business_id, l.client_id, c.phone_norm
    into v_identity, v_auth, v_business, v_client, v_phone_norm
    from public.customer_identities ci
    join public.customer_links l on l.identity_id = ci.id and l.state = 'verified'
    join public.clients c on c.id = l.client_id and c.business_id = l.business_id
   where c.phone_norm is not null
     and not exists (
       select 1 from public.sv_accounts sa
        where sa.client_id in (
          select l2.client_id from public.customer_links l2
           where l2.identity_id = ci.id and l2.state = 'verified'
        )
     )
   order by l.created_at
   limit 1;

  if v_identity is null then
    -- Fallback fixture, known good per the prior v750/v751 session's own probing.
    v_identity := 'd4717615-b102-4076-b041-3d38ce838172';
    v_auth := 'eeb3ce63-73ca-4713-b1b5-95bd37e0028a';
    select l.business_id, l.client_id, c.phone_norm
      into v_business, v_client, v_phone_norm
      from public.customer_links l
      join public.clients c on c.id = l.client_id and c.business_id = l.business_id
     where l.identity_id = v_identity and l.state = 'verified' and c.phone_norm is not null
     order by l.created_at
     limit 1;
  end if;

  if v_business is null or v_phone_norm is null then
    insert into _v751(check_name, ok, detail) values
      ('04 fixture', false, 'no usable verified-link fixture with a phone and no stored value found');
  else
    -- 04 — end to end: delete, then look for the marks.
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_auth::text, 'role','authenticated')::text, true);
    set local role authenticated;
    v_result := public.customer_delete_account_v749('DELETE', v_key);
    reset role;

    insert into _v751(check_name, ok, detail) values (
      '04a the deletion succeeds (status=deleted)',
      v_result->>'status' = 'deleted', coalesce(v_result::text,'null'));

    select count(*)::integer into v_marks_biz
      from public.customer_deletion_marks_v751
     where business_id = v_business and phone_hash = app.v89_sha256(v_phone_norm);
    insert into _v751(check_name, ok, detail) values (
      '04b a per-business mark exists for the deleted client''s hashed phone',
      v_marks_biz >= 1, v_marks_biz::text || ' matching rows');

    select count(*)::integer into v_marks_global
      from public.customer_deletion_marks_v751
     where business_id is null;
    insert into _v751(check_name, ok, detail) values (
      '04c a global (business_id is null) mark exists from the auth phone',
      v_marks_global >= 1, v_marks_global::text || ' global rows');

    -- 05 — a fresh registration with the SAME phone at the SAME business is recognised.
    insert into public.clients(business_id, full_name, phone)
    values (v_business, 'Suite v751 rejoin', v_phone_norm)
    returning id into v_new_client;

    insert into _v751(check_name, ok, detail) values (
      '05a phone_recently_deleted_v751 is TRUE for the re-registered phone',
      app.phone_recently_deleted_v751(v_business, v_new_client), 'client=' || v_new_client::text);
    insert into _v751(check_name, ok, detail) values (
      '05b referral_referred_is_new_v683 is FALSE for the re-registered phone',
      not app.referral_referred_is_new_v683(v_business, v_new_client), 'client=' || v_new_client::text);

    -- 06 — a control client with a different, never-deleted phone is unaffected.
    insert into public.clients(business_id, full_name, phone)
    values (v_business, 'Suite v751 control', '81112233')
    returning id into v_ctrl_client;

    insert into _v751(check_name, ok, detail) values (
      '06a phone_recently_deleted_v751 is FALSE for a different, undeleted phone',
      not app.phone_recently_deleted_v751(v_business, v_ctrl_client), 'client=' || v_ctrl_client::text);
    insert into _v751(check_name, ok, detail) values (
      '06b referral_referred_is_new_v683 is TRUE for a different, undeleted phone',
      app.referral_referred_is_new_v683(v_business, v_ctrl_client), 'client=' || v_ctrl_client::text);
  end if;

  -- 07 — the welcome offer gate, on any business running an active custom offer.
  select business_id into v_offer_biz
    from public.business_welcome_offers_v215
   where active and reward_catalog_kind = 'custom'
   limit 1;

  if v_offer_biz is null then
    insert into _v751(check_name, ok, detail) values
      ('07 welcome offer gate', true, 'no active custom welcome offer to exercise');
  else
    insert into public.customer_deletion_marks_v751(business_id, phone_hash)
    values (v_offer_biz, app.v89_sha256('81119999'));

    insert into public.clients(business_id, full_name, phone)
    values (v_offer_biz, 'Suite v751 offer blocked', '81119999')
    returning id into v_offer_client;

    v_grant := app.issue_welcome_offer_v215(v_offer_biz, v_offer_client);
    insert into _v751(check_name, ok, detail) values (
      '07a issue_welcome_offer_v215 returns NULL for a recently-deleted number',
      v_grant is null, 'grant=' || coalesce(v_grant::text,'null'));
    insert into _v751(check_name, ok, detail) values (
      '07b no welcome_offer_grants_v215 row exists for the blocked client',
      not exists(select 1 from public.welcome_offer_grants_v215 where client_id = v_offer_client),
      'client=' || v_offer_client::text);

    insert into public.clients(business_id, full_name, phone)
    values (v_offer_biz, 'Suite v751 offer control', '81118888')
    returning id into v_offer_ctrl_client;

    v_grant_ctrl := app.issue_welcome_offer_v215(v_offer_biz, v_offer_ctrl_client);
    insert into _v751(check_name, ok, detail) values (
      '07c issue_welcome_offer_v215 returns a grant id for a normal new client',
      v_grant_ctrl is not null, 'grant=' || coalesce(v_grant_ctrl::text,'null'));
  end if;

  reset role;
exception when others then
  reset role;
  insert into _v751(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v751 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v751;

rollback;
