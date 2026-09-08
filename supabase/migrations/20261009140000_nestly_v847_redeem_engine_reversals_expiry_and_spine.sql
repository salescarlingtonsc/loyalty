-- NESTLY v847 — the redemption engine and the availability core stop disagreeing with the rest
-- of the estate about three things: a REVERSED claim, a STOPPED programme, and EXPIRED points.
--
-- Two functions change: app.redeem_reward_core (the counter — what
-- public.staff_manual_redeem_reward_v404 calls once per unit) and app.reward_availability_v432
-- (the one catalogue every reward reader goes through). Nothing else is touched.
--
-- ============================================================================================
-- (A) LATENT, P1 — a reversed redemption permanently burned a usage-limit slot
-- ============================================================================================
-- app.redeem_reward_core counted prior claims with
--     select count(*) from public.loyalty_redemptions where business_id/client_id/reward_id
-- and app.reward_availability_v432's `used_count` lateral (present in BOTH arms) did the same.
-- Neither body contained the string 'loyalty_redemption_reversals'. So a limit-1 gift that was
-- claimed and then reversed — public.reverse_loyalty_redemption_v34_base refunds the points in
-- full and writes public.loyalty_redemption_reversals — still read `limit_reached` for ever.
-- The customer was refunded AND locked out of a gift they never received.
--
-- MEASURED ON PRODUCTION, read-only, inside a rolled-back transaction (2026-09-08), on a scratch
-- firm with a 10-point limit-1 gift and a 30-point balance:
--     claim            -> ok, batch 30 -> 20, catalogue limit_reached / used_count 1
--     reverse          -> restored_points 10, batch back to 30, one reversals row
--     catalogue AFTER  -> FAIL: availability=limit_reached used_count=1
--     claim AFTER      -> FAIL: 23514 'reward usage limit reached'
-- Latent only because production carries ZERO reward versions with a usage_limit (measured the
-- same day), which is why the acceptance suite sets one in its own rolled-back fixture.
--
-- THE FIX. `v_usage` keeps its existing meaning — the count of every redemption ever recorded —
-- because it is stored on the new row as `usage_number` and this migration deliberately changes
-- no stored value. A NEW variable, `v_usage_live`, counts only claims that carry no reversal
-- row, and it is `v_usage_live` the usage_limit is now measured against. The catalogue's
-- `used_count` moves to the same definition, so the number staff read and the gate the counter
-- applies are once again the same number.
--
-- ============================================================================================
-- (B) LIVE, P2 — a stopped stamps programme still paid out
-- ============================================================================================
-- The spine gate read
--     if v_programme_kind is distinct from 'stamps'
--        and not exists(select 1 from public.business_programmes spine
--                        where spine.id=v_reward_programme and spine.active)
--     then raise exception 'catalog redemption is inactive'; end if;
-- — stamps were EXEMPT. nestly_v495 had already withdrawn a stopped programme's gifts from
-- app.reward_availability_v432 and from public.customer_create_redemption_intent_v89, and said
-- so in its own header: "app.redeem_reward_core (the staff-assisted path) is untouched." This is
-- that gap. Production carries 22 inactive stamp spines with 5 live gifts on them (2026-09-08).
--
-- MEASURED ON PRODUCTION, same rolled-back transaction: with the stamps spine switched off the
-- catalogue listed the gift NOT AT ALL and app.redeem_reward_core completed the claim anyway
-- (`catalogue=<not listed> counter_err=-/-`). The fix deletes the exemption, so both halves of
-- the estate now answer identically.
--
-- WHAT IS DELIBERATELY PRESERVED, and proven by the verification block and the acceptance suite:
--   * nestly_v478 — a gift ALREADY EARNED on a card that has since closed stays claimable while
--     the programme runs. That survival path is inside the stamps branch, downstream of this
--     gate, and is untouched; assertion 11 of the suite claims exactly such a survivor and
--     passes.
--   * nestly_v495 — "nothing is destroyed by a stop ... every gift returns the moment the
--     programme is switched back on". Assertion 13 switches the spine back on and claims the
--     same survivor successfully. A stop WITHHOLDS; it does not destroy.
--   * nestly_v568 — the survivor arm's `live.programme_id = sc.programme_id` predicate is not
--     touched, and is asserted still present below.
-- The rule this migration lands is "a stopped programme mints and pays nothing NEW", which is
-- exactly nestly_v495's rule, now applied to the staff path it explicitly left alone.
--
-- ============================================================================================
-- (C) LIVE, P2 — expired points were spendable
-- ============================================================================================
-- app.reward_availability_v432's `pot` CTE filtered only `pb.remaining > 0`, and
-- app.redeem_reward_core's pre-flight `v_batch_balance`, its FEFO drain loop and its post-drain
-- reconcile fence carried no expiry filter at all — while app.customer_live_loyalty_v384 (the
-- customer wallet), app.c45_base_actionable_wallet_card and
-- public.staff_get_customer_actionable_loyalty_v145 (the till) all exclude expired batches with
-- `(expires_at is null or expires_at > <as of>)`. That is the predicate adopted here, verbatim.
--
-- MEASURED ON PRODUCTION, same rolled-back transaction, on a customer whose only batch of 20
-- expired yesterday:
--     wallet 0, catalogue available_at_counter  (the disagreement)
--     claim   -> SUCCEEDED and drained the expired batch 20 -> 10
--     with a fresh batch of 10 added, the next claim took the EXPIRED batch first (it sorts
--     first under `order by expires_at nulls last`) and left the live one at 10.
--
-- FEFO ordering, the v480 advisory lock, the idempotency/loyalty_operations replay contract, the
-- provenance row, the per-batch drain rows, both conservation fences and the ledger write scopes
-- are all unchanged — and the three sites nestly_v815 gave `(v_all_pots or
-- programme_id=v_reward_programme)` still carry it, asserted below.
--
-- ============================================================================================
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- ============================================================================================
-- public.customer_get_stamp_card_v323 (a separate migration owns it), public.
-- customer_create_redemption_intent_v89, public.reverse_loyalty_redemption[_v34_base],
-- app.stamp_progress_v323, app.stamp_cycle_version_v416, app.stamp_reward_expiry_v464,
-- app.programme_balance_scope_v312, every table, every RLS policy, every cron job, and every
-- stored column — including loyalty_redemptions.usage_number, whose meaning is unchanged.
--
-- FORM. Extract-and-diff, not restatement: the live definitions are read with
-- pg_get_functiondef, every anchor is asserted to occur EXACTLY the expected number of times,
-- the splices are applied and the result executed. If production has drifted, this migration
-- refuses rather than silently reverting somebody's work.
--
-- ACCEPTANCE: db/tests/v847_redeem_engine_reversals_expiry_and_spine.sql (and the identical
-- db/tests/executed/ copy). Replay:
--   LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v847

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1 · SPLICE app.redeem_reward_core — pre-flight, patch, execute.
-- ============================================================================================
do $v847_core$
declare
  v_src text;
  v_n integer;

  -- (A) a new variable; v_usage keeps its meaning and its use as usage_number.
  c_decl_old constant text := 'v_usage integer; v_eligibility jsonb;';
  c_decl_new constant text := 'v_usage integer; v_usage_live integer; v_eligibility jsonb;';

  -- (A) the gate moves off v_usage and onto claims that carry no reversal row.
  c_gate_old constant text :=
    '  if v_version.usage_limit is not null and v_usage>=v_version.usage_limit then';
  c_gate_new constant text :=
    '  -- nestly_v847: a REVERSED claim holds no usage-limit slot. v_usage above is still every'
 || E'\n  -- redemption ever recorded, because it is stored as loyalty_redemptions.usage_number;'
 || E'\n  -- the LIMIT is measured against the claims that still stand.'
 || E'\n  select count(*)::integer into v_usage_live from public.loyalty_redemptions lr'
 || E'\n   where lr.business_id=p_business and lr.client_id=p_client and lr.reward_id=p_reward'
 || E'\n     and not exists (select 1 from public.loyalty_redemption_reversals rr'
 || E'\n                      where rr.business_id=lr.business_id and rr.redemption_id=lr.id);'
 || E'\n  if v_version.usage_limit is not null and v_usage_live>=v_version.usage_limit then';

  -- (B) the stamps exemption is deleted; every kind now needs a running spine.
  c_spine_old constant text :=
    'if v_programme_kind is distinct from ''stamps'' and not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception ''catalog redemption is inactive''; end if;';
  c_spine_new constant text :=
    '-- nestly_v847: the ''stamps'' exemption is gone. nestly_v495 already withdrew a stopped'
 || E'\n  -- programme''s gifts from app.reward_availability_v432 and from the customer intent path and'
 || E'\n  -- left this one alone; a stopped programme now mints and pays NOTHING NEW here too. What is'
 || E'\n  -- already earned is not destroyed: the nestly_v478 survivor path below is untouched, and'
 || E'\n  -- every gift returns the moment the spine is switched back on (nestly_v495).'
 || E'\n  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception ''catalog redemption is inactive''; end if;';

  -- (C) the same expiry predicate the wallet and the till already apply, at all three sites.
  c_bal_old constant text :=
    'into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and (v_all_pots or programme_id=v_reward_programme);';
  c_bal_new constant text :=
    'into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and (expires_at is null or expires_at>now()) and (v_all_pots or programme_id=v_reward_programme);';

  c_loop_old constant text :=
    'and remaining>0 and (v_all_pots or programme_id=v_reward_programme) order by expires_at nulls last,earned_at,id for update loop';
  c_loop_new constant text :=
    'and remaining>0 and (expires_at is null or expires_at>now()) and (v_all_pots or programme_id=v_reward_programme) order by expires_at nulls last,earned_at,id for update loop';

  c_fence_old constant text :=
    'and client_id=p_client and (v_all_pots or programme_id=v_reward_programme)) <> v_batch_balance-v_version.cost_points';
  c_fence_new constant text :=
    'and client_id=p_client and (expires_at is null or expires_at>now()) and (v_all_pots or programme_id=v_reward_programme)) <> v_batch_balance-v_version.cost_points';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if v_src is null then
    raise exception 'v847: app.redeem_reward_core is not present' using errcode = 'XX001';
  end if;

  /* Already applied? Refuse rather than double-splice. */
  if position('v_usage_live' in v_src) > 0
     or position('nestly_v847' in v_src) > 0 then
    raise exception 'v847: app.redeem_reward_core already carries the v847 splices'
      using errcode = 'XX001';
  end if;

  /* Every anchor exactly once. */
  if (length(v_src) - length(replace(v_src, c_decl_old, ''))) / length(c_decl_old) <> 1
     or (length(v_src) - length(replace(v_src, c_gate_old, ''))) / length(c_gate_old) <> 1
     or (length(v_src) - length(replace(v_src, c_spine_old, ''))) / length(c_spine_old) <> 1
     or (length(v_src) - length(replace(v_src, c_bal_old, ''))) / length(c_bal_old) <> 1
     or (length(v_src) - length(replace(v_src, c_loop_old, ''))) / length(c_loop_old) <> 1
     or (length(v_src) - length(replace(v_src, c_fence_old, ''))) / length(c_fence_old) <> 1
  then
    raise exception 'v847: app.redeem_reward_core is not the body v847 was written against — '
      'one of the six anchors is missing or occurs more than once; re-read pg_get_functiondef '
      'before splicing' using errcode = 'XX001';
  end if;

  /* The fences and contracts this migration must NOT disturb, asserted BEFORE the splice so a
     later diff of the two counts is meaningful. nestly_v815 gave three sites the pot predicate;
     nestly_v480 owns the advisory lock; the drain conservation checks are the money fence. */
  v_n := (length(v_src) - length(replace(v_src, '(v_all_pots or programme_id=v_reward_programme)', '')))
         / length('(v_all_pots or programme_id=v_reward_programme)');
  if v_n <> 3 then
    raise exception 'v847: expected nestly_v815''s three pot-scope sites in redeem_reward_core, found %', v_n
      using errcode = 'XX001';
  end if;
  if position('app.acquire_loyalty_shared_v480(p_business)' in v_src) = 0
     or position('reward batch delta does not reconcile' in v_src) = 0
     or position('reward drain provenance does not conserve value' in v_src) = 0
     or position('reward batch drain was incomplete' in v_src) = 0
     or position('app.points_ledger_write_scope' in v_src) = 0
     or position('order by expires_at nulls last,earned_at,id for update loop' in v_src) = 0
  then
    raise exception 'v847: a fence redeem_reward_core must keep (v480 lock / conservation / '
      'ledger write scope / FEFO order) is not where v847 expects it' using errcode = 'XX001';
  end if;

  v_src := replace(v_src, c_decl_old,  c_decl_new);
  v_src := replace(v_src, c_gate_old,  c_gate_new);
  v_src := replace(v_src, c_spine_old, c_spine_new);
  v_src := replace(v_src, c_bal_old,   c_bal_new);
  v_src := replace(v_src, c_loop_old,  c_loop_new);
  v_src := replace(v_src, c_fence_old, c_fence_new);
  execute v_src;
