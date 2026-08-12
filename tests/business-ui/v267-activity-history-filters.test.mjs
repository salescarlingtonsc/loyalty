/* V267 — two owner reports about Customer 360 → Activity history.
   A. The owner circled three raw database UUIDs in the reversal pills and asked "what is this?".
      A UUID is not something a shop owner can act on, and it reads as a bug. The reference now
      describes the counterpart row in its own terms (what it was, and when), links to it when
      that row is on screen, and says so honestly when it cannot be resolved at all.
   B. "Customer Activity History, I want a drop down filter i can filter what i want to see",
      with DATE / TYPE / ITEM circled and sort arrows drawn beside AMOUNT and STAFF.

   The pure helpers and the renderer are EXECUTED here rather than pattern-matched, because the
   things that went wrong before on this surface — a "to" date that excluded its own day, a
   filter that reports "nothing" while rows sit one page below — are behaviours, not spellings. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const clientDetail = app.slice(app.indexOf('async function clientDetail(id){'), app.indexOf('function activityTypeOfV267'));
const activityModule = app.slice(app.indexOf('const ACTIVITY_STAFF_NONE_V267='), app.indexOf('/* ---------- quick earn'));

/* ---- executable harness: the real helpers, with the app's own esc/money/sgt/sgIso ---- */
const controls = {};
const $ = (id) => (Object.prototype.hasOwnProperty.call(controls, id) ? controls[id] : null);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (c) => 'SGD ' + ((c || 0) / 100).toFixed(2);
const sgt = (iso) => { if (!iso) return null; const d = new Date(new Date(iso).getTime() + 8 * 3600000); return d.toISOString().slice(0, 16).replace('T', ' '); };
const sgIso = (v) => (v ? new Date(v + ':00+08:00').toISOString() : null);
const CUI = {
  icon: () => '<svg></svg>',
  emptyState: ({ title = '', body = '', actionHtml = '' } = {}) =>
    `<div class="cui-empty" data-title="${esc(title)}"><h3>${esc(title)}</h3><p>${esc(body)}</p>${actionHtml}</div>`,
};
const campaignEntitlementDisplayV99 = (g) => ({ pending: g?.fulfillment_kind === 'campaign_pending', title: 'Campaign' });
/* v281: the sort header's aria-label goes through the v97 reviewed-template mechanism; the
   harness renders it exactly as production does (attribute + marker), resolved to English. */
const workspaceTemplateAttributeV97 = (attribute, key, values = {}) => {
  const en = { sortByAscending: 'Sort by {label}, ascending', sortByDescending: 'Sort by {label}, descending' }[key] || key;
  const text = en.replace(/\{([a-z0-9_]+)\}/gi, (_, name) => String(values[name] ?? ''));
  return `data-workspace-i18n ${attribute}="${esc(text)}"`;
};

const A = new Function('$', 'esc', 'money', 'sgt', 'sgIso', 'CUI', 'campaignEntitlementDisplayV99', 'workspaceTemplateAttributeV97', `${activityModule}
  return {renderHistPage,activityFilteredRowsV267,activityFilterStateV267,activityTypeOfV267,
    activityAmountCentsV267,activityRangeBoundV267,activityItemTextV267,activityWhenTextV267,
    ACTIVITY_SORTS_V267,ACTIVITY_SORT_DEFAULT_V267,ACTIVITY_STAFF_NONE_V267};`)(
  $, esc, money, sgt, sgIso, CUI, campaignEntitlementDisplayV99, workspaceTemplateAttributeV97,
);

function setFilters(values = {}) {
  for (const key of Object.keys(controls)) delete controls[key];
  for (const [id, value] of Object.entries(values)) controls[id] = { value: String(value) };
}

const ORIGINAL_ID = 'f82e92b2-9811-4780-9416-f9b2022aaf3f';
const REVERSAL_ID = '973976e0-98f9-44a7-8aea-8fb2db91a246';
const ORPHAN_ID = '9c1b3ab2-109a-4590-84ec-404832e250a2';
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

