/* V279 — the owner's walkthrough of the live bottle keep module (2026-08-11).
   Eleven rulings against the shipped V275/V278 module: re-entry removed outright, Retrieved made
   terminal and Finish removed with it, five fill-colour bands, a park quantity, a QR customer
   scan, a Bought-on default, status colours, a storage capacity, a Move that actually moves, the
   shelf list made discoverable, and a final action row.
   The assertions that matter here are the ones a screenshot cannot check: that re-entry is gone
   from the SERVER's projections and not merely from the markup, that 'retrieved' is refused
   server-side rather than merely unbuttoned, that the capacity refuses a WHOLE batch rather than
   half-filling the shelf, that a batch of N is one idempotent intention, and that the Scan button
   only exists where something can decode. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260811_nestly_v279_bottle_owner_walkthrough.sql'), 'utf8');
const suite = readFileSync(join(root, 'db', 'tests', 'v279_bottle_owner_walkthrough.sql'), 'utf8');

const NEW_RPCS = ['bar_save_setup_v279', 'park_bottles_v279'];

function functionBody(name, schema = 'public') {
  const start = migration.indexOf(`create or replace function ${schema}.${name}(`);
  assert.notEqual(start, -1, `${name} must be defined in the V279 migration`);
  const bodyStart = migration.indexOf('as $$', start);
  assert.notEqual(bodyStart, -1, `${name} must have a dollar-quoted body`);
  const end = migration.indexOf('\n$$;', bodyStart);
  assert.notEqual(end, -1, `${name} body must be closed`);
  return migration.slice(bodyStart, end);
}

const bottlesPage = app.slice(app.indexOf('async function bottlesPage(){'),
  app.indexOf('/* The event log speaks'));
const setupPage = app.slice(app.indexOf('async function bottleSetupPageV275(){'),
  app.indexOf('async function bottlesPage(){'));
const walletCard = app.slice(app.indexOf('const loadBottlesV275=async()=>{'),
  app.indexOf('const loadFeedback=async()=>{'));
const dashboardCard = app.slice(app.indexOf('async function loadDashboardBottlesV278(root'),
  app.indexOf('async function loadDashboardScheduleGlanceV180('));

/* ------------------------------------------------------------------ 1. re-entry is gone */

test('V279 re-entry is gone from all four surfaces, and from the SERVER that fed them', () => {
  // The four surfaces the owner walked: the park dialog, the list rows, the bottle card, and the
  // customer's own wallet card. Markup first — comments are stripped, because the code comments
  // that RECORD the removal legitimately name the thing they removed.
  const code = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '');
  for (const [label, surface] of [
    ['the park dialog, the list rows and the bottle card', bottlesPage],
    ["the customer's wallet card", walletCard],
    ['the Dashboard card', dashboardCard]
  ]) {
    assert.ok(!/reentry|re-entry/i.test(code(surface)),
      `re-entry must be gone from ${label}`);
  }
  assert.ok(!bottlesPage.includes('parkReentry'), 'the park dialog must not carry a re-entry field');
  assert.ok(!bottlesPage.includes('p_reentry_limit'),
    'the park call must not send a re-entry limit at all');

  // ...and then the part that matters, because markup can be re-added and a published field will
  // simply come back: the SERVER stops publishing it. The shared projection feeds the rows, the
  // card and the Dashboard at once; the customer read feeds the wallet.
  const projection = functionBody('bar_bottle_json_v275', 'app');
  assert.ok(!projection.includes('reentry_limit'),
    'the shared bottle projection must stop publishing reentry_limit');
  const customerRead = functionBody('customer_get_bottles_v275');
  assert.ok(!customerRead.includes('reentry_limit'),
    'the customer read must stop publishing reentry_limit');

  // The COLUMN survives: bottles parked before today carry real values, and a custody record is
  // not edited to tidy a form. Both park paths accept the argument and write null instead.
  assert.doesNotMatch(migration, /drop column reentry_limit/i,
    'the re-entry column must be kept, only stopped being read and written');
  assert.match(migration, /comment on column public\.bar_bottles\.reentry_limit is/,
    'the retirement must be recorded on the column itself, or the next increment re-grows it');
  assert.match(migration, /p_size_ml, v_fill, p_storage_location, null, 'stored',/,
    'park_bottle_v275 must store null where the re-entry limit used to go');
  assert.match(migration, /v_size, v_fill, p_storage_location, null, 'stored',/,
    'park_bottle_v278 must store null where the re-entry limit used to go');
  assert.match(suite, /park_bottle_v278 still stored a re-entry limit/,
    'the rollback suite must prove the argument is accepted and ignored');
});

