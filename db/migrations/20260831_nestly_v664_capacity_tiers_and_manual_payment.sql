/* nestly_v664 — customer capacity becomes three fixed tiers, the tier price is charged per
   branch, and a manual payment can finally move the billing dates.

   Owner rulings (2026-08-31 subscription review):
     · "Change customer capacity — to 10k users for $1,188, up to 40k users at $1,688, up to 100k
        $2,499", four fixed tiers with anything above 100,000 handled by Peekaa support. The
        per-1,000 add-on ($120/year, $10/month) is retired: a tier IS the price.
     · "the number of customers is the cumulative of all branches. example all 5 branches total
        customers = 20k, the business will pay 5 X 1,688 = $8,440." The tier is chosen by the
        COMPANY's customer count — public.clients is already business-scoped, so that number is
        cumulative by construction — and the tier amount is then charged once per billable branch,
        exactly as V202/V280 already charge the base plan per branch unit.
     · "If branches are added in between, we just need to prorate accordingly for the remaining
        duration." Already true and left alone: change_branches goes through
        stripePendingUpdateParamsV125, which sets Stripe proration_behavior='always_invoice'.
     · Manual / GIRO payments must update the page. They did not: platform_verify_manual_payment_v156
        marks the tenant paid (via the v510 projections) but NOTHING has ever written
        current_period_end or next_payment_at except the Stripe webhook, so "Billed until" stayed
        blank and app.business_operational_v620 closed the workspace 14 days after a stale period
        end even though the money had arrived. platform_record_subscription_payment_v664 is the
        one audited RPC that records a manual payment against the billing dates.

   Four supporting corrections this could not be built without:

   1. public.billing_price_catalog IS EMPTY in production, and apply_stripe_billing_event_v94_base
      resolved billing_provider_subscription_items.item_role by matching the incoming price id
      against it. Every mirrored item therefore lands as 'other' — never 'base' — which means
      activate_pending_branches_on_paid_v621 returns 'no_base_item' and a PAID BRANCH NEVER
      SWITCHES ON, and subscriptions.provider_base_item_id stays NULL so change_cadence /
      change_capacity can never run. It has never been seen because no Stripe event has ever
      reached production (billing_provider_events = 0 rows). app.stripe_item_role_v664 resolves
      the role from the price catalogues that actually hold rows, and also assigns 'capacity',
      a role the item_role check constraint has always allowed and nothing ever wrote.
   2. project_billing_terms_v124 derived a tenant's capacity as blocks×1000. Under tiers the
      capacity is the tier ceiling of the base price the tenant is actually on.
   3. billing_commands snapshots the tier it was priced from, the same way it already snapshots
      billing_catalog_id_v124 — a price the owner saw must be the price Stripe is asked for.
   4. A tier with no Stripe price id is NOT sellable. The 40k and 100k tiers ship with a NULL
      provider_base_price_id until `npm run stripe:v124:setup` creates them, and every path that
      could charge for one refuses with a named error rather than falling back to a cheaper price.

   Rollback suite: db/tests/v664_capacity_tiers_and_manual_payment.sql */
begin;

-- =============================================================================================
-- 1. The tier catalogue. Same shape of guarantees as billing_plan_catalog_v124 (RLS on, no
--    policies, service_role + postgres only — it is read exclusively through SECURITY DEFINER
--    functions), but keyed by (cadence, capacity_ceiling) so a cadence can carry several tiers.
-- =============================================================================================
create table if not exists public.billing_capacity_tier_catalog_v664(
  id uuid primary key default gen_random_uuid(),
  currency text not null default 'SGD' check (currency = 'SGD'),
  cadence text not null check (cadence in ('monthly','annual')),
  cadence_months smallint not null check (cadence_months in (1,12)),
  provider text not null default 'stripe' check (provider = 'stripe'),
  capacity_ceiling integer not null check (capacity_ceiling > 0 and capacity_ceiling % 1000 = 0),
  amount_cents integer not null check (amount_cents > 0),
  provider_base_price_id text check (provider_base_price_id ~ '^price_[A-Za-z0-9_]+$'),
  tax_behavior text not null default 'exclusive' check (tax_behavior = 'exclusive'),
  sales_assisted_above boolean not null default false,
  active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_at timestamptz not null default now(),
  constraint billing_capacity_tier_catalog_v664_window
    check (effective_to is null or effective_to > effective_from),
  constraint billing_capacity_tier_catalog_v664_cadence_pair
    check ((cadence = 'monthly' and cadence_months = 1)
        or (cadence = 'annual'  and cadence_months = 12)),
  constraint billing_capacity_tier_catalog_v664_unique
    unique (currency, cadence, capacity_ceiling, effective_from)
);
create unique index if not exists billing_capacity_tier_catalog_v664_price_uk
  on public.billing_capacity_tier_catalog_v664(provider_base_price_id)
  where provider_base_price_id is not null;
