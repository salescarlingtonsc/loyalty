/* V275 — bar sector bottle keep.
   Owner brief 2026-08-11 plus four amendments that override the design document:
     1. VIP stays the EXISTING tier mechanism — no per-tier keep column anywhere;
     2. the keep window is ONE number per business, set in Operations setup;
     3. storage locations are the bar's own list, also set in Operations setup;
     4. HARD bar-only gating, enforced SERVER-SIDE in every RPC, with nothing at all visible to a
        non-bar tenant.
   Amendment 4 is what most of this file is about: a hidden nav row is not a gate, so the tests
   that matter assert the SQL refusal, not the CSS. */
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
  join(root, 'db', 'migrations', '20260811_nestly_v275_bar_bottle_keep.sql'), 'utf8');

const BOTTLE_RPCS = [
  'bar_get_setup_v275',
  'bar_save_setup_v275',
  'park_bottle_v275',
  'set_bottle_fill_v275',
  'set_bottle_status_v275',
  'extend_bottle_v275',
  'transfer_bottle_v275',
  'finish_bottle_v275',
  'list_bar_bottles_v275',
  'customer_get_bottles_v275'
];
const MUTATING_RPCS = [
  'park_bottle_v275',
  'set_bottle_fill_v275',
  'set_bottle_status_v275',
  'extend_bottle_v275',
  'transfer_bottle_v275',
  'finish_bottle_v275'
];

function functionBody(name) {
  const start = migration.indexOf(`create or replace function public.${name}(`);
  assert.notEqual(start, -1, `${name} must be defined in the V275 migration`);
  const bodyStart = migration.indexOf('as $$', start);
  assert.notEqual(bodyStart, -1, `${name} must have a dollar-quoted body`);
  const end = migration.indexOf('\n$$;', bodyStart);
  assert.notEqual(end, -1, `${name} body must be closed`);
  return migration.slice(bodyStart, end);
}