end
$v847_core$;

-- ============================================================================================
-- 2 · SPLICE app.reward_availability_v432 — pre-flight, patch, execute.
-- ============================================================================================
do $v847_avail$
declare
  v_src text;
  v_n integer;

  -- (C) the pot the catalogue judges affordability against stops counting expired batches.
  c_pot_old constant text := E'          and pb.remaining > 0\n';
  c_pot_new constant text := E'          and pb.remaining > 0\n'
                          || E'          -- nestly_v847: the same expiry predicate the wallet\n'
                          || E'          -- (app.customer_live_loyalty_v384) and the till\n'
                          || E'          -- (public.staff_get_customer_actionable_loyalty_v145) already apply.\n'
                          || E'          and (pb.expires_at is null or pb.expires_at > p_as_of)\n';

  -- (A) used_count — present identically in BOTH arms — stops counting reversed claims.
  c_used_old constant text := E'           and lr.reward_id = live.id\n      ) usage';
  c_used_new constant text := E'           and lr.reward_id = live.id\n'
                           || E'           -- nestly_v847: a REVERSED claim holds no usage-limit slot, so it must not\n'
                           || E'           -- be counted here either -- this number decides ''limit_reached'' and is\n'
                           || E'           -- the same gate app.redeem_reward_core applies at the counter.\n'
                           || E'           and not exists (select 1 from public.loyalty_redemption_reversals rr\n'
                           || E'                            where rr.business_id = lr.business_id\n'
                           || E'                              and rr.redemption_id = lr.id)\n'
                           || E'      ) usage';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432';
  if v_src is null then
    raise exception 'v847: app.reward_availability_v432 is not present' using errcode = 'XX001';
  end if;
  if position('nestly_v847' in v_src) > 0 then
    raise exception 'v847: app.reward_availability_v432 already carries the v847 splices'
      using errcode = 'XX001';
  end if;

  if (length(v_src) - length(replace(v_src, c_pot_old, ''))) / length(c_pot_old) <> 1 then
    raise exception 'v847: the pot CTE''s "and pb.remaining > 0" anchor is not unique in '
      'app.reward_availability_v432' using errcode = 'XX001';
  end if;
  v_n := (length(v_src) - length(replace(v_src, c_used_old, ''))) / length(c_used_old);
  if v_n <> 2 then
    raise exception 'v847: expected the used_count lateral in BOTH arms of '
      'app.reward_availability_v432, found %', v_n using errcode = 'XX001';
  end if;

  /* The rules this migration must not disturb: nestly_v815's pot scope (both halves of the
     least()), nestly_v568's survivor-arm pot predicate, and nestly_v495's programme_active
     filter — the reason a stopped programme lists nothing at all. */
  v_n := (length(v_src) - length(replace(v_src, '(select scope from pot_scope) <> ''programme_pot''', '')))
         / length('(select scope from pot_scope) <> ''programme_pot''');
  if v_n <> 2 then
    raise exception 'v847: expected nestly_v815''s two pot-scope halves in the pot CTE, found %', v_n
      using errcode = 'XX001';
  end if;
  if position('and live.programme_id = sc.programme_id' in v_src) = 0
     or position('where rows.programme_active' in v_src) = 0
     or position('app.reward_live_on_offer_v805' in v_src) = 0
     or position('app.reward_pause_on_offer_v814' in v_src) = 0
  then
    raise exception 'v847: a rule reward_availability_v432 must keep (v568 survivor pot / v495 '
      'programme_active filter / v805 / v814) is not where v847 expects it' using errcode = 'XX001';
  end if;

  v_src := replace(v_src, c_pot_old,  c_pot_new);
  v_src := replace(v_src, c_used_old, c_used_new);
  execute v_src;
