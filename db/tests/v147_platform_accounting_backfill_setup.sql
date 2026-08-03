-- Run after V146 and before V147 on a disposable database.
begin;
do $v147_backfill_setup$
declare v_business uuid;v_invoice text:='in_v147_historical_chain';v_object jsonb;
begin
  select id into v_business from public.businesses order by created_at limit 1;
  if v_business is null then raise exception 'V147 backfill fixture requires one synthetic business';end if;
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,number,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,net_cash_ex_tax_cents,paid_at,voided_at,marked_uncollectible_at,
    livemode,provider_event_created_at,provider_event_rank,last_event_id,created_at
  ) values(v_business,'cus_v147_historical',v_invoice,'BACKFILL-001','SGD','paid',true,
    100,0,100,100,100,0,100,'2026-10-05T01:00:00Z','2026-10-04T01:00:00Z','2026-10-03T01:00:00Z',
    false,'2026-10-05T01:00:00Z',100,'evt_v147_history_paid','2026-10-01T01:00:00Z');

  insert into public.billing_provider_events(provider,event_id,event_type,object_id,event_created_at,livemode,payload,payload_sha256,processing_status,processing_attempts,business_id,processed_at)
  select 'stripe',event_id,event_type,v_invoice,event_at,false,
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id',v_invoice,'currency','sgd','status',status,'subtotal_excluding_tax',100,'total',100,
      'amount_paid',amount_paid,'amount_remaining',100-amount_paid,
      'status_transitions',jsonb_build_object(
        'marked_uncollectible_at',case when event_type in ('invoice.marked_uncollectible','invoice.voided','invoice.paid') then extract(epoch from '2026-10-03T01:00:00Z'::timestamptz)::bigint else null end,
        'voided_at',case when event_type in ('invoice.voided','invoice.paid') then extract(epoch from '2026-10-04T01:00:00Z'::timestamptz)::bigint else null end,
        'paid_at',case when event_type='invoice.paid' then extract(epoch from '2026-10-05T01:00:00Z'::timestamptz)::bigint else null end)))),
    encode(extensions.digest(event_id,'sha256'),'hex'),'processed',1,v_business,event_at
  from (values
    ('evt_v147_history_final','invoice.finalized','open',0,'2026-10-01T01:00:00Z'::timestamptz),
    ('evt_v147_history_partial','invoice.payment_failed','open',40,'2026-10-02T01:00:00Z'::timestamptz),
    ('evt_v147_history_bad','invoice.marked_uncollectible','uncollectible',40,'2026-10-03T01:00:00Z'::timestamptz),
    ('evt_v147_history_void','invoice.voided','void',40,'2026-10-04T01:00:00Z'::timestamptz),
    ('evt_v147_history_paid','invoice.paid','paid',100,'2026-10-05T01:00:00Z'::timestamptz)
  ) history(event_id,event_type,status,amount_paid,event_at);
end
$v147_backfill_setup$;
commit;
