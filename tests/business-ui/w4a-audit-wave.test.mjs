/* W4A audit wave — regressions for F002-F012, F014-F017 (business Dashboard, Sales/refunds and
   shell-routing). Each test extracts the real source of the function/block under fix and EXECUTES
   it against stubs, so the assertions fail when the behaviour regresses rather than when the
   spelling changes — see tests/business-ui/w3b-audit-wave.test.mjs for the established pattern. */
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
const flush = async (times = 8) => { for (let i = 0; i < times; i++) await Promise.resolve(); };

/* ---------------------------------------------------------------- F002 */

test('F002 a reversed sale falls back to the ledger\'s own reversal_of linkage when the workflow read is denied', () => {
  const src = section(
    "const W=Object.fromEntries((workflow?.sales||[]).map(x=>[x.id,x]));",
    "salesWorkflowMayHaveMoreV291=!!workflow?.may_have_more;"
  );
  const run = (workflow, sl) => vm.runInNewContext(`(()=>{ ${src} return {W,workflowDeniedV579}; })()`, { workflow, sl });

  const sl = [
    { id: 'sale-1', reversal_of: null },
    { id: 'sale-2', reversal_of: 'sale-1' }, // the compensating reversal row
  ];
  const { W, workflowDeniedV579 } = run(null, sl); // 42501 swallowed to null
  assert.equal(workflowDeniedV579, true);
  assert.equal(W['sale-1'].reversal_sale_id, 'sale-2', 'derived from sl, not from an empty workflow map');
  assert.equal(W['sale-1'].net_amount_cents, 0, 'a fully reversed original nets to zero, not Gross');
  assert.equal(W['sale-1'].can_reverse, false, 'Reverse/Amend stay hidden — this role never had refund_sales');
  assert.match(W['sale-1'].refusal_reason, /Refund permission needed/);
});

test('F002 a legitimate workflow row is never overwritten by the fallback', () => {
  const src = section(
    "const W=Object.fromEntries((workflow?.sales||[]).map(x=>[x.id,x]));",
    "salesWorkflowMayHaveMoreV291=!!workflow?.may_have_more;"
  );
  const workflow = { sales: [{ id: 'sale-1', can_reverse: true, net_amount_cents: 5000 }] };
  const sl = [{ id: 'sale-1', reversal_of: null }];
  const { W } = vm.runInNewContext(`(()=>{ ${src} return {W}; })()`, { workflow, sl });
  assert.equal(W['sale-1'].can_reverse, true, 'a real can_reverse:true row is untouched');
  assert.equal(W['sale-1'].net_amount_cents, 5000);
});

test('F002 an original with no reversal anywhere in sl stays without a fallback entry', () => {
  const src = section(
    "const W=Object.fromEntries((workflow?.sales||[]).map(x=>[x.id,x]));",
    "salesWorkflowMayHaveMoreV291=!!workflow?.may_have_more;"
  );
  const sl = [{ id: 'sale-1', reversal_of: null }];
  const { W } = vm.runInNewContext(`(()=>{ ${src} return {W}; })()`, { workflow: null, sl });
  assert.equal(W['sale-1'], undefined, 'nothing to derive — this row genuinely has no workflow data');
});

/* ---------------------------------------------------------------- F003 */