end
$v847_avail$;

-- ============================================================================================
-- 3 · SHAPE — the splices landed, and only they did.
-- ============================================================================================
do $v847_shape$
declare
  v_core text;
  v_avail text;
  v_n integer;
begin
  select pg_get_functiondef(p.oid) into v_core from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='redeem_reward_core';
  select pg_get_functiondef(p.oid) into v_avail from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='reward_availability_v432';

  if position('loyalty_redemption_reversals' in v_core) = 0
     or position('loyalty_redemption_reversals' in v_avail) = 0 then
    raise exception 'v847: a body still has no notion of a reversal' using errcode='XX001';
  end if;
  if position('v_usage_live>=v_version.usage_limit' in v_core) = 0
     or position('v_usage>=v_version.usage_limit' in v_core) > 0 then
    raise exception 'v847: the usage-limit gate still reads v_usage' using errcode='XX001';
  end if;
  if position('usage_number' in v_core) = 0 or position('v_usage+1' in v_core) = 0 then
    raise exception 'v847: loyalty_redemptions.usage_number no longer receives v_usage+1 — a '
      'stored value changed, which this migration must not do' using errcode='XX001';
  end if;
  if position('v_programme_kind is distinct from ''stamps'' and not exists' in v_core) > 0 then
    raise exception 'v847: the stamps exemption on the spine gate survived' using errcode='XX001';
  end if;
  v_n := (length(v_core) - length(replace(v_core, 'expires_at is null or expires_at>now()', '')))
         / length('expires_at is null or expires_at>now()');
  if v_n <> 3 then
    raise exception 'v847: expected the expiry predicate at all three points_batches sites in '
      'redeem_reward_core, found %', v_n using errcode='XX001';
  end if;
  v_n := (length(v_core) - length(replace(v_core, '(v_all_pots or programme_id=v_reward_programme)', '')))
         / length('(v_all_pots or programme_id=v_reward_programme)');
  if v_n <> 3 then
    raise exception 'v847: nestly_v815''s three pot-scope sites did not survive the splice (found %)', v_n
      using errcode='XX001';
  end if;
  if position('order by expires_at nulls last,earned_at,id for update loop' in v_core) = 0
     or position('app.acquire_loyalty_shared_v480(p_business)' in v_core) = 0
     or position('reward batch delta does not reconcile' in v_core) = 0
     or position('reward drain provenance does not conserve value' in v_core) = 0 then
    raise exception 'v847: FEFO, the v480 lock or a conservation fence did not survive the splice'
      using errcode='XX001';
  end if;
  if position('pb.expires_at is null or pb.expires_at > p_as_of' in v_avail) = 0
     or position('and live.programme_id = sc.programme_id' in v_avail) = 0
     or position('where rows.programme_active' in v_avail) = 0 then
    raise exception 'v847: the availability splice or a rule it must keep is missing'
      using errcode='XX001';
  end if;
