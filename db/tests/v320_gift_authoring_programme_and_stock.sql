-- Rollback-only v320 acceptance: W6 WAVE 1, GIFT AUTHORING — programme choice + the stock column.
--
-- nestly_v320_gift_authoring_programme_and_stock makes a gift's programme an EXPLICIT AUTHOR
-- CHOICE instead of v313's default-trigger guess, adds the total_stock column that nothing reads
-- yet, closes the accruing-kind footgun that author-settable programme_id creates, and lands two
-- declared bug fixes (the draft-to-draft clone reading the LIVE programme instead of the source's;
-- the published-reward materialiser silently DROPPING the tier gate).
--
-- ENFORCEMENT IS NOT IN THIS MIGRATION AND IS NOT IN THIS SUITE. The derived stock counter, the
-- advisory-locked cap inside app.redeem_reward_core, the sold-out intent refusal, availability
-- 'sold_out' on the two customer readers and the owner's gifts board are WAVE 2's v324. Step 16
-- is the wave boundary, stated as an assertion: no reader consults total_stock yet. That cell is
-- SUPPOSED to go red when v324 lands, and v324's suite replaces it.
--
-- WHY EVERY SHAPE IS CONSTRUCTED HERE. Production holds two tenants with rewards (Cubbly, 7 on
-- the points spine; Hougang ABC, 7 on stamps), ZERO capped gifts, ZERO tier-gated rewards and NO
-- firm running two accruing programmes at once. A green run against production therefore proves
-- absence of regression, not presence of correctness. So the suite builds, inside the transaction:
--
--   G1  a firm with points AND stamps both switched on in the spine — the shape that makes
--       "which programme is this gift priced in?" a real question rather than a rhetorical one
--   G2  a second tenant, so the cross-tenant refusal has something to refuse
--
-- and drives every authoring path through the door the browser actually uses:
-- public.save_loyalty_config_draft (authenticated) -> public.save_loyalty_reward_draft. The
-- inner function is revoked from authenticated in production, so calling it directly would prove
-- something the browser can never do.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v320_gift_authoring_programme_and_stock.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.
--
-- RED-FIRST MUTANT MATRIX. Each mutation must turn the NAMED step red; a mutation that turns
-- nothing red means the step is decorative and has to be rewritten.
--
--   M1   drop 'programme_id','total_stock' from save_loyalty_reward_draft's whitelist   -> 1
--   M2   omit programme_id from the loyalty_reward_versions INSERT                      -> 2
--   M3   omit programme_id = excluded.programme_id from the ON CONFLICT list            -> 4
--   M4   omit total_stock = excluded.total_stock from the ON CONFLICT list              -> 6
--   M5   omit source.programme_id from app.clone_reward_versions_for_config             -> 8
--   M6   omit source.total_stock from the clone                                         -> 8
--   M7   remove the accruing-kind refusal from save_loyalty_reward_draft                -> 9
--   M8   remove the accruing-kind refusal from app.reward_programme_tenant_guard_v313   -> 10
--   M9   drop min_tier_id from ensure_published_reward_in_draft_v138                    -> 12
--   M10  drop programme_id / total_stock from ensure_published_reward_in_draft_v138     -> 12
--   M11  omit total_stock=rv.total_stock from publish_loyalty_config                    -> 3
--   M12  accept total_stock <= 0 in save_loyalty_reward_draft                           -> 11
--   M13  put the live-row lookup BEFORE v_existing.programme_id in the coalesce chain   -> 5
--   M14  restore `if not found then` and make the kind lookup a SELECT INTO             -> 1 (the
--        live loyalty_rewards row is never created and the version INSERT fails on its FK)
--   M15  fill programme_id from the v313 default instead of the payload                 -> 2
--   M16  let a legacy payload move programme_id                                         -> 13
--
-- STEP 15 IS THE BEHAVIOUR-NEUTRALITY CELL and it is the one that earns the migration's headline
-- claim: a payload that never mentions programme_id or total_stock lands on exactly the uuid
-- v313's default trigger would have chosen, with total_stock NULL.

begin;

create temp table v320_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v320_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v320_system() to public;

-- The real browser identity: role `authenticated` plus a jwt sub that auth.uid() resolves to.
-- public.save_loyalty_config_draft, create_loyalty_config_draft, publish_loyalty_config and
-- ensure_published_reward_in_draft_v138 are all EXECUTE-able by authenticated in production, so
-- this is the identity every authoring step below runs as.
create or replace function pg_temp.as_v320_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v320_user(uuid,text) to public;

create or replace function pg_temp.v320_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v320_spine(uuid,text) to public;

