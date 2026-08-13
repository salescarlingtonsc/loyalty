-- Rollback-only v308 acceptance: the W2 programme SPINE is a projection of the W1 read model that no
-- browser role can write and that the sync keeps exact.
--
-- public.business_programmes is DERIVED. Legacy columns (loyalty_programs.active/.loyalty_model,
-- businesses.points_mode, the presence of loyalty_tiers rows, referral_programs.enabled) stay
-- authoritative until a later wave flips readers onto the spine, so the only things worth proving in
-- this wave are that the projection is exact, that every legacy surface that can move a flag is
-- watched, that the breadcrumbs only move when something really moved, and that no tenant session
-- can touch the table. Seven jobs.
--
--   1. SHAPE (step 1). Creating a business — through the AFTER INSERT trigger, not through a seed —
--      yields exactly four rows, all four kinds, correct sort ranks, all inactive, both breadcrumbs
--      null. Four-rows-always is what makes every later comparison a row-for-row column check.
--
--   2. EVERY TRIGGER EVENT, IN ISOLATION (steps 2-4 and 8-14). Each of the four watched tables is
--      mutated by ONE statement whose effect is then asserted, so no trigger can be silently
--      redundant. This matters: an earlier draft of this suite inserted the tier rows and changed
--      points_mode in the same step, and dropping the loyalty_tiers trigger altogether left the whole
--      suite GREEN — the businesses trigger was recomputing on the next line and covering for it. The
--      isolation below is the fix, and the red-first mutation set (drop any one trigger; delete the
--      `is distinct from` guard on the upsert; grant a browser role write privileges) turns a named
--      step red for each. Every step also asserts, through one comparison helper, that the spine
--      equals app.business_programmes_v307 — the W1 contract — for that business. A step that only
--      asserted expected flags would pass while spine and read model drifted together.
--        step 2  loyalty_programs INSERT            step 10 referral_programs INSERT
--        step 3  businesses UPDATE OF points_mode,  step 11 referral_programs UPDATE OF enabled,
--                then loyalty_tiers INSERT                  then referral_programs DELETE
--        step 4  loyalty_tiers DELETE               step 12 loyalty_programs UPDATE (active)
--        step 8  loyalty_tiers UPDATE OF business_id  step 14 loyalty_programs DELETE
--                across TWO tenants (the OLD/NEW dual-sync branch)
--        step 9  loyalty_programs UPDATE (model)
--
--   3. THE SYNC WORKS FROM A TENANT SESSION (step 5). Every other step writes the legacy tables from
--      the system context. businesses.points_mode is the one watched column a firm owner edits
--      DIRECTLY over PostgREST, so one step makes that write under `set local role authenticated`
--      with the owner's JWT and asserts both convergence and read-model parity. This is the case the
--      SECURITY DEFINER sync exists for: the W1 read model is SECURITY INVOKER, so an invoker sync
--      would compute the four flags through the caller's RLS.
--
--   4. THE DEFERRED TIERS SYNC (steps 6-7). v308 attaches the loyalty_tiers sync as a CONSTRAINT
--      TRIGGER, DEFERRABLE INITIALLY DEFERRED, because publish_loyalty_config (v55:713-714)
--      republishes the ladder by deleting every rung and re-inserting it — which an immediate trigger
--      reads as a real pause followed by a real activation, rewriting both breadcrumbs on a publish
--      that changed nothing. Step 6 reproduces that storm (delete all rungs, reinsert them under
--      their own ids) and asserts the spine row is not rewritten AT ALL: same active, same
--      activated_at, same deactivated_at, same ctid. Step 7 is the counterweight — rungs deleted and
--      NOT restored still lower the flag and still stamp deactivated_at, so the deferral did not turn
--      the breadcrumb into a no-op. Because the trigger is deferred and this suite never commits,
--      every step that mutates loyalty_tiers runs the queue itself through pg_temp.v308_flush_tiers().
--
--   5. BREADCRUMBS (step 13). activated_at is stamped when active flips false->true, deactivated_at
--      when it flips true->false, neither is ever cleared (the points row ends carrying both), and a
--      legacy UPDATE that leaves `active` unchanged writes NOTHING. "Writes nothing" is asserted on
--      ctid, not on the timestamp values: now() is transaction time, so a re-stamp inside this one
--      transaction would be invisible by value and perfectly visible as a new heap tuple.
--
--   6. NO BROWSER ROLE CAN WRITE THE TABLE (steps 15-17). An unrelated authenticated user sees zero
--      rows, a staff member of the fixture business sees its four, and an authenticated session
--      cannot INSERT, UPDATE or DELETE a spine row at all. The sync function's ACL floor is asserted
--      in both directions (authenticated/anon denied, service_role granted). Note what is NOT claimed:
--      service_role keeps the house default ALL on this PostgREST-exposed table, so a trusted platform
--      surface CAN write these rows — the tripwire, not an ACL, is the structural guard there.
--
--   7. THE TRIPWIRE AND FULL-TENANT PARITY (steps 18-20). A privileged writer may set points.active
--      alone (proving the tripwire is not a blanket denial of privileged writes) but not points AND
--      stamps together. The recompute is idempotent — called twice it produces byte-identical rows
--      including ctid. And the last step is the one that matters on production: ZERO disagreements
--      between the spine and the read model across ALL businesses, with every business owning
--      exactly four rows. Run inside the migration's own transaction it reproduces the recorded W1
--      full-tenant baseline row for row, and it is the standing drift detector for every later wave.
--
-- Fixture note (inherited from db/tests/v307_programme_read_model.sql): the wizard writes
-- kind='points' on loyalty_programs even for the stamps model, so the fixture keeps kind='points'
-- throughout and moves loyalty_model alone — the production shape. Neither the read model nor the
-- spine ever reads kind.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v308_programme_spine.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v308_out(seq integer, step text, outcome text) on commit drop;

