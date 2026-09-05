-- nestly_v792 — a claim only ever hands the executor ids from the provider the platform bills
-- through today, and a subscription left behind on a retired provider reads as unpaid (2026-09-06).
--
-- OBSERVED LIVE, minutes after v791 (owner pressed "Pay now" on a branch): the command failed with
--   resource_missing · No such customer: 'cust_TXtuRBwVvgDij2'
-- That is a RAZORPAY customer id, handed to Stripe Checkout. The mirror tables are shared by every
-- provider — billing_provider_customers holds ONE row per business, subscriptions holds ONE
-- provider_subscription_id — so after a provider switch every claim was still handing out the old
-- provider's ids. Razorpay's subscription ids even share Stripe's `sub_` prefix, so a prefix check
-- in the executor cannot catch it on its own: the fix belongs where the ids are read.
--
-- WHAT THIS MIGRATION DOES
--   1. app.platform_billing_provider_v792() — the provider the platform bills through, read from
--      the ACTIVE tier catalogue (v791 set it to 'stripe'). One authority, so a future switch moves
--      this with the catalogue rather than by hunting for hardcoded names.
--   2. claim_billing_command_v786 (branch scope) hands over a customer id, a subscription id and a
--      prior amount ONLY when the row recording them says the same provider. Anything else is
--      returned NULL, which the executor reads as "not linked yet" — a fresh checkout, never a call
--      against an id that does not exist in its account.
--   3. claim_billing_command_v124 (business scope, patched in place by extract-and-diff) does the
--      same for provider_customer_id, provider_subscription_id and provider_base_item_id. Its
--      provider_base_price_id already comes from the tier catalogue, which v791 repriced.
--   0b. branch_subscriptions_v786.provider accepts 'stripe' as well as 'razorpay' (it pinned
--      Razorpay alone), so a Stripe branch payment can be recorded at all.
--   5. apply_stripe_billing_event_v94_base upserts the customer row on business_id (v760 removed the
--      unique it still named, so every company Stripe event failed 42P10) and RELINKS a business
--      whose row holds another provider's customer, audited, instead of raising.
--   4. get_business_billing_v786 presents a company subscription on a RETIRED provider as no plan:
--      no provider object, no plan label, no amount, state 'none'. The Subscription page then says
--      "Not paid yet" and offers Choose plan, which is the truth — that subscription cannot renew
--      here any more, and its money was never Stripe's. Its invoices stay in Payment history.
--
-- Rollback suite: db/tests/v792_provider_ids_belong_to_one_provider.sql
begin;

-- =============================================================================================
-- 0 · The live bodies this file patches are what it believes they are.
-- =============================================================================================
do $v792_assert$
declare v_body text;
begin
  v_body := pg_get_functiondef('public.claim_billing_command_v124(uuid,uuid)'::regprocedure);
  if position($n$    'provider_customer_id',v_subscription.provider_customer_id,
    'provider_subscription_id',v_subscription.provider_subscription_id,
    'provider_base_item_id',v_subscription.provider_base_item_id,$n$ in v_body) = 0 then
    raise exception 'v792: claim_billing_command_v124 has drifted (provider id needle)';
  end if;
  if position('v792' in v_body) > 0 then
    raise exception 'v792: claim_billing_command_v124 already carries v792';
  end if;
end
$v792_assert$;

-- =============================================================================================
-- 0b · branch_subscriptions_v786 accepts the provider that bills today. The v786 table was written
--      while Razorpay was the only provider and pinned `check (provider in ('razorpay'))`, so the
--      FIRST Stripe branch payment would have been rejected by the applier with 23514 — money taken
--      at Stripe, branch never switched on. Caught by this migration's own acceptance suite.
-- =============================================================================================
alter table public.branch_subscriptions_v786 drop constraint if exists branch_subscriptions_v786_provider_check;
alter table public.branch_subscriptions_v786
  add constraint branch_subscriptions_v786_provider_check check (provider in ('razorpay','stripe'));
alter table public.branch_subscriptions_v786 alter column provider set default 'stripe';

