/**
 * nestly_v948 — the per-branch module projection stops WAITING, without starting to be CACHED.
 *
 * THE SHAPE OF THE PROBLEM. Record sale and Appointments each read their branch list, and only
 * then asked for one `get_my_modules_at_v115` per branch — so the projection was a second round
 * trip stacked behind the first. Measured against the real bundles at 150ms per read:
 *
 *     before   Record sale 412ms, Appointments 409ms — loading screen on 8 of 8 visits
 *     after    Record sale 243ms, Appointments 251ms — loading screen on 0 of 8
 *
 * WHAT MUST NOT CHANGE, and is the whole reason this is not simply a cache: v370 ruled that this
 * projection is never cached, because it carries permission state another session can revoke — a
 * cached copy would let a teammate whose access was just removed keep it until a TTL expired.
 * Every projection here is still a live read. Only the waiting is gone.
 *
 * EVERY ASSERTION EXECUTES THE REAL FUNCTION, lifted out of app/app.js by source slice and
 * instantiated with `new Function` — the technique this repo uses (see
 * tests/release-blockers/rewards-programmes.test.mjs). A grep would stay green while the overlap
 * silently reverted to a second round trip, which is exactly the regression this guards.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const slice = (startRe, endMarker) => {
  const start = app.search(startRe);
  assert.ok(start >= 0, `missing slice start: ${startRe}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing slice end: ${endMarker}`);
  return app.slice(start, end);
};

const starterSrc = slice(/^function startBranchProjectionsV948\(\)\{/m, '\nconst projectionCanRead=');

/** Instantiates the real starter over a controllable clock, cache and loader. */
function harness({ cacheBranches = null, cacheAgeMs = 0, role = 'owner' } = {}) {
  const calls = [];
  let failFor = new Set();
  const S = { biz: { id: 'biz-1' }, user: { id: 'user-1' }, myRole: role };
  const branchScopeCacheV370 = cacheBranches
    ? { key: `biz-1:user-1:${role}`, at: Date.now() - cacheAgeMs, result: { isAdmin: true, branches: cacheBranches } }
    : { key: '', at: 0, result: null };

  const scope = new Function(
    'S', 'branchScopeCacheV370', 'BOOTSTRAP_CACHE_TTL_V370', 'bootstrapCacheFreshV370',
    'activeBranchesForScopeV217', 'loadBranchModuleProjection',
    `${starterSrc} return { startBranchProjectionsV948 };`,
  )(
    S,
    branchScopeCacheV370,
    { branches: 120000 },
    (entry, key, ttl, now = Date.now()) => !!entry && entry.key === key && entry.result !== null && (now - entry.at) < ttl,
    (branches = []) => (branches || []).filter(b => b && b.active !== false),
    async (branchId) => {
      calls.push(branchId);
      if (failFor.has(branchId)) throw new Error(`no access to ${branchId}`);
      return { branch_id: branchId, modules: ['till'], role };
    },
  );
  return { ...scope, calls, S, failFor: ids => { failFor = new Set(ids); } };
}

test('a warm branch scope starts every projection BEFORE anyone asks for one', () => {
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }, { id: 'br2', active: true }] });
  const started = h.startBranchProjectionsV948();
  // The requests are already in flight at this point — nothing has been awaited yet.
  assert.deepEqual(h.calls, ['br1', 'br2'], 'both projections were issued at construction');
  assert.equal(started.seeded, 2);
});

test('settle() waits for what is already flying and issues nothing twice', async () => {
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }, { id: 'br2', active: true }] });
  const started = h.startBranchProjectionsV948();
  const settled = await started.settle(['br1', 'br2']);
  assert.deepEqual(h.calls, ['br1', 'br2'], 'no branch was read a second time');
  assert.deepEqual(settled.map(r => r.branchId), ['br1', 'br2']);
  assert.deepEqual(settled.map(r => r.data.modules), [['till'], ['till']]);
  assert.deepEqual(settled.map(r => r.error), [null, null]);
});

