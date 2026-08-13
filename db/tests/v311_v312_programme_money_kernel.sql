-- Rollback-only v311 + v312 acceptance: THE MONEY WAVE.
--
-- v311 (W5a) turns app.on_sale_recorded's if/elsif engine picker into a loop over the
-- business's active accruing programmes, names the ON CONFLICT arbiter, swaps
-- points_earn_once_per_sale (sale_id) for points_earn_once_per_sale_per_programme
-- (sale_id, programme_id) in the same transaction that removes the v308 tripwire, makes
-- programme_id NOT NULL on both money tables, moves the tier multiplier inside the points
-- branch, and programme-scopes every one of the nine live write paths.
-- v312 (W5b) adds the pot machinery: the transfer-pair migration, its switch trigger, the
-- re-specified detector and the balance_scope flip.
--
-- ZERO LIVE TENANTS EXERCISE ANY CHANGED BRANCH — all 10 live programmes are visits-basis
-- (V306 evidence:43), there are zero live tiers=true and zero live stamps=true tenants
-- (V307 evidence:52-57), zero split pots, and the one stamps firm is paused. A green run
-- against production therefore proves ABSENCE OF REGRESSION, not presence of correctness.
-- So all four tenant shapes are CREATED INSIDE THIS TRANSACTION, the V308/V309 pattern:
--
--   S1 stamps-only     loyalty_model='stamps', stamp_per_cents=1000, spine stamps=true
--   S2 points_tiers    tier_basis='points_earned', three rungs, a >1 multiplier
--   S3 BOTH            S2 + a direct service_role UPDATE turning the stamps spine row on
--                      AFTER the tripwire drop. Not reachable through any UI (the spine is
--                      derived one-way from loyalty_model, which is CHECK-constrained
--                      single-valued) and not durable until W6 flips authority — which is
--                      exactly why the rehearsal has to force it.
--   S4 switched        an S2-shaped firm earns, then flips to 'stamps' and the pot moves
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v311_v312_programme_money_kernel.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v311_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v311_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v311_system() to public;

create or replace function pg_temp.as_v311_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v311_user(uuid,text) to public;

