-- EXECUTED characterisation fixture for the retention "visit unit" question raised against
-- CI-100-CHECKLIST check 4 ("Multiple transactions during one real visit cannot silently create
-- multiple visits or repeat customers"). This is NOT a migration — no schema/function is changed
-- by this file. It pins CURRENT production behaviour so a silent future change (in either the
-- wallet card or the trigger) fails a test instead of shipping unnoticed.
--
-- OWNER DECISION PENDING — retention visits count sale rows (v2/v10 engine + v44/v465 wallet
-- card) vs check 4 (a split bill is one visit). See docs/qa/OWNER-ISSUE-LEDGER.md,
-- RETENTION-VISIT-UNIT-001, for the full write-up. Summary of what execution below proves:
--
--   1. app.c45_base_actionable_wallet_card (db/migrations/20260823_nestly_v465_home_ready_
--      count.sql:369, the `visit_candidate` CTE: `visits_remaining = goal_visits -
--      count(s.id)`) counts RAW SALE ROWS inside the retention window, not distinct visit-days.
--      A same-day split bill therefore advances the customer-facing "visits remaining" counter
--      once per transaction, exactly the shape check 4 forbids.
--   2. app.on_sale_recorded (db/migrations/20260822_nestly_v436_stamp_earn_pinned_and_lazy_
--      close.sql:27, "REGION A, v425") NO LONGER GRANTS RETENTION REWARDS AT ALL. The visit-
--      goal loop that used to read retention_program_versions and write reward_grants on a
--      qualifying sale was withdrawn by nestly_v425 (owner ruling: bringback_campaigns_v361, an
--      absence-triggered CRON sweep, is the one canonical bring-back engine; two engines paying
--      the same kind of reward off one sale is how a customer ends up owed the same thing
--      twice). So "does the engine double-count a split bill toward a reward" is not merely a
--      units-vs-days question today — the trigger fires ZERO retention reward_grants rows for
--      ANY visit count, split or not. Only the wallet card's `visits_remaining` figure still
--      reads goal_visits at all, and it is disconnected from anything that ever grants a reward.
--
-- Named v728 (above the v422 baseline watermark): n/a in the baseline phase (both app.
-- c45_base_actionable_wallet_card and the current app.on_sale_recorded post-date the snapshot),
-- gated on the migrated run only (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- ============================================================================================
-- TRUTH TABLE (hand-computed BEFORE running anything; asserted as exact equality, never `> 0`)
-- ============================================================================================
-- One business, one retention programme: goal_visits = 5, period_days = 365, starts_on = 30
-- days ago (so the whole fixture window sits inside one retention period — the period-window
-- arithmetic is not what's under test here; nestly_v711/v709 already pinned that separately for
-- other readers). One client, five sales, all `kind = 'service'` (default policy: counts_as_
-- visit = true, earns_points = true — app.sale_policy_defaults()):
--
--   Day -10: 3 sales, 09:00 / 11:00 / 13:00 SGT  (a split bill: three transactions, one visit)
--   Day  -9: 1 sale,  09:00 SGT                   (next day)
--   Day  -3: 1 sale,  09:00 SGT                   (a week after the day -10 cluster)
--
-- Raw sale-ROW count over the window: 5.
-- Distinct visit-DAY count (app.ci_visit_day_v699 authority, as nestly_v699/v709/v711 already
-- apply to every other CI "visits" reader): 3 ({-10, -9, -3}).
--
-- CURRENT (pinned) behaviour:
--   * app.c45_base_actionable_wallet_card(...).visits_remaining = greatest(5 - 5, 0) = 0.
--     The card tells this customer they are reward-ready NOW, after 3 real visits against a
--     5-visit goal, purely because one of those visits was paid for as three transactions.
--     Under check 4's "one real visit, however many transactions" rule the correct figure would
--     be greatest(5 - 3, 0) = 2 — still two visits short.
--   * public.sales insert x5 fires public.on_sale_recorded (trg_sale_recorded) five times.
--     public.reward_grants for this retention program: 0 rows, both before AND after the fifth
--     sale — the trigger's retention-visit-goal loop was removed at nestly_v425 and grants
--     nothing from goal_visits any more, regardless of how the 5 is reached. This is the
--     "engine's progress/reward firing" half of the pin: it fires NOTHING, which is itself the
--     fact silently changing back would break (re-adding a loop that pays on raw sale rows would
--     reproduce the double-count check 4 forbids; re-adding one that pays on visit-days would
--     also be a behaviour change from today's zero).
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v728$
declare
  biz         uuid := '00000000-0000-4000-8000-0000000728b1';
  cl          uuid := '00000000-0000-4000-8000-0000000728c1';
  cfg         uuid := '00000000-0000-4000-8000-0000000728ca';
  taxonomy    uuid := '00000000-0000-4000-8000-0000000728da';
  prog        uuid := '00000000-0000-4000-8000-0000000728e1';
  progver     uuid := '00000000-0000-4000-8000-0000000728e2';
  v_payload   jsonb;
  v_remaining int;
  v_progress_remaining int;
  v_goal      int;
  v_grants_before int;
  v_grants_mid int;
  v_grants_after int;
  v_def       text;
  v_err       text;
begin
  ---------------------------------------------------------------------------
  -- Fixture setup: one synthetic business, published config version, reward taxonomy row,
  -- and one retention programme (goal_visits=5, period_days=365, starts_on 30 days ago so the
  -- whole fixture window is inside one period).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, currency, is_synthetic)
  values (biz, 'ZZ v728 retention visit unit', 'zz-v728-' || biz, 'SGD', true);

  -- trg_guard_retention_program_version (nestly_v37b) refuses any insert into
  -- retention_program_versions once its config_version_id's firm_config_versions row is
  -- published — "published retention configuration is immutable". So the version row has to be
  -- inserted while the config version is still a draft, and only THEN flipped to published (a
  -- plain UPDATE on firm_config_versions, which the guard does not touch).
  insert into public.firm_config_versions (
    id, business_id, version_no, status, source, snapshot_hash, created_by
  ) values (
    cfg, biz, 1, 'draft', 'manual', md5('v728-fixture-config'), null
  );

  insert into public.firm_reward_taxonomy (id, business_id, label, fulfillment_kind)
  values (taxonomy, biz, 'ZZ v728 retention credit', 'credit');

  insert into public.retention_programs (
    id, business_id, name, goal_visits, period_days, reward_type, reward_value,
    starts_on, active, reward_taxonomy_id
  ) values (
    prog, biz, 'ZZ v728 five-visit reward', 5, 365, 'credit', 500,
    (current_date - 30), true, taxonomy
  );

  insert into public.retention_program_versions (
    id, program_id, config_version_id, business_id, name, active, goal_visits, period_days,
    starts_on, reward_taxonomy_id, fulfillment_kind, credit_cents, sort, customer_description
  ) values (
    progver, prog, cfg, biz, 'ZZ v728 five-visit reward', true, 5, 365,
    (current_date - 30), taxonomy, 'credit', 500, 0, 'Visit 5 times for a treat on us'
  );

  update public.firm_config_versions set status = 'published', published_at = now()
   where id = cfg;
  update public.businesses set active_config_version_id = cfg where id = biz;

  insert into public.clients (id, business_id, full_name)
  values (cl, biz, 'ZZ v728 split-bill customer');

  ---------------------------------------------------------------------------
  -- Pre-condition: zero reward_grants for this programme before any sale.
  ---------------------------------------------------------------------------
  select count(*) into v_grants_before from public.reward_grants where program_id = prog;
  if v_grants_before <> 0 then
    insert into _fail values ('pre-grants',
      format('reward_grants already has %s row(s) for this programme before any sale — fixture '
             'is not starting clean', v_grants_before));
  end if;

  ---------------------------------------------------------------------------
  -- Day -10: a split bill — three transactions for the same real visit.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, cl, 'service', 1000,
         (current_date - 10)::timestamp at time zone 'Asia/Singapore' + d.tod,
         (current_date - 10)::timestamp at time zone 'Asia/Singapore' + d.tod
    from (values (interval '9 hours'), (interval '11 hours'), (interval '13 hours')) as d(tod);

  -- After the split bill (3 sale rows, 1 real visit-day): the engine must still have fired
  -- nothing — there is no reward at goal_visits=5 yet under ANY counting rule.
  select count(*) into v_grants_mid from public.reward_grants where program_id = prog;
  if v_grants_mid <> 0 then
    insert into _fail values ('mid-grants',
      format('reward_grants has %s row(s) after only 3 sales (1 visit-day, 3 sale rows) — '
             'goal_visits=5 should not be reachable yet by any counting rule', v_grants_mid));
  end if;

  ---------------------------------------------------------------------------
  -- Day -9: the next-day visit.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, cl, 'service', 1000,
          (current_date - 9)::timestamp at time zone 'Asia/Singapore' + interval '9 hours',
          (current_date - 9)::timestamp at time zone 'Asia/Singapore' + interval '9 hours');

  ---------------------------------------------------------------------------
  -- Day -3: a week after the day -10 cluster. This is the 5th SALE ROW and the 3rd VISIT-DAY.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, cl, 'service', 1000,
          (current_date - 3)::timestamp at time zone 'Asia/Singapore' + interval '9 hours',
          (current_date - 3)::timestamp at time zone 'Asia/Singapore' + interval '9 hours');

  ---------------------------------------------------------------------------
  -- ENGINE ASSERTION: 5 sale rows have now been recorded (fires trg_sale_recorded /
  -- app.on_sale_recorded five times). Current behaviour: still ZERO reward_grants rows for
  -- this programme — the retention visit-goal loop was withdrawn at nestly_v425 and this
  -- trigger no longer grants anything from goal_visits, split bill or not.
  ---------------------------------------------------------------------------
  select count(*) into v_grants_after from public.reward_grants where program_id = prog;
  if v_grants_after <> 0 then
    insert into _fail values ('engine-grants-after-5th-sale',
      format('reward_grants has %s row(s) for this programme after the 5th sale — expected 0 '
             '(nestly_v425 withdrew the retention visit-goal loop from app.on_sale_recorded; a '
             'non-zero count here means that loop, or an equivalent, has come back and this '
             'ledger entry''s "the engine fires nothing" premise is now false)', v_grants_after));
  end if;

  ---------------------------------------------------------------------------
  -- Structural proof: app.on_sale_recorded's live body does not ACTUALLY QUERY retention_
  -- program_versions or WRITE reward_grants any more (the loop is gone, not merely inert). This
  -- checks for the schema-qualified reference a real query would use
  -- (`public.retention_program_versions`), not the bare word — the REGION A comment nestly_v425
  -- left in place, documenting the removal, mentions "retention_program_versions" in prose
  -- without the `public.` qualifier, and a naive substring check would misfire on that comment.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(to_regprocedure('app.on_sale_recorded()')) into v_def;
  if v_def is null then
    insert into _fail values ('struct-pre', 'app.on_sale_recorded not found');
  else
    if position('public.retention_program_versions' in v_def) > 0 then
      insert into _fail values ('struct-retention-versions',
        'app.on_sale_recorded queries public.retention_program_versions again — the withdrawn '
        'visit-goal loop (or a replacement) has returned; re-verify its visit-counting unit '
        'before closing RETENTION-VISIT-UNIT-001');
    end if;
    if position('insert into public.reward_grants' in v_def) > 0 then
      insert into _fail values ('struct-reward-grants',
        'app.on_sale_recorded writes reward_grants again — the withdrawn visit-goal loop (or a '
        'replacement) has returned; re-verify its visit-counting unit before closing '
        'RETENTION-VISIT-UNIT-001');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- WALLET CARD ASSERTION: app.c45_base_actionable_wallet_card, called as of now(), over the
  -- full 5-sale-row / 3-visit-day history above.
  ---------------------------------------------------------------------------
  begin
    v_payload := app.c45_base_actionable_wallet_card(
      biz, cl, 'zz-v728', 'ZZ v728 retention visit unit', 'cafe', 'SGD',
      array['loyalty','packages']::text[], now()
    );
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('card-call', format('c45_base_actionable_wallet_card raised %s', v_err));
  end;

  if v_payload is null then
    insert into _fail values ('card-call-pre', 'c45_base_actionable_wallet_card returned no result');
  else
    v_remaining := (v_payload->>'visits_remaining')::int;
    v_progress_remaining := (v_payload#>>'{visit_progress,remaining}')::int;
    v_goal := (v_payload#>>'{visit_progress,goal_visits}')::int;

    if v_remaining is distinct from 0 then
      insert into _fail values ('card-visits_remaining',
        format('got %s, expected 0 — the card counts raw sale rows (5), not visit-days (3), so '
               'goal_visits=5 reads as already met', v_remaining));
    end if;
    if v_progress_remaining is distinct from 0 then
      insert into _fail values ('card-visit_progress-remaining',
        format('got %s, expected 0 (visit_progress.remaining must match top-level '
               'visits_remaining)', v_progress_remaining));
    end if;
    if v_goal is distinct from 5 then
      insert into _fail values ('card-visit_progress-goal',
        format('got %s, expected 5', v_goal));
    end if;

    -- Mutation check in the OTHER direction: if this ever reads 2 (5 goal - 3 visit-days), the
    -- card has switched to counting visit-days (check 4's answer) without RETENTION-VISIT-
    -- UNIT-001 being resolved and this fixture updated to match the new intended behaviour.
    if v_remaining = 2 then
      insert into _fail values ('card-mutation-to-visit-days',
        'visits_remaining=2 — the card now appears to count distinct visit-days instead of raw '
        'sale rows; this is the CORRECT behaviour per check 4, but it is a deliberate change '
        'this fixture must be updated to assert as the new pin, and RETENTION-VISIT-UNIT-001 '
        'must be closed with that ruling recorded, not silently absorbed');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- Structural proof: the wallet card's retention_windows CTE counts sale rows via count(s.id),
  -- not through the visit-day authority app.ci_visit_day_v699.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(to_regprocedure(
    'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)'
  )) into v_def;
  if v_def is null then
    insert into _fail values ('card-struct-pre', 'c45_base_actionable_wallet_card not found');
  elsif position('app.ci_visit_day_v699' in v_def) > 0 then
    -- Not a failure by itself (the authority may have been adopted elsewhere in the function),
    -- but worth surfacing: if it now appears inside the visit_candidate CTE specifically the
    -- visits_remaining assertions above are the ones that would actually catch a real fix, and
    -- the card-mutation-to-visit-days check above should have fired too.
    if v_remaining is distinct from 2 then
      insert into _fail values ('card-struct-inconsistent',
        'c45_base_actionable_wallet_card now calls app.ci_visit_day_v699 but visits_remaining '
        'did not move to 2 — investigate before trusting either signal');
    end if;
  end if;
end
$v728$;

select case when count(*) = 0
            then 'PASS — pinned: wallet card visits_remaining counts raw sale rows (a split '
                 'bill reads as done early); app.on_sale_recorded grants zero retention rewards '
                 'from goal_visits under any counting rule (nestly_v425 withdrew that loop). '
                 'See docs/qa/OWNER-ISSUE-LEDGER.md RETENTION-VISIT-UNIT-001 — decision pending.'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v728: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
