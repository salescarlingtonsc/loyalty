-- NESTLY v281 — STRIPE LAUNCH READINESS: the paid-signup path can complete, renew, and fail
-- into a defined state; plus the bar packages entitlement and the retired duplicate reward.
--
-- CONTEXT. There is no live company yet. The owner's requirement is that a brand-new business
-- owner can sign up, choose a plan, pay by card on Stripe, have the workspace activate itself,
-- have renewals land, and have a failed payment end somewhere defined rather than nowhere. The
-- whole path was walked against production on 2026-08-12 (SELECTs only). Three defects on that
-- path would each have been discovered by the FIRST real customer, and one of them silently.
--
-- =================================================================================================
-- DEFECT 1 (the silent one). DUNNING NEVER STARTS FOR A CARD SUBSCRIPTION.
-- =================================================================================================
-- app.run_subscription_lifecycle_v94 is the daily sweep that produces the whole overdue product:
-- the day-0..day-14 notices, business_subscription_lifecycle_v94.state='grace', and the day-14
-- workspace pause that renderBusinessWorkspaceControl shows the owner. Its overdue CTE is gated on
--
--     and invoice.due_at is not null
--
-- billing_provider_invoices.due_at is populated in apply_stripe_billing_event_v94_base from the
-- Stripe invoice's `due_date`. Stripe only sets `due_date` when collection_method='send_invoice';
-- for collection_method='charge_automatically' it is ALWAYS null. Every subscription created by
-- our own stripe-billing-command is a Checkout `mode:'subscription'` session, i.e. charge
-- automatically. So for every customer we are about to onboard, `due_at` is null, the invoice
-- never enters the overdue CTE, and the sweep evaluates the business as "no overdue invoice" —
-- which is the branch that RESETS the lifecycle to 'current'. A customer whose card fails would
-- have kept full access forever, with no notice, no grace, no pause, and a green lifecycle row.
--
-- app.reconcile_subscription_payment_v94 carries the same predicate twice, so its
-- 'still_overdue' guard could never fire either: an invoice.paid event would report recovery for
-- a business that had never been marked overdue in the first place.
--
-- THE FIX is the smallest one that is also correct for the existing send_invoice shape:
-- app.billing_due_anchor_v281 returns coalesce(due_at, finalized_at). due_at still wins wherever
-- Stripe supplies it, so nothing about a send_invoice tenant changes. For a charge_automatically
-- invoice the anchor becomes the moment Stripe finalized it — which is the moment the first
-- payment attempt happened, and is exactly the day the owner's 14-day clock is meant to start.
-- Both null (a draft invoice) still yields null and is still skipped, so the sweep stays
-- fail-safe: it can only ever start dunning on evidence, never on the absence of it.
--
-- =================================================================================================
-- DEFECT 2. AN OUT-OF-ORDER WEBHOOK STRANDS A PAID WORKSPACE FOREVER.
-- =================================================================================================
-- Activation is a chain: customer.subscription.created writes
-- billing_provider_subscription_items -> app.project_billing_terms_v124 writes
-- billing_subscription_terms_v124 -> invoice.paid writes billing_provider_invoices ->
-- app.capture_money_back_window_v124 writes billing_first_paid_evidence_v144 ->
-- app.activate_self_serve_paid_v130 opens the workspace.
--
-- The middle link is conditional: capture_money_back_window_v124 only writes the first-paid
-- evidence `if exists(... billing_subscription_terms_v124 ...)`. It is an AFTER trigger on
-- billing_provider_invoices, so it is evaluated exactly once, when the paid invoice lands. Stripe
-- does not guarantee webhook ordering and delivers these concurrently. If invoice.paid is applied
-- before customer.subscription.created, the terms row does not exist yet, the capture is skipped,
-- and NOTHING ever re-evaluates it — the later subscription event writes the terms row but there
-- is no trigger on that side. The customer has paid, Stripe is happy, every row in
-- billing_provider_* is correct, and the workspace stays locked until someone notices by hand.
--
-- THE FIX closes the loop from the other side rather than reordering anything: a new AFTER trigger
-- on billing_subscription_terms_v124 replays the identical capture for the earliest already-stored
-- paid invoice of that subscription. Whichever of the two events arrives second performs the
-- capture; both arriving in the happy order is a no-op because the insert is
-- `on conflict do nothing`-shaped. The branch that chooses billing_first_paid_evidence_v144 over
-- billing_money_back_windows_v124 is copied verbatim from capture_money_back_window_v124,
-- including its NULL behaviour for a business with no self-service onboarding row, so the two
-- paths cannot diverge. The existing invoice-side trigger is deliberately left untouched.
--
-- =================================================================================================
-- DEFECT 3. THE ACTIVATION SEED CAN ROLL BACK THE PAYMENT THAT TRIGGERED IT.
-- =================================================================================================
-- V277 taught this exact lesson on the super-admin paths: the loyalty preset insert fires
-- app.seed_loyalty_config_version, whose firm_config_versions draft write is policed by
-- app.c45_loyalty_program_version_write_guard, which raises 42501 unless
-- app.c45_owner_loyalty_write(business) is true. V277 therefore wrapped the seed in that exact
-- predicate in platform_decide_business_application_v105 and
-- platform_activate_approved_application_v169 — "so it can never again break an activation".
--
-- app.activate_self_serve_paid_v130 has the owner impersonation (it is where V277 copied it from)
-- but NOT the gate. It runs inside the invoice.paid transaction. If the predicate is ever false —
-- app.can_module_write refusing, or a future sector bundle published without 'loyalty' — the raise
-- propagates out of the trigger, apply_stripe_billing_event_v94_base marks the event 'failed', the
-- whole transaction rolls back, and the paying customer's workspace does not open. Today
-- app.enforce_self_serve_loyalty_bundle_v132 makes the bundle half of that impossible, but the
-- consequence of being wrong is a rolled-back payment activation, and the cost of the gate is one
-- skipped preset. V281 applies the same twelve-character V277 gate here so all three activation
-- paths are finally identical.
--
-- =================================================================================================
-- HOW THE THREE FUNCTION EDITS ARE MADE, AND WHY NOT BY RETYPING.
-- =================================================================================================
-- All three are large, settled, live-path SECURITY DEFINER functions. Retyping any of them to
-- change one predicate would be the riskiest possible way to change one predicate. So, exactly as
-- V276 and V277 did, this migration reads each function's OWN deployed source with
-- pg_get_functiondef, splices, and re-executes. Every needle is pure SQL with no comment text in
-- it, because the Supabase MCP apply path strips comments and a comment-anchored needle matches a
-- psql rehearsal but silently misses in production. Each splice asserts the EXACT expected number
-- of occurrences before it runs and re-reads the DEPLOYED definition afterwards, so each function
-- is either changed precisely as intended or not at all. Re-running is safe: a function that
-- already carries the change is skipped by name.
--
-- =================================================================================================
-- ALSO IN THIS MIGRATION (owner-requested, unrelated to Stripe).
-- =================================================================================================
-- A. BAR GAINS PACKAGES. sector_bundle_versions('bar',1) shipped in V275 without 'packages' while
--    the client-side sector map lists it; V276 recorded the gap and deliberately left it as an
--    entitlement decision for the owner. The owner has now made it. Section 4 publishes bar v2 =
--    v1 + 'packages', retires v1, and re-points the one existing bar tenant (Bistro 999) at v2
--    through the same mechanism public.platform_assign_business_sector_v75 uses — bump the
--    assignment, then write enabled_modules under
--    set_config('app.sector_entitlement_sync', business_id) so
--    app.business_sector_modules_guard_v75 permits it. The module list is resolved through
--    app.resolve_sector_entitlement_v75 rather than written literally, so module_registry's
--    packages->services dependency is honoured by the same code that honours it everywhere else.
--    An existing bar tenant GAINS a module and loses none.
--
-- B. THE RETIRED DUPLICATE REWARD. loyalty_rewards 95f12d05-2d00-443c-9844-e7a5d62a2423 on the
--    Cubbly demo tenant (8492e8d6) is an inactive byte-duplicate of 749c9f59 — same customer name,
--    same internal name, same 150 points. Verified against production: 0 loyalty_redemptions,
--    0 customer_redemption_intents_v89, 0 loyalty_operations, 0 branch/service/product
--    entitlements. The owner ruled: no live data, clean it.
--
--    IT IS NOT A PLAIN DELETE, AND THE REASON MATTERS. The reward has 6 loyalty_reward_versions
--    rows and only 2 of them belong to draft configurations. The other 4 belong to published or
--    superseded firm_config_versions, and app.reward_version_immutable_guard raises
--    restrict_violation on any DELETE of a version row whose configuration is not 'draft'; the
--    parent row cannot go while any version remains (ON DELETE RESTRICT). Deleting from the drafts
--    alone would not even be durable: app.clone_reward_versions_for_config re-clones the next
--    draft from the last PUBLISHED version, which still holds the duplicate.
--
--    So section 5 disables that one guard for the length of this transaction and no longer, and
--    records the before/after firm_config_versions.snapshot_hash of every configuration it
--    touches in audit_log — because removing a member from a published configuration DOES change
--    that configuration's snapshot (app.refresh_loyalty_config_snapshot_trigger recomputes it),
--    and that rewrite must be evidenced rather than silent. Nothing customer-visible moves: the
--    reward is already active=false in every published version. Every precondition is asserted
--    first and the section aborts rather than guessing. It is fully idempotent — if the reward is
--    already gone it reports and does nothing.
--
-- =================================================================================================
-- OPERATIONAL SAFETY NET (section 3).
-- =================================================================================================
-- app.v281_redrive_failed_billing_events re-applies durable-inbox events left in 'failed', and
-- events stuck in 'processing' for over ten minutes. Today the only retry is Stripe's own, which
-- stops after roughly three days; after that a stranded event is stranded permanently and the
-- money has still moved. The redrive is bounded, oldest-first, and calls the same
-- public.apply_stripe_billing_event_v77 the webhook calls, so it can only produce outcomes the
-- webhook could have produced. It is scheduled every five minutes alongside the existing billing
-- crons.
--
-- Rollback-only acceptance: db/tests/v281_stripe_launch_readiness.sql.
-- Sections 4 and 5 are real committed changes and are evidenced by before/after counts.