alter table public.billing_capacity_tier_catalog_v664 enable row level security;
revoke all on table public.billing_capacity_tier_catalog_v664 from public, anon, authenticated;
grant select, insert, update, delete on table public.billing_capacity_tier_catalog_v664 to service_role;

-- Tier 1 reuses the Stripe prices that already exist and already cost 1,188/year and 148/month;
-- what changes is what they BUY (10,000 profiles instead of 1,000). Tiers 2 and 3 carry the
-- owner's annual amounts with no price id yet. Monthly has no tier above 10,000 because no
-- monthly amount was ruled for one — the app says so rather than inventing a number.
insert into public.billing_capacity_tier_catalog_v664
  (cadence, cadence_months, capacity_ceiling, amount_cents, provider_base_price_id, sales_assisted_above)
select v.cadence, v.months, v.ceiling, v.amount, v.price_id, v.sales_assisted
  from (values
    ('annual',  12::smallint, 10000,  118800, 'price_1U04dzLjvwAsL93HhVbvCFKz', false),
    ('annual',  12::smallint, 40000,  168800, null,                             false),
    ('annual',  12::smallint, 100000, 249900, null,                             true),
    ('monthly',  1::smallint, 10000,   14800, 'price_1U0kvALjvwAsL93HYDnObBoy', false)
  ) as v(cadence, months, ceiling, amount, price_id, sales_assisted)
 where not exists (
   select 1 from public.billing_capacity_tier_catalog_v664 existing
    where existing.cadence = v.cadence and existing.capacity_ceiling = v.ceiling
 );

-- =============================================================================================
-- 2. Tier resolution, stated once. The tier a capacity buys is the SMALLEST active ceiling that
--    still covers it; a capacity above every ceiling has no tier and is a sales conversation.
-- =============================================================================================
create or replace function app.billing_tier_for_capacity_v664(p_cadence text, p_capacity integer)
returns public.billing_capacity_tier_catalog_v664
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select tier.* from public.billing_capacity_tier_catalog_v664 tier
   where tier.currency = 'SGD' and tier.cadence = p_cadence and tier.active
     and tier.effective_from <= now()
     and (tier.effective_to is null or tier.effective_to > now())
     and tier.capacity_ceiling >= p_capacity
   order by tier.capacity_ceiling
   limit 1;
$$;
revoke all on function app.billing_tier_for_capacity_v664(text,integer) from public, anon, authenticated;

create or replace function app.billing_tier_by_price_v664(p_price_id text)
returns public.billing_capacity_tier_catalog_v664
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select tier.* from public.billing_capacity_tier_catalog_v664 tier
   where tier.provider_base_price_id = p_price_id
   order by tier.effective_from desc
   limit 1;
$$;
revoke all on function app.billing_tier_by_price_v664(text) from public, anon, authenticated;

-- =============================================================================================
-- 3. item_role, resolved from catalogues that have rows in them.
-- =============================================================================================
create or replace function app.stripe_item_role_v664(p_price_id text)
returns text
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case
    when p_price_id is null then 'other'
    when exists(select 1 from public.billing_capacity_tier_catalog_v664 tier
                 where tier.provider_base_price_id = p_price_id) then 'base'
    when exists(select 1 from public.billing_plan_catalog_v124 catalog
                 where catalog.provider_base_price_id = p_price_id) then 'base'
    when exists(select 1 from public.billing_plan_catalog_v124 catalog
                 where catalog.provider_capacity_price_id = p_price_id) then 'capacity'
    when exists(select 1 from public.billing_price_catalog legacy
                 where legacy.provider_base_price_id = p_price_id) then 'base'
    when exists(select 1 from public.billing_price_catalog legacy
                 where legacy.provider_seat_price_id = p_price_id) then 'seat'
    else 'other'
  end;
$$;
revoke all on function app.stripe_item_role_v664(text) from public, anon, authenticated;

