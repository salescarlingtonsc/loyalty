import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { surfaceHint, stampDocument } from '../../scripts/quality/stamp-app-bundle.mjs';

/* nestly_v535 — the customer chunk stops waiting for the session.
 *
 * PROFILED ON PRODUCTION, cold, mobile Chrome:
 *   app-core.js        295 ->  577
 *   supabase-js        544 ->  669
 *   app-customer.js    677 ->  805   <- 189 KB, not even REQUESTED until 677 ms
 *   content / DCL                896
 *
 * route() awaits sb.auth.getSession() before choosing a surface, so the largest file on the
 * customer critical path waited for app-core to download, execute, and resolve a session.
 *
 * It does not have to. appSurfaceForRouteV185 answers 'customer' for the bare root and for every
 * customer prefix WITHOUT consulting the session; only the remaining routes need it. For exactly
 * those hashes the answer is knowable from the head, so a hint starts the download with the first
 * wave. It only ever ADDS a preload — it never decides which chunk the router loads — so a wrong
 * answer costs bandwidth, never correctness.
 */

const repo = new URL('../../', import.meta.url);
const shipped = readFileSync(new URL('app/index.gen.html', repo), 'utf8');
const source = readFileSync(new URL('app/index.html', repo), 'utf8');
const appJs = readFileSync(new URL('app/app.js', repo), 'utf8');
const head = shipped.slice(0, shipped.indexOf('<body'));
const hint = head.match(/<script id="surfaceHintV535">([\s\S]*?)<\/script>/)?.[1] ?? '';

test('V535 the hint is in the head, before the body', () => {
  assert.ok(hint.length > 0, 'the shipped head carries the surface hint');
  assert.ok(head.includes('id="surfaceHintV535"'));
});

test('V535 it names the customer chunk by its exact fingerprint', () => {
  const chunk = shipped.match(/"customer":"(\/app-customer\.js\?b=[0-9a-f]{12})"/);
  assert.ok(chunk, 'the manifest names the customer chunk');
  assert.ok(hint.includes(chunk[1]),
    'the hint must preload the SAME build the router will load, or 618 KB is fetched twice');
});

test('V535 the prefixes are read from the router, not retyped', () => {
  const routerList = appJs.match(/const CUSTOMER_ROUTE_PREFIXES_V185=(\[[^\]]*\]);/);
  assert.ok(routerList, 'the router still declares its prefixes as a literal');
  for (const prefix of JSON.parse(routerList[1].replace(/'/g, '"'))) {
    assert.ok(hint.includes(JSON.stringify(prefix)),
      `${prefix} is a customer route but the hint does not know it, so that entry stays slow`);
  }
});

test('V535 the hint fires on exactly the routes the router calls customer', () => {
  /* Executed, not inspected: the emitted script is run against each hash with a fake document,
     and what it appends is compared with the router's own answer. */
  const routerList = JSON.parse(appJs.match(/const CUSTOMER_ROUTE_PREFIXES_V185=(\[[^\]]*\]);/)[1].replace(/'/g, '"'));
  const body = surfaceHint('/app-customer.js?b=abcabcabcabc', routerList)
    .replace(/^<script[^>]*>/, '').replace(/<\/script>$/, '');
  const fires = (hash) => {
    const appended = [];
    const fakeDoc = { createElement: () => ({}), head: { appendChild: (el) => appended.push(el) } };
    new Function('location', 'document', body)({ hash }, fakeDoc);
    return appended.length === 1;
  };
  for (const hash of ['', '#/', '#/wallet', '#/wallet/cubbly-spa', '#/customer/profile',
    '#/b/cubbly-spa', '#/join', '#/claim', '#/offer/abc', '#/wallet?x=1']) {
    assert.equal(fires(hash), true, `${hash} is a customer entry and must be hinted`);
  }
  for (const hash of ['#/dashboard', '#/business', '#/admin', '#/appointments', '#/platform/ops']) {
    assert.equal(fires(hash), false,
      `${hash} is a workspace route — hinting it would download 618 KB nobody asked for`);
  }
});

test('V535 the stamper refuses a document that lost the hint, or an app.js that lost its prefixes', () => {
  const chunks = { core: 'a', auth: 'b', customer: 'c', business: 'd', i18n: 'e' };
  assert.throws(() => stampDocument(shipped.replace(/<script id="surfaceHintV535">[\s\S]*?<\/script>/, ''), chunks, appJs),
    /surfaceHintV535/, 'losing the hint silently would undo this with nothing to notice');
  assert.throws(() => stampDocument(source, chunks, 'const SOMETHING_ELSE=1;'),
    /CUSTOMER_ROUTE_PREFIXES_V185/,
    'if the router renames its prefix list the hint must fail loudly, not preload the wrong set');
});
