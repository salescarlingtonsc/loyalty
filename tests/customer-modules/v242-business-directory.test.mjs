import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* v242 (owner): "customer to view all businesses - within the ecosystem - then show (not set up)
   for businesses that they yet to scan QRcode. and they able to see each customised points
   (existing infrastructure). the rewards are customised to each company and not shared."

   v244 moved this directory from the bottom of Home into the Explore tab; v248 hid that tab
   behind one constant; and v393 (owner decision, 2026-08-19) RETIRED the destination — the tab
   entry, the page and its only call to customer_explore_businesses_v244 are gone from the app.

   What this file protects now is therefore in two halves:

   1) THE REMOVAL IS CLEAN AND REVERSIBLE-ON-THE-SERVER. No entry point, no dead call, and — the
      part that actually matters to a customer — the route still resolves, to #/wallet, so a link
      someone already has in a message or a home-screen shortcut cannot 404.

   2) THE SERVER SIDE IS UNTOUCHED AND STILL CORRECT. public.customer_explore_businesses_v244 and
      its migrations were not rolled back: this was a client decision. Every invariant this file
      has always asserted about that function — an unjoined business gets no balance, anon has no
      EXECUTE, a query matches what a business SELLS, a firm is as far away as its nearest outlet,
      a coordinate pair is all-or-nothing — is asserted here exactly as before, because those are
      the things that would have to hold again the day the surface comes back. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const appCss = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');
const migration = readFileSync(resolve(repoRoot, 'db/migrations/20260808_nestly_v245_customer_explore_search.sql'), 'utf8');
const nearMigration = readFileSync(resolve(repoRoot, 'db/migrations/20260808_nestly_v247_explore_nearest_first.sql'), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

/* ------------------------------------------------- v393 · Explore is removed, not half-wired */

test('the Explore destination is gone from the app — no tab, no page, no call', () => {
  // owner decision 2026-08-19: retire it, having hidden it since v248.
  assert.doesNotMatch(appJs, /CUSTOMER_EXPLORE_LIVE_V248/, 'the hide-it switch went with the page');
  assert.doesNotMatch(appJs, /renderCustomerExplore/, 'the page is deleted, not orphaned');
  assert.doesNotMatch(appJs, /customerExploreRowMarkupV244|customerExploreResultsMarkupV244|customerExploreDistanceTextV247/,
    'its markup helpers are deleted with it');
  /* The RPC keeps existing on the server; the client must have no CALL left. The name still
     appears once, in the removal note that records why — a comment is not a call site. */
  assert.doesNotMatch(appJs, /rpc\(\s*'customer_explore_businesses_v244'/,
    'no client call site may remain');
  assert.equal((appJs.match(/customer_explore_businesses_v244/g) || []).length, 1,
    'the only surviving mention is the v393 removal note');
  const nav = section('const CUSTOMER_PRIMARY_NAV=Object.freeze([', 'function customerPrimaryNavigation(');
  assert.doesNotMatch(nav, /explore/, 'no nav entry, conditional or otherwise');
  assert.equal((nav.match(/\{key:/g) || []).length, 5,
    'five slots: Home, Rewards, Scan, Bookings, Profile');
  assert.doesNotMatch(appJs, /customerBusinessDirectoryHostV242|mountCustomerBusinessDirectoryV242/,
    'the Home-mounted v242 section is fully replaced, not left half-wired');
});

test('the retired route aliases to the wallet — a link a customer already holds must not 404', () => {
  assert.match(appJs, /if\(h==='#\/customer\/explore'\)return nav\('#\/wallet'\);/);
  assert.match(appCss, /\.customer-primary-nav\{[^}]*grid-template-columns:1fr 1fr auto 1fr 1fr;/,
    'five slots: Home, Rewards, Scan, Bookings, Profile (v281)');
  assert.doesNotMatch(appJs, /ComingSoon/, 'the coming-soon surface the owner replaced is gone, not orphaned');
  assert.doesNotMatch(appCss, /customer-coming-soon|peekaaLookAroundV248/, 'its CSS went with it');
});

/* -------------------------------------- the server half, unchanged and still under contract */

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

test('the server orders by distance and keeps unlocated businesses last', () => {
  assert.match(nearMigration, /coalesce\(\(entry->>'distance_km'\)::numeric, 999999\)/);
  assert.match(nearMigration, /'distance_km', app\.v247_distance_km\(v_lat, v_lng, branch\.latitude, branch\.longitude\)/);
  assert.match(nearMigration, /if p_lat between -90 and 90 and p_lng between -180 and 180 then/,
    'a half-supplied or impossible position is ignored, never clamped');
  assert.match(nearMigration, /revoke all on function public\.customer_explore_businesses_v244\(text,numeric,numeric\) from public, anon;/);
  assert.match(nearMigration, /never stored/, 'the position is an argument, never a stored fact');
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
