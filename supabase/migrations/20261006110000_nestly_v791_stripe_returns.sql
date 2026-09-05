-- nestly_v791 — Stripe is the platform billing provider again, and it knows about branches (2026-09-06).
--
-- OWNER DECISION (2026-09-06): "the otp issue apparently is throughout whole razorpay … i am going
-- to change back to stripe." Razorpay's card-tokenisation OTP never arrived, on any phone or card,
-- and the same block hit the Razorpay dashboard itself. The Stripe account, product, prices and
-- live webhook from August are all still in place, so the platform returns to them.
--
-- WHAT THIS MIGRATION DOES
--   1. The tier catalogue prices from the LIVE Stripe prices again (the v755 swap had NULLed
--      them): monthly SGD 148 and annual SGD 1,188 on the flat (10,000) rows. The larger tiers
--      keep their amounts but carry no price id, so they cannot be sold (one price, owner ruling
--      2026-09-06). The sandbox column is cleared — Stripe test mode is a separate key pair and is
--      wired through STRIPE_TEST_SECRET_KEY when the owner wants demo firms on it.
--   2. Branch subscriptions on Stripe. app.stripe_branch_v791 reads metadata.branch_id (set by the
--      executor on the subscription and carried by Stripe onto every invoice's
--      subscription_details), and app.apply_stripe_branch_event_v791 writes the same mirrors as
--      the v94 base applier but the BRANCH's own row (branch_subscriptions_v786), switching the
--      branch on when its invoice is paid and off when its subscription ends. The v77 wrapper is
--      patched in place to hand a branch-named event to it before the base applier runs.
--   3. The nightly reconcile call posts to stripe-billing-reconcile again.
--
-- Rollback suite: db/tests/v791_stripe_returns.sql
begin;

-- =============================================================================================
-- 0 · The live bodies this file patches are what it believes they are.
-- =============================================================================================
do $v791_assert$
declare v_body text;
begin
  v_body := pg_get_functiondef('public.apply_stripe_billing_event_v77(text)'::regprocedure);
  if position($n$  v_result:=public.apply_stripe_billing_event_v94_base(p_event_id);$n$ in v_body) = 0 then
    raise exception 'v791: apply_stripe_billing_event_v77 has drifted (base call needle)';
  end if;
  if position('v791' in v_body) > 0 then
    raise exception 'v791: apply_stripe_billing_event_v77 already carries v791';
  end if;
  v_body := pg_get_functiondef('app.run_billing_reconcile_call_v624()'::regprocedure);
  if position($n$'/functions/v1/razorpay-billing-reconcile'$n$ in v_body) = 0 then
    raise exception 'v791: run_billing_reconcile_call_v624 does not point at razorpay-billing-reconcile';
  end if;
end
$v791_assert$;

-- =============================================================================================
-- 1 · The catalogue prices from Stripe.
-- =============================================================================================
update public.billing_capacity_tier_catalog_v664
   set provider = 'stripe',
       provider_test_price_id = null,
       provider_base_price_id = case
         when cadence = 'monthly' and capacity_ceiling = 10000 then 'price_1U0kvALjvwAsL93HYDnObBoy'
         when cadence = 'annual' and capacity_ceiling = 10000 then 'price_1U04dzLjvwAsL93HhVbvCFKz'
         else null end
 where active;

update public.billing_plan_catalog_v124
   set provider = 'stripe'
 where active;

-- =============================================================================================
-- 2 · Which branch a Stripe event names.
-- =============================================================================================
create or replace function app.stripe_branch_v791(p_payload jsonb)
returns uuid
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_object jsonb := p_payload #> '{data,object}';
  v_candidate text;
  v_subscription text;
  v_branch uuid;
begin
  v_candidate := coalesce(
    v_object #>> '{metadata,branch_id}',
    v_object #>> '{subscription_details,metadata,branch_id}',
    v_object #>> '{parent,subscription_details,metadata,branch_id}'
  );
  if v_candidate ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     and exists (select 1 from public.branches b where b.id = v_candidate::uuid and b.billing_mode = 'own') then
    return v_candidate::uuid;
  end if;
  v_subscription := coalesce(
    case when v_object->>'object' = 'subscription' then v_object->>'id' end,
    case when jsonb_typeof(v_object->'subscription') = 'string' then v_object->>'subscription'
         else v_object#>>'{subscription,id}' end,
    v_object#>>'{parent,subscription_details,subscription}'
  );
  if v_subscription is not null then
    select s.branch_id into v_branch from public.branch_subscriptions_v786 s
     where s.provider_subscription_id = v_subscription;
    if found then return v_branch; end if;
  end if;
  return null;
end
$$;
revoke all on function app.stripe_branch_v791(jsonb) from public, anon, authenticated;

