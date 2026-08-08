import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* v242 (owner): "customer to view all businesses - within the ecosystem - then show (not set up)
   for businesses that they yet to scan QRcode. and they able to see each customised points
   (existing infrastructure). the rewards are customised to each company and not shared."

   v244 moved this directory from the bottom of Home into the Explore tab, where the empty query
   IS the whole ecosystem and a typed query ("chicken rice", "facial") narrows it on the server.
   The invariants this file has always protected are unchanged and are asserted on the Explore
   surface:
   - a business the customer has NOT joined is SHOWN, never linked and never given a balance;
   - a joined business shows ITS OWN points and opens ITS OWN wallet through the same
     #/wallet/<slug> route the linked-programme tiles use — no cross-business total anywhere;
   - only identical business ids deduplicate, demo tenants are not filtered, states are honest,
     and merchant-authored text is escaped. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const appCss = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');
const migration = readFileSync(resolve(repoRoot, 'db/migrations/20260808_nestly_v244_customer_explore_search.sql'), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

const exploreSource = section('function customerExploreRowMarkupV244', 'async function renderCustomerExplore');
const pageSource = section('async function renderCustomerExplore', 'const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');

const api = new Function('esc', 'ct', 'CUI', 'customerMediaUrlV95', 'customerPointTotalV103', `
  ${exploreSource}
  return {row:customerExploreRowMarkupV244,results:customerExploreResultsMarkupV244};`)(
  (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  (key) => String(key), { icon: () => '' }, () => '', (value) => String(value));

test('Explore is a real destination with a server-side search', () => {
  assert.match(appJs, /if\(h==='#\/customer\/explore'\)return renderCustomerExplore\(\);/);
  assert.match(appJs, /\{key:'explore',href:'#\/customer\/explore',icon:'search',copy:'explore'\}/);
  assert.match(pageSource, /customerRpc\('customer_explore_businesses_v244',\{p_query:query\|\|null\}\)/);
  assert.match(pageSource, /debounce=setTimeout\(/, 'typing must not fire a request per keystroke');
  assert.match(pageSource, /epoch!==searchEpoch/, 'a stale reply must never overwrite a newer query');
  assert.doesNotMatch(appJs, /customerBusinessDirectoryHostV242|mountCustomerBusinessDirectoryV242/,
    'the Home-mounted v242 section is fully replaced, not left half-wired');
});

test('a joined business shows its own points and opens its own wallet', () => {
  const html = api.row({ business_id: 'b1', name: 'Cubbly', slug: 'kopi-tiam-tyeh', industry: 'Personal care', joined: true, points_balance: 45 });
  assert.match(html, /href="#\/wallet\/kopi-tiam-tyeh"/);
  assert.match(html, /Member/);
  assert.match(html, /<b>45<\/b>/);
});

test('a business the customer has not scanned into is shown, not linked, and has no points', () => {
  const html = api.row({ business_id: 'b2', name: 'AhXiang', slug: 'ahxiang', industry: 'Food & drink', joined: false, points_balance: null });
  assert.doesNotMatch(html, /<a /, 'an unjoined row must not navigate anywhere');
  assert.match(html, /Not set up/);
  assert.match(html, /Scan their QR in store to join/);
  assert.doesNotMatch(html, /points<\/span>/);
});

test('the server never gives an unjoined row a balance, and anon has no EXECUTE', () => {
  assert.match(migration, /'points_balance', case when cl\.id is null then null else/);
  assert.match(migration, /cl\.state = 'verified' and cl\.unlinked_at is null/);
  assert.match(migration, /revoke all on function public\.customer_explore_businesses_v244\(text\) from public, anon;/);
  assert.match(migration, /where b\.join_enabled/);
});

test('a query matches what a business SELLS, with AND semantics and filler words dropped', () => {
  assert.match(migration, /s\.business_id=b\.id and s\.active and s\.name ilike/);
  assert.match(migration, /p\.business_id=b\.id and coalesce\(p\.active,true\) and p\.name ilike/);
  assert.match(migration, /not exists \(\s*select 1 from unnest\(v_tokens\) t\s*where not \(/,
    'every token must match somewhere — "chicken rice" is not "chicken" OR "rice"');
  assert.match(migration, /'near','me','nearby'/);
  assert.match(migration, /'match_note', matched\.note/, 'a result can say why it appeared');
});

test('only identical business ids are deduplicated; same-name businesses both survive', () => {
  const html = api.results({ status: 'ready', rows: [
    { business_id: 'x1', name: 'Cafe2U', slug: 'cafe2u', joined: false },
    { business_id: 'x2', name: 'Cafe2U', slug: 'cafe2u-1', joined: false },
    { business_id: 'x1', name: 'Cafe2U', slug: 'cafe2u', joined: false }
  ] });
  assert.equal((html.match(/Cafe2U/g) || []).length, 2);
});

test('the isolation guarantee is stated to the customer', () => {
  const html = api.results({ status: 'ready', rows: [{ business_id: 'b1', name: 'Cubbly', slug: 's', joined: true, points_balance: 0 }] });
  assert.match(html, /Points and rewards are separate for every business\./);
});

test('loading, empty, no-match and error states are all honest, and the error offers a retry', () => {
  assert.match(api.results({ status: 'loading' }), /Searching…/);
  assert.match(api.results({ status: 'error' }), /id="customerExploreRetry"/);
  assert.match(api.results({ status: 'ready', rows: [] }), /No businesses to show yet\./);
  assert.match(api.results({ status: 'ready', rows: [], query: 'zzz' }), /Nothing matches “zzz”/);
});

test('business names, industries and addresses from the server are escaped', () => {
  const html = api.row({ business_id: 'b3', name: '<img src=x onerror=alert(1)>', slug: 'x',
    industry: '<script>', address: '"><svg>', match_note: '<b>x</b>', joined: false });
  assert.doesNotMatch(html, /<img src=x/);
  assert.doesNotMatch(html, /<script>/);
  assert.doesNotMatch(html, /"><svg>/);
  assert.match(html, /&lt;img src=x/);
});

test('merchant-authored fields carry the shared content marker, not bespoke a11y interpolation', () => {
  assert.match(exploreSource, /data-merchant-content/);
  assert.doesNotMatch(exploreSource, /aria-label="\$\{esc\(name/,
    'v97: no interpolated accessibility attributes on merchant text');
});

test('the Explore surface reuses the customer card system at 390px', () => {
  assert.match(appCss, /\.customer-explore-search\{[^}]*border-radius:999px/);
  assert.match(appCss, /\.customer-explore-search input\{[^}]*min-height:48px/);
  assert.match(appCss, /\.customer-explore-row\{[^}]*display:flex/);
  assert.match(appCss, /\.customer-explore-copy h3\{[^}]*overflow-wrap:anywhere/);
  assert.match(appCss, /\.customer-explore-logo--fallback\{[^}]*display:flex/);
});
