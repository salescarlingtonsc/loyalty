-- Rollback-only v200 acceptance: subscription revenue posts itself, and an
-- annual payment does not overstate profit.
begin;

do $v200$
declare
  v_sa uuid; v_biz uuid; a jsonb; b jsonb; v_n int; v_sum bigint; v_rev bigint;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- Unpaid and trialing subscriptions must never become revenue.
  a := public.platform_run_subscription_revenue_v200();
  if (a->>'captured_periods')::int <> 0 or (a->>'recognized_months')::int <> 0 then
    raise exception 'A: engine invented revenue from unpaid subscriptions: %', a;
  end if;

  -- One firm pays a FULL YEAR up front.
  select business_id into v_biz from public.subscriptions limit 1;
  update public.subscriptions
     set payment_status='paid', last_paid_at = timestamptz '2026-08-01 10:00+08',
         last_paid_invoice_id='INV-FIXTURE-1',
         period_subtotal_cents=118800, period_tax_cents=0, period_total_cents=118800,
         cadence_months=12, provider_subscription_id='sub_fixture',
         current_period_start = timestamptz '2026-08-01 00:00+08',
         current_period_end   = timestamptz '2027-08-01 00:00+08'
   where business_id = v_biz;

  a := public.platform_run_subscription_revenue_v200();
  if (a->>'captured_periods')::int <> 1 then raise exception 'B: expected 1 capture, got %', a; end if;

  -- Twelve monthly slices that add back to the cash exactly (no rounding leak).
  select count(*), sum(amount_cents) into v_n, v_sum
    from public.platform_subscription_revenue_months_v200;
  if v_n <> 12 then raise exception 'C: expected 12 monthly slices, got %', v_n; end if;
  if v_sum <> 118800 then raise exception 'D: slices sum to % but cash was 118800', v_sum; end if;

  -- Only the month already under way is earned.
  if (a->>'recognized_months')::int <> 1 then
    raise exception 'E: expected 1 month recognised, got %', a->>'recognized_months';
  end if;

  -- THE ACCURACY TEST: the P&L shows one month earned, not a year of cash.
  select (public.platform_get_accounting_books_v147(date '2026-07-01', date '2026-12-31', 200)
          #>>'{summary,revenue_cents}')::bigint into v_rev;
  if v_rev <> 9900 then raise exception 'F: P&L revenue should be 9900 (one month), got %', v_rev; end if;
  if (a->>'deferred_balance_cents')::bigint <> 108900 then
    raise exception 'G: deferred should be 108900, got %', a->>'deferred_balance_cents';
  end if;

  -- Safe to automate: a repeat run changes nothing.
  b := public.platform_run_subscription_revenue_v200();
  if (b->>'captured_periods')::int <> 0 or (b->>'recognized_months')::int <> 0 then
    raise exception 'H: re-run double-posted: %', b;
  end if;
  select (public.platform_get_accounting_books_v147(date '2026-07-01', date '2026-12-31', 200)
          #>>'{summary,revenue_cents}')::bigint into v_rev;
  if v_rev <> 9900 then raise exception 'I: revenue moved on a repeat run: %', v_rev; end if;

  -- Double entry holds.
  select sum(debit_cents) - sum(credit_cents) into v_sum
    from public.platform_accounting_journal_lines_v147;
  if v_sum <> 0 then raise exception 'J: journal does not balance, delta %', v_sum; end if;

  -- Browser roles cannot read the revenue tables directly.
  if has_table_privilege('authenticated','public.platform_subscription_revenue_periods_v200','SELECT')
     or has_table_privilege('anon','public.platform_subscription_revenue_months_v200','SELECT') then
    raise exception 'K: revenue tables are readable by a browser role';
  end if;

  raise notice 'v200 subscription revenue: all assertions passed (P&L % of % cash)', v_rev, 118800;
end
$v200$;

rollback;
