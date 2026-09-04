-- nestly_v755 — Razorpay replaces Stripe as the platform billing provider (2026-09-04).
--
-- OWNER DECISION (2026-09-04): platform billing moves to Razorpay Subscriptions (SG, recurring
-- auto-charge), and Stripe Connect / PayNow POS is removed because Razorpay SG has no equivalent.
-- Test mode first. Nothing here deletes Stripe history: every mirrored Stripe row, event and
-- invoice stays exactly where it is and stays readable. What changes is that the provider columns
-- stop asserting "stripe is the only provider that has ever existed".
--
-- WHAT THIS MIGRATION DOES
--   1. Relaxes every `check (provider = 'stripe')` to `provider in ('stripe','razorpay')`, and
--      `subscriptions.billing_provider` to accept 'razorpay'. Stripe rows are untouched.
--   2. Frees the two catalogue tables to hold Razorpay `plan_...` ids in their provider-neutral
--      price-id columns (the regex only ever allowed `price_...`), drops the NOT NULLs that made
--      "no plan configured yet" unrepresentable, and NULLs the live Stripe `price_1...` ids —
--      they address objects in a Stripe account this product no longer bills through, so leaving
--      them in place would let a checkout be built from a price that cannot be charged.
--   3. public.ingest_billing_event_v755 — the durable inbox, provider-parameterised. Same
--      semantics as ingest_stripe_billing_event_v77 (conflict on (provider,event_id) do nothing,
--      same returned shape, same envelope-conflict refusal), service_role only.
--   4. app.razorpay_event_rank_v755 — the out-of-order ordering key, ranked so that a late
--      `activated` can never overwrite a `cancelled`, and 0 (=> 'ignored') for everything Peekaa
--      does not act on.
--   5. public.apply_razorpay_billing_event_v755 — the Razorpay port of
--      apply_stripe_billing_event_v94_base plus the v94 (workspace recovery) and v621 (paid
--      branch activation) layers that wrap it. Their call sites are copied verbatim from
--      db/migrations/20260830_nestly_v621_branch_payment_truth.sql; only the evidence string
--      names the new provider.
--   6. app.razorpay_plan_cadence_v755 — plan id -> (cadence, cadence_months) from the two
--      catalogues, so a `subscription.charged` can set the tenant cadence without the client.
--   7. public.platform_set_provider_plan_id_v755 — super-admin-only, audited recording of a live
--      Razorpay plan id onto a catalogue row, so going live does not need another migration.
--   8. Every reader that hardcoded `billing_provider='stripe'` to mean "the provider collects
--      automatically" now accepts 'razorpay' as well, and the reconcile cron calls
--      razorpay-billing-reconcile. Both are done by reading the LIVE function body and replacing
--      a needle with an asserted count (the v174/v664 idiom), so a body that has drifted fails
--      this migration instead of being silently retyped from an out-of-date copy.
--
-- NOT DONE HERE, deliberately: no Stripe function is dropped. apply_stripe_billing_event_v77 and
-- its inbox stay callable so historical events can still be replayed and reconciled.
--
-- Rollback suite: db/tests/v755_razorpay_billing.sql
begin;

-- =============================================================================================
-- 1 · The provider columns stop meaning "stripe".
-- =============================================================================================
alter table public.subscriptions
  drop constraint if exists subscriptions_billing_provider_check;
alter table public.subscriptions
  add constraint subscriptions_billing_provider_check
  check (billing_provider in ('manual','stripe','razorpay'));

do $v755_provider_checks$
declare
  v_table text;
  v_constraint text;
  v_relaxed integer := 0;
begin
  foreach v_table in array array[
    'public.billing_price_catalog',
    'public.billing_provider_customers',
    'public.billing_provider_events',
    'public.billing_reconciliation_runs',
    'public.billing_plan_catalog_v124',
    'public.billing_capacity_tier_catalog_v664'
  ]
  loop
    for v_constraint in
      select constraint_row.conname
        from pg_catalog.pg_constraint constraint_row
       where constraint_row.contype = 'c'
         and constraint_row.conrelid = v_table::regclass
         and pg_catalog.pg_get_constraintdef(constraint_row.oid) like '%provider%'
         and pg_catalog.pg_get_constraintdef(constraint_row.oid) like '%''stripe''%'
    loop
      execute format('alter table %s drop constraint %I', v_table, v_constraint);
      v_relaxed := v_relaxed + 1;
    end loop;
    execute format(
      'alter table %s add constraint %I check (provider in (''stripe'',''razorpay''))',
      v_table, replace(split_part(v_table,'.',2),'"','')||'_provider_check_v755'
    );
  end loop;
  if v_relaxed <> 6 then
    raise exception 'v755 expected exactly 6 stripe-only provider checks, relaxed %', v_relaxed;
  end if;
