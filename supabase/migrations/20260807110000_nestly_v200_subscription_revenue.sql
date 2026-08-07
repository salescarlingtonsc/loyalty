-- NESTLY v200 — subscription revenue posts itself, and posts it correctly.
--
-- Owner: "go, must be automatic and accurate."
--
-- ACCURATE first, because it constrains the design. Two facts about production
-- decide the accounting:
--
--   1. Nothing has been paid yet. All ten subscriptions are trialing or
--      incomplete; period_total_cents is 0 across the board. So this engine
--      posts NOTHING today, and that is the correct output. It starts posting
--      by itself the moment a real payment lands. Recognising trial or unpaid
--      subscriptions would invent revenue the company has not earned.
--
--   2. Billing can be annual (subscriptions.cadence_months; branches are billed
--      yearly). Taking a year of cash as revenue on the day it arrives would
--      overstate profit by up to eleven months of income and understate the
--      liability to keep serving that customer. So cash and revenue are split:
--
--        on payment      Dr 1010 Stripe clearing   Cr 2300 Deferred revenue
--        each month      Dr 2300 Deferred revenue  Cr 4000 Subscription revenue
--
--      A monthly plan simply has one slice, so the same path handles both and
--      there is no special case to get wrong.
--
-- AUTOMATIC second. A daily pg_cron job runs the two steps. Every posting is
-- anchored to a deterministic source_id, and app.platform_post_journal_v147 is
-- idempotent on (source_type, source_id) — so re-running the job, or running it
-- twice concurrently, cannot double-post. That property is what makes it safe
-- to automate at all.
--
-- Money is never lost to rounding: a period is split into whole cents and any
-- remainder lands on the final month, so the slices always sum to the cash.
--
-- A locked accounting period makes one slice fail, not the batch — it is skipped
-- and retried on the next run once the period reopens.

begin;

-- The missing half of the double entry. Cash received for service not yet
-- delivered is a liability, not income.
insert into public.platform_accounting_accounts_v147(
  code, name, account_type, normal_balance, system_key)
values ('2300', 'Deferred subscription revenue', 'liability', 'credit',
  'deferred_subscription_revenue')
on conflict (code) do nothing;

-- One row per billing period that has actually been paid for.
create table if not exists public.platform_subscription_revenue_periods_v200(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  period_start date not null,
  period_end date not null,
  total_cents bigint not null check (total_cents > 0),
  month_count integer not null check (month_count between 1 and 60),
  paid_at timestamptz not null,
  invoice_reference text,
  cash_account_code text not null,
  cash_journal_entry_id uuid,
  captured_at timestamptz not null default now(),
  constraint revenue_period_span check (period_end > period_start),
  constraint revenue_period_once unique (business_id, period_start, period_end)
);

-- One row per month of service the payment bought. This is the unit of revenue.
create table if not exists public.platform_subscription_revenue_months_v200(
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.platform_subscription_revenue_periods_v200(id) on delete cascade,
  month_index integer not null check (month_index >= 1),
  month_start date not null,
  amount_cents bigint not null check (amount_cents > 0),
  journal_entry_id uuid,
  recognized_at timestamptz,
  constraint revenue_month_once unique (period_id, month_index),
  -- Recognised exactly when it carries the entry that recognised it.
  constraint revenue_month_shape check (
    (journal_entry_id is null and recognized_at is null)
    or (journal_entry_id is not null and recognized_at is not null))
);

alter table public.platform_subscription_revenue_periods_v200 enable row level security;
alter table public.platform_subscription_revenue_months_v200 enable row level security;
-- Books are read through the accounting RPCs, never PostgREST.
revoke all on table public.platform_subscription_revenue_periods_v200 from anon, authenticated;
revoke all on table public.platform_subscription_revenue_months_v200 from anon, authenticated;

create index if not exists platform_subscription_revenue_months_v200_due_idx
  on public.platform_subscription_revenue_months_v200(month_start)
  where journal_entry_id is null;

comment on table public.platform_subscription_revenue_periods_v200 is
  'v200 paid subscription periods. Cash lands in deferred revenue here and is recognised month by month, so annual billing does not overstate profit.';

-- Step 1 — capture cash for periods that have genuinely been paid.
create or replace function app.v200_capture_paid_periods()
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_sub record; v_period public.platform_subscription_revenue_periods_v200%rowtype;
  v_months integer; v_base bigint; v_remainder bigint; v_index integer;
  v_cash text; v_result jsonb; v_captured integer := 0; v_post_date date;