/* The webhook applier is 400 lines of provider mirroring that must not be retyped by hand: the
   live definition is read, the one price-catalogue lookup is replaced, and the count is asserted
   so a drifted body fails the migration instead of being silently rewritten (the v174 idiom). */
do $v664_item_role$
declare
  v_definition text := pg_get_functiondef('public.apply_stripe_billing_event_v94_base(text)'::regprocedure);
  v_needle constant text := E'        select case\n          when catalog.provider_base_price_id = v_price then ''base''\n          when catalog.provider_seat_price_id = v_price then ''seat''\n          else ''other''\n        end into v_item_role\n          from public.billing_price_catalog catalog\n         where v_price in (catalog.provider_base_price_id,catalog.provider_seat_price_id)\n         order by catalog.effective_from desc\n         limit 1;\n        v_item_role := coalesce(v_item_role,''other'');';
  v_replacement constant text := E'        v_item_role := coalesce(app.stripe_item_role_v664(v_price),''other'');';
  v_occurrences integer;
begin
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'v664 expected exactly one price-catalogue item_role lookup, found %',
      v_occurrences using errcode = '55000';
  end if;
  execute replace(v_definition, v_needle, v_replacement);
end
$v664_item_role$;

-- =============================================================================================
-- 4. A tenant's capacity is the ceiling of the tier their base price belongs to.
-- =============================================================================================
create or replace function app.project_billing_terms_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_subscription_id text := coalesce(new.provider_subscription_id,old.provider_subscription_id);
  v_business uuid;
  v_cadence text;
  v_base public.billing_provider_subscription_items%rowtype;
  v_capacity public.billing_provider_subscription_items%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_blocks integer;
  v_customer_capacity integer;
begin
  select subscription.business_id,subscription.cadence
    into v_business,v_cadence
    from public.billing_provider_subscriptions subscription
   where subscription.provider_subscription_id=v_subscription_id;
  if v_business is null or v_cadence not in ('monthly','annual') then return null; end if;

  select * into v_base from public.billing_provider_subscription_items item
   where item.provider_subscription_id=v_subscription_id and item.item_role='base'
   order by item.updated_at desc limit 1;
  if not found then return null; end if;

  select * into v_capacity from public.billing_provider_subscription_items item
   where item.provider_subscription_id=v_subscription_id and item.item_role='capacity'
   order by item.updated_at desc limit 1;
  v_blocks := 1 + case when found then greatest(v_capacity.quantity,0) else 0 end;

  /* v664: a tiered base price names the capacity outright. The v124 block arithmetic is kept for
     any subscription still sitting on the pre-tier prices, and a base price this deployment does
     not recognise projects nothing at all rather than guessing a capacity. */
  v_tier := app.billing_tier_by_price_v664(v_base.provider_price_id);
  if v_tier.id is not null then
    v_customer_capacity := v_tier.capacity_ceiling;
  else
    select * into v_catalog from public.billing_plan_catalog_v124 catalog
     where catalog.provider_base_price_id=v_base.provider_price_id
       and catalog.cadence=v_cadence
     order by catalog.effective_from desc limit 1;
    if not found then return null; end if;
    v_customer_capacity := v_blocks*1000;
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_capacity_item_id,
    provider_capacity_price_id,provider_event_created_at,last_event_id
  ) values (
    v_business,v_subscription_id,v_cadence,v_customer_capacity,v_blocks,
    v_base.provider_price_id,v_capacity.provider_item_id,
    v_capacity.provider_price_id,
    greatest(v_base.provider_event_created_at,
      coalesce(v_capacity.provider_event_created_at,v_base.provider_event_created_at)),
    coalesce(v_capacity.last_event_id,v_base.last_event_id)
  )
  on conflict(business_id) do update
    set provider_subscription_id=excluded.provider_subscription_id,
        cadence=excluded.cadence,
        customer_capacity=excluded.customer_capacity,
        capacity_blocks=excluded.capacity_blocks,
        provider_base_price_id=excluded.provider_base_price_id,
        provider_capacity_item_id=excluded.provider_capacity_item_id,
        provider_capacity_price_id=excluded.provider_capacity_price_id,
        provider_event_created_at=excluded.provider_event_created_at,
        last_event_id=excluded.last_event_id,updated_at=now()
    where excluded.provider_event_created_at
          >= billing_subscription_terms_v124.provider_event_created_at;
  return null;
end
$function$;
revoke all on function app.project_billing_terms_v124() from public, anon, authenticated;