end
$v755_provider_checks$;

-- =============================================================================================
-- 2 · The catalogues can hold a Razorpay plan id, or hold nothing yet.
--     `provider_base_price_id` / `provider_capacity_price_id` are provider-neutral column names
--     that happened to carry a Stripe-only regex. v664 already taught every charging path to
--     refuse a NULL price id with a named error, so NULL is the correct "not configured yet"
--     state and no path silently falls back to a cheaper price.
-- =============================================================================================
do $v755_price_id_shape$
declare
  v_table text;
  v_constraint text;
  v_dropped integer := 0;
begin
  foreach v_table in array array[
    'public.billing_plan_catalog_v124',
    'public.billing_capacity_tier_catalog_v664'
  ]
  loop
    for v_constraint in
      select constraint_row.conname
        from pg_catalog.pg_constraint constraint_row
       where constraint_row.contype = 'c'
         and constraint_row.conrelid = v_table::regclass
         and pg_catalog.pg_get_constraintdef(constraint_row.oid) like '%^price\_%'
    loop
      execute format('alter table %s drop constraint %I', v_table, v_constraint);
      v_dropped := v_dropped + 1;
    end loop;
  end loop;
  if v_dropped < 3 then
    raise exception 'v755 expected at least 3 price-id regex checks, dropped %', v_dropped;
  end if;
end
$v755_price_id_shape$;

alter table public.billing_plan_catalog_v124
  alter column provider_base_price_id drop not null,
  alter column provider_capacity_price_id drop not null;

alter table public.billing_plan_catalog_v124
  add constraint billing_plan_catalog_v124_base_price_shape_v755 check (
    provider_base_price_id is null
    or provider_base_price_id ~ '^(price|plan)_[A-Za-z0-9_]+$'
  ),
  add constraint billing_plan_catalog_v124_capacity_price_shape_v755 check (
    provider_capacity_price_id is null
    or provider_capacity_price_id ~ '^(price|plan)_[A-Za-z0-9_]+$'
  );

alter table public.billing_capacity_tier_catalog_v664
  add constraint billing_capacity_tier_catalog_v664_price_shape_v755 check (
    provider_base_price_id is null
    or provider_base_price_id ~ '^(price|plan)_[A-Za-z0-9_]+$'
  );

/* The Stripe price ids are retired, not archived here: billing_subscription_terms_v124 and
   billing_commands already snapshot the price a tenant was actually sold, so the audit trail
   does not live in the catalogue row. */
update public.billing_plan_catalog_v124
   set provider_base_price_id = null,
       provider_capacity_price_id = null
 where provider_base_price_id like 'price\_%'
    or provider_capacity_price_id like 'price\_%';

update public.billing_capacity_tier_catalog_v664
   set provider_base_price_id = null
 where provider_base_price_id like 'price\_%';