-- =============================================================================================
-- 1 · Which provider the platform bills through.
-- =============================================================================================
create or replace function app.platform_billing_provider_v792()
returns text
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((
    select tier.provider
      from public.billing_capacity_tier_catalog_v664 tier
     where tier.active
       and tier.effective_from <= now()
       and (tier.effective_to is null or tier.effective_to > now())
       and tier.provider_base_price_id is not null
     order by tier.effective_from desc
     limit 1
  ), 'stripe');
$$;
revoke all on function app.platform_billing_provider_v792() from public, anon, authenticated;
comment on function app.platform_billing_provider_v792() is
  'v792: the provider the platform bills through, from the active tier catalogue. A claim never hands an executor an id belonging to any other provider.';

-- =============================================================================================
-- 2 · The branch claim.
-- =============================================================================================
create or replace function public.claim_billing_command_v786(p_command uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_command public.billing_commands%rowtype;
  v_sub public.branch_subscriptions_v786%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_customer text;
  v_recovery boolean := false;
  /* v792: the provider this executor is talking to. Every id below is handed over only when the
     row that records it names the same provider. */
  v_platform text := app.platform_billing_provider_v792();
  v_branch_provider_ok boolean;
begin
  select * into v_command from public.billing_commands
   where id = p_command and requested_by = p_actor for update;
  if not found then
    raise exception 'billing command was not found for this actor' using errcode = '42501';
  end if;
  if v_command.command_scope <> 'branch' then
    return public.claim_billing_command_v130(p_command, p_actor);
  end if;
  if v_command.status in ('completed','failed','canceled') then
    return jsonb_build_object(
      'command_id',v_command.id,'status',v_command.status,'scope','branch',
      'command_type',v_command.command_type,'branch_id',v_command.requested_branch_id,
      'provider_object_id',v_command.provider_object_id,
      'redirect_url',v_command.redirect_url,'error_code',v_command.error_code,
      'error_message',v_command.error_message,'pricing_model',v_command.pricing_model
    );
  end if;
  v_recovery := v_command.status in ('processing','uncertain');
  update public.billing_commands set status = 'processing'
   where id = v_command.id and status in ('pending','uncertain')
   returning * into v_command;
  if not found then
    select * into strict v_command from public.billing_commands where id = p_command;
  end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = v_command.requested_branch_id;
  v_branch_provider_ok := coalesce(v_sub.provider,'') = v_platform;
  if v_command.requested_cadence is not null then
    select * into v_tier from public.billing_capacity_tier_catalog_v664 tier
     where tier.id = v_command.billing_tier_id_v664;
    if v_tier.id is null or v_tier.provider_base_price_id is null then
      raise exception 'this billing cycle has no provider plan configured' using errcode = '22023';
    end if;
  end if;
  /* The company's provider customer, and only when it is this provider's. A tenant whose row still
     holds the retired provider's customer starts a fresh one at checkout. */
  select customer.provider_customer_id into v_customer
    from public.billing_provider_customers customer
   where customer.business_id = v_command.business_id
     and coalesce(customer.provider,'') = v_platform;

  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,'scope','branch',
    'command_type',v_command.command_type,'business_id',v_command.business_id,
    'branch_id',v_command.requested_branch_id,
    'pricing_model','v124_customer_capacity',
    'requested_cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'extra_capacity_blocks',0,
    'provider_idempotency_key','nestly:v786:branch-command:'||v_command.id::text,
    'recovery_required',v_recovery,
    'prior_provider_object_id',v_command.provider_object_id,
    'prior_redirect_url',v_command.redirect_url,
    'prior_error_code',v_command.error_code,
    'currency','SGD',
    'provider_customer_id',coalesce(
      case when v_branch_provider_ok then v_sub.provider_customer_id end, v_customer),
    'provider_subscription_id',case when v_branch_provider_ok then v_sub.provider_subscription_id end,
    'provider_base_price_id',v_tier.provider_base_price_id,
    'base_amount_cents',v_tier.amount_cents,
    'prior_base_amount_cents',case when v_branch_provider_ok then v_sub.unit_amount_cents end,
    'tax_behavior',coalesce(v_tier.tax_behavior,'exclusive'),
    'self_service_onboarding',false
  );
end
$$;
revoke all on function public.claim_billing_command_v786(uuid,uuid) from public, anon, authenticated;
grant execute on function public.claim_billing_command_v786(uuid,uuid) to service_role;

