/* nestly_v719 — the owner dashboard's Visits KPI drill-down must list VISIT DAYS, not raw sales.

   nestly_v714 (committed) changed the Visits KPI itself to count DISTINCT (client, Asia/Singapore
   calendar day) — a split bill is one visit — but left a debt on record ("the dashboard's Visits
   drill-down still lists raw sales in the browser"): openDashboardMetricRowsV388's 'visits' branch
   queried public.sales directly and rendered one row per sale, so a tile reading 8 opened a dialog
   listing 10. This closes that debt.

   groupVisitDaysV719 groups the SAME rows validVisitSales() already scopes (counts_as_visit, never
   a reversal, never a reversed original) by (client_id, SG calendar day via sgt()); a sale with no
   client_id (a walk-in) stays its own row, exactly as it cannot be folded into anyone else's day.
   visitDaySummaryV719 is the one-line "N tickets · amount" the row prints.

   These tests EXECUTE both functions via vm against a fixture shaped like the truth table nestly_v714
   itself records: "R three same-day + next day + a week later, C five distinct days -> KPI 8 not 10,
   R 3, C 5." There is no client-side re-implementation of the server's visit-day COUNT to import and
   compare against (get_dashboard_summary_v155 computes that count entirely server-side and the tile
   only prints what the RPC returns) — so the assertion is against the literal 8 from that same truth
   table nestly_v714 recorded, with this comment explaining why. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/* ---------------------------------------------------------------- extraction */

const sgtLineMatch = app.match(/^const sgt=.*$/m);
assert.ok(sgtLineMatch, 'sgt() (the SG wall-clock formatter groupVisitDaysV719 keys its day grouping on) must exist at module scope');
const sgtLine = sgtLineMatch[0];

const validVisitStart = app.indexOf('function validVisitSales(');
const validVisitEnd = app.indexOf('async function fetchRowsByIds(', validVisitStart);
assert.ok(validVisitStart > -1 && validVisitEnd > validVisitStart, 'validVisitSales must be a top-level function');
const validVisitBlock = app.slice(validVisitStart, validVisitEnd);

const groupStart = app.indexOf('function groupVisitDaysV719(');
const groupEnd = app.indexOf('/* V468 (owner photos 3, 8 and 9', groupStart);
assert.ok(groupStart > -1 && groupEnd > groupStart, 'groupVisitDaysV719/visitDaySummaryV719 must be top-level functions, before the V468 dialog block');
const groupBlock = app.slice(groupStart, groupEnd);
assert.ok(groupBlock.includes('function visitDaySummaryV719('), 'visitDaySummaryV719 must live in the extracted block');

/* The dialog itself must actually call these, not just declare them next to dead code. */
const dialogStart = app.indexOf('async function openDashboardMetricRowsV388(');
const dialogEnd = app.indexOf('function dashboardMetricWasLineV387(', dialogStart);
assert.ok(dialogStart > -1 && dialogEnd > dialogStart, 'openDashboardMetricRowsV388 must be a top-level function');
const dialogBlock = app.slice(dialogStart, dialogEnd);