test('V275 every bottle RPC holds the industry gate server-side, before anything else', () => {
  for (const name of BOTTLE_RPCS) {
    const body = functionBody(name);
    assert.match(body, /perform app\.require_bar_business_v275\(/,
      `${name} must refuse a non-bar business server-side — hiding the nav is not a gate`);
  }
  // The gate itself: one place, one rule, a plain human message and 42501 (not 404, which would
  // read as "broken" instead of "not for you").
  assert.match(migration,
    /create or replace function app\.require_bar_business_v275\(p_business uuid\)/);
  assert.match(migration, /if coalesce\(v_industry, ''\) <> 'bar' then/);
  assert.match(migration,
    /raise exception 'Bottle keep is only available for bar businesses\.' using errcode = '42501';/);
});

test('V275 the gate is the FIRST authorisation step in every RPC', () => {
  for (const name of BOTTLE_RPCS) {
    const body = functionBody(name);
    const gate = body.indexOf('app.require_bar_business_v275(');
    const staff = body.indexOf('app.require_bar_staff_v275(');
    const owner = body.indexOf('app.is_salon_owner(');
    for (const [label, index] of [['staff gate', staff], ['owner gate', owner]]) {
      if (index === -1) continue;
      assert.ok(gate < index,
        `${name}: the industry gate must run before the ${label}, so a non-bar tenant cannot even learn whether it would have been authorised`);
    }
  }
});

test('V275 every mutating RPC is idempotent and writes exactly one evidence row', () => {
  for (const name of MUTATING_RPCS) {
    const body = functionBody(name);
    assert.match(body, /app\.bar_bottle_replayed_v275\(p_business, v_key\)/,
      `${name} must probe the idempotency key before it writes`);
    assert.match(body, /'duplicate_ignored'/,
      `${name} must answer a replay with duplicate_ignored rather than writing twice`);
    const inserts = body.match(/insert into public\.bar_bottle_events/g) || [];
    assert.equal(inserts.length, 1,
      `${name} must record exactly one bar_bottle_events row per write, not ${inserts.length}`);
    assert.match(body, /idem_key/,
      `${name} must store the idempotency key on the evidence row — the event IS the dedupe record`);
  }
  // The uniqueness that makes the above a property of the schema rather than of the RPC bodies.
  assert.match(migration,
    /create unique index bar_bottle_events_idem_uk\s+on public\.bar_bottle_events \(business_id, idem_key\)/);
  // Append-only evidence, reusing the reviewed v33 guard.
  assert.match(migration,
    /create trigger bar_bottle_events_immutable\s+before update or delete on public\.bar_bottle_events\s+for each row execute function app\.v33_append_only_guard\(\);/);
});

test('V275 the new tables are RPC-only: RLS on, no policies, no browser ACL', () => {
  for (const table of ['bar_bottle_settings', 'bar_storage_locations', 'bar_bottles', 'bar_bottle_events']) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`),
      `${table} must enable RLS`);
    assert.match(migration,
      new RegExp(`revoke all privileges on table public\\.${table} from public, anon, authenticated;`),
      `${table} must revoke every browser role`);
  }
  assert.doesNotMatch(migration, /create policy [a-z_]*bar_bottle/i,
    'the bottle tables are RPC-only; a policy would open a second door');
});

test('V275 the keep window is ONE number per business, and no tier column was added', () => {
  assert.match(migration,
    /keep_days integer not null default 30 check \(keep_days between 1 and 365\)/);
  // Owner amendment 1: tiers move because the purchase is a sale. Nothing is added to the tier
  // tables, and no per-tier keep window exists to disagree with the business's own number.
  assert.doesNotMatch(migration, /bottle_keep_days/,
    'owner amendment 1: VIP is the existing tier method — no per-tier keep window');
  assert.doesNotMatch(migration, /alter table public\.loyalty_tiers/,
    'owner amendment 1: V275 adds no tier column');
});

test('V275 a bottle purchase earns and moves the tier through the existing sale engine', () => {
  assert.match(migration, /\(''bottle_keep''::text, true,  true,  true\)/,
    'bottle_keep must count as revenue, count as a visit and earn points');
  assert.match(migration, /alter table public\.sales add constraint sales_kind_check[\s\S]*?bottle_keep/);
  assert.match(migration, /alter table public\.sale_policies add constraint sale_policies_kind_check[\s\S]*?bottle_keep/);
  // Spliced from the LIVE definitions with comment-free needles and an explicit refusal, because
  // the Supabase apply strips full-line comments.
  for (const needle of [
    'v275: sales_kind_check not found',
    'v275: sale_policies_kind_check not found',
    'v275: app.sale_policy_defaults not found',
    'v275: app.sale_policy_defaults package-row needle not found'
  ]) {
    assert.ok(migration.includes(needle), `the migration must raise "${needle}" rather than guess`);
  }
});

test('V275 every RPC revokes PUBLIC and grants only authenticated', () => {
  for (const name of BOTTLE_RPCS) {
    assert.match(migration, new RegExp(`revoke all on function public\\.${name}\\([^)]*\\) from public, anon, authenticated;`),
      `${name} must revoke PostgreSQL's default EXECUTE-to-PUBLIC`);
    assert.match(migration, new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated;`),
      `${name} must be granted to authenticated only`);
  }
  assert.doesNotMatch(migration, /grant execute on function public\.(bar_|park_bottle|set_bottle|extend_bottle|transfer_bottle|finish_bottle|customer_get_bottles)[a-z_0-9]*\([^)]*\) to anon/,
    'no bottle RPC may be reachable anonymously');
});

test('V275 the nav advertises Bottles to bars only, and no other sector gained a row', () => {
  // The module is stripped from the resolved list before the rail is built.
  assert.match(app, /const isBarSectorV275=\(\)=>String\(S\.biz\?\.industry\|\|''\)\.toLowerCase\(\)==='bar';/);
  assert.match(app, /const sectorShowsBottlesV275=isBarSectorV275\(\);/);
  assert.match(app, /\.filter\(module=>module!=='bottles'\|\|sectorShowsBottlesV275\)/);
  assert.match(app, /\|\|\(m==='bottlesetup'&&sectorShowsBottlesV275&&S\.myRole==='owner'\)/);
  // Bottles rides in Serve & sell; Bottle keep rides in Operations setup.
  assert.match(app, /label:'Serve & sell',items:\['till','appointments','bottles','bookings','waitlist','giftcards'\]/); /* V294: gift cards joined Serve & sell */
  assert.match(app, /label:'Operations setup',items:\['staffmembers','branches','services','inventory','packages','bottlesetup'\]/);
  // Every other sector's module list is untouched: 'bottles' appears in exactly one INDUSTRIES
  // entry (bar) and never in ALLMODS, so it cannot arrive by default anywhere else.
  const industries = app.slice(app.indexOf('const INDUSTRIES={'), app.indexOf('const MODULES={'))
    .replace(/\/\*[\s\S]*?\*\//g, '');
  const sectorsWithBottles = [...industries.matchAll(/^\s{2}([a-z]+):\{em:/gm)]
    .map((match) => ({ key: match[1], index: match.index }))
    .filter(({ index }, position, all) => {
      const end = all[position + 1]?.index ?? industries.length;
      return industries.slice(index, end).includes("'bottles'");
    })
    .map(({ key }) => key);
  assert.deepEqual(sectorsWithBottles, ['bar'],
    'only the bar sector may list the bottles module');
  const allmods = app.slice(app.indexOf('const ALLMODS='), app.indexOf('const INDUSTRIES={'));
  assert.doesNotMatch(allmods, /'bottles'/,
    "ALLMODS is every other sector's default — bottles must never be in it");
  // The V246 F&B rule is untouched by this change.
  assert.match(app, /\(m!=='waitlist'&&m!=='appointments'&&enabled\.includes\(m\)\)/);
});

test('V275 a non-bar tenant that types the route gets an answer, not a bounce or a crash', () => {
  assert.match(app, /const BOTTLE_SURFACES_V275=new Set\(\['bottles','bottlesetup'\]\);/);
  const routeFn = app.slice(app.indexOf('async function route(){'), app.indexOf('function passwordControlHtml('));
  assert.match(routeFn, /&&!BOTTLE_SURFACES_V275\.has\(pageKey\)/,
    'the generic module bounce must not swallow the bottle routes');
  // Both pages re-check the sector themselves, so the exemption above cannot become a hole.
  assert.match(app, /async function bottlesPage\(\)\{[\s\S]*?if\(!isBarSectorV275\(\)\)return bottlesUnavailableCardV275\('Bottles'\);/);
  assert.match(app, /async function bottleSetupPageV275\(\)\{[\s\S]*?if\(!isBarSectorV275\(\)\)return bottlesUnavailableCardV275\('Bottle keep'\);/);
  assert.match(app, /title:'Not available for this business type'/);
  // Bottle keep setup is owner-only, exactly like the other Operations setup surfaces.
  assert.match(app, /const OWNER_ONLY_MODULES=new Set\(\['branches','staffmembers','settings','setup','bottlesetup'\]\);/);
  assert.match(app, /async function bottleSetupPageV275\(\)\{[\s\S]*?if\(S\.myRole!=='owner'\)return bottlesDeniedCardV275\('Bottle keep'\);/);
  // Both routes are dispatchable.
  assert.match(app, /bottles:bottlesPage,bottlesetup:bottleSetupPageV275,/);
});

test('V275 Operations setup carries the keep window and the storage list, owner-gated', () => {
  const page = app.slice(app.indexOf('async function bottleSetupPageV275(){'),
    app.indexOf('async function bottlesPage(){'));
  assert.match(page, /sb\.rpc\('bar_get_setup_v275',\{p_business:S\.biz\.id\}\)/);
  // V279 RETARGET: the setup save moved to bar_save_setup_v279, which writes the same keep window
  // and shelf list PLUS the storage capacity. A fourth parameter on the old name would have been a
  // second overload differing only in arity — the shape PostgREST cannot resolve — so the name
  // changed instead, and bar_save_setup_v275 is deliberately left deployed and callable.
  assert.match(page, /sb\.rpc\('bar_save_setup_v279',\{/);
  assert.match(page, /<h2>Keep window<\/h2>/);
  assert.match(page, /id="bkDays" type="number" min="1" max="365"/);
  assert.match(page, /<h2>Storage places<\/h2>/);
  assert.match(page, /id="bkNewLoc"/);
  assert.match(page, /id="bkAddLoc"/);
  // Loading, error and empty states all exist.
  assert.match(page, /CUI\.loadingState\(\{title:'Bottle keep'/);
  assert.match(page, /CUI\.errorState\(\{title:'Bottle keep unavailable'/);
  assert.match(page, /title:'No storage places yet'/);
});

test('V275 the Park dialog asks the reference questions and previews the expiry', () => {
  const page = app.slice(app.indexOf('async function bottlesPage(){'),
    app.indexOf('/* The event log speaks'));
  // V279 RETARGET: 'parkReentry' is GONE (owner: "what is the purpose of re-entry? please remove
  // it") and 'parkQuantity' takes its place in the flow. The contract this line guards — that the
  // park dialog asks every question the bar actually needs before it takes somebody's bottle — is
  // unchanged; the list of questions is the owner's, and it moved.
  for (const field of ['parkCustomerSearch', 'parkClient', 'parkLabel', 'parkSize', 'parkFill',
    'parkLocation', 'parkQuantity']) {
    assert.ok(page.includes(`id="${field}"`), `the Park dialog must carry ${field}`);
  }
  assert.ok(!page.includes('id="parkReentry"'), 're-entry must be gone from the park dialog');
  assert.match(page, /id="parkProduct"/, 'a bottle may be picked from the product catalogue');
  // V279 RETARGET: the re-entry select and its Default/Disabled/N-pax options were removed on the
  // owner's instruction. What replaces them here is the quantity the owner asked for instead.
  assert.match(page, /id="parkQuantity" type="number" min="1" max="20"/);
  // The expiry the business's own keep window produces is shown BEFORE the button is pressed.
  assert.match(page, /const expiry=new Date\(Date\.now\(\)\+keepDays\*864e5\);/);
  assert.match(page, /Expires \$\{esc\(sgt\(expiry\.toISOString\(\)\)\|\|''\)\} · \$\{keepDays\} days/);
  // V278 SUPERSEDES THIS CALL SITE. The park dialog now sends the five extra answers the reference
  // bar asks for (expiry mode, expiry date, notify channel, note, purchase date) to
  // park_bottle_v278. park_bottle_v275 is deliberately left deployed and callable so a deploy in
  // flight cannot break, but the browser no longer names it; the contract this line guards — one
  // literal rpc call carrying the whole request plus the idempotency key — is unchanged.
  // V279 SUPERSEDES THIS CALL SITE AGAIN. Park now sends the owner's quantity (1..20) to
  // park_bottles_v279, which writes N bottles in one transaction under ONE idempotency key and
  // derives the per-bottle evidence keys from it. park_bottle_v275 and park_bottle_v278 both stay
  // deployed and callable so a deploy in flight cannot break. The contract this line guards — one
  // literal rpc call carrying the whole request plus the idempotency key — is unchanged.
  assert.match(page, /sb\.rpc\('park_bottles_v279',\{\.\.\.request,p_idempotency_key:key\}\)/);
});

test('V275 the bottle detail dialog carries the fill presets and every lifecycle action', () => {
  const page = app.slice(app.indexOf('async function bottlesPage(){'),
    app.indexOf('/* The event log speaks'));
  // V279 RETARGET: the owner asked for four smart buttons — 25 / 50 / 75 / 100 — so the 'Empty'
  // preset was dropped. A genuinely empty bottle is still reachable through the exact input beside
  // them, which is the control this test's next assertion pins.
  assert.match(app,
    /const BOTTLE_FILL_PRESETS_V275=Object\.freeze\(\[\[100,'100%'\],\[75,'75%'\],\[50,'50%'\],\[25,'25%'\]\]\);/);
  assert.match(page, /BOTTLE_FILL_PRESETS_V275\.map\(\(\[value,label\]\)=>/);
  assert.match(page, /id="bottleFillInput"/, 'an exact number sits beside the presets');
  // V279 RETARGET: finish_bottle_v275 is no longer called from this screen. 'Retrieved' is
  // terminal at V279 (owner rulings 10 and 13), so set_bottle_status_v275 is the one control that
  // ends a bottle and the separate Finish button is gone — two buttons for one physical event is
  // how a shelf list starts disagreeing with the shelf. The DB function stays deployed.
  for (const rpc of ['set_bottle_fill_v275', 'set_bottle_status_v275', 'extend_bottle_v275',
    'transfer_bottle_v275']) {
    assert.ok(page.includes(`sb.rpc('${rpc}'`), `the detail dialog must call ${rpc} literally`);
  }
  assert.ok(!page.includes("sb.rpc('finish_bottle_v275'"),
    'the V279 card ends a bottle with Retrieved, not with a second Finish control');
  // Call / At table / Back to storage.
  for (const status of ['stored', 'called', 'at_table']) {
    assert.ok(page.includes(`data-status="${status}"`), `the detail dialog must offer ${status}`);
  }
  assert.match(page, /<h3 style="margin:0;font-size:15px">History<\/h3>/,
    'the event history is the answer to a property dispute and must be on the sheet');
  // One key per intention, released only once the write has landed.
  assert.match(page, /const key=attemptKey\(fingerprint\);/);
  assert.match(page, /bottleAttemptKeys\.delete\(fingerprint\);/);
  // Denied, loading, empty and error states.
  assert.match(page, /bottlesDeniedCardV275\('Bottles'\)/);
  assert.match(page, /CUI\.loadingState\(\{title:'Bottles'/);
  assert.match(page, /CUI\.errorState\(\{title:'Bottles unavailable'/);
  assert.match(page, /title:'No bottles here'/);
});

test('V275 the customer card exists only when the read returns rows, and fails soft', () => {
  const loader = app.slice(app.indexOf('const loadBottlesV275=async()=>{'),
    app.indexOf('const loadFeedback=async()=>{'));
  assert.ok(loader.length > 0, 'the wallet must carry a bottles loader');
  // Bar-only on the customer side too, before a single request is made.
  assert.match(loader, /if\(String\(b\.industry\|\|''\)\.toLowerCase\(\)!=='bar'\)return;/);
  assert.match(loader, /customerRpc\('customer_get_bottles_v275',\{p_business_slug:businessSlug\}\)/);
  // Fail-soft: an error hides the card rather than breaking the wallet.
  assert.match(loader, /if\(error\)return;/);
  // Render-only-when-rows: no skeleton shell is emitted up front, and an empty list renders
  // nothing at all.
  assert.match(loader, /if\(!bottles\.length\)return;/);
  assert.match(loader, /sections\.insertAdjacentHTML\('afterbegin',/);
  assert.doesNotMatch(app, /walletSectionShell\('walletBottles'/,
    'a shell would flash a bottles card at every customer of every non-bar business');
  // What the customer is actually shown.
  // V279 RETARGET: 'reentry_limit' is gone from the customer card too — the server stopped
  // publishing it in the shared projection AND in the customer read, so there is nothing left to
  // render. Everything else the customer is shown is unchanged.
  for (const fragment of ['Your bottles', 'serial_code', 'bottleFillBarV275', 'parked_at',
    'bottleDaysLabelV275', 'storage_location_name']) {
    assert.ok(loader.includes(fragment), `the customer card must show ${fragment}`);
  }
  assert.ok(!loader.includes('reentry_limit'),
    'the customer card must not mention re-entry');
  // It is read-only: no bottle write RPC is reachable from the customer surface.
  for (const rpc of ['park_bottle_v275', 'extend_bottle_v275', 'transfer_bottle_v275',
    'finish_bottle_v275', 'set_bottle_fill_v275', 'set_bottle_status_v275']) {
    assert.ok(!loader.includes(rpc), `the customer card must not call ${rpc}`);
  }
  assert.match(app, /loadFeedback\(\),loadBottlesV275\(\)\]\);/,
    'the loader must actually run with the other wallet sections');
});

test('V275 the customer read resolves identity server-side and cannot ask for someone else', () => {
  const body = functionBody('customer_get_bottles_v275');
  assert.match(body, /from app\.v32_customer_wallet_context\(p_business_slug\) context/,
    'identity comes from the verified-link context, never from an argument');
  assert.match(body, /and bottle\.client_id = v_client/);
  assert.match(body, /if not \('bottles' = any \(coalesce\(v_modules, '\{\}'::text\[\]\)\)\) then/,
    'the module must be enabled for that business');
  assert.doesNotMatch(body, /p_client/,
    'no caller-supplied customer identifier may exist on the customer read');
});
