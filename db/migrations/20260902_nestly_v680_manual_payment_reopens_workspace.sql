/* nestly_v680 — a VERIFIED manual/GIRO payment reopens the workspace.

   Audit finding F129 (P1, confirmed against production read-only on 2026-09-02).

   THE DEFECT
     public.platform_verify_manual_payment_v156 is the only Verify a Super Admin can press
     (app/platform-console.js, manualPaymentVerifyModalV286). It marks the payment verified, mints
     the receipt, and — through the v510 trigger platform_manual_payments_v510_crm_handoff ->
     app.v510_sync_payment_readiness — sets subscriptions.status / payment_status / last_paid_at.
     It has never written current_period_start, current_period_end, next_payment_at or
     obligation_period_*. app.business_operational_v620 opens a workspace only when
       payment_status='paid' AND coalesce(current_period_end, now()) + interval '14 days' >= now(),
     so a manual-rail tenant whose paid period ended more than 14 days ago stays LOCKED OUT after a
     receipted, twice-authorised renewal payment, and is told to pay again by card.

     nestly_v664 shipped public.platform_record_subscription_payment_v664 to write exactly those
     dates, and its own header names this bug — but nothing has ever called it: no client code, no
     edge function, no trigger, no other database function. It is deployed dead code, so the only
     remedy today is raw SQL by an operator.

   THE FIX — one writer, reached from the button people actually press.
     1. app.v680_apply_paid_period is now the SINGLE writer of "this period has been paid" on
        public.subscriptions. Its body is v664's update, unchanged in substance: never decreases a
        period end, keeps status/payment_status/cadence handling identical, writes the same
        SUBSCRIPTION_MANUAL_PAYMENT_V664 audit action with the same operation_key replay contract,
        and clears the v94 dunning state.
     2. public.platform_record_subscription_payment_v664 keeps every one of its validations
        (super-admin only, an eight-character reason, a mandatory idempotency key, a paid-through
        date that is in the future and inside 400 days) and now DELEGATES the write. Its
        out-of-band recovery use and its rollback suite (db/tests/v664_...) are unchanged; it is no
        longer a second authority over the same columns.
     3. app.v680_manual_payment_period derives the period from the invoice the payment settles and
        calls the same writer.
     4. platform_verify_manual_payment_v156 is SPLICED (pg_get_functiondef + anchored replace, the
        nestly_v513 rule and the v542 method) to call (3) in the verified branch, in the SAME
        transaction that issues the receipt. Every present and future caller of Verify — console,
        script or future surface — therefore reopens the workspace. The function is long, settled
        and hand-minified; retyping it to add one line is how the v277 incident happened.

   SEMANTIC CHOICES, each deliberate because this is billing:

   · Period arithmetic. The invoice carries an INCLUSIVE service period of dates
     [service_period_start, service_period_end]; subscriptions.current_period_end is an EXCLUSIVE
     timestamptz (convert_sme_prospect_v79 seeds obligation_period_end = current_period_end - 1
     day). So current_period_start := service_period_start at Singapore midnight and
     current_period_end := (service_period_end + 1 day) at Singapore midnight. Singapore, not UTC:
     the database runs in UTC and a bare date cast would move every period boundary to 08:00 SGT.
   · Never shorten access. current_period_end only ever moves forward (greatest(...)), so a replay,
     a backdated entry or an out-of-order renewal cannot take away access already paid for. The
     start is clamped to the new end so it can never overtake it.
   · obligation_period_* moves only when it is SAFE, and safety is decided by v510 itself, not by a
     copy of its predicate. Those two columns are the key app.v510_verified_initial_payment matches
     evidence on, and AFTER UPDATE trigger subscriptions_payment_link_v510 re-runs
     app.v510_sync_payment_readiness the instant they change — a move that leaves no matching
     evidence would set the tenant past_due, set businesses.join_enabled=false and DEACTIVATE EVERY
     BRANCH. So the move is attempted inside a plpgsql sub-transaction: the columns are advanced,
     v510 is asked whether it can still see a verified payment, and if it cannot the sub-block
     raises and the whole attempt — trigger side effects included — is rolled back. The dates still
     advance, the workspace still reopens, and the skip is recorded in the dispatch audit.
     obligation_period_* is also only ever moved FORWARD, and never on the initial payment (where
     the invoice already matches the obligation the assisted sale wrote).
   · The initial-payment triple is not touched here. subscriptions.initial_payment_source /
     _evidence_id / _verified_at are owned by v510 (constraint subscriptions_v510_initial_payment_
     shape) and record the identity of the FIRST payment; "a period has been paid" is a different
     fact. v664 made the same choice for the same reason.
   · Only the manual rail. If subscriptions.billing_provider <> 'manual', the dates belong to the
     Stripe webhook (apply_stripe_billing_event_v94_base) and this path writes nothing, so a manual
     receipt recorded against a card tenant cannot contradict the provider. The skip is audited.
   · A rejected payment changes nothing: the splice sits after the verified-branch early return.
   · Verifying twice is already a no-op — v156 returns replayed as soon as the payment has left
     'pending_verification' — and the period write is idempotent a second time on its own
     deterministic operation key, so any other route to the same payment also replays.
   · reconcile_subscription_payment_v94 raises business_not_found when a business has no
     business_subscription_lifecycle_v94 row; the writer therefore only calls it when that row
     exists, so a missing lifecycle row can never make a genuine receipt fail.
   · Errors are NOT swallowed. Everything above runs in the verify transaction: if the period write
     fails for a real reason, the verification and the receipt fail with it rather than leaving a
     receipt issued against a workspace that stayed shut.

   Rollback suite: db/tests/v680_manual_payment_reopens_workspace.sql */
