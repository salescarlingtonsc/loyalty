-- NESTLY v621 — a branch is paid for by an invoice, not by a checkout URL.
--
-- Three defects closed together, because each hides the next:
--   1. app.activate_branch_on_paid_command_v202 fired when a billing command reached
--      'completed' — and the edge function marks create_checkout commands 'completed' the
--      moment Stripe returns the Checkout URL. Abandoning payment still activated the branch
--      (four production branches went live this way with zero payment).
--   2. Nothing stopped a browser from flipping branches.active / billing_state directly —
--      the owner Edit form's "Active" checkbox was a full bypass of the paid gate.
--   3. Nothing ever left 'pending_payment': abandoned branch rows inflate the Stripe quantity
--      of every later billing command forever ('suspended' was defined but unreachable).
--
-- The new authority is QUANTITY-DERIVED and WEBHOOK-ANCHORED: when invoice.paid lands (spliced
-- into the v94 wrapper of apply_stripe_billing_event_v77, which already post-processes exactly
-- that event), we activate the oldest pending branches UP TO the number of billable units the
-- provider subscription actually carries. A renewal therefore activates only what the renewal
-- invoice actually charges for; an unpaid branch is never covered and never activates. The
-- activation is idempotent by construction — it converges on the covered count.
--
-- Deliberately NOT a trigger on public.subscriptions: last_paid_invoice_id/payment_status are
-- written by two authorities in three ID spaces within one transaction (v77 step-6 vs the v510
-- readiness sync), so a column trigger would double-fire, first with a fail-closed value.
--
-- Existing rows normalized here, with audit, not guessed:
--   · the four unpaid-but-active branches become billing_state='pending_payment' while KEEPING
--     active=true — operations continue through the owner's trial (no customer harm), the
--     Stripe quantity keeps counting them (so the first real checkout CHARGES for them), and
--     only genuine payment flips them to 'active'.
--   · the reaper suspends only inactive pending_payment shells (never a trial-riding branch).

begin;

-- ---------------------------------------------------------------------------
-- 0 · The command vocabulary never learned 'change_branches': the table CHECK
--     still lists only the six original types, so business_add_branch_v202's
--     change_branches insert has ALWAYS raised 23514 on a live subscription —
--     one more layer of the same dead paid-branch path. Widen it.
-- ---------------------------------------------------------------------------
alter table public.billing_commands drop constraint billing_commands_command_type_check;
alter table public.billing_commands add constraint billing_commands_command_type_check
  check (command_type = any (array[
    'create_checkout'::text, 'create_portal'::text, 'change_cadence'::text,
    'change_capacity'::text, 'change_branches'::text,
    'cancel_at_period_end'::text, 'resume'::text]));

-- ---------------------------------------------------------------------------
-- 1 · Retire checkout-URL activation.
-- ---------------------------------------------------------------------------
drop trigger if exists activate_branch_on_paid_command_v202 on public.billing_commands;
drop function if exists app.activate_branch_on_paid_command_v202();

-- ---------------------------------------------------------------------------
-- 2 · Structural guard: billing_state never moves without the activation
--     authority, and an unpaid branch can never be switched on. Deactivating
--     (true→false) stays free — that direction is always safe, and the v510
--     refund path relies on it. Re-enabling a PAID branch stays free too.
-- ---------------------------------------------------------------------------
create or replace function app.guard_branch_billing_authority_v621()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if current_setting('app.branch_authority_v621', true) = 'on' then
    return new;
  end if;
  if new.billing_state is distinct from old.billing_state then
    raise exception 'branch billing state changes only through the paid-activation authority'
      using errcode = '42501';
  end if;
  if new.active and not old.active and old.billing_state not in ('included','active') then
    raise exception 'an unpaid branch cannot be switched on — payment activates it'
      using errcode = '42501';
  end if;
  return new;
end
$$;
revoke all on function app.guard_branch_billing_authority_v621() from public, anon, authenticated;

