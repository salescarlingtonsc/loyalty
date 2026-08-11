/* V278 — bottle keep parity with the live reference bar (owner screenshots, 2026-08-11).
   Eight additions to the V275 module: tiered expiry, a bottle catalogue with synced ml, a
   'retrieved' lifecycle state, notes, a stored notify preference plus a manual in-app Notify,
   purchase date, move, a tier badge, and a bar-only Dashboard card.
   The assertions that matter here are the ones a screenshot cannot check: that the expiry
   resolution ORDER is fixed, that the millilitres cannot be typed once a catalogue bottle is
   picked, that the retrieved transitions are refused SERVER-SIDE rather than merely unbuttoned,
   and that a non-bar tenant gains nothing at all from any of it. */
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
  join(root, 'db', 'migrations', '20260811_nestly_v278_bottle_keep_parity.sql'), 'utf8');
const suite = readFileSync(join(root, 'db', 'tests', 'v278_bottle_keep_parity.sql'), 'utf8');

const NEW_RPCS = [
  'bar_get_bottle_setup_v278',
  'bar_save_tier_keep_days_v278',
  'bar_save_bottle_product_v278',
  'bar_client_keep_days_v278',
  'park_bottle_v278',
  'set_bottle_expiry_v278',
  'add_bottle_note_v278',
  'move_bottle_v278',
  'set_bottle_purchased_on_v278',
  'notify_bottle_v278'
];
const MUTATING_RPCS = [
  'park_bottle_v278',
  'set_bottle_expiry_v278',
  'add_bottle_note_v278',
  'move_bottle_v278',
  'set_bottle_purchased_on_v278',
  'notify_bottle_v278'
];

