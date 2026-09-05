-- nestly_v766 — a paid self-serve tenant opens at the TIER price, and a skipped activation is
-- never silent (2026-09-05).
--
-- OBSERVED LIVE (Razorpay test mode, 2026-09-05 03:47Z): business "Cafe Only"
-- (665bf0e9-925c-4be4-b1d8-6f7a74027e31) paid SGD 1,188.00 for the annual up-to-10,000 tier.
-- The webhook accepted subscription.charged/authenticated/activated (all three "processed"),
-- subscriptions.status became active/paid, the first-paid evidence row was written and the
-- v144 trigger fired — and self_serve_business_onboarding_v130.status stayed 'payment_pending'.
-- The owner sat on "Setting up your Peekaa workspace…" forever. Second time this has happened
-- (Cafe2U, 2026-09-04, was hand-activated by the v763 backfill).
--
-- ROOT CAUSE. v763 said "the tier IS the price since v664" and then kept comparing the paid
-- invoice's four amount columns against app.self_serve_plan_total_v130(catalog, capacity) —
-- the RETIRED v124 formula (base 118,800 for the first 1,000 customers + 12,000 per extra
-- 1,000). For 10,000 customers that formula says 226,800; the tier, and the invoice, say
-- 118,800. The predicate could only be true for the one capacity (1,000) where the two
-- formulas coincide — which is exactly the capacity the v763 fixture used, so its F1 passed
-- while every larger tier stayed locked. Reader agreement is not correctness; the fixture
-- agreed with the reader.
--
-- TWO MORE THINGS THE INCIDENT SHOWED:
--   * The trigger discarded the apply result. A refusal left no row anywhere — not in
--     audit_log, not in the logs — so the only way to find it was to re-derive the predicate
--     by hand against production. That is the "silent" in "silently stranded".
--   * The evidence row is immutable (v144 guard), so the trigger fires exactly once. If the
--     apply refuses for a transient reason there is no second chance short of an operator.
--
-- WHAT THIS MIGRATION DOES
--   1. app.self_serve_activation_apply_v763 compares the paid invoice against
--      v_tier.amount_cents — the ONE price authority since v664 — and drops the join to
--      billing_plan_catalog_v124, which has been priceless (NULL provider ids) since v755.
--      Everything else in the predicate (paid, normalized, paid_at match, SGD, zero tax, fully
--      paid, terms carry the tier's plan id and capacity, no capacity item) is unchanged.
--   2. app.activate_self_serve_paid_v130 (the v144 trigger) records a refused activation as an
--      audit_log row `SELF_SERVICE_ACTIVATION_SKIPPED` carrying the reason and invoice, and
--      raises a WARNING, so the next one is visible the moment it happens.
--   3. app.sweep_stranded_self_serve_activations_v766(limit) — the v763 backfill loop as a
--      callable — re-tries every payment_pending onboarding whose subscription is already
--      paid, through the same operator path. Scheduled every five minutes as
--      `nestly-v766-self-serve-activation-sweep` so a transiently refused activation heals
--      itself within minutes instead of waiting for a human.
--   4. Runs the sweep once, which activates Cafe Only.
--
-- Grants restate the live proacl: the apply and trigger functions are owner-only; the
-- operator and the sweep are service_role only.

begin;

-- =============================================================================================
-- 1 · The apply predicate prices from the tier.
-- =============================================================================================
create or replace function app.self_serve_activation_apply_v763(
  p_business uuid, p_invoice text, p_paid_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_control public.business_workspace_controls_v94%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_prior_sub text:=current_setting('request.jwt.claim.sub',true);
  v_prior_claims text:=current_setting('request.jwt.claims',true);
begin
  if p_business is null or p_invoice is null or p_paid_at is null then
    return jsonb_build_object('activated',false,'reason','incomplete_paid_evidence');
  end if;

  select * into v_onboarding
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.business_id=p_business
     and onboarding.status='payment_pending' for update;
  if not found then
    return jsonb_build_object('activated',false,'reason','no_payment_pending_onboarding');
  end if;

  /* v763: the tier IS the price since v664. A capacity is mapped UP to the smallest published
     tier that covers it, and that tier's plan id is what the checkout actually subscribed to.
     v766: and that tier's amount is what the invoice must carry — not the retired v124 formula. */
  v_tier := app.billing_tier_for_capacity_v664(
    v_onboarding.selected_cadence, v_onboarding.selected_customer_capacity
  );
  if v_tier.provider_base_price_id is null or v_tier.amount_cents is null then
    return jsonb_build_object('activated',false,'reason','no_self_serve_capacity_tier');
  end if;

  if not exists(
    select 1 from public.billing_provider_invoices invoice
    join public.billing_subscription_terms_v124 terms
      on terms.business_id=invoice.business_id
     and terms.provider_subscription_id=invoice.provider_subscription_id
   where invoice.business_id=p_business
     and invoice.provider_invoice_id=p_invoice
     and invoice.status='paid' and invoice.paid_normalized
     and invoice.paid_at is not null
     and invoice.paid_at=p_paid_at
     and invoice.currency=v_tier.currency
     and invoice.tax_cents=0
     and invoice.subtotal_ex_tax_cents=v_tier.amount_cents
     and invoice.total_cents=v_tier.amount_cents
     and invoice.amount_due_cents=v_tier.amount_cents
     and invoice.amount_paid_cents=v_tier.amount_cents
     and invoice.amount_remaining_cents=0
     and v_tier.currency='SGD'
     and v_tier.tax_behavior='exclusive'
     and v_tier.cadence=v_onboarding.selected_cadence
     and terms.pricing_model='v124_customer_capacity'
     and terms.cadence=v_onboarding.selected_cadence
     and terms.customer_capacity=v_tier.capacity_ceiling
     and terms.capacity_blocks=v_tier.capacity_ceiling/1000
     and terms.provider_base_price_id=v_tier.provider_base_price_id
     and terms.provider_capacity_item_id is null
     and terms.provider_capacity_price_id is null
  ) then
    return jsonb_build_object(
      'activated',false,'reason','paid_evidence_does_not_match_tier_terms',
      'expected_amount_cents',v_tier.amount_cents,
      'expected_plan_id',v_tier.provider_base_price_id
    );
  end if;

  -- The only identity used for the governed draft seed is the active owner
  -- locked into this payment-pending onboarding record.
  if not exists(
    select 1 from public.staff staff
     where staff.business_id=p_business
       and staff.user_id=v_onboarding.owner_user_id
       and staff.role='owner' and staff.active
  ) then
    return jsonb_build_object('activated',false,'reason','no_active_owner');
  end if;

  update public.self_serve_business_onboarding_v130
     set status='active',activation_invoice_id=p_invoice,
         activated_at=p_paid_at,version=version+1,updated_at=now()
   where business_id=p_business and status='payment_pending';
  if not found then
    return jsonb_build_object('activated',false,'reason','onboarding_no_longer_pending');
  end if;

  select * into strict v_control
    from public.business_workspace_controls_v94 control
   where control.business_id=p_business for update;
  if v_control.approval_status<>'pending' then
    return jsonb_build_object('activated',true,'reason','workspace_already_decided');
  end if;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=null,
         decided_at=p_paid_at,
         decision_reason='provider-confirmed self-service subscription payment',
         updated_at=now()
   where business_id=p_business and approval_status='pending';
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    p_business,null,'self_service_payment_confirmed','pending','approved',
    'provider-confirmed self-service subscription payment',v_control.version+1
  );
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(p_business,v_onboarding.bundle_version_id,1,null)
  on conflict(business_id) do nothing;

  -- C45 intentionally requires the real owner identity for draft writes. The
  -- provider trigger temporarily supplies the locked owner claims, performs
  -- one idempotent preset insert, then restores the caller claims. No grant,
  -- RLS policy, or C45 predicate is changed.
  perform set_config(
    'request.jwt.claim.sub',v_onboarding.owner_user_id::text,true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',v_onboarding.owner_user_id,
      'role','authenticated',
      'aud','authenticated'
    )::text,
    true
  );
  if app.c45_owner_loyalty_write(p_business) then
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    p_business,'points',1,800,2000,false,'classic','draft',
    'self_service_onboarding_preset'
  ) on conflict(business_id) do nothing;
  end if;
  perform set_config('request.jwt.claim.sub',coalesce(v_prior_sub,''),true);
  perform set_config('request.jwt.claims',coalesce(v_prior_claims,''),true);

  -- nestly_v542: the firm asked to pay another way and then paid through the provider anyway.
  -- Close the ask here, in the same transaction that opens the workspace, so no Super Admin
  -- raises an invoice for a business that has already paid.
  update public.business_manual_payment_requests_v542
     set status='superseded', superseded_at=p_paid_at,
         decision_reason='provider-confirmed self-service subscription payment'
   where business_id=p_business and status='open';

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,null,'SELF_SERVICE_PAYMENT_CONFIRMED',
    'self_serve_business_onboarding_v130',p_business,
    jsonb_build_object(
      'provider_invoice_id',p_invoice,
      'paid_at',p_paid_at,'workspace_access',true,
      'tier_amount_cents',v_tier.amount_cents,
      'tier_plan_id',v_tier.provider_base_price_id
    )
  );
  return jsonb_build_object('activated',true,'reason','activated');
