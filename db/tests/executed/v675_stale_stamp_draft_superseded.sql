-- Rollback-only acceptance for nestly_v675 — a stale stamp-edit draft is retired, never reused.
--   supabase db query --linked -f db/tests/v675_stale_stamp_draft_superseded.sql
-- Any row whose value starts with FAIL is a failure. Everything runs inside one transaction and
-- is rolled back; nothing is committed.
--
-- The finding (audit F035, P1): app.stamp_config_edit_begin_v433 reused the newest open
-- 'stamp_edit_split_v433' draft on its source tag alone. Once anything else published a new
-- configuration version, that draft was behind the business's pointer forever, and since
-- nestly_v564 public.publish_loyalty_config refuses a draft that is behind ('stale_draft',
-- 23514) — so every later stamp-card edit went begin → the same stale draft → commit → publish
-- → raise → whole save rolled back, permanently, on the tenant's real data.
--
-- The suite BUILDS the wedge with the real RPCs an owner drives, rather than asserting on
-- source text: a pending half-edit, an unrelated publish, then a stamp edit.
--
--   00  the two functions are deployed, are not duplicated, and anon cannot execute them
--   01  the fixture is a published stamps firm: a 6-stamp card with a gift on stamp 6
--   02  WEDGE step 1 — a gift added past the last stamp PENDS, leaving one open split draft D
--       based on the then-active version A (this is nestly_v433's deliberate two-part edit)
--   03  WEDGE step 2 — an unrelated surface publishes B; nothing supersedes D, so D is now
--       behind the pointer exactly as jess-salon is in production
--   04  WEDGE proven — publishing D itself raises stale_draft (23514). This is what the owner
--       hit on every later stamp edit, because begin handed D back every time.
--   05  THE FIX — the next real stamp edit SUCCEEDS: D is abandoned rather than reused, the
--       edit lands on a draft based on B, and it publishes
--   06  the abandoned draft is recorded in audit_log, not silently dropped
--   07  a FRESH split draft, based on the current active version, is still reused (the pending
--       two-part edit that nestly_v433 exists for is not broken by the fix)
--   08  and the estate-wide backfill's predicate now finds nothing for this firm

begin;

create temp table _r(k text, v text) on commit drop;

-- Impersonate a browser session: the RPCs are SECURITY DEFINER but gate on auth.uid().
create or replace function pg_temp.as_v675_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v675_user(uuid) to public;

-- ------------------------------------------------------------------ 0 - shape of the two functions
do $$
declare v_n int;
begin
  if to_regprocedure('app.stamp_config_edit_begin_v433(uuid)') is null then
    insert into _r values('00_begin_deployed', 'FAIL app.stamp_config_edit_begin_v433 is not deployed');
  else
    insert into _r values('00_begin_deployed', 'PASS app.stamp_config_edit_begin_v433 is deployed');
  end if;
  if to_regprocedure('app.stamp_config_abandon_stale_drafts_v675(uuid)') is null then
    insert into _r values('00_abandon_deployed', 'FAIL app.stamp_config_abandon_stale_drafts_v675 is not deployed');
  else
    insert into _r values('00_abandon_deployed', 'PASS app.stamp_config_abandon_stale_drafts_v675 is deployed');
  end if;

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('stamp_config_edit_begin_v433', 'stamp_config_abandon_stale_drafts_v675');
  insert into _r values('00_no_overload_twin',
    case when v_n = 2 then 'PASS exactly one candidate each'
         else 'FAIL ' || v_n || ' candidate(s) — an overload twin exists' end);

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('stamp_config_edit_begin_v433', 'stamp_config_abandon_stale_drafts_v675')
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  insert into _r values('00_internal_only',
    case when v_n = 0 then 'PASS neither anon nor authenticated may call the edit-path internals'
         else 'FAIL ' || v_n || ' internal function(s) are directly callable from the API' end);
end
$$;

do $v675$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_a uuid := gen_random_uuid();          -- version A: the published starting configuration
  v_spine uuid;
  v_reward uuid := gen_random_uuid();     -- the gift on stamp 6
  v_b uuid;                               -- version B: the unrelated publish
  v_d uuid;                               -- draft D: the half-finished stamp edit
  v_e uuid;                               -- the fresh draft the fix opens
  v_f uuid;                               -- a fresh pending draft, for the reuse check
  v_res jsonb;
  v_json json;
  v_txt text;
  v_n int;
  v_status text;
  v_base uuid;
begin
  ---------------------------------------------------------------- fixture
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v675-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules)
  values (v_biz, 'V675 Firm', 'v675-' || substr(v_biz::text, 1, 8), array['loyalty']);
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'V675 Owner', true);
  -- inserting a business auto-creates an undecided controls row, so this takes the conflict branch
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v675 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused = false;
  insert into public.subscriptions(business_id, status, trial_ends_at)
  values (v_biz, 'trialing', now() + interval '7 days')
  on conflict (business_id) do update set status = 'trialing';

  -- Inserting a business auto-creates its programme spine rows; switch the firm onto stamps the
  -- way business_switch_programme would.
  update public.business_programmes set active = (kind = 'stamps'),
         activated_at = case when kind = 'stamps' then now() else activated_at end
   where business_id = v_biz;
  select id into v_spine from public.business_programmes
   where business_id = v_biz and kind = 'stamps';
  if v_spine is null then raise exception 'v675 fixture: no stamps programme spine'; end if;

  insert into public.firm_config_versions(
    id, business_id, version_no, status, source, snapshot_hash, created_by)
  values (v_a, v_biz, 1, 'draft', 'manual', md5('v675-firm'), v_owner);

  insert into public.loyalty_rewards(id, business_id, programme_id, name, internal_name,
                                     customer_name, fulfillment_kind, cost_points, credit_cents,
                                     estimated_cost_cents, active, paused)
  values (v_reward, v_biz, v_spine, 'V675 Sixth Stamp Gift', 'V675 Sixth Stamp Gift',
          'V675 Sixth Stamp Gift', 'manual_item', 6, 0, 0, true, false);

  -- The version tables carry an immutability guard that reads auth.uid(); the claims are set
  -- without switching role, because `authenticated` holds no INSERT grant on them — only the
  -- SECURITY DEFINER publish path writes them in production, and this fixture stands in for it.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.loyalty_program_versions(
    config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents,
    tier_basis, expiry_mode, stamp_target, stamp_per_cents)
  values (v_a, v_biz, 'points', 'stamps', true, 1, 800, 2000, 'visits', 'none', 6, 500);
  insert into public.loyalty_reward_versions(
    config_version_id, business_id, programme_id, reward_id, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active)
  values (v_a, v_biz, v_spine, v_reward, 'V675 Sixth Stamp Gift', 'V675 Sixth Stamp Gift',
          'manual_item', 6, 0, 0, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);

  update public.firm_config_versions set status = 'published', published_at = now() where id = v_a;

  insert into public.loyalty_programs(
    business_id, kind, active, loyalty_model, configuration_status,
    current_config_version_id, earn_points_per_dollar, redeem_points,
    reward_credit_cents, tier_basis, expiry_mode, stamp_target, stamp_per_cents)
  values (v_biz, 'points', true, 'stamps', 'published', v_a, 1, 800, 2000, 'visits', 'none', 6, 500);

  perform set_config('app.v79_system_transition', 'on', true);
  update public.businesses set active_config_version_id = v_a where id = v_biz;
  perform set_config('app.v79_system_transition', '', true);

  ------------------------------------------------------------------ 1 - the fixture is real
  select stamp_target into v_n from public.loyalty_programs where business_id = v_biz;
  insert into _r values('01_fixture_is_a_published_stamps_firm',
    case when v_n = 6
          and exists (select 1 from public.business_programmes
                       where business_id = v_biz and kind = 'stamps' and active)
          and exists (select 1 from public.businesses
                       where id = v_biz and active_config_version_id = v_a)
          and exists (select 1 from public.loyalty_reward_versions
                       where config_version_id = v_a and cost_points = 6 and active)
      then 'PASS a published 6-stamp card with a gift on stamp 6'
      else 'FAIL the fixture is not a published stamps firm (stamp_target=' ||
           coalesce(v_n::text, 'null') || ')' end);

  ------------------------------------------------------- 2 - WEDGE step 1: a half-finished edit
  -- Adding a gift on stamp 8 of a 6-stamp card is exactly the two-part edit nestly_v433 pends:
  -- it cannot publish until the card is long enough, so the split draft stays open.
  perform pg_temp.as_v675_user(v_owner);
  v_res := public.business_create_reward_v326(
    v_biz, v_spine, 'V675 Eighth Stamp Gift', 8, 0, null::text, null::text, null::timestamptz, null::text, null::integer);
  reset role;
  v_d := (v_res->>'target_version_id')::uuid;
  select status, based_on_version_id into v_status, v_base
    from public.firm_config_versions where id = v_d;
  insert into _r values('02_half_edit_pends_on_an_open_draft',
    case when v_res->>'publish_status' = 'pending'
          and v_status = 'draft' and v_base = v_a
          and (select source from public.firm_config_versions where id = v_d) = 'stamp_edit_split_v433'
      then 'PASS the edit pended on an open split draft based on the active version'
      else 'FAIL expected a pending split draft based on A; got publish_status=' ||
           coalesce(v_res->>'publish_status','null') || ' status=' || coalesce(v_status,'null') end);

  ---------------------------------------------------- 3 - WEDGE step 2: an unrelated publish
  -- The shape every other editor uses (the setup wizard's Go-live, the birthday editor, the
  -- retention and studio writers): clone the active version, publish the clone.
  perform pg_temp.as_v675_user(v_owner);
  v_json := public.create_loyalty_config_draft(v_biz, v_a, 'birthday_editor_v424');
  v_b := (v_json->>'version_id')::uuid;
  perform public.publish_loyalty_config(v_b);
  reset role;
  select status, based_on_version_id into v_status, v_base
    from public.firm_config_versions where id = v_d;
  insert into _r values('03_the_other_publish_leaves_the_draft_behind',
    case when (select active_config_version_id from public.businesses where id = v_biz) = v_b
          and v_status = 'draft' and v_base = v_a and v_base is distinct from v_b
      then 'PASS the pointer moved to B and the split draft is still open, still based on A'
      else 'FAIL the wedge was not reproduced (draft status=' || coalesce(v_status,'null') ||
           ', based_on=' || coalesce(v_base::text,'null') || ')' end);

  ------------------------------------------------------- 4 - the wedge, proven on the draft itself
  begin
    perform pg_temp.as_v675_user(v_owner);
    perform public.publish_loyalty_config(v_d);
    reset role;
    insert into _r values('04_stale_draft_is_unpublishable',
      'FAIL the stale draft published — the wedge this suite is built on no longer exists');
  exception when sqlstate '23514' then
    reset role;
    v_txt := sqlerrm;
    insert into _r values('04_stale_draft_is_unpublishable',
      case when position('stale_draft' in v_txt) > 0
        then 'PASS publishing the stale draft raises stale_draft (23514) — reusing it was fatal'
        else 'FAIL 23514 but not stale_draft: ' || v_txt end);
  end;

  ------------------------------------------------------------- 5 - THE FIX: the next edit works
  -- Pre-v675 this call went begin → the same stale draft D → commit → publish → stale_draft,
  -- and the owner's rename was rolled back. It must now land on a fresh draft and publish.
  perform pg_temp.as_v675_user(v_owner);
  v_res := public.business_update_reward_v326(
    v_biz, v_reward, 'V675 Sixth Stamp Gift Renamed', 6, null::text, 0, null::text, false);
  reset role;
  v_e := (v_res->>'target_version_id')::uuid;
  select status into v_status from public.firm_config_versions where id = v_d;
  select based_on_version_id into v_base from public.firm_config_versions where id = v_e;
  insert into _r values('05_the_edit_publishes_again',
    case when v_res->>'publish_status' = 'published'
          and v_e is distinct from v_d
          and v_base = v_b
          and (select active_config_version_id from public.businesses where id = v_biz) = v_e
      then 'PASS the edit opened a fresh draft based on B and published it'
      else 'FAIL publish_status=' || coalesce(v_res->>'publish_status','null') ||
           ', target=' || coalesce(v_e::text,'null') || ', based_on=' || coalesce(v_base::text,'null') end);
  insert into _r values('05b_stale_draft_is_retired',
    case when v_status = 'abandoned'
      then 'PASS the stale draft was abandoned, not handed back'
      else 'FAIL the stale draft is in status ' || coalesce(v_status, 'null') end);
  select count(*) into v_n from public.loyalty_rewards
   where id = v_reward and business_id = v_biz and name = 'V675 Sixth Stamp Gift Renamed';
  insert into _r values('05c_the_owners_change_survived',
    case when v_n = 1 then 'PASS the rename reached the live gift'
         else 'FAIL the rename did not survive the save' end);

  ------------------------------------------------------------------- 6 - it is on the record
  select count(*) into v_n from public.audit_log
   where business_id = v_biz and action = 'stamp_edit_draft.abandoned_stale' and entity_id = v_d;
  insert into _r values('06_abandonment_is_audited',
    case when v_n = 1 then 'PASS exactly one audit row names the dropped half-edit'
         else 'FAIL ' || v_n || ' audit row(s) for the abandoned draft' end);

  --------------------------------------------------- 7 - a CURRENT split draft is still reused
  -- nestly_v433's two-part edit must keep working: two pending edits in a row coalesce into ONE
  -- draft, and the second must not throw the first one's work away.
  perform pg_temp.as_v675_user(v_owner);
  v_res := public.business_create_reward_v326(
    v_biz, v_spine, 'V675 Ninth Stamp Gift', 9, 0, null::text, null::text, null::timestamptz, null::text, null::integer);
  v_f := (v_res->>'target_version_id')::uuid;
  v_res := public.business_create_reward_v326(
    v_biz, v_spine, 'V675 Tenth Stamp Gift', 10, 0, null::text, null::text, null::timestamptz, null::text, null::integer);
  reset role;
  select status into v_status from public.firm_config_versions where id = v_f;
  select count(*) into v_n from public.firm_config_versions
   where business_id = v_biz and status = 'draft' and source = 'stamp_edit_split_v433';
  insert into _r values('07_a_current_split_draft_is_reused',
    case when (v_res->>'target_version_id')::uuid = v_f
          and v_res->>'publish_status' = 'pending'
          and v_status = 'draft' and v_n = 1
      then 'PASS the second pending edit reused the same open draft'
      else 'FAIL the fresh split draft was not reused (drafts open=' || v_n ||
           ', status=' || coalesce(v_status,'null') || ')' end);
  select count(*) into v_n from public.loyalty_reward_versions
   where config_version_id = v_f and business_id = v_biz and cost_points in (9, 10) and active;
  insert into _r values('07b_both_halves_are_on_the_same_draft',
    case when v_n = 2 then 'PASS both pending gifts are staged on the one draft'
         else 'FAIL ' || v_n || ' of the 2 pending gifts survived on the draft' end);

  ------------------------------------------------------------- 8 - nothing left for the backfill
  select count(*) into v_n
    from public.firm_config_versions fcv
    join public.businesses b on b.id = fcv.business_id
   where fcv.business_id = v_biz
     and fcv.status = 'draft'
     and fcv.source = 'stamp_edit_split_v433'
     and b.active_config_version_id is not null
     and fcv.id is distinct from b.active_config_version_id
     and fcv.based_on_version_id is distinct from b.active_config_version_id;
  insert into _r values('08_no_stale_draft_remains',
    case when v_n = 0 then 'PASS the firm holds no stale split draft'
         else 'FAIL ' || v_n || ' stale split draft(s) remain' end);
end
$v675$;

reset role;
select k, v from _r order by k;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v675_gate$
declare
  v_bad integer;
begin
  select count(*) into v_bad from _r where v not like 'PASS%';
  if v_bad > 0 then
    raise exception 'SUITE FAILED: % assertion(s) — %', v_bad,
      (select string_agg(k, ', ') from _r where v not like 'PASS%');
  end if;
end
$v675_gate$;

rollback;