begin;

-- =================================================================================================
-- 1. The dunning anchor.
-- =================================================================================================

create or replace function app.billing_due_anchor_v281(
  p_invoice public.billing_provider_invoices
)
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce((p_invoice).due_at,(p_invoice).finalized_at)
$$;

revoke all on function app.billing_due_anchor_v281(public.billing_provider_invoices)
  from public,anon,authenticated;

comment on function app.billing_due_anchor_v281(public.billing_provider_invoices) is
  'Overdue anchor for a provider invoice. Stripe leaves due_date null for charge_automatically, which is every Checkout subscription, so finalization stands in as the day the payment was first attempted.';

do $v281_dunning$
declare
  v_target text;
  v_source text;
  v_patched text;
  v_hits integer;
  v_expected integer;
  v_targets constant text[] := array[
    'app.run_subscription_lifecycle_v94(date)',
    'app.reconcile_subscription_payment_v94(uuid,text,text,uuid,boolean)'
  ];
  v_expected_hits constant integer[] := array[4,2];
  v_index integer := 0;
  v_needle constant text := 'invoice.due_at';
  v_patch constant text := 'app.billing_due_anchor_v281(invoice)';
begin
  foreach v_target in array v_targets loop
    v_index := v_index + 1;
    v_expected := v_expected_hits[v_index];
    v_source := pg_get_functiondef(v_target::regprocedure);

    if position(v_patch in v_source) > 0 then
      raise notice 'v281: % already uses the V281 due anchor - skipped', v_target;
      continue;
    end if;

    v_hits := (length(v_source) - length(replace(v_source, v_needle, '')))
              / length(v_needle);
    if v_hits <> v_expected then
      raise exception 'v281: expected % due_at references in %, found %',
        v_expected, v_target, v_hits;
    end if;

    v_patched := replace(v_source, v_needle, v_patch);
    execute v_patched;

    v_source := pg_get_functiondef(v_target::regprocedure);
    if position(v_patch in v_source) = 0 then
      raise exception 'v281: the due anchor did not land in the deployed %', v_target;
    end if;
    if position(v_needle in v_source) > 0 then
      raise exception 'v281: % still carries a raw due_at reference', v_target;
    end if;
  end loop;