end
$function$;

comment on function app.self_serve_activation_apply_v763(uuid,text,timestamptz) is
  'nestly_v766: activates a payment-pending self-serve onboarding when the first paid invoice '
  'matches the v664 capacity TIER (plan id AND amount). The v124 catalogue is no longer consulted.';

revoke all on function app.self_serve_activation_apply_v763(uuid,text,timestamptz)
  from public, anon, authenticated, service_role;

-- =============================================================================================
-- 2 · The trigger says why it did nothing.
-- =============================================================================================
create or replace function app.activate_self_serve_paid_v130()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_result jsonb;
begin
  v_result := app.self_serve_activation_apply_v763(
    new.business_id, new.first_paid_invoice_id, new.first_paid_at
  );
  if not coalesce((v_result->>'activated')::boolean, false)
     and coalesce(v_result->>'reason','') <> 'no_payment_pending_onboarding' then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (
      new.business_id, null, 'SELF_SERVICE_ACTIVATION_SKIPPED',
      'self_serve_business_onboarding_v130', new.business_id,
      jsonb_build_object(
        'provider_invoice_id', new.first_paid_invoice_id,
        'paid_at', new.first_paid_at,
        'source', 'billing_first_paid_evidence_v144 trigger'
      ) || coalesce(v_result, '{}'::jsonb)
    );
    raise warning 'v766: self-serve activation skipped for % — %',
      new.business_id, coalesce(v_result->>'reason','unknown');
  end if;
  return new;
