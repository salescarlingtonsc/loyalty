-- Rollback-only V147 automated accounting and financial-document evidence.
begin;

create or replace function pg_temp.as_v147_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v147_user(uuid,text) to public;

do $v147_test$
declare
  v_sa uuid:=gen_random_uuid();v_outsider uuid:=gen_random_uuid();v_business uuid;
  v_result jsonb;v_invoice_result jsonb;v_invoice uuid;v_gst_small uuid;v_receipt uuid;v_credit uuid;v_debit uuid;v_expense uuid;
  v_reversal uuid;v_lines bigint;v_debits bigint;v_credits bigint;
begin
  select id into v_business from public.businesses order by created_at limit 1;
  if v_business is null then raise exception 'v147 requires one synthetic business';end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated','v147-sa@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated','v147-out@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note) values(v_sa,'v147-sa@example.test','v147 rollback fixture');

  perform pg_temp.as_v147_user(v_sa);
  v_result:=public.platform_set_accounting_policy_v147('2026-01-01','Peekaa Synthetic Pte. Ltd.','202600001P','1 Synthetic Street, Singapore','not_registered',null,0,12,31,'PKA','Owner-reviewed synthetic non-GST policy','14700000-0000-4000-8000-000000000001');
  if coalesce((v_result#>>'{policy,version}')::integer,0)<>1 then raise exception 'accounting policy was not versioned';end if;
  v_result:=public.platform_set_accounting_policy_v147('2026-01-01','Peekaa Synthetic Pte. Ltd.','202600001P','1 Synthetic Street, Singapore','not_registered',null,0,12,31,'PKA','Owner-reviewed synthetic non-GST policy','14700000-0000-4000-8000-000000000001');
  if not (v_result->>'replayed')::boolean then raise exception 'accounting policy retry did not replay';end if;
  reset role;

  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,net_cash_ex_tax_cents,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id,created_at
  ) values(v_business,'cus_v147','in_v147_paid','NON-SUBSCRIPTION-V147-001','SGD','paid',true,
    135700,0,135700,135700,135700,0,135700,'2026-08-03T01:00:00Z',false,
    '2026-08-03T01:00:00Z',70,'evt_v147_paid','2026-08-03T00:30:00Z');
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,tax_cents,total_cents,
    currency,source_event_id,provider_object_id,reason,evidence_sha256,occurred_at
  ) values(v_business,'in_v147_paid','refund',-2000,0,-2000,'SGD','evt_v147_refund','re_v147_refund','Synthetic partial refund',repeat('d',64),'2026-08-03T02:00:00Z');

  perform pg_temp.as_v147_user(v_sa);
  v_result:=public.platform_record_operating_expense_v147('2026-08-03','software','Synthetic software and marketing total',40000,'Synthetic Cloud Pte. Ltd.','202677777C','BANK-EXPENSE-001','SYNTHETIC-RECEIPT-001','14700000-0000-4000-8000-000000000002');
  v_expense:=(v_result#>>'{entry,id}')::uuid;
  if v_result#>>'{document,document_number}'<>'PKA-PV-000001' then raise exception 'supplier expense did not generate a payment voucher';end if;
  v_result:=public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-MERIDIAN-20260804',
    '{"legal_name":"Meridian Wellness Pte. Ltd.","registration_number":"202688881M","address":"2 Synthetic Road, Singapore"}',
    '[{"description":"Implementation service","quantity":1,"unit_amount_cents":25000}]',0,
    '14700000-0000-4000-8000-000000000003');
  v_invoice_result:=v_result;
  v_invoice:=(v_result#>>'{document,id}')::uuid;
  if v_result#>>'{document,document_number}'<>'PKA-INV-000001' then raise exception 'invoice numbering is not deterministic';end if;
  v_result:=public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-MERIDIAN-20260804',
    '{"legal_name":"Meridian Wellness Pte. Ltd.","registration_number":"202688881M","address":"2 Synthetic Road, Singapore"}',
    '[{"description":"Implementation service","quantity":1,"unit_amount_cents":25000}]',0,
    '14700000-0000-4000-8000-000000000003');
  if not (v_result->>'replayed')::boolean or (v_result#>>'{document,id}')::uuid<>v_invoice then raise exception 'invoice retry was not exact';end if;
  begin
    perform public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-MERIDIAN-20260804','{"legal_name":"Changed Party"}','[{"description":"Changed","quantity":1,"unit_amount_cents":1}]',0,'14700000-0000-4000-8000-000000000003');
    raise exception 'changed invoice payload replayed';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-MERIDIAN-20260804','{"legal_name":"Duplicate Customer"}','[{"description":"Duplicate source","quantity":1,"unit_amount_cents":25000}]',0,'14700000-0000-4000-8000-000000000018');
    raise exception 'generated invoice accepted a duplicate economic source reference';
  exception when unique_violation then null;
  end;
  begin
    perform public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-V147-001','{"legal_name":"Provider Duplicate"}','[{"description":"Provider duplicate source","quantity":1,"unit_amount_cents":25000}]',0,'14700000-0000-4000-8000-000000000019');
    raise exception 'generated invoice accepted a provider invoice reference';
  exception when unique_violation then null;
  end;
  v_result:=public.platform_issue_debit_note_v147(v_invoice,'2026-08-04',3000,0,'Additional reviewed service','14700000-0000-4000-8000-000000000012');
  v_debit:=(v_result#>>'{document,id}')::uuid;
  if v_result#>>'{document,document_number}'<>'PKA-DN-000001' then raise exception 'debit note numbering failed';end if;
  v_result:=public.platform_reverse_financial_document_v147(v_debit,'2026-08-04','Additional service was not delivered','14700000-0000-4000-8000-000000000013');
  if v_result#>>'{document,document_number}'<>'PKA-JV-000001' then raise exception 'debit note reversal voucher failed';end if;
  v_result:=public.platform_record_invoice_receipt_v147(v_invoice,'2026-08-05',10000,'BANK-TRANSFER-001','14700000-0000-4000-8000-000000000004');
  v_receipt:=(v_result#>>'{document,id}')::uuid;
  if (v_result->>'remaining_cents')::integer<>15000 or v_result#>>'{document,document_number}'<>'PKA-RCT-000001' then raise exception 'partial receipt did not retain exact balance';end if;
  v_result:=public.platform_issue_credit_note_v147(v_invoice,'2026-08-06',5000,0,'Scope reduced after review','14700000-0000-4000-8000-000000000005');
  v_credit:=(v_result#>>'{document,id}')::uuid;
  if v_result#>>'{document,document_number}'<>'PKA-CN-000001' then raise exception 'credit note numbering failed';end if;
  if v_invoice_result#>>'{snapshot,issuer,legal_name}'<>'Peekaa Synthetic Pte. Ltd.' then raise exception 'issued document lost its immutable issuer snapshot';end if;
  v_result:=public.platform_get_accounting_books_v147('2026-08-01','2026-08-31',5000);
  reset role;

  select count(*),sum(line.debit_cents),sum(line.credit_cents) into v_lines,v_debits,v_credits from public.platform_accounting_journal_lines_v147 line;
  if v_lines<12 or v_debits<>v_credits then raise exception 'automated journals are incomplete or unbalanced';end if;
  if (v_result#>>'{summary,revenue_cents}')::bigint<>153700
     or (v_result#>>'{summary,expense_cents}')::bigint<>40000
     or (v_result#>>'{summary,profit_cents}')::bigint<>113700
     or (v_result#>>'{summary,assets_cents}')::bigint<>113700
     or (v_result#>>'{summary,liabilities_cents}')::bigint<>0
     or (v_result#>>'{summary,equity_and_current_profit_cents}')::bigint<>113700 then
    raise exception 'books do not reconcile: %',v_result->'summary';
  end if;
  if (select sum((row->>'period_debits_cents')::bigint) from jsonb_array_elements(v_result->'trial_balance') row)
     <>(select sum((row->>'period_credits_cents')::bigint) from jsonb_array_elements(v_result->'trial_balance') row) then raise exception 'trial balance does not balance';end if;
  if (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_payment' and source_id='in_v147_paid:135700')<>1
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='platform_expense' and source_id=v_expense::text)<>1 then raise exception 'authoritative source posted more than once';end if;

  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,net_cash_ex_tax_cents,livemode,provider_event_created_at,
    provider_event_rank,last_event_id,created_at
  ) values
    (v_business,'cus_v147_void','in_v147_void','V147-VOID','SGD','open',false,100,0,100,100,0,100,0,false,'2026-09-04T01:00:00Z',50,'evt_v147_void_open','2026-09-04T01:00:00Z'),
    (v_business,'cus_v147_bad','in_v147_bad','V147-BAD','SGD','open',false,100,0,100,100,0,100,0,false,'2026-09-05T01:00:00Z',50,'evt_v147_bad_open','2026-09-05T01:00:00Z'),
    (v_business,'cus_v147_partial','in_v147_partial_void','V147-PARTIAL','SGD','open',false,100,0,100,100,40,60,40,false,'2026-09-06T01:00:00Z',50,'evt_v147_partial_open','2026-09-06T01:00:00Z'),
    (v_business,'cus_v147_bad_void','in_v147_bad_void','V147-BAD-VOID','SGD','open',false,100,0,100,100,40,60,40,false,'2026-09-07T01:00:00Z',50,'evt_v147_bad_void_open','2026-09-07T01:00:00Z');
  update public.billing_provider_invoices set status='void',voided_at='2026-09-04T02:00:00Z',amount_remaining_cents=0,provider_event_created_at='2026-09-04T02:00:00Z',provider_event_rank=60,last_event_id='evt_v147_voided' where provider_invoice_id='in_v147_void';
  update public.billing_provider_invoices set status='uncollectible',marked_uncollectible_at='2026-09-05T02:00:00Z',provider_event_created_at='2026-09-05T02:00:00Z',provider_event_rank=70,last_event_id='evt_v147_bad' where provider_invoice_id='in_v147_bad';
  if (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_id='in_v147_void' and line.account_code='1100')<>0
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_void' and source_id='in_v147_void')<>1 then raise exception 'void provider invoice left accrual balances posted';end if;
  if (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_id='in_v147_bad' and line.account_code='1100')<>0
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_type='provider_invoice_uncollectible' and entry.source_id='in_v147_bad' and line.account_code='6300')<>100 then raise exception 'uncollectible provider invoice did not clear receivable to bad debt';end if;
  update public.billing_provider_invoices set status='void',voided_at='2026-09-06T02:00:00Z',amount_remaining_cents=0,provider_event_created_at='2026-09-06T02:00:00Z',provider_event_rank=60,last_event_id='evt_v147_partial_void' where provider_invoice_id='in_v147_partial_void';
  if (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_partial_void' or left(entry.source_id,length('in_v147_partial_void')+1)='in_v147_partial_void:') and line.account_code='1100')<>0
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_type='provider_invoice_payment' and left(entry.source_id,length('in_v147_partial_void')+1)='in_v147_partial_void:' and line.account_code='1010')<>40 then raise exception 'partial payment then void did not reconcile cash and receivable';end if;
  update public.billing_provider_invoices set status='uncollectible',marked_uncollectible_at='2026-09-07T02:00:00Z',provider_event_created_at='2026-09-07T02:00:00Z',provider_event_rank=70,last_event_id='evt_v147_bad_void_bad' where provider_invoice_id='in_v147_bad_void';
  update public.billing_provider_invoices set status='void',voided_at='2026-09-07T03:00:00Z',amount_remaining_cents=0,provider_event_created_at='2026-09-07T03:00:00Z',provider_event_rank=80,last_event_id='evt_v147_bad_void_void' where provider_invoice_id='in_v147_bad_void';
  if (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_bad_void' or left(entry.source_id,length('in_v147_bad_void')+1)='in_v147_bad_void:') and line.account_code='1100')<>0
     or (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_id='in_v147_bad_void' and line.account_code='6300')<>0
     or (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_id='in_v147_bad_void' and line.account_code='4000')<>-40
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where left(entry.source_id,length('in_v147_bad_void')+1)='in_v147_bad_void:' and line.account_code='1010')<>40
     or (select count(*) from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id='in_v147_bad_void')<>1 then raise exception 'uncollectible then void did not reclassify terminal accounting';end if;
  update public.billing_provider_invoices set status='paid',paid_normalized=true,amount_paid_cents=100,amount_remaining_cents=0,net_cash_ex_tax_cents=100,paid_at='2026-09-07T04:00:00Z',provider_event_created_at='2026-09-07T04:00:00Z',provider_event_rank=100,last_event_id='evt_v147_bad_void_paid' where provider_invoice_id='in_v147_bad_void';
  if exists(select 1 from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_bad_void' or left(entry.source_id,length('in_v147_bad_void')+1)='in_v147_bad_void:') and line.account_code in ('1100','6300') group by line.account_code having sum(line.debit_cents-line.credit_cents)<>0)
     or (select coalesce(sum(line.credit_cents-line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_bad_void' or left(entry.source_id,length('in_v147_bad_void')+1)='in_v147_bad_void:') and line.account_code='4000')<>100
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where left(entry.source_id,length('in_v147_bad_void')+1)='in_v147_bad_void:' and line.account_code='1010')<>100 then raise exception 'partial uncollectible then void then paid did not reconcile';end if;
  update public.businesses set name='Renamed Synthetic Business' where id=v_business;
  update public.billing_provider_invoices set status='paid',paid_normalized=true,amount_paid_cents=100,amount_remaining_cents=0,net_cash_ex_tax_cents=100,paid_at='2026-09-05T03:00:00Z',provider_event_created_at='2026-09-05T03:00:00Z',provider_event_rank=100,last_event_id='evt_v147_bad_paid' where provider_invoice_id='in_v147_bad';
  if (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_bad' or left(entry.source_id,length('in_v147_bad')+1)='in_v147_bad:') and line.account_code='1100')<>0
     or (select coalesce(sum(line.debit_cents-line.credit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where (entry.source_id='in_v147_bad' or left(entry.source_id,length('in_v147_bad')+1)='in_v147_bad:') and line.account_code='6300')<>0
     or (select coalesce(sum(line.debit_cents),0) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id where entry.source_type='provider_invoice_payment' and left(entry.source_id,length('in_v147_bad')+1)='in_v147_bad:' and line.account_code='1010')<>100 then raise exception 'uncollectible recovery after business rename did not reconcile';end if;

  perform pg_temp.as_v147_user(v_sa);
  v_result:=public.platform_reverse_financial_document_v147(v_receipt,'2026-08-07','Bank transfer was returned','14700000-0000-4000-8000-000000000006');
  v_reversal:=(v_result#>>'{document,id}')::uuid;
  if v_result#>>'{document,document_number}'<>'PKA-JV-000002' then raise exception 'document reversal voucher was not generated';end if;
  v_result:=public.platform_record_invoice_receipt_v147(v_invoice,'2026-08-08',10000,'BANK-TRANSFER-RETRY','14700000-0000-4000-8000-000000000007');
  if (v_result->>'remaining_cents')::integer<>10000 then raise exception 'reversed receipt still reduced receivable';end if;
  v_result:=public.platform_set_accounting_policy_v147('2026-09-01','Peekaa Synthetic Pte. Ltd.','202600001P','1 Synthetic Street, Singapore','registered','M21234567K',900,12,31,'PKA','Synthetic GST registration review','14700000-0000-4000-8000-000000000014');
  v_result:=public.platform_create_invoice_v147('2026-09-01','2026-09-30','NON-SUBSCRIPTION-GST-20260901','{"legal_name":"GST Customer Pte. Ltd.","registration_number":"202655555G","address":"5 Synthetic Avenue, Singapore"}','[{"description":"GST implementation service","quantity":1,"unit_amount_cents":10000}]',900,'14700000-0000-4000-8000-000000000015');
  begin
    perform public.platform_issue_credit_note_v147((v_result#>>'{document,id}')::uuid,'2026-09-02',1000,0,'Invalid tax reversal','14700000-0000-4000-8000-000000000016');
    raise exception 'GST credit note accepted a non-proportional tax reversal';
  exception when invalid_parameter_value then null;
  end;
  perform public.platform_issue_credit_note_v147((v_result#>>'{document,id}')::uuid,'2026-09-02',1000,90,'Proportional GST correction','14700000-0000-4000-8000-000000000016');
  v_result:=public.platform_create_invoice_v147('2026-09-06','2026-09-30','NON-SUBSCRIPTION-GST-ROUNDING-20260906','{"legal_name":"GST Rounding Customer Pte. Ltd.","registration_number":"202655556H","address":"6 Synthetic Avenue, Singapore"}','[{"description":"GST rounding service","quantity":1,"unit_amount_cents":100}]',900,'14700000-0000-4000-8000-000000000020');
  v_gst_small:=(v_result#>>'{document,id}')::uuid;
  perform public.platform_issue_credit_note_v147(v_gst_small,'2026-09-06',6,1,'First proportional rounding credit','14700000-0000-4000-8000-000000000021');
  begin
    perform public.platform_issue_credit_note_v147(v_gst_small,'2026-09-06',6,1,'Second cumulative rounding credit','14700000-0000-4000-8000-000000000022');
    raise exception 'cumulative GST credits exceeded proportional original tax';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.platform_issue_debit_note_v147((v_result#>>'{document,id}')::uuid,'2026-09-03',1000,90,'GST debit request','14700000-0000-4000-8000-000000000017');
    raise exception 'GST-bearing debit note was accepted';
  exception when invalid_parameter_value then null;
  end;
  v_result:=public.platform_set_accounting_period_lock_v147('2026-08-01','2026-08-31',true,'August books reviewed and closed','14700000-0000-4000-8000-000000000008');
  begin
    perform public.platform_create_invoice_v147('2026-08-20','2026-08-31','NON-SUBSCRIPTION-LOCKED-20260820','{"legal_name":"Locked Period Customer"}','[{"description":"Blocked service","quantity":1,"unit_amount_cents":100}]',0,'14700000-0000-4000-8000-000000000009');
    raise exception 'locked period accepted a posting';
  exception when object_not_in_prerequisite_state then null;
  end;
  perform public.platform_set_accounting_period_lock_v147('2026-08-01','2026-08-31',false,'Owner approved correction window','14700000-0000-4000-8000-000000000010');
  reset role;
  if app.platform_accounting_date_locked_v147('2026-08-20') then raise exception 'period unlock event was ineffective';end if;

  begin
    perform app.platform_post_journal_v147('invalid_test','unbalanced','2026-09-01','Unbalanced journal','[{"account_code":"1000","debit_cents":100,"credit_cents":0},{"account_code":"4090","debit_cents":0,"credit_cents":99}]');
    raise exception 'unbalanced journal was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    update public.platform_accounting_journal_entries_v147 set description='mutated' where id=(select id from public.platform_accounting_journal_entries_v147 limit 1);
    raise exception 'posted journal accepted mutation';
  exception when object_not_in_prerequisite_state then null;
  end;
  begin
    update public.platform_financial_documents_v147 set total_cents=1 where id=v_invoice;
    raise exception 'issued document accepted mutation';
  exception when object_not_in_prerequisite_state then null;
  end;
  begin
    perform pg_temp.as_v147_user(v_outsider);
    perform public.platform_get_accounting_books_v147('2026-08-01','2026-08-31',100);
    reset role;
    raise exception 'non-super-admin read platform books';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v147_user(v_outsider);
    perform public.platform_create_invoice_v147('2026-09-01','2026-09-30','NON-SUBSCRIPTION-FORBIDDEN-20260901','{"legal_name":"Forbidden"}','[{"description":"Forbidden service","quantity":1,"unit_amount_cents":100}]',0,'14700000-0000-4000-8000-000000000011');
    reset role;
    raise exception 'non-super-admin generated a financial document';
  exception when insufficient_privilege then reset role;
  end;
  if not exists(select 1 from public.audit_log where action='PLATFORM_JOURNAL_POSTED_V147')
     or not exists(select 1 from public.audit_log where action='PLATFORM_ACCOUNTING_PERIOD_LOCK_V147') then raise exception 'accounting changes were not audited';end if;
end
$v147_test$;

rollback;