-- =============================================================================================
-- 3 · The durable inbox, provider-parameterised.
-- =============================================================================================
create or replace function public.ingest_billing_event_v755(
  p_provider text,
  p_event_id text,
  p_event_type text,
  p_object_id text,
  p_event_created_at timestamptz,
  p_livemode boolean,
  p_payload jsonb,
  p_payload_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_existing public.billing_provider_events%rowtype;
  v_inserted uuid;
begin
  if p_provider not in ('stripe','razorpay')
     or (p_provider = 'stripe' and p_event_id !~ '^evt_[A-Za-z0-9_]+$')
     or (p_provider = 'razorpay' and p_event_id !~ '^[A-Za-z0-9_\-]{6,}$')
     or nullif(btrim(p_event_type),'') is null
     or nullif(btrim(p_object_id),'') is null
     or p_event_created_at is null
     or p_livemode is null
     or jsonb_typeof(p_payload) <> 'object'
     or p_payload_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid billing event envelope' using errcode = '22023';
  end if;

  insert into public.billing_provider_events(
    provider,event_id,event_type,object_id,event_created_at,livemode,api_version,
    payload,payload_sha256
  ) values (
    p_provider,p_event_id,p_event_type,p_object_id,p_event_created_at,p_livemode,
    nullif(p_payload->>'api_version',''),p_payload,p_payload_sha256
  )
  on conflict(provider,event_id) do nothing
  returning id into v_inserted;

  if v_inserted is not null then
    return jsonb_build_object('event_id',p_event_id,'status','accepted','duplicate',false);
  end if;

  select * into strict v_existing
    from public.billing_provider_events
   where provider = p_provider and event_id = p_event_id;
  if v_existing.event_type <> p_event_type
     or v_existing.object_id <> p_object_id
     or v_existing.event_created_at <> p_event_created_at
     or v_existing.livemode <> p_livemode
     or v_existing.payload <> p_payload
     or v_existing.payload_sha256 <> p_payload_sha256 then
    raise exception 'billing event id conflicts with a different envelope'
      using errcode = '22023';
  end if;
  return jsonb_build_object(
    'event_id',p_event_id,'status',v_existing.processing_status,'duplicate',true
  );
end
$$;
revoke all on function public.ingest_billing_event_v755(
  text,text,text,text,timestamptz,boolean,jsonb,text
) from public,anon,authenticated;
grant execute on function public.ingest_billing_event_v755(
  text,text,text,text,timestamptz,boolean,jsonb,text
) to service_role;

-- =============================================================================================
-- 4 · Razorpay helpers.
-- =============================================================================================
create or replace function app.razorpay_epoch_v755(p_value jsonb)
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) <> 'number' then null
    when (p_value #>> '{}')::numeric <= 0 then null
    else to_timestamp((p_value #>> '{}')::double precision)
  end
$$;
revoke all on function app.razorpay_epoch_v755(jsonb) from public,anon,authenticated;

/* Rank orders the inbox, it does not judge importance: a lower rank arriving later than a higher
   one for the same second is REJECTED, so `cancelled` (90) can never be undone by a late
   `activated` (30). 0 means Peekaa does not act on the event and it is marked 'ignored'. */
create or replace function app.razorpay_event_rank_v755(p_event text)
returns smallint
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_event
    when 'subscription.authenticated' then 20
    when 'subscription.updated' then 30
    when 'subscription.activated' then 30
    when 'subscription.resumed' then 30
    when 'subscription.pending' then 40
    when 'subscription.halted' then 45
    when 'subscription.paused' then 50
    when 'subscription.cancelled' then 90
    when 'subscription.completed' then 90
    when 'subscription.charged' then 100
    when 'refund.created' then 110
    else 0
  end::smallint
$$;
revoke all on function app.razorpay_event_rank_v755(text) from public,anon,authenticated;

create or replace function app.razorpay_status_v755(p_status text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_status
    when 'created' then 'incomplete'
    when 'authenticated' then 'active'
    when 'active' then 'active'
    when 'pending' then 'past_due'
    when 'halted' then 'unpaid'
    when 'paused' then 'paused'
    when 'cancelled' then 'canceled'
    when 'completed' then 'canceled'
    when 'expired' then 'incomplete_expired'
    else 'incomplete'
  end
$$;
revoke all on function app.razorpay_status_v755(text) from public,anon,authenticated;

/* Cadence is a property of the PLAN, and the plan id is the only cadence signal a Razorpay
   subscription payload carries. Both catalogues are consulted because a tenant's base plan is a
   capacity tier (v664) while the legacy v124 rows still describe the same two cadences. */
create or replace function app.razorpay_plan_cadence_v755(p_plan_id text)
returns table(cadence text, cadence_months integer)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select found_row.cadence, found_row.cadence_months::integer
    from (
      select tier.cadence, tier.cadence_months, tier.effective_from, 1 as source_rank
        from public.billing_capacity_tier_catalog_v664 tier
       where p_plan_id is not null and tier.provider_base_price_id = p_plan_id
      union all
      select catalog.cadence, catalog.cadence_months, catalog.effective_from, 2 as source_rank
        from public.billing_plan_catalog_v124 catalog
       where p_plan_id is not null
         and p_plan_id in (catalog.provider_base_price_id,catalog.provider_capacity_price_id)
    ) found_row
   order by found_row.source_rank, found_row.effective_from desc
   limit 1
$$;
revoke all on function app.razorpay_plan_cadence_v755(text) from public,anon,authenticated;

/* Business identity, most-trusted source first. `notes` is the only field Peekaa controls on a
   Razorpay object, so it is the primary; the mirrors are the fallback for an object created
   before the notes convention, or for a refund that carries no notes at all. */
create or replace function app.razorpay_business_v755(p_payload jsonb)
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_subscription jsonb := p_payload #> '{payload,subscription,entity}';
  v_payment jsonb := p_payload #> '{payload,payment,entity}';
  v_refund jsonb := p_payload #> '{payload,refund,entity}';
  v_candidate text;
  v_subscription_id text;
  v_business uuid;
begin
  v_candidate := coalesce(
    v_subscription #>> '{notes,business_id}',
    v_payment #>> '{notes,business_id}'
  );
  if v_candidate ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     and exists (select 1 from public.businesses where id = v_candidate::uuid) then
    return v_candidate::uuid;
  end if;

  v_subscription_id := coalesce(
    v_subscription ->> 'id',
    v_payment ->> 'subscription_id'
  );
  if v_subscription_id is not null then
    select tenant.business_id into v_business
      from public.subscriptions tenant
     where tenant.billing_provider = 'razorpay'
       and tenant.provider_subscription_id = v_subscription_id;
    if found then return v_business; end if;
    select mirror.business_id into v_business
      from public.billing_provider_subscriptions mirror
     where mirror.provider_subscription_id = v_subscription_id;
    if found then return v_business; end if;
  end if;

  if v_refund is not null then
    select invoice_row.business_id into v_business
      from public.billing_provider_invoices invoice_row
     where invoice_row.provider_payment_intent_id = v_refund ->> 'payment_id'
     order by invoice_row.paid_at desc nulls last
     limit 1;
    if found then return v_business; end if;
  end if;

  if v_payment is not null then
    select invoice_row.business_id into v_business
      from public.billing_provider_invoices invoice_row
     where invoice_row.provider_payment_intent_id = v_payment ->> 'id'
     order by invoice_row.paid_at desc nulls last
     limit 1;
    if found then return v_business; end if;
  end if;

  return null;
end
$$;
revoke all on function app.razorpay_business_v755(jsonb) from public,anon,authenticated;

-- =============================================================================================
-- 5 · The applier. Structure, failure handling and out-of-order rejection are
--     apply_stripe_billing_event_v94_base's; the field reads are Razorpay's.
-- =============================================================================================
create or replace function public.apply_razorpay_billing_event_v755(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_event public.billing_provider_events%rowtype;
  v_subscription jsonb;
  v_payment jsonb;
  v_refund jsonb;
  v_business uuid;
  v_rank smallint;
  v_customer text;
  v_subscription_id text;
  v_plan text;
  v_quantity integer;
  v_status text;
  v_cadence text;
  v_cadence_months integer;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_charge_at timestamptz;
  v_cancel_at_period_end boolean;
  v_invoice text;
  v_amount integer;
  v_currency text;
  v_paid_at timestamptz;
  v_attempt_state text;
  v_adjustment_total integer;
  v_adjustment_tax integer;
  v_adjustment_net integer;
  v_adjustment_invoice public.billing_provider_invoices%rowtype;
  v_result jsonb;
  v_paid boolean := false;
begin
  select * into v_event
    from public.billing_provider_events
   where provider = 'razorpay' and event_id = p_event_id
   for update;
  if not found then
    raise exception 'Razorpay event is not in the durable inbox' using errcode = '22023';
  end if;
  if v_event.processing_status in ('processed','ignored') then
    v_result := jsonb_build_object(
      'event_id',p_event_id,'status',v_event.processing_status,'duplicate',true
    );
    /* v621: activation converges on the covered count, so a replay is harmless and free
       recovery. Copied from the v621 wrapper's duplicate branch. */
    if v_event.event_type = 'subscription.charged' and v_event.business_id is not null then
      v_result := v_result || jsonb_build_object(
        'subscription_lifecycle',
        app.reconcile_subscription_payment_v94(
          v_event.business_id,
          'razorpay-charged:'||p_event_id,
          'Razorpay subscription.charged recovered the subscription workspace',
          null,false
        ),
        'branch_activation',
        app.activate_pending_branches_on_paid_v621(
          v_event.business_id,'razorpay-charged:'||p_event_id
        )
      );
    end if;
    return v_result;
  end if;

  update public.billing_provider_events
     set processing_status = 'processing',
         processing_attempts = processing_attempts + 1,
         last_error = null
   where id = v_event.id;

  begin
    v_subscription := v_event.payload #> '{payload,subscription,entity}';
    v_payment := v_event.payload #> '{payload,payment,entity}';
    v_refund := v_event.payload #> '{payload,refund,entity}';
    v_rank := app.razorpay_event_rank_v755(v_event.event_type);
    if v_rank = 0 then
      update public.billing_provider_events
         set processing_status='ignored',processed_at=now()
       where id=v_event.id;
      return jsonb_build_object('event_id',p_event_id,'status','ignored');
    end if;

    v_business := app.razorpay_business_v755(v_event.payload);
    if v_business is null then
      raise exception 'Razorpay event cannot be mapped to a business';
    end if;

    -- ---------------------------------------------------------------------------------------
    -- 5a. The subscription mirror. Every ranked event except refund.created carries one.
    -- ---------------------------------------------------------------------------------------
    if jsonb_typeof(v_subscription) = 'object' then
      v_subscription_id := v_subscription ->> 'id';
      v_customer := v_subscription ->> 'customer_id';
      v_plan := v_subscription ->> 'plan_id';
      v_quantity := greatest(coalesce((v_subscription->>'quantity')::integer,1),0);
      v_status := app.razorpay_status_v755(v_subscription->>'status');
      v_period_start := app.razorpay_epoch_v755(v_subscription->'current_start');
      v_period_end := app.razorpay_epoch_v755(v_subscription->'current_end');
      v_charge_at := app.razorpay_epoch_v755(v_subscription->'charge_at');
      /* Razorpay has no cancel_at_period_end flag. A subscription cancelled at cycle end sits in
         status 'cancelled' with no ended_at and a current_end still in the future; a change
         Razorpay has queued for the cycle end shows as has_scheduled_changes. */
      v_cancel_at_period_end := (
        v_subscription->>'status' = 'cancelled'
        and app.razorpay_epoch_v755(v_subscription->'ended_at') is null
        and v_period_end is not null and v_period_end > now()
      ) or coalesce((v_subscription->>'has_scheduled_changes')::boolean,false);
      select plan.cadence, plan.cadence_months
        into v_cadence, v_cadence_months
        from app.razorpay_plan_cadence_v755(v_plan) plan;

      if exists(
        select 1 from public.billing_provider_subscriptions mirror
         where mirror.provider_subscription_id = v_subscription_id
           and mirror.business_id <> v_business
      ) then
        raise exception 'Razorpay subscription is already linked to another business';
      end if;

      if v_customer is not null then
        if exists(
          select 1 from public.billing_provider_customers customer
           where (customer.provider_customer_id=v_customer
                  and customer.business_id<>v_business)
              or (customer.business_id=v_business
                  and customer.provider_customer_id<>v_customer)
        ) then
          raise exception 'Razorpay customer is already linked to another business';
        end if;
        insert into public.billing_provider_customers(
          business_id,provider,provider_customer_id,currency,livemode,provider_created_at,
          provider_event_created_at,provider_event_rank,last_event_id
        ) values (
          v_business,'razorpay',v_customer,'SGD',v_event.livemode,
          app.razorpay_epoch_v755(v_subscription->'created_at'),
          v_event.event_created_at,v_rank,v_event.event_id
        )
        on conflict(provider_customer_id) do update
          set currency=coalesce(excluded.currency,billing_provider_customers.currency),
              provider=excluded.provider,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
        where (excluded.provider_event_created_at,excluded.provider_event_rank)
              >= (billing_provider_customers.provider_event_created_at,
                  billing_provider_customers.provider_event_rank);
      end if;

      insert into public.billing_provider_subscriptions(
        business_id,provider_customer_id,provider_subscription_id,status,
        cadence,cadence_months,currency,current_period_start,current_period_end,
        billing_cycle_anchor,trial_end,cancel_at_period_end,canceled_at,ended_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,coalesce(v_customer,v_subscription_id),v_subscription_id,v_status,
        v_cadence,v_cadence_months,'SGD',v_period_start,v_period_end,
        app.razorpay_epoch_v755(v_subscription->'start_at'),null,
        v_cancel_at_period_end,
        case when v_subscription->>'status'='cancelled' then v_event.event_created_at end,
        app.razorpay_epoch_v755(v_subscription->'ended_at'),
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_subscription_id) do update
        set status=excluded.status,cadence=excluded.cadence,
            cadence_months=excluded.cadence_months,currency=excluded.currency,
            current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,
            billing_cycle_anchor=excluded.billing_cycle_anchor,
            cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_subscriptions.provider_event_created_at,
                billing_provider_subscriptions.provider_event_rank);

      /* A Razorpay subscription is ONE plan at a quantity — there is no item collection, so the
         mirror carries exactly one row and its provider_item_id is the subscription id. v621
         reads this row's quantity as the paid unit count. */
      if v_plan is not null then
        insert into public.billing_provider_subscription_items(
          provider_subscription_id,provider_item_id,item_role,provider_price_id,
          quantity,unit_amount_cents,currency,interval_name,interval_count,
          current_period_start,current_period_end,provider_event_created_at,
          provider_event_rank,last_event_id
        ) values (
          v_subscription_id,v_subscription_id,
          coalesce(nullif(app.stripe_item_role_v664(v_plan),'other'),'base'),
          v_plan,v_quantity,null,'SGD',
          case when v_cadence_months = 12 then 'year' else 'month' end,
          case when v_cadence_months = 12 then 1 else coalesce(v_cadence_months,1) end,
          v_period_start,v_period_end,v_event.event_created_at,v_rank,v_event.event_id
        )
        on conflict(provider_item_id) do update
          set item_role=excluded.item_role,provider_price_id=excluded.provider_price_id,
              quantity=excluded.quantity,currency=excluded.currency,
              interval_name=excluded.interval_name,interval_count=excluded.interval_count,
              current_period_start=excluded.current_period_start,
              current_period_end=excluded.current_period_end,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
        where (excluded.provider_event_created_at,excluded.provider_event_rank)
              >= (billing_provider_subscription_items.provider_event_created_at,
                  billing_provider_subscription_items.provider_event_rank);
      end if;

      update public.subscriptions tenant_subscription
         set billing_provider='razorpay',provider_customer_id=v_customer,
             provider_subscription_id=v_subscription_id,status=v_status,
             billing_cadence=coalesce(v_cadence,tenant_subscription.billing_cadence),
             cadence_months=coalesce(v_cadence_months,tenant_subscription.cadence_months),
             current_period_start=coalesce(v_period_start,current_period_start),
             current_period_end=coalesce(v_period_end,current_period_end),
             next_payment_at=coalesce(v_charge_at,v_period_end,next_payment_at),
             cancel_at_period_end=v_cancel_at_period_end,
             canceled_at=case when v_subscription->>'status'='cancelled'
                              then v_event.event_created_at else canceled_at end,
             provider_base_item_id=v_subscription_id,
             provider_base_price_id=v_plan,
             provider_seat_quantity=v_quantity,
             provider_event_created_at=v_event.event_created_at,
             provider_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.provider_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.provider_event_created_at,
                     tenant_subscription.provider_event_rank));
    end if;

    -- ---------------------------------------------------------------------------------------
    -- 5b. subscription.charged is the paid truth. Razorpay bills a subscription cycle with a
    --     payment, not an invoice document, so the payment IS the invoice here.
    -- ---------------------------------------------------------------------------------------
    if v_event.event_type = 'subscription.charged'
       and jsonb_typeof(v_payment) = 'object' then
      v_invoice := coalesce(nullif(v_payment->>'invoice_id',''),v_payment->>'id');
      v_amount := greatest(coalesce((v_payment->>'amount')::integer,0),0);
      v_currency := upper(coalesce(nullif(v_payment->>'currency',''),'SGD'));
      v_paid_at := coalesce(
        app.razorpay_epoch_v755(v_payment->'created_at'),v_event.event_created_at
      );
      if exists(
        select 1 from public.billing_provider_invoices invoice_row
         where invoice_row.provider_invoice_id=v_invoice
           and invoice_row.business_id<>v_business
      ) then
        raise exception 'Razorpay payment is already linked to another business';
      end if;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,
        provider_invoice_id,provider_payment_intent_id,number,currency,
        collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,
        total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,
        net_cash_ex_tax_cents,period_start,period_end,paid_at,finalized_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,coalesce(v_customer,v_subscription_id),v_subscription_id,
        v_invoice,v_payment->>'id',v_invoice,v_currency,
        'charge_automatically','paid',true,v_amount,0,
        v_amount,v_amount,v_amount,0,
        v_amount,v_period_start,v_period_end,v_paid_at,v_paid_at,
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_invoice_id) do update
        set provider_payment_intent_id=coalesce(
              excluded.provider_payment_intent_id,
              billing_provider_invoices.provider_payment_intent_id
            ),
            number=coalesce(excluded.number,billing_provider_invoices.number),
            status=excluded.status,paid_normalized=excluded.paid_normalized,
            subtotal_ex_tax_cents=excluded.subtotal_ex_tax_cents,
            tax_cents=excluded.tax_cents,total_cents=excluded.total_cents,
            amount_due_cents=excluded.amount_due_cents,
            amount_paid_cents=excluded.amount_paid_cents,
            amount_remaining_cents=excluded.amount_remaining_cents,
            net_cash_ex_tax_cents=excluded.net_cash_ex_tax_cents,
            period_start=excluded.period_start,period_end=excluded.period_end,
            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_invoices.provider_event_created_at,
                billing_provider_invoices.provider_event_rank);

      insert into public.billing_payment_attempts(
        business_id,provider_invoice_id,source_event_id,provider_payment_intent_id,
        provider_charge_id,attempt_state,amount_cents,tax_cents,occurred_at,
        collection_method
      ) values (
        v_business,v_invoice,v_event.event_id,v_payment->>'id',v_payment->>'id',
        'paid',v_amount,0,v_event.event_created_at,'charge_automatically'
      ) on conflict(source_event_id) do nothing;

      update public.subscriptions tenant_subscription
         set payment_status='paid',
             period_subtotal_cents=v_amount,period_tax_cents=0,
             period_total_cents=v_amount,
             last_paid_at=v_paid_at,last_paid_invoice_id=v_invoice,
             payment_event_created_at=v_event.event_created_at,
             payment_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.payment_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.payment_event_created_at,
                     tenant_subscription.payment_event_rank));
      v_paid := true;
    end if;

    -- ---------------------------------------------------------------------------------------
    -- 5c. pending / halted are the dunning signals. Razorpay's payment.failed carries no
    --     subscription link, so the subscription-level events are the only usable failure truth.
    -- ---------------------------------------------------------------------------------------
    if v_event.event_type in ('subscription.pending','subscription.halted') then
      v_attempt_state := 'failed';
      select invoice_row.* into v_adjustment_invoice
        from public.billing_provider_invoices invoice_row
       where invoice_row.provider_subscription_id=v_subscription_id
       order by invoice_row.period_end desc nulls last
       limit 1;
      if v_adjustment_invoice.provider_invoice_id is not null then
        insert into public.billing_payment_attempts(
          business_id,provider_invoice_id,source_event_id,attempt_state,
          amount_cents,tax_cents,failure_code,failure_message,next_attempt_at,
          occurred_at,collection_method
        ) values (
          v_business,v_adjustment_invoice.provider_invoice_id,v_event.event_id,
          v_attempt_state,v_adjustment_invoice.total_cents,0,
          v_event.event_type,
          left('Razorpay reported '||v_event.event_type,1000),
          v_charge_at,v_event.event_created_at,'charge_automatically'
        ) on conflict(source_event_id) do nothing;
      end if;
      update public.subscriptions tenant_subscription
         set payment_status='failed',
             next_payment_at=coalesce(v_charge_at,next_payment_at),
             payment_event_created_at=v_event.event_created_at,
             payment_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.payment_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.payment_event_created_at,
                     tenant_subscription.payment_event_rank));
      v_adjustment_invoice := null;
    end if;

    -- ---------------------------------------------------------------------------------------
    -- 5d. refund.created is a negative adjustment against the payment it refunds.
    -- ---------------------------------------------------------------------------------------
    if v_event.event_type = 'refund.created' then
      select invoice_row.* into v_adjustment_invoice
        from public.billing_provider_invoices invoice_row
       where invoice_row.provider_payment_intent_id = v_refund ->> 'payment_id'
       order by invoice_row.paid_at desc nulls last
       limit 1;
      v_adjustment_total := -greatest(coalesce((v_refund->>'amount')::integer,0),0);
      if v_adjustment_invoice.id is null or v_adjustment_total = 0 then
        raise exception 'refund cannot be mapped to a paid Razorpay payment';
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
        'refund',
        v_adjustment_net,v_adjustment_tax,v_adjustment_total,
        v_adjustment_invoice.currency,v_event.event_id,v_refund->>'id',
        'Razorpay refund event',
        v_event.payload_sha256,v_event.event_created_at
      ) on conflict(source_event_id) do nothing;
    end if;

    insert into public.billing_evidence(
      business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference
    ) values (
      v_business,'provider_event','razorpay_event',v_event.event_id,
      v_event.payload_sha256,v_event.object_id
    ) on conflict do nothing;

    update public.billing_provider_events
       set processing_status='processed',business_id=v_business,
           processed_at=now(),last_error=null
     where id=v_event.id;
    v_result := jsonb_build_object(
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

  /* v94 + v621, spliced in at the same place and with the same arguments the Stripe invoice.paid
     path uses (db/migrations/20260830_nestly_v621_branch_payment_truth.sql). subscription.charged
     is Razorpay's invoice.paid. */
  if v_paid then
    v_result := v_result || jsonb_build_object(
      'subscription_lifecycle',
      app.reconcile_subscription_payment_v94(
        v_business,
        'razorpay-charged:'||p_event_id,
        'Razorpay subscription.charged recovered the subscription workspace',
        null,false
      ),
      'branch_activation',
      app.activate_pending_branches_on_paid_v621(
        v_business,'razorpay-charged:'||p_event_id
      )
    );
  end if;
  return v_result;
end
$$;
revoke all on function public.apply_razorpay_billing_event_v755(text)
  from public,anon,authenticated;
grant execute on function public.apply_razorpay_billing_event_v755(text)
  to service_role;

-- =============================================================================================
-- 6 · Recording a live plan id without a migration. Super admin only, audited.
-- =============================================================================================
create or replace function public.platform_set_provider_plan_id_v755(
  p_table text,
  p_row_key jsonb,
  p_plan_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row_id uuid;
  v_before text;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_table not in ('billing_plan_catalog_v124','billing_capacity_tier_catalog_v664')
     or jsonb_typeof(p_row_key) <> 'object' then
    raise exception 'unknown provider plan catalogue' using errcode='22023';
  end if;
  if p_plan_id is not null and p_plan_id !~ '^plan_[A-Za-z0-9_]+$' then
    raise exception 'a Razorpay plan id looks like plan_XXXXXXXXXXXXXX' using errcode='22023';
  end if;

  if p_table = 'billing_capacity_tier_catalog_v664' then
    if p_row_key->>'cadence' is null or p_row_key->>'capacity_ceiling' is null then
      raise exception 'cadence and capacity_ceiling identify a tier' using errcode='22023';
    end if;
    select tier.id, tier.provider_base_price_id into v_row_id, v_before
      from public.billing_capacity_tier_catalog_v664 tier
     where tier.cadence = p_row_key->>'cadence'
       and tier.capacity_ceiling = (p_row_key->>'capacity_ceiling')::integer
       and tier.currency = coalesce(p_row_key->>'currency','SGD')
       and tier.active and tier.effective_from <= now()
       and (tier.effective_to is null or tier.effective_to > now())
     order by tier.effective_from desc limit 1;
    if v_row_id is null then
      raise exception 'no active capacity tier matches that key' using errcode='22023';
    end if;
    update public.billing_capacity_tier_catalog_v664
       set provider_base_price_id = p_plan_id
     where id = v_row_id;
  else
    if p_row_key->>'cadence' is null
       or coalesce(p_row_key->>'column','provider_base_price_id')
          not in ('provider_base_price_id','provider_capacity_price_id') then
      raise exception 'cadence and a plan-id column identify a catalogue row'
        using errcode='22023';
    end if;
    select catalog.id into v_row_id
      from public.billing_plan_catalog_v124 catalog
     where catalog.cadence = p_row_key->>'cadence'
       and catalog.currency = coalesce(p_row_key->>'currency','SGD')
       and catalog.active and catalog.effective_from <= now()
       and (catalog.effective_to is null or catalog.effective_to > now())
     order by catalog.effective_from desc limit 1;
    if v_row_id is null then
      raise exception 'no active plan catalogue row matches that key' using errcode='22023';
    end if;
    if coalesce(p_row_key->>'column','provider_base_price_id') = 'provider_base_price_id' then
      select provider_base_price_id into v_before
        from public.billing_plan_catalog_v124 where id = v_row_id;
      update public.billing_plan_catalog_v124
         set provider_base_price_id = p_plan_id where id = v_row_id;
    else
      select provider_capacity_price_id into v_before
        from public.billing_plan_catalog_v124 where id = v_row_id;
      update public.billing_plan_catalog_v124
         set provider_capacity_price_id = p_plan_id where id = v_row_id;
    end if;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    null,v_actor,'PROVIDER_PLAN_ID_SET_V755',p_table,v_row_id,
    jsonb_build_object(
      'row_key',p_row_key,'plan_id',p_plan_id,'previous',v_before,'provider','razorpay'
    )
  );
  return jsonb_build_object(
    'table',p_table,'row_id',v_row_id,'plan_id',p_plan_id,'previous',v_before
  );
end
$$;
revoke all on function public.platform_set_provider_plan_id_v755(text,jsonb,text)
  from public,anon;
grant execute on function public.platform_set_provider_plan_id_v755(text,jsonb,text)
  to authenticated, service_role;

-- =============================================================================================
-- 7 · The readers that said "stripe" when they meant "the provider collects automatically".
--     The live body is read and one needle replaced with an asserted count, so a body that has
--     drifted from this repo fails the migration instead of being silently retyped.
-- =============================================================================================
do $v755_provider_readers$
declare
  v_function record;
  v_definition text;
  v_patched text;
  v_count integer := 0;
begin
  for v_function in
    select proc.oid,
           proc.pronamespace::regnamespace::text||'.'||proc.proname as label
      from pg_catalog.pg_proc proc
     where proc.prokind = 'f'
       and proc.pronamespace::regnamespace::text in ('public','app')
       and proc.prosrc like '%billing_provider%'
       and proc.prosrc ~ 'billing_provider\s*=\s*''stripe'''
     order by 2
  loop
    v_definition := pg_catalog.pg_get_functiondef(v_function.oid);
    v_patched := regexp_replace(
      v_definition,
      'billing_provider\s*=\s*''stripe''',
      'billing_provider in (''stripe'',''razorpay'')',
      'g'
    );
    if v_patched = v_definition then
      raise exception 'v755 could not repoint the provider test in %', v_function.label;
    end if;
    execute v_patched;
    v_count := v_count + 1;
  end loop;
  if v_count < 4 then
    raise exception
      'v755 expected at least 4 stripe-only billing_provider readers, patched %', v_count;
  end if;
  raise notice 'v755 relaxed the provider test in % function(s)', v_count;
end
$v755_provider_readers$;

-- =============================================================================================
-- 8 · The reconcile cron calls the Razorpay reconciler.
-- =============================================================================================
do $v755_reconcile_url$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(proc.oid) into v_definition
    from pg_catalog.pg_proc proc
   where proc.pronamespace::regnamespace::text = 'app'
     and proc.proname = 'run_billing_reconcile_call_v624'
     and proc.pronargs = 0;
  if v_definition is null then
    raise exception 'v755 could not find app.run_billing_reconcile_call_v624';
  end if;
  v_patched := replace(
    v_definition,
    '/functions/v1/stripe-billing-reconcile',
    '/functions/v1/razorpay-billing-reconcile'
  );
  if v_patched = v_definition then
    raise exception
      'v755 found no stripe-billing-reconcile URL in run_billing_reconcile_call_v624';
  end if;
  execute v_patched;
end
$v755_reconcile_url$;
revoke all on function app.run_billing_reconcile_call_v624() from public, anon, authenticated;

commit;
