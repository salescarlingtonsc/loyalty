/* W4B1 audit wave — regressions for F019-F024, F057, F058, F060, F070, F071, F076, F080, F081,
   F093, F095, F097, F102, F105, F136.

   Each test extracts the real source of the function/block under test and EXECUTES it against
   stubs, so the assertions fail when the behaviour regresses rather than when the spelling
   changes. Where a fix is purely template/copy text inside a large DOM-heavy closure that cannot
   reasonably be executed in isolation, the test anchors on the exact literal source that carries
   the behaviour (documented per-test) rather than re-describing it.

   F020 (v666_till_customer_card missing stamp_card), F057 (refreshTillCustomerStandingV408 has no
   client-id lookup path) and F105 (update_expense_v285 cannot express "clear the note") have NO
   test here on purpose: all three need a server-side change (a new/altered RPC) that is out of
   scope for this branch — see the audit report for the exact server change needed. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};
const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------------------------------------------------------------- F019 */

test('F019 tillFoldPhoneDigitsV019 folds a +65/065 prefix before truncating to 8 digits', () => {
  const src = section('function tillFoldPhoneDigitsV019(raw){', '\nasync function tillPage(){');
  const fold = vm.runInNewContext(`${src}; tillFoldPhoneDigitsV019`, {});
  // "+65 8186 3833" -> digits "6581863833" (10 digits, starts 65) -> fold to "81863833"
  assert.equal(fold('+65 8186 3833'), '81863833');
  assert.equal(fold('065 8186 3833'), '81863833');
  // a plain 8-digit number is untouched
  assert.equal(fold('91234567'), '91234567');
  // a number that merely starts with 65 but is not a folded country code (8 digits) is untouched
  assert.equal(fold('65123456'), '65123456');
});

/* ---------------------------------------------------------------- F021 */

test('F021 legacySaleReceiptV145 never asserts "no extra points added" on a replay', () => {
  const src = section('function legacySaleReceiptV145(doneInfo={},unitNounV430=\'points\'){', '\nfunction giftCardAbilitiesV102(');
  const build = vm.runInNewContext(`${src}; legacySaleReceiptV145`, {});
  const replay = build({ duplicate: true, pointsEarned: 0, pointsTotal: 1200 }, 'points');
  assert.equal(replay.heading, 'Recorded');
  assert.doesNotMatch(replay.message, /no extra points added/i);
  assert.match(replay.message, /1,200 points/);
  // F021 also fixed pointsTotal being nulled out whenever pointsEarned<=0 (which was ALWAYS true
  // for a replay, since the server always answers points_earned:0 there) — it must survive.
  assert.equal(replay.pointsTotal, 1200);
  const firstSuccess = build({ duplicate: false, pointsEarned: 40, pointsTotal: 1240 }, 'points');
  assert.equal(firstSuccess.heading, 'Done');
  assert.equal(firstSuccess.message, '+40 points');
  assert.equal(firstSuccess.pointsTotal, 1240);
});

test('F021 the cart receipt (posReceiptV142) duplicate branch shows the same honest copy', () => {
  const block = section("<h2 style=\"margin:8px 0 4px\">${d.duplicate?'Recorded'", '${d.hasSale?`<ul class="till-receipt-lines"');
  assert.doesNotMatch(block, /no extra points added/i);
  assert.match(block, /Recorded — current balance/);
  assert.match(block, /d\.pointsTotal/);
});

/* ---------------------------------------------------------------- F022 */

const buildHandleFinaliseError = () => {
  const src = section('  async function handleFinaliseError(error){', '\n  async function finishCartReceipt(){');
  const calls = { toasts: [], draws: 0, evaluates: 0 };
  const context = {
    payError: null, evalError: null, evalState: 'ready', staleConfirm: false,
    staleReevaluationsV257: 0, appliedTierBenefitV656: 'benefit-1', evalResult: { total: 1 },
    isBackendMissing: () => false,
    BRAND: { productName: 'Peekaa' },
    isTillCurrent: () => true,
    clearExpiry: () => {},
    toast: message => calls.toasts.push(String(message)),
    runEvaluate: async () => { calls.evaluates += 1; context.evalState = 'ready'; return true; },
    draw: () => { calls.draws += 1; },
  };
  const handleFinaliseError = vm.runInNewContext(`${src}; handleFinaliseError`, context);
  return { handleFinaliseError, context, calls };
};