test('F003 clicking Reverse refetches the live workflow row before opening the dialog', async () => {
  const src = section(
    "document.querySelectorAll('[data-reverse-kind]').forEach(btn=>btn.onclick=async()=>{",
    "/* nestly_v665: giving a free gift"
  );
  const btn = { dataset: { reverseKind: 'sale', reverseId: 'sale-1' } };
  const reversalItems = new Map([["sale:sale-1", { id: 'sale-1', client_id: 'client-9', can_reverse: true }]]);
  const loadCalls = [];
  const opens = [];
  const context = {
    document: { querySelectorAll: selector => selector === '[data-reverse-kind]' ? [btn] : [] },
    reversalItems,
    reversalItemKey: (kind, id) => `${kind}:${id}`,
    loadReversalWorkflows: async (clientId, limit, mode) => {
      loadCalls.push({ clientId, limit, mode });
      // Simulate a colleague having reversed it in the meantime: the refetch now says no.
      reversalItems.set('sale:sale-1', { id: 'sale-1', client_id: 'client-9', can_reverse: false, refusal_reason: 'This sale is already fully reversed.' });
      return { sales: [], redemptions: [] };
    },
    openReversalDialog: (kind, item) => opens.push({ kind, item }),
    onDone: () => {},
  };
  vm.runInNewContext(src, context);
  await btn.onclick();
  assert.equal(loadCalls.length, 1, 'the cached row is refetched, not trusted blindly');
  assert.equal(loadCalls[0].clientId, 'client-9', 'scoped to the item\'s own customer');
  assert.equal(opens.length, 1);
  assert.equal(opens[0].item.can_reverse, false,
    'the dialog receives the FRESH row (already-reversed), not the stale can_reverse:true cache — ' +
    'openReversalDialog\'s own guard now refuses up front instead of reaching the shortfall/override maze');
});

test('F003 a refetch failure falls back to the cached row rather than blocking the click', async () => {
  const src = section(
    "document.querySelectorAll('[data-reverse-kind]').forEach(btn=>btn.onclick=async()=>{",
    "/* nestly_v665: giving a free gift"
  );
  const btn = { dataset: { reverseKind: 'redemption', reverseId: 'r-1' } };
  const cachedItem = { id: 'r-1', client_id: 'client-2', can_reverse: true };
  const reversalItems = new Map([["redemption:r-1", cachedItem]]);
  const opens = [];
  const context = {
    document: { querySelectorAll: selector => selector === '[data-reverse-kind]' ? [btn] : [] },
    reversalItems,
    reversalItemKey: (kind, id) => `${kind}:${id}`,
    loadReversalWorkflows: async () => { throw new Error('network down'); },
    openReversalDialog: (kind, item) => opens.push({ kind, item }),
    onDone: () => {},
  };
  vm.runInNewContext(src, context);
  await btn.onclick();
  assert.equal(opens.length, 1);
  assert.equal(opens[0].item, cachedItem, 'network hiccup does not strand a still-valid reversal');
});

/* ---------------------------------------------------------------- F004 */

function buildOpenReversalDialog() {
  const src = section('function openReversalDialog(kind,item,onDone){', 'function bindReversalButtons(onDone){');
  const elements = {};
  const el = (extra = {}) => Object.assign({ disabled: false, textContent: '', innerHTML: '', value: '', checked: false, onclick: null, onchange: null, isConnected: true, insertAdjacentHTML: () => {} }, extra);
  elements.revClose = el(); elements.revCancel = el(); elements.revSubmit = el({ disabled: true });
  elements.revConfirm = el({ checked: true }); elements.revReason = el({ value: 'context' }); elements.revOutcome = el();
  elements.revCancel.insertAdjacentHTML = () => { elements.revReplay = el(); };
  const toasts = [];
  let onDoneCalls = 0;
  const rpcCalls = [];
  let resolveRpc;
  const rpcPromise = new Promise(resolve => { resolveRpc = resolve; });
  const context = {
    item: { id: 'sale-1', can_reverse: true, amount_cents: 5000 },
    kind: 'sale',
    onDone: () => { onDoneCalls++; },
    toast: message => toasts.push(String(message)),
    document: { body: { insertAdjacentHTML: () => { elements.reversalModal = el(); } } },
    $: id => elements[id],
    reversalKeys: new Map(),
    reversalItemKey: (k, id) => `${k}:${id}`,
    crypto: { randomUUID: () => 'idem-1' },
    CUI: { activateDialog: () => (() => { if (elements.reversalModal) elements.reversalModal.isConnected = false; }) },
    esc, money: cents => `SGD ${(Number(cents) / 100).toFixed(2)}`,
    BRAND: { productName: 'Peekaa' },
    confirmDeliberateV288: async () => true,
    S: { myRole: 'owner', biz: { id: 'biz-1' } },
    sb: { rpc: async (name, args) => { rpcCalls.push({ name, args }); return rpcPromise; } },
    reversalResultHtml: () => '<div>done</div>',
  };
  const openReversalDialog = vm.runInNewContext(`${src}; openReversalDialog`, context);
  return { openReversalDialog, elements, toasts, rpcCalls, resolveRpc, getOnDoneCalls: () => onDoneCalls, context };
}

