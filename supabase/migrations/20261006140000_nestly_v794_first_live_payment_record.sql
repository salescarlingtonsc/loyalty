-- nestly_v794 — what the first live payment showed: the record was thinner than the money.
--
-- The platform took its first ever livemode payment on 2026-09-06 (SGD 1.00, invoice
-- EJYBYDM2-0001). The money moved correctly, every webhook processed, and the renewal date was
-- right everywhere. Four things around it were not, and none of them could have been seen without
-- a real payment — every earlier row in this database came from a sandbox.
--
--   1. THE BUSINESS COULD NOT OPEN ITS OWN RECEIPT. The v146 trigger has always stored
--      hosted_invoice_url / provider_receipt_url off the provider event, and the platform console
--      has always returned them — but get_business_billing_v77, which builds the invoice list the
--      BUSINESS's Payments table reads, never selected them. The Receipt column rendered "—" for
--      every invoice, forever.
--
--   2. "NO CARD YET", ON A FIRM THAT HAD JUST PAID BY CARD. Nothing on the Stripe path ever wrote
--      billing_provider_customers.payment_method_*. That blank is the one signal telling an owner
--      their subscription will be collected automatically rather than chased.
--
--   3. THE INVOICE DID NOT SAY WHAT IT BOUGHT. Only the v791 BRANCH applier set `reason`; the v94
--      base applier (which handles every COMPANY subscription) left it NULL, so the Payments row
--      read the generic "Subscription" instead of naming the plan and the period.
--
--   4. "PAID THROUGH 5 SEP 2026" — THE DAY BEFORE THE PAYMENT. Stripe stamps a subscription_create
--      invoice with period_start = period_end = the creation instant; the service window lives on
--      the line item. platform_get_subscription_operations_v156 computes paid_through as
--      period_end - 1 day, so the console kanban card contradicted the money. Razorpay put the
--      true period end on the invoice, so this worked before and broke silently on the switch.
--
-- Fixes 1 and 3 are readers/writers of fields that already existed. Fix 4 is corrected AT SOURCE
-- (the applier now records the service period) rather than by patching the console's arithmetic,
-- so every reader of billing_provider_invoices.period_* is right rather than one of them.
-- Fix 2 records only what Stripe actually tells us: the four events of a live checkout carry NO
-- brand and NO last4 anywhere, so this records that a method exists ('other' -> "Payment method
-- on file") and never guesses 'card' or invents digits.
--
-- Section 5 repairs the one live invoice already written under the old behaviour, from the
-- immutable provider-event payload rather than from anything recomputed.
--
-- Read/write paths only; no price, amount, date or entitlement changes.
-- Rollback suite: db/tests/v794_first_live_payment_record.sql

begin;

-- =============================================================================================
-- 0 · The live bodies this file replaces are what it believes they are.
-- =============================================================================================
do $v794_assert$
declare v_body text;
begin
  v_body := pg_get_functiondef('public.apply_stripe_billing_event_v94_base(text)'::regprocedure);
  if position('v794' in v_body) > 0 then
    raise exception 'v794: apply_stripe_billing_event_v94_base already carries v794';
  end if;
  if position($n$app.stripe_epoch_v77(v_object->'period_start'),$n$ in v_body) = 0 then
    raise exception 'v794: the invoice period expression has drifted';
  end if;
  v_body := pg_get_functiondef('public.get_business_billing_v77(uuid)'::regprocedure);
  if position('hosted_invoice_url' in v_body) > 0 then
    raise exception 'v794: get_business_billing_v77 already returns the receipt links';
  end if;
end
$v794_assert$;

-- =============================================================================================
-- 1 · The business's own Payments table can reach the provider receipt (defect 1).
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_business_billing_v77(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_result jsonb;
begin
  if auth.uid() is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  select jsonb_build_object(
    'business_id',s.business_id,'status',s.status,
    'payment_status',s.payment_status,'currency',s.currency,
    'cadence',s.billing_cadence,'cadence_months',s.cadence_months,
    'billable_seats',app.billable_seats(s.business_id),
    'provider_seat_quantity',s.provider_seat_quantity,
    'period_subtotal_cents',s.period_subtotal_cents,
    'period_tax_cents',s.period_tax_cents,
    'period_total_cents',s.period_total_cents,
    'tax_behavior',s.tax_behavior,
    'provider',jsonb_build_object(
      'name',s.billing_provider,'customer_id',s.provider_customer_id,
      'subscription_id',s.provider_subscription_id
    ),
    'current_period_start',s.current_period_start,
    'current_period_end',s.current_period_end,
    'next_payment_at',s.next_payment_at,
    'last_paid_at',s.last_paid_at,
    'last_paid_invoice_id',s.last_paid_invoice_id,
    'cancel_at_period_end',s.cancel_at_period_end,
    'invoices',coalesce((
      select jsonb_agg(to_jsonb(invoice_rows) order by invoice_rows.sort_at desc)
      from (
        select provider_invoice_id,number,status,paid_normalized,currency,reason,detail,
               subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,
               amount_remaining_cents,collection_method,period_start,period_end,
               paid_at,next_payment_attempt_at,
               /* v794: the receipt the provider issued. The v146 trigger has always stored these
                  off the provider event, and the platform console has always returned them, but
                  this list — the one the BUSINESS's own Payments table reads — omitted them, so
                  the Receipt column rendered "—" for every invoice a tenant ever paid. The
                  business could not open its own receipt anywhere in the product. */
               hosted_invoice_url,provider_receipt_url,
               coalesce(paid_at,created_at) sort_at
          from public.billing_provider_invoices
         where business_id=p_business
         order by coalesce(paid_at,created_at) desc limit 20
      ) invoice_rows
    ),'[]'::jsonb),
    'payment_attempts',coalesce((
      select jsonb_agg(to_jsonb(attempt_rows) order by attempt_rows.occurred_at desc)
      from (
        select provider_invoice_id,attempt_state,amount_cents,tax_cents,
               failure_code,next_attempt_at,occurred_at,collection_method
          from public.billing_payment_attempts
         where business_id=p_business order by occurred_at desc limit 20
      ) attempt_rows
    ),'[]'::jsonb),
    'adjustments',coalesce((
      select jsonb_agg(to_jsonb(adjustment_rows) order by adjustment_rows.occurred_at desc)
      from (
        select id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
               tax_cents,total_cents,currency,reason,occurred_at,reversal_of
          from public.billing_adjustments
         where business_id=p_business order by occurred_at desc limit 20
      ) adjustment_rows
    ),'[]'::jsonb),
    'commands',coalesce((
      select jsonb_agg(to_jsonb(command_rows) order by command_rows.requested_at desc)
      from (
        select id command_id,command_type,requested_cadence,status,redirect_url,
               error_code,requested_at,completed_at
          from public.billing_commands
         where business_id=p_business order by requested_at desc limit 10
      ) command_rows
    ),'[]'::jsonb)
  ) into v_result
    from public.subscriptions s where s.business_id=p_business;
  if v_result is null then
    raise exception 'billing subscription was not found' using errcode='22023';
  end if;
  return v_result;
end
$function$;

revoke all on function public.get_business_billing_v77(uuid) from public, anon;
grant execute on function public.get_business_billing_v77(uuid) to authenticated;

-- =============================================================================================
-- 2/3/4 · The applier records the service period, the reason, and that a payment method exists.
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.apply_stripe_billing_event_v94_base(p_event_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_event public.billing_provider_events%rowtype;
  v_object jsonb;
  v_business uuid;
  v_rank smallint;
  v_customer text;
  v_subscription text;
  v_invoice text;
  v_status text;
  v_interval text;
  v_interval_count integer;
  v_cadence_months integer;
  v_cadence text;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_next_attempt timestamptz;
  v_paid_at timestamptz;
  v_subtotal integer;
  v_tax integer;
  v_total integer;
  v_due integer;
  v_paid integer;
  v_remaining integer;
  v_item jsonb;
  v_item_role text;
  v_price text;
  v_attempt_state text;
  v_adjustment_total integer;
  v_adjustment_tax integer;
  v_adjustment_net integer;
  v_adjustment_invoice public.billing_provider_invoices%rowtype;
begin
  select * into v_event
    from public.billing_provider_events
   where provider = 'stripe' and event_id = p_event_id
   for update;
  if not found then
    raise exception 'Stripe event is not in the durable inbox' using errcode = '22023';
  end if;
  if v_event.processing_status in ('processed','ignored') then
    return jsonb_build_object(
      'event_id',p_event_id,'status',v_event.processing_status,'duplicate',true
    );
  end if;

  update public.billing_provider_events
     set processing_status = 'processing',
         processing_attempts = processing_attempts + 1,
         last_error = null
   where id = v_event.id;

  begin
    v_object := v_event.payload #> '{data,object}';
    v_rank := app.stripe_event_rank_v77(v_event.event_type);
    if v_rank = 0 or jsonb_typeof(v_object) <> 'object' then
      update public.billing_provider_events
         set processing_status='ignored',processed_at=now()
       where id=v_event.id;
      return jsonb_build_object('event_id',p_event_id,'status','ignored');
    end if;

    v_business := app.stripe_business_v77(v_event.payload);
    if v_business is null then
      raise exception 'Stripe event cannot be mapped to a business';
    end if;
    v_customer := case
      when jsonb_typeof(v_object->'customer') = 'string' then v_object->>'customer'
      else v_object#>>'{customer,id}'
    end;
    v_subscription := coalesce(
      case when jsonb_typeof(v_object->'subscription') = 'string'
           then v_object->>'subscription' else v_object#>>'{subscription,id}' end,
      v_object#>>'{parent,subscription_details,subscription}'
    );

    if v_customer is not null then
      if exists(
        select 1 from public.billing_provider_customers customer
         where customer.provider_customer_id=v_customer
           and customer.business_id<>v_business
      ) then
        raise exception 'Stripe customer is already linked to another business';
      end if;
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      select v_business,null,'PROVIDER_CUSTOMER_RELINKED_V792','billing_provider_customers',
             customer.id,
             jsonb_build_object('provider','stripe','previous_provider',customer.provider,
               'previous_customer_id',customer.provider_customer_id,'customer_id',v_customer,
               'event_id',v_event.event_id,'event_type',v_event.event_type)
        from public.billing_provider_customers customer
       where customer.business_id=v_business
         and customer.provider_customer_id<>v_customer;
      insert into public.billing_provider_customers(
        business_id,provider,provider_customer_id,currency,livemode,provider_created_at,
        provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,'stripe',v_customer,upper(nullif(v_object->>'currency','')),
        v_event.livemode,app.stripe_epoch_v77(v_object->'created'),
        v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(business_id) do update
        set provider_customer_id=excluded.provider_customer_id,
            provider='stripe',
            currency=coalesce(excluded.currency,billing_provider_customers.currency),
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_customers.provider_event_created_at,
                billing_provider_customers.provider_event_rank);
    end if;

    if v_event.event_type like 'customer.subscription.%' then
      v_subscription := v_object->>'id';
      if exists(
        select 1 from public.billing_provider_subscriptions subscription
         where subscription.provider_subscription_id=v_subscription
           and subscription.business_id<>v_business
      ) then
        raise exception 'Stripe subscription is already linked to another business';
      end if;
      v_status := case
        when v_event.event_type = 'customer.subscription.deleted' then 'canceled'
        when v_object->>'status' in (
          'trialing','active','incomplete','incomplete_expired','past_due',
          'unpaid','paused','canceled'
        ) then v_object->>'status'
        else 'incomplete'
      end;
      select item into v_item
        from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb)) item
       order by coalesce((item->>'quantity')::integer,0) desc
       limit 1;
      v_interval := v_item#>>'{price,recurring,interval}';
      v_interval_count := nullif(v_item#>>'{price,recurring,interval_count}','')::integer;
      v_cadence := app.stripe_cadence_v77(v_interval,v_interval_count);
      v_cadence_months := case v_cadence
        when 'quarterly' then 3
        when 'half_yearly' then 6
        when 'annual' then 12
        else null
      end;
      v_period_start := coalesce(
        app.stripe_epoch_v77(v_item->'current_period_start'),
        app.stripe_epoch_v77(v_object->'current_period_start')
      );
      v_period_end := coalesce(
        app.stripe_epoch_v77(v_item->'current_period_end'),
        app.stripe_epoch_v77(v_object->'current_period_end')
      );

      insert into public.billing_provider_subscriptions(
        business_id,provider_customer_id,provider_subscription_id,status,
        cadence,cadence_months,currency,current_period_start,current_period_end,
        billing_cycle_anchor,trial_end,cancel_at_period_end,canceled_at,ended_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,v_customer,v_subscription,v_status,v_cadence,v_cadence_months,
        upper(nullif(v_object->>'currency','')),v_period_start,v_period_end,
        app.stripe_epoch_v77(v_object->'billing_cycle_anchor'),
        app.stripe_epoch_v77(v_object->'trial_end'),
        coalesce((v_object->>'cancel_at_period_end')::boolean,false),
        app.stripe_epoch_v77(v_object->'canceled_at'),
        app.stripe_epoch_v77(v_object->'ended_at'),
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_subscription_id) do update
        set status=excluded.status,cadence=excluded.cadence,
            cadence_months=excluded.cadence_months,currency=excluded.currency,
            current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,
            billing_cycle_anchor=excluded.billing_cycle_anchor,
            trial_end=excluded.trial_end,
            cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_subscriptions.provider_event_created_at,
                billing_provider_subscriptions.provider_event_rank);

      for v_item in
        select value from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb))
      loop
        v_price := coalesce(v_item#>>'{price,id}',v_item->>'price');
        v_item_role := coalesce(app.stripe_item_role_v664(v_price),'other');
        insert into public.billing_provider_subscription_items(
          provider_subscription_id,provider_item_id,item_role,provider_price_id,
          quantity,unit_amount_cents,currency,interval_name,interval_count,
          current_period_start,current_period_end,provider_event_created_at,
          provider_event_rank,last_event_id
        ) values (
          v_subscription,v_item->>'id',v_item_role,v_price,
          coalesce((v_item->>'quantity')::integer,0),
          nullif(v_item#>>'{price,unit_amount}','')::integer,
          upper(nullif(v_item#>>'{price,currency}','')),
          v_item#>>'{price,recurring,interval}',
          nullif(v_item#>>'{price,recurring,interval_count}','')::integer,
          app.stripe_epoch_v77(v_item->'current_period_start'),
          app.stripe_epoch_v77(v_item->'current_period_end'),
          v_event.event_created_at,v_rank,v_event.event_id
        )
        on conflict(provider_item_id) do update
          set item_role=excluded.item_role,provider_price_id=excluded.provider_price_id,
              quantity=excluded.quantity,unit_amount_cents=excluded.unit_amount_cents,
              currency=excluded.currency,interval_name=excluded.interval_name,
              interval_count=excluded.interval_count,
              current_period_start=excluded.current_period_start,
              current_period_end=excluded.current_period_end,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
        where (excluded.provider_event_created_at,excluded.provider_event_rank)
              >= (billing_provider_subscription_items.provider_event_created_at,
                  billing_provider_subscription_items.provider_event_rank);
      end loop;

      update public.subscriptions tenant_subscription
         set billing_provider='stripe',provider_customer_id=v_customer,
             provider_subscription_id=v_subscription,status=v_status,
             billing_cadence=v_cadence,cadence_months=v_cadence_months,
             current_period_start=coalesce(v_period_start,current_period_start),
             current_period_end=coalesce(v_period_end,current_period_end),
             next_payment_at=v_period_end,
             cancel_at_period_end=coalesce((v_object->>'cancel_at_period_end')::boolean,false),
             canceled_at=app.stripe_epoch_v77(v_object->'canceled_at'),
             provider_base_item_id=(
               select item.provider_item_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='base'
                order by item.updated_at desc limit 1
             ),
             provider_seat_item_id=(
               select item.provider_item_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),
             provider_base_price_id=(
               select item.provider_price_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='base'
                order by item.updated_at desc limit 1
             ),
             provider_seat_price_id=(
               select item.provider_price_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),
             provider_seat_quantity=coalesce((
               select item.quantity
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),0),
             provider_event_created_at=v_event.event_created_at,
             provider_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.provider_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.provider_event_created_at,
                     tenant_subscription.provider_event_rank));

      /* v794: a firm that had just paid by card read "No card yet" on its own Subscription page,
         because nothing on the Stripe path ever wrote billing_provider_customers.payment_method_*.
         Stripe's webhooks carry NO card brand or last4 (verified across all four events of a live
         checkout), but customer.subscription.* does carry default_payment_method — which is proof
         that a method is stored and the next renewal will be collected automatically. Record that
         much and nothing more: kind 'other' renders as "Payment method on file". Inventing 'card'
         here would be a guess, and inventing digits is what billingCardTextV758 exists to prevent.
         The brand and last4 still require an API read (the update_card / refresh_payment_method
         command), which fills them in without contradicting this. */
      if coalesce(nullif(v_object->>'default_payment_method',''),
                  nullif(v_object#>>'{default_payment_method,id}','')) is not null then
        update public.billing_provider_customers customer
           set payment_method_kind='other',
               payment_method_updated_at=coalesce(customer.payment_method_updated_at,
                                                  v_event.event_created_at),
               updated_at=now()
         where customer.business_id=v_business
           and customer.payment_method_kind is null;
      end if;
    end if;

    if v_event.event_type like 'invoice.%' then
      v_invoice := v_object->>'id';
      if exists(
        select 1 from public.billing_provider_invoices invoice
         where invoice.provider_invoice_id=v_invoice
           and invoice.business_id<>v_business
      ) then
        raise exception 'Stripe invoice is already linked to another business';
      end if;
      if v_subscription is not null and exists(
        select 1 from public.billing_provider_subscriptions subscription
         where subscription.provider_subscription_id=v_subscription
           and subscription.business_id<>v_business
      ) then
        raise exception 'Stripe invoice references another business subscription';
      end if;
      v_status := case
        when v_event.event_type = 'invoice.paid' then 'paid'
        when v_event.event_type = 'invoice.voided' then 'void'
        when v_event.event_type = 'invoice.marked_uncollectible' then 'uncollectible'
        when v_object->>'status' in ('draft','open','void','uncollectible')
          then v_object->>'status'
        else 'open'
      end;
      v_subtotal := greatest(coalesce(
        nullif(v_object->>'total_excluding_tax','')::integer,
        nullif(v_object->>'subtotal_excluding_tax','')::integer,
        nullif(v_object->>'subtotal','')::integer,0
      ),0);
      v_total := greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
      v_tax := greatest(v_total-v_subtotal,0);
      v_due := greatest(coalesce(nullif(v_object->>'amount_due','')::integer,v_total),0);
      v_paid := greatest(coalesce(nullif(v_object->>'amount_paid','')::integer,0),0);
      v_remaining := greatest(coalesce(
        nullif(v_object->>'amount_remaining','')::integer,v_due-v_paid,0
      ),0);
      v_next_attempt := app.stripe_epoch_v77(v_object->'next_payment_attempt');
      v_paid_at := case when v_event.event_type='invoice.paid' then coalesce(
        app.stripe_epoch_v77(v_object#>'{status_transitions,paid_at}'),
        v_event.event_created_at
      ) end;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,
        provider_invoice_id,provider_payment_intent_id,number,currency,
        collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,
        total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,
        net_cash_ex_tax_cents,period_start,period_end,due_at,
        next_payment_attempt_at,paid_at,finalized_at,voided_at,
        marked_uncollectible_at,livemode,provider_event_created_at,
        provider_event_rank,last_event_id,reason,detail
      ) values (
        v_business,v_customer,v_subscription,v_invoice,
        case when jsonb_typeof(v_object->'payment_intent')='string'
             then v_object->>'payment_intent'
             else v_object#>>'{payment_intent,id}' end,
        v_object->>'number',upper(coalesce(nullif(v_object->>'currency',''),'SGD')),
        v_object->>'collection_method',v_status,
        v_event.event_type='invoice.paid',v_subtotal,v_tax,v_total,v_due,v_paid,
        v_remaining,
        case when v_event.event_type='invoice.paid'
             then greatest(least(v_paid,v_total)-least(v_tax,least(v_paid,v_total)),0)
             else 0 end,
        /* v794: Stripe stamps invoice.period_start = invoice.period_end = the moment the
           invoice was created on a subscription_create invoice; the SERVICE window lives on the
           line item. Reading the invoice's own stamps therefore recorded a zero-length period,
           which made platform_get_subscription_operations_v156 compute paid_through as the day
           BEFORE the payment. The line period is the truth; the invoice stamps remain the
           fallback for invoice shapes that carry no lines. */
        coalesce(app.stripe_epoch_v77(v_object#>'{lines,data,0,period,start}'),
                 app.stripe_epoch_v77(v_object->'period_start')),
        coalesce(app.stripe_epoch_v77(v_object#>'{lines,data,0,period,end}'),
                 app.stripe_epoch_v77(v_object->'period_end')),
        app.stripe_epoch_v77(v_object->'due_date'),v_next_attempt,v_paid_at,
        app.stripe_epoch_v77(v_object#>'{status_transitions,finalized_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,voided_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,marked_uncollectible_at}'),
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id,
        /* v794: only the BRANCH applier set reason, so every COMPANY invoice carried NULL and
           the Payments row read the generic "Subscription" instead of naming the plan and the
           period it bought. Stripe already says which kind of invoice this is; translate it into
           the vocabulary the reader (billingInvoiceReasonTextV764) already speaks. */
        case v_object->>'billing_reason'
             when 'subscription_create' then 'initial'
             when 'subscription_cycle' then 'renewal'
             when 'subscription_update' then 'plan_changed'
             when 'subscription' then 'renewal'
             when 'manual' then 'other'
             else null end,
        case when v_object#>>'{lines,data,0,period,end}' is not null
             then jsonb_build_object(
               'covers_from', app.stripe_epoch_v77(v_object#>'{lines,data,0,period,start}'),
               'covers_until', app.stripe_epoch_v77(v_object#>'{lines,data,0,period,end}'))
             end
      )
      on conflict(provider_invoice_id) do update
        set provider_payment_intent_id=coalesce(
              excluded.provider_payment_intent_id,
              billing_provider_invoices.provider_payment_intent_id
            ),
            number=coalesce(excluded.number,billing_provider_invoices.number),
            collection_method=excluded.collection_method,status=excluded.status,
            paid_normalized=excluded.paid_normalized,
            subtotal_ex_tax_cents=excluded.subtotal_ex_tax_cents,
            tax_cents=excluded.tax_cents,total_cents=excluded.total_cents,
            amount_due_cents=excluded.amount_due_cents,
            amount_paid_cents=excluded.amount_paid_cents,
            amount_remaining_cents=excluded.amount_remaining_cents,
            net_cash_ex_tax_cents=excluded.net_cash_ex_tax_cents,
            period_start=excluded.period_start,period_end=excluded.period_end,
            due_at=excluded.due_at,
            next_payment_attempt_at=excluded.next_payment_attempt_at,
            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,
            voided_at=excluded.voided_at,
            marked_uncollectible_at=excluded.marked_uncollectible_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,
            /* A reason a COMMAND already recorded (branch_added, capacity_increase) is more
               specific than anything derived from billing_reason, so it outranks it. */
            reason=coalesce(billing_provider_invoices.reason,excluded.reason),
            detail=coalesce(billing_provider_invoices.detail,excluded.detail),
            updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_invoices.provider_event_created_at,
                billing_provider_invoices.provider_event_rank);

      if v_event.event_type in (
        'invoice.paid','invoice.payment_failed','invoice.payment_action_required'
      ) then
        v_attempt_state := case v_event.event_type
          when 'invoice.paid' then 'paid'
          when 'invoice.payment_failed' then 'failed'
          else 'action_required'
        end;
        insert into public.billing_payment_attempts(
          business_id,provider_invoice_id,source_event_id,
          provider_payment_intent_id,provider_charge_id,attempt_state,
          amount_cents,tax_cents,failure_code,failure_message,next_attempt_at,
          occurred_at,collection_method
        ) values (
          v_business,v_invoice,v_event.event_id,
          case when jsonb_typeof(v_object->'payment_intent')='string'
               then v_object->>'payment_intent'
               else v_object#>>'{payment_intent,id}' end,
          v_object#>>'{charge,id}',v_attempt_state,
          case when v_attempt_state='paid' then v_paid else v_due end,
          v_tax,v_object#>>'{last_finalization_error,code}',
          left(v_object#>>'{last_finalization_error,message}',1000),
          v_next_attempt,v_event.event_created_at,v_object->>'collection_method'
        ) on conflict(source_event_id) do nothing;
      end if;

      update public.subscriptions tenant_subscription
         set payment_status=case
               when v_event.event_type='invoice.payment_failed' then 'failed'
               when v_event.event_type='invoice.payment_action_required'
                 then 'action_required'
               when v_event.event_type='invoice.paid' then 'paid'
               else payment_status
             end,
             period_subtotal_cents=v_subtotal,period_tax_cents=v_tax,
             period_total_cents=v_total,
             next_payment_at=case
               when v_event.event_type in (
                 'invoice.payment_failed','invoice.payment_action_required'
               ) then v_next_attempt
               else next_payment_at
             end,
             last_paid_at=case when v_event.event_type='invoice.paid'
                               then v_paid_at else last_paid_at end,
             last_paid_invoice_id=case when v_event.event_type='invoice.paid'
                                       then v_invoice else last_paid_invoice_id end,
             payment_event_created_at=v_event.event_created_at,
             payment_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.payment_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.payment_event_created_at,
                     tenant_subscription.payment_event_rank));
    end if;

    if v_event.event_type in ('refund.created','charge.dispute.created') then
      if v_event.event_type='refund.created' then
        select invoice_row.* into v_adjustment_invoice
          from public.billing_provider_invoices invoice_row
         where invoice_row.provider_payment_intent_id =
               coalesce(
                 case when jsonb_typeof(v_object->'payment_intent')='string'
                      then v_object->>'payment_intent'
                      else v_object#>>'{payment_intent,id}' end,
                 (
                   select attempt.provider_payment_intent_id
                     from public.billing_payment_attempts attempt
                    where attempt.provider_charge_id = v_object->>'charge'
                    order by attempt.occurred_at desc limit 1
                 )
               )
         order by invoice_row.paid_at desc nulls last
         limit 1;
        v_adjustment_total := -greatest(coalesce((v_object->>'amount')::integer,0),0);
      else
        select invoice_row.* into v_adjustment_invoice
          from public.billing_payment_attempts attempt
          join public.billing_provider_invoices invoice_row
            on invoice_row.provider_invoice_id=attempt.provider_invoice_id
         where attempt.provider_charge_id = coalesce(
           case when jsonb_typeof(v_object->'charge')='string'
                then v_object->>'charge' else v_object#>>'{charge,id}' end,
           v_object->>'charge'
         )
         order by attempt.occurred_at desc limit 1;
        v_adjustment_total := -greatest(coalesce((v_object->>'amount')::integer,0),0);
      end if;
      if v_adjustment_invoice.id is null or v_adjustment_total = 0 then
        raise exception 'refund or chargeback cannot be mapped to a paid invoice';
      end if;
      v_adjustment_tax := case when v_adjustment_invoice.total_cents > 0 then
        -floor(
          abs(v_adjustment_total)::numeric
          * v_adjustment_invoice.tax_cents::numeric
          / v_adjustment_invoice.total_cents::numeric
        )::integer
      else 0 end;
      v_adjustment_net := v_adjustment_total-v_adjustment_tax;
      insert into public.billing_adjustments(
        business_id,provider_invoice_id,adjustment_type,
        subtotal_ex_tax_cents,tax_cents,total_cents,currency,source_event_id,
        provider_object_id,reason,evidence_sha256,occurred_at
      ) values (
        v_adjustment_invoice.business_id,
        v_adjustment_invoice.provider_invoice_id,
        case when v_event.event_type='refund.created' then 'refund' else 'chargeback' end,
        v_adjustment_net,v_adjustment_tax,v_adjustment_total,
        v_adjustment_invoice.currency,v_event.event_id,v_object->>'id',
        case when v_event.event_type='refund.created'
             then 'Stripe refund event' else 'Stripe chargeback event' end,
        v_event.payload_sha256,v_event.event_created_at
      ) on conflict(source_event_id) do nothing;
    end if;

    insert into public.billing_evidence(
      business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference
    ) values (
      v_business,'provider_event','stripe_event',v_event.event_id,
      v_event.payload_sha256,v_event.object_id
    ) on conflict do nothing;

    update public.billing_provider_events
       set processing_status='processed',business_id=v_business,
           processed_at=now(),last_error=null
     where id=v_event.id;
    return jsonb_build_object(
      'event_id',p_event_id,'status','processed','business_id',v_business
    );
  exception when others then
    update public.billing_provider_events
       set processing_status='failed',last_error=left(sqlerrm,2000)
     where id=v_event.id;
    return jsonb_build_object(
      'event_id',p_event_id,'status','failed','error',left(sqlerrm,500)
    );
  end;
end
$function$;

revoke all on function public.apply_stripe_billing_event_v94_base(text) from public, anon, authenticated;

-- =============================================================================================
-- 5 · Repair the rows already written under the old behaviour, from the provider evidence.
-- =============================================================================================
-- Only invoices whose own stamps are a zero-length period are touched, and only where the stored
-- event actually carries a line period. Nothing is inferred; nothing already correct is rewritten.
update public.billing_provider_invoices invoice
   set period_start = coalesce(
         app.stripe_epoch_v77(event.payload#>'{data,object,lines,data,0,period,start}'),
         invoice.period_start),
       period_end = coalesce(
         app.stripe_epoch_v77(event.payload#>'{data,object,lines,data,0,period,end}'),
         invoice.period_end),
       reason = coalesce(invoice.reason, case event.payload#>>'{data,object,billing_reason}'
             when 'subscription_create' then 'initial'
             when 'subscription_cycle' then 'renewal'
             when 'subscription_update' then 'plan_changed'
             when 'subscription' then 'renewal'
             when 'manual' then 'other'
             else null end),
       detail = coalesce(invoice.detail, case
         when event.payload#>>'{data,object,lines,data,0,period,end}' is not null
         then jsonb_build_object(
           'covers_from', app.stripe_epoch_v77(event.payload#>'{data,object,lines,data,0,period,start}'),
           'covers_until', app.stripe_epoch_v77(event.payload#>'{data,object,lines,data,0,period,end}'))
         end),
       updated_at = now()
  from public.billing_provider_events event
 where event.provider = 'stripe'
   and event.event_id = invoice.last_event_id
   and invoice.period_start is not distinct from invoice.period_end
   and event.payload#>>'{data,object,lines,data,0,period,end}' is not null;

-- The same repair for the payment method: a live subscription whose provider event proves a
-- default payment method is on file, but whose customer row was never told.
update public.billing_provider_customers customer
   set payment_method_kind = 'other',
       payment_method_updated_at = coalesce(customer.payment_method_updated_at, event.event_created_at),
       updated_at = now()
  from public.billing_provider_events event
 where event.provider = 'stripe'
   and event.event_type like 'customer.subscription.%'
   and coalesce(nullif(event.payload#>>'{data,object,default_payment_method}',''),
                nullif(event.payload#>>'{data,object,default_payment_method,id}','')) is not null
   and customer.business_id = (
         select subscription.business_id from public.billing_provider_subscriptions subscription
          where subscription.provider_subscription_id = event.payload#>>'{data,object,id}')
   and customer.payment_method_kind is null;

commit;