test('F022 a typed tier-benefit 22023 unlocks the cart instead of a permanent Retry lock', async () => {
  const { handleFinaliseError, context, calls } = buildHandleFinaliseError();
  await handleFinaliseError({ code: '22023', message: 'tier_benefit_limit_reached' });
  assert.equal(context.payError, null, 'payError must stay null — a typed refusal is not a transport failure');
  assert.equal(context.appliedTierBenefitV656, null, 'the spent perk must be dropped from the bill');
  assert.equal(calls.evaluates, 1, 'the cart must be re-priced without the perk');
  assert.match(calls.toasts.join(' '), /already been used this period/);
});

test('F022 the other two birthday-perk refusals are recognised too', async () => {
  for (const message of ['tier_benefit_not_birthday_month', 'tier_benefit_birthday_unknown']) {
    const { handleFinaliseError, context } = buildHandleFinaliseError();
    await handleFinaliseError({ code: '22023', message });
    assert.equal(context.payError, null, message);
    assert.equal(context.appliedTierBenefitV656, null, message);
  }
});

test('F022 an unrelated 22023 still falls through to the generic Retry lock unchanged', async () => {
  const { handleFinaliseError, context } = buildHandleFinaliseError();
  await handleFinaliseError({ code: '22023', message: 'some other refusal entirely' });
  assert.equal(context.payError.kind, 'retry');
});

test('F022 the pre-existing idempotency-conflict and stale-evaluation branches are untouched', async () => {
  const conflict = buildHandleFinaliseError();
  await conflict.handleFinaliseError({ code: '22023', message: 'idempotency key conflicts' });
  assert.equal(conflict.context.payError.kind, 'conflict');

  const stale = buildHandleFinaliseError();
  await stale.handleFinaliseError({ code: 'P0001', message: 'stale_evaluation: price moved' });
  assert.equal(stale.context.staleConfirm, true);
  assert.equal(stale.calls.evaluates, 1);
});

/* F023 (PayNow QR dialog used QRCode before the library loaded) has no target any more:
   nestly_v755 removed the whole V142 PayNow-via-Stripe-Connect lifecycle from the till. */

/* ---------------------------------------------------------------- F024 */

test('F024 drawCustomerCard never renders a "Who made this sale?" picker and always attributes to the acting staff', () => {
  const src = section('  function drawCustomerCard(){', "\n  function drawStep3(){");
  const M = () => ({ set innerHTML(_v) { html = _v; } });
  let html = '';
  const context = {
    tillActingStaffId: 'staff-me',
    tillSaleStaffId: 'staff-someone-else', // whatever it was before must be overwritten
    M, esc, CUI: { pageHeader: () => '', icon: () => '' },
    BRAND: { productName: 'Peekaa' },
    canRecordSales: true,
    cust: { full_name: 'Jane Tan', phone: '81234567' },
    accessibleTillBranches: [{ id: 'b1', name: 'Main' }],
    tillBranchId: 'b1',
    S: { biz: { currency: 'SGD' } },
    legacyTenderOptions: [['cash', 'Cash']],
    tender: null,
    tillTenderIconV578: () => 'cash',
    $: () => ({ onclick: null, onchange: null, onkeydown: null, addEventListener() {}, value: '', focus() {} }),
    document: { querySelectorAll: () => [] },
  };
  vm.runInNewContext(`${src}; drawCustomerCard()`, context);
  assert.equal(context.tillSaleStaffId, 'staff-me', 'the sale must always be attributed to the acting staff — record_sale_by_phone rejects any other p_staff');
  assert.doesNotMatch(html, /Who made this sale\?/);
  assert.doesNotMatch(html, /id="tillSaleStaff"/);
});

/* ---------------------------------------------------------------- F058 */

