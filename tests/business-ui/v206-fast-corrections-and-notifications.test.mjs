import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const css = readFileSync(resolve(root, 'app/index.html'), 'utf8');

/* ------------------------------------------------ 1. Add item: fast, and it can go backwards */

/* Owner: "dont need reason when add item — this is for over sold or ad hoc purchase that need
   fast transactions (like negative transaction = minus points away, or positive transactions
   maybe due to under charge)". */
test('an amount may be negative, and only zero is refused', () => {
  assert.match(app, /if\(!\/\^-\?\\d\+\(\?:\\\.\\d\{1,2\}\)\?\$\/\.test\(raw\)\)/,
    'the minus sign must be accepted by the input pattern');
  assert.match(app, /if\(!c\|\|Math\.abs\(c\)>2147483647\)/,
    'zero is meaningless; the size limit applies in both directions');
  assert.match(app, /for example 12\.50 or -5\.00/);
});

test('the note is optional and the screen says what a minus does', () => {
  assert.match(app, /<label for="tCustomReason">Note \(optional\)<\/label>/);
  assert.match(app, /if\(reason\.length>200\)/);
  // scoped to the till's custom-line modal: Program Studio and stored value still REQUIRE a
  // reason, and should — those are rare, high-stakes actions, not a queue-clearing correction
  const modal = app.slice(app.indexOf('function openCustomModal'), app.indexOf('function addPlanLine'));
  assert.doesNotMatch(modal, /reason\.length<3/);
  assert.match(app, /studioEmgErr[\s\S]{0,120}Write a short reason/,
    'the emergency-stop reason must stay mandatory');
  assert.match(app, /takes \$5 off and reduces the points earned to match/);
});

/* ---------------------------------------------------------------- 2. reversal, where it happens */

/* Owner: "allow firms to reverse the transactions if needed to easily at ease". Reversal already
   existed on every sales row; it was filed under Reports. */
test('the sales list says what you go there to do', () => {
  assert.match(app, /sales:\['sales','Sales & refunds'\]/);
});

/* I moved this page next to Record sale first, reasoning that you go looking for a sale in
   order to CORRECT it. V150 caught it: "operational actions separate from money history" is a
   decision that was made deliberately, and a sales list is money history. Reverted. The label
   carries the discoverability fix on its own, and moving the page stays the owner's call. */
test('the deliberate separation between doing and reviewing is intact', () => {
  assert.match(app, /label:'Serve & sell',items:\['till','appointments','bookings','waitlist'\]/);
  /* V272 owner instruction ("delete this tab cause here have already"): Staff performance left
     this group; the doing-vs-reviewing separation this test guards is unchanged. */
  assert.match(app, /label:'Reports',items:\['dailyreport','sales','expenses','pnl','reports','customerintel'\]/);
  const groups = app.match(/const NAVGROUPS=\[[\s\S]*?\n\];/)[0];
  assert.equal((groups.match(/'sales'/g) || []).length, 1, 'one entry, never duplicated');
});

/* -------------------------------------------------- 3. a notification opens its own record */

/* Owner: "clicking in the specific notification should brings me to the specific page to approve
   or reject or call customer (call button)". */
test('the notification carries the record it is about', () => {
  assert.match(app, /data-refid="\$\{esc\(it\.ref_id\|\|''\)\}"/);
  assert.match(app, /pendingNotificationFocusV206=el\.dataset\.refid\|\|'';/);
});

test('the page lands on that row and puts focus on its first action', () => {
  assert.match(app, /function focusNotifiedBookingV206\(list\)/);
  assert.match(app, /\[data-booking-row="\$\{CSS\.escape\(id\)\}"\]/);
  assert.match(app, /const action=row\.querySelector\('\.booking-decision,a\[href\^="tel:"\]'\)/);
  // consumed once: a stale id would highlight an unrelated row next visit
  assert.match(app, /pendingNotificationFocusV206='';\n  if\(!id\|\|!list\)return;/);
  assert.match(css, /\.is-notified-v206>td\{background:var\(--tint\)/);
});

test('a customer with a phone can be called from the request', () => {
  assert.match(app, /href="tel:\$\{esc\(String\(b\.phone\)\.replace\(\/\[\^\\d\+\]\/g,''\)\)\}"/);
  /* the label goes through the v97 template registry rather than a raw interpolation, so it
     exists in all three locales — the workspace a11y inventory rejects an unclassified one, and
     it was right to: a hard-coded English aria-label is invisible to a Malay screen reader. */
  assert.match(app, /workspaceTemplateAttributeV97\('aria-label','callBookingCustomer',\{customer:b\.name\|\|'this customer',phone:b\.phone\}\)/);
  assert.match(app, /callBookingCustomer:Object\.freeze\(\{en:'Call \{customer\} on \{phone\}','zh-CN':[^,]+,ms:/);
  // an email-only request must not render a dead tel: link
  assert.match(app, /: esc\(b\.email\|\|'—'\)\}<\/td>/);
});