-- Tenant-context calls need a real JWT; privileged seeding needs NO JWT, because several write
-- guards bypass only when no claims are in scope.
create or replace function pg_temp.as_v308_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v308_user(uuid,text) to public;

create or replace function pg_temp.as_v308_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v308_system() to public;

-- The W1 answer and the spine, in the same comparable shape. Both are read in the system context:
-- the read model is SECURITY INVOKER, so reading it through a tenant session would be asserting RLS
-- rather than the projection.
create or replace function pg_temp.v308_model(p_business uuid) returns jsonb
language sql stable as $$
  select jsonb_object_agg(programme.kind, programme.running)
    from app.business_programmes_v307(p_business) programme;
$$;
grant execute on function pg_temp.v308_model(uuid) to public;

create or replace function pg_temp.v308_spine(p_business uuid) returns jsonb
language sql stable as $$
  select jsonb_object_agg(spine.kind, spine.active)
    from public.business_programmes spine
   where spine.business_id = p_business;
$$;
grant execute on function pg_temp.v308_spine(uuid) to public;

-- Physical snapshot. ctid is included on purpose: now() is transaction time, so "the sync did not
-- rewrite this row" is only provable by the absence of a new heap tuple.
create or replace function pg_temp.v308_snapshot(p_business uuid) returns jsonb
language sql stable as $$
  select jsonb_agg(jsonb_build_object(
           'kind', spine.kind,
           'active', spine.active,
           'sort', spine.sort,
           'created_at', spine.created_at,
           'activated_at', spine.activated_at,
           'deactivated_at', spine.deactivated_at,
           'id', spine.id,
           'ctid', spine.ctid::text
         ) order by spine.sort)
    from public.business_programmes spine
   where spine.business_id = p_business;
$$;
grant execute on function pg_temp.v308_snapshot(uuid) to public;

-- Force the DEFERRED loyalty_tiers sync, then put it back.
--
-- v308 attaches the loyalty_tiers sync as a CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED, so
-- that publish_loyalty_config's delete-the-ladder-and-reinsert-it (v55:713-714) recomputes once from
-- the final rung state instead of stamping deactivated_at and then activated_at on a republish that
-- changed nothing. This whole suite runs inside ONE transaction that never commits, so every step
-- that mutates loyalty_tiers and then asserts has to run the queue itself.
--
-- Two commands, not one, and neither is decorative. `set constraints all immediate` runs the queue
-- AND leaves every deferrable constraint in immediate mode for the rest of the transaction, which
-- would quietly turn the storm steps below into the immediate behaviour they exist to disprove. The
-- second command re-defers the tiers trigger BY NAME: `set constraints all deferred` would also
-- defer the v308 tripwire (declared DEFERRABLE INITIALLY IMMEDIATE), and the tripwire step needs it
-- to still raise on the offending statement rather than at a commit that never comes.
create or replace function pg_temp.v308_flush_tiers() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints public.business_programmes_sync_loyalty_tiers_v308 deferred;
end
$$;
grant execute on function pg_temp.v308_flush_tiers() to public;

