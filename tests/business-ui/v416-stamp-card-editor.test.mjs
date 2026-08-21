/* nestly_v416 — the stamp card IS the editor.

   The owner struck out the whole Level / Stamps required / Reward / Description / Photo table and
   drew the card itself: numbered circles, a gift sitting on 5, 10 and 15, a "+" to carry on, and
   "then click pop-up to design reward, add reward photo / etc". Rulings that came with it:
     * the card RESETS when full and the same gifts come round again;
     * there is NO second "page";
     * default one gift every 5 stamps, and a gift may be added, edited or deleted at ANY stamp;
     * a change to a live gift applies from a customer's NEXT card.

   The last one is enforced in the database (app.stamp_cycle_version_v416) and proved by
   db/tests/v416_stamp_cycle_config_pin.sql against production. This file covers the editor: the
   grid is EXECUTED, not matched in the source. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260821_nestly_v416_stamp_cycle_config_pin.sql'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};
const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* The v416 block, evaluated exactly as it ships. Its inputs — the saved card length, the gifts,
   and whether this user may edit — are injected, because those are the whole question. */
const grid = ({ stampTarget = 0, gifts = [], canSetupGrow = true } = {}) => new Function(
  'snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow', 'CUI', 'esc', `
  ${statement('  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';")}
  return {growStampsCardLenV416, growStampsTargetV416, growStampsHighestGiftV416,
    growStampsStrandedV416, growStampsCardLengthBarV416, growStampsGridV416,
    growStampsStrandedNoteV416};`)(
  { loyalty: { stamp_target: stampTarget } },
  gifts,
  new Map(gifts.map(g => [Math.max(0, Number(g.cost_points) || 0), g]).filter(([n]) => n > 0)),
  canSetupGrow,
  { icon: name => `<svg data-icon="${name}"></svg>` },
  esc);

const GIFT = (name, stamps) => ({ id: `r-${stamps}`, customer_name: name, cost_points: stamps });
const cells = markup => [...markup.matchAll(/data-grow-stamps-cell-v416="(\d+)"/g)].map(m => Number(m[1]));

test('v416 a firm with no card length yet gets 15 stamps, drawn in order', () => {
  const g = grid({ stampTarget: 0, gifts: [] });
  assert.equal(g.growStampsCardLenV416, 15, 'the owner drew fifteen');
  assert.deepEqual(cells(g.growStampsGridV416),
    [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15], 'every stamp, in order, each one tappable');
  assert.match(g.growStampsGridV416, /is-add-v416/, 'and a "+" to carry on');
  assert.match(g.growStampsGridV416, /one every 5 stamps/,
    'an empty card says where to start rather than showing a bare row of circles');
});

test('v416 a gift is marked ON the stamp that pays it out', () => {
  const g = grid({ stampTarget: 15, gifts: [GIFT('Free drink', 5), GIFT('Free lotion', 10), GIFT('Free facial', 15)] });
  const tags = markup => [...markup.matchAll(/<button[^>]*data-grow-stamps-cell-v416="(\d+)"[^>]*>/g)];
  const gifted = tags(g.growStampsGridV416)
    .filter(m => m[0].includes('is-gift-v416')).map(m => Number(m[1]));
  assert.deepEqual(gifted, [5, 10, 15], 'the owner drew gifts on 5, 10 and 15');
  /* Each cell says what it does, because a circle with a number is not self-explanatory. */
  assert.match(g.growStampsGridV416, /aria-label="Stamp 10 gives Free lotion\. Edit this gift\."/);
  assert.match(g.growStampsGridV416, /aria-label="Stamp 4 has no gift\. Add one\."/);
});

test('v416 the card is never drawn shorter than a gift already on it', () => {
  /* Cubbly's live state: a 5-stamp card with a gift at stamp 10, which the counter refuses. */
  const g = grid({ stampTarget: 5, gifts: [GIFT('Free Massage Oil', 5), GIFT('Free Lotion', 10)] });
  assert.equal(g.growStampsCardLenV416, 10,
    'hiding the stranded gift would leave the owner unable to find the one nobody can claim');
  assert.equal(g.growStampsStrandedV416, true);
  assert.match(g.growStampsStrandedNoteV416, /Stamps past 5 cannot be claimed yet/);
  assert.match(g.growStampsStrandedNoteV416, /data-grow-stamps-len-v416="10"/,
    'and it offers the one-tap fix rather than only describing the problem');
  const past = [...g.growStampsGridV416.matchAll(/<button[^>]*data-grow-stamps-cell-v416="(\d+)"[^>]*>/g)]
    .filter(m => m[0].includes('is-past-v416')).map(m => Number(m[1]));
  assert.deepEqual(past, [6,7,8,9,10], 'the unreachable stretch is marked, not silently drawn');
});