begin;

-- =============================================================================================
-- 1. The single writer of a paid period on public.subscriptions.
-- =============================================================================================
create or replace function app.v680_apply_paid_period(
  p_business uuid,
  p_period_end timestamptz,
  p_operation_key text,
  p_reason text,
  p_actor uuid,
  p_source text,
  p_period_start timestamptz default null,
  p_obligation_start date default null,
  p_obligation_end date default null,
  p_cadence text default null,
  p_paid_at timestamptz default null,
  p_amount_cents integer default null,
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_before public.subscriptions%rowtype;
  v_after public.subscriptions%rowtype;
  v_paid_at timestamptz := coalesce(p_paid_at, now());
  v_new_end timestamptz;
  v_new_start timestamptz;
  v_obligation_moved boolean := false;
  v_replay jsonb;
begin
  if p_business is null or p_period_end is null
     or length(coalesce(btrim(p_operation_key),'')) < 8 then
    raise exception 'a business, a paid-through date and an operation key are required'
      using errcode = '22023';
  end if;

  /* Replay is keyed on the reason-carrying operation key, exactly as v664 recorded it, so the
     receipts written before this migration replay against the same key they always did. */
  select detail into v_replay from public.audit_log
   where business_id = p_business
     and action = 'SUBSCRIPTION_MANUAL_PAYMENT_V664'
     and detail->>'operation_key' = btrim(p_operation_key)
   limit 1;
  if v_replay is not null then
    return jsonb_build_object('business_id',p_business,'replayed',true,'applied',false,
      'entitlement',app.business_entitlement_v620(p_business));
  end if;

  select * into v_before from public.subscriptions where business_id = p_business for update;
  if v_before.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;

  /* Access is never shortened, and the period start can never overtake the period end. */
  v_new_end := greatest(coalesce(v_before.current_period_end, p_period_end), p_period_end);
  v_new_start := least(
    coalesce(p_period_start, v_before.current_period_end, v_paid_at), v_new_end);

  /* obligation_period_* is v510's evidence key and its own trigger re-derives payment readiness
     the moment it changes.  Attempt the move in a sub-transaction and let v510 itself veto it. */
  if p_obligation_start is not null and p_obligation_end is not null
     and p_obligation_end >= p_obligation_start
     and (v_before.obligation_period_end is null
          or p_obligation_end > v_before.obligation_period_end) then
    begin
      update public.subscriptions
         set obligation_period_start = p_obligation_start,
             obligation_period_end = p_obligation_end,
             updated_at = now()
       where business_id = p_business;
      if app.v510_verified_initial_payment(p_business) is null then
        raise exception 'v680: the advanced obligation period has no verified payment behind it'
          using errcode = 'XX680';
      end if;
      v_obligation_moved := true;
    exception when sqlstate 'XX680' then
      v_obligation_moved := false;
    end;
  end if;

  update public.subscriptions
     set status = 'active',
         payment_status = 'paid',
         billing_cadence = coalesce(p_cadence, billing_cadence),
         cadence_months = case coalesce(p_cadence, billing_cadence)
                            when 'annual' then 12::smallint
                            when 'half_yearly' then 6::smallint
                            when 'quarterly' then 3::smallint
                            when 'monthly' then 1::smallint
                            else cadence_months end,
         current_period_start = v_new_start,
         current_period_end = v_new_end,
         next_payment_at = v_new_end,
         last_paid_at = v_paid_at,
         /* initial_payment_source is deliberately NOT touched: v510 owns it as a triple with
            initial_payment_evidence_id and initial_payment_verified_at (constraint
            subscriptions_v510_initial_payment_shape), and it records the FIRST payment's
            identity. This writer records a period being paid, which is a different fact. */
         updated_at = now()
   where business_id = p_business
  returning * into v_after;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, p_actor, 'SUBSCRIPTION_MANUAL_PAYMENT_V664', 'subscriptions', p_business,
          jsonb_build_object(
            'operation_key', btrim(p_operation_key),
            'source', coalesce(p_source,'unspecified'),
            'reason', btrim(coalesce(p_reason,'')),
            'paid_at', v_paid_at,
            'amount_cents', p_amount_cents,
            'payment_reference', nullif(btrim(coalesce(p_payment_reference,'')),''),
            'obligation_period_moved', v_obligation_moved,
            'before', jsonb_build_object('status',v_before.status,'payment_status',v_before.payment_status,
                                         'current_period_start',v_before.current_period_start,
                                         'current_period_end',v_before.current_period_end,
                                         'next_payment_at',v_before.next_payment_at,
                                         'obligation_period_start',v_before.obligation_period_start,
                                         'obligation_period_end',v_before.obligation_period_end),
            'after',  jsonb_build_object('status',v_after.status,'payment_status',v_after.payment_status,
                                         'current_period_start',v_after.current_period_start,
                                         'current_period_end',v_after.current_period_end,
                                         'next_payment_at',v_after.next_payment_at,
                                         'obligation_period_start',v_after.obligation_period_start,
                                         'obligation_period_end',v_after.obligation_period_end)));

  /* A recorded payment also ends the dunning state the daily v94 sweep put the firm in; without
     this the workspace stays paused with the money already banked.  The guard is there because
     reconcile raises business_not_found on a business with no lifecycle row, and a genuine
     receipt must never fail for that. */
  if exists (select 1 from public.business_subscription_lifecycle_v94
              where business_id = p_business) then
    perform app.reconcile_subscription_payment_v94(
      p_business, btrim(p_operation_key),
      'manual payment recorded: '||left(btrim(coalesce(p_reason,'manual payment')),900),
      p_actor, false);
  end if;

  return jsonb_build_object(
    'business_id', p_business, 'replayed', false, 'applied', true,
    'current_period_start', v_after.current_period_start,
    'current_period_end', v_after.current_period_end,
    'next_payment_at', v_after.next_payment_at,
    'obligation_period_moved', v_obligation_moved,
    'obligation_period_start', v_after.obligation_period_start,
    'obligation_period_end', v_after.obligation_period_end,
    'entitlement', app.business_entitlement_v620(p_business));
