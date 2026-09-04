-- nestly_v763 — self-serve activation follows the capacity TIER plan (2026-09-05).
--
-- LIVE TEST-MODE DEFECT. Business Cafe2U (ded721a7-6b3c-426f-8842-6ecf56725e01) signed up
-- self-serve, Razorpay subscription sub_TY2TBGS2P1WeKX (livemode=false) is active, invoice
-- inv_TY2TCG4HIs73yU is paid for 118800 SGD cents, subscriptions.payment_status='paid', and
-- billing_first_paid_evidence_v144 carries the paid evidence ('provider_invoice_self_serve',
-- v756). Yet self_serve_business_onboarding_v130.status stayed 'payment_pending', so the
-- workspace never opened.
--
-- CAUSE. app.activate_self_serve_paid_v130() (v130, redefined by v132) decides whether the paid
-- invoice matches what the firm bought by comparing the subscription TERMS against
-- public.billing_plan_catalog_v124:
--
--     and terms.provider_base_price_id=catalog.provider_base_price_id
--     and terms.customer_capacity=v_onboarding.selected_customer_capacity
--     and terms.capacity_blocks=v_onboarding.selected_customer_capacity/1000
--     and (... provider_capacity_price_id=catalog.provider_capacity_price_id ...)
--
-- Since v664 the price a self-serve checkout uses no longer comes from that catalog: prices live
-- in public.billing_capacity_tier_catalog_v664 and are resolved by
-- app.billing_tier_for_capacity_v664(cadence, capacity), which maps a requested capacity UP to
-- the smallest published tier that covers it. v755 finished the move and left
-- billing_plan_catalog_v124.provider_base_price_id / provider_capacity_price_id NULL. So on
-- prod today:
--
--   terms.provider_base_price_id  = 'plan_TXsSez20bSui76'  (the v664 annual 10k tier plan)
--   catalog.provider_base_price_id= NULL                   -> predicate can never be true
--   terms.customer_capacity       = 10000  (the tier CEILING the checkout actually bought)
--   onboarding.selected_customer_capacity = 1000           -> predicate can never be true
--
-- The trigger fires from billing_first_paid_evidence_v144 and billing_money_back_windows_v124
-- (v144 / v281), so it HAS already run for Cafe2U — it matched nothing and returned silently.
--
-- WHAT THIS MIGRATION DOES
--   1. States the activation ONCE, in app.self_serve_activation_apply_v763(business, invoice,
--      paid_at). The body is the live v130 body transcribed verbatim — the migration first
--      asserts, by sha256 of prosrc AND by a single-occurrence needle check, that the live body
--      is exactly the one transcribed, so nothing is silently dropped — with the v124 price
--      predicate replaced by the v664 tier rule:
--        terms.provider_base_price_id     = the tier's provider_base_price_id
--        terms.customer_capacity          = the tier's capacity_ceiling
--        terms.capacity_blocks            = capacity_ceiling/1000
--        terms.provider_capacity_price_id is null  (a tier is one line item, no capacity add-on)
--        terms.provider_capacity_item_id  is null
--      Every other condition is kept exactly: SGD, tax_cents=0, catalog currency/tax_behavior/
--      cadence, pricing_model, the four invoice amount equalities against
--      app.self_serve_plan_total_v130, amount_remaining_cents=0, the active-owner check, the
--      'payment_pending' FOR UPDATE lock, the workspace approval, the C45 owner-claims dance,
--      the v542 manual-payment supersede, and the audit row.
--   2. app.activate_self_serve_paid_v130() becomes a THIN WRAPPER that calls the helper. There is
--      now one authority for "did this firm pay for what it bought", not two.
--   3. app.activate_self_serve_paid_now_v763(business) — the operator path, service_role only:
--      applies the SAME helper to one payment_pending onboarding row that already has verified
--      paid evidence. Returns {activated, reason}.
--   4. A backfill that runs the helper for every payment_pending onboarding whose business is
--      subscriptions.payment_status='paid'. Read-only dry run against prod on 2026-09-05 found
--      exactly one such business: Cafe2U. (Bear Bear Cafe is payment_pending with
--      payment_status='not_collected' and no paid evidence — it correctly stays pending.)
--
-- NO WIDENING. This does not make activation easier: it points the same strictness at the
-- catalogue that actually priced the checkout. A terms row whose plan is not the tier's plan
-- still does not activate.
--
-- Rollback suite: db/tests/v763_self_serve_activation_by_tier.sql
-- Executed suite: db/tests/executed/v763_corpus_self_serve_activation.sql
begin;

