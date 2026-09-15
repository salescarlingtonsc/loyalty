-- nestly_v986 — a discounted payment is still a payment (2026-09-16).
--
-- OWNER, 2026-09-16: "my stripe is already live. ensure no defects".
--
-- THE DEFECT, proven against production before this was written, rolled back, with a control.
-- Same firm, same subscription, same settled payment; the ONLY variable is a 15% promo:
--
--   first invoice at the full 100  ->  active    / paid          / source=provider_invoice_self_serve
--   first invoice at 85 (15% off)  ->  incomplete/ not_collected / source=NONE
--
-- and on a firm that has actually gone live (activated_at set), the second arm is not cosmetic:
--
--   paid full price      ->  active    / join_enabled=true  / 1 active branch
--   paid with 15% promo  ->  past_due  / join_enabled=FALSE / 0 active branches
--
-- A firm redeems a promo code, pays, and Peekaa closes their customer join and switches off every
-- branch they have. SAVE200 -- active, unrestricted, unlimited, no expiry -- was live when this was
-- found; it has been deactivated pending this fix. Nothing has fired yet only because all 24
-- businesses currently have activated_at IS NULL.
--
-- WHY IT HAPPENS, in two halves that have to be fixed together.
--
-- 1. THE MIRROR CANNOT HOLD A DISCOUNT. billing_provider_invoices has
--        CHECK (total_cents = subtotal_ex_tax_cents + tax_cents)
--    and v125 pins tax_cents to 0, so total must equal subtotal and "list 100, less 15, pay 85" is
--    unrepresentable. Both appliers dodged this by reading Stripe's `total_excluding_tax` as the
--    SUBTOTAL, storing 85 / 0 / 85 -- the CHECK passes and the discount silently ceases to exist.
--    The list price is lost with it, which is why nestly_v984 had to write
--    consumed_discount_cents = null with the note "the provider discount is not captured".
--
--    The two readers of that column never agreed either: stripe-billing-reconcile computes the
--    subtotal from `subtotal_excluding_tax` (100) and compares it against a stored 85, so a
--    discounted invoice would be reported as a reconciliation mismatch every night -- and the
--    reconciler could not have written its own view even if it tried, because 100/0/85 violates
--    the CHECK. That is the shape the very first probe hit.
--
-- 2. v510 COMPARED THE WRONG NUMBER. app.v510_verified_initial_payment accepted an invoice as
--    proof of payment only when `invoice.amount_paid_cents = subscriptions.period_total_cents`.
--    A discount makes those two differ BY DESIGN, so a promo-discounted payment produced no
--    evidence at all -- and app.v510_sync_payment_readiness'"'"'s no-evidence arm did the rest.
--
-- WHAT THIS MIGRATION DOES
--   1. billing_provider_invoices.discount_cents, and the CHECK becomes
--        total_cents = subtotal_ex_tax_cents - discount_cents + tax_cents
--      Every existing row has discount 0 and already satisfies it, so there is no backfill: the
--      13 invoices on this estate all have subtotal = total (0 of 13 carry a discount, measured).
--   2. Both appliers -- the company one and the branch one -- read `subtotal` (Stripe: before any
--      invoice-level discount) for the subtotal and `total_excluding_tax` (after it) for the net,
--      and record the difference as the discount. The subtotal is then derived back from those two
--      so `total = subtotal - discount + tax` holds by construction, not by luck: a payload where
--      subtotal < total_excluding_tax would otherwise floor the discount at 0, break the CHECK,
--      fail the event and hand it to nestly-v281-billing-event-redrive every five minutes for ever.
--   3. v510 asks the question it meant to ask: did they settle the invoice in full
--      (amount_paid = total, nothing remaining), and was the thing they bought the thing they owed
--      (subtotal before the discount = period_total_cents)? That is STRICTER than before in one
--      direction -- a partial payment of a discounted invoice no longer counts, where previously a
--      coincidental equality could have -- and correctly looser in the other.
--
-- NOT CHANGED, deliberately: the manual-payment arm (a hand-verified payment has no provider
-- invoice and its own v967 promo path), billing_adjustments (its own table, its own
-- total = subtotal + tax CHECK, no discount concept -- and the company applier writes to it a few
-- lines from the code being patched here, so it is named to be sure it was left alone), and
-- subscriptions.period_total_cents, which stays the LIST price. It is the obligation; the discount
-- is a fact about one invoice, not a change to what the firm signed up for.
--
-- Scanner: D23 in db/tests/tenant_divergence_scan.sql.
-- Rollback suite: db/tests/v986_a_discounted_payment_is_still_a_payment.sql

