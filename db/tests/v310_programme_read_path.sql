-- Rollback-only v310 acceptance: the W4a READ-PATH flip.
--
-- v310 makes eleven server readers programme-aware. Ten of the eleven changes are purely
-- ADDITIVE — new keys, no existing key removed, renamed, retyped or given a new meaning — because
-- /app-*.js is Cloudflare-pinned for ~4h and old-bundle x new-server must stay correct for the
-- whole window. The eleventh is the wave's ONE behaviour change: the `tier_basis='points_earned'`
-- tier-fuel metric is scoped to the points programme's ledger rows, in three of its FOUR twins.
-- So the things worth proving are:
--
--   1. ADDITIVE SHAPE (steps 1, 5, 10, 11). Every pre-v310 key is still there, with the same
--      type and the same value, and the new keys are additions. The pre-v310 key sets are
--      captured as literal expectations and compared BEFORE any step flips programme state, so a
--      later fixture mutation cannot launder a shape regression.
--
--   2. programmes[] IS THE SPINE (steps 2, 3). Four rows, spine `sort` order, `active` read from
--      public.business_programmes and never recomputed, breadcrumbs surfaced, and the BINDING
--      cross-check invariant proved behaviourally in both directions on two tenants whose
--      answers differ: programmes[points].customer_visible === legacy `rewards` and
--      programmes[tiers].customer_visible === legacy `tiers`.
--
--   3. D1, THE ONE BEHAVIOUR CHANGE (step 6). A SWITCHED firm — earns under points, flips
--      loyalty_model to stamps, then takes an offsetting row and a stamps earn — must report a
--      tier metric built from the POINTS programme's earns alone, while every BALANCE it exposes
--      stays the single business pot (step 8). This is the currentness policy made testable.
--
--   4. THE FAIL-OPEN BRANCH (step 7) — the highest-severity line in the wave. Deleting the points
--      spine row inside this transaction must leave the metric UNCHANGED, not zeroed. Written the
--      obvious way (`and programme_id = (select ... )`) a NULL subselect makes the predicate never
--      true and silently drops every customer at that firm to no tier.
--
--   5. TWIN PARITY (step 9). customer_get_effective_tier_v143, app.v176_tier_gate_metric and
--      customer_get_business_presentation_v95 must return the SAME metric for the same
--      (business, client) across a tier_basis x loyalty_model matrix — and the fourth twin,
--      app.loyalty_tier_for, must still return the UNFILTERED sum, because app.on_sale_recorded
--      calls it and it is the earn multiplier. That divergence is deliberate and is W5's target.
--
--   6. THE DETECTOR AND THE SUPPRESSION RULE (steps 8, 12). The detector reports the switched
--      firm with distinct_tags=2 and stays silent on every single-pot fixture; and the owner-side
--      liability readers keep points_outstanding_total byte-identical while suppressing the
--      per-tag array to NULL — never a partial array — for the split firm.
--
--   7. IDENTITY-ONLY READERS (steps 10, 11, 13) and the ACL floor (step 14).
--
-- RED-FIRST, MEASURED (not predicted). Against a database that has v307/v308/v309 but NOT v310
-- the suite ABORTS at step 8 with `function app.detect_programme_pot_split_v310() does not exist`
-- (42883) — which is itself the proof that it is testing this wave. To get per-step redness the
-- two new v310 functions were installed ALONE on a pre-v310 cluster (readers untouched), and
-- 12 of the 14 steps went red:
--   1,2,3  `programmes` / `programmes_contract` absent from capabilities
--   4      `programmes` / `balance_scope` absent from the reward catalog
--   5      `tier_fuel` / `balance_scope` absent from the tier payload
--   6      the tier metric reads 150 — the stamps-era earn is counted too — instead of 120
--   7      the metric reads 90 both before and after the spine-row delete: there is no filter,
--          so there is nothing to fail open
--   9      the scoped twins read 47 (the whole ledger) instead of 40
--   10,11  `programme` absent from customer_get_wallet / customer_get_loyalty_details
--   12     `pot_is_split` / `points_outstanding_by_programme_tag` absent
--   13     `stamp_card` absent and point_system counts stamp earners
-- Steps 8 and 14 are green in that run because they exercise ONLY the two new functions, which
-- is exactly what they are for.
--
-- MUTATION MATRIX on the full wave (each mutation applied to the real migration file):
--   revert the D1 filter in all three twins       -> steps 6, 7 and 9 FAIL
--   keep the filter, drop the fail-OPEN branch    -> step 7 FAILs with 0/0/0 after the delete:
--     (`and programme_id = (subselect)`)             the silent tier wipe, reproduced
--   scope the ladder but leave app.v176_tier_gate_metric unfiltered
--                                                 -> step 9 FAILs (v143=40 vs gate=47) and step 6
--                                                    FAILs (120 vs 150): the twin-parity net
--   drop the standing detector                    -> the suite cannot run past step 8 (42883)
--
-- Fixture note: the wizard writes loyalty_programs.kind='points' even for the stamps model, so
-- every fixture keeps kind='points' and moves loyalty_model alone — the production shape,
-- inherited from db/tests/v307, v308 and v309.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v310_programme_read_path.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v310_out(seq integer, step text, outcome text) on commit drop;