function functionBody(name, schema = 'public') {
  const start = migration.indexOf(`create or replace function ${schema}.${name}(`);
  assert.notEqual(start, -1, `${name} must be defined in the V278 migration`);
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

/* ------------------------------------------------------------------ 1. tiered expiry */

test('V278 the tier keep window lives in a bar-scoped table, never on loyalty_tiers', () => {
  assert.match(migration, /create table public\.bar_tier_keep_days_v278 \(/);
  assert.match(migration, /keep_days integer not null check \(keep_days between 1 and 365\)/);
  assert.match(migration, /primary key \(business_id, tier_id\)/);
  // The prior owner ruling (V275 amendment 1) stands: the tier mechanism gains no bar column.
  assert.doesNotMatch(migration, /alter table public\.loyalty_tiers/,
    'V278 must not add anything to the tier tables');
  // And it must NOT be a real foreign key: publish_loyalty_config DELETEs and re-INSERTs
  // loyalty_tiers on every publish, so an FK would either block the publish or erase the
  // overrides. The reason has to be written down, or the next increment "fixes" it.
  assert.doesNotMatch(migration, /tier_id uuid not null references public\.loyalty_tiers/,
    'a restricting FK to loyalty_tiers would fight the publish cycle (V176 precedent)');
  assert.match(migration, /soft reference to loyalty_tiers\.id/,
    'the soft reference must be documented at the table');
  // A soft reference earns its keep only if the write validates it.
  const save = functionBody('bar_save_tier_keep_days_v278');
  assert.match(save, /that tier does not belong to this business/,
    'the save must refuse a tier that is not this business own');
});

test('V278 Auto resolves tier override -> business default, in ONE place', () => {
  const resolver = functionBody('bar_keep_days_for_client_v278', 'app');
  // The order is the contract: the tier's own number first...
  const tierRead = resolver.indexOf('from public.bar_tier_keep_days_v278');
  const fallback = resolver.indexOf('app.bar_keep_days_v275(p_business)');
  assert.ok(tierRead !== -1 && fallback !== -1 && tierRead < fallback,
    'the tier override must be consulted before the business default');
  assert.match(resolver, /coalesce\(v_days, app\.bar_keep_days_v275\(p_business\)\)/,
    'a tier with no override falls through to the business default, which itself defaults to 30');
  // A misconfigured or mid-publish tier must not stop a bottle being parked.
  assert.match(resolver, /exception when others then\s+v_tier_id := null;/,
    'tier resolution must fail soft');

  // Custom and none are the other two modes, and they are resolved by the same function the park
  // and the edit both call, so a preview cannot disagree with the write.
  const expiry = functionBody('bar_bottle_expiry_v278', 'app');
  assert.match(expiry, /if v_mode = 'none' then\s+return null;/);
  assert.match(expiry, /\(\(p_date \+ 1\)::timestamp\) at time zone 'Asia\/Singapore'/,
    'a custom date is the END of that Singapore day');
  assert.match(expiry, /a bottle cannot be kept more than two years/);
  assert.match(expiry, /app\.bar_keep_days_for_client_v278\(p_business, p_client\)/);
  for (const caller of ['park_bottle_v278', 'set_bottle_expiry_v278']) {
    assert.match(functionBody(caller), /app\.bar_bottle_expiry_v278\(/,
      `${caller} must resolve the expiry through the one resolver`);
  }
});

test('V278 no expiry is a real state the schema and both surfaces can hold', () => {
  assert.match(migration, /alter table public\.bar_bottles alter column expires_at drop not null;/);
  assert.match(migration,
    /check \(\(expiry_mode = 'none'\) = \(expires_at is null\)\)/,
    'the mode and the date must be incapable of disagreeing');
  // Number(null) is 0, which would have rendered "Last day" on a bottle that never expires.
  assert.match(app, /if\(days===null\|\|days===undefined\|\|days===''\)return 'No expiry';/);
  // The server sends null rather than a negative number of days.
  assert.match(migration, /'days_left', case when \(\$1\)\.expires_at is null then null else/);
});

test('V278 the expiry can be edited for the life of the bottle, old -> new', () => {
  const body = functionBody('set_bottle_expiry_v278');
  assert.match(body, /'from', v_before, 'to', v_next,\s*\n\s*'from_mode', v_before_mode, 'to_mode', v_mode/,
    'an expiry edit must record both the old and the new value, and both modes');
  assert.match(body, /this bottle is closed/, 'a closed bottle refuses an expiry edit');
  assert.ok(bottlesPage.includes("sb.rpc('set_bottle_expiry_v278'"),
    'the bottle card must offer Edit expiry');
  assert.match(bottlesPage, /data-expiry-confirm/);
  assert.match(bottlesPage, /<span>Edit expiry<\/span>/);
});

test('V278 Operations setup lists the tiers with an optional keep-days override each', () => {
  assert.match(setupPage, /sb\.rpc\('bar_get_bottle_setup_v278',\{p_business:S\.biz\.id\}\)/);
  assert.match(setupPage, /sb\.rpc\('bar_save_tier_keep_days_v278',\{/);
  assert.match(setupPage, /<h2>Tier keep windows<\/h2>/);
  assert.match(setupPage, /data-tier-days="\$\{index\}"/);
  // An empty box means "no override" and must survive the round trip as null, not as 0.
  assert.match(setupPage, /keep_days:tier\.keep_days===''\?null:Number\(tier\.keep_days\)/);
  assert.match(setupPage, /if\(tier\.keep_days===''\)continue;/);
  // Empty and error states exist for a bar with no programme at all.
  assert.match(setupPage, /title:'No tiers yet'/);
  assert.match(setupPage, /Tier windows could not be loaded/);
});

/* ------------------------------------------------------------------ 2. catalogue + ml */

test('V278 a product becomes a bottle by carrying a size, bounded 100..5000ml', () => {
  assert.match(migration, /alter table public\.products\s+add column size_ml integer,/);
  assert.match(migration,
    /check \(size_ml is null or size_ml between 100 and 5000\)/);
  assert.match(setupPage, /<h2>Bottle catalogue<\/h2>/);
  assert.match(setupPage, /sb\.rpc\('bar_save_bottle_product_v278',\{/);
  assert.match(setupPage, /id="bkAddBottle"/);
  assert.match(setupPage, /data-bottle-ml="\$\{index\}"/);
  // Unmarking is clearing the size, and it must not touch the product a bar still sells.
  const save = functionBody('bar_save_bottle_product_v278');
  assert.match(save, /update public\.products product\s+set size_ml = p_size_ml/,
    'marking or unmarking an existing product must only ever write size_ml');
});

test('V278 the park picker fills the ml and takes the field away', () => {
  // Only products WITH a size are offered, because the whole point is that ml is never typed.
  assert.match(bottlesPage,
    /const bottleProductsV278=products\.filter\(product=>Number\(product\.size_ml\)>0\);/);
  assert.match(bottlesPage, /\$\{bottleProductsV278\.length\?`<label for="parkProduct">Bottle<\/label>/);
  assert.match(bottlesPage, /size\.value=String\(Number\(chosen\.size_ml\)\|\|''\);/);
  assert.match(bottlesPage, /size\.readOnly=true;size\.setAttribute\('aria-readonly','true'\);/,
    'a catalogue bottle must lock the ml field, not merely prefill it');
  assert.match(bottlesPage, /size\.readOnly=false;size\.removeAttribute\('aria-readonly'\);/,
    'clearing the picker must hand the field back for an unlisted bottle');
  // And the server does not trust the browser to have copied it.
  const park = functionBody('park_bottle_v278');
  assert.match(park, /select coalesce\(product\.size_ml, v_size\) into v_size/,
    'the size must be re-read server-side from the chosen catalogue product');
  assert.match(park, /that bottle is not in your catalogue/,
    'a product that is not this business own must be refused');
  // The free-text fallback survives for the bottle that is not on the list.
  assert.match(park, /name the bottle or pick it from the catalogue/);
});

/* ------------------------------------------------------------------ 3. retrieved lifecycle */

test('V278 the transition matrix is enforced SERVER-SIDE, not merely unbuttoned', () => {
  assert.match(migration,
    /create or replace function app\.bar_status_transition_allowed_v278\(p_from text, p_to text\)/);
  assert.match(migration,
    /when \$1 in \('stored', 'called', 'at_table'\)\s+and \$2 in \('stored', 'called', 'at_table', 'retrieved'\) then true/);
  assert.match(migration, /when \$1 = 'retrieved' and \$2 = 'stored' then true/);
  assert.match(migration, /else false/);
  // Spliced into the settled V275 function with comment-free, exactly-once needles and a
  // post-verify against the DEPLOYED definition.
  assert.match(migration, /v278: expected exactly 1 target-status needle in set_bottle_status_v275/);
  assert.match(migration, /v278: expected exactly 1 floor-guard needle in set_bottle_status_v275/);
  assert.match(migration, /v278: the retrieved transition rules did not land in the deployed function/);
  assert.match(migration,
    /if not app\.bar_status_transition_allowed_v278\(v_bottle\.status, v_status\) then/);
  // The status itself is legal in the table.
  assert.match(migration, /'stored'', ''called'', ''at_table'', ''retrieved'', ''finished''/);
  // The rollback suite proves the refusal rather than assuming it.
  assert.match(suite, /retrieved -> called must be refused by the server, not merely unbuttoned/);
});

test('V278 the card offers exactly the moves the server allows', () => {
  // V279 RETARGET, owner rulings 10 and 13. V278 modelled 'retrieved' as a floor state you could
  // walk back from, with a separate Finish beside it. The owner ruled that pressing Retrieved
  // means the bottle went out with the customer and is DONE. The contract this test guards is
  // unchanged — the buttons drawn are exactly the moves the server allows — but the matrix it
  // mirrors is now the V279 one, in which nothing leaves 'retrieved'.
  assert.match(app, /const BOTTLE_TRANSITIONS_V279=Object\.freeze\(\{/);
  assert.match(app, /stored:Object\.freeze\(\['called','at_table','retrieved'\]\)/);
  assert.match(app, /retrieved:Object\.freeze\(\[\]\)/,
    'V279: nothing transitions out of retrieved');
  for (const status of ['stored', 'called', 'at_table']) {
    assert.ok(bottlesPage.includes(`nextStatusesV279.includes('${status}')`),
      `the ${status} button must be drawn from the transition matrix, not from a hand-written rule`);
    assert.ok(bottlesPage.includes(`data-status="${status}"`),
      `the detail dialog must offer ${status}`);
  }
  // Sending a bottle out is now its own terminal control rather than a fourth floor button, and
  // there is no Finish beside it.
  assert.match(bottlesPage, /data-retrieve style="min-height:42px">\$\{CUI\.icon\('export'/);
  assert.match(bottlesPage, /p_status:'retrieved',p_idempotency_key:key\}\),'Bottle retrieved'/);
  assert.ok(!bottlesPage.includes('data-finish'),
    'V279: two buttons for one physical event is how a shelf list starts disagreeing with the shelf');
  // The three states the bar is physically holding, and the three tabs that show them.
  assert.match(app, /const BOTTLE_STORAGE_STATUSES_V279=Object\.freeze\(\['stored','called','at_table'\]\);/);
  assert.match(bottlesPage, /data-bottle-tab="\$\{esc\(value\)\}"/);
  assert.match(app, /retrieved:\{label:'Retrieved',icon:'export',tone:'#6B6560'\}/);
  const customerRead = functionBody('customer_get_bottles_v275');
  assert.match(customerRead, /bottle\.status in \('stored', 'called', 'at_table', 'retrieved'\)/,
    'the V278 read kept a retrieved bottle on the wallet card; V279 recreates this function so a '
    + 'bottle that has left with the customer leaves the card too (see v279_bottle_owner_walkthrough)');
});

/* ------------------------------------------------------------------ 4-7. notes, notify, purchase, move */

test('V278 notes, moves and purchase dates are each one evidence row with old -> new', () => {
  assert.match(migration, /'note'', ''move'', ''purchase''/,
    'the three new event kinds must be added to the CHECK, not smuggled through an existing one');
  const note = functionBody('add_bottle_note_v278');
  assert.match(note, /'note', v_actor, v_key,\s*\n\s*jsonb_build_object\('note', v_note\)/);
  assert.match(note, /a note is limited to 500 characters/);
  const move = functionBody('move_bottle_v278');
  assert.match(move, /'from_name', v_before_name, 'to_name', v_after_name/,
    'a move must name both places — "where was it before" is the question a lost bottle asks');
  assert.match(move, /that storage place is not on your list/);
  const purchase = functionBody('set_bottle_purchased_on_v278');
  assert.match(purchase, /'from', v_before, 'to', p_purchased_on/);
  assert.match(purchase, /a bottle cannot have been bought in the future/);
  // Rendered in the activity log in the bar's language, not the schema's.
  assert.match(app, /case 'note':return `Note: \$\{String\(detail\.note\|\|''\)\}`;/);
  assert.match(app, /case 'move':return `Moved \$\{detail\.from_name/);
  assert.match(app, /case 'purchase':return detail\.to\?`Bought on/);
  // And the park note rides in the park event so one write stays one event.
  assert.match(functionBody('park_bottle_v278'), /'note', v_note\)\);/);
  assert.match(app, /\$\{detail\.note\?` · \$\{String\(detail\.note\)\}`:''\}/);
});

test('V278 the notify preference is stored per park, and sending stays deferred', () => {
  assert.match(migration,
    /check \(notify_channel is null or notify_channel in \('whatsapp', 'email', 'none'\)\)/);
  assert.match(bottlesPage, /id="parkNotify"/);
  assert.match(app, /const BOTTLE_NOTIFY_CHANNELS_V278=Object\.freeze\(\[\s*\n\s*\['none','No reminder'\],\['whatsapp','WhatsApp'\],\['email','Email'\]/);
  assert.match(bottlesPage, /p_notify_channel:\$\('parkNotify'\)\.value\|\|'none'/);
  // Deferred means deferred: no new outbound push channel arrives by the back door.
  assert.doesNotMatch(migration, /create or replace function app\.customer_push_event_eligible_v95/,
    'a manual staff tap must not silently become a web-push channel');
  assert.match(migration, /app\.customer_push_event_eligible_v95 is deliberately NOT extended/,
    'and the omission must be recorded, not merely forgotten');
});

test('V278 Notify writes an in-app inbox event on the V122 rails, and never lies about it', () => {
  const body = functionBody('notify_bottle_v278');
  // Reuse means honouring the inbox's closed vocabulary, so all four guards are extended.
  assert.match(migration, /'v278_bottle_reminder'\n?\s*\)\),/);
  assert.match(migration, /add constraint customer_in_app_inbox_events_source_kind_check[\s\S]*?'v278_bottle_reminder'/);
  assert.match(migration, /add constraint customer_in_app_inbox_events_title_check[\s\S]*?'Your bottle is waiting'/);
  assert.match(migration, /add constraint customer_in_app_inbox_events_body_check[\s\S]*?'Open this business wallet to see the bottle being kept for you\.'/);
  assert.match(migration,
    /'v122_promotion_new','v122_promotion_expiry','v278_bottle_reminder'/,
    'the inbox reader must be told the kind exists or the row is written and then hidden');
  // Identity is derived from the bottle, never supplied.
  assert.match(body, /from public\.customer_links link[\s\S]*?link\.client_id = v_bottle\.client_id/);
  assert.match(body, /and link\.state = 'verified'/);
  assert.match(body, /and preference\.channel = 'in_app'\s+and preference\.topic = 'value_expiry'/,
    'the customer\'s own preference decides whether an inbox row is written');
  assert.match(body, /on conflict \(identity_id, dedupe_key\) do nothing;/);
  // The reminder event is ALWAYS recorded and reports what actually happened.
  assert.match(body, /'reminder', v_actor, v_key,\s*\n\s*jsonb_build_object\('delivery', v_delivery/);
  for (const outcome of ['in_app', 'already_notified', 'opted_out', 'no_customer_app']) {
    assert.ok(body.includes(`'${outcome}'`), `notify must be able to report ${outcome}`);
  }
  assert.match(app, /detail\.delivery==='opted_out'\?'Reminder not sent — they turned reminders off'/,
    '"Reminder sent" when nothing was sent is the lie an evidence log exists to prevent');
  assert.ok(bottlesPage.includes("sb.rpc('notify_bottle_v278'"));
});

/* ------------------------------------------------------------------ 8. tier badge */

test('V278 the tier badge is read-only and fails soft to blank', () => {
  const tier = functionBody('bar_tier_name_v278', 'app');
  assert.match(tier, /select \* into v_tier from app\.loyalty_tier_for\(p_business, p_client\);/,
    'the badge must reuse the existing tier resolver rather than reimplement the rule');
  assert.match(tier, /exception when others then\s+return null;/,
    'a shelf screen must not go dark because a loyalty programme is half configured');
  assert.match(migration, /'tier_name', app\.bar_tier_name_v278\(\(\$1\)\.business_id, \(\$1\)\.client_id\)/,
    'the badge belongs to the ONE shared projection so the row and the card cannot disagree');
  // A blank name renders nothing at all rather than an empty pill that looks like a bug.
  assert.match(app, /function bottleTierPillV278\(name\)\{[\s\S]*?if\(!label\)return '';/);
  assert.match(bottlesPage, /\$\{bottleStatusPillV275\(item\.status\)\}\$\{bottleTierPillV278\(item\.tier_name\)\}/,
    'the badge must be on the list rows');
  assert.match(bottlesPage, /\$\{bottleTierPillV278\(bottle\.tier_name\)\}/,
    'and on the bottle card');
});

/* ------------------------------------------------------------------ 9. dashboard card */

test('V278 the Dashboard card is bar-only and fails soft in every direction', () => {
  const cardStart = app.indexOf('async function loadDashboardBottlesV278(root');
  assert.notEqual(cardStart, -1, 'the dashboard must carry a bottles loader');
  const card = app.slice(cardStart, app.indexOf('async function loadDashboardScheduleGlanceV180('));
  assert.ok(card.length > 0, 'the dashboard must carry a bottles loader');
  assert.match(card, /if\(!isBarSectorV275\(\)\)return;/,
    'a non-bar tenant must see no card at all');
  assert.match(card, /if\(S\.myRole!=='owner'&&!canReadModule\('bottles'\)\)return;/);
  assert.match(card, /if\(error\)return;/, 'an error must hide the card, never break the Dashboard');
  assert.match(card, /sb\.rpc\('list_bar_bottles_v275',\{p_business:S\.biz\.id,p_branch:branchId,/,
    'the card must reuse the Bottles page counts rather than invent a second aggregate');
  // V279 RETARGET: 'Active' became 'In storage', rendered as "N / capacity" — the gauge the owner
  // asked for, read from the same RPC that ENFORCES the capacity. The rest of the card is
  // unchanged, and every tile now carries its status colour.
  for (const label of ['In storage', 'Called', 'At table', 'Retrieved', 'Expiring this week']) {
    assert.ok(card.includes(`'${label}'`), `the card must show ${label}`);
  }
  assert.match(card, /BOTTLE_STATUS_V275\.stored\.tone/,
    'the Dashboard must use the same status colours as the Bottles page');
  assert.match(card, /<a class="btn secondary" href="#\/bottles">Open Bottles<\/a>/);
  // The counts it reads have to exist on the server side.
  const list = functionBody('list_bar_bottles_v275');
  assert.match(list, /'retrieved', count\(\*\) filter \(where bottle\.status = 'retrieved'\)/);
  assert.match(list, /'active', count\(\*\) filter \(/);
  assert.match(list, /and bottle\.expires_at is not null\s+and bottle\.expires_at <= now\(\) \+ make_interval\(days => 7\)/,
    'a bottle with no expiry is active but is never "expiring soon"');
  // The slot exists in the Dashboard markup and the loader is actually invoked.
  assert.match(app, /<div id="dashboardBottlesV278"><\/div>/);
  assert.match(app,
    /loadDashboardBottlesV278\(dashboardRoot,appliedDashboardScopeV141\.branchId\)\.catch\(\(\)=>\{\}\);/);
});

/* ------------------------------------------------------------------ gates and hygiene */

test('V278 every new RPC holds the bar gate as its FIRST authorisation step', () => {
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
      assert.ok(gate < index,
        `${name}: the industry gate must run before the ${label}`);
    }
  }
  // And a non-bar tenant is proven refused, not assumed refused.
  assert.match(suite, /all ten new RPCs refuse a non-bar business with 42501/);
});

test('V278 every mutating RPC is idempotent and writes exactly one evidence row', () => {
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
      `${name} must store the idempotency key on the evidence row`);
  }
});

test('V278 the new table is RPC-only and every RPC revokes PUBLIC', () => {
  assert.match(migration,
    /alter table public\.bar_tier_keep_days_v278 enable row level security;/);
  assert.match(migration,
    /revoke all privileges on table public\.bar_tier_keep_days_v278 from public, anon, authenticated;/);
  assert.doesNotMatch(migration, /create policy [a-z_]*bar_tier_keep/i,
    'the table is RPC-only; a policy would open a second door');
  for (const name of NEW_RPCS) {
    assert.match(migration,
      new RegExp(`revoke all on function public\\.${name}\\([^)]*\\) from public, anon, authenticated;`),
      `${name} must revoke PostgreSQL's default EXECUTE-to-PUBLIC`);
    assert.match(migration,
      new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated;`),
      `${name} must be granted to authenticated only`);
  }
  assert.doesNotMatch(migration, /grant execute on function public\.[a-z_0-9]*v278\([^)]*\) to anon/,
    'no V278 RPC may be reachable anonymously');
});

test('V278 the existing client keeps working: park_bottle_v275 is superseded, not broken', () => {
  // A new NAME, not a second overload of the old one: two functions of one name differing only in
  // arity is the shape that makes PostgREST resolution ambiguous.
  assert.doesNotMatch(migration, /create or replace function public\.park_bottle_v275\(/,
    'V278 must not redefine the V275 park function');
  assert.doesNotMatch(migration, /drop function[^\n]*park_bottle_v275/,
    'the V275 park function must stay callable so a deploy in flight cannot break');
  assert.match(migration, /park_bottle_v275 is untouched and still callable/);
  // V279 RETARGET: the same reasoning applied one increment on. The browser now calls
  // park_bottles_v279 (which adds the owner's quantity, the capacity refusal and the retirement of
  // re-entry) and BOTH earlier park functions stay deployed and callable, spliced in V279 only so
  // that an older client in flight cannot overfill the shelf or re-grow the retired field.
  assert.ok(app.includes("sb.rpc('park_bottles_v279'"),
    'the browser must call the V279 batch park');
  for (const retired of ['park_bottle_v275', 'park_bottle_v278']) {
    assert.ok(!bottlesPage.includes(`sb.rpc('${retired}'`),
      `and must no longer call ${retired}`);
  }
});

test('V278 a non-bar tenant gains none of it', () => {
  // The nav rule is unchanged and still lists bottles for the bar sector only.
  assert.match(app, /\.filter\(module=>module!=='bottles'\|\|sectorShowsBottlesV275\)/);
  // Every new surface sits inside a page or a loader that re-checks the sector first.
  assert.match(app, /async function bottleSetupPageV275\(\)\{[\s\S]*?if\(!isBarSectorV275\(\)\)return bottlesUnavailableCardV275\('Bottle keep'\);/);
  assert.match(app, /async function bottlesPage\(\)\{[\s\S]*?if\(!isBarSectorV275\(\)\)return bottlesUnavailableCardV275\('Bottles'\);/);
  // products.size_ml is the one column that lands on a shared table; it is nullable, so a
  // non-bar tenant's products are unchanged and nothing new is required of them.
  assert.match(migration, /add column size_ml integer,/);
  assert.doesNotMatch(migration, /add column size_ml integer not null/);
});

test('V278 splices name their needles, assert exactly one hit, and verify the deployed result', () => {
  for (const target of ['set_bottle_status_v275', 'extend_bottle_v275']) {
    assert.ok(migration.includes(`pg_get_functiondef('public.${target}(`),
      `${target} must be spliced from its OWN deployed source`);
  }
  assert.match(migration, /v278: expected exactly 1 update needle in extend_bottle_v275, found %/);
  assert.match(migration,
    /v278: the expiry mode did not land in the deployed extend_bottle_v275/);
  // Needles must be pure SQL: the Supabase apply path strips full-line comments, so a
  // comment-anchored needle matches a psql rehearsal and misses production.
  const needles = migration.match(/\$needle\$[\s\S]*?\$needle\$/g) || [];
  assert.ok(needles.length >= 5, 'the splices must use dollar-quoted needles');
  for (const needle of needles) {
    assert.ok(!needle.includes('--'),
      `a needle must contain no SQL comment: ${needle.slice(0, 60)}`);
  }
  // Re-running must be safe.
  assert.match(migration, /already validates transitions - nothing to do/);
  assert.match(migration, /already carries the expiry mode - nothing to do/);
});

test('V278 the migration is one transaction and the suite rolls back', () => {
  assert.match(migration, /^begin;$/m);
  assert.match(migration, /^commit;$/m);
  assert.match(suite, /^begin;$/m);
  assert.match(suite, /^rollback;$/m);
  assert.doesNotMatch(suite, /^commit;$/m, 'the acceptance suite must never commit');
  assert.match(suite, /raise notice 'v278: ALL CHECKS PASSED \(rolling back\)';/);
});