test('F004 Cancel/Close/Escape are a no-op while a reversal is in flight', async () => {
  const { openReversalDialog, elements, rpcCalls, resolveRpc, getOnDoneCalls, context } = buildOpenReversalDialog();
  openReversalDialog('sale', { id: 'sale-1', can_reverse: true, amount_cents: 5000 }, context.onDone);
  const invokePromise = elements.revSubmit.onclick();
  await flush();
  assert.equal(rpcCalls.length, 1, 'the RPC is in flight');
  assert.equal(elements.revClose.disabled, true, 'Close is visibly disabled too');
  assert.equal(elements.revCancel.disabled, true);
  // Simulate Cancel/Close/Escape/backdrop — all funnel through the same close().
  elements.revCancel.onclick();
  elements.revClose.onclick();
  assert.equal(elements.reversalModal.isConnected, true, 'the dialog does not disappear mid-write');
  assert.equal(getOnDoneCalls(), 0, 'the caller\'s list is not refreshed before the write actually lands');
  resolveRpc({ data: { reversed_cents: 5000 }, error: null });
  await invokePromise;
  assert.equal(elements.revClose.disabled, false, 'controls re-enable once the write has landed');
  // Now Done/Close genuinely closes and refreshes.
  elements.revCancel.onclick();
  assert.equal(getOnDoneCalls(), 1);
});

test('F004 a stale close (no cached busy state) still surfaces the result instead of throwing on a null $()', async () => {
  const { openReversalDialog, elements, resolveRpc, toasts, getOnDoneCalls, context } = buildOpenReversalDialog();
  openReversalDialog('sale', { id: 'sale-1', can_reverse: true, amount_cents: 5000 }, context.onDone);
  const invokePromise = elements.revSubmit.onclick();
  await flush();
  // The modal is torn down by something outside this flow while the write is in flight
  // (the busy-guard above makes this unreachable via Cancel/Close now — this covers any other path).
  elements.reversalModal.isConnected = false;
  resolveRpc({ data: { reversed_cents: 5000 }, error: null });
  await invokePromise;
  assert.equal(getOnDoneCalls(), 1, 'the caller still gets told to refresh');
  assert.match(toasts.join(' '), /Reversal completed/);
});

/* ---------------------------------------------------------------- F005 */

const quickSaleFns = vm.runInNewContext(
  `${section('function quickSaleCorrectableV579(sale,paymentsBySale){', 'function saleRecordStatusV154(s,w={}){')}; ({quickSaleCorrectableV579, saleAmendCellV579})`,
  { esc });

test('F005 an unpaid quick sale stays correctable', () => {
  const sale = { id: 's-1', kind: 'quick_sale', amount_cents: 3500, reversal_of: null };
  assert.equal(quickSaleFns.quickSaleCorrectableV579(sale, new Map()).allowed, true);
  assert.match(quickSaleFns.saleAmendCellV579(sale, new Map()), /data-correct-sale="s-1"/);
});

test('F005 a fully cash-paid quick sale stays correctable', () => {
  const sale = { id: 's-2', kind: 'quick_sale', amount_cents: 3500, reversal_of: null };
  const payments = new Map([['s-2', [{ method: 'cash', amount_cents: 3500 }]]]);
  assert.equal(quickSaleFns.quickSaleCorrectableV579(sale, payments).allowed, true);
  assert.match(quickSaleFns.saleAmendCellV579(sale, payments), /Amend/);
});