end
$function$;
revoke all on function app.v680_apply_paid_period(uuid,timestamptz,text,text,uuid,text,timestamptz,date,date,text,timestamptz,integer,text) from public, anon, authenticated;

-- =============================================================================================
-- 2. The v664 recovery RPC keeps every validation and stops being a second authority.
--    Same signature, same errors, same replay contract, same return shape as nestly_v664.
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
  v_paid_at timestamptz := coalesce(p_paid_at, now());
  v_key text := 'v664-manual-payment:'||coalesce(p_idempotency_key::text,'');
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

  /* nestly_v680: one writer.  This RPC keeps the policy above — who may record a payment out of
     band, and what a recordable paid-through date is — and hands the write to it.  It does not
     move obligation_period_*: an operator typing a date is not evidence of an invoice. */
  return app.v680_apply_paid_period(
    p_business, p_period_end, v_key, btrim(p_reason), v_actor, 'platform_rpc_v664',
    null, null, null, p_cadence, v_paid_at, p_amount_cents, p_payment_reference);
end
$function$;
revoke all on function public.platform_record_subscription_payment_v664(uuid,text,timestamptz,text,timestamptz,integer,text,uuid) from public, anon;
grant execute on function public.platform_record_subscription_payment_v664(uuid,text,timestamptz,text,timestamptz,integer,text,uuid) to authenticated, service_role;

