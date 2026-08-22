/* V466 (owner ruling 2026-08-23, R4: "hide memberships and gift cards until verified"). Gift
   cards were already fully gated business-side by V303 (2026-08-13) — pinned here alongside the
   new memberships guard so a future edit cannot regress one while touching the other. Memberships
   had THREE live merchant-facing doors before this change: the router dispatch for pageKey
   'memberships' (no refusal guard existed), the grow-page 'recurring' topic tile + its drilled
   Memberships programmeRow, and the till "Add item" sheet's Memberships tab. All three now read
   UNVERIFIED_MODULES_V466, the single flag that makes un-gating a one-line change.

   Pre-gate data check (see the v466 report) found ONE non-QA tenant, AhXiang
   (business 33773caa-6d51-4cf2-9ad6-b83f015759e6), holding a live membership_plans row, a live
   memberships enrolment and a live gift_cards row. The owner confirmed AhXiang is their own test
   tenant, not a real merchant obligation — no per-tenant carve-out, gate globally. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8')
  + '\n' + readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const route = section('async function route()', '/* ---------- customer wallet ---------- */');
const grow = section('async function growPage(', 'async function studioPage(');
const composer = section('function drawCartComposer(){', 'async function applySvTender(){');

test('V466 (a) UNVERIFIED_MODULES_V466 exists and lists exactly the two gated modules', () => {
  const declStart = app.indexOf('const UNVERIFIED_MODULES_V466=');
  assert.ok(declStart >= 0, 'UNVERIFIED_MODULES_V466 constant is missing');
  const declEnd = app.indexOf(';', declStart) + 1;
  const source = app.slice(declStart, declEnd);
  // Real execution, not a regex match: evaluate the actual declaration and inspect the value.
  const value = new Function(`${source}\nreturn UNVERIFIED_MODULES_V466;`)();
  assert.deepEqual(value, ['memberships', 'giftcards'],
    'the flag must list exactly the two unverified modules, in the documented order');
});

test('V466 (b) the router refuses a typed #/memberships with a toast, mirroring the giftcards guard', () => {
  // Pin the pre-existing giftcards refusal FIRST — Agent A's line numbers had already drifted
  // once before this change; this is the anchor a future drift check should re-derive from.
  assert.match(route, /if\(pageKey==='giftcards'\)\{\s*toast\('Gift cards are no longer part of this workspace\.'\);\s*return nav\('#\/dashboard'\);\s*\}/);
  // The new memberships guard sits directly after it, same shape: toast, then nav('#/dashboard').
  // /mn and /plist are element ids inside membershipsPage(), not separate routes, so gating the
  // bare 'memberships' pageKey covers both deep links without a separate check.
  assert.match(route, /if\(pageKey==='memberships'\)\{\s*toast\('Memberships are not part of this workspace yet\.'\);\s*return nav\('#\/dashboard'\);\s*\}/);
  // The guard must appear in the router BEFORE the generic MODULES/module-permission dispatch,
  // i.e. before the giftcards guard's own known downstream neighbour, so a typed hash is refused
  // and never reaches membershipsPage() at all.
  const giftcardsAt = route.indexOf("pageKey==='giftcards'");
  const membershipsAt = route.indexOf("pageKey==='memberships'");
  const promotionsAt = route.indexOf("pageKey==='promotions'");
  assert.ok(giftcardsAt >= 0 && membershipsAt > giftcardsAt && promotionsAt > membershipsAt,
    'the memberships refusal must sit between the giftcards guard and the promotions guard, ahead of the module dispatch');
});

test('V466 (c) the grow overview renders no Memberships tile while the module is unverified', () => {
  // The topic tile itself: the array literal keeps the 'recurring' entry (so un-gating stays a
  // one-line flag removal, not reconstructing the tile), and a trailing .filter() drops it from
  // the list every render actually reads.
  assert.match(grow, /\{key:'recurring',icon:'wallet',title:'Memberships',blurb:'Let customers subscribe and save',/);
  assert.match(grow, /\]\.filter\(topic=>topic\.key!=='recurring'\|\|!UNVERIFIED_MODULES_V466\.includes\('memberships'\)\);/);
  // The drilled category block (the programmeRow with href #/memberships/plist or #/memberships/mn)
  // is ALSO gated directly on the flag, not only via the tile-list filter above: topicOnV229()
  // returns true unconditionally for every category on the legacy #/grow/ongoing, #/grow/available
  // and #/grow/settings views (they are not in growCategoryViewV271's exclusion list), so a
  // tile-list filter alone would not stop this block rendering when reached by one of those routes.
  assert.match(grow, /\$\{topicOnV229\('recurring'\)&&!UNVERIFIED_MODULES_V466\.includes\('memberships'\)\?`/);
  assert.match(grow, /href:membershipConfigured\?'#\/memberships\/plist':'#\/memberships\/mn'/);
});

test('V466 (d) the till "Add item" sheet cannot enrol a customer into a membership while gated', () => {
  // The tab entry itself stays in TILL_SHEET_TABS_V373 (pinned by the V373 suite) — what changed
  // is availability, the same mechanism that already hides it for a walk-in or a branch without
  // write authority.
  assert.match(composer, /membership:canMem&&\(catalog\.memberships\|\|\[\]\)\.length>0&&!UNVERIFIED_MODULES_V466\.includes\('memberships'\)/);
});

test('V466 (e) un-gating either module is a one-line change: nothing else references the ruling', () => {
  // The flag is declared exactly once; every gate reads it rather than re-deriving its own
  // hardcoded module-name check, so removing 'memberships' (or 'giftcards') from the array is
  // the entire un-gate.
  const declarations = (app.match(/const UNVERIFIED_MODULES_V466=/g) || []).length;
  assert.equal(declarations, 1, 'UNVERIFIED_MODULES_V466 must be declared exactly once');
  const readSites = (app.match(/UNVERIFIED_MODULES_V466\.includes\(/g) || []).length;
  // router memberships guard is a bare pageKey check (no .includes call), so the three
  // .includes() read sites are: growTopicDefsV229 filter, the drilled programmeRow guard, and
  // the till composer's membership availability line.
  assert.equal(readSites, 3, 'expected exactly 3 call sites reading the flag via .includes()');
});