end
$v847_shape$;

-- ============================================================================================
-- 4 · ACLs restated, not assumed. Both are internal engine functions reached only through
--     SECURITY DEFINER wrappers (public.redeem_reward_at_context,
--     public.staff_manual_redeem_reward_v404, public.customer_get_reward_catalog, ...).
--     Live production ACL before this migration: {postgres=X/postgres} on both.
-- ============================================================================================
revoke all on function app.redeem_reward_core(uuid, uuid, uuid, text, uuid, uuid, uuid)
  from public, anon, authenticated;
revoke all on function app.reward_availability_v432(uuid, uuid, timestamp with time zone)
  from public, anon, authenticated;

do $v847_acl$
begin
  if pg_catalog.has_function_privilege('anon',
       'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('authenticated',
       'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)', 'execute')
     or pg_catalog.has_function_privilege('anon',
       'app.reward_availability_v432(uuid,uuid,timestamptz)', 'execute')
     or pg_catalog.has_function_privilege('authenticated',
       'app.reward_availability_v432(uuid,uuid,timestamptz)', 'execute')
  then
    raise exception 'v847: a tenant-facing role can execute a redemption engine function'
      using errcode = 'XX001';
  end if;
end
$v847_acl$;

-- ============================================================================================
-- 5 · IN-TRANSACTION VERIFICATION — behaviour, not source text.
--
--     The whole scenario runs inside a PL/pgSQL SUB-TRANSACTION that is ALWAYS rolled back: it
--     creates two scratch tenants, customers, points batches and gifts, and it REDEEMS and
--     REVERSES. Those are appends to public.loyalty_redemptions, public.points_ledger,
--     public.stamp_milestone_claims and public.audit_log — real, append-only, money-adjacent
--     tables. Deleting the fixtures afterwards is not an option (an append-only ledger is not
--     something a migration may garbage-collect), so the scenario is thrown away wholesale by
--     raising the P0847 sentinel, which the handler swallows. A real assertion failure raises
--     P0001 and is NOT caught: it aborts the migration.
--
--     Row-count leak checks either side of the sub-transaction prove production is untouched.
--
--     TWO tenants, not one: public.firm_config_versions carries
--     firm_config_one_published_per_business, and a firm's active programme kind decides how
--     app.reward_availability_v432 shapes every row, so the points scenario and the stamps
--     scenario cannot share a business without one of them measuring the wrong thing.
-- ============================================================================================