/* What a person actually reads: markup with every tag (and therefore every attribute) removed.
   Anchors and data-reverse-id legitimately carry ids; the visible sentence never may. */
const visibleText = (html) => html.replace(/<[^>]*>/g, ' ');

function fixture() {
  return [
    {
      t: '2026-08-09T15:59:45Z', kind: 'sale', id: ORIGINAL_ID, saleKind: 'service',
      note: 'package session used: 5x facial', amount: 0, is_reversal: false,
      reversal_sale_id: REVERSAL_ID, net_amount_cents: 0, staff: 'Aisyah',
      refusal_reason: 'This sale is already fully reversed.',
    },
    {
      t: '2026-08-09T16:10:00Z', kind: 'sale', id: REVERSAL_ID, saleKind: 'service',
      note: 'Peekaa quick reversal: Staff-confirmed sale reversal', amount: 0, is_reversal: true,
      original_sale_id: ORIGINAL_ID, is_package_session: true, staff: 'Aisyah',
      refusal_reason: 'This row is already a reversal.',
    },
    {
      /* The counterpart of this one is deliberately absent — an older original outside this
         customer's visible sales. This is the case that WILL happen for old rows. */
      t: '2026-08-08T04:00:00Z', kind: 'sale', id: 'aa11bb22-3333-4444-5555-666677778888',
      saleKind: 'quick_sale', amount: -158, is_reversal: true, original_sale_id: ORPHAN_ID,
      staff: 'Bala',
    },
    { t: '2026-08-07T02:00:00Z', kind: 'appointment', service: 'Gel manicure', status: 'completed', staff: 'Chen Wei' },
    { t: '2026-08-06T02:00:00Z', kind: 'appointment', service: 'Consultation', status: 'booked', staff: null },
    { t: '2026-08-05T02:00:00Z', kind: 'package', plan: '5x facial', status: 'active', remaining: 3, sessions: 5 },
    { t: '2026-08-04T02:00:00Z', kind: 'sale', id: 'cc11dd22-3333-4444-5555-666677779999', saleKind: 'retail', amount: 4500, is_reversal: false, staff: 'Bala' },
  ];
}

/* ============================ ITEM A — no raw UUIDs ============================ */

test('A1 no bare database id is ever rendered as readable text', () => {
  setFilters({});
  const html = A.renderHistPage(fixture(), 50);
  assert.ok(!UUID_RE.test(visibleText(html)), 'the visible sentence must not contain a UUID');
  // The source must not have kept the old raw-id renderings either.
  assert.ok(!app.includes('${esc(h.original_sale_id||\'\')}'), 'the raw original-id pill is gone');
  assert.ok(!app.includes('<span data-merchant-content>${esc(h.reversal_sale_id)}</span>'), 'the raw reversal-id pill is gone');
});

test('A2 a reversal names the counterpart row in its own terms, and stays unmistakably a reversal', () => {
  setFilters({});
  const html = A.renderHistPage(fixture(), 50);
  const text = visibleText(html);
  assert.ok(text.includes('reversal of'), 'the audit word survives');
  assert.ok(text.includes('reversed →'), 'the original still says it was reversed');
  assert.ok(text.includes('package session used: 5x facial'), 'the counterpart is described by what it was');
  assert.ok(/9 Aug 2026, 23:59/.test(text), 'and by when it happened, in Singapore time');
  // The audit facts the owner must still be able to see.
  assert.ok(text.includes('This sale is already fully reversed.'));
  assert.ok(text.includes('This row is already a reversal.'));
  assert.ok(text.includes('Package session · reversal restores one session with no payment refund'));
  assert.ok(text.includes('Net SGD 0.00'), 'the net-after-reversal figure survives');
});