test('F005 a card/PayNow-paid quick sale is refused up front instead of at the end of the confirm flow', () => {
  const sale = { id: 's-3', kind: 'quick_sale', amount_cents: 5300, reversal_of: null };
  const payments = new Map([['s-3', [{ method: 'card', amount_cents: 5300 }]]]);
  const result = quickSaleFns.quickSaleCorrectableV579(sale, payments);
  assert.equal(result.allowed, false);
  assert.match(result.reason, /reverse and record again/i);
  const html = quickSaleFns.saleAmendCellV579(sale, payments);
  assert.doesNotMatch(html, /data-correct-sale/, 'no Amend button offered — it would only fail at the very end');
  assert.match(html, /Card\/PayNow\/other-paid/);
});

test('F005 a reversal row or a $0 sale never offers Amend regardless of payments', () => {
  const reversalRow = { id: 's-4', kind: 'quick_sale', amount_cents: 3500, reversal_of: 's-3' };
  assert.equal(quickSaleFns.saleAmendCellV579(reversalRow, new Map()), '');
  const zeroSale = { id: 's-5', kind: 'quick_sale', amount_cents: 0, reversal_of: null };
  assert.equal(quickSaleFns.saleAmendCellV579(zeroSale, new Map()), '');
});

/* ---------------------------------------------------------------- F006 */

function makeChainable(log = []) {
  const obj = {};
  ['select', 'eq', 'gte', 'lt', 'order', 'in', 'limit'].forEach(method => {
    obj[method] = (...args) => { log.push([method, ...args]); return obj; };
  });
  return obj;
}

function buildLoadRecent() {
  const src = section('async function loadRecent(){', 'function renderSalesRowsV291(){');
  const elements = {
    salesFrom: { value: '' }, salesTo: { value: '' }, salesStaff: { value: '' },
    salesType: { value: '' }, salesPayment: { value: '' }, salesApply: { isConnected: true },
    salesCustomer: { value: '' },
  };
  const renderCalls = [];
  const fetchAllRowsResultQueue = [];
  let fetchAllRowsResultCallIndex = 0;
  const context = {
    salesLoadSeqV579: 0,
    salesFilteredRowsV291: [], salesWorkflowV291: {}, salesVisibleCountV291: 0,
    salesWorkflowMayHaveMoreV291: false, salesPaymentsBySaleV579: new Map(),
    SALES_PAGE_SIZE_V291: 50,
    $: id => elements[id],
    CUI: { setButtonBusy: () => {} },
    sb: { from: () => makeChainable() },
    S: { biz: { id: 'biz-1' } },
    selectedBranchId: '',
    fetchAllRowsResult: async () => {
      const idx = fetchAllRowsResultCallIndex++;
      return new Promise(resolve => { fetchAllRowsResultQueue[idx] = resolve; });
    },
    loadReversalWorkflows: async () => ({ sales: [], redemptions: [], may_have_more: false }),
    fetchRowsByIds: async () => [],
    fail: () => {},
    salesFilterNoteV266: () => {},
    dashboardScheduleDayLabelV252: value => value,
    renderSalesRowsV291: () => { renderCalls.push({ rows: context.salesFilteredRowsV291.slice() }); },
  };
  const loadRecent = vm.runInNewContext(`${src}; loadRecent`, context);
  return { loadRecent, context, elements, renderCalls, fetchAllRowsResultQueue };
}

test('F006 an older, slower filter load cannot overwrite a newer, faster one', async () => {
  const { loadRecent, context, renderCalls, fetchAllRowsResultQueue } = buildLoadRecent();
  const p1 = loadRecent(); // seq 1 — starts first, will resolve LAST
  await flush();
  const p2 = loadRecent(); // seq 2 — starts second, will resolve FIRST
  await flush();
  assert.equal(fetchAllRowsResultQueue.length, 2, 'both loads are genuinely in flight at once');
  // The newer call resolves first with its own (smaller) result set.
  fetchAllRowsResultQueue[1]({ data: [{ id: 'seq2-a' }], error: null });
  await flush();
  assert.equal(renderCalls.length, 1, 'seq 2 painted');
  assert.deepEqual(context.salesFilteredRowsV291.map(r => r.id), ['seq2-a']);
  // The stale, older call now resolves — it must NOT repaint over seq 2's answer.
  fetchAllRowsResultQueue[0]({ data: [{ id: 'seq1-a' }, { id: 'seq1-b' }], error: null });
  await flush();
  await Promise.all([p1, p2]);
  assert.equal(renderCalls.length, 1, 'the stale load never reached renderSalesRowsV291');
  assert.deepEqual(context.salesFilteredRowsV291.map(r => r.id), ['seq2-a'],
    'the table, summary and export set still reflect the newer filter, not the one that resolved last');
});