test('F058 the keypad gift-scan arm stops and reports on a transport error instead of falling through to the settling scanner', async () => {
  const block = section(
    "    if(payload.kind==='gift'&&onGiftIdentified){",
    "\n    if(payload.kind==='gift'&&onGiftStaged){"
  );
  const context = {
    payload: { kind: 'gift' },
    token: 'tok', businessId: 'biz-1',
    closed: false,
    isCurrent: () => true,
    submitting: false,
    status: { textContent: '' },
    stopCamera: () => { context.stopCameraCalled = true; },
    close: () => { context.closeCalled = true; },
    onGiftIdentified: () => { context.onGiftIdentifiedCalled = true; },
    sb: { rpc: async () => ({ data: null, error: { code: '500', message: 'network timeout' } }) },
  };
  const run = vm.runInNewContext(`(async()=>{ ${block} })`, context);
  await run();
  assert.equal(context.onGiftIdentifiedCalled, undefined, 'must NOT fall through to the settling scanner on a transport error');
  assert.equal(context.closeCalled, undefined, 'the scanner must stay open so staff can retry');
  assert.match(context.status.textContent, /Try the scan again/);
});

test('F058 a soft "not found" answer (no error) still falls through as before', async () => {
  const block = section(
    "    if(payload.kind==='gift'&&onGiftIdentified){",
    "\n    if(payload.kind==='gift'&&onGiftStaged){"
  );
  const context = {
    payload: { kind: 'gift' },
    token: 'tok', businessId: 'biz-1',
    closed: false,
    isCurrent: () => true,
    submitting: false,
    status: { textContent: '' },
    stopCamera: () => {},
    close: () => {},
    onGiftIdentified: () => { context.onGiftIdentifiedCalled = true; },
    sb: { rpc: async () => ({ data: { status: 'not_pending' }, error: null }) },
  };
  const run = vm.runInNewContext(`(async()=>{ ${block} })`, context);
  await run();
  assert.equal(context.onGiftIdentifiedCalled, undefined, 'a soft refusal is not "found" either, so it also falls through unchanged');
});

test('F058 a found gift stops the keypad on the identified customer', async () => {
  const block = section(
    "    if(payload.kind==='gift'&&onGiftIdentified){",
    "\n    if(payload.kind==='gift'&&onGiftStaged){"
  );
  let identifiedWith = null;
  const context = {
    payload: { kind: 'gift' },
    token: 'tok', businessId: 'biz-1',
    closed: false,
    isCurrent: () => true,
    submitting: false,
    status: { textContent: '' },
    stopCamera: () => {},
    close: () => { context.closeCalled = true; },
    onGiftIdentified: (data, token) => { identifiedWith = { data, token }; },
    sb: { rpc: async () => ({ data: { status: 'found', client_id: 'c1' }, error: null }) },
  };
  const run = vm.runInNewContext(`(async()=>{ ${block} })`, context);
  await run();
  assert.equal(context.closeCalled, true);
  assert.deepEqual(identifiedWith, { data: { status: 'found', client_id: 'c1' }, token: 'tok' });
});

/* ---------------------------------------------------------------- F060 */