end
$function$;

comment on function app.activate_self_serve_paid_v130() is
  'nestly_v766: v144 trigger — applies the self-serve activation and records a refusal as '
  'audit_log SELF_SERVICE_ACTIVATION_SKIPPED instead of returning silently.';

revoke all on function app.activate_self_serve_paid_v130()
  from public, anon, authenticated, service_role;

-- =============================================================================================
-- 3 · The sweep: every paid-but-pending onboarding is retried through the operator path.
-- =============================================================================================
create or replace function app.sweep_stranded_self_serve_activations_v766(
  p_limit integer default 50
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_row record;
  v_result jsonb;
  v_activated integer := 0;
  v_skipped integer := 0;
  v_skipped_reasons jsonb := '[]'::jsonb;
begin
  for v_row in
    select onboarding.business_id
      from public.self_serve_business_onboarding_v130 onboarding
      join public.subscriptions subscription
        on subscription.business_id = onboarding.business_id
     where onboarding.status = 'payment_pending'
       and subscription.payment_status = 'paid'
     order by onboarding.created_at
     limit greatest(1, coalesce(p_limit, 50))
  loop
    v_result := app.activate_self_serve_paid_now_v763(v_row.business_id);
    if coalesce((v_result->>'activated')::boolean, false) then
      v_activated := v_activated + 1;
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      values (
        v_row.business_id, null, 'SELF_SERVE_ACTIVATED_BY_SWEEP_V766',
        'self_serve_business_onboarding_v130', v_row.business_id,
        jsonb_build_object('reason', v_result->>'reason',
          'note', 'paid subscription whose first-paid trigger did not open the workspace')
      );
    else
      v_skipped := v_skipped + 1;
      v_skipped_reasons := v_skipped_reasons || jsonb_build_object(
        'business_id', v_row.business_id, 'reason', v_result->>'reason');
    end if;
  end loop;
  return jsonb_build_object(
    'status','ok','activated',v_activated,'skipped',v_skipped,'skipped_reasons',v_skipped_reasons
  );
end
$function$;

comment on function app.sweep_stranded_self_serve_activations_v766(integer) is
  'nestly_v766: retries every payment_pending self-serve onboarding whose subscription is '
  'already paid through app.activate_self_serve_paid_now_v763. Cron every five minutes.';

revoke all on function app.sweep_stranded_self_serve_activations_v766(integer)
  from public, anon, authenticated;
grant execute on function app.sweep_stranded_self_serve_activations_v766(integer)
  to service_role;

select cron.schedule('nestly-v766-self-serve-activation-sweep','*/5 * * * *',
  $cron$select app.sweep_stranded_self_serve_activations_v766(50)$cron$)
 where not exists (select 1 from cron.job where jobname='nestly-v766-self-serve-activation-sweep');

-- =============================================================================================
-- 4 · Heal the tenants the v130-formula predicate stranded (Cafe Only on 2026-09-05).
-- =============================================================================================
do $v766_backfill$
declare
  v_result jsonb;
begin
  v_result := app.sweep_stranded_self_serve_activations_v766(200);
  raise notice 'v766 backfill: %', v_result::text;
end
$v766_backfill$;

commit;
