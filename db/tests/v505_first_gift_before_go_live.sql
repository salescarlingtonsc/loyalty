-- Rollback-only acceptance for nestly_v505 — a business that has never published can save its
-- first gift. Run: supabase db query --linked -f db/tests/v505_first_gift_before_go_live.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- The defect this pins: public.business_create_reward_v326 raised XX001 'this business has no
-- published loyalty configuration yet' for every business whose businesses.active_config_version_id
-- is null — which is every business that has not been through go-live. The Rewards Programme
-- surface ("Continue set up" -> Point system -> Save gift) calls that writer directly, so the
-- first gift could never be saved, and publishing a stamp card requires a gift. Eight production
-- tenants were sitting at zero gifts because of it on 2026-08-25.
--
-- Fixture: one business seeded exactly the way onboarding seeds one — loyalty_programs with
-- configuration_status='draft', so app.seed_loyalty_config_version() writes v1 as a DRAFT and
-- businesses.active_config_version_id stays null.
--
--   01  the precondition is real: no published config, one draft version
--   02  the first gift SAVES (the XX001 refusal is gone) and says so honestly:
--       publish_status='pending', unpublished_draft=true, with a blocker sentence
--   03  it landed in the DRAFT version, not nowhere and not a published one
--   04  customers still see nothing — unpublished means unpublished
--   05  an edit reaches the draft version row too (before v505 the version write was skipped
--       when there was no active version, so publishing would have made the STALE text live)
--   06  publishing carries the edited gift live, and the reward is served
--   07  the published path is unchanged: the NEXT gift returns publish_status='published',
--       unpublished_draft=false, and targets the active version
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v505_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v505_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v505-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_spine uuid;
  v_client uuid := gen_random_uuid();
  v_draft uuid;
  v_active uuid;
  v_gift uuid;
  v_gift2 uuid;
  v_json jsonb;
  v_txt text; v_n integer;