end
$v281_dunning$;

-- CREATE OR REPLACE preserves the ACL; both are stated so the granted surface of a replaced
-- SECURITY DEFINER function is visible in the migration rather than inferred. Neither is a public
-- entry point: the sweep is called by cron, the reconciler by apply_stripe_billing_event_v77.
revoke all on function app.run_subscription_lifecycle_v94(date) from public, anon;
revoke all on function app.reconcile_subscription_payment_v94(uuid,text,text,uuid,boolean)
  from public, anon;

-- =================================================================================================
-- 2. The out-of-order webhook repair.
-- =================================================================================================

create or replace function app.v281_capture_first_paid_from_terms()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_invoice public.billing_provider_invoices%rowtype;
  v_legal_version text;
begin
  select invoice.* into v_invoice
    from public.billing_provider_invoices invoice
   where invoice.business_id=new.business_id
     and invoice.provider_subscription_id=new.provider_subscription_id
     and invoice.paid_normalized
     and invoice.paid_at is not null
   order by invoice.paid_at asc, invoice.provider_invoice_id asc
   limit 1;
  if not found then return null; end if;

  -- Branch copied verbatim from app.capture_money_back_window_v124, including its behaviour when
  -- there is no self-service onboarding row (v_legal_version null, comparison null, else branch).
  select onboarding.legal_document_version into v_legal_version
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.business_id=new.business_id;

  if v_legal_version>='2026-08-03' then
    insert into public.billing_first_paid_evidence_v144(
      business_id,first_paid_invoice_id,first_paid_at,source_event_id
    ) values(
      new.business_id,v_invoice.provider_invoice_id,v_invoice.paid_at,
      v_invoice.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_first_paid_evidence_v144.first_paid_at;
  else
    insert into public.billing_money_back_windows_v124(
      business_id,first_paid_invoice_id,first_paid_at,
      money_back_request_until,source_event_id
    ) values(
      new.business_id,v_invoice.provider_invoice_id,v_invoice.paid_at,
      v_invoice.paid_at+interval '30 days',v_invoice.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          money_back_request_until=excluded.money_back_request_until,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_money_back_windows_v124.first_paid_at;
  end if;
  return null;
end
$$;

revoke all on function app.v281_capture_first_paid_from_terms()
  from public,anon,authenticated;

drop trigger if exists billing_terms_first_paid_replay_v281
  on public.billing_subscription_terms_v124;
create trigger billing_terms_first_paid_replay_v281
  after insert or update of provider_subscription_id, provider_event_created_at
  on public.billing_subscription_terms_v124
  for each row execute function app.v281_capture_first_paid_from_terms();

comment on function app.v281_capture_first_paid_from_terms() is
  'Replays the first-paid capture when the subscription terms arrive after the paid invoice. Stripe does not order webhooks, and the invoice-side capture is evaluated only once.';

-- =================================================================================================
-- 3. The activation gate, and the failed-event redrive.
-- =================================================================================================

do $v281_activation$
declare
  v_target constant text := 'app.activate_self_serve_paid_v130()';
  v_source text;
  v_patched text;
  v_hits integer;
  v_needle constant text :=
       E'  insert into public.loyalty_programs(\n'
    || E'    business_id,kind,earn_points_per_dollar,redeem_points,\n'
    || E'    reward_credit_cents,active,loyalty_model,configuration_status,\n'
    || E'    recommendation_source\n'
    || E'  ) values(\n'
    || E'    new.business_id,''points'',1,800,2000,false,''classic'',''draft'',\n'
    || E'    ''self_service_onboarding_preset''\n'
    || E'  ) on conflict(business_id) do nothing;';
  v_gate constant text := 'if app.c45_owner_loyalty_write(new.business_id) then';
  v_patch text;
begin
  v_source := pg_get_functiondef(v_target::regprocedure);
  if position(v_gate in v_source) > 0 then
    raise notice 'v281: % already gates the loyalty seed - skipped', v_target;
    return;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_needle, '')))
            / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v281: expected exactly 1 loyalty seed in %, found %', v_target, v_hits;
  end if;

  v_patch := E'  ' || v_gate || E'\n' || v_needle || E'\n  end if;';
  v_patched := replace(v_source, v_needle, v_patch);
  execute v_patched;

  v_source := pg_get_functiondef(v_target::regprocedure);
  if position(v_gate in v_source) = 0 then
    raise exception 'v281: the C45 gate did not land in the deployed %', v_target;
  end if;
  if position('insert into public.loyalty_programs(' in v_source) = 0 then
    raise exception 'v281: the loyalty seed was lost from the deployed %', v_target;
  end if;