-- =============================================================================================
-- 3 · The Stripe branch applier.
-- =============================================================================================
create or replace function app.apply_stripe_branch_event_v791(
  p_event_id text, p_business uuid, p_branch uuid, p_rank smallint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
  v_subtotal integer; v_tax integer; v_total integer; v_due integer; v_paid integer; v_remaining integer;
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
      v_subtotal := greatest(coalesce(nullif(v_object->>'total_excluding_tax','')::integer,nullif(v_object->>'subtotal_excluding_tax','')::integer,nullif(v_object->>'subtotal','')::integer,0),0);
      v_total := greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
      v_tax := greatest(v_total-v_subtotal,0);
      v_due := greatest(coalesce(nullif(v_object->>'amount_due','')::integer,v_total),0);
      v_paid := greatest(coalesce(nullif(v_object->>'amount_paid','')::integer,0),0);
      v_remaining := greatest(coalesce(nullif(v_object->>'amount_remaining','')::integer,v_due-v_paid,0),0);
      v_next_attempt := app.stripe_epoch_v77(v_object->'next_payment_attempt');
      v_paid_at := case when v_event.event_type='invoice.paid'
                        then coalesce(app.stripe_epoch_v77(v_object#>'{status_transitions,paid_at}'),v_event.event_created_at) end;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,provider_payment_intent_id,
        number,currency,collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,
        amount_due_cents,amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,period_start,period_end,
        due_at,next_payment_attempt_at,paid_at,finalized_at,voided_at,marked_uncollectible_at,livemode,
        provider_event_created_at,provider_event_rank,last_event_id,reason,detail
      ) values (
        p_business,v_customer,v_subscription,v_invoice,
        case when jsonb_typeof(v_object->'payment_intent')='string' then v_object->>'payment_intent' else v_object#>>'{payment_intent,id}' end,
        v_object->>'number',upper(coalesce(nullif(v_object->>'currency',''),'SGD')),v_object->>'collection_method',v_status,
        v_event.event_type='invoice.paid',v_subtotal,v_tax,v_total,v_due,v_paid,v_remaining,
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
            tax_cents=excluded.tax_cents,total_cents=excluded.total_cents,amount_due_cents=excluded.amount_due_cents,
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

    -- What this event does to the BRANCH.
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
      /* the owner resumed before the date: back to active, still on */
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
$$;
revoke all on function app.apply_stripe_branch_event_v791(text,uuid,uuid,smallint) from public, anon, authenticated;

-- =============================================================================================
-- 4 · Patches to live bodies.
-- =============================================================================================
do $v791_patch$
declare v_body text; v_new text;
begin
  v_body := pg_get_functiondef('public.apply_stripe_billing_event_v77(text)'::regprocedure);
  v_new := replace(v_body,
    $n$  v_result:=public.apply_stripe_billing_event_v94_base(p_event_id);$n$,
    $n$  /* v791: an event that names a branch belongs to that branch's own subscription. The base
     applier must not see it — it would rewrite the company's subscription row from it. */
  declare
    v_pending_v791 public.billing_provider_events%rowtype;
    v_branch_v791 uuid;
    v_business_v791 uuid;
  begin
    select * into v_pending_v791 from public.billing_provider_events e
     where e.provider='stripe' and e.event_id=p_event_id;
    if v_pending_v791.processing_status not in ('processed','ignored')
       and app.stripe_event_rank_v77(v_pending_v791.event_type) > 0 then
      v_branch_v791 := app.stripe_branch_v791(v_pending_v791.payload);
      if v_branch_v791 is not null then
        v_business_v791 := app.stripe_business_v77(v_pending_v791.payload);
        if v_business_v791 is null then
          select b.business_id into v_business_v791 from public.branches b where b.id = v_branch_v791;
        end if;
        update public.billing_provider_events
           set processing_status='processing',processing_attempts=processing_attempts+1,last_error=null
         where id=v_pending_v791.id;
        return app.apply_stripe_branch_event_v791(p_event_id, v_business_v791, v_branch_v791,
                                                  app.stripe_event_rank_v77(v_pending_v791.event_type));
      end if;
    end if;
  end;
  v_result:=public.apply_stripe_billing_event_v94_base(p_event_id);$n$);
  if v_new = v_body then raise exception 'v791: v77 wrapper patch did not apply'; end if;
  execute v_new;

  v_body := pg_get_functiondef('app.run_billing_reconcile_call_v624()'::regprocedure);
  v_new := replace(v_body, $n$'/functions/v1/razorpay-billing-reconcile'$n$, $n$'/functions/v1/stripe-billing-reconcile'$n$);
  if v_new = v_body then raise exception 'v791: reconcile call patch did not apply'; end if;
  execute v_new;
end
$v791_patch$;

commit;