test('A3 an unresolvable counterpart gets an honest sentence, never the id as a fallback', () => {
  setFilters({});
  const text = visibleText(A.renderHistPage(fixture(), 50));
  assert.ok(text.includes('an earlier sale that is not in this history'),
    'the orphan reversal says plainly that the counterpart is not here');
  assert.ok(!text.includes(ORPHAN_ID));
  // The honest branch must also be reachable for the other direction (an original whose
  // correction row is outside this history), or old rows would fall back to nothing.
  assert.ok(app.includes("'a correction that is not in this history'"));
});

test('A4 the reference navigates only when the counterpart row is actually painted', () => {
  setFilters({});
  const both = A.renderHistPage(fixture(), 50);
  assert.ok(both.includes(`data-act-jump="c360-act-sale-${ORIGINAL_ID}"`), 'jumps to the counterpart row');
  assert.ok(both.includes(`id="c360-act-sale-${ORIGINAL_ID}"`), 'and that row carries the anchor');
  // Page down to a single row: the counterpart is no longer on screen, so no fake navigation.
  setFilters({});
  const one = A.renderHistPage(fixture(), 1);
  assert.ok(!one.includes('data-act-jump'), 'no jump is offered to a row that is not rendered');
  assert.ok(visibleText(one).includes('reversal of'), 'the reference itself still reads');
  assert.ok(visibleText(one).includes('package session used: 5x facial'),
    'and still describes the counterpart, just without offering to jump to it');
  assert.ok(!UUID_RE.test(visibleText(one)));
});

test('A5 the jump handler is wired and refuses to move when the target is gone', () => {
  assert.ok(app.includes("document.querySelectorAll('[data-act-jump]')"));
  assert.ok(app.includes('const target=document.getElementById(button.dataset.actJump);'));
  assert.ok(app.includes('if(!target)return;'), 'never pretend to navigate');
  assert.ok(app.includes("target.classList.add('c360-act-flash-v267')"), 'the two rows are visually paired');
  assert.ok(shell.includes('.c360-act-flash-v267'), 'and that pairing carries styling');
});

/* ============================ ITEM B — filters and sorting ============================ */

test('B1 the type menu is derived from the same function that labels the rows', () => {
  // Derivation, not a hand-written list: the menu cannot offer a type the table never renders.
  assert.ok(clientDetail.includes('[...new Set(history.map(activityTypeOfV267))]'));
  assert.ok(activityModule.includes('type:activityTypeOfV267(h)'), 'the cell reads the same function');
  const kinds = fixture().map(A.activityTypeOfV267);
  assert.deepEqual([...new Set(kinds)].sort(), ['Appointment', 'Package', 'Reversal', 'Sale']);
  assert.equal(A.activityTypeOfV267({ kind: 'redemption' }), 'Reward');
  assert.equal(A.activityTypeOfV267({ kind: 'grant' }), 'Retention');
  assert.equal(A.activityTypeOfV267({ kind: 'membership' }), 'Membership');
});

test('B2 filtering by type keeps only that type', () => {
  setFilters({ actType: 'Reversal' });
  const rows = A.activityFilteredRowsV267(fixture());
  assert.equal(rows.length, 2);
  assert.ok(rows.every((r) => r.is_reversal === true));
});

test('B3 the staff menu lists only people present in THIS customer history', () => {
  assert.ok(clientDetail.includes('[...new Set(history.map(h=>h.staff).filter(Boolean))]'),
    'names come from the rows, not from the whole employee roster');
  assert.ok(clientDetail.includes('const activityHasUnassignedV267=history.some(h=>!h.staff)'));
  setFilters({ actStaff: 'Bala' });
  assert.equal(A.activityFilteredRowsV267(fixture()).length, 2);
  setFilters({ actStaff: A.ACTIVITY_STAFF_NONE_V267 });
  const none = A.activityFilteredRowsV267(fixture());
  assert.ok(none.length > 0 && none.every((r) => !r.staff), 'rows with no team member are reachable too');
});

