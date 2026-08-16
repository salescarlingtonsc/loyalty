import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

/* V370 — Supabase load audit, 2026-08-17.
   Peekaa was sitting near 100% CPU on a Micro instance before public launch. The audit found the
   cost was request AMPLIFICATION, not slow queries: the same handful of answers were being fetched
   over and over inside a single navigation, and a 20-second customer poll was re-running an entire
   render pipeline to discover that nothing had changed.

   Every test here pins ONE way that amplification used to happen. They are deliberately written
   against the behaviour (counting calls where the code can be executed) rather than against
   phrasing, so a future refactor that keeps the saving keeps the test. */

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return appJs.slice(from, to);
}

/* ---------------------------------------------------------------- personas */

test('V370 one navigation resolves personas once, not two or three times', () => {
  const route = section('async function route(){', '/* ---------- customer wallet ---------- */');
  /* The workspace bootstrap must not contain a raw persona read any more — every one of them
     goes through the shared loader, which is what makes them a single round trip. */
  assert.doesNotMatch(route, /sb\.rpc\('get_my_personas'\)/,
    'route() must resolve personas through loadPersonasV370, never inline');
  assert.ok(route.split('loadPersonasV370(').length - 1 >= 3,
    'all three historical call sites still resolve personas — they just share one answer now');
});