begin;

-- =============================================================================================
-- 0 · Preconditions.
-- =============================================================================================
do $v986_assert$
declare v_bad integer; v_disc integer;
begin
  select count(*) into v_bad from public.billing_provider_invoices
   where total_cents <> subtotal_ex_tax_cents + tax_cents;
  if v_bad > 0 then
    raise exception 'v986: % invoices already violate the old identity -- investigate before widening it', v_bad;
  end if;

  /* If a discounted invoice were already stored, it would be stored WRONG (subtotal = the
     discounted figure) and adding a 0 default would silently bless it. There are none. */
  select count(*) into v_disc from public.billing_provider_invoices
   where subtotal_ex_tax_cents <> total_cents;
  if v_disc > 0 then
    raise exception 'v986: % invoices already differ subtotal vs total -- they need a real backfill, not a default', v_disc;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='billing_provider_invoices'
                and column_name='discount_cents') then
    raise exception 'v986: discount_cents already exists';
  end if;

  if position('v986' in pg_get_functiondef('app.v510_verified_initial_payment(uuid)'::regprocedure)) > 0 then
    raise exception 'v986: v510_verified_initial_payment already carries v986';
  end if;
end
$v986_assert$;

-- =============================================================================================
-- 1 · The mirror learns what a discount is.
-- =============================================================================================
alter table public.billing_provider_invoices
  add column discount_cents integer not null default 0 check (discount_cents >= 0);

alter table public.billing_provider_invoices drop constraint billing_provider_invoices_total_check;
alter table public.billing_provider_invoices
  add constraint billing_provider_invoices_total_check
  check (total_cents = subtotal_ex_tax_cents - discount_cents + tax_cents);

comment on column public.billing_provider_invoices.discount_cents is
  'nestly_v986: the invoice-level discount, ex tax -- Stripe subtotal minus total_excluding_tax. subtotal_ex_tax_cents is the LIST price before it, total_cents the amount actually charged.';

-- =============================================================================================
-- 2 · The company applier.
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
  v_total_ex_tax integer;   /* nestly_v986 */
  v_discount integer;       /* nestly_v986 */
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
      /* nestly_v986. The old mapping read Stripe's `total_excluding_tax` as the SUBTOTAL, so a
         discounted invoice was stored as though its discounted figure were the list price: a 15%
         coupon on SGD 1.00 landed as subtotal 85 / total 85 and the discount vanished. Stripe is
         explicit about which is which -- `subtotal` is before any invoice-level discount and
         `total_excluding_tax` is after it -- so the difference between them IS the discount. */
      v_subtotal := greatest(coalesce(
        nullif(v_object->>'subtotal_excluding_tax','')::integer,
        nullif(v_object->>'subtotal','')::integer,0
      ),0);
      v_total := greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
      v_total_ex_tax := greatest(coalesce(
        nullif(v_object->>'total_excluding_tax','')::integer,v_total
      ),0);
      v_tax := greatest(v_total-v_total_ex_tax,0);
      v_discount := greatest(v_subtotal-v_total_ex_tax,0);
      /* Subtotal is then DERIVED back from the two figures that produced the discount, so
         total = subtotal - discount + tax holds by construction rather than by luck. Without it a
         payload where subtotal < total_excluding_tax would floor the discount at 0, break the
         CHECK, fail the event, and hand it to the five-minute redrive loop for ever. */
      v_subtotal := v_total_ex_tax + v_discount;
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
        collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,discount_cents,
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
        v_event.event_type='invoice.paid',v_subtotal,v_tax,v_discount,v_total,v_due,v_paid,
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
            tax_cents=excluded.tax_cents,discount_cents=excluded.discount_cents,total_cents=excluded.total_cents,
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

