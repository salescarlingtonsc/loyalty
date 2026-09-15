-- nestly_v962 — a promo code reaches Stripe, so a card-billed merchant is actually charged less.
--
-- OWNER, 2026-09-15: "do the stripe and razorpay coupons too - make sure i am able to set the
-- amount of discount", then, once told what each provider permits: "i just need stripe, skip razor
-- pay", and the coupon takes money off ONCE, matching v961.
--
-- WHY RAZORPAY IS SKIPPED, recorded so nobody re-opens it as an oversight. Razorpay Offers CANNOT
-- be created through their API — the amount is typed into Razorpay's own dashboard and the API only
-- accepts a pre-made offer_id (PATCH /v1/subscriptions/:id, applied at the END of the current
-- cycle). So "set the amount here" is impossible on Razorpay by construction, and all six Razorpay
-- firms are annual and paid through Sept 2027 anyway. Redemption refuses them with their OWN error,
-- promo_razorpay_unsupported, rather than the generic provider one, so the console can say why.
--
-- WHAT v961 LEFT. v961 shipped promo codes for MANUAL firms: the discount is a number a human
-- applies when recording the payment. A stripe firm has no such human — Stripe charges the card —
-- so v961 refused them outright (promo_provider_billed). This is the other half: redeeming a code
-- on a stripe firm now mints a billing command that creates a REAL Stripe coupon from the code's
-- own terms and attaches it to that subscription, so the next invoice is genuinely smaller.
--
-- THE SHAPE, and why the amount does not travel on the command. public.billing_commands carries a
-- cadence and a capacity, not money, and widening it for one command type would put the discount in
-- two places. Instead the command is a bare instruction: the executor asks
-- app.promo_provider_intent_v962 for the pending redemption's own snapshotted terms, creates the
-- coupon from those, and reports back through app.promo_provider_applied_v962. The redemption row
-- stays the single authority for what this merchant was promised, exactly as in v961.
--
-- DURATION 'once' (owner ruling). The coupon comes off ONE invoice. That is the same promise the
-- merchant already reads on their Billing page and the same rule the manual path follows, so a
-- promo code means one thing whichever provider is charging.
--
-- WHAT THIS DOES NOT DO. It does not move money by itself and it does not touch status,
-- payment_status or last_paid_at (v879). Stripe decides when the discounted invoice is raised; the
-- existing reconcilers mirror the result back like any other Stripe event.
--
-- Rollback suite: db/tests/v962_stripe_promo_coupons.sql

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The command type. A bare instruction: act on the pending promo this business already holds.
-- ---------------------------------------------------------------------------------------------
alter table public.billing_commands
  drop constraint if exists billing_commands_command_type_check;
alter table public.billing_commands
  add constraint billing_commands_command_type_check
  check (command_type = any (array[
    'create_checkout','create_portal','change_cadence','change_capacity','change_branches',
    'cancel_at_period_end','resume','update_card','refresh_payment_method',
    'apply_promo_coupon'          -- nestly_v962
  ]));

-- ---------------------------------------------------------------------------------------------
-- 2. What the redemption learns about the provider side.
-- ---------------------------------------------------------------------------------------------
alter table public.platform_promo_redemptions_v961
  add column if not exists provider text,
  add column if not exists provider_coupon_id text,
  add column if not exists provider_applied_at timestamptz,
  add column if not exists provider_error text;

comment on column public.platform_promo_redemptions_v961.provider_applied_at is
  'nestly_v962: when the coupon was actually created and attached AT the provider. NULL on a stripe redemption means the discount is recorded here but not yet live at Stripe — the merchant is not yet owed it by the card.';

