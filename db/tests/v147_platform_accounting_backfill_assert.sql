-- Run after V147 on the disposable database prepared by the setup fixture.
begin;
do $v147_backfill_assert$
declare v_invoice text:='in_v147_historical_chain';
begin
  if (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_issued' and source_id=v_invoice)<>1
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_payment' and left(source_id,length(v_invoice)+1)=v_invoice||':')<>2
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible' and source_id=v_invoice)<>1
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id=v_invoice)<>1
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_void' and source_id=v_invoice)<>1
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_void_recovery' and left(source_id,length(v_invoice)+1)=v_invoice||':')<>1 then
    raise exception 'historical provider transition chain was not reconstructed';
  end if;
  if exists(select 1 from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id=v_invoice or left(entry.source_id,length(v_invoice)+1)=v_invoice||':') and line.account_code in ('1100','6300') group by line.account_code having sum(line.debit_cents-line.credit_cents)<>0)
     or (select coalesce(sum(line.credit_cents-line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id=v_invoice or left(entry.source_id,length(v_invoice)+1)=v_invoice||':') and line.account_code='4000')<>100
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where left(entry.source_id,length(v_invoice)+1)=v_invoice||':' and line.account_code='1010')<>100 then
    raise exception 'historical provider chain balances do not match live accounting';
  end if;
  if not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_payment' and source_id=v_invoice||':40' and journal_date='2026-10-02')
     or not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_payment' and source_id=v_invoice||':100' and journal_date='2026-10-05') then
    raise exception 'historical partial and final cash dates were collapsed';
  end if;
end
$v147_backfill_assert$;
rollback;