/* Session-local, dropped below. It exists so the two scratch firms are built by the SAME
   recipe and a difference between the scenarios cannot come from the fixture. */
create function pg_temp.v847_verify_firm(
  p_biz uuid, p_owner uuid, p_branch uuid, p_kind text, p_stamp_target integer
) returns uuid language plpgsql as $fn$
declare v_cfg uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v847-verify-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now());
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_biz,'V847 Verify','v847v-'||substr(p_biz::text,1,8),'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v847 verify', updated_at=clock_timestamp()
   where business_id=p_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_biz,false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid',
    current_period_end=now()+interval '30 days';
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_biz,p_owner,'owner','V847 Verify Owner',true,'approved');
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_biz,'V847 Verify Main',true,true);
  update public.business_programmes set active=(kind = p_kind) where business_id=p_biz;
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status,
                                      stamp_target)
  values (p_biz,true,case when p_kind='stamps' then 'stamps' else 'points_tiers' end,p_kind,
          'published',p_stamp_target)
  on conflict (business_id) do update
    set active=true, loyalty_model=excluded.loyalty_model, kind=excluded.kind,
        configuration_status='published', stamp_target=excluded.stamp_target;
  select id into v_cfg from public.firm_config_versions
   where business_id=p_biz and status='published' order by version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash,published_at)
    select v_cfg,p_biz,coalesce(max(version_no),0)+1,'published',md5('v847-verify-'||p_biz::text),now()
      from public.firm_config_versions where business_id=p_biz;
  end if;
  update public.businesses set active_config_version_id=v_cfg where id=p_biz;
  return v_cfg;
