/* V276 — the bar sector, as a real bar tenant actually experiences it.
   Owner, 2026-08-11, after creating "Bistro 999" (industry='bar') and signing in:
   "i dont see the full suite of modules ready for production - please plan and analyse and only
   come back when you're ready."

   V275 shipped bottle keep and the 'bar' sector bundle, but every OTHER place that branches on
   sector still only knew the sectors that existed before it: Appointments was advertised to a
   bar (V246 had hard-coded its ruling to the string 'fnb'), the table-seating control was hidden
   from a bar even though its own helper text says "turn this on for a cafe, restaurant or bar",
   the give-back band and the starting reward templates fell to their anonymous defaults, the
   guided setup never mentioned the module the bar was sold, and the SQL recommender sent a bar
   to 'classic' instead of the spend-based tier ladder the owner asked for.

   These tests pin the sector rules, in both directions: what a bar now gets, and what every
   other sector must keep. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migrationPath = join(
  root, 'db', 'migrations', '20260811_nestly_v276_bar_sector_polish.sql');
const suitePath = join(root, 'db', 'tests', 'v276_bar_sector_polish.sql');

const navHtml = app.slice(
  app.indexOf('function navHtml(page,idPrefix=\'nav\'){'),
  app.indexOf('function wireNav(){'));

/* Every sector key the product offers, so "no other sector moved" can be asserted by name
   rather than by hope. */
const OTHER_SECTORS = ['salon', 'facial', 'massage', 'fitness', 'retail', 'other'];

test('V276 the sectors that hide Appointments are a named set of exactly fnb and bar', () => {
  assert.match(app, /const SEATED_SECTORS_WITHOUT_APPOINTMENTS_V276=new Set\(\['fnb','bar'\]\);/);
  assert.match(app,
    /const sectorHidesAppointmentsV276=\(\)=>\s*SEATED_SECTORS_WITHOUT_APPOINTMENTS_V276\.has\(String\(S\.biz\?\.industry\|\|''\)\.toLowerCase\(\)\);/);
  const declaration = app.match(/const SEATED_SECTORS_WITHOUT_APPOINTMENTS_V276=new Set\(\[([^\]]*)\]\);/);
  assert.ok(declaration, 'the seated-sector set must be a literal array so it can be read here');
  for (const sector of OTHER_SECTORS) {
    assert.ok(!declaration[1].includes(`'${sector}'`),
      `${sector} books a person's time and must keep Appointments`);
  }
});

test('V276 the rail hides Appointments for a bar through the V246 rule, unchanged in shape', () => {
  assert.match(navHtml, /const sectorHidesAppointmentsV246=sectorHidesAppointmentsV276\(\);/);
  assert.match(navHtml, /\(m==='appointments'&&!sectorHidesAppointmentsV246&&enabled\.includes\(m\)\)/);
  // Every other module keeps its exact rule, including the V223 waitlist-rides-on-bookings pair.
  assert.match(navHtml, /\(m!=='waitlist'&&m!=='appointments'&&enabled\.includes\(m\)\)/);
  assert.match(navHtml, /\(m==='waitlist'&&enabled\.includes\('waitlist'\)&&enabled\.includes\('bookings'\)\)/);
});

test('V276 hiding stays advertisement-level — the #/appointments route still resolves', () => {
  const routeFn = app.slice(app.indexOf('async function route(){'),
    app.indexOf('function passwordControlHtml('));
  assert.doesNotMatch(routeFn, /sectorHidesAppointments/,
    'a bar with a historical appointment, a deep link or a Customer 360 hand-off must not be stranded');
  // The page is still wired into the route table.
  assert.match(app, /appointments:appointmentsPage/);
});

test('V276 the app-bar action and the mobile dock follow the same rule as the rail', () => {
  /* A rail that hides Appointments while a "New appointment" button sits in the app bar on every
     page is the same "why is this here?" the owner already ruled on — the module would still be
     advertised, just from a different corner of the same screen. */
  const occurrences = app.match(
    /const canViewAppts=canReadModule\('appointments'\)&&!sectorHidesAppointmentsV276\(\);/g) || [];
  assert.equal(occurrences.length, 2,
    'both the global action cluster and the staff mobile dock must consult the sector rule');
  assert.doesNotMatch(app, /const canViewAppts=canReadModule\('appointments'\);/,
    'no advertisement site may keep the unfiltered check');
});

test('V276 a bar keeps Bookings and Waitlist in Serve & sell, and Bottles standalone (v488)', () => {
  assert.match(app,
    /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely");
       nestly_v488 (owner, photo 2): Bottles left the group for its own flat rail entry. */
    /\{key:'serve',icon:'till',label:'Serve & sell',items:\['till','appointments','bookings','waitlist'\]\}/);
  assert.match(app, /\{key:'bottles',icon:'bottle',flat:'Bottles',items:\['bottles'\]\}/);
  // Bottles is stripped for every sector except a bar, and for no other reason.
  assert.match(navHtml, /const sectorShowsBottlesV275=isBarSectorV275\(\);/);
  assert.match(navHtml, /\.filter\(module=>module!=='bottles'\|\|sectorShowsBottlesV275\)/);
  assert.match(navHtml, /\(m==='bottlesetup'&&sectorShowsBottlesV275&&S\.myRole==='owner'\)/);
  // Neither Bookings nor Waitlist acquired a sector rule of any kind.
  assert.doesNotMatch(navHtml, /m==='bookings'&&[^)]*industry/);
});