/* ---------------------------------------------------------------- F007 */

test('F007 the Inactive-customers dashboard tile no longer arms a filter its own dialog cannot consume', () => {
  const src = section(
    "kpis.querySelectorAll('[data-dashboard-metric]').forEach(button=>button.onclick=()=>{",
    'if(loyalty){'
  );
  globalThis.pendingCustomerInactivityTestFlagV579 = 'untouched';
  const button = { dataset: { dashboardMetric: 'inactive' } };
  const opens = [];
  const context = {
    kpis: { querySelectorAll: selector => selector === '[data-dashboard-metric]' ? [button] : [] },
    openDashboardMetricRowsV388: options => opens.push(options),
    from: '2026-08-01', to: '2026-08-31', scopePayload: {}, d: { scope: { branch_ids: null } },
    metrics: [{ key: 'inactive', value: '12' }],
    // pendingCustomerInactivity is intentionally NOT provided — if the fixed handler still wrote
    // to it, this throws ReferenceError in strict-adjacent vm evaluation instead of silently
    // creating a global, which is exactly what we want to prove it is gone.
  };
  vm.runInNewContext(src, context);
  button.onclick();
  assert.equal(opens.length, 1);
  assert.equal(opens[0].key, 'inactive');
  assert.equal(Object.prototype.hasOwnProperty.call(context, 'pendingCustomerInactivity'), false,
    'the handler never touches pendingCustomerInactivity any more — nothing stays armed for the next unrelated Customers visit');
});

/* ---------------------------------------------------------------- F008 */

const validVisitSales = vm.runInNewContext(`${section('function validVisitSales(rows){', '\n}')}\n}; validVisitSales`, {});

test('F008 validVisitSales still excludes an original whose reversal is in the same window', () => {
  const rows = [{ id: 'a', counts_as_visit: true, reversal_of: null }, { id: 'b', counts_as_visit: true, reversal_of: 'a' }];
  assert.deepEqual(validVisitSales(rows).map(r => r.id), []);
});

test('F008 the visits drill-down fetches out-of-window reversals so a later-reversed sale is excluded like the tile excludes it', async () => {
  const src = section('let visitScopeRowsV579=data||[];', "    if(key==='visits'){\n      /* nestly_v717");
  const data = [
    { id: 'aug-sale', client_id: 'c-1', counts_as_visit: true, reversal_of: null, occurred_at: '2026-08-15T10:00:00Z' },
  ];
  const fetchCalls = [];
  const context = {
    data, key: 'visits',
    fetchRowsByIds: async (table, columns, ids, idColumn) => {
      fetchCalls.push({ table, columns, ids, idColumn });
      // The reversal happened 2 Sep — outside the Aug window — but references the windowed original.
      return [{ id: 'sep-reversal', reversal_of: 'aug-sale' }];
    },
    fail: () => {},
    stillOpen: () => true,
    validVisitSales,
  };
  /* Merged with nestly_v717: the widened rows now feed groupVisitDaysV719 (one row per visit day),
     which itself applies validVisitSales — so the assertion is on what that grouping receives. */
  const result = await vm.runInNewContext(`(async()=>{ ${src}; return validVisitSales(visitScopeRowsV579); })()`, context);
  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].idColumn, 'reversal_of');
  assert.deepEqual(fetchCalls[0].ids, ['aug-sale'], 'only windowed originals are asked about');
  assert.equal(result.length, 0, 'the tile and the drill-down now agree: a sale reversed after the window still ends is excluded from both');
});