-- ---------------------------------------------------------------------------------------------
-- 3. Redemption accepts stripe. Razorpay keeps its own refusal.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_redeem_promo_code_v961(
  p_business uuid, p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_is_sa boolean;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_promo public.platform_promo_codes_v961%rowtype;
  v_existing public.platform_promo_redemptions_v961%rowtype;
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_provider text;
  v_provider_subscription text;
begin
  if v_actor is null then
    raise exception 'authenticated account required' using errcode = '28000';
  end if;
  v_is_sa := app.is_super_admin();
  if not v_is_sa and not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select billing_provider, provider_subscription_id
    into v_provider, v_provider_subscription
    from public.subscriptions where business_id = p_business;
  if v_provider is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  /* nestly_v962. manual: the discount is applied by the person recording the payment (v961).
     stripe: a real coupon is created and attached by the billing command this redemption arms.
     razorpay: refused, and said so in its own words — Razorpay offers cannot be created through
     their API at all, so no amount set here could ever reach them. */
  if v_provider = 'razorpay' then
    raise exception 'promo_razorpay_unsupported' using errcode = '22023';
  end if;
  if v_provider not in ('manual', 'stripe') then
    raise exception 'promo_provider_billed' using errcode = '22023';
  end if;
  if v_provider = 'stripe' and v_provider_subscription is null then
    raise exception 'promo_no_provider_subscription' using errcode = '22023';
  end if;

  select * into v_existing from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null for update;
  if v_existing.id is not null then
    if v_existing.consumed_at is not null then
      raise exception 'promo_already_used' using errcode = '22023';
    end if;
    if v_existing.promo_id = (select id from public.platform_promo_codes_v961 where code_norm = v_code) then
      return jsonb_build_object('status', 'already_redeemed', 'redemption_id', v_existing.id,
        'discount_kind', v_existing.discount_kind, 'percent_bps', v_existing.percent_bps,
        'amount_cents', v_existing.amount_cents, 'provider', v_existing.provider,
        'provider_applied_at', v_existing.provider_applied_at);
    end if;
    raise exception 'promo_already_held' using errcode = '22023';
  end if;

  select * into v_promo from public.platform_promo_codes_v961 where code_norm = v_code for update;
  if v_promo.id is null
     or not v_promo.active
     or (v_promo.expires_on is not null and v_promo.expires_on < app.sg_today())
     or (v_promo.restricted_business_id is not null and v_promo.restricted_business_id <> p_business)
     or (v_promo.max_redemptions is not null and v_promo.redeemed_count >= v_promo.max_redemptions)
  then
    raise exception 'promo_code_not_found' using errcode = '22023';
  end if;
  /* A percentage travels to any currency; a fixed amount does not. Stripe refuses a coupon whose
     currency is not the subscription's, so it is refused HERE with a sentence instead of there
     with a provider error the merchant cannot act on. */
  if v_provider = 'stripe' and v_promo.discount_kind = 'amount'
     and v_promo.currency is distinct from (select currency from public.subscriptions where business_id = p_business) then
    raise exception 'promo_currency_mismatch' using errcode = '22023';
  end if;

  insert into public.platform_promo_redemptions_v961(
    promo_id, business_id, redeemed_by, redeemed_by_super_admin,
    discount_kind, percent_bps, amount_cents, currency, provider)
  values (v_promo.id, p_business, v_actor, v_is_sa,
    v_promo.discount_kind, v_promo.percent_bps, v_promo.amount_cents, v_promo.currency, v_provider)
  returning * into v_row;

  update public.platform_promo_codes_v961
     set redeemed_count = redeemed_count + 1, updated_at = now()
   where id = v_promo.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_code_redeemed', 'platform_promo_redemptions_v961', v_row.id,
    jsonb_build_object('source', case when v_is_sa then 'platform_console_v961' else 'business_billing_v961' end,
      'code', v_promo.code_norm, 'discount_kind', v_row.discount_kind,
      'percent_bps', v_row.percent_bps, 'amount_cents', v_row.amount_cents,
      'provider', v_provider));

  return jsonb_build_object('status', 'ok', 'redemption_id', v_row.id, 'code', v_promo.code_norm,
    'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents, 'currency', v_row.currency,
    'provider', v_provider,
    -- the caller runs the billing command when this is true; manual firms need nothing
    'needs_provider_coupon', v_provider = 'stripe');
end
$$;

comment on function public.business_redeem_promo_code_v961(uuid, text) is
  'nestly_v961 + v962: a business owner (or a super admin acting for them) redeems a promo code against their FIRST payment. Manual firms apply it when the payment is recorded; stripe firms arm an apply_promo_coupon billing command that creates the real coupon. Razorpay is refused — their offers cannot be created by API.';

