/* nestly_v988 — a shipped surface may only invoke an edge function that still exists and is still ours.
 *
 * WHY THIS EXISTS. On 2026-09-16 the four razorpay-* edge functions were undeployed as retired. The
 * owner's own Billing page in app/app.js had invoked 'stripe-billing-command' since the provider
 * swap, so it was fine. app/platform-console.js had NOT been switched: two of its three billing
 * invokes still named 'razorpay-billing-command', while a third (line ~9034) already named the
 * Stripe one — the file disagreed with itself. The moment the functions were deleted, every billing
 * action in the super-admin console 404'd, and it did so AFTER request_billing_command_v124 had
 * written a status='pending' row that nothing could then claim or complete. The console became a
 * factory for exactly the orphaned commands it exists to resolve.
 *
 * Nothing caught it because no test connected "what the browser calls" to "what we still ship". A
 * grep for the word razorpay would not have either: platform-console.js legitimately mentions
 * Razorpay a dozen times, in merchant-facing copy and in comments explaining why a Razorpay firm
 * could never take a promo code. What is checkable is narrower: the STRING PASSED TO
 * functions.invoke.
 */

import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

/* The surfaces a browser actually loads. The generated bundles are excluded: they are stamped
   copies of app.js and would double-report the same call site. */
const SHIPPED_SURFACES = ['app/app.js', 'app/platform-console.js'];

function functionsInRepo() {
  const dir = join(ROOT, 'supabase', 'functions');
  return new Set(
    readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith('_'))
      .filter((entry) => existsSync(join(dir, entry.name, 'index.ts')))
      .map((entry) => entry.name),
  );
}

/* Literal single-quoted slugs, plus one level of constant resolution — which is what the fix itself
   introduced (BILLING_EXECUTOR_V988), so the constant is checked rather than skipped. */
function invokedSlugs(source) {
  const literal = [...source.matchAll(/functions\??\.invoke\(\s*'([^']+)'/g)].map((m) => m[1]);
  const viaConst = [...source.matchAll(/functions\??\.invoke\(\s*([A-Za-z_$][\w$]*)\s*,/g)].map((m) => m[1]);
  const resolved = viaConst.map((name) => {
    const decl = source.match(new RegExp(`\\b(?:const|let|var)\\s+${name}\\s*=\\s*'([^']+)'`));
    return decl ? decl[1] : `<unresolved:${name}>`;
  });
  return [...literal, ...resolved];
}

test('v988: every edge function a shipped surface invokes exists in this repo', () => {
  const shipped = functionsInRepo();
  assert.ok(shipped.size > 0, 'no edge functions found — the discovery is broken, not the app');

  const offenders = [];
  for (const surface of SHIPPED_SURFACES) {
    const source = readFileSync(join(ROOT, surface), 'utf8');
    for (const slug of invokedSlugs(source)) {
      if (slug.startsWith('<unresolved:')) {
        offenders.push(`${surface} invokes ${slug} — the slug could not be resolved to a literal`);
      } else if (!shipped.has(slug)) {
        offenders.push(`${surface} invokes '${slug}', which is not a function in supabase/functions/`);
      }
    }
  }
  assert.deepEqual(offenders, [], 'a shipped surface calls an edge function this repo does not ship:\n  ' + offenders.join('\n  '));
});

test("v988: no shipped surface invokes a retired provider's executor", () => {
  /* The repo-presence test above CANNOT catch the bug this file was written for, and saying so is
     better than a false sense of coverage. nestly_v985 deliberately KEPT
     supabase/functions/razorpay-billing-* in the tree so the undeploy stays reversible with
     `supabase functions deploy <name>`. So the directory is still here while the function is absent
     from production — exactly the gap a repo-only check reads as fine. nestly_v984 retired the
     provider; this asserts that ruling: retired means nothing the browser loads may call it,
     whatever is still on disk for recovery. */
  const RETIRED = /^razorpay-/;
  const offenders = [];
  for (const surface of SHIPPED_SURFACES) {
    const source = readFileSync(join(ROOT, surface), 'utf8');
    for (const slug of invokedSlugs(source)) {
      if (RETIRED.test(slug)) offenders.push(`${surface} invokes '${slug}'`);
    }
  }
  assert.deepEqual(
    offenders,
    [],
    'a shipped surface calls a retired Razorpay executor. Those four functions were undeployed on '
      + '2026-09-16 (nestly_v984/v985); their source is kept only so the undeploy stays reversible:\n  '
      + offenders.join('\n  '),
  );
});

test('v988: the console and the owner app agree on who executes a billing command', () => {
  const consoleSource = readFileSync(join(ROOT, 'app/platform-console.js'), 'utf8');
  const appSource = readFileSync(join(ROOT, 'app/app.js'), 'utf8');

  const billingExecutors = (source) =>
    new Set(invokedSlugs(source).filter((slug) => /billing-command$/.test(slug)));

  assert.deepEqual(
    [...billingExecutors(consoleSource)].sort(),
    [...billingExecutors(appSource)].sort(),
    'the super-admin console and the owner Billing page hand billing commands to different '
      + 'executors. They did once — the console kept naming razorpay-billing-command after the swap '
      + 'to Stripe — and nothing noticed until the function was deleted.',
  );
  /* Positive control: an assertion over two empty sets would pass while proving nothing. */
  const appExecutors = billingExecutors(appSource);
  assert.equal(appExecutors.size, 1, `expected exactly one billing executor, saw ${[...appExecutors]}`);
});