-- =============================================================================================
-- 0 · Prove the live body is the one this migration transcribed.
-- =============================================================================================
do $v763_drift$
declare
  v_src text;
  v_sha text;
  v_needle constant text :=
       E'     and terms.customer_capacity=v_onboarding.selected_customer_capacity\n'
    || E'     and terms.capacity_blocks=v_onboarding.selected_customer_capacity/1000\n'
    || E'     and terms.provider_base_price_id=catalog.provider_base_price_id\n';
  v_occurrences integer;
begin
  select p.prosrc into v_src
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'activate_self_serve_paid_v130';

  if v_src is null then
    raise exception 'v763 requires app.activate_self_serve_paid_v130() to exist'
      using errcode = '55000';
  end if;

  v_occurrences := (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle);
  if v_occurrences <> 1 then
    raise exception
      'v763 expected exactly one v124 price/capacity predicate in activate_self_serve_paid_v130, found %',
      v_occurrences using errcode = '55000';
  end if;

  v_sha := encode(sha256(convert_to(v_src, 'UTF8')), 'hex');
  if v_sha <> '230900c9231f499a91ac54c60252eb0296435f2fdf615189fcf177e3fcec5ba8' then
    raise exception
      'v763: app.activate_self_serve_paid_v130() body has drifted (sha256 %); re-transcribe before applying',
      v_sha using errcode = '55000';
  end if;
end
$v763_drift$;

-- =============================================================================================
-- 1 · One authority for self-serve activation.
-- =============================================================================================
create or replace function app.self_serve_activation_apply_v763(
  p_business uuid, p_invoice text, p_paid_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
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
     tier that covers it, and that tier's plan id is what the checkout actually subscribed to. */
  v_tier := app.billing_tier_for_capacity_v664(
    v_onboarding.selected_cadence, v_onboarding.selected_customer_capacity
  );
  if v_tier.provider_base_price_id is null then
    return jsonb_build_object('activated',false,'reason','no_self_serve_capacity_tier');
  end if;

  if not exists(
    select 1 from public.billing_provider_invoices invoice
    join public.billing_subscription_terms_v124 terms
      on terms.business_id=invoice.business_id
     and terms.provider_subscription_id=invoice.provider_subscription_id
    join public.billing_plan_catalog_v124 catalog
      on catalog.id=v_onboarding.billing_catalog_id_v124
   where invoice.business_id=p_business
     and invoice.provider_invoice_id=p_invoice
     and invoice.status='paid' and invoice.paid_normalized
     and invoice.paid_at is not null
     and invoice.paid_at=p_paid_at
     and invoice.currency='SGD'
     and invoice.tax_cents=0
     and invoice.subtotal_ex_tax_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.total_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_due_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_paid_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_remaining_cents=0
     and catalog.currency='SGD'
     and catalog.tax_behavior='exclusive'
     and catalog.cadence=v_onboarding.selected_cadence
     and terms.pricing_model='v124_customer_capacity'
     and terms.cadence=v_onboarding.selected_cadence
     and terms.customer_capacity=v_tier.capacity_ceiling
     and terms.capacity_blocks=v_tier.capacity_ceiling/1000
     and terms.provider_base_price_id=v_tier.provider_base_price_id
     and terms.provider_capacity_item_id is null
     and terms.provider_capacity_price_id is null
  ) then
    return jsonb_build_object(
      'activated',false,'reason','paid_evidence_does_not_match_tier_terms'
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

  -- nestly_v542: the firm asked to pay another way and then paid through Stripe anyway. Close
  -- the ask here, in the same transaction that opens the workspace, so no Super Admin raises an
  -- invoice for a business that has already paid.
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
      'paid_at',p_paid_at,'workspace_access',true
    )
  );
  return jsonb_build_object('activated',true,'reason','activated');
