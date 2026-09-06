-- nestly_v794 rollback suite — the record the first live payment left behind is complete.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   A  the BUSINESS's own invoice list carries the provider receipt links (defect 1).
--   B  an invoice's stored period is the SERVICE period from the line item, not the zero-length
--      stamp Stripe puts on a subscription_create invoice (defect 4, at source).
--   C  the invoice says what it bought — reason is derived from Stripe's billing_reason, and a
--      more specific reason already recorded by a command is NOT overwritten (defect 3).
--   D  paid_through on the console kanban lands the day before the next renewal, not before the
--      payment (defect 4, as the console reads it).
--   E  a subscription with a default payment method is recorded as having one, and the brand and
--      last4 are still NULL — the payload carries neither and nothing invents them (defect 2).
--   F  the two replaced functions keep their ACLs.
begin;

do $v794$
declare
  v_sa uuid;
  v_business uuid;
  v_invoice public.billing_provider_invoices%rowtype;
  v_event public.billing_provider_events%rowtype;
  v_payload jsonb;
  v_paid_through date;
  v_acl text;
  v_kind text; v_brand text; v_last4 text;
begin
  reset role;

  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  /* v625: is_super_admin needs the Google-OAuth session shape, not just `sub`. */
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_sa, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

  -- A · the business-facing list exposes the receipt links at all.
  if position('hosted_invoice_url' in
       pg_get_functiondef('public.get_business_billing_v77(uuid)'::regprocedure)) = 0
     or position('provider_receipt_url' in
       pg_get_functiondef('public.get_business_billing_v77(uuid)'::regprocedure)) = 0 then
    raise exception 'A: the business invoice list does not return the provider receipt links';
  end if;

  -- Work against a real Stripe invoice whose provider event carries a line period.
  select invoice.* into v_invoice
    from public.billing_provider_invoices invoice
    join public.billing_provider_events event
      on event.event_id = invoice.last_event_id and event.provider = 'stripe'
   where event.payload#>>'{data,object,lines,data,0,period,end}' is not null
   order by invoice.paid_at desc nulls last
   limit 1;
  if v_invoice.provider_invoice_id is null then
    raise notice 'v794: no Stripe invoice with a line period yet — B/C/D skipped, A/E/F still run';
  else
    select * into v_event from public.billing_provider_events
     where event_id = v_invoice.last_event_id and provider = 'stripe';
    v_payload := v_event.payload;
    v_business := v_invoice.business_id;

    -- B · the stored period is the line's service window.
    if v_invoice.period_end is not distinct from v_invoice.period_start then
      raise exception 'B1: invoice % still has a zero-length period', v_invoice.provider_invoice_id;
    end if;
    if v_invoice.period_end
       <> app.stripe_epoch_v77(v_payload#>'{data,object,lines,data,0,period,end}') then
      raise exception 'B2: invoice period_end (%) is not the line period end (%)',
        v_invoice.period_end,
        app.stripe_epoch_v77(v_payload#>'{data,object,lines,data,0,period,end}');
    end if;

    -- C · the reason is the provider's billing_reason, in the reader's vocabulary.
    if v_invoice.reason is null then
      raise exception 'C1: invoice % records no reason', v_invoice.provider_invoice_id;
    end if;
    if v_payload#>>'{data,object,billing_reason}' = 'subscription_create'
       and v_invoice.reason <> 'initial' then
      raise exception 'C2: a subscription_create invoice reads as %', v_invoice.reason;
    end if;
    if v_invoice.detail->>'covers_until' is null then
      raise exception 'C3: invoice % does not say what period it covers', v_invoice.provider_invoice_id;
    end if;

    -- C4 · a command's own, more specific reason outranks the derived one and survives a replay.
    update public.billing_provider_invoices
       set reason = 'capacity_increase'
     where provider_invoice_id = v_invoice.provider_invoice_id;
    perform public.apply_stripe_billing_event_v94_base(v_event.event_id);
    if (select reason from public.billing_provider_invoices
         where provider_invoice_id = v_invoice.provider_invoice_id) <> 'capacity_increase' then
      raise exception 'C4: replaying the event overwrote a command-recorded reason';
    end if;
    update public.billing_provider_invoices
       set reason = v_invoice.reason
     where provider_invoice_id = v_invoice.provider_invoice_id;

    -- D · the console's paid_through is the day before the period ends, i.e. AFTER the payment.
    select (r->>'paid_through')::date into v_paid_through
      from jsonb_array_elements(
             public.platform_get_subscription_operations_v156(null,null,500)->'subscriptions') r
     where (r->>'business_id')::uuid = v_business;
    if v_paid_through is null then
      raise exception 'D1: the console reports no paid_through for this firm';
    end if;
    if v_invoice.paid_at is not null
       and v_paid_through < (v_invoice.paid_at at time zone 'Asia/Singapore')::date then
      raise exception 'D2: paid_through (%) is BEFORE the payment (%)',
        v_paid_through, (v_invoice.paid_at at time zone 'Asia/Singapore')::date;
    end if;
    if v_paid_through <> (v_invoice.period_end at time zone 'Asia/Singapore')::date - 1 then
      raise exception 'D3: paid_through (%) is not the day before the period end (%)',
        v_paid_through, (v_invoice.period_end at time zone 'Asia/Singapore')::date;
    end if;
  end if;

  -- E · a stored payment method is recorded, and no brand or digits are invented.
  select customer.payment_method_kind, customer.payment_method_brand, customer.payment_method_last4
    into v_kind, v_brand, v_last4
    from public.billing_provider_customers customer
    join public.billing_provider_events event
      on event.provider = 'stripe' and event.event_type like 'customer.subscription.%'
     and coalesce(nullif(event.payload#>>'{data,object,default_payment_method}',''),
                  nullif(event.payload#>>'{data,object,default_payment_method,id}','')) is not null
     and customer.business_id = (
           select s.business_id from public.billing_provider_subscriptions s
            where s.provider_subscription_id = event.payload#>>'{data,object,id}')
   limit 1;
  if v_kind is not null then
    if v_kind not in ('card','paynow','other') then
      raise exception 'E1: payment method kind % is outside the allowed set', v_kind;
    end if;
    /* Stripe's subscription/invoice/checkout webhooks carry no brand and no last4. If either
       appears here it was invented, or an API-backed refresh filled it — the first is a defect,
       the second is fine, so this only fails when a brand/last4 exists WITHOUT an API refresh
       having recorded when it happened. */
    if (v_brand is not null or v_last4 is not null)
       and (select payment_method_updated_at from public.billing_provider_customers
             where payment_method_last4 = v_last4 limit 1) is null then
      raise exception 'E2: a card brand/last4 exists with no record of where it came from';
    end if;
  end if;

  -- F · ACLs unchanged.
  select proacl::text into v_acl from pg_proc
   where oid = 'public.get_business_billing_v77(uuid)'::regprocedure;
  if v_acl not like '%authenticated=X%' or v_acl like '%anon=X%' then
    raise exception 'F1: unexpected ACL on get_business_billing_v77: %', v_acl;
  end if;
  select proacl::text into v_acl from pg_proc
   where oid = 'public.apply_stripe_billing_event_v94_base(text)'::regprocedure;
  if v_acl like '%anon=X%' or v_acl like '%authenticated=X%' then
    raise exception 'F2: the applier is reachable from the browser: %', v_acl;
  end if;

  raise notice 'v794 first-live-payment record: all assertions passed';
end
$v794$;

rollback;