-- =============================================================================================
-- 2b · Minting a branch command reads the branch's subscription through the same lens: a branch
--      left "paid" on the RETIRED provider must still be able to buy a fresh one here. (Caught by
--      this migration's own acceptance suite before it could strand a switched tenant.)
-- =============================================================================================
create or replace function public.request_branch_billing_command_v786(
  p_business uuid, p_branch uuid, p_command_type text, p_cadence text, p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_sub public.branch_subscriptions_v786%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_cadence text := lower(nullif(btrim(coalesce(p_cadence,'')),''));
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
  /* v792: only a subscription on the provider billing today counts as this branch's subscription. */
  v_live boolean;
begin
  if v_actor is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if p_command_type not in (
      'create_checkout','change_cadence','cancel_at_period_end','resume',
      'update_card','refresh_payment_method'
    ) then
    raise exception 'invalid branch billing command' using errcode = '22023';
  end if;
  select * into v_branch from public.branches
   where id = p_branch and business_id = p_business;
  if not found then
    raise exception 'branch was not found for this business' using errcode = '22023';
  end if;
  if v_branch.billing_mode <> 'own' then
    raise exception 'this branch is covered by the company subscription' using errcode = '22023';
  end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = p_branch;
  v_live := v_sub.branch_id is not null
            and coalesce(v_sub.provider,'') = app.platform_billing_provider_v792()
            and v_sub.provider_subscription_id is not null;

  if p_command_type in ('create_checkout','change_cadence') then
    if v_cadence is null or v_cadence not in ('monthly','annual') then
      raise exception 'a billing cycle of monthly or annual is required' using errcode = '22023';
    end if;
    v_tier := app.billing_flat_tier_v786(v_cadence);
    if v_tier.id is null then
      raise exception 'this billing cycle is not available for card checkout yet' using errcode = '22023';
    end if;
    select * into v_catalog from public.billing_plan_catalog_v124 catalog
     where catalog.currency = 'SGD' and catalog.cadence = v_cadence
       and catalog.active and catalog.effective_from <= now()
       and (catalog.effective_to is null or catalog.effective_to > now())
     order by catalog.effective_from desc limit 1;
    if not found then
      raise exception 'active price catalog entry was not found' using errcode = '22023';
    end if;
  elsif v_cadence is not null then
    raise exception 'a billing cycle is not valid for this command' using errcode = '22023';
  end if;

  if p_command_type = 'create_checkout' then
    if v_live and coalesce(v_sub.status,'') in ('active','past_due','paused')
       and v_sub.payment_status = 'paid' then
      raise exception 'this branch already has a paid subscription' using errcode = '22023';
    end if;
  elsif not v_live then
    raise exception 'this branch has no provider subscription to act on' using errcode = '22023';
  end if;
  if p_command_type = 'change_cadence' and v_live and v_sub.cadence = v_cadence
     and v_sub.scheduled_cadence is null then
    raise exception 'this branch is already on that billing cycle' using errcode = '22023';
  end if;

  v_fingerprint := encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_branch::text||E'\n'||p_command_type||E'\n'||coalesce(v_cadence,'')
    ||E'\nv786_branch','utf8'),'sha256'),'hex');
  select * into v_command from public.billing_commands
   where business_id = p_business and command_type = p_command_type
     and idempotency_key = p_idempotency_key;
  if found then
    if v_command.request_fingerprint <> v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request' using errcode = '22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,pricing_model,requested_customer_capacity,
      billing_catalog_id_v124,billing_tier_id_v664,idempotency_key,request_fingerprint,
      requested_by,requested_branch_id,command_scope
    ) values (
      p_business,p_command_type,v_cadence,'v124_customer_capacity',v_tier.capacity_ceiling,
      v_catalog.id,v_tier.id,p_idempotency_key,v_fingerprint,v_actor,p_branch,'branch'
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,'scope','branch',
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'branch_id',p_branch,'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$$;
revoke all on function public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid) to authenticated, service_role;