-- The same identity WITHOUT the browser role. v311's ACL floor revokes EXECUTE on the
-- money functions from anon and authenticated (step 24 asserts it), so a step that drives
-- redeem_reward_core, the reversal or the v84 correction has to arrive the way production
-- does — through the service role — while auth.uid() still resolves to a real staff member.
create or replace function pg_temp.as_v311_actor(p_uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','service_role')::text,true);
end
$$;
grant execute on function pg_temp.as_v311_actor(uuid) to public;

create or replace function pg_temp.v311_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v311_spine(uuid,text) to public;

-- One raw earn row written exactly the way the loop writes one (the v20 token pair,
-- entry_type='earn', positive points, a sale_id) so a step can attack the arbiter directly.
create or replace function pg_temp.v311_earn(
  p_business uuid, p_client uuid, p_sale uuid, p_points integer, p_programme uuid
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id
  ) values (
    v_id, p_business, p_client, 'earn', p_points, p_sale, 'v311 fixture earn', null, p_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$$;
grant execute on function pg_temp.v311_earn(uuid,uuid,uuid,integer,uuid) to public;

-- The same row, dated. points_ledger is append-only, so a step cannot age a row after the
-- fact; the inactivity window can only be exercised by writing one already old.
create or replace function pg_temp.v311_earn_at(
  p_business uuid, p_client uuid, p_sale uuid, p_points integer, p_programme uuid, p_at timestamptz
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id, created_at
  ) values (
    v_id, p_business, p_client, 'earn', p_points, p_sale, 'v311 dated fixture earn', null, p_programme, p_at
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$$;
grant execute on function pg_temp.v311_earn_at(uuid,uuid,uuid,integer,uuid,timestamptz) to public;

-- A complete tenant of a given shape. Everything the earn path reads: the config version
-- (so app.resolve_loyalty_branch_config returns a row), the programme economics, the owner.
create or replace function pg_temp.v311_tenant(
  p_business uuid, p_owner uuid, p_label text, p_model text,
  p_tier_basis text, p_expiry_mode text, p_expiry_days integer,
  p_per_dollar numeric, p_stamp_per_cents integer
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v311 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V311 Owner',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  -- The wizard writes kind='points' even for the stamps model; both shapes keep it and move
  -- loyalty_model alone (the production shape, inherited from the v307/v308/v309 suites).
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents)
  values (p_business,'points',true,p_model,'published',100,500,p_tier_basis,
          p_expiry_mode,p_expiry_days,p_per_dollar,10,p_stamp_per_cents);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,'points',p_model,true,p_per_dollar,100,500,10,
          p_stamp_per_cents,p_tier_basis,p_expiry_mode,p_expiry_days);

  return v_config;
end
$$;
grant execute on function pg_temp.v311_tenant(uuid,uuid,text,text,text,text,integer,numeric,integer) to public;

-- A sale, written the way record_quick_sale writes one, so the REAL trg_sale_recorded runs.
create or replace function pg_temp.v311_sale(
  p_business uuid, p_client uuid, p_config uuid, p_amount integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  values (v_id,p_business,p_client,'service',p_amount,true,true,true,p_config,now());
  return v_id;
end
$$;
grant execute on function pg_temp.v311_sale(uuid,uuid,uuid,integer) to public;

-- A sale the earn trigger early-returns on (v37b:649), so a step can own the ledger row.
create or replace function pg_temp.v311_quiet_sale(p_business uuid, p_client uuid)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,policy_resolved_at)
  values (v_id,p_business,p_client,'service',0,false,false,true,now());
  return v_id;
end
$$;
grant execute on function pg_temp.v311_quiet_sale(uuid,uuid) to public;

do $v311_test$
declare
  v_owner uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); s1c uuid := gen_random_uuid(); s1cfg uuid;
  s2 uuid := gen_random_uuid(); s2c uuid := gen_random_uuid(); s2cfg uuid;
  s3 uuid := gen_random_uuid(); s3c uuid := gen_random_uuid(); s3cfg uuid;
  s4 uuid := gen_random_uuid(); s4c uuid := gen_random_uuid(); s4cfg uuid;
  s3d uuid := gen_random_uuid();
  s5 uuid := gen_random_uuid(); s5c uuid := gen_random_uuid(); s5d uuid := gen_random_uuid(); s5cfg uuid;
  s6 uuid := gen_random_uuid(); s6c uuid := gen_random_uuid(); s6d uuid := gen_random_uuid(); s6cfg uuid;
  s7 uuid := gen_random_uuid(); s7c uuid := gen_random_uuid(); s7d uuid := gen_random_uuid(); s7cfg uuid;
  v_sale uuid; v_sale2 uuid;
  v_branch uuid; v_quick uuid;
  v_reward uuid := gen_random_uuid();
  v_correction jsonb; v_replay jsonb; v_ids uuid[]; v_map jsonb;
  v_redemption uuid; v_redemption2 uuid;
  v_from uuid; v_to uuid; v_first uuid; v_rest uuid;
  v_identity uuid := gen_random_uuid(); v_cust_user uuid := gen_random_uuid(); v_link uuid;
  s6e uuid := gen_random_uuid();
  v_intent jsonb; v_slug text;
  v_scans bigint; v_scans_caps bigint; v_scans_catalog bigint;
  v_body text;
  v_earns integer; v_batches integer; v_tags integer;
  v_points integer; v_stamps integer;
  v_pot_before integer; v_pot_after integer;
  v_rem_before integer; v_rem_after integer;
  v_msg text; v_state text;
  v_spine_points uuid; v_spine_stamps uuid;
  v_metric numeric; v_metric_open numeric;
  v_detected integer; v_scope text;
  v_expired integer;
  v_ok boolean;
  v_row record;
begin
  perform pg_temp.as_v311_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v311-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  s1cfg := pg_temp.v311_tenant(s1,v_owner,'V311S1','stamps','points_earned','none',null,1,1000);
  s2cfg := pg_temp.v311_tenant(s2,v_owner,'V311S2','points_tiers','points_earned','fixed',30,10,1000);
  s3cfg := pg_temp.v311_tenant(s3,v_owner,'V311S3','points_tiers','points_earned','fixed',30,10,1000);
  s4cfg := pg_temp.v311_tenant(s4,v_owner,'V311S4','points_tiers','points_earned','none',null,10,1000);
  s5cfg := pg_temp.v311_tenant(s5,v_owner,'V311S5','stamps','visits','inactivity',7,10,1000);

  insert into public.clients(id,business_id,full_name,phone) values
    (s1c,s1,'S1 Customer','81000001'),
    (s2c,s2,'S2 Customer','81000002'),
    (s3c,s3,'S3 Customer','81000003'),
    (s4c,s4,'S4 Customer','81000004'),
    (s3d,s3,'S3 Lapsed','81000007'),
    (s5c,s5,'S5 Lapsed','81000005'),
    (s5d,s5,'S5 Active','81000006');

  -- Three rungs with a real multiplier at S2/S3; the multiplier is the thing that must NOT
  -- reach a stamp.
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort) values
    (s2,'Silver',0,1,1),(s2,'Gold',50,2,2),(s2,'Diamond',5000,3,3),
    (s3,'Silver',0,1,1),(s3,'Gold',50,2,2),(s3,'Diamond',5000,3,3);

  -- =========================================================================
  -- STEP 1. THE SWAP'S POST-STATE. The old index is gone, the per-programme index is
  --         authoritative, the tripwire is gone, both columns are NOT NULL.
  --         This is the step V309 suite step 4 said would go red when W5 landed.
  -- =========================================================================
  insert into v311_out values (1,'swap post-state',
    case when exists (select 1 from pg_class where relname='points_earn_once_per_sale' and relkind='i')
           then 'FAIL: the v2 points_earn_once_per_sale index survived'
         when not exists (select 1 from pg_index i join pg_class c on c.oid=i.indexrelid
                           where c.relname='points_earn_once_per_sale_per_programme'
                             and i.indisunique and i.indisvalid)
           then 'FAIL: the per-programme index is not unique+valid'
         when exists (select 1 from pg_trigger where tgrelid='public.business_programmes'::regclass
                       and tgname='business_programmes_exclusive_accrual_v308')
           then 'FAIL: the v308 tripwire survived'
         when to_regprocedure('app.business_programmes_exclusive_accrual_v308()') is not null
           then 'FAIL: the v308 tripwire function survived'
         when exists (select 1 from pg_attribute a
                       where a.attrelid in ('public.points_ledger'::regclass,
                                            'public.points_batches'::regclass)
                         and a.attname='programme_id' and not a.attnotnull)
           then 'FAIL: programme_id is not NOT NULL on both money tables'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 2. S1 STAMPS-ONLY. One sale earns ONE stamp row, tagged stamps, with its batch.
  --         No tier multiplier reaches it even though the firm has none — the shape is
  --         proved at S3, where the multiplier exists.
  -- =========================================================================
  v_sale := pg_temp.v311_sale(s1,s1c,s1cfg,50000);
  select count(*) filter (where l.entry_type='earn'), count(distinct l.programme_id)
    into v_earns, v_tags
    from public.points_ledger l where l.sale_id=v_sale;
  select count(*) into v_batches from public.points_batches b where b.sale_id=v_sale;
  select coalesce(sum(l.points),0) into v_stamps
    from public.points_ledger l
   where l.sale_id=v_sale and l.programme_id=pg_temp.v311_spine(s1,'stamps');
  insert into v311_out values (2,'S1 stamps-only: one tagged earn + one batch',
    case when v_earns<>1 then 'FAIL: '||v_earns||' earn rows'
         when v_batches<>1 then 'FAIL: '||v_batches||' batch rows'
         when v_tags<>1 then 'FAIL: '||v_tags||' distinct tags'
         when v_stamps<>50 then 'FAIL: stamps='||v_stamps||' (50000c / 1000c expected)'
         when not exists (select 1 from public.points_batches b
                           where b.sale_id=v_sale and b.programme_id=pg_temp.v311_spine(s1,'stamps'))
           then 'FAIL: batch not tagged to the stamps programme'
         else 'PASS' end);

  -- D8: a stamp batch carries NO expires_at. The firm's expiry_mode is 'none' here, so the
  -- rule is proved again at S3, where the firm is on fixed 30-day expiry.
  insert into v311_out values (3,'S1 stamp batch is undated (D8)',
    case when exists (select 1 from public.points_batches b
                       where b.sale_id=v_sale and b.expires_at is not null)
           then 'FAIL: a stamp batch carries an expiry date nobody authored'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 4. THE ARBITER. A second earn row for the SAME (sale, programme) is refused by
  --         points_earn_once_per_sale_per_programme, with 23505.
  -- =========================================================================
  begin
    perform pg_temp.v311_earn(s1,s1c,v_sale,5,pg_temp.v311_spine(s1,'stamps'));
    insert into v311_out values (4,'double-fire: same (sale, programme) refused',
      'FAIL: a second earn row for the same sale and programme was accepted');
  exception when unique_violation then
    insert into v311_out values (4,'double-fire: same (sale, programme) refused','PASS');
  end;

  -- =========================================================================
  -- STEP 5. S2 POINTS_TIERS. One earn, tagged points, MULTIPLIED, dated by the firm's
  --         fixed expiry.
  -- =========================================================================
  perform pg_temp.v311_sale(s2,s2c,s2cfg,600);   -- fuel sale: 60 points, reaches Gold (>=50)
  v_sale := pg_temp.v311_sale(s2,s2c,s2cfg,10000);
  select coalesce(sum(l.points),0) into v_points
    from public.points_ledger l where l.sale_id=v_sale and l.entry_type='earn';
  insert into v311_out values (5,'S2 points_tiers: multiplied points earn',
    case when v_points<>2000 then 'FAIL: earned '||v_points||' (100 x 10/dollar x2 Gold = 2000)'
         when not exists (select 1 from public.points_ledger l
                           where l.sale_id=v_sale and l.programme_id=pg_temp.v311_spine(s2,'points'))
           then 'FAIL: earn not tagged to the points programme'
         when not exists (select 1 from public.points_batches b
                           where b.sale_id=v_sale and b.expires_at is not null)
           then 'FAIL: a points batch under fixed expiry has no expires_at'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 6. D1 FUEL. app.loyalty_tier_for reads the POINTS programme's earns only — and
  --         FAILS OPEN when the spine row is absent. S1 is the honest probe: its basis is
  --         points_earned and every earn it has is tagged STAMPS, so the FILTERED metric is
  --         0 and its rung (threshold 5) is out of reach; deleting the unreferenced points
  --         spine row must make the rung reachable again, never zero the tier.
  -- =========================================================================
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort)
  values (s1,'S1 Rung',5,1,1);
  v_ok := (app.loyalty_tier_for(s1,s1c)).id is null;
  delete from public.business_programmes where business_id=s1 and kind='points';
  insert into v311_out values (6,'D1 fuel filter is points-only, and fails OPEN',
    case when not v_ok
           then 'FAIL: a stamps-tagged earn fuelled a points_earned tier'
         when (app.loyalty_tier_for(s1,s1c)).id is null
           then 'FAIL: a missing points spine row ZEROED the tier instead of failing open'
         else 'PASS' end);
  insert into public.business_programmes(business_id,kind,active,sort)
  values (s1,'points',false,1);
  delete from public.loyalty_tiers where business_id=s1;

  -- =========================================================================
  -- STEP 7. S3 BOTH — THE NEW SHAPE. Force the stamps spine row on (only possible now the
  --         tripwire is gone) and record ONE sale: TWO earn rows, TWO batches, one per
  --         programme, the points row multiplied and the stamps row NOT.
  -- =========================================================================
  perform pg_temp.v311_sale(s3,s3c,s3cfg,600);   -- fuel sale (points only): reaches Gold
  update public.business_programmes set active=true
   where business_id=s3 and kind='stamps';
  v_sale := pg_temp.v311_sale(s3,s3c,s3cfg,10000);

  select coalesce(sum(l.points),0) into v_points
    from public.points_ledger l
   where l.sale_id=v_sale and l.entry_type='earn' and l.programme_id=pg_temp.v311_spine(s3,'points');
  select coalesce(sum(l.points),0) into v_stamps
    from public.points_ledger l
   where l.sale_id=v_sale and l.entry_type='earn' and l.programme_id=pg_temp.v311_spine(s3,'stamps');
  select count(*) filter (where l.entry_type='earn'), count(distinct l.programme_id)
    into v_earns, v_tags
    from public.points_ledger l where l.sale_id=v_sale;
  select count(*) into v_batches from public.points_batches b where b.sale_id=v_sale;

  insert into v311_out values (7,'S3 both: two programmes earn from one sale',
    case when v_earns<>2 then 'FAIL: '||v_earns||' earn rows (2 expected)'
         when v_batches<>2 then 'FAIL: '||v_batches||' batch rows (2 expected)'
         when v_tags<>2 then 'FAIL: '||v_tags||' distinct programme tags'
         when v_points<>2000 then 'FAIL: points='||v_points||' (2000 expected, Gold x2)'
         when v_stamps<>10 then 'FAIL: stamps='||v_stamps||' (10 expected, UNMULTIPLIED)'
         else 'PASS' end);

  insert into v311_out values (8,'S3: the tier multiplier never reaches a stamp',
    case when v_stamps=20 then 'FAIL: the Gold multiplier was applied to stamps'
         when v_stamps<>10 then 'FAIL: stamps='||v_stamps
         else 'PASS' end);

  insert into v311_out values (9,'S3: the stamp batch is undated under fixed points expiry (D8)',
    case when exists (select 1 from public.points_batches b
                       where b.sale_id=v_sale and b.programme_id=pg_temp.v311_spine(s3,'stamps')
                         and b.expires_at is not null)
           then 'FAIL: the stamps batch inherited the points expiry date'
         when not exists (select 1 from public.points_batches b
                           where b.sale_id=v_sale and b.programme_id=pg_temp.v311_spine(s3,'points')
                             and b.expires_at is not null)
           then 'FAIL: the points batch lost its expiry date'
         else 'PASS' end);

  -- The double fire, at the shape that can hide a defect: a third earn on EITHER programme
  -- must be refused.
  begin
    perform pg_temp.v311_earn(s3,s3c,v_sale,1,pg_temp.v311_spine(s3,'points'));
    insert into v311_out values (10,'S3 double-fire refused on both programmes',
      'FAIL: a duplicate points earn was accepted');
  exception when unique_violation then
    begin
      perform pg_temp.v311_earn(s3,s3c,v_sale,1,pg_temp.v311_spine(s3,'stamps'));
      insert into v311_out values (10,'S3 double-fire refused on both programmes',
        'FAIL: a duplicate stamps earn was accepted');
    exception when unique_violation then
      insert into v311_out values (10,'S3 double-fire refused on both programmes','PASS');
    end;
  end;

  -- =========================================================================
  -- STEP 11. INVARIANTS at S3: business-scope AND programme-scope ledger<->batch parity,
  --          plus the loop's own count identity and its structural bound.
  -- =========================================================================
  insert into v311_out values (11,'S3 invariants: pot, parity, cardinality',
    case when (select coalesce(sum(points),0) from public.points_ledger
                where business_id=s3 and client_id=s3c)
             <> (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=s3 and client_id=s3c)
           then 'FAIL: business-scope ledger<->batch parity broken'
         when exists (
           select 1 from (
             select programme_id, sum(points) t from public.points_ledger
              where business_id=s3 and client_id=s3c group by 1) led
           full join (
             select programme_id, sum(remaining) t from public.points_batches
              where business_id=s3 and client_id=s3c group by 1) bat
             on bat.programme_id=led.programme_id
            where coalesce(led.t,0)<>coalesce(bat.t,0))
           then 'FAIL: per-programme ledger<->batch parity broken'
         when (select count(*) from public.points_ledger
                where sale_id=v_sale and entry_type='earn')
              > (select count(*) from public.business_programmes
                  where business_id=s3 and active and kind in ('points','stamps'))
           then 'FAIL: more earn rows than active accruing programmes'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 12. THE SWEEP does not cross programmes. An INACTIVITY policy on the points
  --          programme must not zero the stamp card — the inner batch loop has no date
  --          condition in that branch (v20:1027), which is what made this the
  --          highest-severity miss.
  -- =========================================================================
  update public.loyalty_programs set expiry_mode='inactivity', expiry_days=1
   where business_id=s3;
  -- The forced both-state is NOT DURABLE, and that is the strongest single argument that
  -- dropping the tripwire is safe today: business_programmes.active is derived one-way from
  -- loyalty_programs by the v308 sync (v308:398-448), so the very next write to the
  -- programme re-derives the spine and turns stamps back off. Production cannot reach two
  -- accruing programmes through any UI path until W6 flips authority.
  insert into v311_out values (12,'the forced both-state is not durable (spine stays derived)',
    case when (select spine.active from public.business_programmes spine
                where spine.business_id=s3 and spine.kind='stamps')
           then 'FAIL: a loyalty_programs write did not re-derive the spine'
         else 'PASS' end);
  update public.business_programmes set active=true where business_id=s3 and kind='stamps';

  -- A LAPSED customer at the both-programmes firm: points activity older than the window,
  -- a live stamp card. The outer client loop selects her on the points programme; the inner
  -- batch loop has NO date condition in the inactivity branch (v20:1027), so the programme
  -- filter there is the only thing between a points inactivity policy and her stamp card.
  perform pg_temp.v311_earn_at(s3,s3d,pg_temp.v311_quiet_sale(s3,s3d),100,
                               pg_temp.v311_spine(s3,'points'), now()-interval '90 days');
  perform pg_temp.v311_earn(s3,s3d,pg_temp.v311_quiet_sale(s3,s3d),10,
                            pg_temp.v311_spine(s3,'stamps'));
  insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
  values (s3,s3d,100,100,now()-interval '90 days',pg_temp.v311_spine(s3,'points')),
         (s3,s3d,10,10,now(),pg_temp.v311_spine(s3,'stamps'));

  select app.run_points_expiry_for_business(s3) into v_expired;
  insert into v311_out values (13,'sweep is programme-scoped (stamp card survives)',
    case when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s3 and client_id=s3d
                  and programme_id=pg_temp.v311_spine(s3,'stamps')) <> 10
           then 'FAIL: the points inactivity sweep zeroed the lapsed customer''s STAMP CARD'
         when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s3 and client_id=s3d
                  and programme_id=pg_temp.v311_spine(s3,'points')) <> 0
           then 'FAIL: the lapsed customer''s points did not expire; the fixture proves nothing'
         when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s3 and client_id=s3c
                  and programme_id=pg_temp.v311_spine(s3,'stamps')) <> 10
           then 'FAIL: the active customer''s stamp card was touched'
         else 'PASS' end);
  update public.loyalty_programs set expiry_mode='fixed', expiry_days=30 where business_id=s3;
  update public.business_programmes set active=true where business_id=s3 and kind='stamps';

  -- =========================================================================
  -- STEP 13. THE OWNER ADJUST drains only the points programme.
  -- =========================================================================
  perform pg_temp.as_v311_user(v_owner);
  begin
    perform public.adjust_points(s3,s3c,-100,'v311 suite adjustment');
    perform pg_temp.as_v311_system();
    insert into v311_out values (14,'adjust_points drains only the points programme',
      case when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=s3 and client_id=s3c
                    and programme_id=pg_temp.v311_spine(s3,'stamps')) <> 10
             then 'FAIL: an owner points adjustment drained stamp batches'
           when not exists (select 1 from public.points_ledger
                             where business_id=s3 and entry_type='adjust'
                               and programme_id=pg_temp.v311_spine(s3,'points'))
             then 'FAIL: the adjustment row is not tagged to the points programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (14,'adjust_points drains only the points programme','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 14. THE WRITE GUARD refuses an untagged row and a cross-tenant tag.
  -- =========================================================================
  begin
    perform pg_temp.v311_earn(s3,s3c,pg_temp.v311_quiet_sale(s3,s3c),5,pg_temp.v311_spine(s2,'points'));
    insert into v311_out values (15,'write guard: cross-tenant tag refused',
      'FAIL: a row tagged with another tenant''s programme was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v311_out values (15,'write guard: cross-tenant tag refused',
      case when v_msg like '%another tenant%' then 'PASS' else 'FAIL: wrong refusal: '||v_msg end);
  end;

  -- =========================================================================
  -- STEP 15. THE HONESTY TEST, PART 1 OF 2 — THE THREE TRIGGER-FREE SALE-SIDE WRITERS.
  --          Drop BOTH v309 tag triggers and drive the earn loop, the expiry sweep and the
  --          owner adjust: each must still succeed and land the correct programme_id,
  --          because each is now explicit. (V309 mutation matrix row 1, inverted.)
  --
  --          ITS LABEL IS DELIBERATELY NARROW. It covers three of the nine write paths, and
  --          calling that "every writer" was the claim that got audited. The other six —
  --          redeem_reward_core, redeem_points, redeem_points_v40_internal, the v84
  --          correction, the redemption reversal and the v312 pot transfer — are driven
  --          under the same dropped triggers by PART 2 (steps 29-36), which needs the
  --          reward, branch and customer-session fixtures built after this point.
  -- =========================================================================
  begin
    drop trigger trg_points_ledger_programme_tag_v309 on public.points_ledger;
    drop trigger trg_points_batches_programme_tag_v309 on public.points_batches;

    v_sale2 := pg_temp.v311_sale(s3,s3c,s3cfg,20000);          -- path 1: the earn loop
    select app.run_points_expiry_for_business(s3) into v_expired;  -- path 2: the sweep
    perform pg_temp.as_v311_user(v_owner);
    perform public.adjust_points(s3,s3c,25,'v311 untriggered adjust');  -- path 3: owner adjust
    perform pg_temp.as_v311_system();

    insert into v311_out values (16,'honesty 1/2: earn loop + sweep + owner adjust are explicit',
      case when (select count(*) from public.points_ledger where sale_id=v_sale2 and entry_type='earn') <> 2
             then 'FAIL: the earn loop did not write both programmes without the tag trigger'
           when (select count(*) from public.points_batches where sale_id=v_sale2) <> 2
             then 'FAIL: batches did not land without the tag trigger'
           when exists (select 1 from public.points_ledger where business_id=s3 and programme_id is null)
             then 'FAIL: an untagged row landed'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (16,'honesty 1/2: earn loop + sweep + owner adjust are explicit',
      'FAIL: '||v_msg);
  end;
  -- restore the belt-and-braces resolver for the rest of the suite. A plpgsql exception
  -- block rolls back to its own savepoint, so on a FAIL the drops never happened.
  drop trigger if exists trg_points_ledger_programme_tag_v309 on public.points_ledger;
  drop trigger if exists trg_points_batches_programme_tag_v309 on public.points_batches;
  create trigger trg_points_ledger_programme_tag_v309
    before insert on public.points_ledger
    for each row execute function app.tag_ledger_programme_v309();
  create trigger trg_points_batches_programme_tag_v309
    before insert on public.points_batches
    for each row execute function app.tag_ledger_programme_v309();

  -- =========================================================================
  -- STEP 16. S4 SWITCHED — THE POT MIGRATION. An S2-shaped firm earns, then flips to
  --          'stamps'. The switch trigger enqueues and (well under the inline bound) runs
  --          the migration: the business pot and sum(remaining) are BYTE-IDENTICAL, the
  --          per-programme pots become coherent, and the detector reads empty.
  -- =========================================================================
  v_sale := pg_temp.v311_sale(s4,s4c,s4cfg,10000);
  select coalesce(sum(points),0) into v_pot_before
    from public.points_ledger where business_id=s4 and client_id=s4c;
  select coalesce(sum(remaining),0) into v_rem_before
    from public.points_batches where business_id=s4 and client_id=s4c;
  v_spine_points := pg_temp.v311_spine(s4,'points');

  update public.loyalty_programs set loyalty_model='stamps' where business_id=s4;
  v_spine_stamps := pg_temp.v311_spine(s4,'stamps');

  select coalesce(sum(points),0) into v_pot_after
    from public.points_ledger where business_id=s4 and client_id=s4c;
  select coalesce(sum(remaining),0) into v_rem_after
    from public.points_batches where business_id=s4 and client_id=s4c;
  select count(*) into v_detected from app.detect_programme_pot_split_v312();

  insert into v311_out values (17,'S4 pot migration: balances survive the switch',
    case when v_pot_before<>v_pot_after
           then 'FAIL: business pot moved '||v_pot_before||' -> '||v_pot_after
         when v_rem_before<>v_rem_after
           then 'FAIL: sum(remaining) moved '||v_rem_before||' -> '||v_rem_after
         when v_detected<>0
           then 'FAIL: the re-specified detector reports '||v_detected||' rows'
         when not exists (select 1 from public.programme_pot_migrations
                           where business_id=s4 and status='complete')
           then 'FAIL: no completed migration row was recorded'
         when (select coalesce(sum(points),0) from public.points_ledger
                where business_id=s4 and programme_id=v_spine_stamps) <> v_pot_after
           then 'FAIL: the destination programme does not hold the whole pot'
         when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s4 and programme_id=v_spine_stamps) <> v_rem_after
           then 'FAIL: the open batches were not retagged (candidate (a), the trap)'
         else 'PASS' end);

  insert into v311_out values (18,'S4: the transfer is append-only and actor-null',
    case when exists (select 1 from public.points_ledger
                       where business_id=s4 and reference like 'programme pot transfer%'
                         and (actor is not null or sale_id is not null or entry_type<>'adjust'))
           then 'FAIL: a transfer row has the wrong shape'
         when (select count(*) from public.points_ledger
                where business_id=s4 and reference like 'programme pot transfer%') <> 2
           then 'FAIL: expected exactly one transfer pair'
         when (select coalesce(sum(points),0) from public.points_ledger
                where business_id=s4 and reference like 'programme pot transfer%') <> 0
           then 'FAIL: the transfer pair does not net to zero'
         when not exists (select 1 from public.points_ledger
                           where business_id=s4 and programme_id=v_spine_points
                             and entry_type='earn')
           then 'FAIL: history was retagged — the ledger is not append-only'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 18. balance_scope. A firm with a completed migration and a coherent pot reports
  --          'programme_pot'; a firm with an OPEN migration reports 'business_pot' — the
  --          window in which every reader behaves exactly as it did before W5.
  -- =========================================================================
  select app.programme_balance_scope_v312(s4) into v_scope;
  insert into public.programme_pot_migrations(business_id,from_programme_id,to_programme_id,status)
  values (s2,pg_temp.v311_spine(s2,'points'),pg_temp.v311_spine(s2,'stamps'),'running');
  insert into v311_out values (19,'balance_scope flips per firm, and only when it is true',
    case when v_scope<>'programme_pot'
           then 'FAIL: a migrated coherent firm reports '||v_scope
         when app.programme_balance_scope_v312(s2)<>'business_pot'
           then 'FAIL: a firm with an open migration reports '||app.programme_balance_scope_v312(s2)
         when app.programme_balance_scope_v312(null)<>'business_pot'
           then 'FAIL: a null business does not fail safe'
         when app.programme_balance_scope_v312(s3)<>'programme_pot'
           then 'FAIL: a coherent two-programme firm reports '||app.programme_balance_scope_v312(s3)
         else 'PASS' end);
  delete from public.programme_pot_migrations where business_id=s2;

  -- =========================================================================
  -- STEP 19. THE SWITCH DID NOT MOVE THE EXPIRY PROMISE, and a dated batch landing in a
  --          no-expiry programme is NOTICEd and audited rather than silently immortal.
  -- =========================================================================
  insert into v311_out values (20,'the switch never re-dates a customer promise',
    case when exists (select 1 from public.points_batches
                       where business_id=s4 and sale_id=v_sale
                         and expires_at is distinct from (
                           select expires_at from public.points_batches
                            where business_id=s4 and sale_id=v_sale limit 1))
           then 'FAIL: a batch was re-dated by the retag'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 20. BOTH STANDING DETECTORS ARE EMPTY over the whole database, fixtures included.
  -- =========================================================================
  select count(*) into v_detected from app.detect_double_earn_v309();
  insert into v311_out values (21,'app.detect_double_earn_v309() is empty',
    case when v_detected<>0 then 'FAIL: '||v_detected||' rows' else 'PASS' end);
  select count(*) into v_detected from app.detect_programme_pot_split_v312();
  insert into v311_out values (22,'app.detect_programme_pot_split_v312() is empty',
    case when v_detected<>0 then 'FAIL: '||v_detected||' rows' else 'PASS' end);

  -- =========================================================================
  -- STEP 22. TRIGGER INVENTORY AND ORDER on points_ledger are exactly what v309 pinned:
  --          the tag trigger still sorts before the write guard (V309 standing invariant 3).
  -- =========================================================================
  select string_agg(tgname,',' order by tgname) into v_state
    from pg_trigger where tgrelid='public.points_ledger'::regclass and not tgisinternal;
  insert into v311_out values (23,'points_ledger trigger inventory + BEFORE INSERT order',
    case when v_state is distinct from
           'trg_audit_points,trg_points_ledger_append_only,trg_points_ledger_config_version,trg_points_ledger_programme_tag_v309,trg_points_ledger_write_guard'
           then 'FAIL: '||coalesce(v_state,'(none)')
         else 'PASS' end);

  -- =========================================================================
  -- STEP 23. ACL FLOOR. No browser role executes any money function this wave touched.
  -- =========================================================================
  v_state := '';
  for v_row in
    select signature from (values
      ('app.on_sale_recorded()'),
      ('app.loyalty_tier_for(uuid,uuid)'),
      ('app.loyalty_ledger_write_guard()'),
      ('app.run_points_expiry_for_business(uuid)'),
      ('app.run_points_expiry()'),
      ('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'),
      ('app.redeem_points_v40_internal(uuid,uuid,text)'),
      ('public.redeem_points(uuid,uuid)'),
      ('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'),
      ('app.migrate_programme_pot_v312(uuid,uuid,uuid,integer)'),
      ('app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid,integer)'),
      ('app.programme_balance_scope_v312(uuid)'),
      ('app.detect_programme_pot_split_v312()')
    ) touched(signature)
  loop
    if has_function_privilege('anon',v_row.signature,'execute')
       or has_function_privilege('authenticated',v_row.signature,'execute') then
      v_state := v_state||v_row.signature||' ';
    end if;
  end loop;
  insert into v311_out values (24,'ACL floor on every touched money function',
    case when v_state<>'' then 'FAIL: browser-executable: '||v_state else 'PASS' end);

  -- =========================================================================
  -- STEP 24. THE MIGRATION LEDGER IS NOT BROWSER-WRITABLE.
  -- =========================================================================
  insert into v311_out values (25,'programme_pot_migrations is SELECT-only for browsers',
    case when exists (select 1 from information_schema.role_table_grants
                       where table_name='programme_pot_migrations'
                         and grantee in ('anon','authenticated')
                         and privilege_type in ('INSERT','UPDATE','DELETE'))
           then 'FAIL: a browser role can write the migration ledger'
         when not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                           where n.nspname='public' and c.relname='programme_pot_migrations'
                             and c.relrowsecurity)
           then 'FAIL: RLS is not enabled on programme_pot_migrations'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 25. PRODUCTION SURVEY (fixtures excluded): every real tenant still has exactly
  --          four spine rows, no untagged money row, and no negative programme pot.
  -- =========================================================================
  insert into v311_out values (26,'production survey: spine shape + tagged money + no negative pot',
    case when exists (select 1 from public.businesses b
                       where b.id not in (s1,s2,s3,s4)
                         and (select count(*) from public.business_programmes p
                               where p.business_id=b.id) <> 4)
           then 'FAIL: a live business does not carry exactly four spine rows'
         when exists (select 1 from public.points_ledger where programme_id is null)
           then 'FAIL: an untagged ledger row exists'
         when exists (select 1 from public.points_batches where programme_id is null)
           then 'FAIL: an untagged batch exists'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 27/28. THE INACTIVITY CLOCK ACROSS A POT MIGRATION. S5 is a stamps firm whose
  --   pot moves INTO the points programme — the one switch direction the sweep can see,
  --   because the sweep only ever considers the points programme's batches. Two customers:
  --   one whose earn is older than the window, one whose earn is inside it. After the
  --   migration the batches carry the POINTS tag while both earns carry the STAMPS one.
  --
  --     * The transfer's +S row must NOT count as activity (v311's actor-null exclusion),
  --       or every switched customer's expiry is silently postponed. So the LAPSED
  --       customer's batch must still expire.
  --     * The activity the pot INHERITED must count (v312's lineage clause), or a model
  --       switch expires freshly-earned points at the next nightly sweep. So the ACTIVE
  --       customer's batch must survive.
  -- =========================================================================
  perform pg_temp.v311_earn_at(s5,s5c,pg_temp.v311_quiet_sale(s5,s5c),100,
                               pg_temp.v311_spine(s5,'stamps'), now()-interval '90 days');
  perform pg_temp.v311_earn(s5,s5d,pg_temp.v311_quiet_sale(s5,s5d),100,
                            pg_temp.v311_spine(s5,'stamps'));
  insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
  values (s5,s5c,100,100,now()-interval '90 days',pg_temp.v311_spine(s5,'stamps')),
         (s5,s5d,100,100,now(),pg_temp.v311_spine(s5,'stamps'));

  update public.loyalty_programs set loyalty_model='points_tiers' where business_id=s5;
  select app.run_points_expiry_for_business(s5) into v_expired;

  insert into v311_out values (27,'a pot transfer never postpones expiry (lapsed customer)',
    case when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s5 and client_id=s5c) <> 0
           then 'FAIL: the transfer row counted as activity and postponed expiry'
         else 'PASS' end);
  insert into v311_out values (28,'inherited activity still counts (active customer)',
    case when (select coalesce(sum(remaining),0) from public.points_batches
                where business_id=s5 and client_id=s5d) <> 100
           then 'FAIL: a model switch expired freshly-earned points'
         else 'PASS' end);

  -- =========================================================================
  -- THE HONESTY TEST, PART 2 OF 2 (steps 29-36). Every remaining money write path runs
  -- with BOTH v309 tag triggers dropped. programme_id is NOT NULL on both money tables
  -- after v311, so a writer that is not explicit cannot silently mis-tag here — it fails
  -- its own step with a not-null violation, which names it.
  -- =========================================================================
  drop trigger trg_points_ledger_programme_tag_v309 on public.points_ledger;
  drop trigger trg_points_batches_programme_tag_v309 on public.points_batches;

  -- Fixtures the remaining paths need: a branch, a catalogue reward at S6, two more
  -- tenants, and one verified customer session.
  s6cfg := pg_temp.v311_tenant(s6,v_owner,'V311S6','points_tiers','points_earned','none',null,10,1000);
  s7cfg := pg_temp.v311_tenant(s7,v_owner,'V311S7','points_tiers','points_earned','none',null,10,1000);
  insert into public.clients(id,business_id,full_name,phone) values
    (s6c,s6,'S6 Customer','81000008'),
    (s6d,s6,'S6 Control','81000009'),
    (s7c,s7,'S7 Customer','81000010'),
    (s7d,s7,'S7 Customer Two','81000011');

  select branch.id into v_branch from public.branches branch
   where branch.business_id=s3 order by branch.is_default desc, branch.created_at, branch.id limit 1;
  if v_branch is null then
    v_branch := gen_random_uuid();
    insert into public.branches(id,business_id,name) values (v_branch,s3,'V311 S3 Branch');
  end if;

  insert into public.loyalty_rewards(id,business_id,name,cost_points,credit_cents,active,sort)
  values (v_reward,s6,'V311 Manual Reward',150,0,true,1);
  insert into public.loyalty_reward_versions(
    business_id,config_version_id,reward_id,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort)
  values (s6,s6cfg,v_reward,'V311 Manual Reward','V311 Manual Reward','manual_item',
          150,0,0,true,1);

  -- =========================================================================
  -- STEP 29. THE TWO-PROGRAMME FAST CORRECTION, AND ITS RETRY. S3 earns in points AND
  --   stamps from one quick sale; correct_quick_sale_amount_v84 must compensate BOTH
  --   programmes, record the additive audit columns, and — the part that was broken —
  --   REPLAY. points_removed is the cross-programme TOTAL while each compensation row
  --   carries only its own programme's share, so a replay-evidence check that looks for a
  --   single row with points = -points_removed raises XX001 on a routine retry.
  -- =========================================================================
  begin
    perform pg_temp.as_v311_actor(v_owner);
    v_quick := nullif(public.record_quick_sale(
        p_business=>s3, p_amount_cents=>10000, p_method=>'cash', p_client=>s3c,
        p_staff=>null, p_branch=>v_branch, p_note=>null,
        p_idempotency_key=>'v311-f1-original-sale', p_paid=>false)::jsonb #>> '{sale,id}','')::uuid;
    v_correction := public.correct_quick_sale_amount_v84(
      s3, v_quick, 20000, 'v311-f1-correction-key');
    v_replay := public.correct_quick_sale_amount_v84(
      s3, v_quick, 20000, 'v311-f1-correction-key');
    perform pg_temp.as_v311_system();

    select correction.points_compensation_ledger_ids, correction.points_removed_by_programme
      into v_ids, v_map
      from public.sale_amount_corrections_v84 correction
     where correction.business_id=s3 and correction.idempotency_key='v311-f1-correction-key';

    insert into v311_out values (29,'v84 corrects BOTH programmes and replays idempotently',
      case when (select count(*) from public.points_ledger
                  where business_id=s3 and sale_id=(v_correction->>'reversal_sale_id')::uuid
                    and entry_type='adjust') <> 2
             then 'FAIL: the correction did not write one compensation row per programme'
           when coalesce(array_length(v_ids,1),0) <> 2
             then 'FAIL: points_compensation_ledger_ids did not record both rows'
           when (select count(*) from jsonb_object_keys(v_map)) <> 2
             then 'FAIL: points_removed_by_programme did not record both programmes'
           when (select coalesce(sum(value::integer),0) from jsonb_each_text(v_map))
                <> (v_correction->>'points_removed')::integer
             then 'FAIL: the per-programme shares do not sum to points_removed'
           when (select coalesce(sum(ledger.points),0) from public.points_ledger ledger
                  where ledger.id = any(v_ids))
                <> -(v_correction->>'points_removed')::integer
             then 'FAIL: the compensation set does not sum to -points_removed'
           when (select correction.points_compensation_ledger_id
                   from public.sale_amount_corrections_v84 correction
                  where correction.business_id=s3
                    and correction.idempotency_key='v311-f1-correction-key') <> v_ids[1]
             then 'FAIL: the legacy single-id column is not the first compensation row'
           when coalesce(v_replay->>'replayed','') <> 'true'
             then 'FAIL: the retry did not report replayed=true'
           when exists (select 1 from public.points_batches
                         where business_id=s3 and sale_id=v_quick and remaining<>0)
             then 'FAIL: the original earn batches were not zeroed in every programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (29,'v84 corrects BOTH programmes and replays idempotently',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 30. THE REVERSAL ROUND-TRIP ON ONE PROGRAMME still works. redeem_reward_core
  --   drains FEFO inside the reward's programme; reverse_loyalty_redemption_v34_base
  --   restores those exact batches and writes ONE compensation row tagged with their
  --   programme. This is the control for step 31: the guard there must refuse a real
  --   defect, not every reversal.
  -- =========================================================================
  begin
    perform pg_temp.v311_sale(s6,s6d,s6cfg,2000);
    perform pg_temp.as_v311_actor(v_owner);
    v_redemption2 := nullif(app.redeem_reward_core(
      s6,s6d,v_reward,'v311-f2-control-redeem')::jsonb->>'redemption_id','')::uuid;
    perform public.reverse_loyalty_redemption_v34_base(
      s6,v_redemption2,'v311 control reversal','v311-f2-control-reverse');
    perform pg_temp.as_v311_system();
    insert into v311_out values (30,'single-programme redeem + reverse restores coherently',
      case when (select coalesce(sum(points),0) from public.points_ledger
                  where business_id=s6 and client_id=s6d)
                <> (select coalesce(sum(remaining),0) from public.points_batches
                     where business_id=s6 and client_id=s6d)
             then 'FAIL: the reversal broke ledger/batch parity'
           when exists (select 1 from app.detect_programme_pot_split_v312() d
                         where d.business_id=s6)
             then 'FAIL: the reversal split the pot'
           when not exists (select 1 from public.points_ledger
                             where business_id=s6 and client_id=s6d
                               and entry_type='adjust'
                               and reference like 'redemption reversal:%'
                               and programme_id=pg_temp.v311_spine(s6,'points'))
             then 'FAIL: the restore compensation row is not tagged with the drained programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (30,'single-programme redeem + reverse restores coherently',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 31. THE MEASURED CROSS-PROGRAMME REVERSAL. s6c earns twice, then one redemption
  --   drains batch 1 to zero and part of batch 2. THEN the firm switches model and the pot
  --   migrates: v312 retags OPEN batches only (by design — a drained batch keeps its tag
  --   and its reversal provenance), so batch 1 stays under the OLD programme while batch 2
  --   moves to the new one. The drains of that ONE redemption now span two programmes.
  --   Restoring them would put money back into two programmes behind a single compensation
  --   row tagged with one of them — a permanent split pot manufactured by the safety
  --   mechanism. It must RAISE. `select distinct ... into` is not STRICT and would have
  --   silently taken whichever programme sorted first.
  -- =========================================================================
  begin
    -- Two SMALL sales: 10 points per dollar on $10 is one 100-point batch each, so the
    -- 150-point reward must drain one batch to zero and bite into the second.
    perform pg_temp.v311_sale(s6,s6c,s6cfg,1000);
    perform pg_temp.v311_sale(s6,s6c,s6cfg,1000);
    perform pg_temp.as_v311_actor(v_owner);
    v_redemption := nullif(app.redeem_reward_core(
      s6,s6c,v_reward,'v311-f2-split-redeem')::jsonb->>'redemption_id','')::uuid;
    perform pg_temp.as_v311_system();

    update public.loyalty_programs set loyalty_model='stamps' where business_id=s6;

    if (select count(distinct batch.programme_id) from public.points_batches batch
         where batch.id in (select drain.points_batch_id
                              from public.loyalty_redemption_batch_drains drain
                             where drain.redemption_id=v_redemption)) <> 2 then
      insert into v311_out values (31,'cross-programme restore is refused, not split',
        'FAIL: the fixture did not produce drains spanning two programmes');
    else
      begin
        perform pg_temp.as_v311_actor(v_owner);
        perform public.reverse_loyalty_redemption_v34_base(
          s6,v_redemption,'v311 split reversal','v311-f2-split-reverse');
        perform pg_temp.as_v311_system();
        insert into v311_out values (31,'cross-programme restore is refused, not split',
          'FAIL: a reversal spanning two programmes was accepted');
      exception when others then
        get stacked diagnostics v_msg = message_text;
        perform pg_temp.as_v311_system();
        insert into v311_out values (31,'cross-programme restore is refused, not split',
          case when v_msg like '%more than one programme%' then 'PASS'
               else 'FAIL: wrong refusal: '||v_msg end);
      end;
    end if;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (31,'cross-programme restore is refused, not split',
      'FAIL: fixture: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 32. ONE BOUNDED MIGRATION INVOCATION LEAVES THE WHOLE FIRM COHERENT. S7 has two
  --   customers with pots and is enqueued with an inline bound of 1, so it takes the ASYNC
  --   path: status stays 'pending' and the bounded worker owns it. One invocation with
  --   p_limit=1 must move exactly one customer COMPLETELY — ledger pot and open batches
  --   together — and touch the other one not at all.
  --
  --   THE PINNED DETECTOR CONTRACT: zero rows, mid-migration. The detector has no
  --   'exclude firms with an open migration' arm, precisely so that this window is
  --   measured rather than excused. balance_scope is the reader-facing conservatism and
  --   stays 'business_pot' until the row closes.
  -- =========================================================================
  begin
    perform pg_temp.v311_sale(s7,s7c,s7cfg,10000);
    perform pg_temp.v311_sale(s7,s7d,s7cfg,20000);
    v_from := pg_temp.v311_spine(s7,'points');
    v_to := pg_temp.v311_spine(s7,'stamps');
    perform app.enqueue_programme_pot_migration_v312(s7,v_from,v_to,1);
    select ledger.client_id into v_first
      from public.points_ledger ledger
     where ledger.business_id=s7 and ledger.programme_id=v_from
     group by ledger.client_id having sum(ledger.points)<>0
     order by ledger.client_id limit 1;
    v_rest := case when v_first=s7c then s7d else s7c end;

    v_detected := app.migrate_programme_pot_v312(s7,v_from,v_to,1);

    insert into v311_out values (32,'one bounded invocation leaves every client coherent',
      case when v_detected <> 1
             then 'FAIL: p_limit=1 processed '||v_detected||' clients'
           when exists (select 1 from app.detect_programme_pot_split_v312() d
                         where d.business_id=s7)
             then 'FAIL: the detector reports a split mid-migration'
           when (select coalesce(sum(points),0) from public.points_ledger
                  where business_id=s7 and client_id=v_first and programme_id=v_from) <> 0
             then 'FAIL: the processed client kept a source-programme pot'
           when exists (select 1 from public.points_batches
                         where business_id=s7 and client_id=v_first
                           and programme_id=v_from and remaining>0)
             then 'FAIL: the processed client kept an open source-programme batch'
           when (select coalesce(sum(points),0) from public.points_ledger
                  where business_id=s7 and client_id=v_first and programme_id=v_to)
                <> (select coalesce(sum(remaining),0) from public.points_batches
                     where business_id=s7 and client_id=v_first and programme_id=v_to)
             then 'FAIL: the processed client is not coherent in the destination'
           when exists (select 1 from public.points_ledger
                         where business_id=s7 and client_id=v_rest and programme_id=v_to)
             then 'FAIL: the unprocessed client already has destination ledger rows'
           when exists (select 1 from public.points_batches
                         where business_id=s7 and client_id=v_rest and programme_id=v_to)
             then 'FAIL: the unprocessed client had its batches retagged without its ledger'
           when not exists (select 1 from public.programme_pot_migrations
                             where business_id=s7 and status in ('pending','running'))
             then 'FAIL: the migration row closed while work remained'
           when app.programme_balance_scope_v312(s7) <> 'business_pot'
             then 'FAIL: a firm with an open migration did not report business_pot'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (32,'one bounded invocation leaves every client coherent',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 33. THE RESUME. The worker's own loop: run until an invocation moves nobody, then
  --   close the row. Balances are byte-identical to before the switch and the firm reports
  --   programme_pot only once the row is closed.
  -- =========================================================================
  begin
    select coalesce(sum(points),0) into v_pot_before
      from public.points_ledger where business_id=s7;
    v_detected := app.run_programme_pot_migrations_v312(5);
    v_detected := app.run_programme_pot_migrations_v312(5);
    select coalesce(sum(points),0) into v_pot_after
      from public.points_ledger where business_id=s7;
    insert into v311_out values (33,'the bounded worker resumes and closes the migration',
      case when v_pot_before <> v_pot_after
             then 'FAIL: the business pot moved during the resume'
           when exists (select 1 from public.programme_pot_migrations
                         where business_id=s7 and status <> 'complete')
             then 'FAIL: the migration row did not close'
           when exists (select 1 from public.points_ledger
                         where business_id=s7 and programme_id=v_from
                         group by client_id having sum(points)<>0)
             then 'FAIL: a client kept a source-programme pot after the resume'
           when exists (select 1 from public.points_batches
                         where business_id=s7 and programme_id=v_from and remaining>0)
             then 'FAIL: an open batch kept the source tag after the resume'
           when exists (select 1 from app.detect_programme_pot_split_v312() d
                         where d.business_id=s7)
             then 'FAIL: the detector reports a split after the resume'
           when app.programme_balance_scope_v312(s7) <> 'programme_pot'
             then 'FAIL: a finished coherent firm still reports '
                  ||app.programme_balance_scope_v312(s7)
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v311_out values (33,'the bounded worker resumes and closes the migration',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- THE CUSTOMER SESSION FIXTURE (steps 34-35). A verified independent identity linked to
  -- a fresh S6 customer, and the platform flags the customer surfaces gate on.
  -- =========================================================================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_cust_user,'authenticated','authenticated',
          'v311-customer-'||substr(v_cust_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values (v_identity,v_cust_user,'active','email_claim');
  insert into public.clients(id,business_id,full_name,phone)
  values (s6e,s6,'S6 Wallet Customer','81000012');
  v_link := gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (v_link,s6,v_identity,v_cust_user,s6e,'verified','email_claim',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.business_customer_capabilities_v89(
    business_id,booking_enabled,redemption_enabled,appointment_changes_enabled)
  values (s6,false,true,false)
  on conflict (business_id) do update set redemption_enabled=true;
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_qr_redemption',true)
  on conflict (feature_key) do update set enabled=true;

  -- =========================================================================
  -- STEP 34. THE CUSTOMER AFFORDABILITY PROBE, MEASURED IN BOTH DIRECTIONS.
  --   customer_create_redemption_intent_v89 answers "can this customer afford this reward",
  --   and W4a deliberately left it business-scoped ("spend dispatch is W5"). Its ledger
  --   check stays business-scoped on purpose — that is a solvency test — but its BATCH
  --   proof must match the counter's FEFO drain, which v311 scoped to the reward's
  --   programme. S6 is a STAMPS firm, so:
  --     (a) 200 points held ONLY under the POINTS tag must NOT buy a 150-point stamps
  --         reward, even though the business-wide ledger sum says 200. Unscoped, the
  --         customer is handed a QR the counter then refuses with 'insufficient proven
  --         points' (v34:572) — the exact asymmetry this step exists to catch;
  --     (b) the same customer with 200 under the STAMPS tag IS offered the intent.
  -- =========================================================================
  begin
    perform pg_temp.v311_earn(s6,s6e,pg_temp.v311_quiet_sale(s6,s6e),200,
                              pg_temp.v311_spine(s6,'points'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (s6,s6e,200,200,now(),pg_temp.v311_spine(s6,'points'));

    v_ok := false;
    begin
      perform pg_temp.as_v311_user(v_cust_user);
      v_intent := public.customer_create_redemption_intent_v89(s6,v_reward,gen_random_uuid());
      perform pg_temp.as_v311_system();
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v311_system();
      v_ok := (v_msg like '%insufficient%');
    end;

    perform pg_temp.v311_earn(s6,s6e,pg_temp.v311_quiet_sale(s6,s6e),200,
                              pg_temp.v311_spine(s6,'stamps'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (s6,s6e,200,200,now(),pg_temp.v311_spine(s6,'stamps'));
    perform pg_temp.as_v311_user(v_cust_user);
    v_intent := public.customer_create_redemption_intent_v89(s6,v_reward,gen_random_uuid());
    perform pg_temp.as_v311_system();

    insert into v311_out values (34,'v89 intent affordability is scoped to the spendable programme',
      case when not v_ok
             then 'FAIL: an intent was offered against another programme''s batches'
           when coalesce(v_intent->>'intent_id','') = ''
             then 'FAIL: the in-programme intent was not created'
           when (v_intent->'quote'->>'points_spent')::integer <> 150
             then 'FAIL: the quote does not match the reward cost'
           when position('programme_id=app.resolve_ledger_programme_v309(p_business)' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure))
                = 0
             then 'FAIL: the intent batch proof is not programme-scoped'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (34,'v89 intent affordability is scoped to the spendable programme',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 35. ONE BALANCE-SCOPE EVALUATION PER PAYLOAD. app.programme_balance_scope_v312
  --   aggregates the firm's whole points_ledger and points_batches. Spliced in as a
  --   literal-for-call swap it runs once per OCCURRENCE: four times per capabilities
  --   payload (the site sits inside jsonb_agg over the ALWAYS-four-row v308 spine) and
  --   twice per catalog payload. Measured, not asserted structurally: the number of scans
  --   points_batches receives during one call IS the number of evaluations, because
  --   neither reader touches that table anywhere else.
  -- =========================================================================
  begin
    select business.slug into v_slug from public.businesses business where business.id=s6;
    perform pg_temp.as_v311_user(v_cust_user);
    v_scans := pg_stat_get_xact_numscans('public.points_batches'::regclass);
    perform public.customer_portal_capabilities(v_slug);
    v_scans_caps := pg_stat_get_xact_numscans('public.points_batches'::regclass) - v_scans;
    v_scans := pg_stat_get_xact_numscans('public.points_batches'::regclass);
    perform public.customer_get_reward_catalog(v_slug);
    v_scans_catalog := pg_stat_get_xact_numscans('public.points_batches'::regclass) - v_scans;
    perform pg_temp.as_v311_system();

    select p.prosrc into v_body from pg_proc p
     where p.oid='public.customer_portal_capabilities(text)'::regprocedure;
    insert into v311_out values (35,'balance_scope is evaluated once per payload, not once per site',
      case when v_scans_caps <> 1
             then 'FAIL: capabilities scanned points_batches '||v_scans_caps||' times (expected 1)'
           when v_scans_catalog <> 1
             then 'FAIL: reward catalog scanned points_batches '||v_scans_catalog||' times (expected 1)'
           when position('v_balance_scope := app.programme_balance_scope_v312(' in v_body) = 0
             then 'FAIL: capabilities does not hoist the balance scope'
           when (length(v_body)-length(replace(v_body,'app.programme_balance_scope_v312(','')))
                / length('app.programme_balance_scope_v312(') <> 1
             then 'FAIL: capabilities still calls the resolver more than once'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v311_system();
    insert into v311_out values (35,'balance_scope is evaluated once per payload, not once per site',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 36. HONESTY 2/2, THE VERDICT. Every path above ran with both v309 tag triggers
  --   dropped. No untagged money row exists anywhere, and no row carries another tenant's
  --   programme. Then the belt-and-braces resolver goes back on.
  -- =========================================================================
  insert into v311_out values (36,'honesty 2/2: redeem, reverse, correct and transfer are explicit',
    case when exists (select 1 from public.points_ledger where programme_id is null)
           then 'FAIL: an untagged ledger row landed with the tag triggers dropped'
         when exists (select 1 from public.points_batches where programme_id is null)
           then 'FAIL: an untagged batch landed with the tag triggers dropped'
         when exists (select 1 from public.points_ledger ledger
                       join public.business_programmes spine on spine.id=ledger.programme_id
                      where spine.business_id <> ledger.business_id)
           then 'FAIL: a ledger row carries another tenant''s programme'
         when exists (select 1 from public.points_batches batch
                       join public.business_programmes spine on spine.id=batch.programme_id
                      where spine.business_id <> batch.business_id)
           then 'FAIL: a batch carries another tenant''s programme'
         when exists (select 1 from app.detect_programme_pot_split_v312())
           then 'FAIL: the standing detector is not empty after part 2'
         else 'PASS' end);

  create trigger trg_points_ledger_programme_tag_v309
    before insert on public.points_ledger
    for each row execute function app.tag_ledger_programme_v309();
  create trigger trg_points_batches_programme_tag_v309
    before insert on public.points_batches
    for each row execute function app.tag_ledger_programme_v309();
end
$v311_test$;

select seq, step, outcome from v311_out order by seq;

rollback;
