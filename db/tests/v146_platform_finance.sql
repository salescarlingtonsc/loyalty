-- Rollback-only v146 platform finance acceptance evidence.
begin;

create or replace function pg_temp.as_v146_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v146_user(uuid,text) to public;

do $v146_test$
declare
  v_sa uuid:=gen_random_uuid();v_outsider uuid:=gen_random_uuid();
  v_business uuid;v_result jsonb;v_expense uuid;v_duplicate uuid;v_first jsonb;
  v_credit uuid;v_external_payment uuid;v_chargeback uuid;
begin
  select id into v_business from public.businesses order by created_at limit 1;
  if v_business is null then raise exception 'v146 requires one synthetic business fixture';end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated','v146-sa@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated','v146-out@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v146-sa@example.test','v146 rollback fixture');

  insert into public.billing_provider_events(
    event_id,event_type,object_id,event_created_at,livemode,payload,payload_sha256,
    processing_status,business_id
  ) values(
    'evt_v146_paid','invoice.paid','in_v146_paid','2026-08-03T01:00:00Z',false,
    '{"data":{"object":{"hosted_invoice_url":"https://invoice.stripe.com/i/v146","invoice_pdf":"https://pay.stripe.com/invoice/v146/pdf"}}}',
    repeat('a',64),'processed',v_business
  );
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values(v_business,'cus_v146','in_v146_paid','V146-001','SGD','paid',true,
    118800,0,118800,118800,118800,0,118800,'2026-08-03T01:00:00Z',false,
    '2026-08-03T01:00:00Z',70,'evt_v146_paid');
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_business,'cus_v146','in_v146_northstar','V146-002','SGD','paid',true,16900,0,16900,16900,16900,0,16900,'2026-08-03T02:00:00Z',false,'2026-08-03T02:00:00Z',70,'evt_v146_paid'),
    (v_business,'cus_v146','in_v146_pending','V146-003','SGD','open',false,14900,0,14900,14900,0,14900,0,null,false,'2026-08-03T03:00:00Z',20,'evt_v146_paid');
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,tax_cents,
    total_cents,currency,source_event_id,provider_object_id,reason,evidence_sha256,occurred_at
  ) values(v_business,'in_v146_northstar','refund',-2000,0,-2000,'SGD',
    'evt_v146_refund','re_v146_refund','Partial customer refund',repeat('b',64),'2026-08-03T02:30:00Z');
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,tax_cents,
    total_cents,currency,source_event_id,provider_object_id,reason,evidence_sha256,occurred_at
  ) values
    (v_business,'in_v146_northstar','chargeback',-700,0,-700,'SGD','evt_v146_chargeback','cb_v146','Provider chargeback',repeat('b',64),'2026-08-03T02:31:00Z'),
    (v_business,'in_v146_northstar','external_payment',600,0,600,'SGD','evt_v146_external','ep_v146','Confirmed external payment',repeat('b',64),'2026-08-03T02:32:00Z'),
    (v_business,'in_v146_northstar','credit',-300,0,-300,'SGD','evt_v146_credit','cr_v146','Goodwill account credit',repeat('b',64),'2026-08-03T02:33:00Z'),
    (v_business,'in_v146_northstar','debit',400,0,400,'SGD','evt_v146_debit','db_v146','Receivable account debit',repeat('b',64),'2026-08-03T02:34:00Z'),
    (v_business,'in_v146_northstar','writeoff',-500,0,-500,'SGD','evt_v146_writeoff','wo_v146','Receivable writeoff',repeat('b',64),'2026-08-03T02:35:00Z');
  select id into v_external_payment from public.billing_adjustments where source_event_id='evt_v146_external';
  select id into v_credit from public.billing_adjustments where source_event_id='evt_v146_credit';
  select id into v_chargeback from public.billing_adjustments where source_event_id='evt_v146_chargeback';
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,tax_cents,
    total_cents,currency,source_event_id,provider_object_id,reversal_of,reason,evidence_sha256,occurred_at
  ) values
    (v_business,'in_v146_northstar','reversal',-600,0,-600,'SGD','evt_v146_external_reversal','rev_ep_v146',v_external_payment,'External payment reversed',repeat('b',64),'2026-08-03T02:36:00Z'),
    (v_business,'in_v146_northstar','reversal',300,0,300,'SGD','evt_v146_credit_reversal','rev_cr_v146',v_credit,'Account credit reversed',repeat('b',64),'2026-08-03T02:37:00Z'),
    (v_business,'in_v146_northstar','reversal',700,0,700,'SGD','evt_v146_chargeback_reversal','rev_cb_v146',v_chargeback,'Chargeback reversed',repeat('b',64),'2026-08-03T02:38:00Z');
  if not exists(select 1 from public.billing_provider_invoices
    where provider_invoice_id='in_v146_paid'
      and hosted_invoice_url='https://invoice.stripe.com/i/v146'
      and invoice_pdf_url='https://pay.stripe.com/invoice/v146/pdf') then
    raise exception 'Stripe invoice documents were not projected';
  end if;
  begin
    update public.billing_provider_invoices
       set hosted_invoice_url='https://stripe.com.evil.test/invoice'
     where provider_invoice_id='in_v146_paid';
    raise exception 'non-Stripe document URL was accepted';
  exception when check_violation then null;
  end;

  perform pg_temp.as_v146_user(v_sa);
  v_first:=public.platform_record_operating_expense_v146(
    '2026-08-03','software','August infrastructure',28000,'SGD','14600000-0000-4000-8000-000000000001'
  );
  v_result:=public.platform_record_operating_expense_v146(
    '2026-08-03','software','August infrastructure',28000,'SGD','14600000-0000-4000-8000-000000000001'
  );
  reset role;
  v_expense:=(v_first#>>'{entry,id}')::uuid;
  if not coalesce((v_result->>'replayed')::boolean,false)
     or (select count(*) from public.platform_operating_expense_entries_v146 where id=v_expense)<>1 then
    raise exception 'expense retry was not idempotent';
  end if;
  begin
    perform pg_temp.as_v146_user(v_sa);
    perform public.platform_record_operating_expense_v146(
      '2026-08-03','software','Changed payload',1,'SGD','14600000-0000-4000-8000-000000000001'
    );
    reset role;
    raise exception 'changed expense payload replayed';
  exception when invalid_parameter_value then reset role;
  end;

  perform pg_temp.as_v146_user(v_sa);
  perform public.platform_record_operating_expense_v146(
    '2026-08-03','marketing','August campaign',12000,'SGD','14600000-0000-4000-8000-000000000002'
  );
  v_result:=public.platform_record_operating_expense_v146(
    '2026-08-03','software','Duplicate software charge',4500,'SGD','14600000-0000-4000-8000-000000000005'
  );
  v_duplicate:=(v_result#>>'{entry,id}')::uuid;
  perform public.platform_reverse_operating_expense_v146(
    v_duplicate,'Duplicate charge reversed','14600000-0000-4000-8000-000000000003'
  );
  v_result:=public.platform_reverse_operating_expense_v146(
    v_duplicate,'Duplicate charge reversed','14600000-0000-4000-8000-000000000003'
  );
  if not coalesce((v_result->>'replayed')::boolean,false) then
    raise exception 'expense reversal retry was not idempotent';
  end if;
  v_result:=public.platform_get_finance_v146('2026-08-01','2026-08-31',100);
  reset role;
  if (v_result#>>'{summary,income_cents}')::bigint<>135700
     or (v_result#>>'{summary,billing_adjustments_cents}')::bigint<>-2000
     or (v_result#>>'{summary,net_expenses_cents}')::bigint<>40000
     or (v_result#>>'{summary,net_cash_cents}')::bigint<>93700
     or (v_result#>>'{summary,pending_invoice_cents}')::bigint<>14900
     or jsonb_array_length(v_result->'invoices')<>3
     or jsonb_array_length(v_result->'adjustments')<>9
     or jsonb_array_length(v_result->'expenses')<>4 then
    raise exception 'cash P&L did not reconcile invoice, expense and reversal entries: %',v_result->'summary';
  end if;
  if exists(select 1 from jsonb_array_elements(v_result->'adjustments') row
      where row->>'adjustment_type' in ('credit','debit','writeoff')
        and ((row->>'cash_effect_cents')::integer<>0 or (row->>'cash_affecting')::boolean))
     or not exists(select 1 from jsonb_array_elements(v_result->'adjustments') row
      where row->>'adjustment_type'='chargeback' and (row->>'cash_effect_cents')::integer=-700 and (row->>'cash_affecting')::boolean)
     or not exists(select 1 from jsonb_array_elements(v_result->'adjustments') row
      where row->>'source_event_id'='evt_v146_external_reversal' and (row->>'cash_effect_cents')::integer=-600 and (row->>'cash_affecting')::boolean)
     or not exists(select 1 from jsonb_array_elements(v_result->'adjustments') row
      where row->>'source_event_id'='evt_v146_credit_reversal' and (row->>'cash_effect_cents')::integer=0 and not (row->>'cash_affecting')::boolean) then
    raise exception 'cash and non-cash billing adjustment classification failed: %',v_result->'adjustments';
  end if;
  if not exists(select 1 from public.audit_log where action='PLATFORM_EXPENSE_RECORDED_V146')
     or not exists(select 1 from public.audit_log where action='PLATFORM_EXPENSE_REVERSED_V146') then
    raise exception 'expense changes were not audited';
  end if;

  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_business,'cus_v146','in_v146_sgt_start','V146-SGT-START','SGD','paid',true,100,0,100,100,100,0,100,'2026-08-31T16:00:00Z',false,'2026-08-31T16:00:00Z',70,'evt_v146_paid'),
    (v_business,'cus_v146','in_v146_sgt_end','V146-SGT-END','SGD','paid',true,200,0,200,200,200,0,200,'2026-09-30T16:00:00Z',false,'2026-09-30T16:00:00Z',70,'evt_v146_paid'),
    (v_business,'cus_v146','in_v146_usd','V146-USD','USD','paid',true,999,0,999,999,999,0,999,'2026-09-15T00:00:00Z',false,'2026-09-15T00:00:00Z',70,'evt_v146_paid');
  perform pg_temp.as_v146_user(v_sa);
  v_result:=public.platform_get_finance_v146('2026-09-01','2026-09-30',100);
  reset role;
  if (v_result#>>'{summary,income_cents}')::bigint<>100
     or jsonb_array_length(v_result->'invoices')<>1 then
    raise exception 'Singapore half-open boundary or SGD isolation failed: %',v_result->'summary';
  end if;
  insert into public.platform_operating_expense_entries_v146(
    entry_type,expense_date,category,description,amount_cents,currency,
    recorded_by,idempotency_key,request_hash
  ) select 'expense','2026-10-01','operations','October operating item '||series,
    1,'SGD',v_sa,gen_random_uuid(),repeat('c',64)
    from generate_series(1,251) series;
  perform pg_temp.as_v146_user(v_sa);
  v_result:=public.platform_get_finance_v146('2026-10-01','2026-10-31',5000);
  reset role;
  if (v_result#>>'{row_counts,expenses}')::integer<>251
     or not (v_result#>>'{complete,expenses}')::boolean
     or jsonb_array_length(v_result->'expenses')<>251 then
    raise exception '251-row finance ledger was silently truncated';
  end if;

  begin
    perform pg_temp.as_v146_user(v_outsider);
    perform public.platform_get_finance_v146('2026-08-01','2026-08-31',100);
    reset role;
    raise exception 'non-super-admin read platform finance';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v146_user(v_outsider);
    perform public.platform_record_operating_expense_v146(
      '2026-08-03','software','Forbidden expense',100,'SGD','14600000-0000-4000-8000-000000000004'
    );
    reset role;
    raise exception 'non-super-admin wrote platform expense';
  exception when insufficient_privilege then reset role;
  end;
  begin
    update public.platform_operating_expense_entries_v146 set amount_cents=1 where id=v_expense;
    raise exception 'expense ledger accepted an update';
  exception when raise_exception then
    if sqlerrm='expense ledger accepted an update' then raise;end if;
  end;
end
$v146_test$;

rollback;
