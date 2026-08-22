-- Rollback-only acceptance for nestly_v427 — a granted entitlement reaches the customer who
-- earned it, and the bring-back figure comes from the engine that issues bring-backs.
--   supabase db query --linked -f db/tests/v427_entitlement_visibility.sql
-- FAIL rows are failures. Nothing is committed: the whole suite is one transaction that rolls
-- back, including every fixture grant it creates.
--
-- WHY FIXTURES ARE CREATED RATHER THAN FOUND. As of 2026-08-22 production holds zero rows in all
-- three grant tables (welcome_offer_grants_v215, bringback_grants_v361, referral_grants_v420) —
-- which is itself part of why the gap went unnoticed. The suite therefore inserts the grants it
-- needs directly. It deliberately does NOT call app.issue_bringback_for_business_v361 to make
-- them: that issuer selects on "last sale older than away_days" against live sales and would
-- either issue nothing or issue to real customers depending on the day it runs, which is not a
-- fixture, it is a coin toss. Direct inserts obey the same check constraints the issuer does.
--
-- What this proves, in order:
--   01 the new function exists with the ACL a customer read must have (no anon, no public);
--   02 a real customer, acting AS THEMSELVES, sees a welcome grant issued to them;
--   03 a DIFFERENT verified customer at the SAME firm sees nothing — the isolation assertion;
--   04 bring-back and referral grants surface the same way, each labelled with its source;
--   05 a lapsed grant is not offered as active, and is reported in history as expired;
--   06 redeeming the welcome offer at the counter moves it out of active, into v427 history,
--      and into the customer's own Rewards -> History list (customer_get_reward_history_v422);
--   07 the same for a bring-back voucher;
--   08 a customer with no verified link to this firm is refused, not given an empty list;
--   09 anonymous callers are refused;
--   10 configuring the welcome offer is owner-only: a manager holding module WRITE on 'loyalty'
--      is refused with 42501, and the owner is accepted;
--   11 the business-side bring-back stat counts bringback_campaigns_v361 / _grants_v361, and
--      counts REDEEMED, not merely granted;
--   12 db/tests/v386 check 03 still holds: unbounded v386 is v271, exactly.
--
-- Runs against the firm in the owner's photos (business 8492e8d6), which has an owner staff row,
-- an active branch, and five verified customer links.

begin;

create temp table _r(k text, v text) on commit drop;
-- The suite switches into `authenticated` and `anon` to prove the ACL as the real roles, so
-- those roles must be able to record their own results.
grant insert, select on _r to authenticated, anon;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_slug text;
  v_branch uuid;
  v_owner_user uuid;
  v_manager_user uuid;
  v_manager_staff uuid;
  -- customer A is the one who earns everything; customer B is the isolation control.
  v_client_a uuid; v_auth_a uuid;
  v_client_b uuid; v_auth_b uuid;
  v_campaign uuid;
  v_referral uuid;
  v_welcome_grant uuid;
  v_bringback_grant uuid;
  v_referral_grant uuid;
  v_lapsed_grant uuid;
  v_payload jsonb;
  v_history jsonb;
  v_usage jsonb;
  v_row jsonb;
  v_acl text;
  v_msg text; v_code text;
  v_count integer;
