-- EXECUTED acceptance fixture for nestly_v775
-- (db/migrations/20261006_nestly_v775_capacity_increase_invoice_reason.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v775 --migrated-only
--
-- ASSERTIONS (rolled back):
--   F1  billing_provider_invoices accepts reason 'capacity_increase' and still refuses an unknown one.
--   F2  the live applier's allow-list names 'capacity_increase' (the extract-and-diff landed).
begin;

do $v775$
declare
  v_business uuid; v_ok boolean := false; v_def text;
begin
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V775 tenant','v775-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard'])
  returning id into v_business;

  -- F1a: accepted
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id,reason,detail
  ) values (
    v_business,'cust_v775','sub_v775','inv_v775_cap','SGD','paid',true,100000,0,100000,100000,100000,0,
    now(),now()+interval '300 days',now(),false,now(),10,'evt_v775','capacity_increase',
    jsonb_build_object('capacity_from',10000,'capacity_to',40000)
  );
  if not exists (select 1 from public.billing_provider_invoices where provider_invoice_id='inv_v775_cap' and reason='capacity_increase') then
    raise exception 'F1: the capacity_increase row was not stored';
  end if;
  -- F1b: an unknown reason is still refused
  begin
    insert into public.billing_provider_invoices(
      business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
      paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
      amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
      provider_event_rank,last_event_id,reason
    ) values (
      v_business,'cust_v775','sub_v775','inv_v775_bad','SGD','paid',true,1,0,1,1,1,0,
      now(),now()+interval '1 day',now(),false,now(),11,'evt_v775b','made_up_reason'
    );
  exception when check_violation then
    v_ok := true;
  end;
  if not v_ok then raise exception 'F1: an unknown reason was accepted'; end if;

  -- F2
  select pg_get_functiondef('public.apply_razorpay_billing_event_v755'::regproc) into v_def;
  if position('''capacity_increase''' in v_def) = 0 then
    raise exception 'F2: the applier does not admit capacity_increase';
  end if;

  raise notice 'v775 corpus: F1-F2 passed';
end
$v775$;

rollback;