-- =============================================================================================
-- 3 · The business claim, patched in place.
-- =============================================================================================
do $v792_patch$
declare v_body text; v_new text;
begin
  v_body := pg_get_functiondef('public.claim_billing_command_v124(uuid,uuid)'::regprocedure);
  v_new := replace(v_body,
    $n$    'provider_customer_id',v_subscription.provider_customer_id,
    'provider_subscription_id',v_subscription.provider_subscription_id,
    'provider_base_item_id',v_subscription.provider_base_item_id,$n$,
    $n$    /* v792: the mirror columns are shared by every provider, so an id is handed over only
       when the tenant's own subscription row says it belongs to the provider the platform bills
       through now. Otherwise it is NULL and the executor opens a fresh checkout — never a call
       against an id that does not exist in its account (observed: a Razorpay cust_... sent to
       Stripe Checkout, resource_missing). */
    'provider_customer_id',case when coalesce(v_subscription.billing_provider,'')
                                     = app.platform_billing_provider_v792()
                                then v_subscription.provider_customer_id end,
    'provider_subscription_id',case when coalesce(v_subscription.billing_provider,'')
                                         = app.platform_billing_provider_v792()
                                    then v_subscription.provider_subscription_id end,
    'provider_base_item_id',case when coalesce(v_subscription.billing_provider,'')
                                      = app.platform_billing_provider_v792()
                                 then v_subscription.provider_base_item_id end,$n$);
  if v_new = v_body then raise exception 'v792: claim_billing_command_v124 patch did not apply'; end if;
  execute v_new;
end
$v792_patch$;

