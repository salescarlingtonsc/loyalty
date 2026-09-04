import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { billingCommandFailureDisposition } from '../../supabase/functions/_shared/billing-command-recovery.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const commandSource = await read('supabase/functions/razorpay-billing-command/index.ts');

/* The dispatch chain is extracted as BLOCKS, not grepped as loose strings: an assertion that
   'cycle_end' appears somewhere in a 560-line file would stay green if it appeared under the
   wrong command. Each block below is the body of exactly one branch of the if/else chain. */
function dispatchBlocks(source) {
  const chainStart = source.indexOf("if (!providerResolved && commandType === 'create_checkout')");
  assert.ok(chainStart > 0, 'command dispatch chain not found');
  const chainEnd = source.indexOf('if (providerConfirmationPending)', chainStart);
  assert.ok(chainEnd > chainStart, 'command dispatch chain end not found');
  const chain = source.slice(chainStart, chainEnd);
  const markers = [
    ['create_checkout', "if (!providerResolved && commandType === 'create_checkout')"],
    ['create_portal', "} else if (!providerResolved && commandType === 'create_portal')"],
    ['change_*', "['change_cadence', 'change_capacity', 'change_branches'].includes(commandType)"],
    ['cancel_at_period_end', "} else if (!providerResolved && commandType === 'cancel_at_period_end')"],
    ['resume', "} else if (!providerResolved && commandType === 'resume')"],
    ['fallthrough', '} else if (!providerResolved) {'],
  ];
  const offsets = markers.map(([name, marker]) => {
    const at = chain.indexOf(marker);
    assert.ok(at >= 0, `dispatch branch missing: ${name}`);
    return [name, at];
  });
  // The chain must be in this order for the slices below to be the branch bodies.
  for (let index = 1; index < offsets.length; index += 1) {
    assert.ok(offsets[index][1] > offsets[index - 1][1], `dispatch branch out of order: ${offsets[index][0]}`);
  }
  return Object.fromEntries(
    offsets.map(([name], index) => [
      name,
      chain.slice(offsets[index][1], index + 1 < offsets.length ? offsets[index + 1][1] : chain.length),
    ]),
  );
}

/* Reads the redirect the command actually builds and resolves it as a URL, so the assertion is
   about the PATH the browser would request rather than about a substring of the source. */
function checkoutUrlPath(source) {
  const template = source.match(/return `\$\{origin\}([^`]*)`;/);
  assert.ok(template, 'checkout redirect template not found');
  return new URL(`https://www.peekaa.asia${template[1]}`.replace(/\$\{[^}]*\}/g, 'x')).pathname;
}

const blocks = dispatchBlocks(commandSource);

test('every billing command type has exactly one dispatch branch and an explicit fallthrough', () => {
  assert.deepEqual(Object.keys(blocks), [
    'create_checkout',
    'create_portal',
    'change_*',
    'cancel_at_period_end',
    'resume',
    'fallthrough',
  ]);
  assert.match(blocks.fallthrough, /throw new Error\('billing command is not executable'\)/);
});

