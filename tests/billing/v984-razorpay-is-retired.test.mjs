/* nestly_v984 — Razorpay is retired. These tests hold the SOURCE side of that ruling: the
   migration holds the data side, and db/tests/v984_razorpay_is_retired.sql proves the constraint
   against production.

   Owner, 2026-09-16: "i am only using stripe, no more razor pay".

   Two things are asserted, and the split matters. What is FORBIDDEN is the app or an edge function
   starting a NEW Razorpay interaction. What is KEPT is the historical record — the v755..v798
   migrations, the shared client modules that other providers' code still imports, and every
   billing_provider_events row. A test that simply banned the string would be red on the history,
   and someone would delete the history to make it green. */

import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(ROOT, p), 'utf8');

test('v984: the app never invokes a razorpay edge function', () => {
  const app = read('app/app.js');
  const invoked = [...app.matchAll(/functions\.invoke\(\s*'([^']+)'/g)].map((m) => m[1]);
  const razorpay = invoked.filter((name) => name.includes('razorpay'));
  assert.deepEqual(
    razorpay,
    [],
    `app.js invokes razorpay edge functions: ${razorpay.join(', ')}. The platform bills through ` +
      'Stripe (app.platform_billing_provider_v792); nothing may open a Razorpay command.',
  );
  /* Positive control: the assertion above would also pass on an app.js that invokes nothing at
     all, which is exactly how this test could rot into meaninglessness. */
  assert.ok(
    invoked.includes('stripe-billing-command'),
    'app.js no longer invokes stripe-billing-command — the check above has stopped meaning anything',
  );
});

test('v984: the Razorpay checkout page is gone from the shipped app', () => {
  for (const orphan of ['app/razorpay-checkout.js', 'app/razorpay-checkout.html']) {
    assert.equal(
      existsSync(join(ROOT, orphan)),
      false,
      `${orphan} still ships. It exists only to open Razorpay's payment sheet, and nothing routes ` +
        'to it any more.',
    );
  }
});

test('v984: no deploy route or CSP allowance points at Razorpay', () => {
  for (const manifest of ['app/vercel.json', 'config/runtime/vercel.template.json']) {
    const text = read(manifest);
    assert.equal(
      /razorpay/i.test(text),
      false,
      `${manifest} still names razorpay. A route or a script-src allowance for checkout.razorpay.com ` +
        'is a live path to a retired provider.',
    );
  }
});

test('v984: the migration that retires Razorpay asserts sandbox-only before it writes', () => {
  const sql = read('supabase/migrations/20261018000000_nestly_v984_razorpay_is_retired.sql');
  /* The re-point is only defensible because no live-mode event was ever recorded. If someone
     loosens that assertion later, the migration stops being a cleanup and becomes a billing
     change, so the guard is held here as well as in the file. */
  assert.match(
    sql,
    /livemode is true/,
    'the migration no longer refuses to run when a live-mode razorpay event exists',
  );
  assert.match(
    sql,
    /array\['manual'::text, 'stripe'::text\]/,
    'the migration no longer narrows subscriptions.billing_provider to manual/stripe',
  );
});

test('v984: the history is deliberately kept, not deleted', () => {
  /* The v755 migration is the record of how Razorpay was built. It must stay readable: a replayed
     migration chain needs it, and the estate's 34 sandbox events were written by it. */
  assert.ok(
    existsSync(join(ROOT, 'supabase/migrations/20260925000000_nestly_v755_razorpay_billing.sql')),
    'the v755 razorpay migration was deleted — the migration chain cannot replay without it',
  );
  /* CORRECTION (same day, after the four razorpay-* edge functions were undeployed). v984 first
     justified keeping these modules by claiming stripe-billing-reconcile and whatsapp-webhook
     import from _shared/razorpay-*.ts. They do not. Both name Razorpay only in COMMENTS, and
     _shared/billing-payment-method-backfill.ts takes a `razorpay` client as an injected PARAMETER
     rather than importing one. Checked by import, not by mentioning the word:

       grep -rn "from ['\"].*razorpay" supabase/functions/

     answers with exactly two lines, and both are razorpay modules importing each other. Nothing
     Stripe touches them. The original comment would have told a future reader that live Stripe code
     depends on dead code, which is the opposite of true and exactly the kind of claim that costs
     somebody an afternoon.

     They are kept anyway, for the reason that IS true: supabase/functions/razorpay-billing-* is
     still in the tree so an undeploy stays reversible with `supabase functions deploy <name>`, and
     these five modules are what those four functions import. Delete them and the undo is gone. So
     the assertion stands and only its reason changes. */
  assert.ok(
    existsSync(join(ROOT, 'supabase/functions/_shared/razorpay-client.ts')),
    '_shared/razorpay-client.ts was deleted — the four razorpay-billing-* functions kept in this '
      + 'tree import it, and without it undeploying them stops being reversible',
  );
  /* The positive control for the sentence above: the functions this exists to keep redeployable. */
  for (const fn of ['webhook', 'return', 'reconcile', 'command']) {
    assert.ok(
      existsSync(join(ROOT, `supabase/functions/razorpay-billing-${fn}/index.ts`)),
      `supabase/functions/razorpay-billing-${fn} was deleted, so _shared/razorpay-*.ts now has no `
        + 'importer at all — either restore it or remove the shared modules with it',
    );
  }
});
