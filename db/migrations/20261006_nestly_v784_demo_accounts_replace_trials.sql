-- nestly_v784 — demo accounts replace trials, and a workspace is never locked for money (2026-09-05).
--
-- OWNER RULINGS (2026-09-05, from the Subscription page review):
--   · "since when i have trial or grandfathered free branch? i do not have any free branches or
--     trial (please remove it, all are paid plans OR Demo account)".
--   · The fourteen tenants still sitting on unpaid trials: "Convert them all to Demo accounts".
--   · A demo account looks "exactly as how live account will look like, nothing changes, because
--     i need it to test (just that we know it is demo account) — backend no money enter our
--     system".
--   · Access: "Never lock, only switch off branches." A branch whose payment fails switches off on
--     its own; the workspace itself stays open.
--
-- WHAT THIS MIGRATION DOES
--   1. Every trialing, unpaid, non-demo business becomes a demo account (businesses.is_demo,
--      the v174 flag), with one audit row per business in business_demo_flag_audit_v174 — the
--      same table the super-admin RPC writes. The set is data-driven (status='trialing' and not
--      is_demo), not a list of ids: the ruling is about a STATE.
--   2. app.business_operational_v620 — the ONE predicate every tenant gate calls — no longer
--      reads the subscription at all: a workspace is open when it is approved and not paused.
--      Payment truth now acts on BRANCHES (v786 switches a branch off when its own payment
--      lapses), never on the door. The v94 pause switch stays: it is the platform's own,
--      audited, reversible act, not an automatic consequence of a card declining.
--   3. app.business_entitlement_v620 — the rich readback — reports the same decision with names
--      the console can show: 'demo' for a demo firm, 'open' for any other approved, unpaused
--      firm, and carries is_demo. The billing/payment/trial fields are still reported for
--      information; none of them closes the door any more.
--
-- Both functions are re-emitted in full. Each replacement is preceded by an assertion that the
-- LIVE body still contains the exact clause being changed (the v174/v664/v755 extract-and-diff
-- idiom): a body that has drifted from this file's expectation fails the migration loudly.
--
-- NOT DONE HERE, deliberately:
--   · Onboarding (create_business_v79 and the self-serve activation path) still writes
--     status='trialing'. The row's word is a provider-status vocabulary, not a product promise,
--     and the Subscription page no longer prints it.
--   · The Razorpay edge functions are not made demo-aware. Production Razorpay is in TEST mode
--     today (every billing_provider_invoices row has livemode=false), so no money enters for any
--     tenant. Routing demo firms to test keys once live keys are installed is a go-live
--     prerequisite recorded in the wave note.
--
-- Rollback suite: db/tests/v784_demo_accounts_replace_trials.sql
begin;

-- =============================================================================================
-- 0 · The live bodies are what this file believes they are.
-- =============================================================================================
do $v784_assert$
declare
  v_body text;
begin
  v_body := pg_get_functiondef('app.business_operational_v620(uuid)'::regprocedure);
  if position($needle$or (sub.status = 'trialing' and sub.trial_ends_at >= now())$needle$ in v_body) = 0 then
    raise exception 'v784: app.business_operational_v620 has drifted — the trial clause is not where v620 left it';
  end if;
  v_body := pg_get_functiondef('app.business_entitlement_v620(uuid)'::regprocedure);
  if position($needle$v_reason := 'workspace paused for overdue payment';$needle$ in v_body) = 0 then
    raise exception 'v784: app.business_entitlement_v620 has drifted — the paused clause is not where v620 left it';
  end if;
  if position('is_demo' in v_body) > 0 then
    raise exception 'v784: app.business_entitlement_v620 already reads is_demo — this migration has been applied or superseded';
  end if;
end
$v784_assert$;

-- =============================================================================================
-- 1 · Unpaid trialing tenants become demo accounts, audited one row each.
-- =============================================================================================
with flipped as (
  update public.businesses b
     set is_demo = true
   where not b.is_demo
     and exists (
       select 1 from public.subscriptions s
        where s.business_id = b.id
          and s.status = 'trialing'
          and coalesce(s.payment_status, 'not_collected') <> 'paid'
     )
  returning b.id
)
insert into public.business_demo_flag_audit_v174(business_id, actor, prior_is_demo, new_is_demo, reason)
select f.id, null, false, true,
       'nestly_v784: owner ruling 2026-09-05 — trials are retired; every unpaid trialing tenant becomes a demo account'
  from flipped f;

-- =============================================================================================
-- 2 · The hot-path predicate: approved and not paused. Money never closes the door.
-- =============================================================================================
create or replace function app.business_operational_v620(p_business uuid)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((
    select control.approval_status = 'approved'
       and not lifecycle.workspace_paused
      from public.business_workspace_controls_v94 control
      join public.business_subscription_lifecycle_v94 lifecycle
        on lifecycle.business_id = control.business_id
     where control.business_id = p_business
  ), false);
$$;
/* Restated from the live proacl: {postgres=X/postgres} — server-only, exactly as v620 left it. */
revoke all on function app.business_operational_v620(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 3 · The readback: the same decision, with names.
-- =============================================================================================
create or replace function app.business_entitlement_v620(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_control public.business_workspace_controls_v94%rowtype;
  v_paused boolean;
  v_demo boolean;
  v_sub public.subscriptions%rowtype;
  v_state text;
  v_reason text;
  v_open boolean := false;
begin
  select * into v_control from public.business_workspace_controls_v94 where business_id = p_business;
  select workspace_paused into v_paused from public.business_subscription_lifecycle_v94 where business_id = p_business;
  select is_demo into v_demo from public.businesses where id = p_business;
  select * into v_sub from public.subscriptions where business_id = p_business;

  if v_control.business_id is null or v_control.approval_status is distinct from 'approved' then
    v_state := 'pending_approval';
    v_reason := 'workspace approval is pending';
  elsif coalesce(v_paused, false) then
    v_state := 'paused';
    v_reason := 'workspace paused by the platform';
  elsif coalesce(v_demo, false) then
    v_state := 'demo';
    v_open := true;
  else
    /* v784: the door is open. The word says what the money is doing, for the console. */
    v_state := case
      when v_sub.business_id is null then 'open_no_subscription'
      when v_sub.payment_status = 'paid'
           and coalesce(v_sub.current_period_end, now()) + interval '14 days' >= now() then 'paid'
      when v_sub.payment_status = 'paid' then 'open_payment_lapsed'
      else 'open_unpaid' end;
    v_open := true;
  end if;

  return jsonb_build_object(
    'business_id', p_business,
    'may_access_workspace', v_open,
    'operational_state', v_state,
    'restriction_reason', v_reason,
    'is_demo', coalesce(v_demo, false),
    'billing_state', v_sub.status,
    'payment_state', v_sub.payment_status,
    'trial_state', null,
    'trial_ends_at', v_sub.trial_ends_at,
    'plan', v_sub.plan_code,
    'cadence', v_sub.billing_cadence,
    'current_period_start', v_sub.current_period_start,
    'current_period_end', v_sub.current_period_end,
    'computed_at', now()
  );
end
$$;
/* Restated from the live proacl: {postgres=X/postgres} — server-only, exactly as v620 left it. */
revoke all on function app.business_entitlement_v620(uuid) from public, anon, authenticated;

comment on function app.business_operational_v620(uuid) is
  'v620 entitlement authority; v784: approved and not paused — money never closes the workspace (owner ruling 2026-09-05).';
comment on function app.business_entitlement_v620(uuid) is
  'v620 entitlement readback; v784: demo / paid / open_* states, is_demo carried; never closes for money.';

commit;
