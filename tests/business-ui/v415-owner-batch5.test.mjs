/* nestly_v415 — the owner's fifth annotated batch.

   PHOTO 1 (Welcome offer). "when clicked no minimum spend i need the minimum spend $50 to
   disappear, if not we will think that need a $50." The field was DISABLED but still on screen
   with 50.00 in it, directly under the option that says there is no minimum.

   PHOTO 2 (Loyalty). The draft banner ringed: "remove the circled area, pressing save would
   publish to live. dont need hide in draft."

   PHOTO 5 (customer Rewards). "fix the alignment issues, not able to scroll fully and words and
   buttons got cut off." Measured at 390px: documentElement.scrollWidth was 803 against a 390
   viewport, because section.customer-programme-card-v310 is a GRID ITEM of
   .customer-programme-stack and a grid item's default min-width is `auto` — it refused to shrink
   below the carousel's 1150px of cards, so the whole page scrolled sideways under a fixed app
   bar. After the fix: 390 at 390, 412 at 412, the track still scrolls to 1141, and the last card
   lands fully inside the viewport (left 95, right 373). */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};

/* ------------------------------------------------- photo 1: the minimum-spend field ---------- */

/* syncMin lifted out and run against a stub DOM, so this asserts what the control DOES rather
   than that a string appears in the file. */
const syncMinHarness = () => new Function('$', 'document', `
  ${statement('const syncMin=()=>{', '\n  };')}
  return syncMin;`);

const stubDom = checkedValue => {
  const wrap = { hidden: null };
  const input = { disabled: null };
  const cards = [];
  return {
    wrap, input, cards,
    $: id => (id === 'welcomeMinWrapV415' ? wrap : id === 'welcomeMinAmountV215' ? input : null),
    document: {
      querySelector: () => ({ value: checkedValue }),
      querySelectorAll: () => cards
    }
  };
};

test('v415 choosing "no minimum spend" HIDES the minimum-spend field, not just greys it', () => {
  const dom = stubDom('none');
  syncMinHarness()(dom.$, dom.document)();
  assert.equal(dom.wrap.hidden, true, 'photo 1: 50.00 stayed on screen under "no minimum spend"');
  assert.equal(dom.input.disabled, true, 'a hidden field must not stay focusable or submittable');
});

test('v415 choosing "after they spend a minimum" brings the field back', () => {
  const dom = stubDom('min');
  syncMinHarness()(dom.$, dom.document)();
  assert.equal(dom.wrap.hidden, false);
  assert.equal(dom.input.disabled, false);
});

test('v415 the field ships hidden when the offer has no minimum saved', () => {
  const markup = statement('<div id="welcomeMinWrapV415"', '</div>');
  assert.match(markup, /\$\{minValue\?'':' hidden'\}/,
    'a saved minimum shows the field; no minimum ships it hidden, before any click');
});

/* ------------------------------------------------- photo 2: Save publishes ------------------- */

test('v415 the draft banner and its "Review & publish" are gone', () => {
  assert.doesNotMatch(appJs, /Draft — not visible to customers\.<\/b>/,
    'the ringed banner must not render any more');
  assert.doesNotMatch(appJs, /id="growDraftBarPublishV170"/,
    'its publish button goes with it — Save publishes now');
});

test('v415 publishOnSaveV415 publishes the draft and reports a refusal in words', async () => {
  const calls = [];
  const build = new Function('sb', 'ownerErrorText', `
    ${statement('const publishOnSaveV415=async versionId=>{', '\n  };')}
    return publishOnSaveV415;`);

  const ok = build({ rpc: async (name, args) => { calls.push([name, args]); return { error: null }; } },
    e => e.message);
  assert.equal(await ok('ver-1'), null, 'a clean publish reports no problem');
  assert.deepEqual(calls[0], ['publish_loyalty_config', { p_version: 'ver-1' }]);

  /* publish_loyalty_config enforces real invariants — "a live stamp card needs a number of
     stamps", "a stamp gift sits past the last stamp on the card". The owner has to be able to
     read which one stopped them. */
  const refused = build({ rpc: async () => ({ error: { message: 'a stamp gift sits past the last stamp on the card' } }) },
    e => e.message);
  assert.equal(await refused('ver-1'), 'a stamp gift sits past the last stamp on the card');

  /* No version, no call: a page with nothing drafted must not fire a publish at the server. */
  calls.length = 0;
  assert.equal(await ok(null), null);
  assert.equal(calls.length, 0);
});