begin
  -- ==========================================================================================
  -- FIXTURE — a brand-new tenant, seeded as onboarding seeds one
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V505 Acceptance', v_slug, array['loyalty'], 'redeem');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  select id into v_spine from public.business_programmes
   where business_id = v_biz and kind = 'points';

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v505-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V505 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v505 acceptance',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;

  perform pg_temp.as_v505_user(v_owner);

  -- DRAFT, not published — this single word is the whole defect's precondition.
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, earn_points_per_dollar)
  values (v_biz, false, 'classic', 'points', 'draft', 1)
  on conflict (business_id) do update
    set active = false, loyalty_model = 'classic', kind = 'points',
        configuration_status = 'draft', earn_points_per_dollar = 1;

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V505 Customer', '+65 9505 1001');

  -- ==========================================================================================
  -- 01  THE PRECONDITION
  -- ==========================================================================================
  select b.active_config_version_id into v_active from public.businesses b where b.id = v_biz;
  select count(*) into v_n from public.firm_config_versions
   where business_id = v_biz and status = 'draft';
  select id into v_draft from public.firm_config_versions
   where business_id = v_biz and status = 'draft' order by version_no desc limit 1;
  insert into _r values('01_never_published',
    case when v_active is null and v_n = 1 and v_draft is not null
      then 'PASS no published configuration, one draft version — a brand-new tenant'
      else 'FAIL active=' || coalesce(v_active::text,'null') || ' drafts=' || v_n end);

  -- ==========================================================================================
  -- 02  THE FIRST GIFT SAVES
  -- ==========================================================================================
  v_json := public.business_create_reward_v326(v_biz, v_spine, 'Lotion', 10, 0, 'Redeem today!');
  v_gift := (v_json ->> 'reward_id')::uuid;
  insert into _r values('02_first_gift_saves',
    case when v_json ->> 'status' = 'ok' and v_gift is not null
      then 'PASS the XX001 refusal is gone — the first gift saved'
      else 'FAIL ' || coalesce(v_json::text, 'null') end);
  insert into _r values('02_reply_is_honest',
    case when v_json ->> 'publish_status' = 'pending'
          and (v_json ->> 'unpublished_draft')::boolean
          and coalesce(v_json #>> '{blockers,0,message}', '') like '%not gone live%'
      then 'PASS pending, with the sentence the toast shows instead of "live for customers"'
      else 'FAIL publish_status=' || coalesce(v_json ->> 'publish_status','null')
           || ' unpublished_draft=' || coalesce(v_json ->> 'unpublished_draft','null')
           || ' blocker=' || coalesce(v_json #>> '{blockers,0,message}','null') end);

  -- ==========================================================================================
  -- 03  IT LANDED IN THE DRAFT
  -- ==========================================================================================
  select count(*) into v_n from public.loyalty_reward_versions
   where reward_id = v_gift and business_id = v_biz and config_version_id = v_draft;
  insert into _r values('03_version_row_on_the_draft',
    case when v_n = 1 and (v_json ->> 'target_version_id')::uuid = v_draft
      then 'PASS the version row sits on the business''s own draft'
      else 'FAIL rows=' || v_n || ' target=' || coalesce(v_json ->> 'target_version_id','null') end);
  select count(*) into v_n from public.loyalty_rewards
   where id = v_gift and business_id = v_biz and active and cost_points = 10;
  insert into _r values('03_base_row_visible_to_the_owner',
    case when v_n = 1 then 'PASS the gift shows in the owner''s Live gifts list (loyalty_rewards)'
         else 'FAIL ' || v_n || ' base rows' end);

  -- ==========================================================================================
  -- 04  CUSTOMERS STILL SEE NOTHING
  -- ==========================================================================================
  select count(*) into v_n from app.reward_availability_v432(v_biz, v_client, now()) r
   where r.reward_id = v_gift;
  insert into _r values('04_unpublished_stays_invisible',
    case when v_n = 0 then 'PASS an unpublished gift is not served to customers'
         else 'FAIL the customer can already see it (' || v_n || ' rows)' end);

  -- ==========================================================================================
  -- 05  AN EDIT REACHES THE DRAFT ROW
  -- ==========================================================================================
  v_json := public.business_update_reward_v326(v_biz, v_gift, 'Body Lotion', 12,
              'Redeem today!', 0, null, false, null, true, null);
  select internal_name into v_txt from public.loyalty_reward_versions
   where reward_id = v_gift and business_id = v_biz and config_version_id = v_draft;
  select cost_points into v_n from public.loyalty_reward_versions
   where reward_id = v_gift and business_id = v_biz and config_version_id = v_draft;
  insert into _r values('05_edit_reaches_the_draft',
    case when v_txt = 'Body Lotion' and v_n = 12
      then 'PASS the draft version carries the edit — publishing cannot make stale text live'
      else 'FAIL draft still reads name=' || coalesce(v_txt,'null') || ' points=' || coalesce(v_n::text,'null') end);
  insert into _r values('05_edit_reply_is_pending',
    case when v_json ->> 'publish_status' = 'pending' and (v_json ->> 'unpublished_draft')::boolean
      then 'PASS an edit before go-live says pending too'
      else 'FAIL ' || coalesce(v_json ->> 'publish_status','null') end);

  -- ==========================================================================================
  -- 06  PUBLISHING CARRIES IT LIVE
  -- ==========================================================================================
  update public.loyalty_program_versions set active = true
   where config_version_id = v_draft and business_id = v_biz;
  perform public.publish_loyalty_config(v_draft);
  select b.active_config_version_id into v_active from public.businesses b where b.id = v_biz;
  select count(*) into v_n from app.reward_availability_v432(v_biz, v_client, now()) r
   where r.reward_id = v_gift;
  select customer_name into v_txt from public.loyalty_rewards where id = v_gift;
  insert into _r values('06_publish_makes_it_live',
    case when v_active = v_draft and v_n = 1 and v_txt = 'Body Lotion'
      then 'PASS go-live publishes the draft and the edited gift reaches customers'
      else 'FAIL active=' || coalesce(v_active::text,'null') || ' served=' || v_n
           || ' name=' || coalesce(v_txt,'null') end);

  -- ==========================================================================================
  -- 07  THE PUBLISHED PATH IS UNCHANGED
  -- ==========================================================================================
  v_json := public.business_create_reward_v326(v_biz, v_spine, 'Tote bag', 25, 0, null);
  v_gift2 := (v_json ->> 'reward_id')::uuid;
  select count(*) into v_n from public.loyalty_reward_versions
   where reward_id = v_gift2 and business_id = v_biz and config_version_id = v_active;
  insert into _r values('07_published_path_unchanged',
    case when v_json ->> 'publish_status' = 'published'
          and (v_json ->> 'unpublished_draft')::boolean is false
          and v_n = 1
      then 'PASS once published, gifts go straight to the active version and report published'
      else 'FAIL publish_status=' || coalesce(v_json ->> 'publish_status','null')
           || ' unpublished_draft=' || coalesce(v_json ->> 'unpublished_draft','null')
           || ' rows_on_active=' || v_n end);
end $$;

select * from _r order by k;
rollback;