do $v308_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_stranger uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other uuid:=gen_random_uuid();
  v_slug text:='v308-spine-'||substr(gen_random_uuid()::text,1,8);
  v_other_slug text:='v308-spine-b-'||substr(gen_random_uuid()::text,1,8);
  v_all_false jsonb:=jsonb_build_object(
    'points',false,'tiers',false,'stamps',false,'referral',false);
  v_points jsonb:=jsonb_build_object(
    'points',true,'tiers',false,'stamps',false,'referral',false);
  v_points_tiers jsonb:=jsonb_build_object(
    'points',true,'tiers',true,'stamps',false,'referral',false);
  v_stamps jsonb:=jsonb_build_object(
    'points',false,'tiers',false,'stamps',true,'referral',false);
  v_stamps_referral jsonb:=jsonb_build_object(
    'points',false,'tiers',false,'stamps',true,'referral',true);
  v_spine jsonb;
  v_model jsonb;
  v_mid jsonb;
  v_before jsonb;
  v_after jsonb;
  v_other_before jsonb;
  v_other_after jsonb;
  v_kinds text[];
  v_sorts smallint[];
  v_rows integer;
  v_other_rows integer;
  v_activated integer;
  v_deactivated integer;
  v_points_activated timestamptz;
  v_points_deactivated timestamptz;
  v_stamps_activated timestamptz;
  v_tiers_activated timestamptz;
  v_tiers_deactivated timestamptz;
  v_tiers_activated_after timestamptz;
  v_tiers_deactivated_after timestamptz;
  v_tiers_ctid text;
  v_tiers_ctid_after text;
  v_tiers_active boolean;
  v_rung uuid;
  v_updated integer;
  v_seen integer;
  v_denied text:='';
  v_ok boolean;
  v_single boolean;
  v_err text;
  v_businesses bigint;
  v_spine_rows bigint;
  v_shape bigint;
  v_disagreements bigint;
  v_detail text;
