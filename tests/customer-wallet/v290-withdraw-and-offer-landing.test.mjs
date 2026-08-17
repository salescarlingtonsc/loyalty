import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v290 (owner: "build the road from 8 to 9") — two features:
   1. a signed-in customer can WITHDRAW a booking request nobody has actioned yet;
   2. a shared offer deep-links into the app (#/offer/<id>) instead of dead-ending. */

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');
const indexHtml = await read('app/index.html');
const migration = await read('db/migrations/20260812_nestly_v290_customer_withdraw_booking_request.sql');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

/* ------------------------------------------------------------------- request withdrawal */

test('the withdraw control exists only on active requests and goes through the v290 RPC', () => {
  const bookings = section(appJs, 'const paintBookings', 'async function renderCustomerMessages');
  /* The row markup moved out of paintBookings into the shared request-row renderer above it, so
     it is matched against the file rather than that one slice; the HANDLER assertions below stay
     scoped to the bookings section, which is where they still live. The gate itself is unchanged:
     only an active request the customer owns gets the control. */
  assert.match(appJs, /isActiveCustomerBookingRequest\(item\)&&item\.request_id\?`<button class="btn ghost sm" type="button" data-withdraw-request=/,
    'only a pending/waitlisted request the customer owns gets the button');
  assert.match(bookings, /customerRpc\('customer_withdraw_booking_request_v290',\{p_request:button\.dataset\.withdrawRequest\}\)/);
  assert.match(bookings, /if\(!confirm\('Withdraw this booking request\?/, 'a destructive act asks first');
  assert.match(bookings, /button\.disabled=true;button\.setAttribute\('aria-busy','true'\)/, 'the tap goes busy');
  assert.match(bookings, /already_actioned/, 'a decided request is explained, not a generic failure');
  assert.match(bookings, /toast\('Request withdrawn'\);\s*renderCustomerBookings\(\)/, 'success repaints from the server');
});

test('the RPC resolves ownership exactly as the reader does, and only un-actioned rows move', () => {
  for (const condition of [
    "link.state = 'verified'",
    'request.customer_client_id = link.client_id',
    'token.authenticated_user_id = v_actor',
    'for update of request',
    "v_request.status not in ('new','pending','waitlisted')",
    "set status = 'cancelled'",
    'already_actioned',
  ]) assert.ok(migration.includes(condition), `migration must contain: ${condition}`);
  assert.match(migration, /if v_request\.status = 'cancelled' then\s*return jsonb_build_object\('status','cancelled','replayed',true\)/,
    'a double-tap replays as success — one decision, not an error');
  assert.match(migration, /revoke all on function public\.customer_withdraw_booking_request_v290\(uuid\) from public, anon;/);
});

/* ------------------------------------------------------------------ the offer deep link */

test('the offer route never gates a stranger behind sign-in', () => {
  const route = section(appJs, "if(h.startsWith('#/offer/'))", 'const directCustomerDestination');
  assert.ok(route.length < 900, 'the offer branch sits BEFORE the signed-out destination guard');
  const landing = section(appJs, 'async function renderCustomerOfferLandingV290', 'async function renderCustomerMessages');
  assert.match(landing, /if\(!S\.user\)\{/);
  assert.match(landing, /nav\(slug\?`#\/b\/\$\{encodeURIComponent\(slug\)\}`:'#\/wallet'\)/,
    'a signed-out recipient forwards to the public business page, never a sign-in wall');
  assert.match(landing, /^[\s\S]*?\/\^\[0-9a-f\]\{8\}/m, 'junk ids are refused before any fetch');
});

test('a signed-in customer sees the offer with live state and a CTA that knows if they are linked', () => {
  const landing = section(appJs, 'async function renderCustomerOfferLandingV290', 'async function renderCustomerMessages');
  assert.match(landing, /customerRpc\('offer_share_page_v268',\{p_offer:id\}\)/);
  assert.match(landing, /customerRpc\('customer_list_programmes_v89'\)/);
  assert.match(landing, /customerOfferLandingStateV290\(offer\.ends_at\)/);
  assert.match(landing, /linked\?`<a class="btn" href="#\/wallet\/\$\{encodeURIComponent\(slug\)\}"/);
  assert.match(landing, /:slug\?`<a class="btn" href="#\/b\/\$\{encodeURIComponent\(slug\)\}"/);
  assert.match(landing, /object-fit:contain/, 'merchant artwork is never cropped');
  assert.match(landing, /This offer has ended/, 'a dead link says so honestly');
  assert.match(landing, /data-merchant-content/, 'merchant text carries the shared content marker');
});

test('the live state is computed honestly', () => {
  const fn = new Function(`${section(appJs, 'function customerOfferLandingStateV290', 'async function renderCustomerOfferLandingV290')}
    return customerOfferLandingStateV290;`)();
  const now = new Date('2026-08-12T04:00:00Z');
  assert.equal(fn('2026-08-12T15:59:59Z', now), 'Ends today');
  assert.equal(fn('2026-08-13T15:59:59Z', now), 'Ends tomorrow');
  assert.equal(fn('2026-08-31T15:59:59Z', now), '19 days left'); // Aug 12 -> Aug 31 SGT: 19 calendar days after today
  assert.equal(fn('2026-08-01T00:00:00Z', now), 'Ended');
  assert.equal(fn(null, now), '');
});

test('the surface loaders agree that #/offer/ is a customer route', () => {
  assert.match(appJs, /const CUSTOMER_ROUTE_PREFIXES_V185=\['#\/b\/','#\/customer\/','#\/wallet','#\/claim','#\/join','#\/offer\/','#\/local\/customer-preview'\];/);
  assert.match(indexHtml, /'#\/b\/','#\/customer\/','#\/wallet','#\/claim','#\/join','#\/offer\/'/,
    'the index.html preloader mirrors the router rule it races');
});

test('the /o/ share page hands humans to the in-app offer landing', async () => {
  const fn = await read('app/api/offer-share.js');
  assert.match(fn, /\/app#\/offer\/\$\{encodeURIComponent\(String\(offer\.offer_id \|\| ''\)\)\}/);
});
