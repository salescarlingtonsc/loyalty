-- nestly_v987 — the ledger can post a discounted invoice (2026-09-16).
--
-- Found by nestly_v986's own acceptance suite, on the first run after v986 was applied. The suite
-- inserted the first honestly-recorded discounted invoice this database has ever held and the
-- insert threw:
--
--     22023: journal must contain valid active accounts and balanced one-sided lines
--     CONTEXT: app.platform_post_journal_v147 <- app.platform_sync_provider_invoice_v147
--
-- app.platform_sync_provider_invoice_v147 posts a double entry when an invoice is issued:
--
--     1100 accounts receivable   debit   total_cents
--     4000 subscription revenue  credit  subtotal_ex_tax_cents
--     2200 GST output payable    credit  tax_cents        (only when tax > 0)
--
-- Before v986 those balanced for every row, because the appliers stored the discounted figure AS
-- the subtotal, so subtotal always equalled total. v986 made the subtotal the true list price --
-- and the entry immediately stopped balancing by exactly the discount: 85 of debits against 100 of
-- credits. The ledger has always been the last writer in the chain, so this would have surfaced as
-- a FAILED WEBHOOK EVENT, retried by nestly-v281-billing-event-redrive every five minutes for ever,
-- rather than as a wrong number.
--
-- THE FIX: revenue is recognised NET of the discount. `credit 4000 = subtotal - discount`, which is
-- the amount actually earned, and the entry balances against the receivable at total.
--
-- WHY NOT 4010. The chart already carries 4010 "Refunds, credits and discounts", a contra-revenue
-- account (normal balance: debit), and gross-revenue-plus-contra is the more informative
-- presentation -- it would put "discounts given" on the face of the ledger. It is deliberately NOT
-- taken here, because the discount would then have to be reversed in the void path and re-posted in
-- BOTH recovery paths (uncollectible-recovery and void-recovery), which is a four-place change to
-- live double-entry code in service of presentation. Net recognition leaves every one of those
-- paths arithmetically identical to what it does today -- they all work from total_cents and
-- tax_cents, neither of which changed meaning -- so this migration touches exactly one line of
-- accounting. The discount is not lost: it is on the invoice row as discount_cents, which is where
-- reporting reads it and what consumed_discount_cents was always meant to carry. Moving to the
-- gross presentation later is a clean, separate change.
--
-- No backfill: all 13 invoices on this estate carry discount_cents = 0, so every existing journal
-- entry is already correct under the new expression, which reduces to the old one when discount is
-- zero. Asserted below rather than assumed.
--
-- Rollback suite: db/tests/v986_a_discounted_payment_is_still_a_payment.sql (this is what made it
-- fail; assertions 1 and 3 do not pass without this migration).

begin;

do $v987_assert$
declare v_bad integer;
begin
  select count(*) into v_bad from public.billing_provider_invoices where discount_cents <> 0;
  if v_bad > 0 then
    raise exception 'v987: % invoices already carry a discount -- their journal entries need a backfill, not just a new expression', v_bad;
  end if;
  if position('discount_cents' in pg_get_functiondef(
       'app.platform_sync_provider_invoice_v147(public.billing_provider_invoices)'::regprocedure)) > 0 then
    raise exception 'v987: platform_sync_provider_invoice_v147 already knows about discount_cents';
  end if;
end
$v987_assert$;

CREATE OR REPLACE FUNCTION app.platform_sync_provider_invoice_v147(p_invoice billing_provider_invoices)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_date date;v_result jsonb;v_counterparty text:=p_invoice.business_id::text;v_issued uuid;v_terminal uuid;
  v_target_paid bigint:=least(p_invoice.total_cents,p_invoice.amount_paid_cents);v_posted_paid bigint;v_payment_delta bigint;
  v_remaining bigint;v_remaining_tax bigint;v_remaining_subtotal bigint;v_lines jsonb;
  v_terminal_total bigint;v_recovered_total bigint;v_recovery_delta bigint;v_recovered_tax bigint;v_prior_recovered_tax bigint;v_recovery_tax bigint;v_recovery_subtotal bigint;