test('V719 the Visits drill-down wires the grouped renderer, not a per-sale one', () => {
  assert.match(dialogBlock, /groupVisitDaysV719\(data\|\|\[\]\)/,
    'the visits branch must group the fetched sales rather than list them one-for-one');
  assert.match(dialogBlock, /visitDaySummaryV719\(group\)/,
    'each grouped row must print through visitDaySummaryV719');
  assert.doesNotMatch(dialogBlock, /key==='visits'\?esc\(String\(row\.kind/,
    'the old one-row-per-sale rendering path must be gone');
});

function run(code) {
  const sandbox = { money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2) };
  const context = vm.createContext(sandbox);
  vm.runInContext(`${sgtLine}\n${validVisitBlock}\n${groupBlock}\n${code}`, context);
  return context.__result;
}

function sale({ id, clientId, name, day, time = '10:00:00', amount, countsAsVisit = true, reversalOf = null }) {
  return {
    id,
    client_id: clientId,
    clients: name ? { full_name: name } : null,
    occurred_at: `${day}T${time}.000Z`,
    amount_cents: amount,
    counts_as_visit: countsAsVisit,
    reversal_of: reversalOf
  };
}

test('V719 groups by (client, SG day): R 3 same-day + next day + a week later, C 5 distinct days -> 8 rows, R 3, C 5', () => {
  const rows = [
    /* Times are kept before 16:00 UTC so that sgt()'s +8h SGT conversion never crosses into the
       next calendar day and silently changes which day a sale groups under. */
    // R: three tickets the same SG day (a split bill / repeat same-day purchase) -> ONE row, 3 tickets.
    sale({ id: 'r1', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '01:00:00', amount: 1500 }),
    sale({ id: 'r2', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '04:00:00', amount: 2000 }),
    sale({ id: 'r3', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '08:00:00', amount: 1000 }),
    // R: next day -> a second, separate row.
    sale({ id: 'r4', clientId: 'r', name: 'Rina', day: '2026-09-02', time: '01:00:00', amount: 800 }),
    // R: a week later -> a third, separate row.
    sale({ id: 'r5', clientId: 'r', name: 'Rina', day: '2026-09-09', time: '01:00:00', amount: 500 }),
    // C: five distinct days -> five separate rows.
    sale({ id: 'c1', clientId: 'c', name: 'Chandra', day: '2026-09-01', amount: 100 }),
    sale({ id: 'c2', clientId: 'c', name: 'Chandra', day: '2026-09-02', amount: 100 }),
    sale({ id: 'c3', clientId: 'c', name: 'Chandra', day: '2026-09-03', amount: 100 }),
    sale({ id: 'c4', clientId: 'c', name: 'Chandra', day: '2026-09-04', amount: 100 }),
    sale({ id: 'c5', clientId: 'c', name: 'Chandra', day: '2026-09-05', amount: 100 })
  ];
  const groups = run(`__result = groupVisitDaysV719(${JSON.stringify(rows)})`);

  /* The literal 8: this is the exact truth table nestly_v714's own commit message records for this
     fixture ("KPI 8 not 10, R 3, C 5") — there is no client-side visit-day counter to import and
     compare against instead, since the count itself is server-computed (get_dashboard_summary_v155)
     and only printed here. */
  assert.equal(groups.length, 8, 'the drill-down row count must equal the KPI tile (8), not the raw sale count (10)');

  const rGroups = groups.filter((g) => g.clientId === 'r');
  const cGroups = groups.filter((g) => g.clientId === 'c');
  assert.equal(rGroups.length, 3, "R's three same-day sales collapse into one row, alongside the next-day and week-later rows");
  assert.equal(cGroups.length, 5, "C's five distinct-day sales stay five separate rows");

  const rSameDay = rGroups.find((g) => g.count === 3);
  assert.ok(rSameDay, "R's same-day row must carry all 3 tickets");
  assert.equal(rSameDay.amountCents, 1500 + 2000 + 1000, "R's same-day row must sum the 3 tickets' amounts");
  assert.equal(visitDaySummaryFromGroup(rSameDay), '3 tickets · SGD 45.00', 'the printed line must read "N tickets · summed amount"');

  const rOtherDays = rGroups.filter((g) => g.count !== 3);
  assert.ok(rOtherDays.every((g) => g.count === 1), "R's other two rows are each a single ticket");
});

function visitDaySummaryFromGroup(group) {
  return run(`__result = visitDaySummaryV719(${JSON.stringify(group)})`);
}

test('V719 an anonymous (walk-in) sale never merges with another anonymous sale on the same day', () => {
  const rows = [
    sale({ id: 'a1', clientId: null, day: '2026-09-01', time: '09:00:00', amount: 300 }),
    sale({ id: 'a2', clientId: null, day: '2026-09-01', time: '15:00:00', amount: 400 })
  ];
  const groups = run(`__result = groupVisitDaysV719(${JSON.stringify(rows)})`);
  assert.equal(groups.length, 2, 'two anonymous sales on the same day must stay two rows, not fold into one');
  assert.ok(groups.every((g) => g.clientId === null), 'both rows must still be walk-ins');
  assert.ok(groups.every((g) => g.count === 1), 'each anonymous row is exactly one ticket');
});

test('V719 excludes what validVisitSales excludes: reversed sales and rows not marked as visits', () => {
  const rows = [
    sale({ id: 'v1', clientId: 'x', name: 'Xin', day: '2026-09-01', amount: 1000 }),
    sale({ id: 'v2', clientId: 'x', name: 'Xin', day: '2026-09-02', amount: 500, reversalOf: null }),
    // v2 gets reversed by v3 -> v2 must drop out (it is the reversed original).
    sale({ id: 'v3', clientId: 'x', name: 'Xin', day: '2026-09-02', amount: -500, reversalOf: 'v2' }),
    // Not marked as a visit at all (e.g. a membership/gift-card sale) -> excluded outright.
    sale({ id: 'v4', clientId: 'x', name: 'Xin', day: '2026-09-03', amount: 900, countsAsVisit: false })
  ];
  const groups = run(`__result = groupVisitDaysV719(${JSON.stringify(rows)})`);
  assert.equal(groups.length, 1, 'only v1 (2026-09-01) is a valid, un-reversed, visit-counted sale');
  assert.equal(groups[0].amountCents, 1000);
});

test('V719 the printed summary pluralises correctly and reads "N tickets · amount"', () => {
  assert.equal(visitDaySummaryFromGroup({ count: 1, amountCents: 2000 }), '1 ticket · SGD 20.00');
  assert.equal(visitDaySummaryFromGroup({ count: 2, amountCents: 4500 }), '2 tickets · SGD 45.00');
});