-- Tenant-context calls need a real JWT; privileged seeding needs NO JWT, because several write
-- guards (link insertion, branch enforcement) bypass only when no claims are in scope.
create or replace function pg_temp.as_v310_user(
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
grant execute on function pg_temp.as_v310_user(uuid,text) to public;

create or replace function pg_temp.as_v310_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v310_system() to public;

-- One earn row, written exactly the way app.on_sale_recorded writes one (v37b:653-661), through
-- the real v20 write-guard token route. p_programme is normally NULL — the v309 BEFORE INSERT
-- trigger fills it from the BUSINESS — and is passed non-null only where the test needs a row
-- that the current model would not produce.
create or replace function pg_temp.v310_earn(
  p_business uuid, p_client uuid, p_sale uuid, p_points integer,
  p_entry text default 'earn', p_programme uuid default null
) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
  -- the v20 write guard admits exactly four internal routes and checks the row shape against
  -- the route, so the fixture picks the route its entry_type belongs to rather than forcing one.
  v_scope text := case p_entry
                    when 'earn' then 'sale_trigger'
                    when 'redeem' then 'redeem_points'
                    when 'expire' then 'points_expiry'
                    else 'adjust_points' end;
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', v_scope, true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id
  ) values (
    v_id, p_business, p_client, p_entry, p_points, p_sale, 'v310 fixture', null, p_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$$;
grant execute on function pg_temp.v310_earn(uuid,uuid,uuid,integer,text,uuid) to public;

create or replace function pg_temp.v310_sale(
  p_business uuid, p_client uuid, p_cents integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  -- earns_points/counts_as_visit false with policy_resolved_at pinned (v106/v300 idiom) so the
  -- live app.on_sale_recorded early-returns and this fixture's own rows own the sale.
  insert into public.sales(id,business_id,client_id,kind,amount_cents,occurred_at,
                           counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,note)
  values(v_id,p_business,p_client,'quick_sale',p_cents,now(),
         true,false,false,now(),'v310 fixture');
  return v_id;
end
$$;
grant execute on function pg_temp.v310_sale(uuid,uuid,integer) to public;

create or replace function pg_temp.v310_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v310_spine(uuid,text) to public;

-- The sorted key set of a jsonb object, as a text array — the shape assertion primitive.
create or replace function pg_temp.v310_keys(p_obj jsonb) returns text[]
language sql immutable as $$
  select coalesce(array(select k from jsonb_object_keys(p_obj) k order by k), '{}'::text[])
$$;
grant execute on function pg_temp.v310_keys(jsonb) to public;

create or replace function pg_temp.v310_programme(p_caps jsonb, p_kind text) returns jsonb
language sql immutable as $$
  select entry from jsonb_array_elements(coalesce(p_caps->'programmes','[]'::jsonb)) entry
   where entry->>'kind' = p_kind
$$;
grant execute on function pg_temp.v310_programme(jsonb,text) to public;

do $v310_test$
declare
  v_owner uuid := gen_random_uuid();
  v_member uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_points_biz uuid := gen_random_uuid();
  v_tiers_biz uuid := gen_random_uuid();
  v_stamps_biz uuid := gen_random_uuid();
  v_both_biz uuid := gen_random_uuid();
  v_switch_biz uuid := gen_random_uuid();
  v_failopen_biz uuid := gen_random_uuid();
  v_points_client uuid := gen_random_uuid();
  v_tiers_client uuid := gen_random_uuid();
  v_stamps_client uuid := gen_random_uuid();
  v_both_client uuid := gen_random_uuid();
  v_switch_client uuid := gen_random_uuid();
  v_failopen_client uuid := gen_random_uuid();
  v_biz uuid;
  v_client uuid;
  v_points_slug text := 'v310-points-'||substr(gen_random_uuid()::text,1,8);
  v_tiers_slug text := 'v310-tiers-'||substr(gen_random_uuid()::text,1,8);
  v_stamps_slug text := 'v310-stamps-'||substr(gen_random_uuid()::text,1,8);
  v_both_slug text := 'v310-both-'||substr(gen_random_uuid()::text,1,8);
  v_switch_slug text := 'v310-switch-'||substr(gen_random_uuid()::text,1,8);
  v_failopen_slug text := 'v310-failopen-'||substr(gen_random_uuid()::text,1,8);
  v_link uuid;
  v_config uuid;
  v_reward uuid;
  v_sale uuid;
  v_caps jsonb;
  v_caps_both jsonb;
  v_catalog jsonb;
  v_catalog_stamps jsonb;
  v_tier jsonb;
  v_wallet jsonb;
  v_card jsonb;
  v_details jsonb;
  v_usage jsonb;
  v_insights jsonb;
  v_overview jsonb;
  v_presentation jsonb;
  v_expected_caps_keys text[] := array[
    'activity','appointments','booking_request','membership','packages',
    'points_mode','rewards','tiers','wallet'];
  v_expected_catalog_keys text[] := array['points_mode','rewards'];
  v_expected_tier_keys text[] := array[
    'basis','current','label','metric','next','points_mode','progress_percent','tiers'];
  v_expected_loyalty_keys text[] := array[
    'balance','credit_balance_cents','enabled','model','unit'];
  v_metric_143 numeric;
  v_metric_gate numeric;
  v_metric_pres numeric;
  v_metric_tier_for numeric;
  v_metric_before numeric;
  v_metric_after numeric;
  v_gate_before numeric;
  v_gate_after numeric;
  v_pres_before numeric;
  v_pres_after numeric;
  v_business_pot integer;
  v_points_only integer;
  v_detected record;
  v_detected_off record;
  v_detected_others bigint;
  v_matrix text := '';
  v_matrix_fail text := '';
  v_basis text;
  v_model text;
  v_anon boolean;
  v_auth boolean;
  v_service boolean;
begin
  perform pg_temp.as_v310_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v310-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_member,'authenticated','authenticated',
     'v310-member-'||substr(v_member::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.customer_identities(id,auth_user_id,status)
  values(v_identity,v_member,'active');

  -- Five tenant shapes, created through the v79 system-transition path the other suites use.
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode) values
    (v_points_biz,'V310 points fixture',v_points_slug,
     'retail','SGD',array['dashboard','clients','sales','loyalty'],'redeem'),
    (v_tiers_biz,'V310 tiers fixture',v_tiers_slug,
     'retail','SGD',array['dashboard','clients','sales','loyalty'],'tiers'),
    (v_stamps_biz,'V310 stamps fixture',v_stamps_slug,
     'cafe','SGD',array['dashboard','clients','sales','loyalty'],'redeem'),
    (v_both_biz,'V310 both fixture',v_both_slug,
     'retail','SGD',array['dashboard','clients','sales','loyalty'],'both'),
    (v_switch_biz,'V310 switched fixture',v_switch_slug,
     'cafe','SGD',array['dashboard','clients','sales','loyalty'],'tiers'),
    (v_failopen_biz,'V310 fail-open fixture',v_failopen_slug,
     'retail','SGD',array['dashboard','clients','sales','loyalty'],'tiers');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v310 rollback fixture'
   where business_id in (v_points_biz,v_tiers_biz,v_stamps_biz,v_both_biz,v_switch_biz,
                         v_failopen_biz);
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_points_biz),(v_tiers_biz),(v_stamps_biz),(v_both_biz),(v_switch_biz),(v_failopen_biz)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id in (v_points_biz,v_tiers_biz,v_stamps_biz,v_both_biz,v_switch_biz,
                         v_failopen_biz);

  insert into public.staff(business_id,user_id,role,full_name,active) values
    (v_points_biz,v_owner,'owner','V310 Owner',true),
    (v_tiers_biz,v_owner,'owner','V310 Owner',true),
    (v_stamps_biz,v_owner,'owner','V310 Owner',true),
    (v_both_biz,v_owner,'owner','V310 Owner',true),
    (v_switch_biz,v_owner,'owner','V310 Owner',true),
    (v_failopen_biz,v_owner,'owner','V310 Owner',true);

  insert into public.branches(business_id,name,active,is_default) values
    (v_points_biz,'Main',true,true),(v_tiers_biz,'Main',true,true),
    (v_stamps_biz,'Main',true,true),(v_both_biz,'Main',true,true),
    (v_switch_biz,'Main',true,true),(v_failopen_biz,'Main',true,true);
  insert into public.business_brand_presentation_v95(business_id)
  values(v_points_biz),(v_tiers_biz),(v_stamps_biz),(v_both_biz),(v_switch_biz),(v_failopen_biz)
  on conflict (business_id) do nothing;

  -- classic points firm: a redeemable catalogue, no ladder.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,reward_credit_cents
  ) values(v_points_biz,'points',true,'classic','published',100,500);
  -- tiers firm: points_earned basis, a published ladder. THE D1 FIXTURE.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,tier_basis,
    redeem_points,reward_credit_cents
  ) values(v_tiers_biz,'points',true,'points_tiers','published','points_earned',100,500);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,stamp_target,stamp_per_cents
  ) values(v_stamps_biz,'points',true,'stamps','published',10,1000);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,tier_basis,
    redeem_points,reward_credit_cents
  ) values(v_both_biz,'points',true,'points_tiers','published','points_earned',100,500);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,tier_basis,
    redeem_points,reward_credit_cents
  ) values(v_switch_biz,'points',true,'classic','published','points_earned',100,500);
  -- the fail-open fixture: points_earned basis, a ladder, and (in step 7) an earn tagged with a
  -- programme the resolver would never pick, which is what leaves its points spine row deletable.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,tier_basis,
    redeem_points,reward_credit_cents
  ) values(v_failopen_biz,'points',true,'points_tiers','published','points_earned',100,500);

  insert into public.loyalty_tiers(business_id,name,threshold,sort,perk_note) values
    (v_tiers_biz,'Silver',0,1,'Welcome'),(v_tiers_biz,'Gold',100,2,'Free drink'),
    (v_both_biz,'Silver',0,1,'Welcome'),(v_both_biz,'Gold',100,2,'Free drink'),
    (v_switch_biz,'Silver',0,1,'Welcome'),(v_switch_biz,'Gold',100,2,'Free drink'),
    (v_failopen_biz,'Silver',0,1,'Welcome'),(v_failopen_biz,'Gold',100,2,'Free drink');
  -- The v308 loyalty_tiers sync is a DEFERRABLE INITIALLY DEFERRED constraint trigger (V308
  -- standing invariant 2), so the spine's `tiers` flag converges at COMMIT, not per statement.
  -- This suite asserts mid-transaction, so the queue is flushed here and then RE-DEFERRED BY
  -- NAME — never `set constraints all deferred`, which would also defer the exclusive-accrual
  -- tripwire and hide the one thing it exists to catch. (v308 suite:161-170.)
  set constraints all immediate;
  set constraints public.business_programmes_sync_loyalty_tiers_v308 deferred;

  insert into public.referral_programs(business_id,enabled,reward_cents,min_spend_cents)
  values(v_points_biz,true,500,0);

  insert into public.clients(id,business_id,full_name,phone) values
    (v_points_client,v_points_biz,'V310 Points Member','+6580003101'),
    (v_tiers_client,v_tiers_biz,'V310 Tiers Member','+6580003102'),
    (v_stamps_client,v_stamps_biz,'V310 Stamps Member','+6580003103'),
    (v_both_client,v_both_biz,'V310 Both Member','+6580003104'),
    (v_switch_client,v_switch_biz,'V310 Switch Member','+6580003105'),
    (v_failopen_client,v_failopen_biz,'V310 Fail-open Member','+6580003106');

  -- One customer identity, five verified links, through the real v31 claim guard.
  foreach v_biz in array array[v_points_biz,v_tiers_biz,v_stamps_biz,v_both_biz,v_switch_biz,
                               v_failopen_biz] loop
    select client.id into v_client from public.clients client
     where client.business_id = v_biz limit 1;
    v_link := gen_random_uuid();
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links(
      id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
    ) values(v_link,v_biz,v_identity,v_member,v_client,'verified','email_claim',now());
    perform set_config('app.customer_link_insert_id','',true);
  end loop;

  -- A published reward catalogue for the points firm and the stamps firm, so the catalog reader
  -- has something to group.
  foreach v_biz in array array[v_points_biz,v_stamps_biz,v_both_biz] loop
    v_config := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
    values(v_config,v_biz,1,'published',now());
    update public.businesses set active_config_version_id=v_config where id=v_biz;
    v_reward := gen_random_uuid();
    insert into public.loyalty_rewards(id,business_id,name,cost_points,credit_cents,active,sort)
    values(v_reward,v_biz,'V310 free drink',50,0,true,1);
    insert into public.loyalty_reward_versions(
      reward_id,business_id,config_version_id,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort
    ) values(v_reward,v_biz,v_config,'v310 internal','V310 free drink',
             'manual_item',50,0,0,true,1);
  end loop;

  -- ================= 1. capabilities: additive shape, BEFORE anything is flipped =============
  perform pg_temp.as_v310_user(v_member);
  v_caps := public.customer_portal_capabilities(v_points_slug);
  perform pg_temp.as_v310_system();

  insert into v310_out values(1,'capabilities_additive_shape',
    case when pg_temp.v310_keys(v_caps - 'programmes' - 'programmes_contract')
              = v_expected_caps_keys
          and v_caps->>'programmes_contract' = 'v310'
          and jsonb_typeof(v_caps->'programmes') = 'array'
          and jsonb_array_length(v_caps->'programmes') = 4
          and (select bool_and(entry->>'balance_scope' = 'business_pot')
                 from jsonb_array_elements(v_caps->'programmes') entry)
          and (select array_agg(entry->>'kind' order by ord)
                 from jsonb_array_elements(v_caps->'programmes')
                      with ordinality as e(entry,ord))
              = array['points','tiers','stamps','referral']
      then 'PASS pre-v310 keys byte-stable ('||array_to_string(v_expected_caps_keys,',')
             ||'); programmes[4] in spine sort order, all business_pot'
      else 'FAIL keys='||array_to_string(
             pg_temp.v310_keys(v_caps - 'programmes' - 'programmes_contract'),',')
             ||' contract='||coalesce(v_caps->>'programmes_contract','null')
             ||' programmes='||coalesce(v_caps->'programmes','null'::jsonb)::text end);

  -- ================= 2. programmes[] active/visibility comes from the SPINE ==================
  insert into v310_out values(2,'capabilities_programmes_mirror_the_spine',
    case when (pg_temp.v310_programme(v_caps,'points')->>'active')::boolean
              = (select spine.active from public.business_programmes spine
                  where spine.id = pg_temp.v310_spine(v_points_biz,'points'))
          and (pg_temp.v310_programme(v_caps,'referral')->>'active')::boolean
              = (select spine.active from public.business_programmes spine
                  where spine.id = pg_temp.v310_spine(v_points_biz,'referral'))
          and (pg_temp.v310_programme(v_caps,'points')->>'active')::boolean
          and (pg_temp.v310_programme(v_caps,'referral')->>'active')::boolean
          and not (pg_temp.v310_programme(v_caps,'tiers')->>'active')::boolean
          and not (pg_temp.v310_programme(v_caps,'stamps')->>'active')::boolean
          and pg_temp.v310_programme(v_caps,'points')->>'running_since' is not null
          -- referral customer_visible is the SPINE ALONE: the referral card still renders only
          -- from customer_get_referral_card_v300's {enabled:true}, so there is one truth for
          -- referral presentation, not two.
          and (pg_temp.v310_programme(v_caps,'referral')->>'customer_visible')::boolean
              = (pg_temp.v310_programme(v_caps,'referral')->>'active')::boolean
      then 'PASS active/breadcrumbs read from public.business_programmes; referral visibility '
             ||'is the spine alone'
      else 'FAIL '||coalesce(v_caps->'programmes','null'::jsonb)::text end);

  -- ============ 3. the BINDING cross-check, proved in BOTH directions on two tenants =========
  perform pg_temp.as_v310_user(v_member);
  v_caps_both := public.customer_portal_capabilities(v_both_slug);
  perform pg_temp.as_v310_system();

  insert into v310_out values(3,'capabilities_cross_check_invariant',
    case when (pg_temp.v310_programme(v_caps,'points')->>'customer_visible')::boolean
              = (v_caps->>'rewards')::boolean
          and (pg_temp.v310_programme(v_caps,'tiers')->>'customer_visible')::boolean
              = (v_caps->>'tiers')::boolean
          and (pg_temp.v310_programme(v_caps_both,'points')->>'customer_visible')::boolean
              = (v_caps_both->>'rewards')::boolean
          and (pg_temp.v310_programme(v_caps_both,'tiers')->>'customer_visible')::boolean
              = (v_caps_both->>'tiers')::boolean
          -- and the two tenants really do answer differently, or the equality is vacuous
          and (v_caps->>'tiers')::boolean is distinct from (v_caps_both->>'tiers')::boolean
      then 'PASS points<->rewards and tiers<->tiers agree on both tenants; the ''redeem'' firm '
             ||'says tiers='||(v_caps->>'tiers')||' and the ''both'' firm says tiers='
             ||(v_caps_both->>'tiers')
      else 'FAIL redeem='||v_caps::text||' both='||v_caps_both::text end);

  -- ================= 4. reward catalog: additive + derived grouping ==========================
  perform pg_temp.as_v310_user(v_member);
  v_catalog := public.customer_get_reward_catalog(v_points_slug);
  begin
    v_catalog_stamps := public.customer_get_reward_catalog(v_stamps_slug);
  exception when others then
    v_catalog_stamps := jsonb_build_object('error', sqlerrm);
  end;
  perform pg_temp.as_v310_system();

  insert into v310_out values(4,'catalog_additive_and_derived_grouping',
    case when pg_temp.v310_keys(
                v_catalog - 'programmes' - 'programmes_contract' - 'balance_scope')
              = v_expected_catalog_keys
          and v_catalog->>'balance_scope' = 'business_pot'
          and v_catalog->>'programmes_contract' = 'v310'
          and jsonb_array_length(v_catalog->'programmes') = 1
          and v_catalog->'programmes'->0->>'kind' = 'points'
          and v_catalog->'programmes'->0->>'balance_scope' = 'business_pot'
          -- ONE aggregation, referenced twice: the flat and grouped views cannot drift.
          and v_catalog->'programmes'->0->'rewards' = v_catalog->'rewards'
          and jsonb_array_length(v_catalog->'rewards') = 1
          and coalesce(v_catalog_stamps->'programmes'->0->>'kind','') = 'stamps'
          and v_catalog_stamps->'programmes'->0->'rewards' = v_catalog_stamps->'rewards'
      then 'PASS rewards/points_mode byte-stable; grouping derived points at the classic firm '
             ||'and stamps at the stamps firm, from the same v_result'
      else 'FAIL points='||v_catalog::text||' stamps='||coalesce(v_catalog_stamps::text,'null')
        end);

  -- ================= 5. tier payload: additive shape ========================================
  perform pg_temp.as_v310_user(v_member);
  v_tier := public.customer_get_effective_tier_v143(v_tiers_biz);
  perform pg_temp.as_v310_system();

  insert into v310_out values(5,'tier_payload_additive_shape',
    case when pg_temp.v310_keys((v_tier->'tier') - 'tier_fuel' - 'balance_scope')
              = v_expected_tier_keys
          and v_tier->'tier'->>'tier_fuel' = 'points_programme_earn'
          and v_tier->'tier'->>'balance_scope' = 'business_pot'
      then 'PASS pre-v310 tier keys byte-stable; tier_fuel and balance_scope added'
      else 'FAIL keys='||array_to_string(
             pg_temp.v310_keys((v_tier->'tier') - 'tier_fuel' - 'balance_scope'),',')
             ||' payload='||v_tier::text end);

  -- ============ 6. D1: a SWITCHED firm's tier metric counts ONLY points-programme earns ======
  -- 120 points earned while the firm ran POINTS, then the model flips to stamps: the offsetting
  -- row and the new earn land on the STAMPS programme (V309's currentness gap, by design).
  v_sale := pg_temp.v310_sale(v_switch_biz, v_switch_client, 12000);
  perform pg_temp.v310_earn(v_switch_biz, v_switch_client, v_sale, 120);

  update public.loyalty_programs
     set loyalty_model='stamps', stamp_target=8, stamp_per_cents=1000
   where business_id = v_switch_biz;

  -- an OFFSETTING row (sale_id null — the exact shape the gap is defined over) ...
  perform pg_temp.v310_earn(v_switch_biz, v_switch_client, null, -50, 'redeem');
  -- ... and a stamps-era earn.
  v_sale := pg_temp.v310_sale(v_switch_biz, v_switch_client, 4000);
  perform pg_temp.v310_earn(v_switch_biz, v_switch_client, v_sale, 30);

  select coalesce(sum(ledger.points),0)::integer into v_business_pot
    from public.points_ledger ledger
   where ledger.business_id = v_switch_biz and ledger.client_id = v_switch_client;
  select coalesce(sum(ledger.points),0)::integer into v_points_only
    from public.points_ledger ledger
   where ledger.business_id = v_switch_biz and ledger.client_id = v_switch_client
     and ledger.entry_type = 'earn'
     and ledger.programme_id = pg_temp.v310_spine(v_switch_biz,'points');

  perform pg_temp.as_v310_user(v_member);
  v_tier := public.customer_get_effective_tier_v143(v_switch_biz);
  perform pg_temp.as_v310_system();
  v_metric_143 := (v_tier->'tier'->>'metric')::numeric;
  v_metric_gate := app.v176_tier_gate_metric(v_switch_biz, v_switch_client);

  insert into v310_out values(6,'d1_tier_metric_counts_only_points_programme_earns',
    case when v_metric_143 = v_points_only and v_points_only = 120
          and v_metric_gate = v_points_only
          and v_metric_143 <> (select coalesce(sum(ledger.points),0)
                                 from public.points_ledger ledger
                                where ledger.business_id = v_switch_biz
                                  and ledger.client_id = v_switch_client
                                  and ledger.entry_type = 'earn')
      then 'PASS metric='||v_metric_143||' = points-programme earns only; the stamps-era earn '
             ||'is excluded and the business-wide earn sum would have been '
             ||(select coalesce(sum(ledger.points),0) from public.points_ledger ledger
                 where ledger.business_id = v_switch_biz and ledger.client_id = v_switch_client
                   and ledger.entry_type = 'earn')
      else 'FAIL v143='||v_metric_143||' gate='||v_metric_gate
             ||' points_only='||v_points_only end);

  -- ============ 7. THE FAIL-OPEN BRANCH — the highest-severity line in the wave =============
  -- Reaching the reader's NULL branch needs a firm whose points spine row is DELETABLE, and the
  -- v309 FK is ON DELETE RESTRICT while public.points_ledger is append-only (no UPDATE can
  -- re-point a tag — app.forbid_mutation refuses it, correctly). So this fixture earns with an
  -- EXPLICITLY supplied programme_id (the v309 trigger never overrides one), leaving the points
  -- spine row unreferenced. Before the delete the D1 filter therefore reads 0 — no points-tagged
  -- earn exists — and after the delete all three twins must fall back to the UNFILTERED lifetime
  -- sum. A zero after the delete is the silent tier wipe this branch exists to prevent.
  v_sale := pg_temp.v310_sale(v_failopen_biz, v_failopen_client, 9000);
  perform pg_temp.v310_earn(v_failopen_biz, v_failopen_client, v_sale, 90, 'earn',
                            pg_temp.v310_spine(v_failopen_biz,'stamps'));

  perform pg_temp.as_v310_user(v_member);
  v_tier := public.customer_get_effective_tier_v143(v_failopen_biz);
  v_presentation := public.customer_get_business_presentation_v95(v_failopen_biz, null, 'en');
  perform pg_temp.as_v310_system();
  v_metric_before := (v_tier->'tier'->>'metric')::numeric;
  v_gate_before := app.v176_tier_gate_metric(v_failopen_biz, v_failopen_client);
  v_pres_before := (v_presentation->'programme'->'tier'->'current'->>'metric')::numeric;

  -- The spine is a DERIVED projection with no browser write path; this deletion happens as the
  -- table owner inside a rolled-back transaction purely to reach the reader's NULL branch.
  delete from public.business_programmes
   where business_id = v_failopen_biz and kind = 'points';

  perform pg_temp.as_v310_user(v_member);
  v_tier := public.customer_get_effective_tier_v143(v_failopen_biz);
  v_presentation := public.customer_get_business_presentation_v95(v_failopen_biz, null, 'en');
  perform pg_temp.as_v310_system();
  v_metric_after := (v_tier->'tier'->>'metric')::numeric;
  v_gate_after := app.v176_tier_gate_metric(v_failopen_biz, v_failopen_client);
  v_pres_after := (v_presentation->'programme'->'tier'->'current'->>'metric')::numeric;

  insert into v310_out values(7,'fail_open_missing_points_spine_row_does_not_zero_a_tier',
    case when v_metric_after = 90 and v_gate_after = 90 and v_pres_after = 90
          and v_metric_before = 0 and v_gate_before = 0 and v_pres_before = 0
      then 'PASS with the points spine row absent all three twins fell back to the UNFILTERED '
             ||'lifetime earn sum (90); with it present and no points-tagged earn they read 0, '
             ||'so the fallback demonstrably fired rather than the filter being a no-op'
      else 'FAIL before v143/gate/presentation='||coalesce(v_metric_before::text,'null')
             ||'/'||coalesce(v_gate_before::text,'null')||'/'||coalesce(v_pres_before::text,'null')
             ||' after='||coalesce(v_metric_after::text,'null')
             ||'/'||coalesce(v_gate_after::text,'null')||'/'||coalesce(v_pres_after::text,'null')
             ||' (a zero after the delete is the silent tier wipe this branch exists to prevent)'
        end);

  -- ============ 8. the detector reports the split firm, and ONLY the split firm ==============
  select * into v_detected from app.detect_programme_pot_split_v310()
   where business_id = v_switch_biz;
  select count(*) into v_detected_others from app.detect_programme_pot_split_v310()
   where business_id in (v_points_biz,v_tiers_biz,v_stamps_biz,v_both_biz);
  -- The step-7 fixture deliberately carries a tag the resolver would not produce, so the detector
  -- MUST report it too — with distinct_tags=1. That is the whole reason V309 migration assertion
  -- (b) is not carried forward: tag-disagrees-with-resolver is a finding here, not a failure.
  select * into v_detected_off from app.detect_programme_pot_split_v310()
   where business_id = v_failopen_biz;

  insert into v310_out values(8,'detector_reports_the_split_firm_only',
    case when v_detected.business_id = v_switch_biz
          and v_detected.distinct_tags = 2
          and v_detected.rows_off_current = 1
          and v_detected.negative_tag_pots = 1
          and v_detected_others = 0
          and v_detected_off.distinct_tags = 1
          and v_detected_off.rows_off_current = 1
          and app.programme_pot_is_split_v310(v_switch_biz)
          and not app.programme_pot_is_split_v310(v_points_biz)
          and not app.programme_pot_is_split_v310(v_failopen_biz)
      then 'PASS switched firm reported distinct_tags='||v_detected.distinct_tags
             ||' rows_off_current='||v_detected.rows_off_current
             ||' negative_tag_pots='||v_detected.negative_tag_pots
             ||'; the off-resolver fixture is reported as distinct_tags=1 '
             ||'rows_off_current='||v_detected_off.rows_off_current
             ||' (a finding, not a failure — V309 assertion (b) is deliberately not carried '
             ||'forward); the four clean fixtures are silent'
      else 'FAIL detected='||coalesce(v_detected.business_id::text,'none')
             ||' distinct_tags='||coalesce(v_detected.distinct_tags::text,'null')
             ||' others='||v_detected_others end);

  -- ============ 9. TWIN PARITY across the basis x model matrix, and the fourth twin =========
  -- Seeded BEFORE the loop: parity asserted on all-zero metrics would be vacuous. `visits` stays
  -- structurally 0 because every fixture sale is written counts_as_visit=false (the v106/v300
  -- idiom that keeps the live app.on_sale_recorded out of this transaction); `spend` and
  -- `points_earned` are non-zero, which is where the D1 change actually lives.
  v_sale := pg_temp.v310_sale(v_tiers_biz, v_tiers_client, 5000);
  perform pg_temp.v310_earn(v_tiers_biz, v_tiers_client, v_sale, 40);

  foreach v_basis in array array['visits','spend','points_earned'] loop
    foreach v_model in array array['classic','points_tiers','stamps'] loop
      update public.loyalty_programs
         set tier_basis = v_basis, loyalty_model = v_model,
             stamp_target = case when v_model='stamps' then 8 end,
             stamp_per_cents = case when v_model='stamps' then 1000 end
       where business_id = v_tiers_biz;

      perform pg_temp.as_v310_user(v_member);
      v_tier := public.customer_get_effective_tier_v143(v_tiers_biz);
      v_presentation := public.customer_get_business_presentation_v95(v_tiers_biz, null, 'en');
      perform pg_temp.as_v310_system();
      v_metric_143 := (v_tier->'tier'->>'metric')::numeric;
      v_metric_gate := app.v176_tier_gate_metric(v_tiers_biz, v_tiers_client);
      v_metric_pres :=
        coalesce((v_presentation->'programme'->'tier'->'current'->>'metric')::numeric, -1);

      if v_metric_143 is distinct from v_metric_gate
         or (v_metric_pres <> -1 and v_metric_pres is distinct from v_metric_143) then
        v_matrix_fail := v_matrix_fail||' '||v_basis||'/'||v_model||'='
          ||coalesce(v_metric_143::text,'null')||'/'||coalesce(v_metric_gate::text,'null')
          ||'/'||coalesce(v_metric_pres::text,'null');
      else
        v_matrix := v_matrix||' '||v_basis||'/'||v_model||'='||coalesce(v_metric_143::text,'null');
      end if;
    end loop;
  end loop;

  -- Restore the tiers fixture and give it a points-programme earn plus a foreign-programme earn,
  -- so the fourth twin's deliberate divergence is observable rather than vacuous.
  update public.loyalty_programs
     set tier_basis='points_earned', loyalty_model='points_tiers',
         stamp_target=null, stamp_per_cents=null
   where business_id = v_tiers_biz;
  v_sale := pg_temp.v310_sale(v_tiers_biz, v_tiers_client, 5000);
  perform pg_temp.v310_earn(v_tiers_biz, v_tiers_client, v_sale, 7, 'earn',
                            pg_temp.v310_spine(v_tiers_biz,'stamps'));

  perform pg_temp.as_v310_user(v_member);
  v_tier := public.customer_get_effective_tier_v143(v_tiers_biz);
  perform pg_temp.as_v310_system();
  v_metric_143 := (v_tier->'tier'->>'metric')::numeric;
  v_metric_gate := app.v176_tier_gate_metric(v_tiers_biz, v_tiers_client);
  select coalesce((app.loyalty_tier_for(v_tiers_biz, v_tiers_client)).threshold, -1)
    into v_metric_tier_for;

  insert into v310_out values(9,'tier_metric_twin_parity_and_the_deliberate_fourth_divergence',
    case when v_matrix_fail = ''
          and v_metric_143 = 40 and v_metric_gate = 40
          -- app.loyalty_tier_for still sums the WHOLE ledger (40 + 7 = 47), so it places the
          -- member on Silver-or-above by an unfiltered metric. It is the EARN multiplier
          -- (app.on_sale_recorded calls it) and is W5's named target; the assertion here is that
          -- it is STILL unfiltered, i.e. that this wave did not touch it.
          and (select coalesce(sum(ledger.points),0) from public.points_ledger ledger
                where ledger.business_id = v_tiers_biz and ledger.client_id = v_tiers_client
                  and ledger.entry_type='earn') = 47
          and v_metric_tier_for >= 0
      then 'PASS matrix parity'||v_matrix||'; scoped twins read 40 while the unfiltered ledger '
             ||'earn sum is 47, and app.loyalty_tier_for still resolves on the unfiltered sum '
             ||'(W5 target)'
      else 'FAIL matrix mismatches:'||coalesce(nullif(v_matrix_fail,''),'none')
             ||' v143='||v_metric_143||' gate='||v_metric_gate
             ||' tier_for_threshold='||coalesce(v_metric_tier_for::text,'null') end);

  -- ============ 10/11. the identity-only readers: wallet and loyalty details =================
  perform pg_temp.as_v310_user(v_member);
  v_wallet := public.customer_get_wallet();
  v_details := public.customer_get_loyalty_details(v_stamps_slug);
  perform pg_temp.as_v310_system();

  select entry into v_card from jsonb_array_elements(v_wallet) entry
   where entry->'business'->>'slug' = v_stamps_slug;

  insert into v310_out values(10,'wallet_programme_identity_only',
    case when pg_temp.v310_keys(v_card->'loyalty') = v_expected_loyalty_keys
          and v_card->'programme'->>'kind' = 'stamps'
          and v_card->'programme'->>'balance_scope' = 'business_pot'
          and (v_card->'programme'->>'active')::boolean
              = (select spine.active from public.business_programmes spine
                  where spine.id = pg_temp.v310_spine(v_stamps_biz,'stamps'))
          and (v_card->'loyalty'->>'balance')::integer
              = coalesce((select sum(ledger.points)::integer from public.points_ledger ledger
                           where ledger.business_id = v_stamps_biz
                             and ledger.client_id = v_stamps_client),0)
      then 'PASS loyalty{} keys unchanged, programme identity added, balance still the business pot'
      else 'FAIL card='||coalesce(v_card::text,'null') end);

  insert into v310_out values(11,'loyalty_details_programme_identity_only',
    case when v_details->>'model' = 'stamps'
          and v_details->>'unit' = 'stamps'
          and v_details->'programme'->>'kind' = 'stamps'
          and v_details->'programme'->>'balance_scope' = 'business_pot'
          and (v_details->>'balance')::integer
              = coalesce((select sum(ledger.points)::integer from public.points_ledger ledger
                           where ledger.business_id = v_stamps_biz
                             and ledger.client_id = v_stamps_client),0)
          and v_details ? 'expiry' and v_details ? 'items'
      then 'PASS model/unit/balance/expiry/items unchanged, programme identity added'
      else 'FAIL details='||coalesce(v_details::text,'null') end);

  -- ============ 12. owner liability: total byte-identical, per-tag suppressed when split =====
  v_insights := app.v179_business_insights(
    v_switch_biz, (now()-interval '30 days')::date, now()::date,
    (now()-interval '60 days')::date, (now()-interval '31 days')::date);
  v_overview := app.v177_overview(v_points_biz, null);

  insert into v310_out values(12,'liability_total_byte_identical_and_split_suppression',
    case when (v_insights->'loyalty'->>'points_outstanding_total')::numeric
              = coalesce((select sum(ledger.points) from public.points_ledger ledger
                           where ledger.business_id = v_switch_biz),0)
          and (v_insights->'loyalty'->>'pot_is_split')::boolean
          and jsonb_typeof(v_insights->'loyalty'->'points_outstanding_by_programme_tag') = 'null'
          and (v_overview->'outstanding'->>'points')::numeric
              = coalesce((select sum(ledger.points) from public.points_ledger ledger
                           where ledger.business_id = v_points_biz),0)
          and not (v_overview->'outstanding'->>'pot_is_split')::boolean
          and jsonb_typeof(v_overview->'outstanding'->'points_outstanding_by_programme_tag')
              = 'array'
      then 'PASS totals unchanged; the split firm''s per-tag array is NULL (never partial) and '
             ||'the single-pot firm gets an array'
      else 'FAIL insights='||(v_insights->'loyalty')::text
             ||' overview='||(v_overview->'outstanding')::text end);

  -- ============ 13. programme usage: earner count scoped, stamp_card added ===================
  -- The stamps tenant earns under its stamps programme; a points-programme row is planted so
  -- "scoped" cannot be confused with "there was only ever one kind of row".
  v_sale := pg_temp.v310_sale(v_stamps_biz, v_stamps_client, 3000);
  perform pg_temp.v310_earn(v_stamps_biz, v_stamps_client, v_sale, 3);
  v_sale := pg_temp.v310_sale(v_stamps_biz, v_stamps_client, 3000);
  perform pg_temp.v310_earn(v_stamps_biz, v_stamps_client, v_sale, 5, 'earn',
                            pg_temp.v310_spine(v_stamps_biz,'points'));

  perform pg_temp.as_v310_user(v_owner);
  v_usage := public.business_programme_usage_v271(v_stamps_biz);
  v_insights := public.business_programme_usage_v271(v_points_biz);
  perform pg_temp.as_v310_system();

  insert into v310_out values(13,'usage_v271_scoped_to_the_spine_plus_stamp_card',
    case when (v_usage->'point_system'->>'customers')::int = 1
          and (v_usage->'stamp_card'->>'customers')::int = 1
          and jsonb_typeof(v_insights->'stamp_card'->'customers') = 'null'
          and (v_insights->'point_system'->>'customers')::int = 0
          -- v273's null-when-never-set-up rule must survive the splice
          and jsonb_typeof(v_insights->'birthday'->'customers') = 'null'
          and jsonb_typeof(v_insights->'promotions'->'customers') = 'null'
      then 'PASS stamps tenant: point_system counts the planted points-programme earner and '
             ||'stamp_card counts the stamp earner; the classic firm reports stamp_card null '
             ||'and keeps v273''s birthday/promotions nulls'
      else 'FAIL stamps='||v_usage::text||' points='||v_insights::text end);

  -- ============ 14. ACL floor ================================================================
  select has_function_privilege('anon','app.detect_programme_pot_split_v310()','execute'),
         has_function_privilege('authenticated','app.detect_programme_pot_split_v310()','execute'),
         has_function_privilege('service_role','app.detect_programme_pot_split_v310()','execute')
    into v_anon, v_auth, v_service;

  insert into v310_out values(14,'acl_floor',
    case when not v_anon and not v_auth and v_service
          and not has_function_privilege('anon','app.programme_pot_is_split_v310(uuid)','execute')
          and not has_function_privilege(
                'authenticated','app.programme_pot_is_split_v310(uuid)','execute')
          and has_function_privilege(
                'service_role','app.programme_pot_is_split_v310(uuid)','execute')
          and not has_function_privilege(
                'anon','public.customer_portal_capabilities(text)','execute')
          and has_function_privilege(
                'authenticated','public.customer_portal_capabilities(text)','execute')
          and not has_function_privilege(
                'anon','public.customer_get_reward_catalog(text)','execute')
          and has_function_privilege(
                'authenticated','public.customer_get_reward_catalog(text)','execute')
          and not has_function_privilege(
                'anon','public.business_programme_usage_v271(uuid)','execute')
          and has_function_privilege(
                'authenticated','public.business_programme_usage_v271(uuid)','execute')
      then 'PASS the two v310 functions are service_role-only; the six customer/owner readers '
             ||'kept their anon=false / authenticated=true floor through create-or-replace'
      else 'FAIL detector anon='||v_anon||' authenticated='||v_auth||' service_role='||v_service
        end);
end
$v310_test$;

reset role;

select seq, step, outcome from v310_out order by seq;

rollback;