-- =============================================================================================
-- 3 · The branch applier.
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.apply_stripe_branch_event_v791(p_event_id text, p_business uuid, p_branch uuid, p_rank smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_event public.billing_provider_events%rowtype;
  v_object jsonb;
  v_branch public.branches%rowtype;
  v_customer text;
  v_subscription text;
  v_invoice text;
  v_status text;
  v_interval text;
  v_interval_count integer;
  v_cadence text;
  v_cadence_months integer;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_next_attempt timestamptz;
  v_paid_at timestamptz;
  v_subtotal integer; v_tax integer; v_total integer; v_total_ex_tax integer; v_discount integer; v_due integer; v_paid integer; v_remaining integer;
  v_item jsonb;
  v_price text;
  v_unit integer;
  v_cancel_at_period_end boolean;
  v_ended_at timestamptz;
  v_paid_now boolean := false;
  v_new_state text;
  v_new_active boolean;
  v_new_cancel_at timestamptz;
  v_last4 text;
  v_brand text;
  v_result jsonb;
begin
  select * into v_event from public.billing_provider_events
   where provider = 'stripe' and event_id = p_event_id;
  select * into v_branch from public.branches where id = p_branch and business_id = p_business;
  if v_branch.id is null then
    raise exception 'Stripe branch event names a branch outside its business';
  end if;

  begin
    v_object := v_event.payload #> '{data,object}';
    v_customer := case when jsonb_typeof(v_object->'customer') = 'string' then v_object->>'customer'
                       else v_object#>>'{customer,id}' end;
    v_subscription := coalesce(
      case when v_object->>'object' = 'subscription' then v_object->>'id' end,
      case when jsonb_typeof(v_object->'subscription') = 'string' then v_object->>'subscription'
           else v_object#>>'{subscription,id}' end,
      v_object#>>'{parent,subscription_details,subscription}'
    );

    if v_customer is not null then
      insert into public.billing_provider_customers(
        business_id,provider,provider_customer_id,currency,livemode,provider_created_at,
        provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        p_business,'stripe',v_customer,upper(coalesce(nullif(v_object->>'currency',''),'SGD')),
        v_event.livemode,app.stripe_epoch_v77(v_object->'created'),
        v_event.event_created_at,p_rank,v_event.event_id
      )
      on conflict(business_id) do update
        set provider_customer_id=excluded.provider_customer_id,provider='stripe',
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_customers.provider_event_created_at,billing_provider_customers.provider_event_rank);
    end if;

    if v_event.event_type like 'customer.subscription.%' then
      if exists(select 1 from public.billing_provider_subscriptions m
                 where m.provider_subscription_id=v_subscription and m.business_id<>p_business) then
        raise exception 'Stripe subscription is already linked to another business';
      end if;
      if exists(select 1 from public.branch_subscriptions_v786 o
                 where o.provider_subscription_id=v_subscription and o.branch_id<>p_branch) then
        raise exception 'Stripe subscription is already linked to another branch';
      end if;
      v_status := case
        when v_event.event_type = 'customer.subscription.deleted' then 'canceled'
        when v_object->>'status' in ('trialing','active','incomplete','incomplete_expired','past_due','unpaid','paused','canceled')
          then v_object->>'status'
        else 'incomplete' end;
      select item into v_item
        from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb)) item
       order by coalesce((item->>'quantity')::integer,0) desc limit 1;
      v_price := coalesce(v_item#>>'{price,id}',v_item->>'price');
      v_unit := nullif(v_item#>>'{price,unit_amount}','')::integer;
      v_interval := v_item#>>'{price,recurring,interval}';
      v_interval_count := nullif(v_item#>>'{price,recurring,interval_count}','')::integer;
      v_cadence := app.stripe_cadence_v77(v_interval,v_interval_count);
      v_cadence_months := case v_cadence when 'quarterly' then 3 when 'half_yearly' then 6 when 'annual' then 12 else null end;
      v_period_start := coalesce(app.stripe_epoch_v77(v_item->'current_period_start'),app.stripe_epoch_v77(v_object->'current_period_start'));
      v_period_end := coalesce(app.stripe_epoch_v77(v_item->'current_period_end'),app.stripe_epoch_v77(v_object->'current_period_end'));
      v_cancel_at_period_end := coalesce((v_object->>'cancel_at_period_end')::boolean,false);
      v_ended_at := app.stripe_epoch_v77(v_object->'ended_at');

      insert into public.billing_provider_subscriptions(
        business_id,provider_customer_id,provider_subscription_id,status,
        cadence,cadence_months,currency,current_period_start,current_period_end,
        billing_cycle_anchor,trial_end,cancel_at_period_end,canceled_at,ended_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        p_business,v_customer,v_subscription,v_status,v_cadence,v_cadence_months,
        upper(coalesce(nullif(v_object->>'currency',''),'SGD')),v_period_start,v_period_end,
        app.stripe_epoch_v77(v_object->'billing_cycle_anchor'),app.stripe_epoch_v77(v_object->'trial_end'),
        v_cancel_at_period_end,app.stripe_epoch_v77(v_object->'canceled_at'),v_ended_at,
        v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id
      )
      on conflict(provider_subscription_id) do update
        set status=excluded.status,cadence=excluded.cadence,cadence_months=excluded.cadence_months,
            currency=excluded.currency,current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,billing_cycle_anchor=excluded.billing_cycle_anchor,
            trial_end=excluded.trial_end,cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_subscriptions.provider_event_created_at,billing_provider_subscriptions.provider_event_rank);

      for v_item in select value from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb)) loop
        insert into public.billing_provider_subscription_items(
          provider_subscription_id,provider_item_id,item_role,provider_price_id,quantity,unit_amount_cents,
          currency,interval_name,interval_count,current_period_start,current_period_end,
          provider_event_created_at,provider_event_rank,last_event_id
        ) values (
          v_subscription,v_item->>'id',coalesce(app.stripe_item_role_v664(coalesce(v_item#>>'{price,id}',v_item->>'price')),'base'),
          coalesce(v_item#>>'{price,id}',v_item->>'price'),coalesce((v_item->>'quantity')::integer,0),
          nullif(v_item#>>'{price,unit_amount}','')::integer,upper(nullif(v_item#>>'{price,currency}','')),
          v_item#>>'{price,recurring,interval}',nullif(v_item#>>'{price,recurring,interval_count}','')::integer,
          app.stripe_epoch_v77(v_item->'current_period_start'),app.stripe_epoch_v77(v_item->'current_period_end'),
          v_event.event_created_at,p_rank,v_event.event_id
        )
        on conflict(provider_item_id) do update
          set item_role=excluded.item_role,provider_price_id=excluded.provider_price_id,quantity=excluded.quantity,
              unit_amount_cents=excluded.unit_amount_cents,currency=excluded.currency,interval_name=excluded.interval_name,
              interval_count=excluded.interval_count,current_period_start=excluded.current_period_start,
              current_period_end=excluded.current_period_end,provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,last_event_id=excluded.last_event_id,updated_at=now()
          where (excluded.provider_event_created_at,excluded.provider_event_rank)
                >= (billing_provider_subscription_items.provider_event_created_at,billing_provider_subscription_items.provider_event_rank);
      end loop;

      insert into public.branch_subscriptions_v786(
        business_id,branch_id,provider,provider_customer_id,provider_subscription_id,provider_plan_id,
        status,cadence,cadence_months,unit_amount_cents,current_period_start,current_period_end,next_payment_at,
        cancel_at_period_end,canceled_at,ended_at,livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        p_business,p_branch,'stripe',v_customer,v_subscription,v_price,v_status,v_cadence,v_cadence_months,v_unit,
        v_period_start,v_period_end,v_period_end,v_cancel_at_period_end,app.stripe_epoch_v77(v_object->'canceled_at'),
        v_ended_at,v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id
      )
      on conflict(branch_id) do update
        set provider='stripe',provider_customer_id=coalesce(excluded.provider_customer_id,branch_subscriptions_v786.provider_customer_id),
            provider_subscription_id=excluded.provider_subscription_id,provider_plan_id=excluded.provider_plan_id,
            status=excluded.status,cadence=coalesce(excluded.cadence,branch_subscriptions_v786.cadence),
            cadence_months=coalesce(excluded.cadence_months,branch_subscriptions_v786.cadence_months),
            unit_amount_cents=coalesce(excluded.unit_amount_cents,branch_subscriptions_v786.unit_amount_cents),
            current_period_start=coalesce(excluded.current_period_start,branch_subscriptions_v786.current_period_start),
            current_period_end=coalesce(excluded.current_period_end,branch_subscriptions_v786.current_period_end),
            next_payment_at=coalesce(excluded.next_payment_at,branch_subscriptions_v786.next_payment_at),
            cancel_at_period_end=excluded.cancel_at_period_end,canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            livemode=excluded.livemode,provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,last_event_id=excluded.last_event_id,updated_at=now()
      where branch_subscriptions_v786.provider_event_created_at is null
         or (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (branch_subscriptions_v786.provider_event_created_at,branch_subscriptions_v786.provider_event_rank);
    end if;

    if v_event.event_type like 'invoice.%' then
      v_invoice := v_object->>'id';
      if exists(select 1 from public.billing_provider_invoices i where i.provider_invoice_id=v_invoice and i.business_id<>p_business) then
        raise exception 'Stripe invoice is already linked to another business';
      end if;
      v_status := case
        when v_event.event_type = 'invoice.paid' then 'paid'
        when v_event.event_type = 'invoice.voided' then 'void'
        when v_event.event_type = 'invoice.marked_uncollectible' then 'uncollectible'
        when v_object->>'status' in ('draft','open','void','uncollectible') then v_object->>'status'
        else 'open' end;
      /* nestly_v986 -- the same correction as the company applier, for the same reason: Stripe's
         `total_excluding_tax` is AFTER the invoice discount, so reading it as the subtotal erased
         the discount and recorded the discounted figure as the list price. */
      v_subtotal := greatest(coalesce(nullif(v_object->>'subtotal_excluding_tax','')::integer,nullif(v_object->>'subtotal','')::integer,0),0);
      v_total := greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
      v_total_ex_tax := greatest(coalesce(nullif(v_object->>'total_excluding_tax','')::integer,v_total),0);
      v_tax := greatest(v_total-v_total_ex_tax,0);
      v_discount := greatest(v_subtotal-v_total_ex_tax,0);
      v_subtotal := v_total_ex_tax + v_discount;  /* keeps total = subtotal - discount + tax exact */
      v_due := greatest(coalesce(nullif(v_object->>'amount_due','')::integer,v_total),0);
      v_paid := greatest(coalesce(nullif(v_object->>'amount_paid','')::integer,0),0);
      v_remaining := greatest(coalesce(nullif(v_object->>'amount_remaining','')::integer,v_due-v_paid,0),0);
      v_next_attempt := app.stripe_epoch_v77(v_object->'next_payment_attempt');
      v_paid_at := case when v_event.event_type='invoice.paid'
                        then coalesce(app.stripe_epoch_v77(v_object#>'{status_transitions,paid_at}'),v_event.event_created_at) end;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,provider_payment_intent_id,
        number,currency,collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,discount_cents,total_cents,
        amount_due_cents,amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,period_start,period_end,
        due_at,next_payment_attempt_at,paid_at,finalized_at,voided_at,marked_uncollectible_at,livemode,
        provider_event_created_at,provider_event_rank,last_event_id,reason,detail
      ) values (
        p_business,v_customer,v_subscription,v_invoice,
        case when jsonb_typeof(v_object->'payment_intent')='string' then v_object->>'payment_intent' else v_object#>>'{payment_intent,id}' end,
        v_object->>'number',upper(coalesce(nullif(v_object->>'currency',''),'SGD')),v_object->>'collection_method',v_status,
        v_event.event_type='invoice.paid',v_subtotal,v_tax,v_discount,v_total,v_due,v_paid,v_remaining,
        case when v_event.event_type='invoice.paid' then greatest(least(v_paid,v_total)-least(v_tax,least(v_paid,v_total)),0) else 0 end,
        app.stripe_epoch_v77(v_object->'period_start'),app.stripe_epoch_v77(v_object->'period_end'),
        app.stripe_epoch_v77(v_object->'due_date'),v_next_attempt,v_paid_at,
        app.stripe_epoch_v77(v_object#>'{status_transitions,finalized_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,voided_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,marked_uncollectible_at}'),
        v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id,
        case when exists(select 1 from public.billing_provider_invoices pi where pi.provider_subscription_id=v_subscription and pi.provider_invoice_id<>v_invoice)
             then 'renewal' else 'initial' end,
        jsonb_build_object('branch_id',p_branch::text,'branch_name',v_branch.name,'own_subscription',true)
      )
      on conflict(provider_invoice_id) do update
        set provider_payment_intent_id=coalesce(excluded.provider_payment_intent_id,billing_provider_invoices.provider_payment_intent_id),
            number=coalesce(excluded.number,billing_provider_invoices.number),collection_method=excluded.collection_method,
            status=excluded.status,paid_normalized=excluded.paid_normalized,subtotal_ex_tax_cents=excluded.subtotal_ex_tax_cents,
            tax_cents=excluded.tax_cents,discount_cents=excluded.discount_cents,total_cents=excluded.total_cents,amount_due_cents=excluded.amount_due_cents,
            amount_paid_cents=excluded.amount_paid_cents,amount_remaining_cents=excluded.amount_remaining_cents,
            net_cash_ex_tax_cents=excluded.net_cash_ex_tax_cents,period_start=excluded.period_start,period_end=excluded.period_end,
            due_at=excluded.due_at,next_payment_attempt_at=excluded.next_payment_attempt_at,paid_at=excluded.paid_at,
            finalized_at=excluded.finalized_at,voided_at=excluded.voided_at,marked_uncollectible_at=excluded.marked_uncollectible_at,
            reason=coalesce(excluded.reason,billing_provider_invoices.reason),detail=coalesce(excluded.detail,billing_provider_invoices.detail),
            provider_event_created_at=excluded.provider_event_created_at,provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_invoices.provider_event_created_at,billing_provider_invoices.provider_event_rank);

      if v_event.event_type in ('invoice.paid','invoice.payment_failed','invoice.payment_action_required') then
        insert into public.billing_payment_attempts(
          business_id,provider_invoice_id,source_event_id,provider_payment_intent_id,provider_charge_id,attempt_state,
          amount_cents,tax_cents,failure_code,failure_message,next_attempt_at,occurred_at,collection_method
        ) values (
          p_business,v_invoice,v_event.event_id,
          case when jsonb_typeof(v_object->'payment_intent')='string' then v_object->>'payment_intent' else v_object#>>'{payment_intent,id}' end,
          v_object#>>'{charge,id}',
          case v_event.event_type when 'invoice.paid' then 'paid' when 'invoice.payment_failed' then 'failed' else 'action_required' end,
          case when v_event.event_type='invoice.paid' then v_paid else v_due end,v_tax,
          v_object#>>'{last_finalization_error,code}',left(v_object#>>'{last_finalization_error,message}',1000),
          v_next_attempt,v_event.event_created_at,v_object->>'collection_method'
        ) on conflict(source_event_id) do nothing;
      end if;

      update public.branch_subscriptions_v786 s
         set payment_status=case when v_event.event_type='invoice.payment_failed' then 'failed'
                                 when v_event.event_type='invoice.paid' then 'paid' else s.payment_status end,
             next_payment_at=case when v_event.event_type in ('invoice.payment_failed','invoice.payment_action_required')
                                  then coalesce(v_next_attempt,s.next_payment_at) else s.next_payment_at end,
             last_paid_at=case when v_event.event_type='invoice.paid' then v_paid_at else s.last_paid_at end,
             last_paid_invoice_id=case when v_event.event_type='invoice.paid' then v_invoice else s.last_paid_invoice_id end,
             payment_event_created_at=v_event.event_created_at,payment_event_rank=p_rank,updated_at=now()
       where s.branch_id=p_branch
         and (s.payment_event_created_at is null
              or (v_event.event_created_at,p_rank) >= (s.payment_event_created_at,s.payment_event_rank));
      v_paid_now := v_event.event_type='invoice.paid';
    end if;

    select * into v_branch from public.branches where id = p_branch;
    v_new_state := null;
    if v_paid_now then
      v_new_state := 'active'; v_new_active := true; v_new_cancel_at := null;
    elsif v_event.event_type = 'customer.subscription.deleted'
          or (v_event.event_type like 'customer.subscription.%' and v_object->>'status' in ('canceled','unpaid','incomplete_expired')) then
      if v_branch.billing_state <> 'unsubscribed' then
        v_new_state := case when v_object->>'status' = 'unpaid' then 'suspended' else 'unsubscribed' end;
        v_new_active := false; v_new_cancel_at := null;
      end if;
    elsif v_event.event_type like 'customer.subscription.%' and v_cancel_at_period_end
          and v_period_end is not null and v_period_end > now()
          and v_branch.billing_state in ('active','pending_payment') then
      v_new_state := 'canceling'; v_new_active := v_branch.active; v_new_cancel_at := v_period_end;
    elsif v_event.event_type like 'customer.subscription.%' and not v_cancel_at_period_end
          and v_branch.billing_state = 'canceling' and v_object->>'status' = 'active' then
      v_new_state := 'active'; v_new_active := true; v_new_cancel_at := null;
    end if;
    if v_new_state is not null and (v_new_state <> v_branch.billing_state or v_new_active <> v_branch.active) then
      perform set_config('app.branch_authority_v621','on',true);
      perform set_config('app.v79_system_transition','on',true);
      update public.branches
         set billing_state = v_new_state,
             billing_state_prior = case when v_new_state in ('suspended','canceling') then v_branch.billing_state else null end,
             billing_cancel_at = v_new_cancel_at, active = v_new_active, updated_at = now()
       where id = p_branch;
      perform set_config('app.branch_authority_v621','off',true);
      perform set_config('app.v79_system_transition','off',true);
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      values (p_business,null,'BRANCH_SUBSCRIPTION_STATE_V791','branches',p_branch,
              jsonb_build_object('event_id',v_event.event_id,'event_type',v_event.event_type,'from',v_branch.billing_state,
                                 'to',v_new_state,'active',v_new_active,'provider_subscription_id',v_subscription));
    end if;

    insert into public.billing_evidence(business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference)
    values (p_business,'provider_event','stripe_event',v_event.event_id,v_event.payload_sha256,v_event.object_id)
    on conflict do nothing;

    update public.billing_provider_events
       set processing_status='processed',business_id=p_business,processed_at=now(),last_error=null
     where id=v_event.id;
    v_result := jsonb_build_object('event_id',p_event_id,'status','processed','business_id',p_business,
                                   'branch_id',p_branch,'scope','branch','paid',v_paid_now);
  exception when others then
    update public.billing_provider_events set processing_status='failed',last_error=left(sqlerrm,2000) where id=v_event.id;
    return jsonb_build_object('event_id',p_event_id,'status','failed','error',left(sqlerrm,500),'scope','branch');
  end;
  return v_result;
end
$function$;

-- =============================================================================================
-- 4 · What counts as proof of payment.
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v510_verified_initial_payment(p_business uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with obligation as (
    select subscription.* from public.subscriptions subscription
    join public.sme_commercial_terms terms on terms.id=subscription.commercial_terms_id
    where subscription.business_id=p_business and terms.contract_status in ('accepted','signed')
      and terms.accepted_value_cents>0
  ), self_serve as (
    -- No commercial terms exist for this tenant, so there is no contract period to match against.
    -- The subscription row itself is the obligation: its currency and its period total.
    select subscription.* from public.subscriptions subscription
    where subscription.business_id=p_business
      and subscription.commercial_terms_id is null
      and subscription.billing_provider in ('stripe','razorpay')
      and subscription.period_total_cents>0
      and subscription.provider_subscription_id is not null
  ), evidence as (
    select 'stripe_invoice' source,invoice.id evidence_id,invoice.paid_at verified_at
    from obligation join public.billing_provider_invoices invoice
      on invoice.business_id=obligation.business_id
      and invoice.provider_subscription_id=obligation.provider_subscription_id
    where obligation.billing_provider in ('stripe','razorpay') and invoice.paid_normalized and invoice.status='paid'
      and invoice.currency=obligation.currency
      /* nestly_v986: what must equal the obligation is the invoice's LIST price, not the amount
         charged. A promo makes those two different on purpose. What the firm must have done is
         settle the invoice in full -- so paid = total, nothing remaining -- and the thing they
         bought must be the thing they owed, which is subtotal before the discount came off. */
      and invoice.amount_paid_cents=invoice.total_cents
      and invoice.amount_remaining_cents=0
      and invoice.subtotal_ex_tax_cents=obligation.period_total_cents
      and app.sg_day(invoice.period_start)=obligation.obligation_period_start
      and (app.sg_day(invoice.period_end)=obligation.obligation_period_end
        or app.sg_day(invoice.period_end)=obligation.obligation_period_end+1)
      and not exists(select 1 from public.billing_adjustments adjustment
        where adjustment.provider_invoice_id=invoice.provider_invoice_id
          and adjustment.adjustment_type in ('refund','chargeback'))
    union all
    select 'provider_invoice_self_serve',invoice.id,invoice.paid_at
    from self_serve join public.billing_provider_invoices invoice
      on invoice.business_id=self_serve.business_id
      and invoice.provider_subscription_id=self_serve.provider_subscription_id
    where invoice.paid_normalized and invoice.status='paid'
      and invoice.currency=self_serve.currency
      /* nestly_v986, as above. This is the arm a self-serve firm redeeming a promo code lands in,
         and the one that was proven to read a paid firm as unpaid. */
      and invoice.amount_paid_cents=invoice.total_cents
      and invoice.amount_remaining_cents=0
      and invoice.subtotal_ex_tax_cents=self_serve.period_total_cents
      and not exists(select 1 from public.billing_adjustments adjustment
        where adjustment.provider_invoice_id=invoice.provider_invoice_id
          and adjustment.adjustment_type in ('refund','chargeback'))
    union all
    select 'manual_payment',payment.id,payment.verified_at
    from obligation join public.platform_subscription_documents_v156 document
      on document.business_id=obligation.business_id and document.document_type='invoice'
    join public.platform_manual_payments_v156 payment
      on payment.invoice_document_id=document.id and payment.status='verified'
    where obligation.billing_provider='manual' and document.provider_invoice_id is null
      and document.currency=obligation.currency
      and document.total_cents=obligation.period_total_cents
      and payment.amount_cents=obligation.period_total_cents
      and document.service_period_start=obligation.obligation_period_start
      and document.service_period_end=obligation.obligation_period_end
  ) select jsonb_build_object('source',source,'evidence_id',evidence_id,'verified_at',verified_at)
    from evidence order by verified_at limit 1
$function$;

-- =============================================================================================
-- 4b · CREATE OR REPLACE preserves grants, so this changes nothing -- it is restated because the
--      preflight gate requires every migration that replaces a public SECURITY DEFINER RPC to say
--      so out loud, which is how a genuinely new one never ships world-executable by default.
-- =============================================================================================
revoke all on function public.apply_stripe_billing_event_v94_base(text) from public, anon, authenticated;

-- =============================================================================================
-- 5 · The identity holds, and the live firm did not lose its evidence.
-- =============================================================================================
do $v986_verify$
declare v_bad integer; v_src text;
begin
  select count(*) into v_bad from public.billing_provider_invoices
   where total_cents <> subtotal_ex_tax_cents - discount_cents + tax_cents;
  if v_bad <> 0 then
    raise exception 'v986: % invoices violate the new identity', v_bad;
  end if;

  /* The one live Stripe payer must still read as paid AFTER the rule changes. A fix that quietly
     revokes an existing firm's payment evidence would be worse than the bug. */
  select initial_payment_source into v_src from public.subscriptions
   where provider_subscription_id = 'sub_1UCaf5LjvwAsL93HgquLMyLC';
  perform app.v510_sync_payment_readiness(
    (select business_id from public.subscriptions
      where provider_subscription_id = 'sub_1UCaf5LjvwAsL93HgquLMyLC'), null);
  if (select status from public.subscriptions
       where provider_subscription_id = 'sub_1UCaf5LjvwAsL93HgquLMyLC') <> 'active' then
    raise exception 'v986: the live Stripe subscription stopped reading as active under the new rule';
  end if;
end
$v986_verify$;

commit;