-- ---------------------------------------------------------------------------------------------
-- 4. What the executor reads and writes. service_role only: these are the edge function's hands.
-- ---------------------------------------------------------------------------------------------
create or replace function app.promo_provider_intent_v962(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_code text;
  v_sub public.subscriptions%rowtype;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null and consumed_at is null
     and provider_applied_at is null;
  if v_row.id is null then
    return jsonb_build_object('has_intent', false);
  end if;
  select * into v_sub from public.subscriptions where business_id = p_business;
  select code_norm into v_code from public.platform_promo_codes_v961 where id = v_row.promo_id;
  return jsonb_build_object(
    'has_intent', true,
    'redemption_id', v_row.id,
    'code', v_code,
    'discount_kind', v_row.discount_kind,
    'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents,
    'currency', v_row.currency,
    'provider', coalesce(v_row.provider, v_sub.billing_provider),
    'provider_subscription_id', v_sub.provider_subscription_id);
end
$$;

comment on function app.promo_provider_intent_v962(uuid) is
  'nestly_v962: the pending, not-yet-applied promo for one business, as the billing executor needs it. The redemption''s own snapshotted terms — never the code''s current ones — so a code edited after redemption cannot change what is sent to the provider.';

create or replace function app.promo_provider_applied_v962(
  p_redemption uuid, p_coupon_id text, p_error text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where id = p_redemption for update;
  if v_row.id is null then
    raise exception 'promo redemption was not found' using errcode = '42704';
  end if;
  if v_row.removed_at is not null then
    -- Removed while the provider call was in flight. Recording success would leave a live coupon
    -- attached to a subscription with nothing here to explain it, so it is recorded as an error.
    update public.platform_promo_redemptions_v961
       set provider_error = coalesce(nullif(btrim(coalesce(p_error,'')),''),
             'redemption was removed before the provider call returned; coupon '||coalesce(p_coupon_id,'?')||' may be attached at the provider')
     where id = p_redemption;
    return jsonb_build_object('status','removed_in_flight','redemption_id',p_redemption);
  end if;

  if nullif(btrim(coalesce(p_error, '')), '') is not null then
    update public.platform_promo_redemptions_v961
       set provider_error = left(btrim(p_error), 1000), provider_coupon_id = p_coupon_id
     where id = p_redemption;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'promo_provider_coupon_failed',
      'platform_promo_redemptions_v961', p_redemption,
      jsonb_build_object('source','app.promo_provider_applied_v962','error',left(btrim(p_error),1000),
        'coupon_id', p_coupon_id));
    return jsonb_build_object('status','error','redemption_id',p_redemption);
  end if;

  update public.platform_promo_redemptions_v961
     set provider_coupon_id = p_coupon_id,
         provider_applied_at = now(),
         provider_error = null
   where id = p_redemption;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_row.business_id, null, 'promo_provider_coupon_applied',
    'platform_promo_redemptions_v961', p_redemption,
    jsonb_build_object('source','app.promo_provider_applied_v962','coupon_id',p_coupon_id,
      'provider', v_row.provider, 'discount_kind', v_row.discount_kind,
      'percent_bps', v_row.percent_bps, 'amount_cents', v_row.amount_cents));

  return jsonb_build_object('status','ok','redemption_id',p_redemption,'coupon_id',p_coupon_id);
end
$$;

comment on function app.promo_provider_applied_v962(uuid, text, text) is
  'nestly_v962: the billing executor records the coupon it created at the provider, or the error it hit. Never touches the money columns; a redemption removed mid-flight is recorded as an error so an orphaned provider coupon is visible rather than silent.';