test('create_portal fails with provider_portal_unavailable and never calls Razorpay', () => {
  const block = blocks.create_portal;
  assert.match(block, /p_status: 'failed'/);
  assert.match(block, /p_error_code: 'provider_portal_unavailable'/);
  assert.match(block, /p_redirect_url: null/);
  // Razorpay has no portal, so no provider call may be attempted and no redirect handed back.
  assert.doesNotMatch(block, /razorpay\.\w+\(/);
  assert.doesNotMatch(block, /redirectUrl =/);
  assert.doesNotMatch(block, /providerCallStarted = true/);
});

test('create_checkout sends plan_id + quantity and a total_count Razorpay requires', () => {
  const block = blocks.create_checkout;
  assert.match(block, /createSubscription\(\{/);
  assert.match(block, /plan_id: planId/);
  assert.match(block, /quantity: planUnits/);
  assert.match(block, /total_count: cadence === 'annual' \? TOTAL_COUNT_ANNUAL : TOTAL_COUNT_MONTHLY/);
  assert.match(block, /customer_notify: 0/);
  assert.match(block, /expire_by:/);
  assert.match(block, /notes: subscriptionNotes\(businessId, data, commandId\)/);
  // Razorpay has no Idempotency-Key: the command note is the reuse key, and it is consulted
  // BEFORE anything is created.
  const lookupAt = block.indexOf('findSubscriptionByCommand');
  const createAt = block.indexOf('createSubscription');
  assert.ok(lookupAt > 0 && lookupAt < createAt, 'must look for an existing subscription first');
});

test('a checkout redirect is our own page and is never treated as payment', () => {
  const block = blocks.create_checkout;
  assert.match(block, /redirectUrl = checkoutRedirectUrl\(/);
  // No status/paid/invoice write anywhere on the redirect path.
  assert.doesNotMatch(block, /payment_status|last_paid|amount_paid|'paid'/);
  /* The Vercel Root Directory is `app`, so the page is served from the ORIGIN ROOT. Building
     `/app/razorpay-checkout.html` would hit the `/app` rewrite to the app shell and the checkout
     would never open, so the path is pinned exactly. */
  const built = checkoutUrlPath(commandSource);
  assert.equal(built, '/razorpay-checkout.html');
  assert.doesNotMatch(commandSource, /\/app\/razorpay-checkout\.html/);
  assert.match(commandSource, /\/functions\/v1\/razorpay-billing-return\?cmd=/);
  // The command completes with a redirect only; the money truth is the webhook's.
  assert.match(commandSource, /p_status: 'completed',\s*\n\s*p_provider_object_id: providerObjectId,\s*\n\s*p_redirect_url: redirectUrl,/);

  const returnSource = commandSource; // guard: the command must not import payment truth helpers
  assert.doesNotMatch(returnSource, /apply_razorpay_billing_event_v755|ingest_billing_event_v755/);
});

test('the return function verifies the redirect signature and writes nothing', async () => {
  const source = await read('supabase/functions/razorpay-billing-return/index.ts');
  assert.match(source, /verifyCheckoutSignature\(/);
  assert.match(source, /status: 303/);
  assert.match(source, /reason=signature/);
  // A verified redirect means "Razorpay sent this browser here", not "money moved": the success
  // route is the app's own processing screen, and the function performs no database write.
  assert.match(source, /status=processing/);
  assert.doesNotMatch(source, /billingAdminClient|\.rpc\(|\.from\(|\.insert\(|\.update\(/);
  // Which route the browser lands on comes from Razorpay's own notes, not the query string.
  assert.match(source, /subscription\.notes\?\.self_serve/);
});

test('change_* chooses schedule_change_at by direction and cadence never changes mid-period', () => {
  const block = blocks['change_*'];
  assert.match(block, /updateSubscription\(subscriptionId, \{/);
  assert.match(block, /plan_id: planId/);
  assert.match(block, /quantity: planUnits/);
  assert.match(block, /schedule_change_at: scheduleChangeAt/);
  // A cadence switch mid-period would rebase a period the owner already paid for.
  assert.match(block, /commandType === 'change_cadence'\)\s*\{\s*scheduleChangeAt = 'cycle_end';/);
  // v665 direction rule: fewer units take effect at cycle end (no refund), more units start now.
  assert.match(
    block,
    /commandType === 'change_branches'\)\s*\{\s*scheduleChangeAt = planUnits < Number\(current\.quantity \|\| 0\) \? 'cycle_end' : 'now';/,
  );
  // Only the capacity model treats a still-scheduled change as unconfirmed.
  assert.match(block, /providerConfirmationPending = capacityModel && verified\.has_scheduled_changes === true/);
  assert.match(block, /subscriptionMatchesCommandV755\(verified, commandType, planId, planUnits\)/);
});

test('cancel is cycle-end and resume refuses what Razorpay cannot do', () => {
  assert.match(blocks.cancel_at_period_end, /cancelSubscription\(subscriptionId, 1\)/);
  const resume = blocks.resume;
  assert.match(resume, /String\(current\.status\) === 'paused'/);
  assert.match(resume, /resumeSubscription\(subscriptionId\)/);
  assert.match(resume, /p_error_code: 'provider_resume_unavailable'/);
  assert.match(resume, /p_status: 'failed'/);
});

test('the plan is validated against the reviewed catalogue before any subscription is created', () => {
  const validateAt = commandSource.indexOf('await validateV755Plan(');
  const createAt = commandSource.indexOf('await razorpay.createSubscription(');
  assert.ok(validateAt > 0 && validateAt < createAt);
  assert.match(commandSource, /Razorpay plans do not match the reviewed catalogue/);
  assert.match(commandSource, /Peekaa is not GST-registered; catalogue tax behavior must be exclusive/);
  assert.match(commandSource, /RAZORPAY_PLAN_MAP_JSON/);
  // A Razorpay subscription carries ONE plan, so a catalogue row still asking for a second
  // priced item must be refused rather than silently under-charged.
  assert.match(commandSource, /Razorpay subscriptions carry one plan/);
});

test('planUnits is base coverage plus billable branches, floored at one', () => {
  assert.match(commandSource, /planUnits = Math\.max\(1, baseUnits \+ branchUnits\)/);
  assert.match(commandSource, /\.in\('billing_state', \['pending_payment', 'active'\]\)/);
  assert.match(commandSource, /provider_covers_base_unit/);
  // Fail closed: an unreadable branch count must never over-charge.
  assert.match(commandSource, /branchUnits = !branchError && typeof count === 'number'/);
});

test('the claim/complete contract and its disposition rules are unchanged', () => {
  assert.match(commandSource, /claim_billing_command_v130/);
  assert.match(commandSource, /p_command: commandId,\s*\n\s*p_actor: actor,/);
  assert.match(commandSource, /complete_billing_command_v77/);
  for (const parameter of [
    'p_command',
    'p_status',
    'p_provider_object_id',
    'p_redirect_url',
    'p_error_code',
    'p_error_message',
  ]) {
    assert.ok(commandSource.includes(`${parameter}:`), `missing completion parameter ${parameter}`);
  }
  assert.match(commandSource, /billingCommandFailureDisposition\(\{/);
  assert.match(commandSource, /error instanceof RazorpayApiError &&\s*\n?\s*error\.nonExecutionProven/);
  assert.match(commandSource, /p_error_code: 'provider_confirmation_pending'/);
  assert.match(commandSource, /'provider_result_uncertain'/);

  // Executed, not grepped: a started call with no proof of non-execution is uncertain.
  assert.equal(
    billingCommandFailureDisposition({ providerCallStarted: false, nonExecutionProven: false }),
    'failed',
  );
  assert.equal(
    billingCommandFailureDisposition({ providerCallStarted: true, nonExecutionProven: true }),
    'failed',
  );
  assert.equal(
    billingCommandFailureDisposition({ providerCallStarted: true, nonExecutionProven: false }),
    'uncertain',
  );
});

test('the return origin is validated and the success/cancel routes are unchanged', () => {
  assert.match(commandSource, /configured\.protocol !== 'https:'/);
  assert.match(commandSource, /configured\.pathname !== '\/'/);
  assert.match(commandSource, /BILLING_RETURN_ORIGIN/);
  assert.match(commandSource, /\/business#\/onboarding\/payment\?status=processing/);
  assert.match(commandSource, /\/business#\/onboarding\/payment\?status=canceled/);
  assert.match(commandSource, /\/#\/settings\?billing=processing/);
  assert.match(commandSource, /\/#\/settings\?billing=canceled/);
});

test('the checkout page loads Razorpay under its own CSP and carries no secret', async () => {
  const page = await read('app/razorpay-checkout.html');
  assert.match(page, /script-src 'self' https:\/\/checkout\.razorpay\.com/);
  assert.match(page, /frame-src https:\/\/api\.razorpay\.com https:\/\/checkout\.razorpay\.com/);
  assert.match(page, /connect-src https:\/\/lumberjack\.razorpay\.com https:\/\/api\.razorpay\.com/);
  assert.match(page, /src="https:\/\/checkout\.razorpay\.com\/v1\/checkout\.js"/);
  assert.match(page, /Pay securely with Razorpay/);
  /* The CSP grants no 'unsafe-inline', so the opener MUST live in an external same-origin file.
     The first live run shipped it inline and the page sat on "Opening Razorpay…" forever. */
  assert.doesNotMatch(page, /<script>/, 'no inline <script> block: the CSP would block it');
  assert.match(page, /<script src="\/razorpay-checkout\.js"><\/script>/);
  assert.match(page, /script-src 'self' https:\/\/checkout\.razorpay\.com https:\/\/cdn\.razorpay\.com/);
  const opener = await read('app/razorpay-checkout.js');
  assert.match(opener, /subscription_id: subscriptionId/);
  assert.match(opener, /redirect: true/);
  assert.doesNotMatch(page + opener, /key_secret|KEY_SECRET|rzp_(?:test|live)_/);
  // app/index.html's CSP must not be widened for a third-party payment script.
  const app = await read('app/index.html');
  assert.doesNotMatch(app, /razorpay/i);
});

test('the config declares the four Razorpay functions and no Stripe function survives', async () => {
  const config = await read('supabase/config.toml');
  assert.match(config, /\[functions\.razorpay-billing-webhook\]\nverify_jwt = false/);
  assert.match(config, /\[functions\.razorpay-billing-command\]\nverify_jwt = true/);
  assert.match(config, /\[functions\.razorpay-billing-reconcile\]\nverify_jwt = false/);
  assert.match(config, /\[functions\.razorpay-billing-return\]\nverify_jwt = false/);
  assert.doesNotMatch(config, /\[functions\.stripe-/);
});

test('reconciliation keeps the run/finish contract and stays scoped to the Razorpay provider', async () => {
  const source = await read('supabase/functions/razorpay-billing-reconcile/index.ts');
  assert.match(source, /start_billing_reconciliation_v77/);
  assert.match(source, /finish_billing_reconciliation_v77/);
  assert.match(source, /x-nestly-reconciliation-secret/);
  assert.match(source, /drainBoundedKeysetPages/);
  assert.match(source, /drainBoundedOffsetPages/);
  // Stripe history rows stay in these tables; asking Razorpay about a sub_... id would report
  // every one of them missing forever.
  const providerFilters = source.match(/\.eq\('provider', PROVIDER\)/g) || [];
  assert.ok(providerFilters.length >= 4, 'every local projection must be provider-scoped');
  assert.match(source, /const PROVIDER = 'razorpay'/);
  assert.match(source, /razorpayStatusToLocalV755/);
});

test('the deployed CSP header for the checkout page matches the page meta exactly', async () => {
  const page = await read('app/razorpay-checkout.html');
  const meta = page.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)"/);
  assert.ok(meta, 'checkout page must carry a meta CSP');

  /* app/vercel.json is GENERATED from config/runtime/vercel.template.json, so both must carry
     the entry or the next `runtime-config:check` reverts it. A header CSP and a meta CSP are
     BOTH enforced and the browser applies their INTERSECTION: if the site-wide header (which
     admits no Razorpay origin) were the only one in force on this path, checkout.js would be
     blocked and the page would render a dead button. */
  for (const file of ['app/vercel.json', 'config/runtime/vercel.template.json']) {
    const config = JSON.parse(await read(file));
    const sources = config.headers.map((entry) => entry.source);
    const index = sources.indexOf('/razorpay-checkout.html');
    assert.ok(index >= 0, `${file} must set a CSP for /razorpay-checkout.html`);
    // Vercel applies a LATER matching entry over an earlier one for the same header key.
    assert.ok(index > sources.indexOf('/(.*)'), `${file}: the page CSP must come after /(.*)`);
    const value = config.headers[index].headers.find(
      (header) => header.key === 'Content-Security-Policy',
    )?.value;
    assert.equal(value, meta[1]);
    // The site-wide CSP must not be widened for a third-party payment script.
    const siteWide = config.headers[sources.indexOf('/(.*)')].headers.find(
      (header) => header.key === 'Content-Security-Policy',
    ).value;
    assert.doesNotMatch(siteWide, /razorpay/i);
  }
  for (const directive of [
    "script-src 'self' https://checkout.razorpay.com",
    'frame-src https://api.razorpay.com https://checkout.razorpay.com',
    'connect-src https://lumberjack.razorpay.com https://api.razorpay.com',
    "frame-ancestors 'none'",
  ]) {
    assert.ok(meta[1].includes(directive), `checkout CSP is missing: ${directive}`);
  }
});