test('V370 a staff-only account stops re-resolving "no customer persona" on every navigation', () => {
  const route = section('async function route(){', '/* ---------- customer wallet ---------- */');
  /* The bug: "resolved, and there is none" was stored as null — the same value that means "not
     checked yet" — so the whole block (personas + customer_get_profile) re-ran on EVERY hash
     change, forever, for every staff-only account. */
  assert.match(route, /customerPersonaResolvedV370=\{userId:String\(S\.user\?\.id\|\|''\),value:S\.hasCustomerPersona===true\}/,
    'the resolved answer must be recorded as a real boolean');
  assert.match(route, /if\(S\.hasCustomerPersona===null&&customerPersonaResolvedV370\.userId===String\(S\.user\?\.id\|\|''\)/,
    'and re-used before any read is attempted');
  /* It is USER-scoped: S.hasCustomerPersona is reset alongside S.biz on a business switch, which
     is why this could not simply live on S. */
  assert.match(route, /if\(S\.hasCustomerPersona===true\)customerPersonaResolvedV370=\{userId:String\(S\.user\?\.id\|\|''\),value:true\}/,
    'a positive answer survives a business switch too');
  /* The profile fallback must survive: a phone-registered customer with no personas row is still
     discovered, or they lose the Customer link in their workspace header. */
  assert.match(route, /if\(!S\.hasCustomerPersona\)\{[\s\S]{0,400}?customer_get_profile/,
    'the phone-registration fallback is preserved — this is not a functionality removal');
});

test('V370 the persona cache is per-user, never caches a failure, and drops on every persona write', () => {
  const loader = section('async function loadPersonasV370(', 'async function loadBusinessControlV370(');
  assert.match(loader, /personaCacheV370\.userId===userId/, 'keyed by user — a shared phone must not leak');
  assert.match(loader, /if\(result\?\.error\)return result;/,
    'a failure drives a "could not resolve" screen; caching it would pin that screen up');
  /* Anything that can create a persona invalidates immediately, so a new invite/claim/signup is
     never hidden behind the window. */
  for (const site of [
    'accept_invite', 'customer_create_identity', 'customer_claim_link_invitation',
    'customer_claim_link_by_verified_phone', 'customer_claim_link_by_email',
    'customer_register_verified_phone', 'start_self_serve_business_v130'
  ]) {
    /* Every INVOCATION, not the first textual mention — several of these names also appear in
       comments, and a comment invalidates nothing. */
    const calls = [...appJs.matchAll(new RegExp(`sb\\.rpc\\('${site}'`, 'g'))].map(m => m.index);
    assert.ok(calls.length > 0, `${site} call site must exist`);
    for (const at of calls) {
      assert.ok(appJs.lastIndexOf('invalidatePersonaCacheV370()', at) > at - 400,
        `${site} must invalidate the persona cache before it runs`);
    }
  }
  assert.match(section('function resetClientSessionState(', 'const $=(id)=>'),
    /invalidateBranchModuleProjectionCache\(\)/, 'sign-out clears everything');
  assert.match(section('function invalidateBranchModuleProjectionCache(', 'const BOOTSTRAP_CACHE_TTL_V370'),
    /invalidateWorkspaceBootstrapCachesV370\(\)/);
});

/* ------------------------------------------------------- bootstrap caching */

test('V370 the workspace bootstrap caches are short-lived, not session-lifetime', () => {
  const ttls = section('const BOOTSTRAP_CACHE_TTL_V370', 'let personaCacheV370');
  /* A platform admin can suspend a firm from another session, and an owner can be granted a
     branch while their tab is open. These windows are the deliberate price of not re-reading the
     same four answers twenty times a minute — they must stay small enough to be honest. */
  const values = [...ttls.matchAll(/(\w+):(\d+)/g)].map(m => [m[1], Number(m[2])]);
  assert.ok(values.length === 4, 'four cached bootstrap reads');
  for (const [name, ms] of values) {
    assert.ok(ms > 0 && ms <= 120000, `${name} window must be at most two minutes, got ${ms}ms`);
  }
});

test('V370 the branch roster is cached, hands out copies, and drops on every roster write', () => {
  const branches = section('async function visibleBranchesForCurrentUser(', 'async function refreshBranchFilter(');
  assert.match(branches, /bootstrapCacheFreshV370\(branchScopeCacheV370/);
  assert.match(branches, /`\$\{S\.biz\?\.id\|\|''\}:\$\{S\.user\?\.id\|\|''\}:\$\{S\.myRole\|\|''\}`/,
    'role is in the key — the admin and employee branches return different sets');
  /* Callers sort and filter what they get. Handing out the cached array itself would let one
     caller mutate another caller's answer. */
  assert.match(branches, /branches:cached\.branches\.map\(branch=>\(\{\.\.\.branch\}\)\)/);
  assert.match(branches, /return \{isAdmin,branches:branches\.map\(branch=>\(\{\.\.\.branch\}\)\)\}/);
  for (const site of ["sb.rpc('business_add_branch_v202'", "from('staff_branches').insert({business_id:S.biz.id,staff_id:staffId",
    "from('staff_branches').delete().eq('business_id',S.biz.id).eq('staff_id',staffId)"]) {
    const at = appJs.indexOf(site);
    assert.ok(at > 0, `${site} call site must exist`);
    assert.ok(appJs.lastIndexOf('invalidateBranchScopeCacheV370()', at) > at - 300,
      `${site} must invalidate the branch scope cache`);
  }
});

test('V370 the firm row and the workspace gate are cached but still resolve in the safe order', () => {
  const route = section('async function route(){', '/* ---------- customer wallet ---------- */');
  assert.doesNotMatch(route, /sb\.rpc\('platform_get_business_control_v94'/,
    'the gate goes through the cache helper');
  assert.doesNotMatch(route, /sb\.from\('businesses'\)\.select\('\*'\)/,
    'so does the firm row');
  /* Unchanged and load-bearing: a pending or payment-blocked firm must be refused BEFORE any
     tenant data is read. */
  assert.ok(route.indexOf('loadBusinessControlV370(') < route.indexOf('loadBusinessRecordV370('));
  const control = section('async function loadBusinessControlV370(', 'async function loadBusinessRecordV370(');
  assert.match(control, /if\(result\?\.error\|\|!result\?\.data\)return result;/,
    'a refused or failed gate is never cached');
});

/* --------------------------------------------------- realtime amplification */

test('V370 one booking event produces one refresh, not one per emitted row', async () => {
  /* The DB writes a notifications row alongside the booking_requests row, so a single customer
     booking delivered two events on the channel and each handler re-rendered the whole open page.
     Executed rather than pattern-matched: what matters is the COUNT. */
  const src = section('const REALTIME_REFRESH_DEBOUNCE_MS_V370', 'function ensureRealtimeChannel(')
    + section('function refreshPendingBookingRequestCountV329(', 'async function openBookingRequestPopupV329ById(');
  let refreshes = 0, counts = 0;
  const ctx = {
    setTimeout, clearTimeout, Promise,
    currentPage: ['bookings'],
    globalThis: { document: { activeElement: null } },
    M: () => ({ contains: () => false }),
    bookingsPage: () => { refreshes += 1; },
    appointmentsPage: () => {}, waitlistPage: () => {},
    S: { biz: { id: 'b1' } },
    canReadModule: () => true,
    sb: { from: () => ({ select: () => ({ eq: () => ({ in: async () => { counts += 1; return { count: 2 }; } }) }) }) },
    $: () => null,
    STAFF_BOOKING_DECISION_STATUSES: new Set(['pending']),
    bookingRequestsBadgeWrapHtml: () => '', wireBookingRequestsBadgeV329: () => {}
  };
  const api = vm.runInNewContext(
    `(()=>{${src};return {autoRefreshIfRelevant,refreshPendingBookingRequestCountV329}})()`, ctx);

  // The exact burst a single booking produces today: booking_requests INSERT + notifications INSERT.
  api.autoRefreshIfRelevant();
  api.refreshPendingBookingRequestCountV329();
  api.autoRefreshIfRelevant();
  api.refreshPendingBookingRequestCountV329();
  await new Promise(resolve => setTimeout(resolve, 500));

  assert.equal(refreshes, 1, 'two events, ONE page refresh');
  assert.equal(counts, 1, 'two events, ONE pending-count read');

  // A genuinely later event still refreshes — this coalesces bursts, it does not drop updates.
  api.autoRefreshIfRelevant();
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.equal(refreshes, 2, 'a later event is not swallowed');
});

test('V370 a debounced refresh cannot fire into a signed-out session', () => {
  const kill = section('function killChannels(){', '/* ---------- V329: booking-request pop-up');
  assert.match(kill, /clearTimeout\(autoRefreshTimerV370\)/);
  assert.match(kill, /clearTimeout\(pendingBookingCountTimerV370\)/);
});

/* ------------------------------------------------------- polling visibility */

test('V370 the PayNow till poll suspends while the tab is hidden and resumes on return', () => {
  const till = section('function paynowSuspendedForVisibilityV370(', 'async function beginPaynowPaymentV142(');
  assert.match(till, /visibilityState!=='hidden'\)return false/, 'visible tabs poll exactly as before');
  assert.match(till, /document\.addEventListener\('visibilitychange',paynowHiddenResumeV370\)/);
  assert.match(till, /if\(!isTillCurrent\(\)\|\|!paynowAttempt\)return;/,
    'a dialog closed while away must not resurrect its poll');
  assert.match(till, /if\(paynowSuspendedForVisibilityV370\(attemptId\)\)return;/);
  /* No cap and no backoff were added: the payment flow itself is untouched, and the first poll
     after resume reads whatever status the attempt reached while the tab was away. */
  assert.match(till, /pollPaynowAttemptV142\(attemptId\);/);
});

test('V370 the customer redemption QR poll pauses when hidden and reconciles on return', () => {
  const redemption = section('const schedulePoll=(delay=1500)', 'document.addEventListener(\'visibilitychange\',onVisibilityChange)');
  assert.match(redemption, /if\(document\.visibilityState!=='visible'\)\{pollTimer=0;return\}/);
  const visibility = section('const onVisibilityChange=()=>{', 'const close=(');
  assert.match(visibility, /if\(!closed&&!terminal&&!pollTimer\)void reconcileRedemptionState\(\)/,
    'returning restarts the loop, so a redemption completed while away still resolves');
});