-- A published, loyalty-enabled, owner-operated tenant. Identical in shape to the v313/v314 suite's
-- fixture, which is deliberate: the two suites must be describing the same product.
create or replace function pg_temp.v320_tenant(
  p_business uuid, p_owner uuid, p_label text, p_stamp_per_cents integer
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(replace(p_label,' ','-'))||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v320 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V320 Owner',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents,current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits',
          'none',null,1.0,10,p_stamp_per_cents,v_config);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,'points','points_tiers',true,1.0,100,500,10,
          p_stamp_per_cents,'visits','none',null);

  return v_config;
end
$$;
grant execute on function pg_temp.v320_tenant(uuid,uuid,text,integer) to public;

-- A bare draft whose based_on_version_id is NULL, so app.clone_reward_versions_for_config returns
-- early and the draft starts with NO reward versions. That is the only way to give
-- ensure_published_reward_in_draft_v138 something to do.
create or replace function pg_temp.v320_bare_draft(p_business uuid) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_no integer;
begin
  select coalesce(max(version_no),0)+1 into v_no
    from public.firm_config_versions where business_id = p_business;
  insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash)
  values (v_id,p_business,v_no,'draft','v320-bare-draft');
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  select p_business,v_id,kind,loyalty_model,active,earn_points_per_dollar,redeem_points,
         reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
    from public.loyalty_program_versions
   where config_version_id = (select active_config_version_id from public.businesses
                               where id = p_business);
  return v_id;
end
$$;
grant execute on function pg_temp.v320_bare_draft(uuid) to public;

-- The versioned reward row for one gift inside one config version, found by its internal name.
create or replace function pg_temp.v320_rv(p_config uuid, p_name text)
returns public.loyalty_reward_versions language sql stable as $$
  select rv.* from public.loyalty_reward_versions rv
   where rv.config_version_id = p_config and rv.internal_name = p_name
$$;
grant execute on function pg_temp.v320_rv(uuid,text) to public;

create or replace function pg_temp.v320_reward_id(p_config uuid, p_name text) returns uuid
language sql stable as $$
  select rv.reward_id from public.loyalty_reward_versions rv
   where rv.config_version_id = p_config and rv.internal_name = p_name
$$;
grant execute on function pg_temp.v320_reward_id(uuid,text) to public;