test('F008 an original with no reversal anywhere stays in the drill-down list', async () => {
  const src = section('let visitScopeRowsV579=data||[];', "    if(key==='visits'){\n      /* nestly_v717");
  const data = [{ id: 'clean-sale', client_id: 'c-1', counts_as_visit: true, reversal_of: null }];
  const context = {
    data, key: 'visits',
    fetchRowsByIds: async () => [],
    fail: () => {}, stillOpen: () => true, validVisitSales,
  };
  const scoped = await vm.runInNewContext(`(async()=>{ ${src}; return validVisitSales(visitScopeRowsV579); })()`, context);
  assert.deepEqual(Array.from(scoped, r => r.id), ['clean-sale']);
});

/* ---------------------------------------------------------------- F009 */

test('F009 the "+N more" chip opens today\'s list for today, and the picked day\'s own range otherwise', () => {
  const src = section('host.innerHTML=`<ol class="dashboard-schedule-chips">${shown.map(row=>{', '\n}\n/* V182');
  const run = (isTodayV252, day) => {
    const host = {};
    Object.defineProperty(host, 'innerHTML', { set(v) { host._v = v; }, get() { return host._v; } });
    vm.runInNewContext(`${src};`, {
      host, shown: [], overflow: 3, day, isTodayV252,
      esc, sgt: () => '', workspaceTemplateAttributeV97: () => '',
    });
    return host._v;
  };
  assert.match(run(true, '2026-09-02'), /href="#\/appointments\?view=list&preset=today"/);
  const html = run(false, '2026-09-03');
  assert.match(html, /href="#\/appointments\?view=list&from=2026-09-03&to=2026-09-03"/,
    'Tomorrow\'s overflow chip now points at Tomorrow, not at today\'s (possibly empty) list');
  assert.doesNotMatch(html, /preset=today/);
});

test('F009 the Appointments router honours an explicit from/to pair the same way it honours a preset', () => {
  const src = section("const routeFromV579=routeParamV288('from')", '\n  /* V375 (owner, photo 15):');
  const run = params => {
    const elements = { appointmentListFrom: { value: '' }, appointmentListTo: { value: '' } };
    const calls = { applyPreset: [], setView: [], loadGuarded: 0 };
    const context = {
      routeParamV288: name => params[name] || '',
      $: id => elements[id],
      applyAppointmentPresetV288: (preset, opts) => { calls.applyPreset.push(preset); return false; },
      setCalendarView: view => calls.setView.push(view),
      loadAppointmentsGuardedV288: () => { calls.loadGuarded++; },
      listPage: 3,
    };
    vm.runInNewContext(src, context);
    return { elements, calls, listPage: context.listPage };
  };
  const { elements, calls, listPage } = run({ view: 'list', from: '2026-09-03', to: '2026-09-03' });
  assert.equal(elements.appointmentListFrom.value, '2026-09-03');
  assert.equal(elements.appointmentListTo.value, '2026-09-03');
  assert.equal(listPage, 0, 'paging resets for the new range, same as a preset does');
  assert.deepEqual(calls.setView, ['list'], 'the explicit range reaches the list the same way preset=today would');

  const withPreset = run({ view: 'list', preset: 'today', from: '2026-09-03', to: '2026-09-03' });
  assert.equal(withPreset.elements.appointmentListFrom.value, '', 'an explicit preset still wins over stray from/to params');
});

/* ---------------------------------------------------------------- F010 */