end
$fn$;

/* Ledger and batch must agree, or app.programme_balance_scope_v312 flips the firm into
   business_pot and these assertions stop measuring what they claim to. */
create function pg_temp.v847_verify_seed(
  p_biz uuid, p_client uuid, p_programme uuid, p_points integer, p_expires timestamptz
) returns uuid language plpgsql as $fn$
declare v_id uuid := gen_random_uuid(); v_batch uuid;
begin
  perform app.acquire_loyalty_shared_v480(p_biz);
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_biz,p_client,'adjust',p_points,'v847 verify seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
  values (p_biz,p_client,p_programme,p_points,p_points,p_expires)
  returning id into v_batch;
  return v_batch;
end
$fn$;

do $v847_verify$
declare
  v_bizp uuid := gen_random_uuid();  v_ownerp uuid := gen_random_uuid();  v_branchp uuid := gen_random_uuid();
  v_bizs uuid := gen_random_uuid();  v_owners uuid := gen_random_uuid();  v_branchs uuid := gen_random_uuid();
  v_cfg uuid; v_spine_pts uuid; v_spine_stp uuid;
  v_c1 uuid := gen_random_uuid();
  v_c2 uuid := gen_random_uuid();
  v_c3 uuid := gen_random_uuid();
  v_gift_lim uuid := gen_random_uuid();
  v_gift_exp uuid := gen_random_uuid();
  v_gift_s3 uuid := gen_random_uuid();
  v_gift_s5 uuid := gen_random_uuid();
  v_dead uuid; v_fresh uuid;
  v_res jsonb; v_red uuid;
  v_avail text; v_used integer; v_left integer;
  v_err text; v_msg text;
  v_redemptions_before bigint; v_ledger_before bigint; v_biz_before bigint; v_claims_before bigint;
  v_redemptions_after bigint;  v_ledger_after bigint;  v_biz_after bigint;  v_claims_after bigint;