-- One gift payload, in the exact envelope the browser sends.
create or replace function pg_temp.v320_gift(p_name text, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object('reward', jsonb_build_object(
    'internal_name', p_name,
    'customer_name', p_name,
    'fulfillment_kind', 'manual_item',
    'cost_points', 100,
    'credit_cents', 0,
    'estimated_cost_cents', 0,
    'active', true,
    'sort', 0
  ) || p_extra)
$$;
grant execute on function pg_temp.v320_gift(text,jsonb) to public;

create or replace function pg_temp.v320_body(p_schema text, p_name text) returns text
language sql stable as $$
  select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = p_schema and p.proname = p_name
$$;
grant execute on function pg_temp.v320_body(text,text) to public;

create or replace function pg_temp.v320_occ(p_hay text, p_needle text) returns integer
language sql immutable as $$
  select ((length(coalesce(p_hay,'')) - length(replace(coalesce(p_hay,''), p_needle, '')))
          / length(p_needle))::integer
$$;
grant execute on function pg_temp.v320_occ(text,text) to public;

do $v320_test$
declare
  v_owner uuid := gen_random_uuid();
  g1 uuid := gen_random_uuid(); g1cfg uuid;
  g2 uuid := gen_random_uuid(); g2cfg uuid;
  v_points uuid; v_stamps uuid; v_tiers uuid; v_referral uuid; v_other_points uuid;
  d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; d6 uuid;
  v_gift uuid; v_gated uuid; v_legacy uuid;
  v_rv public.loyalty_reward_versions%rowtype;
  v_live public.loyalty_rewards%rowtype;
  v_res json;
  v_msg text; v_state text;
  v_msg2 text; v_state2 text;
  v_hash_before text; v_hash_after text;
  v_src text;
  v_bad bigint; v_divergent bigint;
  v_default uuid;
begin
  perform pg_temp.as_v320_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v320-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  g1cfg := pg_temp.v320_tenant(g1,v_owner,'V320 Both',1000);
  g2cfg := pg_temp.v320_tenant(g2,v_owner,'V320 Other',1000);

  -- THE SHAPE THIS WHOLE WAVE EXISTS FOR: one firm, two accruing programmes, both on. Thrown
  -- through the ONE spine writer, exactly as an owner would.
  perform pg_temp.as_v320_user(v_owner);
  perform public.set_programmes_v314(g1, '{"points":true,"stamps":true}'::jsonb, gen_random_uuid());
  perform pg_temp.as_v320_system();

  v_points   := pg_temp.v320_spine(g1,'points');
  v_stamps   := pg_temp.v320_spine(g1,'stamps');
  v_tiers    := pg_temp.v320_spine(g1,'tiers');
  v_referral := pg_temp.v320_spine(g1,'referral');
  v_other_points := pg_temp.v320_spine(g2,'points');
  v_default  := app.reward_default_programme_v313(g1);

  -- =========================================================================
  -- STEP 1. A STAMP GIFT CAN BE AUTHORED AT ALL. Before v320 the whitelist held zero occurrences
  --   of programme_id, so this exact call died with 22023 'reward contains unsupported fields'.
  --   It is simultaneously the FOUND-hazard regression cell: creating a gift from nothing must
  --   write BOTH the live public.loyalty_rewards row and the versioned row. Restore
  --   `if not found then` with a SELECT INTO ahead of it (M14) and the live row is never created,
  --   so the version INSERT dies on its FK.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_res := public.create_loyalty_config_draft(g1, null, 'v320 suite');
    d1 := (v_res->>'version_id')::uuid;
    perform public.save_loyalty_config_draft(d1,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('programme_id', v_stamps::text, 'total_stock', '20')), null);
    perform pg_temp.as_v320_system();
    v_gift := pg_temp.v320_reward_id(d1,'V320 Stamp Gift');
    v_rv := pg_temp.v320_rv(d1,'V320 Stamp Gift');
    select * into v_live from public.loyalty_rewards where id = v_gift;
    insert into v320_out values (1,'a stamp gift can be authored with an explicit programme_id',
      case when v_gift is null then 'FAIL: no reward version was written'
           when v_live.id is null then 'FAIL: the live loyalty_rewards row was never created (the FOUND hazard)'
           when v_rv.programme_id <> v_stamps then 'FAIL: the version row is not on the stamps programme'
           when v_live.programme_id <> v_stamps then 'FAIL: the live row is not on the stamps programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (1,'a stamp gift can be authored with an explicit programme_id',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 2. THE AUTHOR'S CHOICE, NOT THE DEFAULT'S GUESS. G1 runs two accruing programmes, so
  --   app.reward_default_programme_v313 falls back to POINTS. The gift above is on STAMPS. If the
  --   version INSERT drops programme_id (M2) or fills it from the default (M15), this is where it
  --   shows: the two uuids are different by construction.
  -- =========================================================================
  begin
    v_rv := pg_temp.v320_rv(d1,'V320 Stamp Gift');
    insert into v320_out values (2,'the authored programme beats the v313 default at a two-programme firm',
      case when v_default <> v_points
             then 'FAIL: fixture broken — the v313 default is not points at a two-accruing firm'
           when v_rv.programme_id = v_default
             then 'FAIL: the gift landed on the DEFAULT programme, not the authored one'
           when v_rv.programme_id <> v_stamps then 'FAIL: the gift is on neither'
           when v_rv.total_stock is distinct from 20 then 'FAIL: total_stock did not reach the version row'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (2,'the authored programme beats the v313 default at a two-programme firm',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 3. PUBLISH PROJECTS BOTH COLUMNS ONTO THE LIVE ROW. programme_id has been projected
  --   since v313; total_stock is v320's one line in that UPDATE (M11).
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    perform public.publish_loyalty_config(d1);
    perform pg_temp.as_v320_system();
    select * into v_live from public.loyalty_rewards where id = v_gift;
    insert into v320_out values (3,'publish projects programme_id AND total_stock onto the live row',
      case when v_live.programme_id <> v_stamps then 'FAIL: the live programme is not stamps'
           when v_live.total_stock is distinct from 20
             then 'FAIL: publish did not project total_stock (live='||coalesce(v_live.total_stock::text,'null')||')'
           when v_live.active is not true then 'FAIL: publish did not activate the gift'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (3,'publish projects programme_id AND total_stock onto the live row',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 4. AN EDIT CAN MOVE A GIFT BETWEEN PROGRAMMES. This is the ON CONFLICT DO UPDATE entry
  --   the contract calls the silent failure mode (M3): without it the insert conflicts, the DO
  --   UPDATE preserves the old value, and an owner's reassignment is swallowed with a success
  --   response.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_res := public.create_loyalty_config_draft(g1, null, 'v320 suite');
    d2 := (v_res->>'version_id')::uuid;
    perform public.save_loyalty_config_draft(d2,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('id', v_gift::text, 'programme_id', v_points::text)), null);
    perform pg_temp.as_v320_system();
    v_rv := pg_temp.v320_rv(d2,'V320 Stamp Gift');
    insert into v320_out values (4,'an edit MOVES a gift to another programme (ON CONFLICT DO UPDATE)',
      case when v_rv.reward_id is null then 'FAIL: the draft row vanished'
           when v_rv.programme_id <> v_points
             then 'FAIL: the reassignment was swallowed; the gift is still on stamps'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (4,'an edit MOVES a gift to another programme (ON CONFLICT DO UPDATE)',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 5. AN EDIT THAT DOES NOT MENTION THE PROGRAMME NEVER MOVES IT. The draft row (points,
  --   from step 4) must win over the LIVE row (stamps, from step 3). Reorder the coalesce chain
  --   so the live lookup comes first (M13) and this step reports stamps.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    perform public.save_loyalty_config_draft(d2,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('id', v_gift::text, 'cost_points', 150)), null);
    perform pg_temp.as_v320_system();
    v_rv := pg_temp.v320_rv(d2,'V320 Stamp Gift');
    select * into v_live from public.loyalty_rewards where id = v_gift;
    insert into v320_out values (5,'an edit that omits programme_id leaves the DRAFT value alone',
      case when v_rv.cost_points <> 150 then 'FAIL: the edit did not land at all'
           when v_live.programme_id <> v_stamps
             then 'FAIL: fixture broken — the live row is no longer the stamps one'
           when v_rv.programme_id = v_stamps
             then 'FAIL: the omitting edit re-read the LIVE programme and reverted the draft'
           when v_rv.programme_id <> v_points then 'FAIL: the draft programme moved to neither'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (5,'an edit that omits programme_id leaves the DRAFT value alone',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 6. total_stock follows the same rule, in all three directions: an omitting edit keeps
  --   it, an explicit value changes it, an explicit empty string clears it back to unlimited.
  --   Drop total_stock = excluded.total_stock (M4) and the middle case fails.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_rv := pg_temp.v320_rv(d2,'V320 Stamp Gift');
    if v_rv.total_stock is distinct from 20 then
      raise exception 'the omitting edits of steps 4-5 did not carry total_stock forward (got %)',
        coalesce(v_rv.total_stock::text,'null');
    end if;
    perform public.save_loyalty_config_draft(d2,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('id', v_gift::text, 'total_stock', '5')), null);
    v_rv := pg_temp.v320_rv(d2,'V320 Stamp Gift');
    if v_rv.total_stock is distinct from 5 then
      raise exception 'an explicit total_stock edit did not land (got %)',
        coalesce(v_rv.total_stock::text,'null');
    end if;
    perform public.save_loyalty_config_draft(d2,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('id', v_gift::text, 'total_stock', '')), null);
    v_rv := pg_temp.v320_rv(d2,'V320 Stamp Gift');
    perform pg_temp.as_v320_system();
    insert into v320_out values (6,'total_stock: an omitting edit keeps it, an explicit one moves it, an empty one clears it',
      case when v_rv.total_stock is not null
             then 'FAIL: an explicit empty total_stock did not clear the cap'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (6,'total_stock: an omitting edit keeps it, an explicit one moves it, an empty one clears it',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 7. The draft-to-draft clone carries the gift at all. Fixture step for 8: d2 currently
  --   holds the gift on POINTS with total_stock NULL; put a cap back on it and leave d2 UNpublished
  --   so the live row (stamps / 20) and the source (points / 7) genuinely disagree.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    perform public.save_loyalty_config_draft(d2,
      pg_temp.v320_gift('V320 Stamp Gift',
        jsonb_build_object('id', v_gift::text, 'total_stock', '7')), null);
    v_res := public.create_loyalty_config_draft(g1, d2, 'v320 suite clone');
    d3 := (v_res->>'version_id')::uuid;
    perform pg_temp.as_v320_system();
    v_rv := pg_temp.v320_rv(d3,'V320 Stamp Gift');
    insert into v320_out values (7,'a draft-to-draft clone reproduces the gift',
      case when v_rv.reward_id is null then 'FAIL: the clone produced no reward version'
           when v_rv.cost_points <> 150 then 'FAIL: the clone did not copy the source row'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (7,'a draft-to-draft clone reproduces the gift',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 8. DECLARED BUG FIX (a): THE CLONE READS THE SOURCE, NOT THE LIVE ROW. d2 (the source)
  --   says points / 7. The live row still says stamps / 20 because d2 was never published. Before
  --   v320 the clone omitted programme_id entirely and v313's default trigger re-read the LIVE row
  --   — so an owner's reassignment silently reverted the moment they opened a new draft.
  -- =========================================================================
  begin
    v_rv := pg_temp.v320_rv(d3,'V320 Stamp Gift');
    select * into v_live from public.loyalty_rewards where id = v_gift;
    insert into v320_out values (8,'the clone carries the SOURCE programme and cap, not the live row''s',
      case when v_live.programme_id <> v_stamps or v_live.total_stock is distinct from 20
             then 'FAIL: fixture broken — the live row is not the disagreeing one'
           when v_rv.programme_id = v_stamps
             then 'FAIL: the clone re-read the LIVE programme (this is the bug v320 fixes)'
           when v_rv.programme_id <> v_points then 'FAIL: the clone carried neither programme'
           when v_rv.total_stock is distinct from 7
             then 'FAIL: the clone dropped total_stock (got '||coalesce(v_rv.total_stock::text,'null')||')'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (8,'the clone carries the SOURCE programme and cap, not the live row''s',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 9. A GIFT MAY NOT BE TAGGED TO A PROGRAMME NOBODY EARNS INTO. points_batches never holds
  --   a row for tiers or referral, so such a gift is permanently unclaimable — the customer sees
  --   it, saves for it and is refused forever. The RPC refuses first, with a message an owner can
  --   read; the trigger (step 10) is the floor under it.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    begin
      perform public.save_loyalty_config_draft(d3,
        pg_temp.v320_gift('V320 Tiers Gift',
          jsonb_build_object('programme_id', v_tiers::text)), null);
      perform pg_temp.as_v320_system();
      insert into v320_out values (9,'a gift tagged to a NON-ACCRUING programme is refused by the RPC',
        'FAIL: a tiers-tagged gift was accepted');
    exception when sqlstate '22023' then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v320_system();
      insert into v320_out values (9,'a gift tagged to a NON-ACCRUING programme is refused by the RPC',
        case when v_msg <> 'a gift may only belong to a programme customers earn into'
               then 'FAIL: refused, but with the wrong message: '||v_msg
             when exists (select 1 from public.loyalty_reward_versions
                           where config_version_id = d3 and internal_name = 'V320 Tiers Gift')
               then 'FAIL: refused but the row survived'
             else 'PASS' end);
    end;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (9,'a gift tagged to a NON-ACCRUING programme is refused by the RPC',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 10. THE FLOOR. Same refusal from app.reward_programme_tenant_guard_v313, reached by a
  --   direct UPDATE that never goes near the RPC — and v313's CROSS-TENANT refusal preserved
  --   byte-for-byte in message and errcode beside it.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_system();
    if not exists (select 1 from public.loyalty_reward_versions
                    where config_version_id = d3 and internal_name = 'V320 Stamp Gift') then
      raise exception 'fixture broken: draft d3 does not hold the gift this step must retag';
    end if;
    v_msg := '<accepted>'; v_state := '00000';
    begin
      update public.loyalty_reward_versions set programme_id = v_referral
       where config_version_id = d3 and internal_name = 'V320 Stamp Gift';
    exception when others then
      get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    end;
    v_msg2 := '<accepted>'; v_state2 := '00000';
    begin
      update public.loyalty_reward_versions set programme_id = v_other_points
       where config_version_id = d3 and internal_name = 'V320 Stamp Gift';
    exception when others then
      get stacked diagnostics v_msg2 = message_text, v_state2 = returned_sqlstate;
    end;
    insert into v320_out values (10,'the trigger refuses a non-accruing programme AND still refuses another tenant''s',
      case when v_state <> '22023'
             then 'FAIL: the non-accruing refusal used sqlstate '||v_state||' ('||v_msg||')'
           when v_msg <> 'a gift may only belong to a programme customers earn into'
             then 'FAIL: non-accruing message drifted: '||v_msg
           when v_state2 <> '42501'
             then 'FAIL: the cross-tenant refusal used sqlstate '||v_state2||' ('||v_msg2||')'
           when v_msg2 <> 'reward is tagged with another tenant''s programme'
             then 'FAIL: v313''s cross-tenant message drifted: '||v_msg2
           when (select programme_id from public.loyalty_reward_versions
                  where config_version_id = d3 and internal_name = 'V320 Stamp Gift') <> v_points
             then 'FAIL: a refused retag still moved the row'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (10,'the trigger refuses a non-accruing programme AND still refuses another tenant''s',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 11. A cap must be a positive whole number, refused in the RPC with a message an owner
  --   can act on AND at the table by a named CHECK. Two doors, because the client is not the only
  --   writer.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_msg := '<accepted>'; v_state := '00000';
    begin
      perform public.save_loyalty_config_draft(d3,
        pg_temp.v320_gift('V320 Zero Cap', jsonb_build_object('total_stock', '0')), null);
    exception when others then
      get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    end;
    perform pg_temp.as_v320_system();
    v_msg2 := '<accepted>'; v_state2 := '00000';
    begin
      update public.loyalty_reward_versions set total_stock = 0
       where config_version_id = d3 and internal_name = 'V320 Stamp Gift';
    exception when others then
      get stacked diagnostics v_msg2 = message_text, v_state2 = returned_sqlstate;
    end;
    insert into v320_out values (11,'a non-positive cap is refused by the RPC and by the CHECK',
      case when v_state <> '22023'
             then 'FAIL: the RPC accepted or mis-refused total_stock=0 (sqlstate '||coalesce(v_state,'none')||')'
           when v_msg <> 'total available must be a positive whole number'
             then 'FAIL: RPC message drifted: '||v_msg
           when v_state2 <> '23514'
             then 'FAIL: the table CHECK did not refuse a direct total_stock=0 (sqlstate '||coalesce(v_state2,'none')||')'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (11,'a non-positive cap is refused by the RPC and by the CHECK',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 12. DECLARED BUG FIX (b): MATERIALISING A PUBLISHED REWARD KEPT ITS TIER GATE. The v138
  --   INSERT listed 20 columns and omitted min_tier_id / min_tier_threshold, so opening a premium
  --   reward for editing silently opened it to everyone on the next publish. v320 adds those two
  --   plus programme_id and total_stock. All four are asserted here (M9, M10).
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_res := public.create_loyalty_config_draft(g1, null, 'v320 gated');
    d4 := (v_res->>'version_id')::uuid;
    perform public.save_loyalty_config_draft(d4,
      pg_temp.v320_gift('V320 Gated Gift', jsonb_build_object(
        'programme_id', v_stamps::text, 'total_stock', '4',
        'min_tier_id', gen_random_uuid()::text, 'min_tier_threshold', '3')), null);
    perform public.publish_loyalty_config(d4);
    perform pg_temp.as_v320_system();
    v_gated := pg_temp.v320_reward_id(d4,'V320 Gated Gift');
    d5 := pg_temp.v320_bare_draft(g1);
    perform pg_temp.as_v320_user(v_owner);
    perform public.ensure_published_reward_in_draft_v138(d5, v_gated, null);
    perform pg_temp.as_v320_system();
    v_rv := pg_temp.v320_rv(d5,'V320 Gated Gift');
    insert into v320_out values (12,'materialising a published reward keeps its tier gate, its programme and its cap',
      case when v_rv.reward_id is null then 'FAIL: nothing was materialised'
           when v_rv.min_tier_id is null
             then 'FAIL: THE TIER GATE WAS DROPPED — the premium reward is now open to everyone'
           when v_rv.min_tier_threshold is distinct from 3 then 'FAIL: min_tier_threshold was dropped'
           when v_rv.programme_id <> v_stamps
             then 'FAIL: the materialised copy is on the wrong programme'
           when v_rv.total_stock is distinct from 4 then 'FAIL: total_stock was dropped'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (12,'materialising a published reward keeps its tier gate, its programme and its cap',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 13. THE SNAPSHOT-HASH SELF-HEAL. v320 deliberately refreshes NO snapshot, so every open
  --   draft keeps a hash computed before total_stock existed. That is only safe because the
  --   optimistic check reads the STORED value BEFORE any write and the refresh happens after. A
  --   client holding the pre-migration hash must therefore succeed exactly once and then hold a
  --   new one. Modelled by stamping a known-stale hash on the draft.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_system();
    d6 := pg_temp.v320_bare_draft(g1);
    update public.firm_config_versions set snapshot_hash = 'v320-pre-migration-hash' where id = d6;
    v_hash_before := (select snapshot_hash from public.firm_config_versions where id = d6);
    perform pg_temp.as_v320_user(v_owner);
    perform public.ensure_published_reward_in_draft_v138(d6, v_gated, 'v320-pre-migration-hash');
    perform pg_temp.as_v320_system();
    v_hash_after := (select snapshot_hash from public.firm_config_versions where id = d6);
    insert into v320_out values (13,'a client holding the pre-migration snapshot hash saves once and self-heals',
      case when v_hash_before <> 'v320-pre-migration-hash' then 'FAIL: fixture broken'
           when v_hash_after = v_hash_before
             then 'FAIL: the write did not refresh the hash, so the heal never happens'
           when not exists (select 1 from public.loyalty_reward_versions
                             where config_version_id = d6 and reward_id = v_gated)
             then 'FAIL: the save did not land'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (13,'a client holding the pre-migration snapshot hash saves once and self-heals',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 14. Another tenant's programme is still 42501 through the RPC, with the message v313
  --   wrote. The FK references business_programmes(id) alone, so a cross-tenant tag is a legal
  --   row and only this refusal stands between it and a pot drained in the wrong firm's namespace.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    v_msg := '<accepted>'; v_state := '00000';
    begin
      perform public.save_loyalty_config_draft(d3,
        pg_temp.v320_gift('V320 Foreign Gift',
          jsonb_build_object('programme_id', v_other_points::text)), null);
    exception when others then
      get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    end;
    perform pg_temp.as_v320_system();
    insert into v320_out values (14,'a gift tagged with another tenant''s programme is still 42501',
      case when v_state <> '42501'
             then 'FAIL: cross-tenant tagging returned sqlstate '||coalesce(v_state,'none')
           when v_msg <> 'reward programme does not belong to this business'
             then 'FAIL: message drifted: '||v_msg
           when exists (select 1 from public.loyalty_reward_versions
                         where config_version_id = d3 and internal_name = 'V320 Foreign Gift')
             then 'FAIL: refused but the row survived'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (14,'a gift tagged with another tenant''s programme is still 42501',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 15. THE BEHAVIOUR-NEUTRALITY CELL. A payload that mentions NEITHER new field — every
  --   payload the shipped, CDN-pinned client sends — must land on exactly the uuid v313's default
  --   trigger would have chosen, with total_stock NULL. This is the whole basis of the claim that
  --   v320 changes no existing behaviour, and it is the cell M16 breaks.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_user(v_owner);
    perform public.save_loyalty_config_draft(d3, pg_temp.v320_gift('V320 Legacy Gift'), null);
    perform pg_temp.as_v320_system();
    v_legacy := pg_temp.v320_reward_id(d3,'V320 Legacy Gift');
    v_rv := pg_temp.v320_rv(d3,'V320 Legacy Gift');
    select * into v_live from public.loyalty_rewards where id = v_legacy;
    perform pg_temp.as_v320_user(v_owner);
    v_msg := '<accepted>'; v_state := '00000';
    begin
      perform public.save_loyalty_config_draft(d3,
        pg_temp.v320_gift('V320 Bad Field', jsonb_build_object('not_a_field','x')), null);
    exception when others then
      get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    end;
    perform pg_temp.as_v320_system();
    insert into v320_out values (15,'a legacy payload lands exactly where v313''s default put it, uncapped',
      case when v_rv.reward_id is null then 'FAIL: the legacy payload did not author anything'
           when v_rv.programme_id <> app.reward_default_programme_v313(g1)
             then 'FAIL: a legacy payload no longer reproduces the v313 default'
           when v_rv.total_stock is not null then 'FAIL: a legacy payload invented a cap'
           when v_live.total_stock is not null then 'FAIL: the live row invented a cap'
           when v_live.programme_id <> app.reward_default_programme_v313(g1)
             then 'FAIL: the live row disagrees with the v313 default'
           when v_state <> '22023' or v_msg <> 'reward contains unsupported fields'
             then 'FAIL: the whitelist stopped refusing unknown fields ('||coalesce(v_state,'none')||')'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (15,'a legacy payload lands exactly where v313''s default put it, uncapped',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 16. THE WAVE BOUNDARY, STATED AS AN ASSERTION. Nothing reads total_stock. The counter,
  --   the cap inside app.redeem_reward_core, the sold-out intent refusal and the two customer
  --   readers are v324's. THIS CELL IS SUPPOSED TO GO RED WHEN v324 LANDS — that is the signal
  --   that enforcement arrived, and v324's own suite replaces it. It must not be "fixed" by
  --   deleting it.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_system();
    insert into v320_out values (16,'WAVE BOUNDARY: no reader consults total_stock yet (goes red on purpose at v324)',
      case when pg_temp.v320_body('app','redeem_reward_core') is null
             or pg_temp.v320_body('public','customer_create_redemption_intent_v89') is null
             or pg_temp.v320_body('public','customer_get_reward_catalog') is null
             or pg_temp.v320_body('public','customer_get_business_actions_v89') is null
             or pg_temp.v320_body('app','c45_base_actionable_wallet_card') is null
             then 'FAIL: one of the five v324 targets no longer exists under that name'
           when pg_temp.v320_occ(pg_temp.v320_body('app','redeem_reward_core'),'total_stock') <> 0
             then 'FAIL: app.redeem_reward_core reads total_stock — enforcement leaked into wave 1'
           when pg_temp.v320_occ(pg_temp.v320_body('public','customer_create_redemption_intent_v89'),'total_stock') <> 0
             then 'FAIL: the intent path reads total_stock'
           when pg_temp.v320_occ(pg_temp.v320_body('public','customer_get_reward_catalog'),'total_stock') <> 0
             then 'FAIL: the customer catalogue reads total_stock'
           when pg_temp.v320_occ(pg_temp.v320_body('public','customer_get_business_actions_v89'),'total_stock') <> 0
             then 'FAIL: the customer actions reader reads total_stock'
           when pg_temp.v320_occ(pg_temp.v320_body('app','c45_base_actionable_wallet_card'),'total_stock') <> 0
             then 'FAIL: the wallet card reads total_stock'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (16,'WAVE BOUNDARY: no reader consults total_stock yet (goes red on purpose at v324)',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 17. THE POST-STATE PINS. Every contracted edit is present exactly once, in the exact
  --   shape the migration's postconditions asserted. A later wave that re-splices one of these
  --   bodies and drops an edit goes red here rather than in production.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_system();
    v_src := pg_temp.v320_body('public','save_loyalty_reward_draft');
    insert into v320_out values (17,'the five re-stated bodies carry every contracted edit exactly once',
      case when pg_temp.v320_occ(v_src, $q$'programme_id','total_stock'$q$) <> 1
             then 'FAIL: the whitelist entry is not present exactly once'
           when pg_temp.v320_occ(v_src, 'programme_id = excluded.programme_id') <> 1
             then 'FAIL: the ON CONFLICT programme entry is missing'
           when pg_temp.v320_occ(v_src, 'total_stock = excluded.total_stock') <> 1
             then 'FAIL: the ON CONFLICT cap entry is missing'
           when pg_temp.v320_occ(v_src, 'v_is_new := not found;') <> 1
             then 'FAIL: the FOUND capture is missing'
           when position('if not found then' in v_src) <> 0
             then 'FAIL: the live-row branch still depends on FOUND'
           when pg_temp.v320_occ(pg_temp.v320_body('app','clone_reward_versions_for_config'),'source.programme_id') <> 1
             then 'FAIL: the clone no longer reads the source programme'
           when pg_temp.v320_occ(pg_temp.v320_body('app','clone_reward_versions_for_config'),'source.total_stock') <> 1
             then 'FAIL: the clone no longer carries the cap'
           when pg_temp.v320_occ(pg_temp.v320_body('public','ensure_published_reward_in_draft_v138'),'v_source.min_tier_id') <> 1
             then 'FAIL: the materialiser dropped the tier gate again'
           when pg_temp.v320_occ(pg_temp.v320_body('public','publish_loyalty_config'),'total_stock=rv.total_stock') <> 1
             then 'FAIL: the publish projection lost total_stock'
           when pg_temp.v320_occ(pg_temp.v320_body('public','publish_loyalty_config'),'programme_id=rv.programme_id') <> 1
             then 'FAIL: the publish projection lost v313''s programme'
           when pg_temp.v320_occ(pg_temp.v320_body('app','reward_programme_tenant_guard_v313'),
                                 'a gift may only belong to a programme customers earn into') <> 1
             then 'FAIL: the guard lost its accruing-kind refusal'
           when pg_temp.v320_occ(pg_temp.v320_body('app','reward_programme_tenant_guard_v313'),
                                 'reward is tagged with another tenant''s programme') <> 1
             then 'FAIL: the guard lost v313''s cross-tenant refusal'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (17,'the five re-stated bodies carry every contracted edit exactly once',
      'FAIL: '||v_state||' '||v_msg);
  end;

  -- =========================================================================
  -- STEP 18. The standing detectors, and the one that is a REPORT rather than an assertion
  --   (ruling R-H). app.detect_spine_legacy_divergence_v314 is NON-EMPTY in production right now
  --   because a real owner switched tiers on — that is the product working. Read it, print it,
  --   never assert it.
  -- =========================================================================
  begin
    perform pg_temp.as_v320_system();
    select count(*) into v_divergent from app.detect_spine_legacy_divergence_v314();
    select count(*) into v_bad from (
      select 1 from public.loyalty_rewards r
        join public.business_programmes s on s.id = r.programme_id
       where s.kind not in ('points','stamps')
      union all
      select 1 from public.loyalty_reward_versions rv
        join public.business_programmes s on s.id = rv.programme_id
       where s.kind not in ('points','stamps')
      union all
      select 1 from app.detect_programme_pot_split_v312()
      union all
      select 1 from app.detect_double_earn_v309()
    ) x;
    insert into v320_out values (18,
      'detectors empty; spine/legacy divergence REPORTED ('||v_divergent||' row(s)), never asserted',
      case when v_bad <> 0
             then 'FAIL: '||v_bad||' detector/non-accruing row(s) after the whole suite'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    perform pg_temp.as_v320_system();
    insert into v320_out values (18,'detectors empty; spine/legacy divergence REPORTED, never asserted',
      'FAIL: '||v_state||' '||v_msg);
  end;

  perform pg_temp.as_v320_system();
end
$v320_test$;

select seq, step, outcome from v320_out order by seq;

rollback;
