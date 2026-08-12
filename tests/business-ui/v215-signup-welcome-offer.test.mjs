/* V215 — welcome offer for first-time sign-ups.
   Owner: "i need to enable new sign ups redeemption (criteria set by boss): - example minimum
   spend $5 (get free xx product) - redeem using qrcode for first time sign ups only. or no
   minimum spend and free xx product."
   Server behaviour is proved by the rolled-back production chains (28/28). These assertions pin
   the client half: that the offer is configurable, that it is surfaced where staff will meet it,
   and — most importantly — that this screen never decides eligibility for itself. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function fn(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  return app.slice(start, app.indexOf('\nfunction ', start + 1));
}

test('V215 owner can configure both shapes the owner asked for', () => {
  const editor = fn('openWelcomeOfferEditorV215');
  // Two claim rules: none, or a minimum spend. Nothing else.
  assert.match(editor, /Straight away — no minimum spend/);
  assert.match(editor, /After they spend a minimum amount/);
  // The free item is chosen from the live catalogue — services AND products, since a business
  // may sell only one of the two.
  assert.match(editor, /from\('services'\)[\s\S]*eq\('active',true\)/);
  assert.match(editor, /from\('products'\)[\s\S]*eq\('active',true\)/);
  assert.match(editor, /business_set_welcome_offer_v215/);
  // Money is parsed strictly; a typo must not silently become a different minimum.
  assert.match(editor, /\^\\d\+\(\?:\\\.\\d\{1,2\}\)\?\$/);
  assert.match(editor, /Expiry must be a whole number of days from 1 to 3650/);
});

test('V215 appears in Programmes with a state an owner can act on', () => {
  const row = fn('welcomeOfferRowV215');
  assert.match(row, /Not set up/);
  assert.match(row, /Paused/);
  // A deactivated free item is called out, because the offer silently stops issuing.
  assert.match(row, /item_available===false/);
  assert.match(row, /no longer on sale/);
  // Uses the shared pill, not an invented status class.
  assert.match(row, /class="pill \$\{esc\(tone\)\}"/);
  assert.match(app, /\[data-welcome-offer-edit-v215\]/);
  /* V291 retarget (not a deletion): the row now also receives whether an editing draft is open,
     so it can say the welcome offer is NOT part of that draft. Same call site, one argument more. */
  assert.match(app, /welcomeOfferRowV215\(welcomeOfferStatusV215,canSetupGrow,canRewards,Boolean\(growDraftPendingId\)\)/);
  // A failed status read must not blank the whole programme overview.
  assert.match(app, /business_get_welcome_offer_v215[\s\S]{0,200}catch\(\(\)=>null\)/);
});

test('V215 till surfaces the offer and follows the server contract for minimum spend', () => {
  // The entitlements payload the till already reads carries the offer.
  assert.match(app, /customerWelcomeOffer:entitlements\.error\?null:\(entitlements\.data\?\.welcome_offer\|\|null\)/);

  // A minimum-spend offer gets NO redeem button in the picker: the server proves the spend
  // against a real recorded sale, which does not exist yet at that point.
  const picker = app.slice(app.indexOf('const welcomeOffer=(!walkin'), app.indexOf('picker=`${welcomeBanner}'));
  assert.match(picker, /Ring the sale up first — the free item is offered on the receipt/);
  assert.match(picker, /welcomeMin\s*\?/);
  const zeroBranch = picker.slice(picker.indexOf('No minimum spend. Nothing is charged.'));
  assert.match(zeroBranch, /id="tWelcomeRedeemV215"/);
  // The button for the minimum-spend case must not be in the picker at all.
  const minBranch = picker.slice(picker.indexOf('${welcomeMin'), picker.indexOf('No minimum spend. Nothing is charged.'));
  assert.doesNotMatch(minBranch, /tWelcomeRedeemV215/);

  // The receipt offers it only when the completed sale actually clears the minimum.
  assert.match(app, /welcomeOfferV215:\(!walkin&&catalog\?\.customerWelcomeOffer&&r&&r\.saleId/);
  assert.match(app, /Number\(r\.total\)>=\(Number\(catalog\.customerWelcomeOffer\.min_spend_cents\)\|\|0\)/);
  assert.match(app, /id="tWelcomeReceiptRedeemV215"/);
});

test('V215 redemption passes the qualifying sale and is safe to double-tap', () => {
  const redeem = fn('redeemWelcomeOfferV215');
  assert.match(redeem, /staff_redeem_welcome_offer_v215/);
  // The sale that proves the spend is passed through, not asserted client-side.
  assert.match(redeem, /p_qualifying_sale:qualifyingSaleId\|\|null/);
  // A stable key per grant + sale, so a second tap replays instead of giving a second item.
  assert.match(redeem, /p_idempotency_key:`v215-\$\{offer\.grant_id\}-\$\{qualifyingSaleId\|\|'no-sale'\}`/);
  assert.match(redeem, /This can only be done once/);
  // An incomplete receipt is an error, never a silent success.
  assert.match(redeem, /data\?\.status!=='completed'/);
  assert.match(app, /redeemWelcomeOfferV215\(d\.welcomeOfferV215\?\.saleId\|\|null\)/);
});