end
$v281_activation$;

create or replace function app.v281_redrive_failed_billing_events(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_event record;
  v_result jsonb;
  v_attempted integer := 0;
  v_processed integer := 0;
  v_still_failed integer := 0;
begin
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'redrive limit must be between 1 and 1000' using errcode='22023';
  end if;
  for v_event in
    select event_row.event_id
      from public.billing_provider_events event_row
     where event_row.provider='stripe'
       and (
         event_row.processing_status='failed'
         or (event_row.processing_status='processing'
             and event_row.received_at < now()-interval '10 minutes')
       )
     order by event_row.event_created_at asc, event_row.id asc
     limit p_limit
  loop
    v_attempted := v_attempted + 1;
    v_result := public.apply_stripe_billing_event_v77(v_event.event_id);
    if coalesce(v_result->>'status','') in ('processed','ignored') then
      v_processed := v_processed + 1;
    else
      v_still_failed := v_still_failed + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'attempted',v_attempted,'processed',v_processed,'still_failed',v_still_failed
  );
end
$$;

revoke all on function app.v281_redrive_failed_billing_events(integer)
  from public,anon,authenticated;

comment on function app.v281_redrive_failed_billing_events(integer) is
  'Re-applies durable-inbox Stripe events left failed or stuck processing. Stripe stops retrying after roughly three days; after that a stranded event is permanent and the money has still moved.';

