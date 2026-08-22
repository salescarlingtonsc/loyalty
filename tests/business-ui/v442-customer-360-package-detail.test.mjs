/* V442 — Package detail on the Customer 360.
   The profile showed a "Package · 5 left" chip with nothing behind it. This card is what the
   owner circled in the right column: plan, sessions used/left, purchase date and price, the
   history of the sessions already used, and the staff action to use one.

   Everything below is EXECUTED, never pattern-matched. The failures this surface is exposed
   to are behaviours, not spellings: a used/remaining pair that disagrees with the chip, a
   history list attributed to the wrong purchase, a card that quietly reports "0 packages" for
   a role that was never allowed to count them, and — the one that passes `node --check` and
   every grep — an identifier referenced but never declared. The renderer and the write path
   are therefore taken out of app/app.js itself and run against fixtures, with the Supabase
   client stubbed to RECORD what it was asked for. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const indexHtml = readFileSync(join(root, 'app', 'index.html'), 'utf8');

/* ---- the module under test, taken verbatim out of app/app.js ---- */
const v442 = app.slice(
  app.indexOf("const PACKAGE_SESSION_NOTE_PREFIX_V442="),
  app.indexOf('function packageSaleResultV102(data){'),
);
assert.ok(v442.length > 500, 'the V442 block must be found in app/app.js');
/* Its two collaborators are taken from the same source rather than re-implemented — a change
   to either is a change to what this harness executes. */
const collaborators = [
  'function packageUseAttemptKeyV102(',
  'function packageUseResultV102(',
  'function serviceDisplayName(',
  'function formatCustomerJoinedDateV141(',
].map((start) => {
  const from = app.indexOf(start);
  assert.ok(from > 0, `${start} must exist in app/app.js`);
  return app.slice(from, app.indexOf('\n}', from) + 2);
}).join('\n');

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (c) => 'SGD ' + ((c || 0) / 100).toFixed(2);
const sgt = (iso) => { if (!iso) return null; const d = new Date(new Date(iso).getTime() + 8 * 3600000); return d.toISOString().slice(0, 16).replace('T', ' '); };
const CUI = { icon: () => '<svg></svg>' };

/* The stubbed Supabase client. It records every call so a builder that is assigned but never
   awaited — which sends nothing at all — cannot pass as a working write. */
const rpcCalls = [];
let rpcReply = { data: null, error: null };
const sb = {
  rpc(name, args) {
    rpcCalls.push({ name, args });
    /* A real PostgREST builder is a thenable, not a resolved value. Returning one here means
       the code under test must actually await it. */
    return { then: (resolve) => Promise.resolve(rpcReply).then(resolve) };
  },
};

let branchReply = { branches: [{ id: 'br-1', name: 'Bugis', active: true }] };
let branchThrows = false;
const visibleBranchesForCurrentUser = async () => {
  if (branchThrows) throw new Error('branch scope unavailable');
  return branchReply;
};
const activeBranchesForScopeV217 = (branches = []) => (branches || []).filter((b) => b && b.active !== false);

const V = new Function(
  'esc', 'money', 'sgt', 'CUI', 'sb', 'visibleBranchesForCurrentUser', 'activeBranchesForScopeV217', 'console',
  `${collaborators}\n${v442}\n  return {PACKAGE_SESSION_NOTE_PREFIX_V442,packageSessionUsesV442,packageDetailModelV442,
    packageDetailCardHtmlV442,packageUseBranchesV442,usePackageSessionV442};`,
)(esc, money, sgt, CUI, sb, visibleBranchesForCurrentUser, activeBranchesForScopeV217, { error() {} });

const visibleText = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
const STAFF = { 'st-1': 'Aisyah', 'st-2': 'Bala' };
const BRANCH = { 'br-1': 'Bugis', 'br-2': 'Tampines' };

/* ------------------------------------------------------------------ fixtures */

const ACTIVE_PACKAGE = {
  id: 'cp-active', plan_name_snapshot: '10x Facial', plan_version_snapshot: 2,
  sessions_snapshot: 10, remaining: 7, status: 'active',
  purchased_at: '2026-07-01T02:00:00Z', price_cents: null, price_cents_snapshot: 45000,
  service_name_snapshot: 'Signature facial', service_variant_snapshot: null,
  service_duration_min_snapshot: 60,
};
const EXHAUSTED_PACKAGE = {
  id: 'cp-done', plan_name_snapshot: '3x Scalp', plan_version_snapshot: 1,
  sessions_snapshot: 3, remaining: 0, status: 'used_up',
  purchased_at: '2026-05-02T02:00:00Z', price_cents_snapshot: 12000,
  service_name_snapshot: null,
};

