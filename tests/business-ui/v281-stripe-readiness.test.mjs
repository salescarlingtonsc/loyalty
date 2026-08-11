/* V281 — end-to-end Stripe readiness for the first paying customer (2026-08-12).

   There is no live company yet, so nothing on the paid-signup path has ever been exercised by a
   real card. Walking it against production found three defects that would each have been
   discovered by the FIRST customer, one of them silently, plus a checkout button with an
   undefined fourth state. This file pins the FIXED shape of each, because every one of them is
   invisible to a screenshot and none of them shows up until money has already moved:

     * dunning cannot start for a card subscription, because Stripe leaves the invoice due date
       null for collection_method='charge_automatically' and the daily sweep required it;
     * a paid workspace stays locked forever when Stripe delivers invoice.paid before
       customer.subscription.created, because the first-paid capture is evaluated exactly once
       and there is no trigger on the other side;
     * the self-service activation seed is ungated, so a preset that cannot be written rolls back
       the invoice.paid transaction that is meant to open the workspace (the V277 lesson, applied
       to the one activation path V277 did not touch);
     * the owner-facing checkout button never performed the retry the server itself documents for
       an `uncertain` execution, so an owner with a live Stripe session was told to wait instead.

   It also pins the two owner-requested items that ride along: the bar sector gaining `packages`,
   and the removal of the retired duplicate reward — including the part of that removal that is
   NOT a plain delete, because the reward's versions belong to published configurations that
   app.reward_version_immutable_guard is right to protect. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260812_nestly_v281_stripe_launch_readiness.sql'), 'utf8');
const suite = readFileSync(join(root, 'db', 'tests', 'v281_stripe_launch_readiness.sql'), 'utf8');
const webhook = readFileSync(
  join(root, 'supabase', 'functions', 'stripe-billing-webhook', 'index.ts'), 'utf8');
const command = readFileSync(
  join(root, 'supabase', 'functions', 'stripe-billing-command', 'index.ts'), 'utf8');

const checkoutExecutor = app.slice(
  app.indexOf('async function runSelfServeCheckoutV281('),
  app.indexOf('function renderBusinessWorkspaceControl('));
assert.ok(checkoutExecutor.length > 200, 'the V281 checkout executor must be locatable');

/* ---------------------------------------------------------------------------------------------
   1. Dunning must be able to start for a card subscription.
   --------------------------------------------------------------------------------------------- */

test('V281 the overdue anchor falls back to finalization, because Stripe gives card invoices no due date', () => {
  assert.match(migration,
    /create or replace function app\.billing_due_anchor_v281\(\s*p_invoice public\.billing_provider_invoices\s*\)/);
  assert.match(migration,
    /select coalesce\(\(p_invoice\)\.due_at,\(p_invoice\)\.finalized_at\)/,
    'due_at must still win wherever Stripe supplies it; finalization only stands in');
});

test('V281 both lifecycle functions are rewritten from their DEPLOYED source, with the hit count asserted', () => {
  const block = migration.slice(migration.indexOf('do $v281_dunning$'),
    migration.indexOf('$v281_dunning$;'));
  assert.match(block, /'app\.run_subscription_lifecycle_v94\(date\)'/,
    'the daily sweep is the function that produces notices, grace and the day-14 pause');
  assert.match(block, /'app\.reconcile_subscription_payment_v94\(uuid,text,text,uuid,boolean\)'/,
    'the reconciler carries the same predicate and would report false recoveries');
  assert.match(block, /pg_get_functiondef/,
    'a settled live-path function is spliced from its own deployed source, never retyped');
  assert.match(block, /v_expected_hits constant integer\[\] := array\[4,2\]/,
    'the exact number of due_at references is pinned so a drifted function aborts the migration');
  assert.match(block, /if v_hits <> v_expected then\s*\n\s*raise exception/,
    'a mismatched needle count must abort, not patch partially');
  assert.match(block, /if position\(v_needle in v_source\) > 0 then\s*\n\s*raise exception/,
    'the DEPLOYED definition must be re-read and proved free of raw due_at');
  assert.match(block, /if position\(v_patch in v_source\) > 0 then[\s\S]{0,120}?continue;/,
    're-running must be safe');
});