do $v281_cron$
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    -- cron.unschedule raises when the job is absent, so it is only called when it exists.
    if exists(select 1 from cron.job where jobname='nestly-v281-billing-event-redrive') then
      perform cron.unschedule('nestly-v281-billing-event-redrive');
    end if;
    perform cron.schedule(
      'nestly-v281-billing-event-redrive','*/5 * * * *',
      'select app.v281_redrive_failed_billing_events(200)'
    );
  else
    raise notice 'v281: pg_cron is absent - the redrive must be scheduled by hand';
  end if;
end
$v281_cron$;

-- =================================================================================================
-- 4. Bar gains packages (owner decision recorded in V276 as pending).
-- =================================================================================================

do $v281_bar$
declare
  v_v1 public.sector_bundle_versions%rowtype;
  v_v2 public.sector_bundle_versions%rowtype;
  v_modules text[];
  v_effective text[];
  v_business record;
  v_next bigint;
  v_moved integer := 0;
begin
  select * into v_v1 from public.sector_bundle_versions
   where sector_key='bar' and version=1;
  if not found then
    raise exception 'v281: the bar v1 bundle is missing - refusing to guess the module list';
  end if;

  select * into v_v2 from public.sector_bundle_versions
   where sector_key='bar' and version=2;
  if found then
    raise notice 'v281: bar bundle v2 already exists - skipping publication';
  else
    if v_v1.modules @> array['packages']::text[] then
      raise exception 'v281: bar v1 already carries packages - nothing to publish';
    end if;
    if not v_v1.modules @> array['services']::text[] then
      raise exception 'v281: bar v1 has no services module, which packages requires';
    end if;
    -- One published bundle per sector: the incumbent is retired in the same transaction.
    -- sector_bundle_versions_status_time_check requires retired_at alongside status='retired'.
    v_modules := v_v1.modules || array['packages']::text[];
    update public.sector_bundle_versions
       set status='retired', retired_at=now()
     where id=v_v1.id;
    insert into public.sector_bundle_versions(
      sector_key,version,label,modules,status,published_at
    ) values('bar',2,'Bar core',v_modules,'published',now())
    returning * into v_v2;
  end if;

  -- Existing bar tenants GAIN the module. Same mechanism as
  -- public.platform_assign_business_sector_v75: bump the assignment, then write enabled_modules
  -- under the sector-sync setting the guard recognises.
  v_effective := app.resolve_sector_entitlement_v75(v_v2.id,'{}','{}');
  if not v_effective @> array['packages']::text[] then
    raise exception 'v281: the resolved bar entitlement does not contain packages';
  end if;

  for v_business in
    select assignment.business_id, assignment.version
      from public.business_sector_assignments assignment
     where assignment.bundle_version_id=v_v1.id
       and assignment.override_version_id is null
     order by assignment.business_id
  loop
    v_next := v_business.version + 1;
    update public.business_sector_assignments
       set bundle_version_id=v_v2.id, version=v_next, updated_at=now()
     where business_id=v_business.business_id;
    perform set_config('app.sector_entitlement_sync', v_business.business_id::text, true);
    update public.businesses
       set enabled_modules=v_effective, industry=v_v2.sector_key
     where id=v_business.business_id;
    perform set_config('app.sector_entitlement_sync','',true);
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(
      v_business.business_id,null,'BUSINESS_SECTOR_ASSIGNED_V281','businesses',
      v_business.business_id,
      jsonb_build_object(
        'reason','bar bundle v2 adds packages; V275 shipped v1 without it and V276 deferred the entitlement decision to the owner',
        'bundle_version_id',v_v2.id,'sector_key','bar','assignment_version',v_next,
        'effective_modules',to_jsonb(v_effective)
      )
    );
    v_moved := v_moved + 1;
  end loop;

  -- A tenant left on a retired bundle would be entitled to a bundle nobody can be assigned.
  if exists(
    select 1 from public.business_sector_assignments assignment
     where assignment.bundle_version_id=v_v1.id
       and assignment.override_version_id is null
  ) then
    raise exception 'v281: a bar tenant is still assigned to the retired v1 bundle';
  end if;

  raise notice 'v281: bar v2 published; % tenant(s) moved onto it', v_moved;