begin
  select count(*) into v_redemptions_before from public.loyalty_redemptions;
  select count(*) into v_ledger_before from public.points_ledger;
  select count(*) into v_biz_before from public.businesses;
  select count(*) into v_claims_before from public.stamp_milestone_claims;

  begin
    ------------------------------------------------------------------------- FIRM P: points
    v_cfg := pg_temp.v847_verify_firm(v_bizp,v_ownerp,v_branchp,'points',null);
    select id into v_spine_pts from public.business_programmes
     where business_id=v_bizp and kind='points';

    insert into public.clients(id,business_id,full_name,phone)
    values (v_c1,v_bizp,'V847 Verify One','+65 9832 1001'),
           (v_c2,v_bizp,'V847 Verify Two','+65 9832 1002');
    v_fresh := pg_temp.v847_verify_seed(v_bizp,v_c1,v_spine_pts,30,now()+interval '365 days');
    v_dead  := pg_temp.v847_verify_seed(v_bizp,v_c2,v_spine_pts,20,now()-interval '1 day');

    insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
    values (v_gift_lim,v_bizp,'V847 Limit','V847 Limit','V847 Limit','manual_item',10,0,0,true,false,1,v_spine_pts),
           (v_gift_exp,v_bizp,'V847 Open','V847 Open','V847 Open','manual_item',10,0,0,true,false,2,v_spine_pts);
    insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
      customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,
      image_ref,sort,programme_id,usage_limit)
    values (v_gift_lim,v_bizp,v_cfg,'V847 Limit','V847 Limit','limit 1','manual_item',10,0,0,null,1,v_spine_pts,1),
           (v_gift_exp,v_bizp,v_cfg,'V847 Open','V847 Open','no limit','manual_item',10,0,0,null,2,v_spine_pts,null);

    if app.programme_balance_scope_v312(v_bizp) <> 'programme_pot' then
      raise exception 'v847 verify: the scratch points firm did not resolve to programme_pot';
    end if;

    perform set_config('request.jwt.claim.sub',v_ownerp::text,true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_ownerp,'role','authenticated')::text,true);

    ---------------------------------------------------------------------------------- (A)
    v_res := app.redeem_reward_core(v_bizp,v_c1,v_gift_lim,
               'v847ver-a1-'||replace(gen_random_uuid()::text,'-',''),v_branchp,null,null)::jsonb;
    v_red := (v_res->>'redemption_id')::uuid;
    select a.availability into v_avail from app.reward_availability_v432(v_bizp,v_c1) a
     where a.reward_id=v_gift_lim;
    if v_avail is distinct from 'limit_reached' then
      raise exception 'v847 verify: a claimed limit-1 gift did not read limit_reached (read %)',
        coalesce(v_avail,'<not listed>');
    end if;

    v_res := public.reverse_loyalty_redemption(v_bizp,v_red,
               'v847 verification: reversal must free the usage slot',
               'v847ver-rev-'||replace(gen_random_uuid()::text,'-',''))::jsonb;
    if (v_res->>'restored_points') <> '10' then
      raise exception 'v847 verify: the reversal did not restore 10 points (returned %)',
        coalesce(v_res->>'restored_points','<null>');
    end if;

    select a.availability,a.used_count into v_avail,v_used
      from app.reward_availability_v432(v_bizp,v_c1) a where a.reward_id=v_gift_lim;
    if v_avail is distinct from 'available_at_counter' or v_used <> 0 then
      raise exception 'v847 verify (A/reader): after a full reversal the catalogue still reads '
        '% at used_count % — the reversal is not excluded from used_count',
        coalesce(v_avail,'<not listed>'), v_used;
    end if;
    v_res := app.redeem_reward_core(v_bizp,v_c1,v_gift_lim,
               'v847ver-a2-'||replace(gen_random_uuid()::text,'-',''),v_branchp,null,null)::jsonb;
    if coalesce(v_res->>'ok','') <> 'true' then
      raise exception 'v847 verify (A/counter): the refunded customer is still locked out';
    end if;
    begin
      perform app.redeem_reward_core(v_bizp,v_c1,v_gift_lim,
                'v847ver-a3-'||replace(gen_random_uuid()::text,'-',''),v_branchp,null,null);
      raise exception 'v847 verify (A/sensitivity): a THIRD claim of a limit-1 gift succeeded — '
        'the usage limit was dropped rather than made reversal-aware';
    exception when sqlstate '23514' then null;
    end;

    ---------------------------------------------------------------------------------- (C)
    select a.availability into v_avail from app.reward_availability_v432(v_bizp,v_c2) a
     where a.reward_id=v_gift_exp;
    if v_avail is distinct from 'insufficient_balance' then
      raise exception 'v847 verify (C/reader): a customer whose only batch expired yesterday is '
        'offered the gift as % — the pot CTE still counts expired batches',
        coalesce(v_avail,'<not listed>');
    end if;
    v_err := null; v_msg := null;
    begin
      perform app.redeem_reward_core(v_bizp,v_c2,v_gift_exp,
                'v847ver-c1-'||replace(gen_random_uuid()::text,'-',''),v_branchp,null,null);
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    select remaining into v_left from public.points_batches where id=v_dead;
    if v_err is null or v_msg not like '%insufficient proven points%' or v_left <> 20 then
      raise exception 'v847 verify (C/counter): the counter spent expired points (err=%/%, '
        'expired batch left at % of 20)', coalesce(v_err,'-'), coalesce(v_msg,'-'), v_left;
    end if;
    -- and unexpired points still pay, FEFO skipping the expired batch rather than taking it first
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims','',true);
    v_fresh := pg_temp.v847_verify_seed(v_bizp,v_c2,v_spine_pts,10,now()+interval '365 days');
    perform set_config('request.jwt.claim.sub',v_ownerp::text,true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_ownerp,'role','authenticated')::text,true);
    v_res := app.redeem_reward_core(v_bizp,v_c2,v_gift_exp,
               'v847ver-c2-'||replace(gen_random_uuid()::text,'-',''),v_branchp,null,null)::jsonb;
    if coalesce(v_res->>'ok','') <> 'true'
       or (select remaining from public.points_batches where id=v_dead) <> 20
       or (select remaining from public.points_batches where id=v_fresh) <> 0 then
      raise exception 'v847 verify (C/sensitivity): the drain did not take the LIVE batch only '
        '(expired %, fresh %)', (select remaining from public.points_batches where id=v_dead),
        (select remaining from public.points_batches where id=v_fresh);
    end if;
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims','',true);

    ------------------------------------------------------------------------- FIRM S: stamps
    v_cfg := pg_temp.v847_verify_firm(v_bizs,v_owners,v_branchs,'stamps',5);
    select id into v_spine_stp from public.business_programmes
     where business_id=v_bizs and kind='stamps';
    if (select stamp_target from public.loyalty_program_versions
         where config_version_id=v_cfg and business_id=v_bizs) is distinct from 5 then
      raise exception 'v847 verify: the stamps config version does not carry stamp_target 5';
    end if;

    insert into public.clients(id,business_id,full_name,phone)
    values (v_c3,v_bizs,'V847 Verify Stamps','+65 9832 1003');
    perform pg_temp.v847_verify_seed(v_bizs,v_c3,v_spine_stp,5,null);

    insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
    values (v_gift_s3,v_bizs,'V847 S3','V847 S3','V847 S3','manual_item',3,0,0,true,false,1,v_spine_stp),
           (v_gift_s5,v_bizs,'V847 S5','V847 S5','V847 S5','manual_item',5,0,0,true,false,2,v_spine_stp);
    insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
      customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,
      image_ref,sort,programme_id)
    values (v_gift_s3,v_bizs,v_cfg,'V847 S3','V847 S3','slot 3','manual_item',3,0,0,null,1,v_spine_stp),
           (v_gift_s5,v_bizs,v_cfg,'V847 S5','V847 S5','slot 5','manual_item',5,0,0,null,2,v_spine_stp);

    perform set_config('request.jwt.claim.sub',v_owners::text,true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owners,'role','authenticated')::text,true);

    -- a RUNNING stamps programme still pays, and the last slot still closes the card
    v_res := app.redeem_reward_core(v_bizs,v_c3,v_gift_s5,
               'v847ver-b1-'||replace(gen_random_uuid()::text,'-',''),v_branchs,null,null)::jsonb;
    if coalesce(v_res->>'ok','') <> 'true' or coalesce(v_res->>'stamp_card_closed','') <> 'true' then
      raise exception 'v847 verify (B/control): a running stamps programme stopped paying (%)',
        coalesce(v_res::text,'<null>');
    end if;

    -- STOPPED: the counter must refuse the survivor the catalogue already refuses to list
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims','',true);
    update public.business_programmes set active=false where id=v_spine_stp;
    select a.availability into v_avail from app.reward_availability_v432(v_bizs,v_c3) a
     where a.reward_id=v_gift_s3;
    if v_avail is not null then
      raise exception 'v847 verify (B): a stopped programme''s gift is listed as % — nestly_v495 '
        'regressed', v_avail;
    end if;
    perform set_config('request.jwt.claim.sub',v_owners::text,true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owners,'role','authenticated')::text,true);
    v_err := null; v_msg := null;
    begin
      perform app.redeem_reward_core(v_bizs,v_c3,v_gift_s3,
                'v847ver-b2-'||replace(gen_random_uuid()::text,'-',''),v_branchs,null,null);
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    if v_err is null or v_msg not like '%catalog redemption is inactive%' then
      raise exception 'v847 verify (B): with the stamps programme switched off the counter still '
        'paid (err=%/%)', coalesce(v_err,'-'), coalesce(v_msg,'-');
    end if;

    -- nestly_v478 + nestly_v495: switch it back on and the already-earned survivor returns
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims','',true);
    update public.business_programmes set active=true where id=v_spine_stp;
    perform set_config('request.jwt.claim.sub',v_owners::text,true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owners,'role','authenticated')::text,true);
    v_res := app.redeem_reward_core(v_bizs,v_c3,v_gift_s3,
               'v847ver-b3-'||replace(gen_random_uuid()::text,'-',''),v_branchs,null,null)::jsonb;
    if coalesce(v_res->>'ok','') <> 'true' or coalesce(v_res->>'from_expired_card','') <> 'true' then
      raise exception 'v847 verify (B/v478+v495): the already-earned survivor did not return when '
        'the programme was switched back on (%)', coalesce(v_res::text,'<null>');
    end if;

    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims','',true);

    raise exception 'v847 verify: rollback sentinel' using errcode = 'P0847';
  exception
    when sqlstate 'P0847' then
      null;  -- expected: every assertion passed, the whole scenario is discarded
  end;

  select count(*) into v_redemptions_after from public.loyalty_redemptions;
  select count(*) into v_ledger_after from public.points_ledger;
  select count(*) into v_biz_after from public.businesses;
  select count(*) into v_claims_after from public.stamp_milestone_claims;
  if v_redemptions_after <> v_redemptions_before
     or v_ledger_after <> v_ledger_before
     or v_biz_after <> v_biz_before
     or v_claims_after <> v_claims_before then
    raise exception 'v847 verify: the verification block leaked rows (redemptions %/%, ledger '
      '%/%, businesses %/%, stamp claims %/%)', v_redemptions_before, v_redemptions_after,
      v_ledger_before, v_ledger_after, v_biz_before, v_biz_after,
      v_claims_before, v_claims_after using errcode = 'XX001';
  end if;

  raise notice 'v847: reversal-aware usage limits, the stopped-programme gate and the expired-'
    'batch filter all verified in a rolled-back sub-transaction; production state unchanged';
end
$v847_verify$;

drop function pg_temp.v847_verify_firm(uuid,uuid,uuid,text,integer);
drop function pg_temp.v847_verify_seed(uuid,uuid,uuid,integer,timestamptz);

commit;