/* ------------------------------------------------------------------ 2. retrieved is terminal */

test('V279 retrieved is terminal, and the refusal is SERVER-SIDE', () => {
  assert.match(migration,
    /create or replace function app\.bar_status_transition_allowed_v279\(p_from text, p_to text\)/);
  assert.match(migration,
    /when \$1 in \('stored', 'called', 'at_table'\)\s+and \$2 in \('stored', 'called', 'at_table', 'retrieved'\) then true/);
  assert.match(migration, /else false/);
  // No clause lets anything out of 'retrieved' — not even back to storage, which is what V278
  // allowed and what the owner ruled against.
  assert.ok(!/when \$1 = 'retrieved'/.test(migration),
    'V279 must not carry any transition out of retrieved');
  // Spliced into the settled V275 function with a comment-free, exactly-once needle and a
  // post-verify against the DEPLOYED definition.
  assert.match(migration, /v279: expected exactly 1 floor-guard needle in set_bottle_status_v275/);
  assert.match(migration, /v279: the terminal-retrieved rule did not land in the deployed function/);
  assert.match(migration, /if v_bottle\.status not in \('stored', 'called', 'at_table'\) then\n\s+raise exception 'this bottle has already been sent out'/);
  // The rollback suite proves the refusal rather than assuming it.
  assert.match(suite, /retrieved -> % was NOT refused by the server/);
  assert.match(suite, /retrieved -> % must be impossible/);
});

test('V279 the card ends a bottle with Retrieved and offers no second Finish', () => {
  assert.match(app, /retrieved:Object\.freeze\(\[\]\)/,
    'the browser matrix must mirror the server: nothing leaves retrieved');
  assert.match(app, /const BOTTLE_STORAGE_STATUSES_V279=Object\.freeze\(\['stored','called','at_table'\]\);/);
  assert.match(bottlesPage, /const live=BOTTLE_STORAGE_STATUSES_V279\.includes\(bottle\.status\);/,
    'a retrieved bottle must offer no actions at all, exactly like a finished one');
  assert.match(bottlesPage, /data-retrieve style="min-height:42px"/);
  assert.match(bottlesPage, /p_status:'retrieved',p_idempotency_key:key\}\),'Bottle retrieved'/);
  assert.ok(!bottlesPage.includes('data-finish'), 'the Finish control must be gone');
  assert.ok(!bottlesPage.includes("sb.rpc('finish_bottle_v275'"),
    'and the browser must no longer call the finish RPC');
  // finish_bottle_v275 itself stays deployed: a deploy in flight must not break.
  assert.ok(!/drop function[^\n]*finish_bottle_v275/.test(migration),
    'the finish function must stay callable even though the client drops it');
  // The final action row the owner asked for, in order.
  const actions = ['Extend ${keepDays}d', 'Edit expiry', 'Move', 'Add note', 'Bought on',
    'Remind customer', 'Transfer', 'Retrieved'];
  let cursor = -1;
  for (const label of actions) {
    const at = bottlesPage.indexOf(`<span>${label}</span>`);
    assert.ok(at > cursor, `the action row must carry ${label}, in the owner's order`);
    cursor = at;
  }
});

/* ------------------------------------------------------------------ 3. the three tabs */