test('F010 the New-customers drill-down states its own cap instead of silently truncating', async () => {
  const src = section("if(key==='new'){", "if(key==='inactive'){");
  const run = async rows => {
    const tableCalls = [];
    const notes = [];
    const context = {
      key: 'new',
      sb: { from: () => makeChainable() },
      S: { biz: { id: 'biz-1' } }, from: '2026-08-01', to: '2026-08-31',
      sgDateBoundary: d => d,
      stillOpen: () => true,
      failed: () => {},
      ownerErrorText: e => String(e),
      body: { insertAdjacentHTML: (pos, html) => notes.push(html) },
      table: (head, rowsHtml) => { tableCalls.push(rowsHtml.length); return '<table></table>'; },
      customerCellV408: id => `<b>${id}</b>`,
      esc, sgLedgerDateV154: () => ({ date: '01/08/2026' }),
    };
    // Patch the chain's terminal await target: sb.from(...).select(...)... resolves via awaiting
    // the chainable itself, so give it a `then` that fulfils with the supplied rows.
    context.sb.from = () => {
      const chain = makeChainable();
      chain.then = (resolve) => resolve({ data: rows, error: null });
      return chain;
    };
    await vm.runInNewContext(`(async()=>{ ${src} })()`, context);
    return { tableCalls, notes };
  };
  const under = await run(Array.from({ length: 3 }, (_, i) => ({ id: `c${i}`, created_at: '2026-08-01' })));
  assert.equal(under.notes.length, 0, 'well under the cap: no note');

  const atCap = await run(Array.from({ length: 500 }, (_, i) => ({ id: `c${i}`, created_at: '2026-08-01' })));
  assert.equal(atCap.notes.length, 1);
  assert.match(atCap.notes[0], /Showing the first 500\. Open Customers for the rest\./);
});

/* ---------------------------------------------------------------- F011 */

test('F011 a date range beyond 1827 days is refused client-side with its own reason, not a generic failure', () => {
  const src = section('if(daysBetweenSgInputsV153(from,to)>1827)', 'killCharts();');
  const run = (from, to) => {
    const calls = [];
    vm.runInNewContext(`(()=>{ ${src} })()`, {
      from, to,
      daysBetweenSgInputsV153: vm.runInNewContext(`${section('function daysBetweenSgInputsV153(from,to){', '\n}')}\n}; daysBetweenSgInputsV153`, {}),
      showLoadError: (message, retryId) => calls.push({ message, retryId }),
    });
    return calls;
  };
  const start = '2020-01-01';
  const under = new Date(Date.parse(start + 'T00:00:00Z') + 1826 * 86400000).toISOString().slice(0, 10); // 1827 days inclusive
  const over = new Date(Date.parse(start + 'T00:00:00Z') + 1827 * 86400000).toISOString().slice(0, 10); // 1828 days inclusive
  assert.deepEqual(run(start, under), [], 'exactly 1827 days is still allowed');
  const refused = run(start, over);
  assert.equal(refused.length, 1);
  assert.match(refused[0].message, /5 years|1827/);
});

test('F011 when the branch-scope hint is empty, the raw server reason is shown instead of a dead-end generic message', () => {
  const src = section("branchScopeErrorHintV217(error)||ownerErrorText(error)", ');return}');
  const html = vm.runInNewContext(`(${src})`, {
    branchScopeErrorHintV217: () => '',
    ownerErrorText: error => error.message,
    error: { message: 'report date range cannot exceed 1827 days' },
  });
  assert.equal(html, 'report date range cannot exceed 1827 days');
});

/* ---------------------------------------------------------------- F012 */

test('F012 the visits/revenue drill-down query paginates on a unique key, not bare occurred_at', () => {
  const src = section('const {data,error}=await fetchAllRowsResult(()=>{', 'if(!stillOpen())return;');
  const log = [];
  vm.runInNewContext(`(async()=>{ ${src} })()`, {
    sb: { from: () => makeChainable(log) },
    S: { biz: { id: 'biz-1' } }, from: '2026-08-01', to: '2026-08-31',
    sgDateBoundary: d => d,
    branchIdsV519: null,
    fetchAllRowsResult: async factory => { factory(); return { data: [], error: null }; },
    stillOpen: () => true,
  });
  // Cross-realm safety: {ascending:false} was built by code executing INSIDE the vm context, so
  // it must be re-plained in this realm before deepEqual — otherwise a structurally identical
  // object fails deepStrictEqual purely on prototype identity.
  const orderCalls = log.filter(entry => entry[0] === 'order').map(([method, column, opts]) => [method, column, { ...opts }]);
  assert.deepEqual(orderCalls, [
    ['order', 'occurred_at', { ascending: false }],
    ['order', 'id', { ascending: false }],
  ], 'occurred_at is not unique across sales — id is now the tiebreaker, matching the ledger read beside it');
});

