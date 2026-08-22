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
/* nestly_v453: the stamp editor now renders two of its strings through the workspace copy
   machinery (the disabled length steppers explain their refusal, and that sentence is reviewed,
   localised copy). The REAL machinery is extracted with the block under test rather than stubbed —
   a stub would happily return text for a key nobody registered, which is the one thing the
   workspace audit exists to prevent. */
const workspaceRigV453 = source => {
  const from = source.indexOf('const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({');
  const to = source.indexOf('const workspaceTemplateInnerHtmlV97=', from);
  assert.ok(from >= 0 && to > from, 'workspace template machinery not found in this revision');
  return source.slice(from, to);
};
const grid = ({ stampTarget = 0, gifts = [], canSetupGrow = true, busy = false } = {}) => new Function(
  'snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow',
  'growPointsBusyV326', 'CUI', 'esc', 'workspaceLocale', `
  ${workspaceRigV453(appJs)}
  ${statement('  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';")}
  return {growStampsCardLenV416, growStampsTargetV416, growStampsHighestGiftV416,
    growStampsStrandedV416, growStampsCardLengthBarV416, growStampsGridV416,
    growStampsStrandedNoteV416};`)(
  { loyalty: { stamp_target: stampTarget } },
  gifts,
  new Map(gifts.map(g => [Math.max(0, Number(g.cost_points) || 0), g]).filter(([n]) => n > 0)),
  canSetupGrow,
  /* nestly_v422: the typed length field is disabled while a write is in flight, so the block now
     reads growPointsBusyV326. It is injected rather than stubbed away — leaving it out made the
     whole block throw ReferenceError, which is what these four tests caught. */
  busy,
  { icon: name => `<svg data-icon="${name}"></svg>` },
  esc,
  'en');

const GIFT = (name, stamps) => ({ id: `r-${stamps}`, customer_name: name, cost_points: stamps });
const cells = markup => [...markup.matchAll(/data-grow-stamps-cell-v416="(\d+)"/g)].map(m => Number(m[1]));