begin
  if p_invoice.currency<>'SGD' or p_invoice.status='draft' or p_invoice.total_cents<=0 then return;end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_provider_invoice_state:'||p_invoice.provider_invoice_id,147));
  v_date:=(coalesce(p_invoice.created_at,clock_timestamp()) at time zone 'Asia/Singapore')::date;
  select id into v_issued from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_issued' and source_id=p_invoice.provider_invoice_id;
  if v_issued is null then
    v_result:=app.platform_post_journal_v147('provider_invoice_issued',p_invoice.provider_invoice_id,v_date,'Provider invoice '||p_invoice.provider_invoice_id||' issued',jsonb_build_array(
      jsonb_build_object('account_code','1100','debit_cents',p_invoice.total_cents,'credit_cents',0,'counterparty',v_counterparty),
      jsonb_build_object('account_code','4000','debit_cents',0,'credit_cents',p_invoice.subtotal_ex_tax_cents-p_invoice.discount_cents,'counterparty',v_counterparty)
    )||case when p_invoice.tax_cents>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',p_invoice.tax_cents,'counterparty',v_counterparty)) else '[]'::jsonb end,null,null,null,null);
    v_issued:=(v_result#>>'{entry,id}')::uuid;
  end if;

  select coalesce(sum(line.debit_cents),0) into v_posted_paid
    from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='1010'
   where entry.source_type='provider_invoice_payment' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
  v_payment_delta:=greatest(0,v_target_paid-v_posted_paid);
  if v_payment_delta>0 then
    v_date:=(coalesce(p_invoice.paid_at,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null and not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id=p_invoice.provider_invoice_id) then
      select coalesce(sum(debit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='6300';
      select coalesce(sum(line.credit_cents),0) into v_recovered_total from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='6300' where entry.source_type='provider_invoice_uncollectible_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
      v_recovery_delta:=least(v_payment_delta,greatest(0,v_terminal_total-v_recovered_total));
      if v_recovery_delta>0 then
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible_recovery',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Recovery of uncollectible provider invoice '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','6300','debit_cents',0,'credit_cents',v_recovery_delta,'counterparty',v_counterparty)
        ),null,null,null,v_terminal);
      end if;
    end if;
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_void' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null then
      select coalesce(sum(credit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='1100';
      select coalesce(sum(line.debit_cents),0),coalesce(sum(line.credit_cents) filter(where line.account_code='2200'),0)
        into v_recovered_total,v_prior_recovered_tax from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id where entry.source_type='provider_invoice_void_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':' and line.account_code in ('1100','2200');
      v_recovery_delta:=least(v_payment_delta,greatest(0,v_terminal_total-v_recovered_total));
      if v_recovery_delta>0 then
        v_recovered_tax:=round((v_recovered_total+v_recovery_delta)*p_invoice.tax_cents::numeric/p_invoice.total_cents);
        v_recovery_tax:=v_recovered_tax-v_prior_recovered_tax;v_recovery_subtotal:=v_recovery_delta-v_recovery_tax;
        v_lines:=jsonb_build_array(jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),jsonb_build_object('account_code','4000','debit_cents',0,'credit_cents',v_recovery_subtotal,'counterparty',v_counterparty))||case when v_recovery_tax>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',v_recovery_tax,'counterparty',v_counterparty)) else '[]'::jsonb end;
        v_result:=app.platform_post_journal_v147('provider_invoice_void_recovery',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Recovery of void provider invoice '||p_invoice.provider_invoice_id,v_lines,null,null,null,v_terminal);
      end if;
    end if;
    v_result:=app.platform_post_journal_v147('provider_invoice_payment',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Provider invoice payment '||p_invoice.provider_invoice_id,jsonb_build_array(
      jsonb_build_object('account_code','1010','debit_cents',v_payment_delta,'credit_cents',0,'counterparty',v_counterparty),
      jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_payment_delta,'counterparty',v_counterparty)
    ),null,null,null,null);
  end if;

  if p_invoice.status='void' then
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null and not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id=p_invoice.provider_invoice_id) then
      select coalesce(sum(debit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='6300';
      select coalesce(sum(line.credit_cents),0) into v_recovered_total from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='6300' where entry.source_type='provider_invoice_uncollectible_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
      v_recovery_delta:=greatest(0,v_terminal_total-v_recovered_total);
      if v_recovery_delta>0 then
        v_date:=(coalesce(p_invoice.voided_at,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible_to_void',p_invoice.provider_invoice_id,v_date,'Reclassify uncollectible provider invoice before void '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','6300','debit_cents',0,'credit_cents',v_recovery_delta,'counterparty',v_counterparty)
        ),null,null,null,v_terminal);
      end if;
    end if;
  end if;

  if p_invoice.status in ('void','uncollectible') then
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type=case when p_invoice.status='void' then 'provider_invoice_void' else 'provider_invoice_uncollectible' end and source_id=p_invoice.provider_invoice_id;
    v_remaining:=greatest(0,p_invoice.total_cents-v_target_paid);
    if v_terminal is null and v_remaining>0 then
      v_date:=(coalesce(case when p_invoice.status='void' then p_invoice.voided_at else p_invoice.marked_uncollectible_at end,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
      if p_invoice.status='void' then
        v_remaining_tax:=round(v_remaining*p_invoice.tax_cents::numeric/p_invoice.total_cents);
        v_remaining_subtotal:=v_remaining-v_remaining_tax;
        v_lines:=jsonb_build_array(
          jsonb_build_object('account_code','4000','debit_cents',v_remaining_subtotal,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_remaining,'counterparty',v_counterparty)
        )||case when v_remaining_tax>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',v_remaining_tax,'credit_cents',0,'counterparty',v_counterparty)) else '[]'::jsonb end;
        v_result:=app.platform_post_journal_v147('provider_invoice_void',p_invoice.provider_invoice_id,v_date,'Void provider invoice '||p_invoice.provider_invoice_id,v_lines,null,null,null,v_issued);
      else
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible',p_invoice.provider_invoice_id,v_date,'Provider invoice marked uncollectible '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','6300','debit_cents',v_remaining,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_remaining,'counterparty',v_counterparty)
        ),null,null,null,v_issued);
      end if;
    end if;
  end if;
end
$function$;

commit;