-- =============================================================================================
-- 5. The command snapshots the tier it was priced from.
-- =============================================================================================
alter table public.billing_commands
  add column if not exists billing_tier_id_v664 uuid
    references public.billing_capacity_tier_catalog_v664(id);

create or replace function public.request_billing_command_v124(p_business uuid, p_command_type text, p_cadence text, p_customer_capacity integer, p_idempotency_key uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid:=auth.uid();
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
  v_current_customer_count integer;
  v_existing_capacity integer;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
begin
  if v_actor is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  if p_command_type not in (
      'create_checkout','create_portal','change_cadence','change_capacity',
      'change_branches','cancel_at_period_end','resume'
    ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  if p_command_type in ('create_checkout','change_cadence','change_capacity','change_branches') then
    if p_cadence not in ('monthly','annual')
       or p_customer_capacity < 1000
       or p_customer_capacity % 1000 <> 0 then
      raise exception 'canonical cadence and customer capacity are required'
        using errcode='22023';
    end if;
    select count(*)::integer into v_current_customer_count
      from public.clients client where client.business_id=p_business;
    if p_customer_capacity < v_current_customer_count then
      raise exception 'selected capacity is below the current customer count'
        using errcode='22023';
    end if;
    /* v664: capacity is a TIER, not an arithmetic block count. The requested capacity must be a
       tier this cadence actually sells, and that tier must have a Stripe price — a tier the owner
       can see but Peekaa cannot charge for refuses here rather than silently billing tier 1. */
    v_tier := app.billing_tier_for_capacity_v664(p_cadence,p_customer_capacity);
    if v_tier.id is null then
      raise exception 'customer capacity above the largest tier needs Peekaa support'
        using errcode='22023';
    end if;
    if v_tier.capacity_ceiling <> p_customer_capacity then
      raise exception 'customer capacity must be one of the published tiers'
        using errcode='22023';
    end if;
    if v_tier.provider_base_price_id is null then
      raise exception 'this capacity tier is not available for self-serve checkout yet'
        using errcode='22023';
    end if;
    select * into v_catalog
      from public.billing_plan_catalog_v124 catalog
       where catalog.currency='SGD' and catalog.cadence=p_cadence
         and catalog.active and catalog.effective_from<=now()
         and (catalog.effective_to is null or catalog.effective_to>now())
       order by catalog.effective_from desc limit 1;
    if not found then
      raise exception 'active V124 Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
    if p_command_type in ('change_cadence','change_capacity') then
      select terms.customer_capacity into v_existing_capacity
        from public.billing_subscription_terms_v124 terms
       where terms.business_id=p_business;
      if p_command_type='change_capacity' and (
           v_existing_capacity is null
           or p_customer_capacity<=v_existing_capacity
         ) then
        raise exception 'capacity changes must be an increase'
          using errcode='22023';
      elsif p_command_type='change_cadence'
            and v_existing_capacity is not null
            and p_customer_capacity<v_existing_capacity then
        raise exception 'billing-cycle changes cannot decrease customer capacity'
          using errcode='22023';
      end if;
    end if;
  elsif p_cadence is not null or p_customer_capacity is not null then
    raise exception 'cadence and capacity are not valid for this command'
      using errcode='22023';
  end if;

  v_fingerprint:=encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_command_type||E'\n'||coalesce(p_cadence,'')
    ||E'\n'||coalesce(p_customer_capacity::text,'')
    ||E'\nv124_customer_capacity','utf8'
  ),'sha256'),'hex');
  select * into v_command from public.billing_commands
   where business_id=p_business and command_type=p_command_type
     and idempotency_key=p_idempotency_key;
  if found then
    if v_command.request_fingerprint<>v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request'
        using errcode='22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,pricing_model,
      requested_customer_capacity,billing_catalog_id_v124,billing_tier_id_v664,
      idempotency_key,request_fingerprint,requested_by
    ) values (
      p_business,p_command_type,p_cadence,'v124_customer_capacity',
      p_customer_capacity,v_catalog.id,v_tier.id,p_idempotency_key,v_fingerprint,v_actor
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$function$;
revoke all on function public.request_billing_command_v124(uuid,text,text,integer,uuid) from public, anon;
grant execute on function public.request_billing_command_v124(uuid,text,text,integer,uuid) to service_role, authenticated;

-- =============================================================================================
-- 6. The claim hands Stripe ONE line item: the tier price, quantity = branch units.
-- =============================================================================================
create or replace function public.claim_billing_command_v124(p_command uuid, p_actor uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_command public.billing_commands%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_terms public.billing_subscription_terms_v124%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_recovery_required boolean:=false;
  v_current_customer_count integer;
  v_capacity integer;
  v_blocks integer;
begin
  select * into v_command from public.billing_commands
   where id=p_command and requested_by=p_actor for update;
  if not found then
    raise exception 'billing command was not found for this actor'
      using errcode='42501';
  end if;
  if v_command.pricing_model is distinct from 'v124_customer_capacity' then
    return public.claim_billing_command_v77(p_command,p_actor);
  end if;
  if v_command.status in ('completed','failed','canceled') then
    return jsonb_build_object(
      'command_id',v_command.id,'status',v_command.status,
      'command_type',v_command.command_type,
      'provider_object_id',v_command.provider_object_id,
      'redirect_url',v_command.redirect_url,'error_code',v_command.error_code,
      'error_message',v_command.error_message,'pricing_model',v_command.pricing_model
    );
  end if;
  v_recovery_required:=v_command.status in ('processing','uncertain');
  update public.billing_commands set status='processing'
   where id=v_command.id and status in ('pending','uncertain')
   returning * into v_command;
  if not found then
    select * into strict v_command from public.billing_commands where id=p_command;
  end if;
  select * into strict v_subscription from public.subscriptions
   where business_id=v_command.business_id;
  select * into v_terms from public.billing_subscription_terms_v124
   where business_id=v_command.business_id;
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id=v_command.business_id;

  if v_command.requested_cadence is not null then
    select * into v_catalog from public.billing_plan_catalog_v124 catalog
     where catalog.id=v_command.billing_catalog_id_v124
       and catalog.currency='SGD'
       and catalog.cadence=v_command.requested_cadence;
    if not found then
      raise exception 'snapshotted V124 Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
  end if;
  v_capacity:=coalesce(v_command.requested_customer_capacity,v_terms.customer_capacity);
  if v_capacity is not null and (
       v_capacity<v_current_customer_count or v_capacity%1000<>0
     ) then
    raise exception 'selected capacity is below the current customer count'
      using errcode='22023';
  end if;
  if v_command.command_type in ('change_cadence','change_capacity')
     and v_terms.business_id is not null and (
       v_capacity<v_terms.customer_capacity
       or (v_command.command_type='change_capacity'
           and v_capacity=v_terms.customer_capacity
           and not v_recovery_required)
     ) then
    raise exception 'subscription changes cannot decrease or replay customer capacity'
      using errcode='22023';
  end if;
  v_blocks:=case when v_capacity is null then null else v_capacity/1000 end;

  /* v664: the tier snapshotted when the owner pressed the button is the price Stripe is asked
     for. An older command with no snapshot resolves the tier from its capacity; a command whose
     tier has since lost its Stripe price refuses rather than falling back to another amount. */
  if v_command.requested_cadence is not null then
    if v_command.billing_tier_id_v664 is not null then
      select * into v_tier from public.billing_capacity_tier_catalog_v664 tier
       where tier.id=v_command.billing_tier_id_v664;
    else
      v_tier := app.billing_tier_for_capacity_v664(v_command.requested_cadence,v_capacity);
    end if;
    if v_tier.id is null or v_tier.provider_base_price_id is null then
      raise exception 'this capacity tier has no Stripe price configured'
        using errcode='22023';
    end if;
  end if;

  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'business_id',v_command.business_id,
    'pricing_model','v124_customer_capacity',
    'requested_cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_capacity,
    'current_customer_count',v_current_customer_count,
    'capacity_blocks',v_blocks,'extra_capacity_blocks',0,
    'capacity_tier_ceiling',v_tier.capacity_ceiling,
    'provider_idempotency_key','nestly:v124:billing-command:'||v_command.id::text,
    'recovery_required',v_recovery_required,
    'prior_provider_object_id',v_command.provider_object_id,
    'prior_redirect_url',v_command.redirect_url,
    'prior_error_code',v_command.error_code,
    'currency',v_subscription.currency,
    'provider_customer_id',v_subscription.provider_customer_id,
    'provider_subscription_id',v_subscription.provider_subscription_id,
    'provider_base_item_id',v_subscription.provider_base_item_id,
    'provider_capacity_item_id',v_terms.provider_capacity_item_id,
    'provider_base_price_id',v_tier.provider_base_price_id,
    'provider_capacity_price_id',null,
    'base_amount_cents',v_tier.amount_cents,
    'capacity_block_amount_cents',0,
    'tax_behavior',coalesce(v_tier.tax_behavior,v_catalog.tax_behavior)
  );
end
$function$;
revoke all on function public.claim_billing_command_v124(uuid,uuid) from public, anon, authenticated;
grant execute on function public.claim_billing_command_v124(uuid,uuid) to service_role;

-- =============================================================================================
-- 7. The billing payload carries the tiers the page must draw.
-- =============================================================================================
create or replace function public.get_business_billing_v124(p_business uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_base jsonb;
  v_current_customer_count integer;
begin
  if auth.uid() is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode = '42501';
  end if;
  v_base := public.get_business_billing_v77(p_business);
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id = p_business;
  return v_base || jsonb_build_object(
    'pricing_model', 'v124_customer_capacity',
    'current_customer_count', v_current_customer_count,
    'staff_billing', false,
    'staff_access_note', 'Staff access is included; use individual logins and roles.',
    'terms', (select to_jsonb(terms) from public.billing_subscription_terms_v124 terms
      where terms.business_id = p_business),
    'money_back_window', (select to_jsonb(window_row)
      from public.billing_money_back_windows_v124 window_row
      where window_row.business_id = p_business),
    /* v664: what the page prices from. `plans` stays for the cadence amounts and the reference
       price; `capacity_tiers` is the capacity ladder, each tier saying plainly whether Peekaa can
       charge for it yet — a tier with no Stripe price is shown and refused, never hidden. */
    'billable_branch_count', (
      select count(*)::integer from public.branches branch
       where branch.business_id = p_business
         and branch.billing_state in ('pending_payment','active')
    ),
    'capacity_tiers', coalesce((
      select jsonb_agg(to_jsonb(tier_rows) order by tier_rows.cadence, tier_rows.capacity_ceiling)
      from (
        select cadence, cadence_months, capacity_ceiling, amount_cents,
               sales_assisted_above, tax_behavior,
               provider_base_price_id is not null as checkout_available
          from public.billing_capacity_tier_catalog_v664 tier
         where currency = 'SGD' and active and effective_from <= now()
           and (effective_to is null or effective_to > now())
      ) tier_rows
    ), '[]'::jsonb),
    'plans', coalesce((
      select jsonb_agg(to_jsonb(plan_rows) order by
        case plan_rows.cadence when 'annual' then 0 else 1 end)
      from (
        select cadence, cadence_months, base_amount_cents,
               included_customer_capacity, capacity_block_size,
               capacity_block_amount_cents, compare_at_monthly_cents,
               tax_behavior
          from public.billing_plan_catalog_v124 catalog
         where currency = 'SGD' and active and effective_from <= now()
           and (effective_to is null or effective_to > now())
      ) plan_rows
    ), '[]'::jsonb),
    'included_modules', jsonb_build_array(
      'Customer CRM and QR signup', 'Loyalty points, stamps and rewards',
      'Birthday benefits and referrals', 'Appointments, team schedule and waitlist',
      'Record sale and sales history', 'Packages, memberships and gift cards',
      'Customer wallet, history and redemption', 'Promotions and template-assisted promotion wording',
      'Feedback and Google review handoff', 'Configured notifications',
      'Profitability and operational reports', 'Branches, roles and permissions',
      'English, Simplified Chinese and Malay business UI'
    ),
    'exclusions', jsonb_build_array(
      'Stripe payment processing fees', 'Usage-priced external messaging',
      'Custom integrations', 'Platform-only administration',
      'Disabled or unconfigured modules'
    )
  );
end;
$function$;
revoke all on function public.get_business_billing_v124(uuid) from public, anon;
grant execute on function public.get_business_billing_v124(uuid) to service_role, authenticated;

-- =============================================================================================
-- 8. A manual payment moves the billing dates.
--    Everything app.business_operational_v620 reads is set here, in one audited write, so a firm
--    that pays by bank transfer or GIRO is indistinguishable from a card payer to every gate.
--    Idempotent on the reason-carrying operation key; never DECREASES a period end, so a replay
--    or an out-of-order entry cannot shorten access someone has already paid for.
-- =============================================================================================
create or replace function public.platform_record_subscription_payment_v664(
  p_business uuid,
  p_reason text,
  p_period_end timestamptz,
  p_cadence text default null,
  p_paid_at timestamptz default null,
  p_amount_cents integer default null,
  p_payment_reference text default null,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_before public.subscriptions%rowtype;
  v_after public.subscriptions%rowtype;
  v_paid_at timestamptz := coalesce(p_paid_at, now());
  v_key text := 'v664-manual-payment:'||coalesce(p_idempotency_key::text,'');
  v_replay jsonb;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(coalesce(btrim(p_reason),'')) < 8 then
    raise exception 'a reason of at least 8 characters is required' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if p_period_end is null or p_period_end <= v_paid_at then
    raise exception 'the paid-through date must be after the payment date' using errcode = '22023';
  end if;
  if p_period_end > now() + interval '400 days' then
    raise exception 'a paid-through date more than 400 days out is not recordable here'
      using errcode = '22023';
  end if;
  if p_cadence is not null and p_cadence not in ('monthly','annual') then
    raise exception 'cadence must be monthly or annual' using errcode = '22023';
  end if;

  select detail into v_replay from public.audit_log
   where business_id = p_business
     and action = 'SUBSCRIPTION_MANUAL_PAYMENT_V664'
     and detail->>'operation_key' = v_key
   limit 1;
  if v_replay is not null then
    return jsonb_build_object('business_id',p_business,'replayed',true,
      'entitlement',app.business_entitlement_v620(p_business));
  end if;

  select * into v_before from public.subscriptions where business_id = p_business for update;
  if v_before.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;

  update public.subscriptions
     set status = 'active',
         payment_status = 'paid',
         billing_cadence = coalesce(p_cadence, billing_cadence),
         cadence_months = case coalesce(p_cadence, billing_cadence)
                            when 'annual' then 12::smallint
                            when 'monthly' then 1::smallint
                            else cadence_months end,
         current_period_start = coalesce(current_period_end, v_paid_at),
         current_period_end = greatest(coalesce(current_period_end, p_period_end), p_period_end),
         next_payment_at = greatest(coalesce(current_period_end, p_period_end), p_period_end),
         last_paid_at = v_paid_at,
         /* initial_payment_source is deliberately NOT touched: v510 owns it as a triple with
            initial_payment_evidence_id and initial_payment_verified_at (constraint
            subscriptions_v510_initial_payment_shape), and it records the FIRST payment's
            identity. This RPC records a period being paid, which is a different fact. */
         updated_at = now()
   where business_id = p_business
  returning * into v_after;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SUBSCRIPTION_MANUAL_PAYMENT_V664', 'subscriptions', p_business,
          jsonb_build_object(
            'operation_key', v_key,
            'reason', btrim(p_reason),
            'paid_at', v_paid_at,
            'amount_cents', p_amount_cents,
            'payment_reference', nullif(btrim(coalesce(p_payment_reference,'')),''),
            'before', jsonb_build_object('status',v_before.status,'payment_status',v_before.payment_status,
                                         'current_period_end',v_before.current_period_end,
                                         'next_payment_at',v_before.next_payment_at),
            'after',  jsonb_build_object('status',v_after.status,'payment_status',v_after.payment_status,
                                         'current_period_end',v_after.current_period_end,
                                         'next_payment_at',v_after.next_payment_at)));

  /* A recorded payment also ends the dunning state the daily v94 sweep put the firm in; without
     this the workspace stays paused with the money already banked. */
  perform app.reconcile_subscription_payment_v94(
    p_business, v_key, 'manual payment recorded: '||btrim(p_reason), v_actor, false);

  return jsonb_build_object(
    'business_id', p_business, 'replayed', false,
    'current_period_end', v_after.current_period_end,
    'next_payment_at', v_after.next_payment_at,
    'entitlement', app.business_entitlement_v620(p_business));
end
$function$;
revoke all on function public.platform_record_subscription_payment_v664(uuid,text,timestamptz,text,timestamptz,integer,text,uuid) from public, anon;
grant execute on function public.platform_record_subscription_payment_v664(uuid,text,timestamptz,text,timestamptz,integer,text,uuid) to service_role, authenticated;

-- =============================================================================================
-- 9. Self-serve signup prices from the same ladder.
--    Without this a new owner could pick 3,000 profiles at signup, be quoted a block price that
--    no longer exists, and only meet the refusal at the Stripe hand-off — after the workspace row
--    had been created. The tier is validated where the choice is made.
-- =============================================================================================
create or replace function app.self_serve_plan_total_v664(p_cadence text, p_customer_capacity integer)
returns integer
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select (app.billing_tier_for_capacity_v664(p_cadence,p_customer_capacity)).amount_cents;
$$;
revoke all on function app.self_serve_plan_total_v664(text,integer) from public, anon, authenticated;

do $v664_self_serve$
declare
  v_definition text := pg_get_functiondef('public.start_self_serve_business_v130(text,text,text,text,text,text,text,integer,boolean,uuid)'::regprocedure);
  v_needle constant text := E'  select * into v_bundle from public.sector_bundle_versions bundle';
  v_guard constant text := E'  if (app.billing_tier_for_capacity_v664(p_cadence,p_customer_capacity)).capacity_ceiling\n     is distinct from p_customer_capacity then\n    raise exception ''customer capacity must be one of the published tiers''\n      using errcode=''22023'';\n  end if;\n  if (app.billing_tier_for_capacity_v664(p_cadence,p_customer_capacity)).provider_base_price_id is null then\n    raise exception ''this capacity tier is not available for self-serve checkout yet''\n      using errcode=''22023'';\n  end if;\n  select * into v_bundle from public.sector_bundle_versions bundle';
  v_total_needle constant text := E'app.self_serve_plan_total_v130(v_catalog,p_customer_capacity)';
  v_total_replacement constant text := E'app.self_serve_plan_total_v664(p_cadence,p_customer_capacity)';
  v_occurrences integer;
begin
  v_occurrences := (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'v664 expected one sector-bundle anchor in start_self_serve_business_v130, found %',
      v_occurrences using errcode='55000';
  end if;
  v_definition := replace(v_definition, v_needle, v_guard);
  v_occurrences := (length(v_definition)-length(replace(v_definition,v_total_needle,'')))/length(v_total_needle);
  if v_occurrences <> 1 then
    raise exception 'v664 expected one self_serve_plan_total_v130 call in start_self_serve_business_v130, found %',
      v_occurrences using errcode='55000';
  end if;
  execute replace(v_definition, v_total_needle, v_total_replacement);
end
$v664_self_serve$;

do $v664_checkout_read$
declare
  v_definition text := pg_get_functiondef('public.get_self_serve_checkout_v130(uuid)'::regprocedure);
  v_total_needle constant text := E'        ''total_cents'', app.self_serve_plan_total_v130(\n          (select catalog from public.billing_plan_catalog_v124 catalog\n            where catalog.id = v_onboarding.billing_catalog_id_v124),\n          v_onboarding.selected_customer_capacity\n        )';
  v_total_replacement constant text := E'        ''total_cents'', app.self_serve_plan_total_v664(\n          v_onboarding.selected_cadence, v_onboarding.selected_customer_capacity\n        )';
  v_plans_needle constant text := E'    ''plans'', coalesce((';
  v_plans_replacement constant text := E'    ''capacity_tiers'', coalesce((\n      select jsonb_agg(jsonb_build_object(\n        ''cadence'', tier.cadence,\n        ''capacity_ceiling'', tier.capacity_ceiling,\n        ''amount_cents'', tier.amount_cents,\n        ''sales_assisted_above'', tier.sales_assisted_above,\n        ''checkout_available'', tier.provider_base_price_id is not null\n      ) order by tier.cadence, tier.capacity_ceiling)\n      from public.billing_capacity_tier_catalog_v664 tier\n      where tier.currency = ''SGD'' and tier.active\n        and tier.effective_from <= now()\n        and (tier.effective_to is null or tier.effective_to > now())\n    ), ''[]''::jsonb),\n    ''plans'', coalesce((';
  v_occurrences integer;
begin
  v_occurrences := (length(v_definition)-length(replace(v_definition,v_total_needle,'')))/length(v_total_needle);
  if v_occurrences <> 1 then
    raise exception 'v664 expected one block-priced total in get_self_serve_checkout_v130, found %',
      v_occurrences using errcode='55000';
  end if;
  v_definition := replace(v_definition, v_total_needle, v_total_replacement);
  v_occurrences := (length(v_definition)-length(replace(v_definition,v_plans_needle,'')))/length(v_plans_needle);
  if v_occurrences <> 1 then
    raise exception 'v664 expected one plans key in get_self_serve_checkout_v130, found %',
      v_occurrences using errcode='55000';
  end if;
  execute replace(v_definition, v_plans_needle, v_plans_replacement);
end
$v664_checkout_read$;

commit;