begin
  perform pg_temp.as_v308_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v308-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_stranger,'authenticated','authenticated',
     'v308-stranger-'||substr(v_stranger::text,1,8)||'@example.test','',now(),now(),now());

  -- No owner session exists yet, so the business insert is a system transition. The trigger it
  -- fires writes the pending workspace control + lifecycle pair that app.business_workspace_open_v94
  -- reads, so the fixture UPDATEs the decision to approved the way platform review would.
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values(v_business,'V308 programme spine fixture',v_slug,'retail','SGD',
         array['dashboard','clients','sales','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v308 rollback fixture'
   where business_id=v_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_business)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id=v_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V308 Owner',true);

  -- ---- 1. the AFTER INSERT trigger alone produced the full four-row shape ----
  select array_agg(spine.kind order by spine.sort),
         array_agg(spine.sort order by spine.sort),
         count(*)::integer,
         (count(*) filter (where spine.activated_at is not null))::integer,
         (count(*) filter (where spine.deactivated_at is not null))::integer
    into strict v_kinds,v_sorts,v_rows,v_activated,v_deactivated
    from public.business_programmes spine
   where spine.business_id=v_business;
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(1,'bare_business_gets_four_inactive_rows',
    case when v_rows=4
          and v_kinds=array['points','tiers','stamps','referral']
          and v_sorts=array[1,2,3,4]::smallint[]
          and v_spine=v_all_false and v_model=v_all_false
          and v_activated=0 and v_deactivated=0
      then 'PASS 4 rows '||v_kinds::text||' sorts '||v_sorts::text||' '||v_spine::text
      else 'FAIL rows='||v_rows||' kinds='||coalesce(v_kinds::text,'null')
             ||' sorts='||coalesce(v_sorts::text,'null')
             ||' spine='||coalesce(v_spine::text,'null')
             ||' model='||coalesce(v_model::text,'null')
             ||' activated='||v_activated||' deactivated='||v_deactivated end);

  -- ---- 2. loyalty_programs INSERT: a classic programme activates points, stamping activated_at --
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents,tier_basis
  ) values(v_business,'points',true,'classic','published',100,500,'visits');
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  select spine.activated_at into v_points_activated
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='points';
  insert into v308_out values(2,'lp_insert_activates_points',
    case when v_spine=v_points and v_spine=v_model and v_points_activated is not null
      then 'PASS '||v_spine::text||' activated_at set'
      else 'FAIL spine='||coalesce(v_spine::text,'null')||' model='||coalesce(v_model::text,'null')
             ||' activated_at='||coalesce(v_points_activated::text,'null') end);

  -- ---- 3. businesses UPDATE OF points_mode, then loyalty_tiers INSERT — one statement each ----
  -- 'both' alone cannot raise tiers (no ladder exists yet); the FIRST tier row is what flips it, and
  -- asserting the intermediate state is what stops the businesses trigger covering for a missing
  -- loyalty_tiers trigger.
  update public.businesses set points_mode='both' where id=v_business;
  v_mid:=pg_temp.v308_spine(v_business);
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort) values
    (v_business,'Silver',0,1,1),
    (v_business,'Gold',5,1,2),
    (v_business,'Diamond',15,1.5,3);
  perform pg_temp.v308_flush_tiers();
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(3,'businesses_mode_update_then_lt_insert_raises_tiers',
    case when v_mid=v_points and v_spine=v_points_tiers and v_spine=v_model
      then 'PASS both-mode alone '||v_mid::text||' -> first ladder rows '||v_spine::text
      else 'FAIL mode_only='||coalesce(v_mid::text,'null')
             ||' with_ladder='||coalesce(v_spine::text,'null')
             ||' model='||coalesce(v_model::text,'null') end);

  -- ---- 4. loyalty_tiers DELETE: the LAST row vanishing lowers tiers, on its own statement ----
  delete from public.loyalty_tiers where business_id=v_business;
  perform pg_temp.v308_flush_tiers();
  v_mid:=pg_temp.v308_spine(v_business);
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort)
  values(v_business,'Silver',0,1,1);
  perform pg_temp.v308_flush_tiers();
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(4,'lt_delete_lowers_tiers',
    case when v_mid=v_points and v_spine=v_points_tiers and v_spine=v_model
      then 'PASS ladder deleted '||v_mid::text||' -> restored '||v_spine::text
      else 'FAIL deleted='||coalesce(v_mid::text,'null')
             ||' restored='||coalesce(v_spine::text,'null')
             ||' model='||coalesce(v_model::text,'null') end);

  -- ---- 5. an AUTHENTICATED session's own write drives the sync ----
  -- Every other step writes the legacy tables from the system context, which is not the case the
  -- SECURITY DEFINER rationale is about. businesses.points_mode is the one watched column a firm
  -- owner edits DIRECTLY over PostgREST (the frenly_init salons_update policy still governs it), so
  -- this step makes that exact write: `set local role authenticated` carrying the owner's JWT. The
  -- W1 read model is SECURITY INVOKER; had the sync been invoker too, it would compute the four
  -- flags through THIS session's RLS and could project a wrong answer. row_count is asserted so an
  -- RLS refusal shows up as a failure instead of a silently skipped step.
  -- Both directions are exercised and points_mode is left back on 'both', so every following step
  -- starts from exactly the state it started from before this step existed.
  perform pg_temp.as_v308_user(v_owner);
  update public.businesses set points_mode='redeem' where id=v_business;
  get diagnostics v_updated = row_count;
  perform pg_temp.as_v308_system();
  v_mid:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  perform pg_temp.as_v308_user(v_owner);
  update public.businesses set points_mode='both' where id=v_business;
  perform pg_temp.as_v308_system();
  v_spine:=pg_temp.v308_spine(v_business);
  insert into v308_out values(5,'authenticated_session_write_syncs_spine',
    case when v_updated=1 and v_mid=v_points and v_mid=v_model
          and v_spine=v_points_tiers and v_spine=pg_temp.v308_model(v_business)
      then 'PASS owner PostgREST-shaped write updated 1 row; redeem -> '||v_mid::text
           ||' and back to both -> '||v_spine::text||', spine = read model both times'
      else 'FAIL rows_updated='||coalesce(v_updated::text,'null')
             ||' redeem_spine='||coalesce(v_mid::text,'null')
             ||' redeem_model='||coalesce(v_model::text,'null')
             ||' both_spine='||coalesce(v_spine::text,'null')
             ||' both_model='||coalesce(pg_temp.v308_model(v_business)::text,'null') end);

  -- ---- 6. THE PUBLISH STORM: delete-all + reinsert-identical must not move the breadcrumbs ----
  -- public.publish_loyalty_config (v55:713-714) republishes the ladder by DELETING every rung for
  -- the business and re-INSERTing them from the version table, ids and all. Fired immediately, the
  -- tiers sync would read that as tiers=false after the DELETE (stamping deactivated_at) and
  -- tiers=true after the INSERT (stamping activated_at) — a republish that changed nothing would
  -- rewrite the whole "running since… / paused on…" history. The v308 trigger is deferred for
  -- exactly this reason, so the queued events recompute once, from the FINAL rung state, and the
  -- upsert's `is distinct from` guard finds nothing to do.
  -- Asserted on the physical snapshot, which carries ctid: within one transaction now() is constant,
  -- so a re-stamp would be invisible by value and is only provable as a new heap tuple. The rung is
  -- reinserted under its OWN id, the way publish does it.
  select tier.id into strict v_rung
    from public.loyalty_tiers tier where tier.business_id=v_business;
  select spine.activated_at,spine.deactivated_at,spine.ctid::text
    into strict v_tiers_activated,v_tiers_deactivated,v_tiers_ctid
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='tiers';
  v_before:=pg_temp.v308_snapshot(v_business);
  delete from public.loyalty_tiers where business_id=v_business;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values(v_rung,v_business,'Silver',0,1,1);
  perform pg_temp.v308_flush_tiers();
  v_after:=pg_temp.v308_snapshot(v_business);
  select spine.activated_at,spine.deactivated_at,spine.ctid::text
    into strict v_tiers_activated_after,v_tiers_deactivated_after,v_tiers_ctid_after
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='tiers';
  insert into v308_out values(6,'publish_storm_leaves_breadcrumbs_untouched',
    case when v_before=v_after
          and v_tiers_activated_after is not distinct from v_tiers_activated
          and v_tiers_deactivated_after is not distinct from v_tiers_deactivated
          and v_tiers_ctid_after=v_tiers_ctid
          and pg_temp.v308_spine(v_business)=v_points_tiers
          and pg_temp.v308_spine(v_business)=pg_temp.v308_model(v_business)
      then 'PASS ladder deleted and reinserted identically: tiers still true, activated_at '
           ||coalesce(v_tiers_activated::text,'null')||' and deactivated_at '
           ||coalesce(v_tiers_deactivated::text,'null')||' unchanged, no new heap tuple (ctid '
           ||v_tiers_ctid||')'
      else 'FAIL snapshot_changed='||(v_before is distinct from v_after)::text
             ||' activated '||coalesce(v_tiers_activated::text,'null')||' -> '
             ||coalesce(v_tiers_activated_after::text,'null')
             ||' deactivated '||coalesce(v_tiers_deactivated::text,'null')||' -> '
             ||coalesce(v_tiers_deactivated_after::text,'null')
             ||' ctid '||v_tiers_ctid||' -> '||v_tiers_ctid_after
             ||' spine='||coalesce(pg_temp.v308_spine(v_business)::text,'null') end);

  -- ---- 7. …but a REAL pause still records ----
  -- The deferral must not have turned the tiers breadcrumb into a no-op generally. Delete the rungs
  -- and do NOT restore them before the queue runs: the recompute at flush time sees no ladder,
  -- lowers the flag and stamps deactivated_at, rewriting the row (new ctid). The rung is restored
  -- afterwards so the following steps start where they did before.
  delete from public.loyalty_tiers where business_id=v_business;
  perform pg_temp.v308_flush_tiers();
  select spine.active,spine.activated_at,spine.deactivated_at,spine.ctid::text
    into strict v_tiers_active,v_tiers_activated_after,v_tiers_deactivated_after,v_tiers_ctid_after
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='tiers';
  v_mid:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values(v_rung,v_business,'Silver',0,1,1);
  perform pg_temp.v308_flush_tiers();
  v_spine:=pg_temp.v308_spine(v_business);
  insert into v308_out values(7,'real_ladder_pause_still_stamps_deactivated_at',
    case when v_tiers_active=false and v_mid=v_points and v_mid=v_model
          and v_tiers_deactivated_after is not null
          and v_tiers_activated_after is not null
          and v_tiers_deactivated_after>=v_tiers_activated_after
          and v_tiers_ctid_after<>v_tiers_ctid
          and v_spine=v_points_tiers and v_spine=pg_temp.v308_model(v_business)
      then 'PASS rungs deleted without restore: tiers false, deactivated_at stamped, row rewritten '
           ||'(ctid '||v_tiers_ctid||' -> '||v_tiers_ctid_after||'); ladder restored -> '||v_spine::text
      else 'FAIL active='||coalesce(v_tiers_active::text,'null')
             ||' paused_spine='||coalesce(v_mid::text,'null')
             ||' paused_model='||coalesce(v_model::text,'null')
             ||' activated='||coalesce(v_tiers_activated_after::text,'null')
             ||' deactivated='||coalesce(v_tiers_deactivated_after::text,'null')
             ||' ctid '||v_tiers_ctid||' -> '||v_tiers_ctid_after
             ||' restored='||coalesce(v_spine::text,'null') end);

  -- ---- 8. loyalty_tiers UPDATE OF business_id: BOTH tenants resync (the OLD/NEW branch) ----
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values(v_other,'V308 spine second tenant',v_other_slug,'retail','SGD',
         array['dashboard','clients','sales','loyalty'],'both');
  perform set_config('app.v79_system_transition','',true);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents,tier_basis
  ) values(v_other,'points',true,'classic','published',100,500,'visits');
  v_before:=pg_temp.v308_spine(v_business);
  v_other_before:=pg_temp.v308_spine(v_other);
  update public.loyalty_tiers set business_id=v_other where business_id=v_business;
  perform pg_temp.v308_flush_tiers();
  v_after:=pg_temp.v308_spine(v_business);
  v_other_after:=pg_temp.v308_spine(v_other);
  insert into v308_out values(8,'lt_business_id_move_resyncs_both_tenants',
    case when v_before=v_points_tiers and v_other_before=v_points
          and v_after=v_points and v_other_after=v_points_tiers
          and v_after=pg_temp.v308_model(v_business)
          and v_other_after=pg_temp.v308_model(v_other)
      then 'PASS source '||v_before::text||' -> '||v_after::text
           ||'; target '||v_other_before::text||' -> '||v_other_after::text
      else 'FAIL source '||coalesce(v_before::text,'null')||' -> '||coalesce(v_after::text,'null')
             ||'; target '||coalesce(v_other_before::text,'null')||' -> '
             ||coalesce(v_other_after::text,'null') end);

  -- ---- 9. loyalty_programs UPDATE (model) + points_mode: stamps on, points and tiers off ----
  update public.loyalty_programs
     set loyalty_model='stamps',stamp_per_cents=500,stamp_target=10
   where business_id=v_business;
  update public.businesses set points_mode='redeem' where id=v_business;
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  select spine.deactivated_at into v_points_deactivated
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='points';
  select spine.activated_at into v_stamps_activated
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='stamps';
  insert into v308_out values(9,'lp_model_update_moves_points_off_stamps_on',
    case when v_spine=v_stamps and v_spine=v_model
          and v_points_deactivated is not null and v_stamps_activated is not null
      then 'PASS '||v_spine::text||' points deactivated_at + stamps activated_at set'
      else 'FAIL spine='||coalesce(v_spine::text,'null')||' model='||coalesce(v_model::text,'null')
             ||' points_deactivated='||coalesce(v_points_deactivated::text,'null')
             ||' stamps_activated='||coalesce(v_stamps_activated::text,'null') end);

  -- ---- 10. referral_programs INSERT moves referral and nothing else ----
  v_before:=pg_temp.v308_spine(v_business);
  insert into public.referral_programs(business_id,enabled,reward_cents,min_spend_cents)
  values(v_business,true,1000,0);
  v_after:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(10,'rp_insert_is_independent',
    case when v_after=v_stamps_referral and v_after=v_model
          and (v_before-'referral'::text)=(v_after-'referral'::text)
      then 'PASS only referral moved: '||v_before::text||' -> '||v_after::text
      else 'FAIL '||coalesce(v_before::text,'null')||' -> '||coalesce(v_after::text,'null')
             ||' model='||coalesce(v_model::text,'null') end);

  -- ---- 11. referral_programs UPDATE OF enabled, then DELETE of an ENABLED row ----
  update public.referral_programs set enabled=false where business_id=v_business;
  v_mid:=pg_temp.v308_spine(v_business);
  update public.referral_programs set enabled=true where business_id=v_business;
  v_before:=pg_temp.v308_spine(v_business);
  delete from public.referral_programs where business_id=v_business;
  v_after:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(11,'rp_enabled_update_and_delete_lower_referral',
    case when v_mid=v_stamps and v_before=v_stamps_referral
          and v_after=v_stamps and v_after=v_model
      then 'PASS disabled '||v_mid::text||' re-enabled '||v_before::text||' deleted '||v_after::text
      else 'FAIL disabled='||coalesce(v_mid::text,'null')
             ||' re_enabled='||coalesce(v_before::text,'null')
             ||' deleted='||coalesce(v_after::text,'null')
             ||' model='||coalesce(v_model::text,'null') end);

  -- ---- 12. loyalty_programs UPDATE (active=false) zeroes the loyalty three ----
  update public.loyalty_programs set active=false where business_id=v_business;
  v_spine:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(12,'inactive_programme_zeroes_loyalty_flags',
    case when v_spine=v_all_false and v_spine=v_model
      then 'PASS '||v_spine::text
      else 'FAIL spine='||coalesce(v_spine::text,'null')||' model='||coalesce(v_model::text,'null') end);

  -- ---- 13. breadcrumbs: never cleared, never churned ----
  -- The points row has been on (step 2) and off (step 6), so it must carry BOTH stamps. An UPDATE to
  -- a legacy column that cannot move a flag must write no spine tuple at all: asserted on ctid,
  -- because now() is transaction time and a re-stamp would be invisible by value.
  select spine.activated_at,spine.deactivated_at
    into strict v_points_activated,v_points_deactivated
    from public.business_programmes spine
   where spine.business_id=v_business and spine.kind='points';
  v_before:=pg_temp.v308_snapshot(v_business);
  update public.loyalty_programs set earn_rate_bps=777 where business_id=v_business;
  v_after:=pg_temp.v308_snapshot(v_business);
  insert into v308_out values(13,'breadcrumbs_kept_and_unchanged_active_writes_nothing',
    case when v_points_activated is not null and v_points_deactivated is not null
          and v_points_deactivated>=v_points_activated
          and v_before=v_after
      then 'PASS points carries both stamps and the no-op recompute wrote no tuple'
      else 'FAIL activated='||coalesce(v_points_activated::text,'null')
             ||' deactivated='||coalesce(v_points_deactivated::text,'null')
             ||' snapshot_changed='||(v_before is distinct from v_after)::text end);

  -- ---- 14. loyalty_programs DELETE of an ACTIVE programme row lowers its flag ----
  update public.loyalty_programs set active=true where business_id=v_business;
  v_before:=pg_temp.v308_spine(v_business);
  delete from public.loyalty_programs where business_id=v_business;
  v_after:=pg_temp.v308_spine(v_business);
  v_model:=pg_temp.v308_model(v_business);
  insert into v308_out values(14,'lp_delete_lowers_its_flag',
    case when v_before=v_stamps and v_after=v_all_false and v_after=v_model
      then 'PASS reactivated '||v_before::text||' -> deleted '||v_after::text
      else 'FAIL reactivated='||coalesce(v_before::text,'null')
             ||' deleted='||coalesce(v_after::text,'null')
             ||' model='||coalesce(v_model::text,'null') end);

  -- ---- 15. RLS: a stranger sees nothing, a staff member sees exactly four ----
  perform pg_temp.as_v308_user(v_stranger);
  select count(*)::integer into strict v_seen
    from public.business_programmes spine where spine.business_id=v_business;
  perform pg_temp.as_v308_system();
  perform pg_temp.as_v308_user(v_owner);
  select count(*)::integer into strict v_rows
    from public.business_programmes spine where spine.business_id=v_business;
  -- …and only its own: the staff member is not a member of the second tenant.
  select count(*)::integer into strict v_other_rows
    from public.business_programmes spine where spine.business_id=v_other;
  perform pg_temp.as_v308_system();
  insert into v308_out values(15,'rls_staff_reads_own_four_only',
    case when v_seen=0 and v_rows=4 and v_other_rows=0
      then 'PASS stranger 0 rows, staff 4 own rows, 0 rows of the other tenant'
      else 'FAIL stranger='||v_seen||' staff_own='||v_rows||' staff_other='||v_other_rows end);

  -- ---- 16. no BROWSER role can write the spine at all ----
  -- Scope: `authenticated`. service_role is deliberately NOT asserted denied — it keeps the house
  -- default ALL on this PostgREST-exposed table and is a trusted platform surface.
  perform pg_temp.as_v308_user(v_owner);
  begin
    insert into public.business_programmes(business_id,kind,active,sort)
    values(v_business,'points',true,1);
    v_denied:=v_denied||'insert:ALLOWED ';
  exception when others then
    v_denied:=v_denied||'insert:'||sqlstate||' ';
  end;
  begin
    update public.business_programmes set active=true where business_id=v_business;
    v_denied:=v_denied||'update:ALLOWED ';
  exception when others then
    v_denied:=v_denied||'update:'||sqlstate||' ';
  end;
  begin
    delete from public.business_programmes where business_id=v_business;
    v_denied:=v_denied||'delete:ALLOWED ';
  exception when others then
    v_denied:=v_denied||'delete:'||sqlstate||' ';
  end;
  perform pg_temp.as_v308_system();
  select count(*)::integer into strict v_rows
    from public.business_programmes spine where spine.business_id=v_business;
  insert into v308_out values(16,'authenticated_cannot_write_the_spine',
    case when v_denied not like '%ALLOWED%' and v_rows=4
          and pg_temp.v308_spine(v_business)=v_all_false
      then 'PASS '||v_denied||'(rows still 4, all inactive)'
      else 'FAIL '||v_denied||' rows='||v_rows
             ||' spine='||coalesce(pg_temp.v308_spine(v_business)::text,'null') end);

  -- ---- 17. ACL floor on the sync function and on the table ----
  insert into v308_out values(17,'acl_floor',
    case when has_function_privilege('authenticated',
                 'app.sync_business_programmes_v308(uuid)','execute')=false
          and has_function_privilege('anon',
                 'app.sync_business_programmes_v308(uuid)','execute')=false
          and has_function_privilege('service_role',
                 'app.sync_business_programmes_v308(uuid)','execute')=true
          and has_table_privilege('authenticated','public.business_programmes','select')=true
          and has_table_privilege('authenticated','public.business_programmes','insert')=false
          and has_table_privilege('authenticated','public.business_programmes','update')=false
          and has_table_privilege('authenticated','public.business_programmes','delete')=false
          and has_table_privilege('anon','public.business_programmes','select')=false
      then 'PASS sync execute: authenticated=false anon=false service_role=true; '
           ||'table: authenticated select-only, anon none'
      else 'FAIL sync auth='||has_function_privilege('authenticated',
                 'app.sync_business_programmes_v308(uuid)','execute')::text
             ||' anon='||has_function_privilege('anon',
                 'app.sync_business_programmes_v308(uuid)','execute')::text
             ||' service_role='||has_function_privilege('service_role',
                 'app.sync_business_programmes_v308(uuid)','execute')::text
             ||' table_auth_select='||has_table_privilege('authenticated',
                 'public.business_programmes','select')::text
             ||' table_auth_insert='||has_table_privilege('authenticated',
                 'public.business_programmes','insert')::text
             ||' table_auth_update='||has_table_privilege('authenticated',
                 'public.business_programmes','update')::text
             ||' table_auth_delete='||has_table_privilege('authenticated',
                 'public.business_programmes','delete')::text
             ||' table_anon_select='||has_table_privilege('anon',
                 'public.business_programmes','select')::text end);

  -- ---- 18. the tripwire: one accruing programme is fine, two are refused ----
  -- The single-flag write proves the refusal below comes from the PAIR, not from a blanket denial of
  -- privileged writes. BOTH writes are wrapped, so a regression is reported as a FAIL row rather
  -- than aborting the transaction and taking the whole report down with it. Both are undone before
  -- the parity step: the raise rolls its own statement back, and the sync restores the row the first
  -- write moved.
  begin
    update public.business_programmes set active=true
     where business_id=v_business and kind='points';
    v_single:=true;
    v_err:='single flag accepted;';
  exception when others then
    v_single:=false;
    v_err:='single flag REFUSED '||sqlstate||' '||sqlerrm||';';
  end;
  begin
    update public.business_programmes set active=true
     where business_id=v_business and kind='stamps';
    v_ok:=false;
    v_err:=v_err||' pair ACCEPTED';
  exception when others then
    v_ok:=true;
    v_err:=v_err||' pair refused '||sqlstate;
  end;
  perform app.sync_business_programmes_v308(v_business);
  insert into v308_out values(18,'tripwire_refuses_points_and_stamps_together',
    case when v_single and v_ok and pg_temp.v308_spine(v_business)=v_all_false
      then 'PASS '||v_err||', spine restored by the sync'
      else 'FAIL '||v_err
             ||' spine='||coalesce(pg_temp.v308_spine(v_business)::text,'null') end);

  -- ---- 19. idempotence: recomputing twice writes nothing at all ----
  v_before:=pg_temp.v308_snapshot(v_business);
  perform app.sync_business_programmes_v308(v_business);
  perform app.sync_business_programmes_v308(v_business);
  v_after:=pg_temp.v308_snapshot(v_business);
  select count(*)::integer into strict v_rows
    from public.business_programmes spine where spine.business_id=v_business;
  insert into v308_out values(19,'recompute_is_idempotent',
    case when v_before=v_after and v_rows=4
      then 'PASS two recomputes changed no value, no timestamp and no tuple'
      else 'FAIL rows='||v_rows||' before='||coalesce(v_before::text,'null')
             ||' after='||coalesce(v_after::text,'null') end);

  -- ---- 20. FULL-TENANT PARITY: the spine equals the read model for EVERY business ----
  select count(*) into strict v_businesses from public.businesses;
  select count(*) into strict v_spine_rows from public.business_programmes;
  select count(*) into strict v_shape
    from (
      select business.id
        from public.businesses business
        left join public.business_programmes spine on spine.business_id=business.id
       group by business.id
      having count(spine.id)<>4 or count(distinct spine.kind)<>4
    ) shape;
  select count(*),coalesce(string_agg(
           business.id::text||'/'||model.kind
             ||' spine='||spine.active::text||' model='||model.running::text,
           ', ' order by business.id,model.kind),'')
    into strict v_disagreements,v_detail
    from public.businesses business
    cross join lateral app.business_programmes_v307(business.id) model
    join public.business_programmes spine
      on spine.business_id=business.id and spine.kind=model.kind
   where spine.active is distinct from model.running;
  insert into v308_out values(20,'full_tenant_spine_equals_read_model',
    case when v_disagreements=0 and v_shape=0 and v_spine_rows=v_businesses*4
      then 'PASS '||v_businesses||' businesses, '||v_spine_rows
             ||' spine rows, zero disagreements with app.business_programmes_v307'
      else 'FAIL businesses='||v_businesses||' spine_rows='||v_spine_rows
             ||' wrong_shape='||v_shape||' disagreements='||v_disagreements
             ||' detail='||v_detail end);
end
$v308_test$;

reset role;

select seq, step, outcome from v308_out order by seq;

rollback;
