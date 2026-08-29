-- NESTLY v620 — one entitlement authority: billing truth decides whether a workspace operates.
--
-- Before this migration, "may this business operate" was answered by approval_status + a pause
-- flag alone. Payment played no part: expired trials ran forever, and nothing between
-- `subscriptions` and the tenant gates ever compared dates. This migration gives the four tenant
-- gates (is_salon_member / is_salon_owner / has_perm / can_see_branch) a billing-aware brain by
-- redefining the ONE predicate they all already call: app.business_workspace_open_v94.
--
-- Policy, stated once (constants live in app.business_operational_v620):
--   · approved AND not paused, AND
--   · paid:   payment_status='paid' and current_period_end + 14 days grace >= now()
--             (14 days mirrors the v94 dunning pause window), OR
--   · trial:  status='trialing' and trial_ends_at >= now() — a hard stop, no implicit grace.
--             Runway is granted EXPLICITLY (audited) via platform_adjust_subscription_v622,
--             never silently.
--   Anything else (incomplete, canceled past its paid period, lapsed, missing rows) is closed.
--   NULL trial_ends_at on a trialing row is CLOSED (fail-closed); the normalization below
--   guarantees no pre-v620 tenant is left in that state.
--
-- A locked workspace must still be able to PAY ITS WAY BACK IN. is_salon_owner now (correctly)
-- fails for a locked business, so the two billing entry points switch to
-- app.is_billing_owner_v620 — the same active-approved-owner test WITHOUT the workspace gate.
-- Their bodies below are byte-faithful re-emissions of the live production definitions with only
-- that one gate line changed.
--
-- Existing tenants: every pre-v620 trialing subscription whose trial already ended is extended,
-- with an audit row per business, to 2026-09-14 23:59:59 SGT. That is an explicit, uniform,
-- audited runway for owner outreach — not a silent grandfathering: after this migration the same
-- input state produces the same entitlement for every business, old or new.

begin;

-- ---------------------------------------------------------------------------
-- 1 · Normalize pre-v620 state BEFORE enforcement exists (same transaction).
-- ---------------------------------------------------------------------------
with fixed as (
  update public.subscriptions s
     set trial_ends_at = '2026-09-14T15:59:59Z'::timestamptz
   where s.status = 'trialing'
     and (s.trial_ends_at is null or s.trial_ends_at < now())
  returning s.business_id
)
insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
select f.business_id, null, 'TRIAL_RUNWAY_V620', 'subscriptions', f.business_id,
       jsonb_build_object(
         'trial_ends_at', '2026-09-14T15:59:59Z',
         'why', 'pre-v620 expired trial given an explicit audited runway before entitlement enforcement began'
       )
  from fixed f;

-- ---------------------------------------------------------------------------
-- 2 · The hot-path operational predicate. One row lookup per table, all keyed
--     on business_id; called from RLS via business_workspace_open_v94, so it
--     must stay lean SQL.
-- ---------------------------------------------------------------------------
create or replace function app.business_operational_v620(p_business uuid)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((
    select control.approval_status = 'approved'
       and not lifecycle.workspace_paused
       and (
             (sub.payment_status = 'paid'
              and coalesce(sub.current_period_end, now()) + interval '14 days' >= now())
          or (sub.status = 'trialing' and sub.trial_ends_at >= now())
       )
      from public.business_workspace_controls_v94 control
      join public.business_subscription_lifecycle_v94 lifecycle
        on lifecycle.business_id = control.business_id
      left join public.subscriptions sub
        on sub.business_id = control.business_id
     where control.business_id = p_business
  ), false);