test('B4 the date range is Singapore time and the "to" day is inclusive to its last second', () => {
  // The regression this repo has shipped before: a sale late on the "to" day disappearing.
  const late = fixture()[0]; // 2026-08-09 23:59:45 SGT
  assert.equal(sgt(late.t).slice(0, 10), '2026-08-09');
  setFilters({ actFrom: '2026-08-09', actTo: '2026-08-09' });
  const rows = A.activityFilteredRowsV267(fixture());
  assert.ok(rows.some((r) => r.id === ORIGINAL_ID), 'a 23:59:45 SGT row is inside a range ending on its own day');
  // The reversal row is 2026-08-10 00:10 SGT, so a range ending 9 Aug correctly excludes it.
  assert.equal(rows.length, 1, 'and only that Singapore day is shown');
  // The minute-resolution bound the sales ledger uses would have dropped it.
  assert.ok(Date.parse(sgIso('2026-08-09T23:59')) < Date.parse(late.t));
  assert.ok(A.activityRangeBoundV267('2026-08-09', { end: true }) > Date.parse(late.t));
  assert.equal(A.activityRangeBoundV267(''), null);
  assert.equal(A.activityRangeBoundV267('not-a-date'), null);
  // An open-ended range still works from one side only.
  setFilters({ actFrom: '2026-08-09' });
  assert.equal(A.activityFilteredRowsV267(fixture()).length, 2);
  setFilters({ actTo: '2026-08-05' });
  assert.equal(A.activityFilteredRowsV267(fixture()).length, 2);
});

test('B5 every sort the owner marked exists, in both directions', () => {
  assert.deepEqual(A.ACTIVITY_SORTS_V267.map((o) => o.key),
    ['date_desc', 'date_asc', 'amount_desc', 'amount_asc', 'staff_asc', 'staff_desc']);
  assert.equal(A.ACTIVITY_SORT_DEFAULT_V267, 'date_desc');

  setFilters({ actSort: 'date_asc' });
  const oldestFirst = A.activityFilteredRowsV267(fixture()).map((r) => r.t);
  assert.deepEqual(oldestFirst, [...oldestFirst].sort());

  setFilters({ actSort: 'amount_desc' });
  const byAmount = A.activityFilteredRowsV267(fixture());
  assert.equal(byAmount[0].amount, 4500, 'the biggest sale leads');
  // Rows that carry no money sink to the bottom in BOTH directions rather than posing as 0.00.
  assert.equal(A.activityAmountCentsV267({ kind: 'appointment' }), null);
  const tail = byAmount.slice(-3).every((r) => A.activityAmountCentsV267(r) === null);
  assert.ok(tail, 'non-monetary rows are last on a descending amount sort');
  setFilters({ actSort: 'amount_asc' });
  const ascending = A.activityFilteredRowsV267(fixture());
  assert.ok(ascending.slice(-3).every((r) => A.activityAmountCentsV267(r) === null),
    'and last on an ascending one too — null is not a low number');
  assert.equal(ascending[0].amount, -158, 'the reversal is the lowest real amount');

  setFilters({ actSort: 'staff_asc' });
  const names = A.activityFilteredRowsV267(fixture()).map((r) => r.staff).filter(Boolean);
  assert.deepEqual(names, [...names].sort((a, b) => a.localeCompare(b)));
  setFilters({ actSort: 'staff_desc' });
  const reversed = A.activityFilteredRowsV267(fixture()).map((r) => r.staff).filter(Boolean);
  assert.deepEqual(reversed, [...names].reverse());
  // An unknown sort value falls back to the default rather than throwing away the ordering.
  setFilters({ actSort: 'nonsense' });
  assert.equal(A.activityFilterStateV267().sort, 'date_desc');
});

