-- nestly_v989 — the general ledger records live money only.
--
-- FOUND BY AUDITING THE BOOKS against the bank, at the owner's request, before building statutory
-- accounting on top of them. The trial balance balances to the cent and is almost entirely fiction:
--
--     1010 Stripe clearing              21,634.00 Dr
--     1100 Accounts receivable                  -      (issued and collected)
--     2300 Deferred subscription revenue  6,647.68 Cr
--     4000 Subscription revenue          14,986.32 Cr
--                                       ---------
--                                        36,620.32 both sides, zero unbalanced entries
--
-- Against billing_provider_invoices:
--
--     livemode = false   12 invoices   14,380.00   <- Stripe TEST mode
--     livemode = true     1 invoice         1.00   <- every real dollar this company has earned
--
-- So the ledger has recognised 14,986.32 of revenue for a company that has invoiced one dollar,
-- and reports 21,634.00 of cash it does not have. Nothing validated substance: every control in
-- v147 checks form (balance, immutability, period lock, idempotency) and not one of them asks
-- whether the money was real.
--
-- IT IS STILL GETTING WORSE. platform-subscription-revenue-v200 is an ACTIVE cron at 00:20 SGT,
-- and platform_subscription_revenue_months_v200 holds 66 unrecognised slices worth 664,768 cents
-- dated 2026-10-04 to 2027-08-05 - which is precisely the deferred revenue balance above. From
-- 4 October it would have recognised sandbox revenue nightly, into the book that FY2026's ECI and
-- Form C-S will be built from.
--
-- THE ROOT CAUSE is one missing clause in three places. app.platform_sync_provider_invoice_v147
-- opens with
--
--     if p_invoice.currency<>'SGD' or p_invoice.status='draft' or p_invoice.total_cents<=0 then return
--
-- which screens currency, drafts and non-positive amounts, and never asks about livemode. The two
-- v200 revenue functions never ask either. Sandbox money therefore walks into the statutory ledger
-- through the front door.
--
-- WHAT THIS MIGRATION DOES, and deliberately does not do. It closes the door, in all three places,
-- so no further test-mode money can ever be posted and the 66 queued slices can never fire. It
-- does NOT reverse the 40 entries already posted. Voiding and reopening the book of record is the
-- right next step, but it is the owner's call and a considered one: it restarts journal numbering,
-- it needs an attributed opening balance for the one real dollar, and it wants the manual-journal
-- tool that does not exist yet. Stopping the bleeding does not require that decision, and must not
-- wait for it.
--
-- WHY GUARD RATHER THAN DISABLE THE CRON. Deactivating the job would stop tonight and would be
-- silently re-armed by the next person who looks at a paused cron and wonders why. A guard in the
-- function is the invariant itself: this ledger holds real money, and it says so in the code that
-- would otherwise post.
--
-- A MANUAL firm has no provider invoice at all - it is invoiced by hand and pays by bank transfer,
-- which is real money. The guards below therefore only reject a period or an invoice that IS
-- provider-billed and IS sandbox; absence of a provider invoice is not evidence of fakeness.

begin;

/* nestly_v989: patched by extraction with asserted-unique needles, so nothing else in these long
   accounting functions moves. */
do $patch$
declare
  v_def text;
  v_hits integer;
  v_target text;
  v_old text;
  v_new text;
  v_targets text[] := array[
    'app.platform_sync_provider_invoice_v147',
    'app.v200_recognize_due_months',
    'app.v200_capture_paid_periods'
  ];
  v_olds text[] := array[
    'if p_invoice.currency<>''SGD'' or p_invoice.status=''draft'' or p_invoice.total_cents<=0 then return;end if;',
    E'     where m.journal_entry_id is null\n       and m.month_start <= v_today\n       and p.cash_journal_entry_id is not null',
    E'            and p.period_end = (s.current_period_end at time zone ''Asia/Singapore'')::date)'
  ];
  v_news text[] := array[
    /* nestly_v989: sandbox money is not this company's money. */
    'if p_invoice.currency<>''SGD'' or p_invoice.status=''draft'' or p_invoice.total_cents<=0'
      || ' or not coalesce(p_invoice.livemode,false) then return;end if;',
    E'     where m.journal_entry_id is null\n'
      || E'       and m.month_start <= v_today\n'
      || E'       and p.cash_journal_entry_id is not null\n'
      || E'       /* nestly_v989: a slice whose period was paid by a TEST-mode invoice is not revenue.\n'
      || E'          66 such slices were queued to 2027-08-05 when this guard was written. */\n'
      || E'       and not exists (select 1 from public.billing_provider_invoices bad\n'
      || E'                        where bad.provider_invoice_id = p.invoice_reference\n'
      || E'                          and not coalesce(bad.livemode,false))',
    E'            and p.period_end = (s.current_period_end at time zone ''Asia/Singapore'')::date)\n'
      || E'       /* nestly_v989: never capture a period settled by a TEST-mode invoice. A manual firm\n'
      || E'          has no provider invoice at all and is unaffected - absence is not fakeness. */\n'
      || E'       and not exists (select 1 from public.billing_provider_invoices bad\n'
      || E'                        where bad.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'''')),'''')\n'
      || E'                          and not coalesce(bad.livemode,false))'
  ];
  i integer;
begin
  for i in 1 .. array_length(v_targets,1) loop
    v_target := v_targets[i]; v_old := v_olds[i]; v_new := v_news[i];
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = split_part(v_target,'.',1) and p.proname = split_part(v_target,'.',2);
    if v_def is null then raise exception 'v989: % does not exist', v_target; end if;
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'v989: expected exactly 1 anchor in %, found %', v_target, v_hits;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$patch$;

comment on function app.platform_sync_provider_invoice_v147(public.billing_provider_invoices) is
  'nestly_v147 + v989: posts a provider invoice to the general ledger. Refuses non-SGD, drafts, non-positive totals and - since v989 - anything that is not livemode, because the statutory ledger holds real money only.';

commit;