begin
  select slug into v_slug from public.businesses where id = v_biz;
  select id into v_branch from public.branches
   where business_id = v_biz and active order by is_default desc, created_at limit 1;
  select user_id into v_owner_user from public.staff
   where business_id = v_biz and role = 'owner' and active and user_id is not null limit 1;

  -- Two DIFFERENT verified customers at this firm.
  select link.client_id, identity.auth_user_id into v_client_a, v_auth_a
    from public.customer_links link
    join public.customer_identities identity on identity.id = link.identity_id
   where link.business_id = v_biz and link.state = 'verified' and identity.status = 'active'
   order by link.created_at, link.id limit 1;
  select link.client_id, identity.auth_user_id into v_client_b, v_auth_b
    from public.customer_links link
    join public.customer_identities identity on identity.id = link.identity_id
   where link.business_id = v_biz and link.state = 'verified' and identity.status = 'active'
     and link.client_id <> v_client_a
   order by link.created_at, link.id limit 1;

  if v_slug is null or v_branch is null or v_owner_user is null
     or v_client_a is null or v_client_b is null then
    insert into _r values('00_fixture',
      'FAIL the firm needs a slug, an active branch, an owner login and two verified customers');
    return;
  end if;
  insert into _r values('00_fixture', 'PASS two verified customers, an owner and a branch');

  -- ==========================================================================================
  -- 01 THE ACL
  -- ==========================================================================================
  select coalesce(array_to_string(proacl, ' '), '') into v_acl
    from pg_proc where oid = 'public.customer_get_entitlements_v427(text)'::regprocedure;
  insert into _r values('01_acl_no_anon',
    case when v_acl not like '%anon=X%' and v_acl like '%authenticated=X%'
         then 'PASS authenticated may execute it; anon may not'
         else 'FAIL unexpected ACL: ' || v_acl end);

  -- ==========================================================================================
  -- FIXTURES: one of each entitlement for customer A, plus one already-lapsed grant.
  -- ==========================================================================================
  insert into public.welcome_offer_grants_v215(
      business_id, client_id, min_spend_cents, reward_catalog_kind, reward_label, expires_at)
    values (v_biz, v_client_a, 0, 'custom', 'V427 welcome pastry', now() + interval '30 days')
    returning id into v_welcome_grant;

  select id into v_campaign from public.bringback_campaigns_v361
   where business_id = v_biz and deleted_at is null order by away_days, id limit 1;
  if v_campaign is null then
    insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, expiry_days)
      values (v_biz, 'V427 fixture campaign', 'V427 free coffee', 60, 30)
      returning id into v_campaign;
  end if;
  insert into public.bringback_grants_v361(
      business_id, campaign_id, client_id, reward_label, away_days, cycle_key, expires_at)
    values (v_biz, v_campaign, v_client_a, 'V427 free coffee', 60,
            (now() - interval '61 days')::date, now() + interval '30 days')
    returning id into v_bringback_grant;

  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status, qualified_at)
    values (v_biz, v_client_a, v_client_b, 'qualified', now())
    returning id into v_referral;
  insert into public.referral_grants_v420(
      business_id, client_id, referral_id, reward_label, beneficiary, expires_at)
    values (v_biz, v_client_a, v_referral, 'V427 referral treat', 'referrer', now() + interval '30 days')
    returning id into v_referral_grant;

  -- A grant that has lapsed but whose stored status is still 'granted' — the shape the tables
  -- actually hold, because expiry is only written when someone tries to redeem.
  insert into public.referral_grants_v420(
      business_id, client_id, referral_id, reward_label, beneficiary, expires_at)
    values (v_biz, v_client_a, v_referral, 'V427 lapsed treat', 'friend', now() - interval '1 day')
    returning id into v_lapsed_grant;

  -- ==========================================================================================
  -- 02-05 THE CUSTOMER'S OWN VIEW
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_payload := public.customer_get_entitlements_v427(v_slug);

  insert into _r values('02_contract',
    case when v_payload->>'contract' = 'v427' and (v_payload->>'business_id')::uuid = v_biz
         then 'PASS' else 'FAIL ' || coalesce(v_payload::text, 'null') end);

  select count(*)::int into v_count
    from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant, v_referral_grant);
  insert into _r values('02_three_active',
    case when v_count = 3 then 'PASS all three earned entitlements are visible'
         else 'FAIL saw ' || v_count || ' of 3 in active' end);

  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_welcome_grant;
  insert into _r values('02_welcome_shape',
    case when v_row->>'source' = 'welcome'
          and v_row->>'label' = 'V427 welcome pastry'
          and v_row->>'status' = 'active'
          and v_row->>'granted_at' is not null
          and v_row->>'expires_at' is not null
          and v_row->>'instructions' is not null
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_bringback_grant;
  insert into _r values('04_bringback_shape',
    case when v_row->>'source' = 'bringback' and (v_row->>'away_days')::int = 60
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_referral_grant;
  insert into _r values('04_referral_shape',
    case when v_row->>'source' = 'referral' and v_row->>'beneficiary' = 'referrer'
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- 05 the lapsed one: never offered, always explained.
  select count(*)::int into v_count
    from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_lapsed_grant;
  insert into _r values('05_lapsed_not_active',
    case when v_count = 0 then 'PASS a lapsed grant is not offered'
         else 'FAIL an expired entitlement was offered as claimable' end);
  select item into v_row from jsonb_array_elements(v_payload->'history') item
   where (item->>'id')::uuid = v_lapsed_grant;
  insert into _r values('05_lapsed_in_history',
    case when v_row->>'status' = 'expired'
         then 'PASS it is reported as expired' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- ==========================================================================================
  -- 03 ISOLATION: the same call, made by the other customer at the same firm
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_b, 'role', 'authenticated')::text, true);
  v_payload := public.customer_get_entitlements_v427(v_slug);
  select count(*)::int into v_count
    from jsonb_array_elements(v_payload->'active' || v_payload->'history') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant, v_referral_grant, v_lapsed_grant);
  insert into _r values('03_isolation',
    case when v_count = 0 then 'PASS customer B sees none of customer A''s entitlements'
         else 'FAIL customer B saw ' || v_count || ' of customer A''s entitlements' end);

  -- ==========================================================================================
  -- 08/09 REFUSALS
  -- ==========================================================================================
  begin
    perform public.customer_get_entitlements_v427('a-slug-this-customer-has-no-link-to');
    insert into _r values('08_unlinked_refused', 'FAIL an unlinked business returned a payload');
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
    insert into _r values('08_unlinked_refused',
      case when v_code = '42501' then 'PASS refused 42501' else 'FAIL ' || v_code || ' ' || v_msg end);
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
  set local role anon;
  begin
    perform public.customer_get_entitlements_v427(v_slug);
    insert into _r values('09_anon_refused', 'FAIL anon executed it');
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    insert into _r values('09_anon_refused',
      case when v_code in ('42501','28000') then 'PASS refused ' || v_code
           else 'FAIL ' || v_code end);
  end;
  reset role;

  -- ==========================================================================================
  -- 06/07 REDEMPTION MOVES THE CANONICAL STATE, AND BOTH CUSTOMER READS FOLLOW
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.staff_redeem_welcome_offer_v215(
    v_biz, v_client_a, v_branch, null, 'v427-test-welcome-idempotency');
  perform public.staff_redeem_bringback_v361(v_biz, v_client_a, v_branch, v_bringback_grant);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_payload := public.customer_get_entitlements_v427(v_slug);
  v_history := public.customer_get_reward_history_v422(v_slug, 100);

  select count(*)::int into v_count
    from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant);
  insert into _r values('06_left_active',
    case when v_count = 0 then 'PASS redeemed entitlements are no longer claimable'
         else 'FAIL ' || v_count || ' redeemed entitlement(s) still offered' end);

  select count(*)::int into v_count
    from jsonb_array_elements(v_payload->'history') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant)
     and item->>'status' = 'redeemed' and item->>'redeemed_at' is not null;
  insert into _r values('06_in_v427_history',
    case when v_count = 2 then 'PASS both appear in v427 history as redeemed'
         else 'FAIL only ' || v_count || ' of 2 in v427 history' end);

  select count(*)::int into v_count
    from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant);
  insert into _r values('07_in_v422_history',
    case when v_count = 2 then 'PASS both appear in the customer''s Rewards -> History list'
         else 'FAIL only ' || v_count || ' of 2 in v422 history' end);

  select item into v_row from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid = v_welcome_grant;
  insert into _r values('07_v422_row_shape',
    case when v_row->>'source' = 'welcome'
          and v_row->>'reward_name' = 'V427 welcome pastry'
          and (v_row->>'consumes_balance')::boolean = false
          and (v_row->>'points_spent')::int = 0
          and v_row->>'sale_id' is not null
          and v_row ? 'image_ref' and v_row ? 'fulfillment_kind'
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- The pre-existing rows must be untouched by the extension: every points redemption still
  -- carries the keys the client already reads, now with source='reward'.
  select count(*)::int into v_count
    from jsonb_array_elements(v_history->'items') item
   where item->>'source' = 'reward';
  insert into _r values('07_v422_reward_rows_kept',
    'INFO ' || v_count || ' points redemption row(s) still listed, tagged source=reward');
  reset role;

  -- ==========================================================================================
  -- 10 CONFIGURING THE WELCOME OFFER IS OWNER-ONLY
  -- ==========================================================================================
  -- A manager who genuinely holds module WRITE on 'loyalty' — the permission the old body
  -- accepted. Both halves matter: if can_module_write were false the refusal would prove nothing.
  select identity.auth_user_id into v_manager_user
    from public.customer_identities identity
   where identity.auth_user_id not in (
     select user_id from public.staff where business_id = v_biz and user_id is not null)
   order by identity.created_at limit 1;
  if v_manager_user is null then
    insert into _r values('10_manager_refused', 'FAIL no spare auth user to make a manager from');
  else
    insert into public.staff(business_id, user_id, name, role, active, access_state)
      values (v_biz, v_manager_user, 'V427 fixture manager', 'manager', true, 'approved')
      returning id into v_manager_staff;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_manager_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into _r values('10_manager_has_module_write',
      case when app.can_module_write(v_biz, 'loyalty')
           then 'PASS the fixture manager really does hold loyalty write'
           else 'FAIL the fixture manager has no loyalty write, so the refusal proves nothing' end);
    begin
      perform public.business_set_welcome_offer_v215(v_biz, true, 0, 'custom', null, null, 'V427 manager attempt');
      insert into _r values('10_manager_refused', 'FAIL a manager configured the welcome offer');
    exception when others then
      get stacked diagnostics v_code = returned_sqlstate;
      insert into _r values('10_manager_refused',
        case when v_code = '42501' then 'PASS refused 42501' else 'FAIL ' || v_code end);
    end;
    reset role;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
      v_row := public.business_set_welcome_offer_v215(v_biz, true, 0, 'custom', null, null, 'V427 owner attempt');
      insert into _r values('10_owner_accepted',
        case when v_row->>'status' = 'ok' and v_row->>'reward_label' = 'V427 owner attempt'
             then 'PASS the owner may still configure it' else 'FAIL ' || v_row::text end);
    exception when others then
      get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
      insert into _r values('10_owner_accepted', 'FAIL owner refused ' || v_code || ' ' || v_msg);
    end;
    reset role;
  end if;

  -- ==========================================================================================
  -- 11/12 THE BUSINESS-SIDE BRING-BACK FIGURE
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_usage := public.business_programme_usage_v271(v_biz);

  select item into v_row from jsonb_array_elements(v_usage->'retention') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('11_campaign_listed',
    case when v_row is not null and v_row->>'source' = 'bringback_v361'
         then 'PASS the v361 campaign is in the retention array'
         else 'FAIL the canonical bring-back campaign is not counted' end);
  insert into _r values('11_counts_redeemed',
    case when (v_row->>'customers')::int = 1
         then 'PASS one customer redeemed a bring-back voucher'
         else 'FAIL expected 1, got ' || coalesce(v_row->>'customers','null') end);

  select count(*)::int into v_count
    from jsonb_array_elements(v_usage->'bringback') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('11_bringback_alias',
    case when v_count = 1 then 'PASS the bringback alias carries the same row'
         else 'FAIL the bringback key does not name the campaign' end);

  -- The legacy engine's own figures are still queryable for audit, under their own source.
  select count(*)::int into v_count
    from jsonb_array_elements(v_usage->'retention') item
   where item->>'source' = 'retention_legacy';
  insert into _r values('11_legacy_kept',
    case when v_count = (select count(*) from public.retention_programs where business_id = v_biz)
         then 'PASS every legacy retention programme is still reported'
         else 'FAIL legacy audit rows went missing' end);

  insert into _r values('12_unbounded_equals_v271',
    case when ((public.business_programme_usage_v386(v_biz) - 'as_of' - 'window')
             = (public.business_programme_usage_v271(v_biz) - 'as_of'))
         then 'PASS' else 'FAIL the windowless read drifted from v271' end);

  -- A window that ends before today cannot contain a redemption made a moment ago.
  select item into v_row
    from jsonb_array_elements(
      public.business_programme_usage_v386(v_biz, '2020-01-01'::date, '2020-01-02'::date)->'retention') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('12_window_excludes',
    case when (v_row->>'customers')::int = 0
         then 'PASS an old window reports 0 for the campaign'
         else 'FAIL got ' || coalesce(v_row->>'customers','null') end);
  reset role;
exception when others then
  reset role;
  get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
  insert into _r values('99_suite_aborted', 'FAIL ' || v_code || ' ' || v_msg);
end $$;

select k, v from _r order by k;

rollback;