test('B6 the current sort is visible on the header the owner marked', () => {
  setFilters({ actSort: 'amount_asc' });
  const html = A.renderHistPage(fixture(), 50);
  assert.ok(/<th aria-sort="ascending"><button type="button" class="c360-act-sort-v267" data-act-sort="amount_desc"[^>]*>Amount/.test(html),
    'the Amount header announces its direction and offers the opposite one next');
  assert.ok(html.includes('aria-sort="none"'), 'the columns not sorted say so');
  assert.ok(html.includes('data-act-sort="date_desc"') && html.includes('data-act-sort="staff_desc"'),
    'date and staff are sortable from their headers too');
  // Headers stay in the owner-approved order.
  assert.ok(html.indexOf('>Date<') < html.indexOf('>Type</th>'));
  assert.ok(html.indexOf('>Type</th>') < html.indexOf('>Item</th>'));
  assert.ok(html.indexOf('>Item</th>') < html.indexOf('>Amount<'));
  assert.ok(html.indexOf('>Amount<') < html.indexOf('>Staff<'));
});

test('B7 a filtered-empty table is a different message from a genuinely empty one', () => {
  setFilters({ actType: 'Membership' });
  const hidden = A.renderHistPage(fixture(), 50);
  assert.ok(hidden.includes('No activity matches these filters'));
  assert.ok(visibleText(hidden).includes('the filters above are hiding all of it'),
    'the owner is told a filter is responsible, not that the customer has no history');
  assert.ok(hidden.includes('id="actClearEmpty"'), 'and is offered a way out from inside the empty state');

  setFilters({});
  const genuinely = A.renderHistPage([], 50);
  assert.ok(genuinely.includes('No activity is recorded in the sources available to this role yet.'));
  assert.ok(!genuinely.includes('No activity matches these filters'));
  assert.ok(!genuinely.includes('actClearEmpty'), 'nothing to clear when there is nothing to show');
});

test('B8 the filter controls exist, are labelled, and every one of them redraws the table', () => {
  for (const id of ['actItem', 'actType', 'actStaff', 'actFrom', 'actTo', 'actSort']) {
    assert.ok(clientDetail.includes(`id="${id}"`), `${id} must exist`);
    assert.ok(clientDetail.includes(`for="${id}"`), `${id} must be labelled`);
  }
  assert.ok(clientDetail.includes('<input type="date" id="actFrom">') && clientDetail.includes('<input type="date" id="actTo">'));
  /* V270: six, not five — the ITEM search the owner circled was missing from the V267 pass. */
  assert.ok(clientDetail.includes("['actItem','actType','actStaff','actFrom','actTo','actSort'].forEach(controlId=>{"),
    'all six controls are wired to the one redraw');
  assert.ok(clientDetail.includes('control.onchange=()=>{histShown=50;redrawActivityV267()}'),
    'changing a filter returns to the first page');
  assert.ok(clientDetail.includes("clearActivity.onclick=()=>{clearActivityFiltersV267();histShown=50;redrawActivityV267()}"));
  // Existing repo patterns, not new ones: the app's own filter bar, label/select, and buttons.
  assert.ok(clientDetail.includes('class="v150-filterbar c360-activity-filters-v267"'));
  assert.ok(shell.includes('.v150-filterbar{display:flex'), 'that bar already wraps on a narrow screen');
  assert.ok(shell.includes('.c360-activity-filters-v267'));
  // On a 390px phone each control is allowed to take the full row rather than overflow.
  assert.ok(/min-width:min\(100%,1[5-9]5px\)/.test(clientDetail));
});

test('B9 filtering is applied before paging, so a filter never reports a false "nothing"', () => {
  // The row that matches sits at the very bottom of the feed; with a page size of 1 a
  // page-then-filter implementation would render the filtered-empty state instead.
  setFilters({ actStaff: 'Chen Wei' });
  const html = A.renderHistPage(fixture(), 1);
  assert.ok(!html.includes('No activity matches these filters'));
  assert.ok(visibleText(html).includes('Gel manicure'));
});

