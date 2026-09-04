-- EXECUTED acceptance fixture for nestly_v757
-- (db/migrations/20260927_nestly_v757_reconcile_run_provider_label.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v757_corpus --migrated-only
--
-- WHY THIS EXISTS. public.billing_reconciliation_runs.provider defaults to 'stripe' and
-- public.start_billing_reconciliation_v77(p_run_mode, p_cursor_start) never set it, so a
-- Razorpay reconciliation run's own row said provider='stripe' while its finish summary said
-- provider='razorpay' -- the row label contradicted its own summary.
--
-- ASSERTIONS:
--   C1  start_billing_reconciliation_v757 with p_provider='razorpay' inserts a run row with
--       provider='razorpay'.
--   C2  an invalid p_provider raises 22023.
--   C3  the original start_billing_reconciliation_v77 still works and its rows still default to
--       provider='stripe' -- v77 was not dropped or altered.
--   C4  the migration's backfill statement is idempotent: running it a second time relabels zero
--       additional rows.

begin;

do $v757_test$
declare
  v_run_757 uuid;
  v_run_77 uuid;
  v_provider text;
  v_caught boolean := false;
  v_relabelled_first integer;
  v_relabelled_second integer;
  v_stale_run uuid;
begin
  -- ---------------------------------------------------------------------------------------
  -- C1: v757 with 'razorpay' inserts provider='razorpay'.
  -- ---------------------------------------------------------------------------------------
  v_run_757 := public.start_billing_reconciliation_v757('dry_run', null, 'razorpay');
  select provider into v_provider from public.billing_reconciliation_runs where id = v_run_757;
  if v_provider is distinct from 'razorpay' then
    raise exception 'C1 failed: expected provider=razorpay, got %', v_provider;
  end if;
  raise notice 'C1 passed: v757 razorpay run carries provider=razorpay';

  -- ---------------------------------------------------------------------------------------
  -- C2: invalid provider raises 22023.
  -- ---------------------------------------------------------------------------------------
  begin
    perform public.start_billing_reconciliation_v757('dry_run', null, 'paypal');
    raise exception 'C2 failed: expected 22023 for an invalid provider';
  exception
    when sqlstate '22023' then
      v_caught := true;
  end;
  if not v_caught then
    raise exception 'C2 failed: no exception raised';
  end if;
  raise notice 'C2 passed: invalid provider raises 22023';

  -- ---------------------------------------------------------------------------------------
  -- C3: v77 still works, still defaults to provider='stripe'.
  -- ---------------------------------------------------------------------------------------
  v_run_77 := public.start_billing_reconciliation_v77('dry_run', null);
  select provider into v_provider from public.billing_reconciliation_runs where id = v_run_77;
  if v_provider is distinct from 'stripe' then
    raise exception 'C3 failed: expected v77 default provider=stripe, got %', v_provider;
  end if;
  raise notice 'C3 passed: start_billing_reconciliation_v77 unchanged, still defaults to stripe';

  -- ---------------------------------------------------------------------------------------
  -- C4: the backfill statement is idempotent.
  -- ---------------------------------------------------------------------------------------
  -- Plant a v77-shaped stale row: provider defaulted to 'stripe', but its own finish summary
  -- already names razorpay -- exactly the shape the migration's backfill corrects.
  v_stale_run := public.start_billing_reconciliation_v77('dry_run', null);
  update public.billing_reconciliation_runs
     set status = 'clean', finished_at = now(),
         summary = jsonb_build_object('provider', 'razorpay', 'processed', 0)
   where id = v_stale_run;

  with corrected as (
    update public.billing_reconciliation_runs
       set provider = 'razorpay'
     where provider = 'stripe'
       and summary->>'provider' = 'razorpay'
    returning id
  )
  select count(*) into v_relabelled_first from corrected;
  if v_relabelled_first < 1 then
    raise exception 'C4 failed: first backfill pass relabelled nothing (expected the planted stale row)';
  end if;

  with corrected as (
    update public.billing_reconciliation_runs
       set provider = 'razorpay'
     where provider = 'stripe'
       and summary->>'provider' = 'razorpay'
    returning id
  )
  select count(*) into v_relabelled_second from corrected;
  if v_relabelled_second <> 0 then
    raise exception 'C4 failed: second backfill pass relabelled % rows, expected 0', v_relabelled_second;
  end if;
  raise notice 'C4 passed: backfill is idempotent (first pass % rows, second pass 0)', v_relabelled_first;

  raise notice 'v757_corpus_reconcile_run_provider: all assertions passed';
end
$v757_test$;

rollback;