test('V276 table seating is offered to a bar', () => {
  assert.match(app,
    /const seatingSectorV235=\['fnb','bar','other'\]\.includes\(String\(S\.biz\.industry\|\|''\)\.toLowerCase\(\)\);/);
  // The switch itself, and everything it unlocks, are unchanged.
  assert.match(app, /const seatsGuestsV235=seatingSectorV235&&S\.biz\.takes_table_reservations===true;/);
  const seated = app.match(/const seatingSectorV235=\['([^\]]*)'\]/);
  for (const sector of ['salon', 'facial', 'massage', 'fitness', 'retail']) {
    assert.ok(!seated[1].includes(sector),
      `${sector} has no tables — V235 must still keep the seating question away from it`);
  }
});

test('V276 the give-back band and the starting rewards know what a bar sells', () => {
  assert.match(app, /if\(\/\^bar\$\|pub\/\.test\(key\)\)\s*\n?\s*return \{label:'Bar \/ Pub',low:2,high:8,start:5\};/);
  // The F&B band it copies is untouched, and so is the anonymous fallback for a sector with no
  // profile of its own.
  assert.match(app, /return \{label:'F&B \/ Café',low:2,high:8,start:5\};/);
  assert.match(app, /return \{label:'your sector',low:2,high:10,start:5\};/);
  // Starting reward templates: a bar gets the F&B set ("Free drink"), not the generic one.
  assert.match(app, /sets\.facial=sets\.salon;sets\.massage=sets\.salon;/);
  assert.match(app, /sets\.bar=sets\.fnb;/);
});

test('V276 the guided setup asks a bar to park its first bottle, and asks nobody else', () => {
  const setup = app.slice(app.indexOf('async function setupPage(){'),
    app.indexOf('/* ---------- staff performance ---------- */'));
  assert.match(setup,
    /const showBottleStepV276=isBarSectorV275\(\)&&\(S\.myRole==='owner'\|\|canReadModule\('bottles'\)\);/);
  assert.match(setup, /\.\.\.\(showBottleStepV276\?\[\{id:'bottles',icon:'bottle',title:'Park your first bottle',/);
  assert.match(setup, /link:'#\/bottles',cta:'Park a bottle →'\}\]:\[\]\),/);
  // The probe is the Bottles page's own RPC, is only issued for a bar, and its failure must not
  // take the other six checks down with it.
  assert.match(setup, /showBottleStepV276\s*\n?\s*\?sb\.rpc\('list_bar_bottles_v275'/);
  assert.match(setup, /:Promise\.resolve\(\{data:null,error:null\}\)/);
  assert.match(setup, /const err=e1\|\|e2\|\|e3\|\|e4\|\|e5\|\|e6;/,
    'the bottle probe must stay out of the guide-wide error gate');
  // The progress meter counts whatever steps exist, so the extra step cannot desynchronise it.
  assert.match(setup, /const doneCount=steps\.filter\(s=>s\.done\)\.length;/);
  assert.match(setup, /\$\{doneCount\} of \$\{steps\.length\} done/);
});

test('V276 the migration splices only the bar sector into the recommender', () => {
  assert.ok(existsSync(migrationPath), 'the V276 migration file must exist');
  const migration = readFileSync(migrationPath, 'utf8');
  // The needles are pure SQL — a comment-anchored needle would miss, because the MCP migration
  // path strips comments.
  assert.match(migration,
    /in \('salon','spa','facial','massage','fitness','retail'\) then 'points_tiers'/);
  assert.match(migration,
    /in \('salon','spa','facial','massage','fitness','retail','bar'\) then 'points_tiers'/);
  assert.match(migration,
    /'tier_basis',case when lower\(coalesce\(v_business\.industry,''\)\)='bar' then 'spend' else null end,/);
  // Exactly-one assertions before either splice runs, and a post-execute verification.
  assert.match(migration, /raise exception 'v276: expected exactly 1 sector-CASE needle/);
  assert.match(migration, /raise exception 'v276: expected exactly 1 draft-save needle/);
  assert.match(migration, /raise exception 'v276: the bar sector did not land in the deployed recommender'/);
  // No other sector's mapping is rewritten, and no entitlement is widened behind the owner's back.
  assert.doesNotMatch(migration, /update public\.sector_bundle_versions/);
  assert.doesNotMatch(migration, /update public\.businesses/);
  assert.doesNotMatch(migration, /then 'stamps'[\s\S]{0,40}'bar'/);
});

test('V276 the rollback suite proves the bar change and the absence of a leak', () => {
  assert.ok(existsSync(suitePath), 'the V276 rollback suite must exist');
  const suite = readFileSync(suitePath, 'utf8');
  assert.match(suite, /^begin;/m);
  assert.match(suite, /^rollback;/m);
  assert.match(suite, /v276\.4: bar recommended % instead of points_tiers/);
  assert.match(suite, /v276\.4: bar draft tier_basis is % instead of spend/);
  assert.match(suite, /v276\.3: fnb recommended % instead of stamps/);
  assert.match(suite, /v276\.5: salon draft tier_basis moved from % to % - the bar-only write leaked/);
  assert.match(suite, /v276\.6: other recommended % instead of classic/);
});

test('V276 the sector map and the landing page name the bar', () => {
  assert.match(app, /bar:\{em:'🍸',label:'Bar \/ Pub',mods:\[/);
  const landing = readFileSync(join(root, 'app', 'landing.html'), 'utf8');
  assert.match(landing, /Bars &amp; pubs<\/li>/);
  // The categories strip is a list of who the product is for; it gains one entry and loses none.
  for (const category of ['Cafés', 'Restaurants', 'Fitness studios', 'Retail shops', 'Services']) {
    assert.ok(landing.includes(`${category}</li>`), `${category} must stay in the categories strip`);
  }
});