/* Three uses of the active package, one unrelated paid sale, and — the case that must not be
   mistaken for a session use — a $0 sale that is NOT a package session. */
const salesWithThreeUses = () => ([
  { id: 's-1', occurred_at: '2026-07-05T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 10x Facial', staff_id: 'st-1', branch_id: 'br-1' },
  { id: 's-2', occurred_at: '2026-07-19T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 10x Facial', staff_id: 'st-2', branch_id: 'br-2' },
  { id: 's-3', occurred_at: '2026-08-02T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 10x Facial', staff_id: null, branch_id: null },
  { id: 's-4', occurred_at: '2026-08-03T03:00:00Z', kind: 'retail', amount_cents: 4500, note: 'Shampoo', staff_id: 'st-1', branch_id: 'br-1' },
  { id: 's-5', occurred_at: '2026-08-04T03:00:00Z', kind: 'service', amount_cents: 0, note: 'Comped consultation', staff_id: 'st-1', branch_id: 'br-1' },
]);

const render = (model, options = {}) => V.packageDetailCardHtmlV442(model, {
  staffName: STAFF, branchName: BRANCH, ...options,
});

/* ============================ A — one active package, three uses ============================ */

test('A1 used/remaining is the chip\'s own arithmetic, and the history is the three $0 session sales', () => {
  const model = V.packageDetailModelV442({ packages: [ACTIVE_PACKAGE], sales: salesWithThreeUses() });
  assert.equal(model.length, 1);
  const [entry] = model;
  /* The chip renders `${activePackage.remaining} left` off client_packages.remaining. The card
     must be derived from the SAME column pair, so the two can never disagree. */
  assert.equal(entry.remaining, ACTIVE_PACKAGE.remaining);
  assert.equal(entry.used, ACTIVE_PACKAGE.sessions_snapshot - ACTIVE_PACKAGE.remaining);
  assert.equal(entry.exhausted, false);
  assert.equal(entry.uses.length, 3);
  assert.deepEqual(entry.uses.map((u) => u.saleId), ['s-3', 's-2', 's-1'], 'most recent first');
  assert.equal(entry.ambiguous, false);
  assert.equal(entry.unattributed, false, '3 visible uses against 3 counted uses');
});

test('A2 the card prints the numbers, the purchase date, the price and every use', () => {
  const html = render(V.packageDetailModelV442({ packages: [ACTIVE_PACKAGE], sales: salesWithThreeUses() }),
    { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] });
  const text = visibleText(html);
  assert.match(text, /10x Facial · v2/);
  assert.match(text, /3 of 10 used · 7 left/, 'the owner\'s own phrasing, from the chip\'s columns');
  assert.match(text, /7 left/);
  assert.match(text, /Bought 1 Jul 2026 · SGD 450\.00/);
  assert.match(text, /Signature facial · 60 min/);
  assert.match(text, /Session history · 3/);
  /* Each use prints when it happened in Singapore time, plus whatever the $0 sale row itself
     carried — the staff member and the branch. Nothing is invented for the row that has neither. */
  assert.match(text, /2026-08-02 11:00/);
  assert.match(text, /2026-07-19 11:00 · Bala · Tampines/);
  assert.match(text, /2026-07-05 11:00 · Aisyah · Bugis/);
  assert.ok(!text.includes('Comped consultation'), 'a $0 sale that is not a package session is not a use');
  assert.ok(!text.includes('Shampoo'), 'a paid sale is not a use');
});

test('A3 a reversed use stays visible and is labelled, never silently dropped', () => {
  const sales = salesWithThreeUses().concat([
    { id: 's-1r', occurred_at: '2026-07-06T03:00:00Z', kind: 'service', amount_cents: 0, reversal_of: 's-1', note: 'Peekaa quick reversal', staff_id: 'st-1', branch_id: 'br-1' },
  ]);
  /* The reversal restored a session, so the package's own counter is one higher. */
  const model = V.packageDetailModelV442({ packages: [{ ...ACTIVE_PACKAGE, remaining: 8 }], sales });
  const [entry] = model;
  assert.equal(entry.used, 2, 'the restored session is already netted out of remaining');
  assert.equal(entry.uses.length, 3, 'the undone use is still listed');
  assert.equal(entry.uses.filter((u) => u.reversed).length, 1);
  assert.equal(entry.unattributed, false, '2 unreversed uses against a counter of 2');
  const text = visibleText(render(model));
  assert.match(text, /Added back · no refund/);
  assert.ok(!text.includes('Peekaa quick reversal'), 'the reversal row is not itself a use');
});

