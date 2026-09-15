-- nestly_v984 acceptance — Razorpay is retired, proven against production and rolled back.
--
-- Run:  supabase db query --linked -f db/tests/v984_razorpay_is_retired.sql
-- Ends by raising V984_RESULT so nothing can commit. A PASS is an exception whose message says
-- ALL PASS; any other exception is the failure.
--
-- Four assertions, in the order the migration has to be true in:
--   1  the premise — Razorpay was sandbox-only, so re-pointing is a cleanup and not a refund
--   2  D22 reports the divergence BEFORE the change, and nothing AFTER it
--   3  the CHECK actually refuses a new razorpay subscription (the writer is closed, not just tidy)
--   4  the six firms land where a non-provider firm is supposed to land, ids and all
--
-- Assertion 2 manufactures its own row if production is already clean, because a scanner suite
-- that passes only because there is nothing left to find proves nothing about the scanner.

begin;

do $v984_suite$
declare
  n integer := 0;
  v_before integer;
  v_after integer;
  v_live integer;
  v_ids integer;
  v_refused boolean := false;
  v_probe uuid;
begin
  -- ==========================================================================================
  -- 1 · THE PREMISE. Every razorpay event ever recorded is sandbox. If this is ever false, the
  --     migration's own guard stops it, and this suite should be the thing that says why.
  -- ==========================================================================================
  select count(*) into v_live
    from public.billing_provider_events
   where provider = 'razorpay' and livemode is true;
  if v_live <> 0 then
    raise exception 'V984 ASSERT 1 FAILED: % live-mode razorpay events exist; retiring the provider by re-pointing rows would be hiding real money', v_live;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 2 · D22 SEES IT, AND STOPS SEEING IT. The predicate is copied from
  --     db/tests/tenant_divergence_scan.sql; if the two drift, the gate's own run disagrees with
  --     this suite and someone notices on the next tenant-gate.
  -- ==========================================================================================
  select count(*) into v_before
    from public.subscriptions s
   where coalesce(s.billing_provider,'') <> 'manual'
     and coalesce(s.billing_provider,'') <> app.platform_billing_provider_v792();

  if v_before = 0 then
    /* Production is already clean. Manufacture the exact shape D22 exists to catch, on a real
       row, so the check is exercised rather than merely skipped. */
    select business_id into v_probe from public.subscriptions
     where billing_provider = 'manual' limit 1;
    if v_probe is null then
      raise exception 'V984 ASSERT 2 INCONCLUSIVE: no subscription exists to probe with';
    end if;
    /* The CHECK the migration installs would refuse 'razorpay' here, which is itself assertion 3.
       So the probe uses a DIFFERENT wrong provider — the point of D22 is that it keys on the
       authority, not on one retired provider's name. */
    alter table public.subscriptions drop constraint if exists subscriptions_billing_provider_check;
    update public.subscriptions set billing_provider = 'paypal' where business_id = v_probe;
    select count(*) into v_before
      from public.subscriptions s
     where coalesce(s.billing_provider,'') <> 'manual'
       and coalesce(s.billing_provider,'') <> app.platform_billing_provider_v792();
    if v_before <> 1 then
      raise exception 'V984 ASSERT 2 FAILED: D22 did not report a manufactured divergence (saw %)', v_before;
    end if;
    update public.subscriptions set billing_provider = 'manual' where business_id = v_probe;
  end if;

  if v_before = 0 then
    raise exception 'V984 ASSERT 2 FAILED: nothing to detect and nothing manufactured';
  end if;
  n := n + 1;

  -- Apply exactly what the migration applies.
  update public.subscriptions
     set billing_provider = 'manual',
         provider_customer_id = null,
         provider_subscription_id = null,
         provider_base_item_id = null
   where billing_provider = 'razorpay';

  select count(*) into v_after
    from public.subscriptions s
   where coalesce(s.billing_provider,'') <> 'manual'
     and coalesce(s.billing_provider,'') <> app.platform_billing_provider_v792();
  if v_after <> 0 then
    raise exception 'V984 ASSERT 2 FAILED: D22 still reports % row(s) after the re-point', v_after;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 3 · THE WRITER IS CLOSED. Not "no caller writes it" — the table refuses it.
  -- ==========================================================================================
  alter table public.subscriptions drop constraint if exists subscriptions_billing_provider_check;
  alter table public.subscriptions
    add constraint subscriptions_billing_provider_check
    check (billing_provider = any (array['manual'::text, 'stripe'::text]));

  begin
    update public.subscriptions
       set billing_provider = 'razorpay'
     where business_id = (select business_id from public.subscriptions limit 1);
  exception when check_violation then
    v_refused := true;
  end;
  if not v_refused then
    raise exception 'V984 ASSERT 3 FAILED: the constraint accepted billing_provider = razorpay';
  end if;
  n := n + 1;

  -- 'stripe' must still be accepted — a constraint that refuses everything would pass the
  -- assertion above while breaking the only provider that actually bills.
  update public.subscriptions
     set billing_provider = 'stripe'
   where business_id = (select business_id from public.subscriptions where billing_provider = 'stripe' limit 1);

  -- ==========================================================================================
  -- 4 · NO ORPHANED IDS. A 'manual' row holding a provider's customer id is the exact shape that
  --     produced v792's live failure, so it is checked rather than assumed.
  -- ==========================================================================================
  select count(*) into v_ids
    from public.subscriptions
   where billing_provider = 'manual'
     and (provider_customer_id is not null
       or provider_subscription_id is not null
       or provider_base_item_id is not null);
  if v_ids <> 0 then
    raise exception 'V984 ASSERT 4 FAILED: % manual subscription(s) still carry provider ids', v_ids;
  end if;
  n := n + 1;

  raise exception 'V984_RESULT ALL PASS (% assertions)', n;
end
$v984_suite$;

rollback;