-- ---------------------------------------------------------------------------------------------
-- 5. The command gate. This is the LIVE body with two needles replaced and one guard inserted —
--    extract-and-diff, not a restatement. A first draft of this migration DID restate it from
--    memory and silently dropped app.is_billing_owner_v620, the v664 capacity-tier rules and the
--    "capacity changes must be an increase" guard. Diffing against pg_get_functiondef caught it.
--    Exactly two lines of the live body are removed here; everything else is byte-identical.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_billing_command_v124(p_business uuid, p_command_type text, p_cadence text, p_customer_capacity integer, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
      'change_branches','cancel_at_period_end','resume',
      'update_card','refresh_payment_method',
      'apply_promo_coupon'                       -- nestly_v962
    ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  /* v765: both new types act ON a provider subscription - one opens the card-change sheet for
     it, the other refetches the card it was last charged on. Without one there is nothing to
     act on, and the edge function would discover that only after the owner had been sent to a
     checkout page. Refuse here instead. */
  /* nestly_v962 joins them: a promo coupon is attached to a provider subscription, so there is
     no point minting a command for a firm that has none. */
  if p_command_type in ('update_card','refresh_payment_method','apply_promo_coupon')
     and not exists(
       select 1 from public.subscriptions provider_subscription
        where provider_subscription.business_id = p_business
          and provider_subscription.provider_subscription_id is not null
     ) then
    raise exception 'this business has no provider subscription to update'
      using errcode='22023';
  end if;
  /* nestly_v962: and no point minting one with nothing to apply. The redemption is the authority
     for what the coupon is worth, so its absence is refused here rather than at the provider. */
  if p_command_type = 'apply_promo_coupon'
     and not exists(
       select 1 from public.platform_promo_redemptions_v961 redemption
        where redemption.business_id = p_business
          and redemption.removed_at is null
          and redemption.consumed_at is null
          and redemption.provider_applied_at is null
     ) then
    raise exception 'this business has no promo code waiting to be applied'
      using errcode='22023';
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

comment on function public.request_billing_command_v124(uuid, text, text, integer, uuid) is
  'nestly_v124 + v962: mints one billing command for the edge executor. v962 adds apply_promo_coupon, which needs a provider subscription and a promo redemption waiting to be applied.';

-- ---------------------------------------------------------------------------------------------
-- 6. The merchant's and the console's read learns the provider state.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_get_promo_state_v961(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_code text;
  v_sub public.subscriptions%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated account required' using errcode = '28000';
  end if;
  if not app.is_super_admin() and not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions where business_id = p_business;
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null;
  if v_row.id is null then
    return jsonb_build_object('business_id', p_business, 'has_promo', false,
      -- nestly_v962: stripe joins manual as a provider a code can be redeemed against.
      'can_redeem', coalesce(v_sub.billing_provider, '') in ('manual','stripe')
                    and (v_sub.billing_provider <> 'stripe' or v_sub.provider_subscription_id is not null),
      'provider', v_sub.billing_provider);
  end if;
  select code_norm into v_code from public.platform_promo_codes_v961 where id = v_row.promo_id;
  return jsonb_build_object(
    'business_id', p_business, 'has_promo', true, 'can_redeem', false,
    'provider', coalesce(v_row.provider, v_sub.billing_provider),
    'code', v_code,
    'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents, 'currency', v_row.currency,
    'redeemed_at', v_row.redeemed_at,
    'consumed_at', v_row.consumed_at,
    'consumed_list_cents', v_row.consumed_list_cents,
    'consumed_discount_cents', v_row.consumed_discount_cents,
    'consumed_payment_reference', v_row.consumed_payment_reference,
    -- nestly_v962
    'provider_coupon_id', v_row.provider_coupon_id,
    'provider_applied_at', v_row.provider_applied_at,
    'provider_error', v_row.provider_error,
    'needs_provider_coupon', coalesce(v_row.provider, v_sub.billing_provider) = 'stripe'
                             and v_row.provider_applied_at is null);
end
$$;

comment on function public.business_get_promo_state_v961(uuid) is
  'nestly_v961 + v962: the pending or consumed promo for one business, readable by that business''s owner and by a super admin. v962 adds the provider coupon state so a stripe firm can be told whether the discount is live at Stripe yet.';

-- ---------------------------------------------------------------------------------------------
-- 7. Grants. The two executor functions are service_role only — they are the edge function's
--    hands, never a browser's. The three replaced public functions keep the ACLs they had.
-- ---------------------------------------------------------------------------------------------
revoke all on function app.promo_provider_intent_v962(uuid) from public, anon, authenticated;
grant execute on function app.promo_provider_intent_v962(uuid) to service_role;

revoke all on function app.promo_provider_applied_v962(uuid, text, text) from public, anon, authenticated;
grant execute on function app.promo_provider_applied_v962(uuid, text, text) to service_role;

revoke all on function public.business_redeem_promo_code_v961(uuid, text) from public, anon;
grant execute on function public.business_redeem_promo_code_v961(uuid, text) to authenticated, service_role;

revoke all on function public.business_get_promo_state_v961(uuid) from public, anon;
grant execute on function public.business_get_promo_state_v961(uuid) to authenticated, service_role;

revoke all on function public.request_billing_command_v124(uuid, text, text, integer, uuid) from public, anon;
grant execute on function public.request_billing_command_v124(uuid, text, text, integer, uuid) to authenticated, service_role;

commit;