test('A4 a use from before this purchase is not counted against it, whatever the timestamp format', () => {
  /* Two tables, two renderings of the same instant: PostgREST may hand back fractional seconds
     on one and not the other, and '+' sorts BEFORE '.', so a string compare would put
     2026-07-01T02:00:00.500+00:00 earlier than 2026-07-01T02:00:00+00:00. */
  const sales = [
    { id: 'old', occurred_at: '2026-06-30T23:59:59+00:00', kind: 'service', amount_cents: 0, note: 'package session used: 10x Facial' },
    { id: 'new', occurred_at: '2026-07-01T02:00:00.500+00:00', kind: 'service', amount_cents: 0, note: 'package session used: 10x Facial' },
  ];
  const model = V.packageDetailModelV442({
    packages: [{ ...ACTIVE_PACKAGE, remaining: 9, purchased_at: '2026-07-01T02:00:00+00:00' }],
    sales,
  });
  assert.deepEqual(model[0].uses.map((u) => u.saleId), ['new'],
    'only the use that happened after this package was bought belongs to it');
  assert.equal(model[0].unattributed, false);
});

/* ============================ B — exhausted ============================ */

test('B1 an exhausted package is shown, muted, with its history intact — never hidden', () => {
  const sales = [
    { id: 'x-1', occurred_at: '2026-05-10T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 3x Scalp', staff_id: 'st-1', branch_id: 'br-1' },
    { id: 'x-2', occurred_at: '2026-05-20T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 3x Scalp', staff_id: 'st-1', branch_id: 'br-1' },
    { id: 'x-3', occurred_at: '2026-06-01T03:00:00Z', kind: 'service', amount_cents: 0, note: 'package session used: 3x Scalp', staff_id: 'st-2', branch_id: 'br-1' },
  ];
  const model = V.packageDetailModelV442({ packages: [EXHAUSTED_PACKAGE], sales });
  assert.equal(model[0].exhausted, true);
  assert.equal(model[0].used, 3);
  const html = render(model, { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] });
  assert.match(html, /class="c360-package-v442 is-exhausted-v442"/, 'muted, not removed');
  const text = visibleText(html);
  assert.match(text, /3 of 3 used · 0 left/);
  assert.match(text, /No sessions left/);
  assert.match(text, /Session history · 3/);
  /* Nothing may offer to use a session that does not exist, and the absence must not read as
     a permissions problem either. */
  assert.ok(!html.includes('data-use-package-v442'), 'no Use control on an exhausted package');
  assert.ok(!text.includes('Read only'), 'an all-exhausted card is not a permissions message');
  assert.ok(!html.includes('c360PackageBranchV442'), 'no branch picker with nothing to use');
});

/* ============================ C — two packages ============================ */