test('V279 the status filter is three tabs: Storage / Retrieved / Expired', () => {
  assert.match(app, /const BOTTLE_TABS_V279=Object\.freeze\(\[/);
  for (const [value, label] of [['storage', 'Storage'], ['retrieved', 'Retrieved'],
    ['expired', 'Expired']]) {
    assert.ok(app.includes(`Object.freeze(['${value}','${label}',`),
      `the tabs must carry ${label}`);
  }
  assert.match(bottlesPage, /let filters=\{status:'storage',/,
    'Storage is the default answer, because it is the shelf');
  assert.match(bottlesPage, /data-bottle-tab="\$\{esc\(value\)\}"/);
  assert.match(bottlesPage, /aria-pressed="\$\{value==='storage'\?'true':'false'\}"/);
  assert.ok(!bottlesPage.includes('id="bottleStatusFilter"'),
    'the eight-option select must be gone');
  // Storage is the three floor states as ONE server-side answer, so the tab and the default
  // cannot drift apart.
  const list = functionBody('list_bar_bottles_v275');
  assert.match(list, /v_storage := v_status in \('', 'storage'\);/);
  assert.match(list, /\(v_storage and bottle\.status in \('stored', 'called', 'at_table'\)\)/);
  assert.match(suite, /the Storage tab must be exactly the three floor states/);
  assert.match(suite, /the Expired tab must be exactly the expired bottles/);
  // A retrieved bottle has left the building, so it leaves the customer's card too.
  const customerRead = functionBody('customer_get_bottles_v275');
  assert.match(customerRead, /and bottle\.status in \('stored', 'called', 'at_table'\)/);
});

/* ------------------------------------------------------------------ 4. the fill colour bands */

test('V279 the fill bar carries five colour bands, from one table, everywhere it renders', () => {
  assert.match(app, /const BOTTLE_FILL_BANDS_V279=Object\.freeze\(\[/);
  for (const [ceiling, colour, name] of [
    [25, '#B3453A', 'red'],
    [50, '#C2701A', 'orange'],
    [75, '#A8951C', 'yellow'],
    [100, '#6FAE7C', 'light green'],
    [101, '#2E7D5B', 'green']
  ]) {
    assert.ok(app.includes(`Object.freeze([${ceiling},'${colour}','${name}'])`),
      `the ${name} band must be declared with an exclusive ceiling of ${ceiling}`);
  }
  // One resolver, consulted by the one renderer, so the rows, the card, the Dashboard and the
  // customer's wallet cannot disagree about what "half" looks like.
  assert.match(app, /function bottleFillToneV279\(percent\)\{[\s\S]*?BOTTLE_FILL_BANDS_V279\.find\(\(\[ceiling\]\)=>value<ceiling\)/);
  assert.match(app, /function bottleFillBarV275\(percent\)\{[\s\S]*?const tone=bottleFillToneV279\(value\);/);
  assert.ok(!/const tone=value>=50\?/.test(app), 'the old three-tone rule must be gone');
  // The renderer is reached from every surface that draws a bar.
  assert.match(bottlesPage, /\$\{bottleFillBarV275\(item\.fill_percent\)\}/, 'the list rows');
  assert.match(bottlesPage, /\$\{bottleFillBarV275\(fill\)\}<b>\$\{fill\}%<\/b>/, 'the bottle card');
  assert.match(bottlesPage, /bar\.innerHTML=bottleFillBarV275\(\$\('parkFill'\)\.value\)/,
    'and the park dialog, where the number is first chosen');
  assert.match(walletCard, /\$\{bottleFillBarV275\(fill\)\}/, "and the customer's own wallet");
  // The four smart buttons, with the exact input still beside them.
  assert.match(app,
    /const BOTTLE_FILL_PRESETS_V275=Object\.freeze\(\[\[100,'100%'\],\[75,'75%'\],\[50,'50%'\],\[25,'25%'\]\]\);/);
  assert.match(bottlesPage, /data-park-fill="\$\{value\}"/);
  assert.match(bottlesPage, /id="bottleFillInput"/);
});

/* ------------------------------------------------------------------ 5. quantity */

test('V279 a batch of N bottles is N rows and ONE idempotent intention', () => {
  assert.match(bottlesPage, /id="parkQuantity" type="number" min="1" max="20"[^>]*value="1"/,
    'the park dialog asks how many, 1..20, default 1');
  assert.match(bottlesPage, /Park between 1 and 20 bottles at a time\./);
  assert.match(bottlesPage, /p_quantity:quantity\}/);
  assert.match(bottlesPage, /sb\.rpc\('park_bottles_v279',\{\.\.\.request,p_idempotency_key:key\}\)/,
    'ONE key is sent for the whole batch');
  assert.match(bottlesPage, /parked>1\?`Parked \$\{parked\} bottles`/);

  const park = functionBody('park_bottles_v279');
  assert.match(park, /park between 1 and 20 bottles at a time/);
  // Each bottle is its own row with its own serial, allocated as a contiguous range under the
  // same settings-row lock V275 and V278 use.
  assert.match(park, /for v_index in 1\.\.v_quantity loop/);
  assert.match(park, /v_seq \+ v_index - 1/);
  assert.match(park, /for update;/, 'serial allocation must stay serialised');
  // The per-bottle evidence key is DERIVED from the one intention, and the replay probe matches
  // the prefix — so a retry cannot park a second batch, nor a partial one.
  assert.match(park, /v_key \|\| '#' \|\| v_index/);
  assert.match(park, /left\(event\.idem_key, length\(v_key\) \+ 1\) = v_key \|\| '#'/,
    'the prefix must be compared literally, not as a LIKE pattern');
  assert.match(park, /'duplicate_ignored'/);
  assert.match(park, /'batch_key', v_key/, 'the evidence must name the batch it belonged to');
  // Proven, not assumed.
  assert.match(suite, /a batch of 3 wrote % evidence rows, expected 3/);
  assert.match(suite, /replaying a batch key parked more bottles/);
  assert.match(suite, /the replay returned a different batch/);
  assert.match(suite, /a quantity of % must be refused/);
});

/* ------------------------------------------------------------------ 6. storage capacity */

test('V279 the storage capacity is enforced in every park path, and refuses a batch WHOLE', () => {
  assert.match(migration,
    /add column storage_capacity integer not null default 500\s+check \(storage_capacity between 1 and 10000\)/);
  // Only the three floor states consume a slot: a retrieved bottle has physically left.
  assert.match(migration,
    /create or replace function app\.bar_in_storage_count_v279\(p_business uuid\)[\s\S]*?and bottle\.status in \('stored', 'called', 'at_table'\)/);
  assert.match(migration,
    /raise exception 'Storage is full — % of % in use', v_used, v_capacity using errcode = '22023';/,
    'the refusal must say how full the bar is, in the message the bartender reads');
  // Every park path holds it — the new one directly, the two older ones by splice, so an older
  // client in flight cannot walk around the number the owner set.
  assert.match(functionBody('park_bottles_v279'),
    /perform app\.bar_capacity_guard_v279\(p_business, v_quantity\);/,
    'the batch must ask for its WHOLE quantity before the first insert');
  assert.match(migration, /v279: expected exactly 1 serial-year needle in park_bottle_v275/);
  assert.match(migration, /v279: expected exactly 1 serial-year needle in park_bottle_v278/);
  assert.match(migration,
    /v279: the capacity guard and the re-entry retirement did not land in park_bottle_v275/);
  assert.match(migration,
    /v279: the capacity guard and the re-entry retirement did not land in park_bottle_v278/);
  // Setup writes it, both reads publish it, and both KPI rows show "N / capacity".
  assert.match(setupPage, /id="bkCapacity" type="number" min="1" max="10000"/);
  assert.match(setupPage, /sb\.rpc\('bar_save_setup_v279',\{/);
  assert.match(setupPage, /p_storage_capacity:capacity,/);
  assert.match(migration, /'storage_capacity', app\.bar_storage_capacity_v279\(p_business\)/);
  assert.match(bottlesPage, /capacity\?`\$\{inStorage\} \/ \$\{capacity\}`/);
  assert.match(dashboardCard, /capacity\?`\$\{inStorage\} \/ \$\{capacity\}`/);
  // The batch edge is proven, and proven to leave nothing behind.
  assert.match(suite, /a batch of 3 into 2 free slots must be refused/);
  assert.match(suite, /the refused batch parked bottles anyway - it must be refused WHOLE/);
  assert.match(suite, /% parked a bottle into a full bar/);
});

/* ------------------------------------------------------------------ 7-8. scan, bought on */

test('V279 the customer Scan button is feature-detected and fails soft to search', () => {
  // A button that opens a camera which can never decode anything is worse than no button, so the
  // control does not exist at all where BarcodeDetector does not.
  assert.match(app, /const bottleScanSupportedV279=\(\)=>typeof window!=='undefined'\s*\n\s*&&typeof window\.BarcodeDetector==='function'\s*\n\s*&&!!navigator\.mediaDevices\?\.getUserMedia;/);
  assert.match(bottlesPage, /\$\{bottleScanSupportedV279\(\)\?`<button type="button" class="btn ghost sm" id="parkScanV279"/);
  assert.match(bottlesPage, /const scanButtonV279=\$\('parkScanV279'\);\s*\n\s*if\(scanButtonV279\)/,
    'the handler must only be wired when the button exists');
  // Resolved the way the till resolves a customer: an exact id if the code carries one, otherwise
  // the phone number.
  assert.match(app, /function resolveScannedCustomerV279\(raw,list\)\{/);
  assert.match(app, /const byPhone=rows\.find\(client=>String\(client\?\.phone\|\|''\)\.replace\(\/\\D\/g,''\)\.endsWith\(tail\)\);/);
  // Fail-soft: an unrecognised code lands in the search box rather than being thrown away.
  assert.match(bottlesPage, /toast\('Code not recognised — search for them'\);/);
  assert.match(bottlesPage, /renderClientOptions\(\$\('parkCustomerSearch'\)\.value\);/);
  // And the scanner itself never throws into the dialog it lives in.
  assert.match(app, /function openBottleQrScanV279\(\)\{[\s\S]*?if\(!bottleScanSupportedV279\(\)\)return resolve\(null\);/);
  assert.match(app, /stream\.getTracks\(\)\.forEach\(track=>track\.stop\(\)\)/,
    'the camera must be released however the scan ends');
});

test('V279 Bought on defaults to today in Singapore, and stays editable', () => {
  // nestly_tz-client: the bespoke sgtTodayV279 duplicate was redirected to the single
  // canonical "today in SG" helper (sgDateInputValue, Intl formatToParts on Asia/Singapore)
  // rather than its own fixed-offset new Date()+8h reimplementation.
  assert.match(app, /const sgDateInputValue=\(date=new Date\(\)\)=>\{/,
    "the default must be the bar's own day, not the browser's");
  assert.match(bottlesPage, /id="parkPurchased" type="date" value="\$\{esc\(sgDateInputValue\(\)\)\}"/);
  assert.match(bottlesPage, /p_purchased_on:\$\('parkPurchased'\)\.value\|\|null,/,
    'and it is still whatever the bartender leaves in the field');
});

/* ------------------------------------------------------------------ 9. status colours */

test('V279 every status carries one colour, used on the rows, the card and the Dashboard', () => {
  for (const [status, tone] of [
    ['stored', '#2E7D5B'], ['called', '#B4761F'], ['at_table', '#2F6FB3'],
    ['retrieved', '#6B6560'], ['expired', '#B3453A']
  ]) {
    assert.ok(new RegExp(`${status}:\\{label:'[^']+',icon:'[^']+',tone:'${tone}'\\}`).test(app),
      `${status} must declare its colour once, in the status map`);
  }
  assert.match(app, /function bottleStatusPillV275\(status\)\{[\s\S]*?style="color:\$\{meta\.tone\|\|'#6B6560'\}/,
    'the pill must read its colour from the map rather than hard-coding one');
  assert.match(bottlesPage, /BOTTLE_STATUS_V275\.stored\.tone/, 'the Bottles KPI row');
  assert.match(dashboardCard, /BOTTLE_STATUS_V275\.called\.tone/, 'and the Dashboard card');
});

/* ------------------------------------------------------------------ 10-11. move, discoverability */

test('V279 Move cannot be a dead control: no shelves means a route to setup, not an empty select', () => {
  // ROOT CAUSE the owner met: with no storage places the only option was "Not recorded", so
  // pressing Move recorded a move to nothing and changed nothing visible.
  assert.match(bottlesPage,
    /\$\{locations\.length\?`<label for="bottleMoveLocation">Move to<\/label>/,
    'the Move panel must branch on whether the bar has anywhere to move a bottle to');
  assert.match(bottlesPage, /this bar has no shelves on its list yet, so there is nowhere to move it to/);
  assert.match(bottlesPage, /href="#\/bottlesetup" data-move-setup/,
    'and must point the owner at the page that fixes it');
  // The second half of the same failure: submitting the shelf it is already on.
  assert.match(bottlesPage,
    /if\(\(target\|\|null\)===\(bottle\.storage_location_id\|\|null\)\)\{/);
  assert.match(bottlesPage, /That is where it already is\. Pick a different place\./);
  // The write itself is unchanged and still literal, so PS-0 discovery still sees it.
  assert.ok(bottlesPage.includes("sb.rpc('move_bottle_v278'"));
});

test('V279 the shelf list is the first thing Bottle keep setup asks for', () => {
  const storageAt = setupPage.indexOf('<h2>Storage places</h2>');
  const keepAt = setupPage.indexOf('<h2>Keep window</h2>');
  assert.ok(storageAt !== -1 && keepAt !== -1 && storageAt < keepAt,
    'Storage places must be the FIRST card: everything else on the page has a working default');
  assert.match(setupPage, /Add your shelves — e\.g\. Shelf A, Chiller 2\./);
  // The park dialog's helper is a real route, not a sentence.
  assert.match(bottlesPage, /<a class="btn ghost sm" id="parkAddShelfV279" href="#\/bottlesetup"/);
  assert.match(bottlesPage, /Ask the owner to add them in Bottle keep\./,
    'and a staff member is told who can fix it');
});

/* ------------------------------------------------------------------ gates and hygiene */

test('V279 both new RPCs hold the bar gate as their FIRST authorisation step', () => {
  for (const name of NEW_RPCS) {
    const body = functionBody(name);
    assert.match(body, /perform app\.require_bar_business_v275\(/,
      `${name} must refuse a non-bar business server-side — hiding the nav is not a gate`);
    const gate = body.indexOf('app.require_bar_business_v275(');
    for (const [label, index] of [
      ['staff gate', body.indexOf('app.require_bar_staff_v275(')],
      ['owner gate', body.indexOf('app.is_salon_owner(')]
    ]) {
      if (index === -1) continue;
      assert.ok(gate < index, `${name}: the industry gate must run before the ${label}`);
    }
  }
  // The recreated reads keep the same discipline.
  for (const name of ['bar_get_setup_v275', 'list_bar_bottles_v275']) {
    const body = functionBody(name);
    assert.ok(body.indexOf('app.require_bar_business_v275(')
      < body.indexOf('app.require_bar_staff_v275('),
      `${name}: the industry gate must stay first`);
  }
  assert.match(suite, /both new RPCs refuse a non-bar business with 42501/);
});

test('V279 every new RPC revokes PUBLIC and grants only authenticated', () => {
  for (const name of NEW_RPCS) {
    assert.match(migration,
      new RegExp(`revoke all on function public\\.${name}\\([^)]*\\) from public, anon, authenticated;`),
      `${name} must revoke PostgreSQL's default EXECUTE-to-PUBLIC`);
    assert.match(migration,
      new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated;`),
      `${name} must be granted to authenticated only`);
  }
  assert.doesNotMatch(migration, /grant execute on function public\.[a-z_0-9]*v279\([^)]*\) to anon/,
    'no V279 RPC may be reachable anonymously');
  assert.match(suite, /anon can execute %/, 'and the suite proves it against the live grants');
});

test('V279 the splices are comment-free, exactly-once, and verified against the deployed result', () => {
  for (const target of ['set_bottle_status_v275', 'park_bottle_v275', 'park_bottle_v278']) {
    assert.ok(migration.includes(`pg_get_functiondef(`),
      'the splices must read their own deployed source');
    assert.ok(migration.includes(target),
      `${target} must be spliced rather than retyped`);
  }
  // The Supabase apply path strips full-line comments, so a comment-anchored needle matches a
  // psql rehearsal and misses production.
  const needles = migration.match(/\$needle\$[\s\S]*?\$needle\$/g) || [];
  assert.ok(needles.length >= 6, 'the splices must use dollar-quoted needles');
  for (const needle of needles) {
    assert.ok(!needle.includes('--'),
      `a needle must contain no SQL comment: ${needle.slice(0, 60)}`);
  }
  // Re-running must be safe, and a missing needle must raise rather than guess.
  assert.match(migration, /already treats retrieved as terminal - nothing to do/);
  assert.match(migration, /already holds the capacity guard - nothing to do/);
  assert.match(migration,
    /v279: set_bottle_status_v275 does not carry the V278 transition rule - refusing to guess/);
});

test('V279 the migration is one transaction and the suite rolls back', () => {
  assert.match(migration, /^begin;$/m);
  assert.match(migration, /^commit;$/m);
  assert.match(suite, /^begin;$/m);
  assert.match(suite, /^rollback;$/m);
  assert.doesNotMatch(suite, /^commit;$/m, 'the acceptance suite must never commit');
  assert.match(suite, /raise notice 'v279: ALL CHECKS PASSED \(rolling back\)';/);
});