-- =============================================================================================
-- 4 · The page's read: a subscription on a retired provider is not a plan.
-- =============================================================================================
create or replace function public.get_business_billing_v786(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_payload jsonb := public.get_business_billing_v758(p_business);
  v_branches jsonb;
  v_annual public.billing_capacity_tier_catalog_v664%rowtype := app.billing_flat_tier_v786('annual');
  v_monthly public.billing_capacity_tier_catalog_v664%rowtype := app.billing_flat_tier_v786('monthly');
  /* v792 */
  v_platform text := app.platform_billing_provider_v792();
  v_company_provider text;
  v_stale boolean;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'branch_id', s.branch_id,
           'provider_subscription_id', s.provider_subscription_id,
           'status', s.status,
           'payment_status', s.payment_status,
           'cadence', s.cadence,
           'plan_label', case s.cadence when 'annual' then 'Annual' when 'monthly' then 'Monthly' else null end,
           'unit_amount_cents', s.unit_amount_cents,
           'current_period_start', s.current_period_start,
           'current_period_end', s.current_period_end,
           'renews_at', coalesce(s.next_payment_at, s.current_period_end),
           'last_paid_at', s.last_paid_at,
           'cancel_at_period_end', s.cancel_at_period_end,
           'renewal_cancel_requested_at', s.renewal_cancel_requested_at,
           'renewal_cancel_sent_at', s.renewal_cancel_sent_at,
           'renewal_cancel_final_after', case when s.renewal_cancel_requested_at is not null and s.current_period_end is not null
                                              then s.current_period_end - interval '48 hours' end,
           'scheduled_change', case when s.scheduled_cadence is not null then jsonb_build_object(
               'kind','cadence','cadence',s.scheduled_cadence,
               'plan_label', case s.scheduled_cadence when 'annual' then 'Annual' when 'monthly' then 'Monthly' end,
               'effective_at', s.scheduled_effective_at, 'amount_cents', s.scheduled_amount_cents) end,
           'payment_method', case when s.payment_method_kind is not null then jsonb_build_object(
               'kind', s.payment_method_kind, 'brand', s.payment_method_brand, 'last4', s.payment_method_last4,
               'updated_at', s.payment_method_updated_at) end,
           /* v792: a branch subscription on a retired provider is not a live plan either. */
           'state', case
             when coalesce(s.provider,'') <> v_platform then 'none'
             when s.status = 'canceled' then 'canceled'
             when s.status = 'unpaid' then 'unpaid'
             when s.renewal_cancel_requested_at is not null then 'canceling'
             when s.cancel_at_period_end then 'canceling'
             when s.payment_status = 'failed' then 'past_due'
             when s.status = 'active' and s.payment_status = 'paid' then 'active'
             else 'none' end
         ) order by s.created_at), '[]'::jsonb)
    into v_branches
    from public.branch_subscriptions_v786 s
   where s.business_id = p_business;

  select s.billing_provider into v_company_provider from public.subscriptions s where s.business_id = p_business;
  /* 'manual' is not a retired provider: a firm Peekaa invoices by hand has no provider object and
     never had one. Only a subscription created by a DIFFERENT payment provider is stale. */
  v_stale := v_company_provider is not null
             and v_company_provider not in (v_platform, 'manual')
             and nullif(v_payload #>> '{provider,subscription_id}', '') is not null;

  if v_stale then
    v_payload := v_payload
      || jsonb_build_object('provider', null, 'terms', null,
           'summary', coalesce(v_payload->'summary','{}'::jsonb) || jsonb_build_object(
             'plan_label', null, 'capacity', null, 'unit_amount_cents', 0, 'total_cents', 0,
             'renews_at', null, 'state', 'none', 'cancel_at_period_end', false,
             'scheduled_change', null, 'renewal_cancel_requested_at', null,
             'renewal_cancel_sent_at', null, 'renewal_cancel_final_after', null,
             'retired_provider', v_company_provider));
  end if;

  return v_payload || jsonb_build_object(
    'branch_subscriptions', v_branches,
    'flat_price', jsonb_build_object(
      'annual_cents', v_annual.amount_cents, 'monthly_cents', v_monthly.amount_cents,
      'annual_available', v_annual.id is not null, 'monthly_available', v_monthly.id is not null)
  );
end
$$;
revoke all on function public.get_business_billing_v786(uuid) from public, anon;
grant execute on function public.get_business_billing_v786(uuid) to authenticated, service_role;
comment on function public.get_business_billing_v786(uuid) is
  'v786 + v792: branch subscriptions and the flat price; a company or branch subscription left on a retired provider reads as no plan.';

-- =============================================================================================
-- 5 · The Stripe company applier can write a customer row again, and a switched tenant relinks.
--
--     billing_provider_customers lost its unique(provider_customer_id) in v760 (a Razorpay customer
--     spans several businesses) and gained unique(business_id). The Stripe base applier — untouched
--     since August — still upserts `on conflict(provider_customer_id)`, so EVERY company-level
--     Stripe event would have failed with 42P10: the owner's card would be charged and the workspace
--     never activated. Caught by this migration's acceptance suite (D5) before a live payment.
--
--     The same block also raised when a business already held a DIFFERENT customer id, which is
--     exactly what a provider switch looks like. v760 settled that question on the Razorpay side: a
--     cross-BUSINESS collision is an error, the same business being handed a new customer id is a
--     relink, recorded in audit_log. The Stripe path now says the same thing.
-- =============================================================================================
do $v792_customer_patch$
declare v_body text; v_new text;
begin
  v_body := pg_get_functiondef('public.apply_stripe_billing_event_v94_base(text)'::regprocedure);
  if position('PROVIDER_CUSTOMER_RELINKED_V792' in v_body) > 0 then
    raise exception 'v792: apply_stripe_billing_event_v94_base already carries v792';
  end if;
  v_new := replace(v_body, $needle$      if exists(
        select 1 from public.billing_provider_customers customer
         where (
           customer.provider_customer_id=v_customer
           and customer.business_id<>v_business
         ) or (
           customer.business_id=v_business
           and customer.provider_customer_id<>v_customer
         )
      ) then
        raise exception 'Stripe customer is already linked to another business';
      end if;
      insert into public.billing_provider_customers(
        business_id,provider_customer_id,currency,livemode,provider_created_at,
        provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,v_customer,upper(nullif(v_object->>'currency','')),
        v_event.livemode,app.stripe_epoch_v77(v_object->'created'),
        v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_customer_id) do update
        set currency=coalesce(excluded.currency,billing_provider_customers.currency),
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_customers.provider_event_created_at,
                billing_provider_customers.provider_event_rank);$needle$, $fixed$      if exists(
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
                billing_provider_customers.provider_event_rank);$fixed$);
  if v_new = v_body then
    raise exception 'v792: the Stripe customer upsert needle did not match';
  end if;
  execute v_new;
end
$v792_customer_patch$;

commit;