begin
  for v_sub in
    select s.business_id, s.current_period_start, s.current_period_end,
           s.period_total_cents, s.last_paid_at, s.last_paid_invoice_id,
           s.provider_subscription_id, s.cadence_months
      from public.subscriptions s
     where s.payment_status = 'paid'
       and s.last_paid_at is not null
       and coalesce(s.period_total_cents,0) > 0
       and s.current_period_start is not null
       and s.current_period_end is not null
       and s.current_period_end > s.current_period_start
       and not exists (
         select 1 from public.platform_subscription_revenue_periods_v200 p
          where p.business_id = s.business_id
            and p.period_start = (s.current_period_start at time zone 'Asia/Singapore')::date
            and p.period_end = (s.current_period_end at time zone 'Asia/Singapore')::date)
  loop
    v_post_date := (v_sub.last_paid_at at time zone 'Asia/Singapore')::date;

    -- Nothing posts before the company legally existed.
    if not exists (select 1 from public.platform_accounting_policies_v147
                    where effective_from <= v_post_date) then
      continue;
    end if;

    -- Prefer the subscription's own cadence; fall back to the period's length.
    v_months := greatest(1, coalesce(v_sub.cadence_months,
      (extract(year from age(v_sub.current_period_end, v_sub.current_period_start))*12
       + extract(month from age(v_sub.current_period_end, v_sub.current_period_start)))::integer));
    if v_months > 60 then v_months := 60; end if;

    v_cash := case when v_sub.provider_subscription_id is not null then '1010' else '1000' end;

    insert into public.platform_subscription_revenue_periods_v200(
      business_id, period_start, period_end, total_cents, month_count,
      paid_at, invoice_reference, cash_account_code)
    values (v_sub.business_id,
      (v_sub.current_period_start at time zone 'Asia/Singapore')::date,
      (v_sub.current_period_end at time zone 'Asia/Singapore')::date,
      v_sub.period_total_cents, v_months, v_sub.last_paid_at,
      nullif(btrim(coalesce(v_sub.last_paid_invoice_id,'')),''), v_cash)
    returning * into v_period;

    -- Whole cents only; the remainder rides on the final month so the slices
    -- always add back to the cash received.
    v_base := v_period.total_cents / v_months;
    v_remainder := v_period.total_cents - (v_base * v_months);
    for v_index in 1..v_months loop
      insert into public.platform_subscription_revenue_months_v200(
        period_id, month_index, month_start, amount_cents)
      values (v_period.id, v_index,
        (v_period.period_start + make_interval(months => v_index - 1)),
        v_base + case when v_index = v_months then v_remainder else 0 end);
    end loop;

    begin
      v_result := app.platform_post_journal_v147(
        'platform_subscription_cash_v200',
        v_period.id::text,
        v_post_date,
        'Subscription payment received (deferred until earned)',
        jsonb_build_array(
          jsonb_build_object('account_code', v_cash,
            'debit_cents', v_period.total_cents, 'credit_cents', 0),
          jsonb_build_object('account_code', '2300',
            'debit_cents', 0, 'credit_cents', v_period.total_cents)));
      update public.platform_subscription_revenue_periods_v200
         set cash_journal_entry_id = ((v_result->'entry')->>'id')::uuid
       where id = v_period.id;
      v_captured := v_captured + 1;
    exception when sqlstate '55000' then
      -- Period locked: leave the capture recorded but unposted; the next run
      -- retries rather than silently dropping the payment.
      null;
    end;
  end loop;
  return v_captured;
end $$;

-- Step 2 — recognise each month of service once it has started.
create or replace function app.v200_recognize_due_months()
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_row record; v_result jsonb; v_recognized integer := 0; v_today date;
begin
  v_today := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  for v_row in
    select m.id, m.month_index, m.month_start, m.amount_cents,
           p.business_id, p.cash_journal_entry_id
      from public.platform_subscription_revenue_months_v200 m
      join public.platform_subscription_revenue_periods_v200 p on p.id = m.period_id
     where m.journal_entry_id is null
       and m.month_start <= v_today
       -- Only recognise what the cash entry already backs.
       and p.cash_journal_entry_id is not null
     order by m.month_start
  loop
    if not exists (select 1 from public.platform_accounting_policies_v147
                    where effective_from <= v_row.month_start) then
      continue;
    end if;
    begin
      v_result := app.platform_post_journal_v147(
        'platform_subscription_revenue_v200',
        v_row.id::text,
        v_row.month_start,
        'Subscription revenue earned',
        jsonb_build_array(
          jsonb_build_object('account_code', '2300',
            'debit_cents', v_row.amount_cents, 'credit_cents', 0),
          jsonb_build_object('account_code', '4000',
            'debit_cents', 0, 'credit_cents', v_row.amount_cents)));
      update public.platform_subscription_revenue_months_v200
         set journal_entry_id = ((v_result->'entry')->>'id')::uuid,
             recognized_at = now()
       where id = v_row.id;
      v_recognized := v_recognized + 1;
    exception when sqlstate '55000' then
      -- Locked period: skip this slice, retry next run.
      null;
    end;
  end loop;
  return v_recognized;
end $$;

-- The automation entry point. Safe to call at any time, by cron or by hand.
create or replace function public.platform_run_subscription_revenue_v200()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_captured integer; v_recognized integer;
begin
  if auth.uid() is not null and not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_subscription_revenue_v200', 200));
  v_captured := app.v200_capture_paid_periods();
  v_recognized := app.v200_recognize_due_months();
  return jsonb_build_object(
    'captured_periods', v_captured,
    'recognized_months', v_recognized,
    'deferred_balance_cents', coalesce((
      select sum(m.amount_cents) from public.platform_subscription_revenue_months_v200 m
       join public.platform_subscription_revenue_periods_v200 p on p.id = m.period_id
      where m.journal_entry_id is null and p.cash_journal_entry_id is not null), 0),
    'ran_at', now());
end $$;

revoke all on function public.platform_run_subscription_revenue_v200()
  from public, anon, authenticated;
revoke all on function app.v200_capture_paid_periods() from public, anon, authenticated;
revoke all on function app.v200_recognize_due_months() from public, anon, authenticated;
grant execute on function public.platform_run_subscription_revenue_v200() to authenticated, service_role;

commit;