test('v416 the length stepper cannot shorten the card past a live gift', () => {
  const g = grid({ stampTarget: 10, gifts: [GIFT('Free Lotion', 10)] });
  const minus = g.growStampsCardLengthBarV416.match(/data-grow-stamps-len-v416="9"[^>]*/)[0];
  assert.match(minus, /disabled/,
    'business_set_stamp_card_length_v414 would refuse it; the button must not offer it');
  assert.match(g.growStampsCardLengthBarV416, /data-grow-stamps-len-v416="11"/, 'longer is always allowed');
});

test('v416 a user who may not edit sees the card but is offered no controls', () => {
  const g = grid({ stampTarget: 10, gifts: [GIFT('Free Lotion', 10)], canSetupGrow: false });
  assert.equal(cells(g.growStampsGridV416).length, 0, 'no cell is a button');
  assert.doesNotMatch(g.growStampsGridV416, /is-add-v416/);
  assert.doesNotMatch(g.growStampsCardLengthBarV416, /grow-stamps-lenstep-v416/);
  assert.match(g.growStampsGridV416, /grow-stamps-editcell-v416/, 'but the card itself is still shown');
});

test('v416 the level table it replaced is gone, and so is its renderer', () => {
  assert.doesNotMatch(appJs, /growStampsLevelRowV350/, 'a dead 50-line renderer is drift');
  assert.doesNotMatch(appJs, /growStampsHeadRowV356/);
  /* The dashed "+ Add another level" button is gone; the grid's own "+" replaces it. The PHRASE
     survives in a v410 comment quoting the owner's markup — that is history, not a control — so
     this asserts on the class the button actually had. */
  assert.doesNotMatch(appJs, /grow-stamps-addlevel-v350/);
  /* History is untouched: it renders through growPointsGiftRowV326 and always did. */
  assert.match(appJs, /growPointsHistoryV326\.map\(reward=>growPointsGiftRowV326\(reward,\{history:true\}\)\)/);
});

test('v416 tapping a stamp opens the ONE gift form, fixed to that stamp', () => {
  /* end marker is the NEXT statement, not '});' — the handler body contains several of those. */
  const handler = statement("outerMain.querySelectorAll('[data-grow-stamps-cell-v416]')",
    "  /* nestly_v416: the card's length.");
  assert.match(handler, /growStampsPickedV416=stamp;/);
  assert.match(handler, /growPointsAddOpenV326='form';/);
  /* An occupied stamp opens ITS gift; an empty one opens a new gift at that number. */
  assert.match(handler, /growPointsEditingV326=reward\?String\(reward\.id\):null;/);
  assert.match(handler, /points:String\(stamp\)/);
  /* The grid is the stamp chooser, so the number field must not invite a second answer. */
  const form = statement('const growPointsAddFormV326=', "</li>`:'';");
  assert.match(form, /growStampsPickedV416\?' readonly aria-readonly="true"':''/);
  assert.match(form, /On stamp \$\{growStampsPickedV416\}/);
  /* and Delete came into the dialog with it, because the row it used to sit on is gone. */
  assert.match(form, /data-grow-points-gift-delete-v326="\$\{esc\(growPointsEditingV326\)\}"/);
});

test('v416 the card length is written through the server, and its refusal is shown verbatim', () => {
  const handler = statement("outerMain.querySelectorAll('[data-grow-stamps-len-v416]')",
    "  const growPointsAddCancel=");
  assert.match(handler, /sb\.rpc\('business_set_stamp_card_length_v414',/);
  assert.match(handler, /p_stamps:next/);
  assert.match(handler, /growPointsErrorV326=ownerErrorText\(error\)/,
    'v414 names the gift that is in the way — replacing that message would lose the only detail');
});

/* ------------------------------------------------- the ruling, in the database --------------- */

test('v416 all three stamp reads resolve the customer\'s OWN card, not the firm\'s latest publish', () => {
  for (const fn of ['stamp_progress_v323', 'customer_get_stamp_card_v323', 'redeem_reward_core']) {
    assert.ok(migration.includes(fn), `${fn} must be re-pointed at the resolver`);
  }
  assert.match(migration, /create or replace function app\.stamp_cycle_version_v416\(/);
  /* An empty card takes today's setup — this is what makes "from their next card" work. */
  assert.match(migration, /Nothing collected on this card yet: no promise has been made/);
  /* And the resolver is server-side only. */
  assert.match(migration,
    /revoke all on function app\.stamp_cycle_version_v416\(uuid,uuid,uuid\) from public, anon, authenticated;/);
});

test('v416 the grid is styled from the same vocabulary as the customer preview', () => {
  assert.match(html, /\.grow-stamps-editcell-v416\{/);
  const rule = html.slice(html.indexOf('.grow-stamps-editcell-v416{'));
  assert.match(rule.slice(0, 400), /width:44px;height:44px/, 'every circle is pressable, so 44px');
  assert.match(html, /\.grow-stamps-editcell-v416\.is-past-v416\{[^}]*var\(--warn\)/,
    'an unclaimable stamp is drawn as a warning, not as a normal one');
});