-- =============================================================================================
-- 3. The verified manual payment, read as a period.
--    Everything is derived from the immutable invoice document the payment settles — never from
--    anything the verifier types — so the dates a workspace reopens on are the dates on the paper.
-- =============================================================================================
create or replace function app.v680_manual_payment_period(p_payment uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_payment public.platform_manual_payments_v156%rowtype;
  v_invoice public.platform_subscription_documents_v156%rowtype;
  v_sub public.subscriptions%rowtype;
  v_skip text;
  v_result jsonb;
begin
  select * into v_payment from public.platform_manual_payments_v156 where id = p_payment;
  if not found or v_payment.status <> 'verified' then
    return jsonb_build_object('applied',false,'reason','payment_not_verified');
  end if;
  select * into v_invoice from public.platform_subscription_documents_v156
   where id = v_payment.invoice_document_id;
  select * into v_sub from public.subscriptions where business_id = v_invoice.business_id;

  v_skip := case
    when v_invoice.id is null then 'invoice_not_found'
    when v_invoice.business_id is null then 'no_workspace_yet'          -- a prospect invoice
    when v_invoice.service_period_start is null
      or v_invoice.service_period_end is null then 'invoice_has_no_service_period'
    when v_invoice.service_period_end < v_invoice.service_period_start then 'invoice_period_inverted'
    when v_sub.business_id is null then 'no_subscription'
    when v_sub.billing_provider <> 'manual' then 'not_manual_rail'      -- Stripe owns those dates
    else null end;

  if v_skip is not null then
    insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor)
    values('manual_payment_period_not_applied','manual_payment',p_payment,
           jsonb_build_object('reason',v_skip,'invoice',v_invoice.id,
                              'business_id',v_invoice.business_id),p_actor);
    return jsonb_build_object('applied',false,'reason',v_skip);
  end if;

  v_result := app.v680_apply_paid_period(
    p_business => v_invoice.business_id,
    /* the invoice period is inclusive of its last day; current_period_end is exclusive, and both
       boundaries are Singapore local midnight rather than UTC midnight. */
    p_period_end => ((v_invoice.service_period_end + 1)::timestamp at time zone 'Asia/Singapore'),
    p_operation_key => 'v664-manual-payment:v680-verified-payment:'||p_payment::text,
    p_reason => 'manual payment verified against invoice '||coalesce(v_invoice.document_number,'')
                ||' for '||v_invoice.service_period_start||' to '||v_invoice.service_period_end,
    p_actor => p_actor,
    p_source => 'verify_manual_payment_v156',
    p_period_start => (v_invoice.service_period_start::timestamp at time zone 'Asia/Singapore'),
    p_obligation_start => v_invoice.service_period_start,
    p_obligation_end => v_invoice.service_period_end,
    p_cadence => null,                                  -- the rail's cadence is not re-decided here
    p_paid_at => coalesce(v_payment.verified_at, now()),
    p_amount_cents => v_payment.amount_cents::integer,
    p_payment_reference => v_payment.payment_reference);

  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor)
  values('manual_payment_period_applied','manual_payment',p_payment,
         jsonb_build_object('invoice',v_invoice.id,'business_id',v_invoice.business_id,
                            'current_period_end',v_result->>'current_period_end',
                            'obligation_period_moved',v_result->>'obligation_period_moved',
                            'replayed',v_result->>'replayed'),p_actor);
  return v_result;
end
$function$;
revoke all on function app.v680_manual_payment_period(uuid,uuid) from public, anon, authenticated;

-- =============================================================================================
-- 4. Verify calls it — spliced, not retyped (the nestly_v513 rule; the v542 method).
--    The anchor is REPRODUCED inside the replacement, and must match exactly once.
-- =============================================================================================
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'  return jsonb_build_object(''payment'',to_jsonb(v_payment),''receipt'',to_jsonb(v_receipt),''replayed'',false);';
  v_inject constant text :=
'  -- nestly_v680: the money has arrived and a second admin has confirmed it.  Move the billing
  -- dates in the same transaction that issues the receipt, or the workspace stays shut behind
  -- app.business_operational_v620 while the firm holds a Peekaa receipt.
  perform app.v680_manual_payment_period(v_payment.id,v_actor);
  return jsonb_build_object(''payment'',to_jsonb(v_payment),''receipt'',to_jsonb(v_receipt),''replayed'',false);';
begin
  v_def := pg_get_functiondef(
    'public.platform_verify_manual_payment_v156(uuid,text,text,uuid)'::regprocedure);
  if position('v680_manual_payment_period' in v_def) > 0 then
    raise notice 'nestly_v680: verify already moves the billing dates, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v680: anchor did not match exactly once in platform_verify_manual_payment_v156 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v680: splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.platform_verify_manual_payment_v156(uuid,text,text,uuid) from public, anon;
grant execute on function public.platform_verify_manual_payment_v156(uuid,text,text,uuid) to authenticated, service_role;

-- =============================================================================================
-- 5. Prove the code change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
begin
  if position('v680_manual_payment_period' in pg_get_functiondef(
       'public.platform_verify_manual_payment_v156(uuid,text,text,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v680: verifying a manual payment still does not move the billing dates'
      using errcode = 'XX001';
  end if;
  if position('v680_apply_paid_period' in pg_get_functiondef(
       'public.platform_record_subscription_payment_v664(uuid,text,timestamptz,text,timestamptz,integer,text,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v680: the v664 RPC is still a second writer of the billing dates'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'app'
                and routine_name in ('v680_apply_paid_period','v680_manual_payment_period')
                and grantee in ('anon','authenticated','PUBLIC')) then
    raise exception 'nestly_v680: an app-schema writer is reachable from the API'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