test('B10 the Show earlier control counts the filtered rows, not the whole feed', () => {
  assert.ok(clientDetail.includes("moreWrap.style.display=activityFilteredRowsV267(history).length>histShown?'':'none'"),
    'paging and filtering read one shared result');
  assert.ok(clientDetail.includes("$('histBody').innerHTML=renderHistPage(history,histShown)"),
    'the same renderer still drives the body');
  assert.ok(clientDetail.includes('if(histMore) histMore.onclick=()=>{histShown+=50;redrawActivityV267()}'));
});

test('B11 the whole history is in memory, so client-side filtering cannot hide a server page', () => {
  // Sales, appointments, memberships, packages and redemptions are all fetched with the
  // unlimited paging helpers before they are merged. If that ever changes, a client-side
  // filter becomes a trap and this test is the tripwire.
  assert.ok(clientDetail.includes("canReadSales?fetchAllRows(()=>sb.from('sales')"));
  assert.ok(clientDetail.includes("canReadAppointments?fetchAllRowsResult(()=>sb.from('appointments')"));
  assert.ok(clientDetail.includes("canReadMemberships?fetchAllRowsResult(()=>sb.from('memberships')"));
  assert.ok(clientDetail.includes("canReadPackages?fetchAllRowsResult(()=>sb.from('client_packages')"));
  assert.ok(clientDetail.includes('canReadLoyalty?fetchAllRowsResult(()=>sb.rpc(\'list_customer_redemption_history_v145\''));
});

/* V267 addendum — the owner's "what is this?" was raised on Customer 360, but the same raw
   record id was rendered on three other surfaces. Two of them are ordinary operational views
   where an id is noise; the third is a deliberate audit disclosure where the id is the point,
   so it stays and is merely labelled as a record id instead of being dropped into prose. */
test('V267 no operational surface prints a bare record id for a reversal', () => {
  // Packages session-correction history, in all three shipped languages.
  assert.doesNotMatch(app, /Reversal of \{id\}/);
  assert.doesNotMatch(app, /reversed by \{id\}/);
  assert.match(app, /reversalOf:Object\.freeze\(\{en:'Reversal of an earlier session use'/);
  assert.match(app, /usedSessionReversedBy:Object\.freeze\(\{en:'Used session → later reversed'/);

  // Daily report's all-sales table no longer echoes the id next to "reversal of".
  assert.doesNotMatch(app, /<span data-workspace-i18n>reversal of<\/span> <span data-merchant-content>\$\{esc\(r\.reversal_of\)\}/);
  assert.match(app, /reversal of an earlier sale/);
});

test('V267 the Sales audit disclosure keeps the id, but calls it a record id', () => {
  // Deliberate exception: this text lives inside the collapsed "Audit details" disclosure and
  // is the one place a reconciler genuinely needs the key. It must not read as prose.
  assert.match(app, /Compensating reversal row\. Audit record id of the sale it reverses: \$\{s\.reversal_of\}/);
  assert.match(app, /Original sale row, fully reversed\. Audit record id of the reversal: \$\{w\.reversal_sale_id\}/);
});

/* V270 — the owner circled DATE, TYPE and ITEM on the Activity history header. Type and date
   shipped in V267; ITEM did not. Item values are free text across six different row shapes
   (service, plan name, reward name, sale kind), so a substring search over the SAME text the
   ITEM cell renders is the only honest form: it cannot disagree with what is on screen. */
test('V270 the ITEM search exists, is labelled, and matches the text the ITEM cell prints', () => {
  assert.match(clientDetail, /<label for="actItem">Item<\/label><input type="search" id="actItem"/);
  assert.match(app, /if\(s\.item&&!activityItemTextV267\(h\)\.toLowerCase\(\)\.includes\(s\.item\)\)return false;/);
  assert.match(app, /item:read\('actItem'\)\.trim\(\)\.toLowerCase\(\)/);
});

test('V270 clearing the filters clears the ITEM search too', () => {
  assert.match(app, /\['actItem','actType','actStaff','actFrom','actTo'\]\.forEach\(controlId=>\{const el=\$\(controlId\);if\(el\)el\.value=''\}\);/);
});
