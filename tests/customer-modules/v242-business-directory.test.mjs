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
const migration = readFileSync(resolve(repoRoot, 'db/migrations/20260808_nestly_v245_customer_explore_search.sql'), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

const exploreSource = section('function customerExploreDistanceTextV247', 'async function renderCustomerExplore');
const pageSource = section('async function renderCustomerExplore', 'const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');

const api = new Function('esc', 'ct', 'CUI', 'customerMediaUrlV95', 'customerPointTotalV103', `
  ${exploreSource}
  return {row:customerExploreRowMarkupV244,results:customerExploreResultsMarkupV244};`)(
  (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  (key) => String(key), { icon: () => '' }, () => '', (value) => String(value));

test('Explore is a real destination with a server-side search', () => {
  /* v248: the owner hid Explore from customers for now. The route resolves to this finished
     search the moment CUSTOMER_EXPLORE_LIVE_V248 flips — it is gated, not removed, which is why
     every assertion below still runs against the real code. */
  assert.match(appJs, /if\(h==='#\/customer\/explore'\)return CUSTOMER_EXPLORE_LIVE_V248\?renderCustomerExplore\(\)/);
  assert.match(appJs, /\{key:'explore',href:'#\/customer\/explore',icon:'search',copy:'explore'\}/);
  assert.match(pageSource, /customerRpc\('customer_explore_businesses_v244',\{\s*\n?\s*p_query:query\|\|null/);
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

/* ------------------------------------------- v247 · nearest first, once a branch is located */

const nearMigration = readFileSync(resolve(repoRoot, 'db/migrations/20260808_nestly_v247_explore_nearest_first.sql'), 'utf8');
const distance = new Function(`${section('function customerExploreDistanceTextV247', 'function customerExploreRowMarkupV244')}
  return customerExploreDistanceTextV247;`)();
/* exploreSource now starts at the distance helper so the row renderer can call it; the merchant
   markup assertions below still read the same rendered output. */

test('a distance is only printed when the server computed one', () => {
  assert.equal(distance(2.4), '2.4 km');
  assert.equal(distance(18.37), '18 km', 'past 10 km, a decimal is false precision');
  assert.equal(distance(0.42), '400 m');
  assert.equal(distance(0.02), '50 m', 'closer than the GPS is accurate reads as a floor, not 20 m');
  assert.equal(distance(0), '50 m');
  // an unlocated business must render nothing at all — never "0 km", never "unknown km"
  for (const value of [null, undefined, '', 'near', NaN, -3]) assert.equal(distance(value), '');
});

test('an unlocated business is shown without a distance, not hidden', () => {
  const located = api.row({ business_id: 'n1', name: 'Cubbly', slug: 's', joined: true, points_balance: 0, distance_km: 1.2, located: true, address: '313 Orchard Road' });
  const unlocated = api.row({ business_id: 'n2', name: 'AhXiang', slug: 'a', joined: false, distance_km: null, located: false });
  assert.match(located, /1\.2 km/);
  assert.doesNotMatch(unlocated, /km|m<\/span>/);
  assert.match(unlocated, /AhXiang/, 'a business with no address still appears');
});

test('the list says when it is ordered by distance, and how many could not be ranked', () => {
  const html = api.results({ status: 'ready', near: true, rows: [
    { business_id: 'n1', name: 'Cubbly', slug: 's', joined: true, distance_km: 1.2, located: true },
    { business_id: 'n2', name: 'AhXiang', slug: 'a', joined: false, located: false },
    { business_id: 'n3', name: 'Kopi', slug: 'k', joined: false, located: false }
  ] });
  assert.match(html, /Nearest first/);
  assert.match(html, /2 businesses have no address yet, shown last/);
  const one = api.results({ status: 'ready', near: true, rows: [
    { business_id: 'n1', name: 'Cubbly', slug: 's', joined: true, distance_km: 1.2, located: true },
    { business_id: 'n2', name: 'AhXiang', slug: 'a', joined: false, located: false }
  ] });
  assert.match(one, /1 business has no address yet/);
  // no position shared → no claim about ordering
  assert.doesNotMatch(api.results({ status: 'ready', rows: [{ business_id: 'n1', name: 'C', slug: 's', joined: false }] }), /Nearest first/);
});

test('the customer position is an argument only — asked for, used, never kept', () => {
  assert.match(pageSource, /navigator\.geolocation\.getCurrentPosition/);
  assert.match(pageSource, /p_lat:position\?\.lat\?\?null,p_lng:position\?\.lng\?\?null/);
  assert.doesNotMatch(pageSource, /localStorage|sessionStorage|indexedDB/,
    'a location must not outlive the screen that asked for it');
  // turning it off forgets it immediately
  assert.match(pageSource, /if\(position\)\{setNear\(null,''\);run\(input\.value\.trim\(\)\);return\}/);
  // refusal is a decision, not an error
  assert.match(pageSource, /Location is off for this site/);
  assert.match(pageSource, /This browser cannot share your location/);
  assert.match(pageSource, /sorted by name/);
  assert.match(nearMigration, /never stored/);
});

test('the server orders by distance and keeps unlocated businesses last', () => {
  assert.match(nearMigration, /coalesce\(\(entry->>'distance_km'\)::numeric, 999999\)/);
  assert.match(nearMigration, /'distance_km', app\.v247_distance_km\(v_lat, v_lng, branch\.latitude, branch\.longitude\)/);
  assert.match(nearMigration, /if p_lat between -90 and 90 and p_lng between -180 and 180 then/,
    'a half-supplied or impossible position is ignored, never clamped');
  assert.match(nearMigration, /revoke all on function public\.customer_explore_businesses_v244\(text,numeric,numeric\) from public, anon;/);
});

test('a branch coordinate carries the address it came from, so it can be re-checked', () => {
  assert.match(nearMigration, /add column if not exists geocoded_address text/);
  assert.match(nearMigration, /add column if not exists geocode_source text/);
  assert.match(nearMigration, /latitude between -90 and 90 and longitude between -180 and 180/);
  assert.match(nearMigration, /\(latitude is null and longitude is null\)/, 'a coordinate pair is all-or-nothing');
});

test('a firm with several outlets is as far away as its NEAREST outlet', () => {
  assert.match(nearMigration, /order by\s*\n\s*case when v_lat is null then null\s*\n\s*else app\.v247_distance_km\(v_lat, v_lng, br\.latitude, br\.longitude\) end\s*\n\s*nulls last,/);
});

/* ----------------------------------------------- v248 · Explore is not offered to customers */

test('Explore is hidden entirely — no tab, and the route refuses', () => {
  // owner: "just hide the explore button entire (so will not shown to customers)"
  assert.match(appJs, /const CUSTOMER_EXPLORE_LIVE_V248=false;/);
  const nav = section('const CUSTOMER_PRIMARY_NAV=Object.freeze([', 'function customerPrimaryNavigation(');
  assert.match(nav, /\.\.\.\(CUSTOMER_EXPLORE_LIVE_V248\?\[\{key:'explore'/,
    'the tab is conditional on the flag, not deleted');
  assert.match(appJs, /if\(h==='#\/customer\/explore'\)return CUSTOMER_EXPLORE_LIVE_V248\?renderCustomerExplore\(\):nav\('#\/wallet'\);/,
    'a hand-typed URL must not reach a page with no way back into it');
  assert.doesNotMatch(appJs, /ComingSoon/, 'the coming-soon surface the owner replaced is gone, not orphaned');
  assert.doesNotMatch(appCss, /customer-coming-soon|peekaaLookAroundV248/, 'its CSS went with it');
  assert.match(appCss, /\.customer-primary-nav\{[^}]*grid-template-columns:1fr 1fr auto 1fr;/,
    'four slots while Explore is hidden: Home, Rewards, Scan, Bookings');
});

test('the flag is declared before the navigation reads it', () => {
  /* A const used above its declaration is a temporal-dead-zone crash at load — the exact failure
     mode that took the Appointments page down in v217, and one that node --check cannot see. */
  const declaration = appJs.indexOf('const CUSTOMER_EXPLORE_LIVE_V248=false;');
  const navUse = appJs.indexOf("...(CUSTOMER_EXPLORE_LIVE_V248?[{key:'explore'");
  assert.ok(declaration > 0 && navUse > declaration,
    'CUSTOMER_EXPLORE_LIVE_V248 must be initialised before CUSTOMER_PRIMARY_NAV evaluates it');
});

test('the finished search is gated, not deleted', () => {
  assert.match(appJs, /async function renderCustomerExplore\(\)\{/);
  assert.match(appJs, /customer_explore_businesses_v244/);
  assert.match(appJs, /function customerExploreResultsMarkupV244/);
  assert.match(appJs, /function customerExploreDistanceTextV247/);
});