test('F060 merchantRedemptionRefusalTextV060 maps every known server refusal to its own sentence', () => {
  const src = section('function merchantRedemptionRefusalTextV060(error){', '\nfunction openMerchantRedemptionScanner(');
  const context = { humanErrorV295: (error, fallback) => {
    const raw = String(error?.message || '');
    return /\s/.test(raw) ? raw : fallback;
  } };
  const refusalText = vm.runInNewContext(`${src}; merchantRedemptionRefusalTextV060`, context);
  assert.match(refusalText({ message: 'insufficient proven points' }), /doesn't have enough points/);
  assert.match(refusalText({ message: 'reward usage limit reached' }), /usage limit/);
  assert.match(refusalText({ message: 'reward requires a higher membership tier' }), /higher membership tier/);
  assert.match(refusalText({ message: 'reward is currently paused' }), /paused right now/);
  assert.match(refusalText({ message: 'classic/catalog redemption terms changed; create a new QR' }), /fresh QR/);
  assert.match(refusalText({ message: 'reward is not eligible at this branch' }), /not available at this branch/);
  assert.match(refusalText({ message: 'this reward expired on 1 Jan 2026' }), /expired on 1 Jan 2026/);
  assert.match(refusalText({ message: 'customer redemption is disabled for this business' }), /turned off for this business/);
  assert.match(refusalText({ code: '42501', message: 'permission denied' }), /permission to confirm/);
  // an unmapped refusal falls back to the server's own message rather than the fixed wrong guess
  assert.equal(refusalText({ message: 'some brand-new server refusal' }), 'some brand-new server refusal');
});

test('F060 the classic redemption arm now uses merchantRedemptionRefusalTextV060 instead of a fixed guess', () => {
  const block = section("'This gift could not be given. It may have expired, already been used, or belong to another business.')", "return}");
  assert.match(block, /merchantRedemptionRefusalTextV060\(error\)/);
  assert.doesNotMatch(block, /may be expired, already used, or for another business/);
});

/* ---------------------------------------------------------------- F070 */

test('F070 the three service-catalogue write paths guard renderSvc() with isCurrent(), matching the bundle handlers', () => {
  const addBlock = section("if(canWrite)$('sadd').onclick=async()=>{", '\n  if(canWrite&&$(\'openServiceForm\'))');
  assert.match(addBlock, /if\(!isCurrent\(\)\)return;[\s\S]*renderSvc\(\)/);

  const saveBlock = section("document.querySelectorAll('[data-svc-save]').forEach(b=>b.onclick=async()=>{", "\n  }\n  /* nestly_v613.");
  assert.match(saveBlock, /if\(!isCurrent\(\)\)return;[\s\S]*renderSvc\(\);toast\('Service updated'\)/);

  const toggleBlock = section('window.toggleSvc=async(id,to)=>{', '\n  async function load(){');
  assert.match(toggleBlock, /if\(!isCurrent\(\)\)return;[\s\S]*renderSvc\(\)/);
});

/* ---------------------------------------------------------------- F071 */

test('F071 openAppointmentDetails only filters on branch_id when the caller actually supplied one', () => {
  const block = section('  async function openAppointmentDetails(summary,{startEditing=false}={}){', '\n    if(!stillCurrent()||!loading.isConnected)');
  assert.doesNotMatch(block, /\.eq\('branch_id',summary\.branch_id\)\.eq\('id',summary\.id\)/,
    'an unconditional branch_id filter defeats a deep link that does not know the branch');
  assert.match(block, /if\(summary\.branch_id\)appointmentQueryV071=appointmentQueryV071\.eq\('branch_id',summary\.branch_id\)/);
});

test('F071 the dashboard schedule-chip deep link passes branch_id:null, matching its own comment', () => {
  const block = section('     tenant\'s simply reports that it could not be opened, exactly as a stale calendar tap does. */',
    '\n}\n\n/* ---------- waitlist');
  assert.match(block, /openAppointmentDetails\(\{id:routedAppointmentV375,branch_id:null\}\)/);
});

/* ---------------------------------------------------------------- F076 */

const buildRefreshBookingBadge = ({ canRead, count = 0, rpcError = null }) => {
  const src = section('async function refreshPendingBookingRequestCountNowV370(){', '\n/* The single decision path,');
  const calls = { wrapRepaints: 0, slotRepaints: 0, wired: 0 };
  const context = {
    S: { biz: { id: 'biz-1' } },
    canReadModule: () => canRead,
    pendingBookingRequestCountV329: 999, // stale value from a previous business
    sb: { from: () => ({ select: () => ({ eq: () => ({ in: async () => ({ count, error: rpcError }) }) }) }) },
    STAFF_BOOKING_DECISION_STATUSES: ['pending'],
    $: id => (id === 'bookingRequestsBadgeWrapV329' ? { outerHTML: '' } : null),
    bookingRequestsBadgeWrapHtml: () => { calls.wrapRepaints += 1; return ''; },
    wireBookingRequestsBadgeV329: () => { calls.wired += 1; },
    document: { querySelectorAll: () => ({ forEach: fn => { calls.slotRepaints += 1; fn({ set innerHTML(_v) {} }); } }) },
    appointmentsNavBadgeHtml: () => '',
  };
  const refresh = vm.runInNewContext(`${src}; refreshPendingBookingRequestCountNowV370`, context);
  return { refresh, context, calls };
};

test('F076 switching to a business where "bookings" is unreadable zeroes the stale badge, mirroring refreshWaitlistBadge', async () => {
  const { refresh, context, calls } = buildRefreshBookingBadge({ canRead: false });
  await refresh();
  assert.equal(context.pendingBookingRequestCountV329, 0, 'the previous business\'s count must not leak across a switch');
  assert.equal(calls.wrapRepaints, 1);
  assert.equal(calls.slotRepaints, 1);
});

test('F076 a readable business still counts and repaints as before', async () => {
  const { refresh, context } = buildRefreshBookingBadge({ canRead: true, count: 3 });
  await refresh();
  assert.equal(context.pendingBookingRequestCountV329, 3);
});

test('F076 renderShell calls the refresh unconditionally now, not gated on canReadModule', () => {
  const block = section("wireBookingRequestsBadgeV329();", "\n  wireProfile(page);");
  assert.doesNotMatch(block, /if\(canReadModule\('bookings'\)\)refreshPendingBookingRequestCountV329/);
  assert.match(block, /^\s*refreshPendingBookingRequestCountV329\(\);/m);
});

/* ---------------------------------------------------------------- F080 */

test('F080 the header Import button is gated on owner, matching stage_import_rows\' server-side ownership check', () => {
  const block = section('async function clientsPage(){', "\n  routeMain.innerHTML=`<section id=\"customersView\">");
  assert.match(block, /S\.myRole==='owner'\?importBtn\('customers'\)/);
  assert.doesNotMatch(block, /\(canWrite\?importBtn\('customers'\)/);
});

test('F080 runImport reports an ownership refusal distinctly from a data-quality refusal', () => {
  const src = section('async function runImport(recs,entity,idempotencyKey,onProgress){', '\n/* The modal.');
  const context = { S: { biz: { id: 'biz-1' } }, sb: { rpc: async () => ({ data: null, error: { code: '42501', message: 'only the business owner can stage imports' } }) } };
  const runImport = vm.runInNewContext(`${src}; runImport`, context);
  return runImport([{ mapped: {} }], 'customers', 'idem-1').then(result => {
    assert.equal(result.blocked, true);
    assert.equal(result.permissionDenied, true);
  });
});

test('F080 a non-permission stage error is not flagged as a permission denial', () => {
  const src = section('async function runImport(recs,entity,idempotencyKey,onProgress){', '\n/* The modal.');
  const context = { S: { biz: { id: 'biz-1' } }, sb: { rpc: async () => ({ data: null, error: { code: '22P02', message: 'bad row' } }) } };
  const runImport = vm.runInNewContext(`${src}; runImport`, context);
  return runImport([{ mapped: {} }], 'customers', 'idem-1').then(result => {
    assert.equal(result.blocked, true);
    assert.equal(result.permissionDenied, false);
  });
});

/* ---------------------------------------------------------------- F081 */

test('F081 the bottom-of-page CSV import resumes from the failing row instead of freezing the button', async () => {
  const src = section('    const runCsvImportBatchV081=async()=>{', "\n    $('csvgo').onclick=runCsvImportBatchV081;");
  let recs = [
    { idempotency_key: 'k1', full_name: 'Amy Tan' },
    { idempotency_key: 'k2', full_name: 'Bad Row' },
    { idempotency_key: 'k3', full_name: 'Cara Lim' },
  ];
  let calls = 0;
  const btnState = { disabled: false, onclick: null };
  const prevHtml = { value: '' };
  const context = {
    recs,
    esc,
    $: id => (id === 'csvgo' ? btnState : id === 'csvprev' ? prevHtml : null),
    toast: () => {},
    workspaceTemplateTextV97: (key, args) => `${key}:${JSON.stringify(args)}`,
    workspaceTemplateHtmlV97: (key, args) => `${key}:${JSON.stringify(args)}`,
    sb: { rpc: async () => {
      calls += 1;
      if (calls === 2) return { data: null, error: { message: 'phone already used' } };
      return { data: {}, error: null };
    } },
    S: { biz: { id: 'biz-1' } },
  };
  // prevHtml needs an innerHTML setter so the retry button re-render is observable
  Object.defineProperty(prevHtml, 'innerHTML', { get() { return prevHtml.value; }, set(v) { prevHtml.value = v; if (v.includes('id="csvgo"')) { btnState.disabled = false; } } });
  const runBatch = vm.runInNewContext(`${src}; runCsvImportBatchV081`, context);
  await runBatch();
  assert.equal(btnState.disabled, false, 'the button must be re-enabled after a mid-batch failure, not frozen');
  assert.equal(recs.length, 2, 'the already-succeeded row must be consumed so a retry does not re-attempt it');
  assert.equal(recs[0].full_name, 'Bad Row', 'retry must resume at the row that failed');
  assert.match(prevHtml.value, /1 imported so far, 2 left to try/);
});

/* ---------------------------------------------------------------- F093 */

test('F093 the Add-teammate copy no longer promises a nonexistent hours editor or a false "cannot be booked" consequence', () => {
  const block = section('<label class="checkrow" for="staffAddHours"', '</label>');
  assert.doesNotMatch(block, /you can set their hours later/);
  assert.doesNotMatch(block, /cannot be booked until you do/);
  assert.match(block, /Block time/);
});

test('F093 the post-add toast points at the real, reachable remedy', () => {
  const block = section("toast(wantsHours?'Teammate added':", ');');
  assert.doesNotMatch(block, /set their work week before booking them/);
  assert.match(block, /Block time/);
});

/* ---------------------------------------------------------------- F095 */

test('F095 chRole only claims a finance-module removal when the PRIOR role actually had finance access', () => {
  const src = section('  window.chRole=async(id,role)=>{', '\n  window.decideStaffAccessV569=async(');
  const buildContext = priorRole => {
    const calls = { loaded: 0 };
    return {
      window: {},
      teamRowsById: new Map([['staff-1', { id: 'staff-1', role: priorRole }]]),
      sb: { rpc: async () => ({ data: { module_perms: null }, error: null }) },
      fail: () => {},
      permissionStatusByStaff: {},
      ROLE_LABELS: { staff: 'Staff', frontdesk: 'Front desk' },
      esc,
      invalidateBranchModuleProjectionCache: () => {},
      panelSel: {},
      openModId: null,
      toast: () => {},
      loadTeam: async () => { calls.loaded += 1; },
      myStaffId: 'someone-else',
      S: { biz: { id: 'biz-1' }, myModules: null, myModulePerms: null },
      route: () => {},
      calls,
    };
  };
  return (async () => {
    // lateral move between two already-non-finance roles: staff -> frontdesk
    const lateral = buildContext('staff');
    vm.runInNewContext(`${src}`, lateral);
    await lateral.window.chRole('staff-1', 'frontdesk');
    assert.doesNotMatch(lateral.permissionStatusByStaff['staff-1'], /were removed/,
      'a teammate who never had finance access cannot have it "removed" by a lateral move');

    // a genuine demotion from a finance-capable role must still warn
    const demotion = buildContext('manager');
    vm.runInNewContext(`${src}`, demotion);
    await demotion.window.chRole('staff-1', 'staff');
    assert.match(demotion.permissionStatusByStaff['staff-1'], /were removed/);
  })();
});

/* ---------------------------------------------------------------- F097 */

test('F097 deleteBranchV285 refuses to even attempt deleting a branch with sales or appointment history', async () => {
  const src = section('  window.deleteBranchV285=async(branchId,button)=>{', "\n  window.toggleStaffBranch=async(");
  const toasts = [];
  const deleteCalls = { count: 0 };
  const context = {
    window: {},
    branchList: [{ id: 'b1', name: 'Orchard', is_default: false }],
    toast: message => toasts.push(String(message)),
    confirmActionV386: async () => true,
    prompt: () => 'Orchard',
    fail: () => {},
    load: () => {},
    S: { biz: { id: 'biz-1' } },
    sb: {
      from: table => ({
        select: () => ({ eq: () => ({ eq: async () => ({ count: table === 'sales' ? 2 : 0 }) }) }),
        delete: () => { deleteCalls.count += 1; return { eq: () => ({ eq: async () => ({ error: null }) }) }; },
      }),
    },
  };
  vm.runInNewContext(`${src}`, context);
  await context.window.deleteBranchV285('b1', { disabled: false });
  assert.equal(deleteCalls.count, 0, 'a branch with sales history must never even attempt the DELETE the FK will refuse');
  assert.match(toasts.join(' '), /has recorded sales or appointments, so it can't be deleted/);
});

test('F097 a branch with no history still deletes through the normal confirm+type-to-confirm flow', async () => {
  const src = section('  window.deleteBranchV285=async(branchId,button)=>{', "\n  window.toggleStaffBranch=async(");
  const toasts = [];
  let deleted = false;
  const context = {
    window: {},
    branchList: [{ id: 'b1', name: 'Orchard', is_default: false }],
    toast: message => toasts.push(String(message)),
    confirmActionV386: async () => true,
    prompt: () => 'Orchard',
    fail: () => {},
    load: () => {},
    S: { biz: { id: 'biz-1' } },
    sb: {
      from: () => ({
        select: () => ({ eq: () => ({ eq: async () => ({ count: 0 }) }) }),
        delete: () => ({ eq: () => ({ eq: async () => { deleted = true; return { error: null }; } }) }),
      }),
    },
  };
  vm.runInNewContext(`${src}`, context);
  await context.window.deleteBranchV285('b1', { disabled: false });
  assert.equal(deleted, true);
  assert.match(toasts.join(' '), /Branch deleted/);
});

/* ---------------------------------------------------------------- F102 */

test('F102 every mutation in wireBusinessProfileExtrasV418 repaints the live preview', () => {
  const src = section('function wireBusinessProfileExtrasV418(){', '\n/* V325 (owner-authorized exception #2, relocation).');
  const refreshCalls = (src.match(/refreshCustomerInterfaceLivePreviewV326\(\)/g) || []).length;
  assert.ok(refreshCalls >= 4, `expected the move/remove/add handlers and the save success path to all call refreshCustomerInterfaceLivePreviewV326 (found ${refreshCalls})`);
  assert.match(src, /galleryMoveV418[\s\S]*?renderBusinessProfileExtrasV418\(\);\s*refreshCustomerInterfaceLivePreviewV326\(\);/);
  assert.match(src, /galleryRemoveV418[\s\S]*?renderBusinessProfileExtrasV418\(\);\s*refreshCustomerInterfaceLivePreviewV326\(\);/);
  assert.match(src, /toast\('Photos and links saved'\);\s*await loadBusinessProfileExtrasV418\(\);\s*refreshCustomerInterfaceLivePreviewV326\(\);/);
});

/* ---------------------------------------------------------------- F136 */

test('F136 the Add-teammate commission % rejects an out-of-range value instead of silently discarding it', () => {
  const block = section("const bps=id=>{const raw=val(id);", "const button=listPanel.querySelector('#staffAddSave');");
  assert.match(block, /pct>=0&&pct<=100\?Math\.round\(pct\*100\):undefined/, 'an out-of-range/malformed value must resolve to undefined, not null');
  assert.match(block, /commission_service_bps===undefined\|\|commission_product_bps===undefined/);
  // exercise the actual bps() predicate against representative inputs
  const bpsSrc = section('    const bps=id=>{const raw=val(id);', "const commission_service_bps=bps('#staffAddSvc');");
  const context = { val: id => ({ '#a': '150', '#b': '-5', '#c': '', '#d': '15' }[id]) };
  const bps = vm.runInNewContext(`${bpsSrc} bps`, context);
  assert.equal(bps('#a'), undefined, '150% must be rejected, not collapsed to null');
  assert.equal(bps('#b'), undefined, '-5% must be rejected');
  assert.equal(bps('#c'), null, 'a blank field stays "not set"');
  assert.equal(bps('#d'), 1500, '15% still converts to 1500 bps');
});