$$;
revoke all on function app.business_operational_v620(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3 · The rich entitlement object for UI/console. Same decision tree, with
--     names and reasons. Never used on the RLS hot path.
-- ---------------------------------------------------------------------------
create or replace function app.business_entitlement_v620(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_control public.business_workspace_controls_v94%rowtype;
  v_paused boolean;
  v_sub public.subscriptions%rowtype;
  v_state text;
  v_reason text;
  v_open boolean := false;
begin
  select * into v_control from public.business_workspace_controls_v94 where business_id = p_business;
  select workspace_paused into v_paused from public.business_subscription_lifecycle_v94 where business_id = p_business;
  select * into v_sub from public.subscriptions where business_id = p_business;

  if v_control.business_id is null or v_control.approval_status is distinct from 'approved' then
    v_state := 'pending_approval';
    v_reason := 'workspace approval is pending';
  elsif coalesce(v_paused, false) then
    v_state := 'paused';
    v_reason := 'workspace paused for overdue payment';
  elsif v_sub.business_id is null then
    v_state := 'no_subscription';
    v_reason := 'no subscription record exists';
  elsif v_sub.payment_status = 'paid'
        and coalesce(v_sub.current_period_end, now()) + interval '14 days' >= now() then
    v_state := 'paid';
    v_open := true;
  elsif v_sub.status = 'trialing' and v_sub.trial_ends_at >= now() then
    v_state := 'trial';
    v_open := true;
  elsif v_sub.status = 'trialing' then
    v_state := 'trial_expired';
    v_reason := 'the trial ended on ' || to_char(v_sub.trial_ends_at at time zone 'Asia/Singapore', 'DD Mon YYYY');
  elsif v_sub.payment_status = 'paid' then
    v_state := 'payment_lapsed';
    v_reason := 'the paid period ended on ' || to_char(v_sub.current_period_end at time zone 'Asia/Singapore', 'DD Mon YYYY');
  else
    v_state := coalesce(v_sub.status, 'unknown');
    v_reason := 'subscription is ' || coalesce(v_sub.status, 'missing');
  end if;

  return jsonb_build_object(
    'business_id', p_business,
    'may_access_workspace', v_open,
    'operational_state', v_state,
    'restriction_reason', v_reason,
    'billing_state', v_sub.status,
    'payment_state', v_sub.payment_status,
    'trial_state', case
        when v_sub.status = 'trialing' and v_sub.trial_ends_at >= now() then 'active'
        when v_sub.status = 'trialing' then 'expired'
        else null end,
    'trial_ends_at', v_sub.trial_ends_at,
    'plan', v_sub.plan_code,
    'cadence', v_sub.billing_cadence,
    'current_period_start', v_sub.current_period_start,
    'current_period_end', v_sub.current_period_end,
    'computed_at', now()
  );
end
$$;
revoke all on function app.business_entitlement_v620(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4 · The RPC. A locked owner MUST be able to read WHY they are locked, so the
--     gate is staff-of-business (ignoring workspace state) or super admin —
--     never the workspace predicate this function reports on.
-- ---------------------------------------------------------------------------
create or replace function public.get_business_entitlement_v620(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  if not (
    app.is_super_admin()
    or exists (
      select 1 from public.staff s
       where s.business_id = p_business
         and s.user_id = auth.uid()
         and s.active
    )
  ) then
    raise exception 'staff access to this business is required' using errcode = '42501';
  end if;
  return app.business_entitlement_v620(p_business);
end
$$;
revoke all on function public.get_business_entitlement_v620(uuid) from public, anon;
grant execute on function public.get_business_entitlement_v620(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5 · The billing escape hatch: active approved owner, workspace state ignored.
-- ---------------------------------------------------------------------------
create or replace function app.is_billing_owner_v620(p_business uuid)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.staff s
     where s.business_id = p_business
       and s.user_id = auth.uid()
       and s.active
       and s.access_state = 'approved'
       and s.role = 'owner'
  );
$$;
revoke all on function app.is_billing_owner_v620(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6 · The splice: every tenant gate now asks the entitlement authority.
--     Signature, name and ACL unchanged; only the brain is new.
-- ---------------------------------------------------------------------------
create or replace function app.business_workspace_open_v94(p_business uuid)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.business_operational_v620(p_business);
$$;
revoke all on function app.business_workspace_open_v94(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7 · Billing entry points for locked tenants. Byte-faithful re-emissions of
--     the live production bodies; the ONLY change in each is the gate line:
--     app.is_salon_owner -> app.is_billing_owner_v620, so an owner whose
--     workspace is closed for non-payment can still open billing and pay.
-- ---------------------------------------------------------------------------
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
        select provider_invoice_id,number,status,paid_normalized,currency,
               subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,
               amount_remaining_cents,collection_method,period_start,period_end,
               paid_at,next_payment_attempt_at,
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
grant execute on function public.get_business_billing_v77(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_business_billing_v124(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
grant execute on function public.get_business_billing_v124(uuid) to authenticated, service_role;

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
    if p_customer_capacity < greatest(1000,
         ceil(v_current_customer_count::numeric/1000)::integer*1000) then
      raise exception 'selected capacity is below the current customer count'
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
      requested_customer_capacity,billing_catalog_id_v124,
      idempotency_key,request_fingerprint,requested_by
    ) values (
      p_business,p_command_type,p_cadence,'v124_customer_capacity',
      p_customer_capacity,v_catalog.id,p_idempotency_key,v_fingerprint,v_actor
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
revoke all on function public.request_billing_command_v124(uuid, text, text, integer, uuid) from public, anon;
grant execute on function public.request_billing_command_v124(uuid, text, text, integer, uuid) to authenticated, service_role;

commit;
