-- nestly_v990 — provider-cleared cash must prove it came from a live invoice.
--
-- Two findings, both from checking rather than assuming.
--
-- FIRST, v989's guard was INCOMPLETE. After applying it, 22 of the 66 queued revenue slices were
-- blocked and 44 were not. v989 asked "is there a billing_provider_invoices row for this period
-- that is NOT livemode". That catches a period whose invoice_reference is a Stripe invoice id and
-- does nothing for the other four periods, whose invoice_reference is a bare UUID with no matching
-- row at all - the retired Razorpay firms (nestly_v984). Absence of evidence read as evidence of
-- innocence, and 44 slices worth 447,868 cents stayed armed to recognise from 2026-10-04.
--
-- THE RULE THAT HOLDS: money sitting in a PROVIDER clearing account must be traceable to a LIVE
-- provider invoice. Account 1010 exists precisely because a payment processor is holding that
-- cash; if no livemode invoice can be produced for it, the processor is not holding it and it is
-- not revenue. Stated positively - prove it is live - rather than negatively, so a missing row, a
-- retired provider, a renamed id, or a provider we have not integrated yet all fail CLOSED.
--
-- Manual firms are deliberately untouched. They clear through 1000, are invoiced by hand and pay by
-- bank transfer, and have no provider invoice to produce. The guards only speak about provider cash.
--
-- SECOND, these two functions are RESTATED here rather than patched. v989 originally patched them
-- by replacing a multi-line anchor lifted from production, and that migration could not be replayed
-- on a clean database: production's stored body had been through a path that strips SQL comments,
-- so it differs from the repo text a rebuild is built from, and the anchor matched exactly one of
-- the two worlds. A restatement has no such dependency - it produces the same body from any
-- starting point. The bodies below are v200's originals with the guard added and nothing else
-- changed; the comment v200 shipped with is kept, so repo and database now agree.
--
-- Measured against production before applying: 66 of 66 pending slices blocked, 0 manual periods
-- affected, and a period re-pointed at a live invoice recognises again - so the guard tests
-- liveness rather than simply refusing everything.

begin;

create or replace function app.v200_recognize_due_months()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
       /* nestly_v990: and only what a payment processor can be shown to be holding. Cash in a
          provider clearing account must be traceable to a LIVE invoice; a missing row, a retired
          provider or an unmatched id all fail closed. Manual periods clear through 1000 and are
          untouched. */
       and (p.cash_account_code <> '1010'
            or exists (select 1 from public.billing_provider_invoices good
                        where good.provider_invoice_id = p.invoice_reference
                          and coalesce(good.livemode, false)))
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
      null;
    end;
  end loop;
  return v_recognized;
end $$;

comment on function app.v200_recognize_due_months() is
  'nestly_v200 + v990: releases deferred subscription revenue month by month. Since v990 a slice is only earned when its period''s provider cash can be traced to a livemode invoice; manual periods are unaffected.';

create or replace function app.v200_capture_paid_periods()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
       /* nestly_v990: a provider-billed subscription must produce a LIVE paid invoice before its
          cash is deferred. A manual firm has no provider subscription and passes. */
       and (s.provider_subscription_id is null
            or exists (select 1 from public.billing_provider_invoices good
                        where good.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'')),'')
                          and coalesce(good.livemode, false)))
       and not exists (
         select 1 from public.platform_subscription_revenue_periods_v200 p
          where p.business_id = s.business_id
            and p.period_start = (s.current_period_start at time zone 'Asia/Singapore')::date
            and p.period_end = (s.current_period_end at time zone 'Asia/Singapore')::date)
  loop
    v_post_date := (v_sub.last_paid_at at time zone 'Asia/Singapore')::date;
    if not exists (select 1 from public.platform_accounting_policies_v147
                    where effective_from <= v_post_date) then
      continue;
    end if;
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
      null;
    end;
  end loop;
  return v_captured;
end $$;

comment on function app.v200_capture_paid_periods() is
  'nestly_v200 + v990: opens a deferral period for each newly paid subscription. Since v990 a provider-billed subscription must produce a livemode paid invoice first; manual firms are unaffected.';

commit;