test('V281 the rollback suite reproduces the card-invoice defect rather than only asserting the fix', () => {
  assert.match(suite, /pg_temp\.v281_anchor\(null, v_now - interval '20 days'\) is null/,
    'the suite must show a charge_automatically invoice previously had no anchor at all');
  assert.match(suite, /pg_temp\.v281_anchor\(v_now - interval '3 days', v_now - interval '20 days'\)\s*\n?\s*<> v_now - interval '3 days'/,
    'a send_invoice tenant’s existing clock must be proved unmoved');
  assert.match(suite, /pg_temp\.v281_anchor\(null, null\) is not null/,
    'no evidence must still mean no dunning: the sweep may never invent an overdue state');
  assert.match(suite, /v_day>=14/,
    'the day-14 pause must be proved still present in the rewritten sweep');
});

/* ---------------------------------------------------------------------------------------------
   2. An out-of-order webhook must not strand a paid workspace.
   --------------------------------------------------------------------------------------------- */

test('V281 the first-paid capture is replayed from the terms side, since Stripe does not order webhooks', () => {
  assert.match(migration, /create or replace function app\.v281_capture_first_paid_from_terms\(\)/);
  assert.match(migration,
    /create trigger billing_terms_first_paid_replay_v281\s*\n\s*after insert or update of provider_subscription_id, provider_event_created_at\s*\n\s*on public\.billing_subscription_terms_v124/,
    'the missing link is a trigger on the terms table, which had none');
  /* The branch that chooses v144 evidence over the v124 money-back window is copied verbatim
     from app.capture_money_back_window_v124; if the two ever disagree, one of the two paths
     silently writes to the wrong table and activation stops. */
  assert.match(migration, /if v_legal_version>='2026-08-03' then/);
  assert.match(migration, /insert into public\.billing_first_paid_evidence_v144\(/);
  assert.match(migration, /insert into public\.billing_money_back_windows_v124\(/);
  assert.match(migration, /order by invoice\.paid_at asc, invoice\.provider_invoice_id asc/,
    'the FIRST paid invoice is the activation evidence, so ordering is load-bearing');
  assert.match(migration,
    /where excluded\.first_paid_at\s*\n\s*< billing_first_paid_evidence_v144\.first_paid_at/,
    'the immutable evidence may only ever move earlier, matching the v144 guard');
});

test('V281 the existing invoice-side capture is left untouched', () => {
  assert.doesNotMatch(migration, /create or replace function app\.capture_money_back_window_v124/,
    'the invoice-side trigger already works in the happy order; V281 adds a second door only');
});

test('V281 the suite proves the interleaving, not just the trigger', () => {
  /* V281 courier correction: the original single $v281_2$ block was unsatisfiable as written
     (no onboarding row -> the ELSE branch), so the suite was split into 2a/2b/2c with the
     intermediate no-evidence state asserted inline. The pin follows the corrected shape: the
     paid invoice is still stored BEFORE the terms row, the pre-terms state is asserted to hold
     ZERO evidence, and the fixture still uses the collection method our Checkout produces. */
  assert.ok(suite.indexOf('insert into public.billing_provider_invoices(')
    < suite.indexOf('insert into public.billing_subscription_terms_v124('),
    'the paid invoice must be stored BEFORE the terms, which is the failing order');
  assert.match(suite, /if v_captured <> 0 or v_money_back <> 0 then/,
    'the intermediate state must be asserted, or the test proves nothing about ordering');
  assert.match(suite, /'charge_automatically'/,
    'the fixture must be the collection method our own Checkout sessions produce');
});

/* ---------------------------------------------------------------------------------------------
   3. The activation seed must not be able to roll back the payment that triggered it.
   --------------------------------------------------------------------------------------------- */

test('V281 the self-service activation seed gets the V277 gate the other two paths already have', () => {
  const block = migration.slice(migration.indexOf('do $v281_activation$'),
    migration.indexOf('$v281_activation$;'));
  assert.match(block, /'app\.activate_self_serve_paid_v130\(\)'/);
  assert.match(block, /if app\.c45_owner_loyalty_write\(new\.business_id\) then/,
    'the gate is the guard’s own predicate, so nothing is weakened by adding it');
  assert.match(block, /if v_hits <> 1 then\s*\n\s*raise exception/);
  assert.match(block, /if position\(v_gate in v_source\) > 0 then[\s\S]{0,120}?return;/,
    're-running must be safe');
  assert.match(block, /if position\('insert into public\.loyalty_programs\(' in v_source\) = 0 then\s*\n\s*raise exception/,
    'the verification must prove the seed SURVIVED the splice, not just that the gate landed');
});

/* ---------------------------------------------------------------------------------------------
   4. The checkout button has three defined outcomes and no fourth.
   --------------------------------------------------------------------------------------------- */

test('V281 an uncertain execution is retried with the SAME command id, as the server documents', () => {
  assert.match(checkoutExecutor,
    /if\(!result\?\.redirect_url&&\['uncertain','pending','processing'\]\.includes\(String\(result\?\.status\|\|''\)\)\)\{/,
    'a 202 uncertain response carries no redirect_url and is exactly the recoverable case');
  assert.match(checkoutExecutor,
    /const recovered=await sb\.functions\.invoke\('stripe-billing-command',\{body:\{command_id:commandId\}\}\)/,
    'recovery is retry_same_command_id: a new command id would be a second Stripe session');
  const replays = checkoutExecutor.match(/sb\.functions\.invoke\('stripe-billing-command'/g) || [];
  assert.equal(replays.length, 2,
    'exactly one replay: the command holds a stable Stripe idempotency key, but a loop is not a retry policy');
});

test('V281 every non-redirect outcome re-enables the button and names what to do next', () => {
  assert.match(app, /const SELF_SERVE_CHECKOUT_STATUS_V281=Object\.freeze\(\{/);
  for (const key of ['opening', 'request_failed', 'unreachable', 'pending']) {
    assert.match(app, new RegExp(`${key}:'`), `the ${key} outcome must have a named message`);
  }
  assert.match(app, /pending:'Stripe has not returned a checkout page yet\. Retry/,
    'the terminal message must tell the owner to retry, not to wait for a webhook that will never come');
  assert.match(checkoutExecutor + app.slice(app.indexOf('async function driveSelfServeCheckoutV281(')),
    /if\(button\)button\.disabled=false;/,
    'a disabled button with a pending message is the stuck state this executor exists to remove');
  assert.match(app,
    /const outcome=await runSelfServeCheckoutV281\(onboarding\);\s*\n\s*if\(outcome\.outcome==='redirect'\)\{location\.assign\(outcome\.redirectUrl\);return outcome\}/,
    'redirect is the only outcome that leaves the page');
});

test('V281 both self-service surfaces run the one executor, so the two copies cannot drift again', () => {
  const calls = app.match(/driveSelfServeCheckoutV281\(/g) || [];
  assert.equal(calls.length, 3,
    'one definition plus exactly two call sites: the workspace-control screen and the onboarding screen');
  assert.match(app,
    /\$\('businessControlPay'\)\.onclick=\(\)=>driveSelfServeCheckoutV281\(/,
    'the workspace-control payment screen must use the shared executor');
  assert.match(app,
    /const finishCheckout=\(onboarding,statusNode,button\)=>\s*\n?\s*driveSelfServeCheckoutV281\(onboarding,statusNode,button\);/,
    'the onboarding screen must use the shared executor');
  /* The old hand-rolled copies each built their own idempotency key inline. One helper now owns
     the sessionStorage key, so a second key can never mint a second Stripe session. */
  const inlineKeys = app.match(/nestly-self-serve-checkout-\$\{/g) || [];
  assert.equal(inlineKeys.length, 1, 'exactly one place may compute the checkout idempotency key');
});

test('V281 the poll that waits for provider confirmation is unchanged and still terminates', () => {
  assert.match(app, /if\(attempts<15\)setTimeout\(poll,2000\)/,
    'the processing poll must stay bounded: an infinite poll is another way to be stuck');
  assert.match(app, /Stripe has not confirmed activation yet\. Use Check payment again/,
    'the poll must end on an instruction, not on silence');
});

/* ---------------------------------------------------------------------------------------------
   5. Mode safety at the webhook.
   --------------------------------------------------------------------------------------------- */

test('V281 the webhook refuses an event whose livemode does not match the API key mode', () => {
  assert.match(webhook, /function expectedLivemode\(secretKey: string\): boolean \| null/);
  assert.match(webhook, /secretKey\.startsWith\('sk_live_'\)/);
  assert.match(webhook, /secretKey\.startsWith\('sk_test_'\)/);
  assert.match(webhook,
    /if \(wantLivemode !== null && event\.livemode !== wantLivemode\) \{/,
    'going live is a two-secret change; half-done is otherwise silent');
  assert.match(webhook, /error: 'livemode_mismatch'/);
  /* The check must run BEFORE ingestion: a mode-mismatched event must never become production
     billing evidence, and 400 stops Stripe from resending something that cannot become correct. */
  assert.ok(webhook.indexOf("error: 'livemode_mismatch'")
    < webhook.indexOf('ingest_stripe_billing_event_v77'),
    'the mismatch must be rejected before the durable inbox write');
  assert.match(webhook, /return billingJson\(400, \{\s*\n\s*error: 'livemode_mismatch'/);
});

test('V281 an unrecognised key prefix disables the check rather than the webhook', () => {
  assert.match(webhook, /return null;\n\}/,
    'a restricted or future key format must not brick payment processing');
  assert.match(webhook, /wantLivemode !== null &&/);
});

test('V281 the signed-webhook contract around the check is untouched', () => {
  assert.match(webhook, /constructEventAsync\(/);
  assert.match(webhook, /requiredEnv\('STRIPE_WEBHOOK_SECRET'\)/);
  assert.match(webhook, /StripeSignatureVerificationError/);
  assert.match(command, /automatic_tax: \{ enabled: false \}/,
    'Peekaa is not GST-registered; the checkout must still create no tax');
});

/* ---------------------------------------------------------------------------------------------
   6. The operational safety net.
   --------------------------------------------------------------------------------------------- */

test('V281 stranded provider events are re-driven on a schedule, bounded, and never by a browser', () => {
  assert.match(migration,
    /create or replace function app\.v281_redrive_failed_billing_events\(p_limit integer default 200\)/);
  assert.match(migration, /if p_limit is null or p_limit < 1 or p_limit > 1000 then/,
    'an unbounded redrive would replay the whole inbox in one transaction');
  assert.match(migration, /processing_status='failed'/);
  assert.match(migration, /received_at < now\(\)-interval '10 minutes'/,
    'an event stuck in processing is as stranded as a failed one');
  assert.match(migration, /v_result := public\.apply_stripe_billing_event_v77\(v_event\.event_id\)/,
    'the redrive must call the same applier the webhook calls, so outcomes cannot diverge');
  assert.match(migration,
    /revoke all on function app\.v281_redrive_failed_billing_events\(integer\)\s*\n\s*from public,anon,authenticated;/);
  assert.match(migration, /'nestly-v281-billing-event-redrive','\*\/5 \* \* \* \*'/);
  assert.match(migration, /if exists\(select 1 from cron\.job where jobname='nestly-v281-billing-event-redrive'\) then/,
    'cron.unschedule raises when the job is absent, so re-running must stay safe');
});

/* ---------------------------------------------------------------------------------------------
   7. Owner-requested items riding along.
   --------------------------------------------------------------------------------------------- */

test('V281 bar gains packages by publishing v2 and retiring v1, and existing bar tenants move with it', () => {
  const block = migration.slice(migration.indexOf('do $v281_bar$'), migration.indexOf('$v281_bar$;'));
  assert.match(block, /v_modules := v_v1\.modules \|\| array\['packages'\]::text\[\]/,
    'v2 must be v1 plus one module, derived from v1 rather than retyped');
  assert.match(block, /set status='retired', retired_at=now\(\)/,
    'sector_bundle_versions_status_time_check requires retired_at alongside the retired status');
  assert.match(block, /values\('bar',2,'Bar core',v_modules,'published',now\(\)\)/);
  assert.match(block, /if not v_v1\.modules @> array\['services'\]::text\[\] then/,
    'module_registry says packages requires services; publishing without it would be rewritten away');
  assert.match(block, /app\.resolve_sector_entitlement_v75\(v_v2\.id,'\{\}','\{\}'\)/,
    'the effective module list must come from the same resolver every other assignment uses');
  assert.match(block, /perform set_config\('app\.sector_entitlement_sync', v_business\.business_id::text, true\)/,
    'app.business_sector_modules_guard_v75 locks enabled_modules; this is its sanctioned key');
  assert.match(block, /perform set_config\('app\.sector_entitlement_sync','',true\)/,
    'the sync key must be cleared again, not left open for the rest of the transaction');
  assert.match(block, /raise exception 'v281: a bar tenant is still assigned to the retired v1 bundle'/,
    'a tenant left on a retired bundle is entitled to a bundle nobody can be assigned');
});

test('V281 the duplicate reward removal states every precondition and aborts on any of them', () => {
  const block = migration.slice(migration.indexOf('do $v281_reward$'),
    migration.indexOf('$v281_reward$;'));
  assert.match(block, /v_reward constant uuid := '95f12d05-2d00-443c-9844-e7a5d62a2423'/);
  assert.match(block, /raise notice 'v281: reward % is already removed - skipped'/,
    'idempotent: a re-run must not fail on an absent row');
  assert.match(block, /if v_row\.active then\s*\n\s*raise exception/,
    'an active reward must never be deleted by a migration');
  assert.match(block, /no surviving active twin of reward/,
    'the point is to remove a duplicate; with no twin it is not a duplicate');
  for (const table of ['loyalty_redemptions', 'customer_redemption_intents_v89', 'loyalty_operations']) {
    assert.ok(block.includes(table), `${table} must be checked before deleting`);
  }
  assert.match(block, /carries customer history - refusing to delete/);
});

test('V281 the removal suspends the immutability guard deliberately, narrowly, and with evidence', () => {
  const block = migration.slice(migration.indexOf('do $v281_reward$'),
    migration.indexOf('$v281_reward$;'));
  /* This is not a plain delete: 4 of the reward's 6 version rows belong to published or
     superseded configurations, which app.reward_version_immutable_guard is right to protect. */
  assert.match(block,
    /alter table public\.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_immutable;/);
  assert.match(block,
    /alter table public\.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_immutable;/);
  const off = block.indexOf('disable trigger trg_loyalty_reward_versions_immutable');
  const on = block.indexOf('enable trigger trg_loyalty_reward_versions_immutable');
  assert.ok(off < on, 'the guard must be re-enabled inside the same transaction');
  assert.ok(block.indexOf('delete from public.loyalty_rewards where id=v_reward') < on,
    'both deletes must happen inside the suspension window');
  /* Removing a member from a published configuration rewrites its snapshot_hash. That rewrite
     must be recorded, not silent. */
  assert.match(block, /'config_snapshots_before',coalesce\(v_before,'\[\]'::jsonb\)/);
  assert.match(block, /'config_snapshots_after',coalesce\(v_after,'\[\]'::jsonb\)/);
  assert.match(block, /'LOYALTY_REWARD_DUPLICATE_REMOVED_V281'/);
  assert.match(suite, /trigger_row\.tgenabled <> 'D'/,
    'the acceptance suite must prove the guard is back on afterwards');
});