test('v416 a firm with no card length yet gets 15 stamps, drawn in order', () => {
  const g = grid({ stampTarget: 0, gifts: [] });
  assert.equal(g.growStampsCardLenV416, 15, 'the owner drew fifteen');
  assert.deepEqual(cells(g.growStampsGridV416),
    [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15], 'every stamp, in order, each one tappable');
  /* nestly_v463 (owner ruling R3a): 15 IS the maximum now, so the grid's trailing "+" — which
     only ever offered len+1 — is withheld at the default length. The refusal is said once, by the
     length bar's own disabled "+" and its reason line; a second dead circle at the end of the
     grid would add nothing. A card below the maximum still gets it, asserted just below. */
  assert.doesNotMatch(g.growStampsGridV416, /is-add-v416/,
    'a 15-stamp card is already the longest a card may be, so nothing offers to lengthen it');
  assert.match(grid({ stampTarget: 12, gifts: [] }).growStampsGridV416, /is-add-v416/,
    'but a 12-stamp card still has a "+" to carry on');
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

test('v416/v445 a gift past the end is reported, and the card is still drawn at its real length', () => {
  /* Cubbly's live state: a 5-stamp card with a gift at stamp 10, which the counter refuses.
     v445 REVERSED this pin. It used to assert growStampsCardLenV416 === 10 — the drawn card was
     stretched to cover the stranded gift — and that is exactly the defect REG-001 reported: the
     stretched number is also what the length field, the steppers and the grid's "+" are built
     from, so the editor offered to write a length the owner never asked for. The stranded gift is
     still surfaced, in the warning band, which is where a validation fault belongs. */
  const g = grid({ stampTarget: 5, gifts: [GIFT('Free Massage Oil', 5), GIFT('Free Lotion', 10)] });
  assert.equal(g.growStampsCardLenV416, 5, 'the card is 5 stamps long, so 5 slots are drawn');
  assert.deepEqual(cells(g.growStampsGridV416), [1, 2, 3, 4, 5]);
  assert.equal(g.growStampsStrandedV416, true);
  assert.match(g.growStampsStrandedNoteV416, /Stamps past 5 cannot be claimed yet/);
  assert.match(g.growStampsStrandedNoteV416, /data-grow-stamps-len-v416="10"/,
    'and it offers the one-tap fix rather than only describing the problem');
  assert.doesNotMatch(g.growStampsGridV416, /is-past-v416/,
    'no cell of the grid can be past the end of the card it draws');
  assert.match(g.growStampsStrandedNoteV416, /grow-stamps-strandedgifts-v445/,
    'the stranded gift is drawn in the warning band instead — as a chip, not as a slot');
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
  /* nestly_v422 split the write out of the stepper's onclick so the typed field could share it.
     There is still exactly ONE writer; both entry points below call it. */
  const writer = statement('const growStampsSetLengthV422=async next=>{',
    "  outerMain.querySelectorAll('[data-grow-stamps-len-v416]')");
  assert.match(writer, /sb\.rpc\('business_set_stamp_card_length_v414',/);
  assert.match(writer, /p_stamps:next/);
  assert.match(writer, /growPointsErrorV326=ownerErrorText\(error\)/,
    'v414 names the gift that is in the way — replacing that message would lose the only detail');
  const handler = statement("outerMain.querySelectorAll('[data-grow-stamps-len-v416]')",
    "  const growPointsAddCancel=");
  assert.match(handler, /growStampsSetLengthV422\(Math\.round\(Number\(button\.dataset\.growStampsLenV416\)/,
    'the steppers reach the server through that one writer');
  assert.equal((appJs.match(/sb\.rpc\('business_set_stamp_card_length_v414'/g) || []).length, 1,
    'exactly one call site — a second copy is a second place the refusal could be handled differently');
});

/* ------------------------------------------------- nestly_v422: the length is a FIELD ---------- */

test('v422 the card length is a typed field, with the steppers kept beside it', () => {
  const g = grid({ stampTarget: 12, gifts: [GIFT('Free Lotion', 10)] });
  assert.match(g.growStampsCardLengthBarV416, /data-grow-stamps-lenfield-v422/,
    'owner photo 2: "do as a field, so can edit number"');
  assert.match(g.growStampsCardLengthBarV416, /type="number"[^>]*min="1"[^>]*max="15"/,
    'the field declares the same 1..15 bound the server enforces (nestly_v463)');
  assert.match(g.growStampsCardLengthBarV416, /value="12"/, 'pre-filled with the length in force');
  assert.match(g.growStampsCardLengthBarV416, /data-grow-stamps-len-v416="11"/, 'the − stepper stays');
  assert.match(g.growStampsCardLengthBarV416, /data-grow-stamps-len-v416="13"/, 'and the + stepper stays');
  assert.doesNotMatch(g.growStampsCardLengthBarV416, /grow-stamps-lenvalue-v416/,
    'the read-only value it replaced is gone for an editor');
});

test('v422 a user who may not edit gets the plain value, never an input', () => {
  const g = grid({ stampTarget: 12, gifts: [GIFT('Free Lotion', 10)], canSetupGrow: false });
  assert.doesNotMatch(g.growStampsCardLengthBarV416, /data-grow-stamps-lenfield-v422/);
  assert.match(g.growStampsCardLengthBarV416, /grow-stamps-lenvalue-v416/);
  assert.match(g.growStampsCardLengthBarV416, /12 stamps/);
});

test('v422 the field is disabled while a length write is in flight', () => {
  assert.match(grid({ stampTarget: 12, busy: true }).growStampsCardLengthBarV416, / disabled/);
  assert.doesNotMatch(grid({ stampTarget: 12, busy: false }).growStampsCardLengthBarV416,
    /data-grow-stamps-lenfield-v422[^>]*disabled/);
});

test('v422 the typed field commits on Enter and blur, never per keystroke', () => {
  const wiring = statement('const growStampsLenFieldV422=outerMain.querySelector',
    '  const growPointsAddCancel=');
  assert.match(wiring, /growStampsLenFieldV422\.onblur=commitV422/);
  assert.match(wiring, /event\.key==='Enter'/);
  assert.doesNotMatch(wiring, /oninput/,
    'a write per digit would send "1" then "4" on the way to 14, and the server would refuse the first');
  /* Out of range, blank, or unchanged: put the real length back rather than send a doomed write. */
  assert.match(wiring, /typed<1\|\|typed>GROW_STAMPS_MAX_LEN_V463\|\|typed===growStampsCardLenV416/);
  assert.match(wiring, /growStampsLenFieldV422\.value=String\(growStampsCardLenV416\)/);
});

test('v422 the customer preview under the editor is gone, and so is its renderer', () => {
  /* Owner photo 2 struck the whole Preview block out corner to corner: "no need this preview".
     The editor grid above it is the same picture and is tappable, so the preview was a read-only
     duplicate. Its builder, its two constants and its gift popup go with it — a dead renderer is
     drift, which is the rule v416 itself recorded one test up. */
  /* Matched against the source with COMMENTS STRIPPED. Two of these names survive inside the v422
     comments that explain their removal, so a plain assertion on the raw file would either fail on
     prose or have to be weakened into something that passes whatever the code says. */
  const code = appJs.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, ' ');
  for (const dead of ['growStampsPreviewV350', 'GROW_STAMPS_PREVIEW_MAX_V410', 'growStampsDrawnV410',
    'growStampsMaxV350', 'data-grow-stamp-gift-v410', 'growStampGiftDoneV410']) {
    assert.ok(!code.includes(dead), `${dead} must not survive as live code`);
  }
  assert.doesNotMatch(appJs, /grow-stamps-preview-card-v350/);
  assert.doesNotMatch(appJs, /Collect stamps and unlock rewards!/);
  assert.doesNotMatch(html, /grow-stamps-preview-card-v350\{/, 'its CSS goes too');
  assert.doesNotMatch(html, /\.grow-stamps-cell-v410\{/);
  /* growStampsRewardAtV410 survives: the EDITOR grid reads it. */
  assert.match(appJs, /const growStampsRewardAtV410=new Map/);
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
