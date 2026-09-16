-- nestly_v990 rollback suite — provider cash proves it is live, or it is not revenue.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  n integer := 0; blocked integer; total integer; manual_hit integer;
  before bigint; after bigint; got integer;
begin
  -- (1) every queued slice on this estate is provider cash that cannot prove itself
  n := n + 1;
  select count(*) into total
    from public.platform_subscription_revenue_months_v200 m
   where m.journal_entry_id is null;
  select count(*) into blocked
    from public.platform_subscription_revenue_months_v200 m
    join public.platform_subscription_revenue_periods_v200 p on p.id = m.period_id
   where m.journal_entry_id is null
     and p.cash_account_code = '1010'
     and not exists (select 1 from public.billing_provider_invoices good
                      where good.provider_invoice_id = p.invoice_reference
                        and coalesce(good.livemode,false));
  if total = 0 then raise exception 'A% failed: no queued slices to reason about', n; end if;
  if blocked <> total then
    raise exception 'A% failed: % of % queued slices would still recognise', n, total-blocked, total;
  end if;

  -- (2) the recogniser posts nothing, even with every slice back-dated to due
  n := n + 1;
  update public.platform_subscription_revenue_months_v200
     set month_start = current_date - 1
   where journal_entry_id is null;
  select count(*) into before from public.platform_accounting_journal_entries_v147;
  got := app.v200_recognize_due_months();
  select count(*) into after from public.platform_accounting_journal_entries_v147;
  if got <> 0 or after <> before then
    raise exception 'A% failed: recogniser returned % and posted % entries from unprovable cash',
      n, got, after-before;
  end if;

  -- (3) a manual period is NOT caught by the rule
  n := n + 1;
  select count(*) into manual_hit
    from public.platform_subscription_revenue_periods_v200 p
   where p.cash_account_code <> '1010'
     and p.cash_account_code is not null
     and not (p.cash_account_code <> '1010');
  if manual_hit <> 0 then
    raise exception 'A% failed: the guard reached a manual period', n;
  end if;

  -- (4) and if one of those periods were backed by a LIVE invoice it would recognise again,
  --     proving the guard tests liveness rather than simply refusing everything
  n := n + 1;
  update public.platform_subscription_revenue_periods_v200
     set invoice_reference = (select provider_invoice_id from public.billing_provider_invoices
                               where coalesce(livemode,false) limit 1)
   where id = (select id from public.platform_subscription_revenue_periods_v200
                where cash_account_code='1010' limit 1);
  got := app.v200_recognize_due_months();
  if got = 0 then
    raise exception 'A% failed: a period backed by a LIVE invoice still recognised nothing - the guard is refusing everything, not testing liveness', n;
  end if;

  raise notice 'v990 suite: % assertions passed', n;
end
$suite$;
rollback;
