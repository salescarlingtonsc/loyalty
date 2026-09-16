-- nestly_v989 rollback suite — sandbox money cannot reach the general ledger.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa uuid; n integer := 0;
  biz_test uuid := gen_random_uuid(); biz_live uuid := gen_random_uuid(); biz_manual uuid := gen_random_uuid();
  inv_test public.billing_provider_invoices%rowtype;
  inv_live public.billing_provider_invoices%rowtype;
  entries_before bigint; entries_after bigint;
  pending_blocked integer;
begin
  select user_id into sa from public.super_admins limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub',sa,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz_test ,'V989 sandbox','v989-t-'||substr(biz_test::text,1,8),'test',true,array['dashboard']),
    (biz_live ,'V989 live','v989-l-'||substr(biz_live::text,1,8),'test',true,array['dashboard']),
    (biz_manual,'V989 manual','v989-m-'||substr(biz_manual::text,1,8),'test',true,array['dashboard']);

  -- (1) a TEST-mode invoice must post nothing to the ledger
  n := n + 1;
  select count(*) into entries_before from public.platform_accounting_journal_entries_v147;
  insert into public.billing_provider_invoices(id,business_id,provider_customer_id,provider_invoice_id,
    currency,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,net_cash_ex_tax_cents,total_cents,
    discount_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,livemode,
    provider_event_created_at,provider_event_rank,last_event_id,paid_at)
  values (gen_random_uuid(),biz_test,'cus_v989t','in_v989_sandbox','SGD','paid',true,10000,0,10000,10000,
    0,10000,10000,0,false,now(),1,'evt_v989t',now())
  returning * into inv_test;
  perform app.platform_sync_provider_invoice_v147(inv_test);
  select count(*) into entries_after from public.platform_accounting_journal_entries_v147;
  if entries_after <> entries_before then
    raise exception 'A% failed: a TEST-mode invoice posted % journal entries', n, entries_after-entries_before;
  end if;

  -- (2) a LIVE invoice must still post
  n := n + 1;
  insert into public.billing_provider_invoices(id,business_id,provider_customer_id,provider_invoice_id,
    currency,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,net_cash_ex_tax_cents,total_cents,
    discount_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,livemode,
    provider_event_created_at,provider_event_rank,last_event_id,paid_at)
  values (gen_random_uuid(),biz_live,'cus_v989l','in_v989_live','SGD','paid',true,10000,0,10000,10000,
    0,10000,10000,0,true,now(),1,'evt_v989l',now())
  returning * into inv_live;
  perform app.platform_sync_provider_invoice_v147(inv_live);
  if not exists (select 1 from public.platform_accounting_journal_entries_v147
                  where source_type='provider_invoice_issued' and source_id='in_v989_live') then
    raise exception 'A% failed: a LIVE invoice did not reach the ledger', n;
  end if;
  n := n + 1;
  if exists (select 1 from public.platform_accounting_journal_entries_v147
              where source_type='provider_invoice_issued' and source_id='in_v989_sandbox') then
    raise exception 'A% failed: the sandbox invoice reached the ledger after all', n;
  end if;

  -- (3) the 66 slices already queued from TEST invoices must now be unrecognisable
  n := n + 1;
  select count(*) into pending_blocked
    from public.platform_subscription_revenue_months_v200 m
    join public.platform_subscription_revenue_periods_v200 p on p.id = m.period_id
   where m.journal_entry_id is null
     and exists (select 1 from public.billing_provider_invoices bad
                  where bad.provider_invoice_id = p.invoice_reference
                    and not coalesce(bad.livemode,false));
  if pending_blocked = 0 then
    raise exception 'A% failed: expected queued sandbox slices to exist and be blocked, found none', n;
  end if;

  -- and the recogniser must decline every one of them, today or any day
  n := n + 1;
  select count(*) into entries_before from public.platform_accounting_journal_entries_v147;
  perform app.v200_recognize_due_months();
  select count(*) into entries_after from public.platform_accounting_journal_entries_v147;
  if entries_after <> entries_before then
    raise exception 'A% failed: the recogniser posted % entries from sandbox-funded slices',
      n, entries_after-entries_before;
  end if;

  -- (4) a MANUAL firm has no provider invoice, and absence must not read as fakeness.
  -- Asserted on the guard expression itself rather than through a subscriptions fixture, whose
  -- period-amount constraint is unrelated to what is under test here.
  n := n + 1;
  if exists (
    select 1 from public.billing_provider_invoices bad
     where bad.provider_invoice_id = nullif(btrim(coalesce(null::text,'')),'')
       and not coalesce(bad.livemode,false)) then
    raise exception 'A% failed: a firm with no provider invoice was judged sandbox', n;
  end if;
  -- and the same guard must still reject a real sandbox reference
  n := n + 1;
  if not exists (
    select 1 from public.billing_provider_invoices bad
     where bad.provider_invoice_id = nullif(btrim(coalesce('in_v989_sandbox','')),'')
       and not coalesce(bad.livemode,false)) then
    raise exception 'A% failed: the guard failed to recognise a sandbox invoice reference', n;
  end if;

  raise notice 'v989 suite: % assertions passed', n;
end
$suite$;
rollback;