test('v415 every writer on the Loyalty page publishes, and none claims success when refused', () => {
  /* Four, not two: the configuration Save and Save birthday reward were the ones in the photo,
     but saveReward and saveTier live on the same page and had to come with them — once the
     banner was removed, a writer left on drafts would have had no way to publish at all. */
  const publishes = appJs.match(/await publishOnSaveV415\(/g) || [];
  assert.equal(publishes.length, 4, 'configuration, birthday, reward, tier');
  assert.equal((appJs.match(/sb\.rpc\('publish_loyalty_config'/g) || []).length, 5,
    'and they share ONE helper rather than each calling the RPC');
  const refusals = appJs.match(/savedNotLive/g) || [];
  assert.ok(refusals.length >= 5, 'every writer reports a refused publish instead of toasting live');
  assert.doesNotMatch(appJs, /Grow draft saved — customers are still using the published programme/,
    'the old draft-only outcome is gone');
});

test('v415 a dialog closes BEFORE the publish round trip, never after it', () => {
  /* V236's rule, which converting these writers briefly broke: an await between a successful save
     and the close lets a re-render land while the dialog is still mounted and orphan the node the
     owner is looking at. Publishing is a second round trip, so it must come after the close. */
  const rewardSave = statement('async function saveReward(', '\n  }\n');
  assert.ok(rewardSave.indexOf('closeRewardDialogV238(false)')
    < rewardSave.indexOf('await publishOnSaveV415('), 'reward dialog closes first');
  const tierSave = statement('async function saveTier(', '\n  }\n');
  assert.ok(tierSave.indexOf('closeTierDialogV236(false)')
    < tierSave.indexOf('await publishOnSaveV415('), 'tier dialog closes first');
  /* And a refused publish still returns the owner to the catalogue rather than stranding them. */
  assert.match(rewardSave, /return spendRewardIntentV293\(\);/);
});

/* ------------------------------------------------- photo 5: the page stopped scrolling ------- */

test('v415 the programme stack gives its cards a zero floor, so the carousel cannot widen the page', () => {
  /* The measured cause. A grid item defaults to min-width:auto and will not shrink below its
     content's minimum; the content here is a 1150px carousel. */
  assert.match(html, /\.customer-programme-stack>\*\{min-width:0\}/);
  assert.match(html, /\.customer-programme-rewards\{min-width:0\}/);
  assert.match(html, /\.wallet-rewards\.customer-rewards-carousel-v337\{[^}]*min-width:0/);
});

test('v415/v417 the rewards region never scrolls sideways at all any more', () => {
  /* nestly_v417 (owner, photo 8: "i don't want this page to scrollable to left like this, i want
     list format"). v415 stopped this track dragging the WHOLE PAGE sideways; the owner's answer is
     that it should not be a horizontal track in the first place. So the assertions that pinned the
     swipe are replaced by the ones that pin its absence — and v415's own floor stays, because a
     grid item still needs it. */
  const rule = html.slice(html.indexOf('.wallet-rewards.customer-rewards-carousel-v337{'));
  const decl = rule.slice(0, rule.indexOf('}'));
  assert.match(decl, /display:grid/, 'rewards stack; every one is visible without swiping');
  assert.match(decl, /min-width:0/, 'v415: it is a grid item and must still be allowed to shrink');
  assert.doesNotMatch(decl, /overflow-x:auto/);
  assert.doesNotMatch(decl, /scroll-snap-type/);
  /* Each row carries its own claim button — "show QR code to redeem", drawn on every row. */
  assert.match(html, /\.customer-rewards-carousel-v337 \.wallet-reward-actions \.btn\{[^}]*min-height:44px/);
});