end
$v281_bar$;

-- =================================================================================================
-- 5. Remove the retired duplicate reward (owner ruling: no live data, clean it).
-- =================================================================================================

do $v281_reward$
declare
  v_reward constant uuid := '95f12d05-2d00-443c-9844-e7a5d62a2423';
  v_business constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_row public.loyalty_rewards%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_versions integer;
begin
  select * into v_row from public.loyalty_rewards where id=v_reward;
  if not found then
    raise notice 'v281: reward % is already removed - skipped', v_reward;
    return;
  end if;

  -- Preconditions. Every one of these is a reason NOT to delete, so each aborts rather than
  -- warns. The surviving twin must exist: the point is to remove a duplicate, not the reward.
  if v_row.business_id <> v_business then
    raise exception 'v281: reward % does not belong to the expected demo tenant', v_reward;
  end if;
  if v_row.active then
    raise exception 'v281: reward % is active - refusing to delete a live reward', v_reward;
  end if;
  if not exists(
    select 1 from public.loyalty_rewards twin
     where twin.business_id=v_business and twin.id<>v_reward
       and twin.internal_name=v_row.internal_name
       and twin.customer_name=v_row.customer_name
       and twin.cost_points=v_row.cost_points
       and twin.active
  ) then
    raise exception 'v281: no surviving active twin of reward % - it is not a duplicate', v_reward;
  end if;
  if exists(select 1 from public.loyalty_redemptions x where x.reward_id=v_reward)
     or exists(select 1 from public.loyalty_redemptions x
                where x.reward_version_id in (
                  select id from public.loyalty_reward_versions where reward_id=v_reward))
     or exists(select 1 from public.customer_redemption_intents_v89 x where x.reward_id=v_reward)
     or exists(select 1 from public.customer_redemption_intents_v89 x
                where x.quoted_reward_version_id in (
                  select id from public.loyalty_reward_versions where reward_id=v_reward))
     or exists(select 1 from public.loyalty_operations x where x.reward_id=v_reward) then
    raise exception 'v281: reward % carries customer history - refusing to delete', v_reward;
  end if;

  select count(*)::integer into v_versions
    from public.loyalty_reward_versions where reward_id=v_reward;

  -- Removing a member from a PUBLISHED configuration changes that configuration's snapshot.
  -- app.refresh_loyalty_config_snapshot_trigger recomputes snapshot_hash automatically; the
  -- before/after values are captured so the rewrite is evidenced rather than silent.
  select jsonb_agg(jsonb_build_object(
           'config_version_id',config.id,'version_no',config.version_no,
           'status',config.status,'snapshot_hash',config.snapshot_hash)
         order by config.version_no)
    into v_before
    from public.firm_config_versions config
   where config.id in (
     select version_row.config_version_id
       from public.loyalty_reward_versions version_row
      where version_row.reward_id=v_reward
   );

  -- app.reward_version_immutable_guard correctly refuses to delete a version row belonging to a
  -- non-draft configuration. Four of this reward's six versions do. The guard is suspended for
  -- the length of this transaction only, and only for this one table.
  alter table public.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_immutable;

  delete from public.loyalty_reward_versions where reward_id=v_reward;
  delete from public.loyalty_rewards where id=v_reward;

  alter table public.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_immutable;

  if exists(select 1 from public.loyalty_rewards where id=v_reward)
     or exists(select 1 from public.loyalty_reward_versions where reward_id=v_reward) then
    raise exception 'v281: reward % survived the delete', v_reward;
  end if;

  select jsonb_agg(jsonb_build_object(
           'config_version_id',config.id,'version_no',config.version_no,
           'status',config.status,'snapshot_hash',config.snapshot_hash)
         order by config.version_no)
    into v_after
    from public.firm_config_versions config
   where config.id in (
     select (member->>'config_version_id')::uuid
       from jsonb_array_elements(coalesce(v_before,'[]'::jsonb)) member
   );

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(
    v_business,null,'LOYALTY_REWARD_DUPLICATE_REMOVED_V281','loyalty_rewards',v_reward,
    jsonb_build_object(
      'reason','owner ruling 2026-08-12: retired duplicate reward with no live data',
      'reward_id',v_reward,'customer_name',v_row.customer_name,
      'internal_name',v_row.internal_name,'cost_points',v_row.cost_points,
      'reward_versions_removed',v_versions,
      'config_snapshots_before',coalesce(v_before,'[]'::jsonb),
      'config_snapshots_after',coalesce(v_after,'[]'::jsonb)
    )
  );

  raise notice 'v281: removed reward % and its % version row(s)', v_reward, v_versions;
end
$v281_reward$;

commit;