/* ---------------------------------------------------------------- F014 */

const navModuleVisibleFn = (S, overrides = {}) => vm.runInNewContext(
  /* nestly_v768 (main) prefixes the predicate with a retired-module guard; the F014 owner-only
     clause sits inside it. */
  `${section("const navModuleVisible=m=>!RETIRED_BUSINESS_MODULES_V768.has(m)&&((m==='dashboard'", 'const visGroups=')}; navModuleVisible`,
  { enabled: overrides.enabled || [], S, sectorShowsBottlesV275: false, sectorHidesAppointmentsV246: false, RETIRED_BUSINESS_MODULES_V768: new Set() });

test('F014 the Staff Members rail row now matches the page it opens: owner only', () => {
  assert.equal(navModuleVisibleFn({ myRole: 'owner' })('staffmembers'), true);
  assert.equal(navModuleVisibleFn({ myRole: 'manager' })('staffmembers'), false,
    'a manager used to see this row and then always hit "Only the owner can open this — Settings"');
  assert.equal(navModuleVisibleFn({ myRole: 'staff' })('staffmembers'), false);
});

/* ---------------------------------------------------------------- F015 */

test('F015 "Check again" invalidates the cached workspace-control answer before re-routing', () => {
  const src = section("$('businessControlRetry').onclick=", '};') + '}';
  const calls = [];
  const context = {
    $: () => ({ set onclick(fn) { context._onclick = fn; } }),
    invalidateBusinessControlCacheV370: () => calls.push('control'),
    invalidatePersonaCacheV370: () => calls.push('persona'),
    route: () => calls.push('route'),
  };
  vm.runInNewContext(src + ';', context);
  context._onclick();
  assert.deepEqual(calls, ['control', 'persona', 'route'],
    'the cache is cleared BEFORE route() re-reads it, so an approval that just landed is seen immediately');
});

/* ---------------------------------------------------------------- F016 / F017 */

const buildStaffMobileActionsHtml = grants => {
  const src = section('function staffMobileActionsHtml(page){', 'function wireStaffMobileActions(){');
  const context = {
    canReadModule: module => !!grants[module],
    canWriteModule: module => !!grants[`write:${module}`],
    hasRoleCapability: () => grants.createSales !== false,
    canScanCustomerRedemption: () => grants.scanEligible !== false,
    sectorHidesAppointmentsV276: () => false,
    CUI: { icon: () => '' },
    S: { myRole: grants.role || 'staff', biz: {}, user: {} },
    BRAND: { productName: 'Peekaa' }, INDUSTRIES: {},
    esc, workspaceLanguagePickerV97: () => '', navHtml: () => '',
  };
  const fn = vm.runInNewContext(`${src}; staffMobileActionsHtml`, context);
  return fn(['till']);
};

test('F016 Scan QR is withheld from a staff account without till access, even if it would otherwise qualify', () => {
  const withTill = buildStaffMobileActionsHtml({ till: true, clients: true, 'write:loyalty': true });
  assert.match(withTill, /id="staffMobileScan"/);
  const withoutTill = buildStaffMobileActionsHtml({ till: false, clients: true, 'write:loyalty': true });
  assert.doesNotMatch(withoutTill, /id="staffMobileScan"/,
    'Customers + Loyalty write but no Record sale used to still show a Scan QR button that always bounced');
});

test('F017 Workspace settings only renders in the mobile drawer for an owner', () => {
  const owner = buildStaffMobileActionsHtml({ role: 'owner', till: true, clients: true });
  assert.match(owner, /href="#\/settings">Workspace settings/);
  const frontdesk = buildStaffMobileActionsHtml({ role: 'frontdesk', till: true, clients: true });
  assert.doesNotMatch(frontdesk, /Workspace settings/,
    'every non-owner used to see a link that always toasts "Only the owner can open Settings" and bounces');
});