end
$fn$;

comment on function app.self_serve_activation_apply_v763(uuid,text,timestamptz) is
  'v763: the single authority for opening a self-serve workspace once the provider confirms '
  'payment. The plan a firm must have bought is the v664 capacity TIER for its cadence and '
  'requested capacity, not a v124 catalog price id (those are NULL since v755).';

revoke all on function app.self_serve_activation_apply_v763(uuid,text,timestamptz)
  from public, anon, authenticated;

-- =============================================================================================
-- 2 · The trigger keeps its name and its firing points; it now just calls the authority.
-- =============================================================================================
create or replace function app.activate_self_serve_paid_v130()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
begin
  perform app.self_serve_activation_apply_v763(
    new.business_id, new.first_paid_invoice_id, new.first_paid_at
  );
  return new;
end
$fn$;

comment on function app.activate_self_serve_paid_v130() is
  'v763: thin wrapper. Fires from billing_first_paid_evidence_v144 and '
  'billing_money_back_windows_v124; all decisions live in '
  'app.self_serve_activation_apply_v763.';

revoke all on function app.activate_self_serve_paid_v130()
  from public, anon, authenticated;

-- =============================================================================================
-- 3 · The operator path.
-- =============================================================================================
create or replace function app.activate_self_serve_paid_now_v763(p_business uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_evidence public.billing_first_paid_evidence_v144%rowtype;
  v_result jsonb;
begin
  if p_business is null then
    raise exception 'a business id is required' using errcode = '22023';
  end if;

  select * into v_evidence
    from public.billing_first_paid_evidence_v144 evidence
   where evidence.business_id = p_business;
  if not found or v_evidence.first_paid_invoice_id is null
     or v_evidence.first_paid_at is null then
    return jsonb_build_object(
      'business_id', p_business, 'activated', false, 'reason', 'no_first_paid_evidence'
    );
  end if;

  v_result := app.self_serve_activation_apply_v763(
    p_business, v_evidence.first_paid_invoice_id, v_evidence.first_paid_at
  );

  return jsonb_build_object('business_id', p_business)
         || coalesce(v_result, jsonb_build_object('activated',false,'reason','unknown'));
end
$fn$;

comment on function app.activate_self_serve_paid_now_v763(uuid) is
  'v763: operator re-run of self-serve activation for ONE business that already has verified '
  'first-paid evidence. Idempotent — a business that is no longer payment_pending returns '
  'activated=false, reason=no_payment_pending_onboarding. Service role only.';

revoke all on function app.activate_self_serve_paid_now_v763(uuid)
  from public, anon, authenticated;
grant execute on function app.activate_self_serve_paid_now_v763(uuid) to service_role;

-- =============================================================================================
-- 4 · Backfill: the firms the broken predicate stranded.
-- =============================================================================================
do $v763_backfill$
declare
  v_row record;
  v_result jsonb;
  v_activated integer := 0;
  v_skipped integer := 0;
begin
  for v_row in
    select onboarding.business_id
      from public.self_serve_business_onboarding_v130 onboarding
      join public.subscriptions subscription
        on subscription.business_id = onboarding.business_id
     where onboarding.status = 'payment_pending'
       and subscription.payment_status = 'paid'
     order by onboarding.business_id
  loop
    v_result := app.activate_self_serve_paid_now_v763(v_row.business_id);
    if coalesce((v_result->>'activated')::boolean, false) then
      v_activated := v_activated + 1;
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      values (
        v_row.business_id, null, 'SELF_SERVE_ACTIVATED_BY_TIER_V763',
        'self_serve_business_onboarding_v130', v_row.business_id,
        jsonb_build_object(
          'migration', 'nestly_v763',
          'reason', v_result->>'reason',
          'note', 'stranded by the v124 price predicate; activated against the v664 tier plan'
        )
      );
    else
      v_skipped := v_skipped + 1;
      raise notice 'v763 backfill skipped % — %', v_row.business_id, v_result->>'reason';
    end if;
  end loop;

  raise notice 'v763 backfill: % activated, % skipped', v_activated, v_skipped;
end
$v763_backfill$;

commit;