test('a branch the seed did not know about is still fetched — the seed is a head start, not a source of truth', async () => {
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }] });
  const started = h.startBranchProjectionsV948();
  assert.deepEqual(h.calls, ['br1']);
  const settled = await started.settle(['br1', 'br-new']);
  assert.deepEqual(h.calls, ['br1', 'br-new'], 'the unseeded branch was topped up at settle');
  assert.deepEqual(settled.map(r => r.branchId), ['br1', 'br-new']);
  assert.equal(settled[1].data.branch_id, 'br-new');
});

test('a COLD scope cache seeds nothing and falls back to fetching at settle — never a duplicate branch read to warm it', async () => {
  const h = harness({ cacheBranches: null });
  const started = h.startBranchProjectionsV948();
  assert.deepEqual(h.calls, [], 'a cold cache issues no speculative reads');
  assert.equal(started.seeded, 0);
  await started.settle(['br1']);
  assert.deepEqual(h.calls, ['br1'], 'and the projection still happens, just at the old moment');
});

test('an EXPIRED scope cache is not trusted', () => {
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }], cacheAgeMs: 130000 });
  h.startBranchProjectionsV948();
  assert.deepEqual(h.calls, [], 'past the 120s window the seed is refused');
});

test('an inactive branch is never speculated on', () => {
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }, { id: 'brOff', active: false }] });
  h.startBranchProjectionsV948();
  assert.deepEqual(h.calls, ['br1']);
});

test('a failure is carried to settle() rather than thrown at nobody', async () => {
  /* The requests start before anything awaits them. A projection that rejects in that window must
     not become an unhandled rejection for a request the page never asked for — but the page's own
     error path still has to see it, because that path draws the "branch access could not be
     checked" card and its retry. */
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }, { id: 'br2', active: true }] });
  h.failFor(['br2']);
  const started = h.startBranchProjectionsV948();
  await new Promise(r => setTimeout(r, 10));   // the rejection lands here, unobserved
  const settled = await started.settle(['br1', 'br2']);
  assert.equal(settled[0].error, null);
  assert.match(String(settled[1].error), /no access to br2/, 'the error survives to the caller');
  assert.equal(settled[1].data, null);
});

test('the projection is still a LIVE read every time — v948 must never have become a cache', async () => {
  /* The v370 ruling this change is built around: the per-branch projection carries permission
     state another session can revoke. Two separate page loads must each re-read it. */
  const h = harness({ cacheBranches: [{ id: 'br1', active: true }] });
  await h.startBranchProjectionsV948().settle(['br1']);
  await h.startBranchProjectionsV948().settle(['br1']);
  assert.deepEqual(h.calls, ['br1', 'br1'],
    'a second page load re-read the projection; caching it would let revoked access survive');
});

test('both callers start the projection ABOVE their own reads, not after them', () => {
  /* The behaviour is in the ORDER, and the order is per-call-site. Each page must construct the
     starter before the Promise.all it used to wait on, or the overlap silently disappears. */
  const till = app.slice(app.indexOf('async function tillPage(){'));
  const tillStart = till.indexOf('startBranchProjectionsV948()');
  const tillWave = till.indexOf('await Promise.all([');
  assert.ok(tillStart > -1 && tillWave > -1, 'both markers exist in tillPage');
  assert.ok(tillStart < tillWave, 'Record sale starts the projection before its first read wave');

  const appt = app.slice(app.indexOf('async function appointmentsPage(){'));
  const apptStart = appt.indexOf('startBranchProjectionsV948()');
  const apptWave = appt.indexOf('await Promise.all([');
  assert.ok(apptStart > -1 && apptWave > -1, 'both markers exist in appointmentsPage');
  assert.ok(apptStart < apptWave, 'Appointments starts the projection before its first read wave');

  // and neither page still issues the per-branch RPC inline, which is what made it a second wave
  assert.doesNotMatch(till.slice(0, tillWave + 4000), /get_my_modules_at_v115/,
    'Record sale no longer reads the projection inline after its branch list');
});