drop trigger if exists zz_guard_branch_billing_v621 on public.branches;
create trigger zz_guard_branch_billing_v621
  before update of active, billing_state on public.branches
  for each row
  execute function app.guard_branch_billing_authority_v621();

-- ---------------------------------------------------------------------------
-- 3 · The activation authority. Covered billable units = paid base-item
--     quantity minus the base unit the provider covers; activate oldest
--     pending branches up to that count. Assisted-tenant rails (v79) are
--     satisfied explicitly, never bypassed silently.
-- ---------------------------------------------------------------------------
create or replace function app.activate_pending_branches_on_paid_v621(p_business uuid, p_evidence text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_sub public.subscriptions%rowtype;
  v_units integer;
  v_base_covered integer;
  v_active integer;
  v_to_activate integer;
  v_branch record;
  v_activated uuid[] := '{}';
begin
  select * into v_sub from public.subscriptions where business_id = p_business;
  if v_sub.business_id is null or v_sub.provider_subscription_id is null then
    return jsonb_build_object('activated', 0, 'reason', 'no_provider_subscription');
  end if;

  select item.quantity into v_units
    from public.billing_provider_subscription_items item
   where item.provider_subscription_id = v_sub.provider_subscription_id
     and item.item_role = 'base';
  if v_units is null then
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (p_business, null, 'BRANCH_ACTIVATION_DEFERRED_V621', 'branches', p_business,
            jsonb_build_object('evidence', p_evidence, 'why', 'no base subscription item mirrored yet'));
    return jsonb_build_object('activated', 0, 'reason', 'no_base_item');
  end if;

  v_base_covered := case when coalesce(v_sub.provider_covers_base_unit, true) then 1 else 0 end;

  select count(*)::integer into v_active
    from public.branches b
   where b.business_id = p_business and b.billing_state = 'active';

  v_to_activate := greatest(v_units - v_base_covered, 0) - v_active;
  if v_to_activate <= 0 then
    return jsonb_build_object('activated', 0, 'covered_units', greatest(v_units - v_base_covered, 0));
  end if;

  perform set_config('app.branch_authority_v621', 'on', true);
  perform set_config('app.v79_system_transition', 'on', true);

  for v_branch in
    select b.id from public.branches b
     where b.business_id = p_business and b.billing_state = 'pending_payment'
     order by b.created_at
     limit v_to_activate
  loop
    update public.branches
       set billing_state = 'active', active = true, updated_at = now()
     where id = v_branch.id;
    v_activated := v_activated || v_branch.id;
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (p_business, null, 'BRANCH_ACTIVATED_PAID_V621', 'branches', v_branch.id,
            jsonb_build_object('evidence', p_evidence, 'covered_units', greatest(v_units - v_base_covered, 0)));
  end loop;

  perform set_config('app.branch_authority_v621', 'off', true);
  perform set_config('app.v79_system_transition', 'off', true);

  return jsonb_build_object('activated', coalesce(array_length(v_activated, 1), 0),
                            'branches', to_jsonb(v_activated));
end
$$;
revoke all on function app.activate_pending_branches_on_paid_v621(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4 · Splice into the invoice.paid post-processing wrapper. Byte-faithful
--     re-emission of the live v94 wrapper with one added block before return.
-- ---------------------------------------------------------------------------
create or replace function public.apply_stripe_billing_event_v77(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_event public.billing_provider_events%rowtype;
  v_recovery jsonb;
begin
  v_result:=public.apply_stripe_billing_event_v94_base(p_event_id);
  select * into v_event
  from public.billing_provider_events event_row
  where event_row.provider='stripe' and event_row.event_id=p_event_id;
  if v_event.event_type='invoice.paid'
     and coalesce(v_result->>'status','')='processed'
     and v_event.business_id is not null
  then
    v_recovery:=app.reconcile_subscription_payment_v94(
      v_event.business_id,
      'stripe-paid:'||p_event_id,
      'Stripe invoice.paid recovered the subscription workspace',
      null,false
    );
    v_result:=v_result||jsonb_build_object(
      'subscription_lifecycle',v_recovery
    );
  elsif v_event.event_type='invoice.paid'
        and coalesce(v_result->>'duplicate','false')='true'
        and v_event.business_id is not null
  then
    v_recovery:=app.reconcile_subscription_payment_v94(
      v_event.business_id,
      'stripe-paid:'||p_event_id,
      'Stripe invoice.paid recovered the subscription workspace',
      null,false
    );
    v_result:=v_result||jsonb_build_object(
      'subscription_lifecycle',v_recovery
    );
  end if;
  /* v621: paid truth is the only branch activator. Runs on processed AND duplicate replays —
     activation converges on the covered count, so replay is harmless and recovery is free. */
  if v_event.event_type='invoice.paid'
     and v_event.business_id is not null
     and (coalesce(v_result->>'status','')='processed'
          or coalesce(v_result->>'duplicate','false')='true')
  then
    v_result:=v_result||jsonb_build_object(
      'branch_activation',
      app.activate_pending_branches_on_paid_v621(v_event.business_id,'stripe-paid:'||p_event_id)
    );
  end if;
  return v_result;
end
$function$;
revoke all on function public.apply_stripe_billing_event_v77(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5 · The exit from pending_payment: inactive shells older than 7 days are
--     suspended (audited), so they stop inflating every later Stripe quantity.
--     Trial-riding branches (active=true) are never touched by the reaper.
-- ---------------------------------------------------------------------------
create or replace function app.reap_stale_pending_branches_v621()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_count integer := 0;
  v_branch record;
begin
  perform set_config('app.branch_authority_v621', 'on', true);
  for v_branch in
    select b.id, b.business_id from public.branches b
     where b.billing_state = 'pending_payment'
       and not b.active
       and b.updated_at < now() - interval '7 days'
  loop
    update public.branches
       set billing_state = 'suspended', updated_at = now()
     where id = v_branch.id;
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (v_branch.business_id, null, 'BRANCH_SUSPENDED_STALE_V621', 'branches', v_branch.id,
            jsonb_build_object('why', 'pending_payment for over 7 days with no payment'));
    v_count := v_count + 1;
  end loop;
  perform set_config('app.branch_authority_v621', 'off', true);
  return v_count;
end
$$;
revoke all on function app.reap_stale_pending_branches_v621() from public, anon, authenticated;

select cron.schedule(
  'nestly-v621-branch-reaper',
  '45 19 * * *',
  $$select app.reap_stale_pending_branches_v621()$$
);

-- ---------------------------------------------------------------------------
-- 6 · Normalize the four unpaid-but-active production branches (and any like
--     them): they ride the trial with active=true, but their billing_state
--     tells the truth — pending_payment, counted in the next checkout's
--     quantity, activated only by real payment.
-- ---------------------------------------------------------------------------
do $$
declare
  v_branch record;
begin
  perform set_config('app.branch_authority_v621', 'on', true);
  for v_branch in
    select b.id, b.business_id from public.branches b
     where b.billing_state = 'active'
       and not b.is_default
       and not exists (
         select 1 from public.billing_provider_invoices inv
          where inv.business_id = b.business_id and inv.paid_normalized
       )
       and not exists (
         select 1
           from public.platform_manual_payments_v156 mp
           join public.platform_subscription_documents_v156 doc
             on doc.id = mp.invoice_document_id
          where doc.business_id = b.business_id and mp.status = 'verified'
       )
  loop
    update public.branches
       set billing_state = 'pending_payment', updated_at = now()
     where id = v_branch.id;
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (v_branch.business_id, null, 'BRANCH_BILLING_RECLASSIFIED_V621', 'branches', v_branch.id,
            jsonb_build_object('from', 'active', 'to', 'pending_payment',
              'why', 'activated by checkout-URL creation with no payment evidence; rides the trial, charged at first real checkout'));
  end loop;
  perform set_config('app.branch_authority_v621', 'off', true);
end
$$;

commit;