test('C1 two packages render one block each, most recent purchase first', () => {
  const model = V.packageDetailModelV442({
    packages: [EXHAUSTED_PACKAGE, ACTIVE_PACKAGE],
    sales: salesWithThreeUses(),
  });
  assert.deepEqual(model.map((m) => m.id), ['cp-active', 'cp-done'], 'newest purchase leads');
  const html = render(model, { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] });
  assert.equal((html.match(/class="c360-package-v442/g) || []).length, 2);
  assert.deepEqual([...html.matchAll(/data-package-v442="([^"]+)"/g)].map((m) => m[1]), ['cp-active', 'cp-done'],
    'each block declares which purchase it is — including the exhausted one');
  assert.ok(html.indexOf('10x Facial') < html.indexOf('3x Scalp'));
  /* One shared branch picker, and a Use control only on the package that has sessions left. */
  assert.equal((html.match(/id="c360PackageBranchV442"/g) || []).length, 1);
  assert.deepEqual([...html.matchAll(/data-use-package-v442="([^"]+)"/g)].map((m) => m[1]), ['cp-active']);
});

test('C2 the same plan bought twice is declared unattributable instead of being guessed at', () => {
  const first = { ...ACTIVE_PACKAGE, id: 'cp-a', remaining: 8, purchased_at: '2026-06-01T02:00:00Z' };
  const second = { ...ACTIVE_PACKAGE, id: 'cp-b', remaining: 9, purchased_at: '2026-07-01T02:00:00Z' };
  const model = V.packageDetailModelV442({ packages: [first, second], sales: salesWithThreeUses() });
  assert.ok(model.every((entry) => entry.ambiguous), 'both blocks must own up to it');
  const text = visibleText(render(model));
  assert.match(text, /holds more than one/);
  assert.match(text, /recorded on the sale, not against one purchase/);
  /* The counters stay authoritative and stay different, even though the two lists overlap. */
  assert.deepEqual(model.map((m) => m.used), [1, 2]);
});

test('C3 when the visible sales cannot account for the counter, the card says so', () => {
  /* Six sessions used, but only the three $0 sales this role can see. The counter wins and the
     shortfall is stated — a short list presented as the whole story is the failure mode. */
  const model = V.packageDetailModelV442({
    packages: [{ ...ACTIVE_PACKAGE, remaining: 4 }], sales: salesWithThreeUses(),
  });
  assert.equal(model[0].used, 6);
  assert.equal(model[0].unattributed, true);
  const text = visibleText(render(model));
  assert.match(text, /The counter above is authoritative\. 6 sessions have been used; 3 matching sales are visible to you here\./);
  assert.match(text, /6 of 10 used · 4 left/);
});

/* ============================ D — none, and states ============================ */

test('D1 a customer with no packages gets no card at all', () => {
  assert.equal(V.packageDetailModelV442({ packages: [], sales: salesWithThreeUses() }).length, 0);
  assert.equal(render([], { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] }), '',
    'empty is absent, exactly as the visit-feedback strip beside it does it');
  assert.equal(render(null), '');
  assert.equal(render(undefined), '');
});

test('D2 a package with no recorded uses says so rather than showing an empty disclosure', () => {
  const model = V.packageDetailModelV442({ packages: [{ ...ACTIVE_PACKAGE, remaining: 10 }], sales: [] });
  assert.equal(model[0].used, 0);
  const html = render(model);
  assert.ok(!html.includes('Session history'), 'no empty disclosure');
  assert.match(visibleText(html), /No session use has been recorded against this package yet\./);
});

test('D3 read-only, no-branch and branch-error each get their own honest state', () => {
  const model = V.packageDetailModelV442({ packages: [ACTIVE_PACKAGE], sales: salesWithThreeUses() });

  const readOnly = render(model, { canUse: false, branches: [{ id: 'br-1', name: 'Bugis' }] });
  assert.match(visibleText(readOnly), /Read only — ask for Packages edit access to use a session\./);
  assert.ok(!readOnly.includes('data-use-package-v442'));

  const noBranch = render(model, { canUse: true, branches: [] });
  assert.match(visibleText(noBranch), /No active branch is available to you/);
  assert.ok(!noBranch.includes('data-use-package-v442'));

  const failed = render(model, { canUse: true, branches: [], branchError: true });
  assert.match(visibleText(failed), /The branch list could not be loaded/);
  assert.match(failed, /class="err small"/, 'the house error voice, inside the card');
  assert.ok(!failed.includes('data-use-package-v442'), 'no write control without a proven branch');
  /* The facts the card already holds survive the failure — a degraded action never blanks the
     figures beside it. */
  assert.match(visibleText(failed), /3 of 10 used · 7 left/);
});

test('D4 the branch scope loader degrades instead of throwing', async () => {
  branchThrows = false;
  branchReply = { branches: [{ id: 'br-1', name: 'Bugis', active: true }, { id: 'br-9', name: 'Closed', active: false }] };
  const ok = await V.packageUseBranchesV442();
  assert.deepEqual(ok.branches.map((b) => b.id), ['br-1'], 'an inactive branch can never complete a session');
  assert.equal(ok.error, false);

  branchThrows = true;
  const failed = await V.packageUseBranchesV442();
  assert.deepEqual(failed, { branches: [], error: true });
  branchThrows = false;
});

/* ============================ E — the write ============================ */

test('E1 using a session calls use_package_session_v102 with the right arguments', async () => {
  rpcCalls.length = 0;
  rpcReply = {
    data: {
      status: 'completed', consumption_id: 'con-1', sale_id: 'sale-1',
      client_package_id: 'cp-active', client_id: 'cl-1', branch_id: 'br-1',
      remaining_before: 7, remaining_after: 6, points_earned: 0, points_total: 120,
    },
    error: null,
  };
  const attempts = new Map();
  const { result, error } = await V.usePackageSessionV442({
    businessId: 'biz-1', clientPackageId: 'cp-active', branchId: 'br-1', attempts,
  });
  assert.equal(error, undefined);
  assert.equal(rpcCalls.length, 1, 'the builder must actually be awaited — an unawaited one sends nothing');
  assert.equal(rpcCalls[0].name, 'use_package_session_v102');
  assert.equal(rpcCalls[0].args.p_business, 'biz-1');
  assert.equal(rpcCalls[0].args.p_client_package, 'cp-active');
  assert.equal(rpcCalls[0].args.p_branch, 'br-1');
  assert.match(String(rpcCalls[0].args.p_idempotency_key), /.{8,}/, 'the server demands >= 8 characters');
  assert.equal(result.remainingAfter, 6);
  assert.equal(attempts.size, 0, 'a completed use releases its key');
});

test('E2 a failed attempt keeps its idempotency key so the retry is the same request', async () => {
  rpcCalls.length = 0;
  rpcReply = { data: null, error: { message: 'network' } };
  const attempts = new Map();
  const first = await V.usePackageSessionV442({ businessId: 'biz-1', clientPackageId: 'cp-active', branchId: 'br-1', attempts });
  assert.ok(first.error);
  assert.equal(attempts.size, 1);
  rpcReply = {
    data: {
      status: 'completed', consumption_id: 'con-2', sale_id: 'sale-2',
      client_package_id: 'cp-active', client_id: 'cl-1', branch_id: 'br-1',
      remaining_before: 7, remaining_after: 6, points_earned: 0, points_total: 120,
    },
    error: null,
  };
  await V.usePackageSessionV442({ businessId: 'biz-1', clientPackageId: 'cp-active', branchId: 'br-1', attempts });
  assert.equal(rpcCalls[0].args.p_idempotency_key, rpcCalls[1].args.p_idempotency_key,
    'a retry must be the SAME operation, not a second session deduction');
});

test('E3 an incomplete receipt is refused rather than reported as a used session', async () => {
  rpcCalls.length = 0;
  rpcReply = { data: { status: 'completed', sale_id: 'sale-3' }, error: null };
  const { result, error } = await V.usePackageSessionV442({
    businessId: 'biz-1', clientPackageId: 'cp-active', branchId: 'br-1', attempts: new Map(),
  });
  assert.equal(result, undefined);
  assert.match(String(error.message), /receipt was incomplete/);
});

/* ============================ F — the wiring in clientDetail ============================ */

/* The renderer and the RPC are proven above. What is left is the join between them, and the
   two ways that join has broken on this surface before: an identifier referenced but never
   declared (passes node --check, passes every grep, throws at render), and a data-* attribute
   whose dataset casing does not match what the handler reads. */
const clientDetail = app.slice(
  app.indexOf('async function clientDetail(id){'),
  app.indexOf('const ACTIVITY_STAFF_NONE_V267='),
);

test('F1 every V442 identifier the profile uses is declared in the profile', () => {
  /* Bindings only. A `.dataset.usePackageV442` read is a property (F2 pins that separately) and
     a quoted 'c360PackageBranchV442' is an element id, not a variable. */
  const used = new Set([...clientDetail.matchAll(/(^|[^.\w$'"])([A-Za-z_$][\w$]*V442)\b/g)].map((m) => m[2]));
  assert.ok(used.size >= 6, `expected the V442 wiring in clientDetail, found ${[...used].join(', ')}`);
  const topLevel = new Set([...app.matchAll(/^(?:const|let|function|async function) ([A-Za-z_$][\w$]*V442)\b/gm)].map((m) => m[1]));
  for (const name of used) {
    /* `let a=[],b=false` declares both — a first-name-only scan is exactly how an undeclared
       identifier slips through a source check. */
    const declaredLocally = new RegExp(`(?:\\bconst\\b|\\blet\\b|\\bvar\\b|,)\\s*${name}\\s*=`).test(clientDetail);
    assert.ok(topLevel.has(name) || declaredLocally, `${name} is used by clientDetail but declared nowhere`);
  }
});

test('F2 the handler reads the dataset key the markup actually emits', () => {
  const html = render(V.packageDetailModelV442({ packages: [ACTIVE_PACKAGE], sales: [] }),
    { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] });
  const attribute = html.match(/<button[^>]*\sdata-([a-z0-9-]+)="cp-active"/)[1];
  assert.equal(attribute, 'use-package-v442');
  const camel = attribute.replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
  assert.ok(clientDetail.includes(`querySelectorAll('[data-${attribute}]')`),
    'the profile must select on the attribute the card emits');
  assert.ok(clientDetail.includes(`button.dataset.${camel}`),
    `the handler must read dataset.${camel}`);
});

test('F3 the write is confirmed, branch-scoped and reloads the profile', () => {
  const block = clientDetail.slice(clientDetail.indexOf("querySelectorAll('[data-use-package-v442]')"));
  const handler = block.slice(0, block.indexOf('const eraseButtonV291'));
  assert.match(handler, /await confirmActionV386\(/, 'the house confirm, not a bare click');
  assert.match(handler, /\$\('c360PackageBranchV442'\)/, 'the branch comes from the picker on the card');
  assert.match(handler, /if\(!branchId\)return toast\(/, 'no branch, no write');
  assert.match(handler, /await usePackageSessionV442\(/, 'and it must be awaited');
  assert.match(handler, /if\(error\)return fail\(error\)/);
  assert.match(handler, /if\(isClientDetailCurrent\(\)\)clientDetail\(id\)/,
    'a completed use reloads so the chip, the counter and the history agree again');
});

test('F4 the card is placed under the summary card, in the right column, and only when it has rows', () => {
  assert.match(clientDetail, /<div class="c360-summary-stack-v442">\$\{summaryCardV294\}\$\{packageDetailMarkupV442\}<\/div>/,
    'the two must share one grid cell — a sibling cell lands in the LEFT column of the next row');
  assert.match(clientDetail, /:summaryCardV294\}/, 'and with no package the summary card is unwrapped');
  assert.match(clientDetail, /const packageModelV442=canReadPackages\?/,
    'a role that cannot read packages must not be told it has none');
  assert.match(indexHtml, /\.c360-summary-stack-v442\{display:grid/);
  assert.match(indexHtml, /@media\(max-width:960px\)\{\.c360-summary-stack-v442\{order:-1;width:100%\}\}/,
    'the stack inherits the summary card\'s own "figures first on a phone" rule');
  assert.match(indexHtml, /\.c360-package-v442\.is-exhausted-v442\{opacity:\.62\}/);
  /* The branch picker above the list is a div too, so a :first-of-type separator rule would
     match IT and draw a line above the first package. Adjacent-sibling only. */
  assert.match(indexHtml, /\.c360-package-v442\+\.c360-package-v442\{[^}]*border-top:1px dashed/);
  assert.doesNotMatch(indexHtml, /\.c360-package-v442:first-of-type/);
});

test('F5 the card reuses the profile\'s existing classes rather than inventing a parallel system', () => {
  const html = render(V.packageDetailModelV442({ packages: [ACTIVE_PACKAGE], sales: salesWithThreeUses() }),
    { canUse: true, branches: [{ id: 'br-1', name: 'Bugis' }] });
  for (const cls of ['card', 'c360-summary-row-v294', 'c360-summary-label-v294',
    'c360-summary-value-v294', 'pill', 'c360-reward-adjust', 'c360-reward-row-v226', 'muted small']) {
    assert.ok(html.includes(cls), `${cls} is the profile's own idiom and must be reused`);
  }
});

/* ============================ G — no second source of truth ============================ */

test('G1 the card and the chip read the same two columns, and the reader was already there', () => {
  /* The chip: `Package · ${activePackage.remaining} left`, off client_packages.remaining. */
  assert.match(clientDetail, /label:`Package · \$\{activePackage\.remaining\} left`/);
  /* The card takes cpRows — the very rows the chip is found in — and the sales already loaded
     for the timeline. If this ever becomes its own query, the two can drift. */
  assert.match(clientDetail, /packageDetailModelV442\(\{packages:cpRows\|\|\[\],sales:allSl\|\|\[\]\}\)/);
  assert.ok(!v442.includes(".from('client_packages')"), 'the card must not re-read the table');
  assert.ok(!v442.includes(".from('sales')"), 'nor the sales it was handed');
  assert.ok(!v442.includes('staff_list_package_entitlements_v102'),
    'the whole-business entitlements reader is not a per-customer source');
});

test('G2 the only write is the same RPC the Packages page uses', () => {
  const rpcs = [...v442.matchAll(/sb\.rpc\('([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(rpcs, ['use_package_session_v102']);
  const packages = app.slice(app.indexOf('async function packagesPage(){'));
  assert.ok(packages.includes("sb.rpc('use_package_session_v102'"),
    'the Packages page call site must still be the same one — two definitions of "use a session" is the thing to avoid');
});
