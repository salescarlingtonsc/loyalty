import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const app = (await read('app/index.html')) + '\n' + (await read('app/app.js'));
const migration = await read('db/migrations/20260807_nestly_v188_no_self_service_account_deletion.sql');

/* --------------------------------------------------- chart legends are a key, not a control */

test('a chart legend cannot hide a slice', () => {
  assert.match(app, /Chart\.defaults\.plugins\.legend\.onClick=\(\)=>\{\}/);
  // the gender doughnut is the one the owner hit: clicking "Male" struck it out and re-proportioned
  assert.match(app, /type:'doughnut'[\s\S]{0,400}plugins:\{legend:\{position:'bottom'\}\}/);
  assert.doesNotMatch(app, /legend:\{[^}]*onClick:\s*\(?\s*event/,
    'no chart may re-introduce a click handler that toggles a dataset');
});

/* ------------------------------------------------------ account closure goes through Peekaa */

test('no surface offers self-service account deletion any more', () => {
  // nestly_v749 (owner directive 2026-09-04, App Store 5.1.1(v)) reverses this v188 ban for
  // CUSTOMER accounts only: Apple requires that an app which lets a person create an account also
  // lets them delete it, in-app, without a support conversation. Business accounts are unaffected
  // — accountDeletionCardHtml() still routes to the mailto closure request below, and
  // openAccountDeletionDialog / the old submit-RPC path never come back for anyone. The typed
  // 'DELETE' confirmation and the 'Delete your Peekaa account' heading now legitimately exist, but
  // ONLY inside the new customer-only dialog function — asserted below rather than banned outright.
  assert.doesNotMatch(app, /function openAccountDeletionDialog/);
  assert.doesNotMatch(app, /Submit deletion request/);
  assert.doesNotMatch(app, /request_account_deletion_v131/,
    'the browser must not call the submit RPC at all');

  const businessCard = app.slice(app.indexOf('function accountDeletionCardHtml'), app.indexOf('function customerAccountDeletionCardHtmlV749'));
  assert.doesNotMatch(businessCard, /Type DELETE/,
    'the business mailto card must not grow a typed self-service confirmation');

  const customerDialog = app.slice(app.indexOf('function openCustomerDeleteAccountDialogV749'), app.indexOf('function accountPrivacyFooterHtmlV593'));
  assert.match(customerDialog, /Delete your Peekaa account/,
    'the customer-only dialog is where this string is allowed to live');
  assert.match(customerDialog, /Type DELETE to confirm/,
    'the customer-only dialog is where this confirmation is allowed to live');
});

test('closing an account is a real action, not a sentence with an address in it', () => {
  const card = app.slice(app.indexOf('function accountDeletionCardHtml'), app.indexOf('async function wireAccountDeletionButton'));
  // v189: the owner found the route "hidden inside here, small button".
  assert.match(card, /<a class="btn" style="width:100%" href="mailto:admin\.peekaa@gmail\.com\?subject=\$\{closureSubject\}&amp;body=\$\{closureBody\}">Request account closure<\/a>/,
    'the primary action must be the closure request itself');
  assert.match(card, /Peekaa account closure request/, 'the mail arrives pre-addressed and pre-titled');
  assert.match(card, /Name:.*Phone or email used:/s, 'the body asks for what Peekaa needs to act');
  assert.match(card, /Ask what data is held/);
  assert.match(card, /speak to your assigned consultant/);
  assert.match(card, /replies within 30 days/);
  assert.match(card, /Legally required financial, fraud-prevention and security records may be retained/);
  /* nestly_v593 (owner: "shift the entire account & privacy module into settings — put it at the
     bottom of the page just a small button (so i dont see account & privacy in the drop down)").
     The v188/v189 invariant is unchanged — closing an account is a real action that goes through
     Peekaa, and it is never a self-service dialog. What moved is the DOOR: out of the account menu
     every staff member opens, into one small button at the foot of Settings that reveals this same
     card. Both halves are asserted, because deleting the row without adding the button would have
     stranded the route entirely. */
  /* The row is gone for an OWNER, who now has the button at the foot of Settings. It is kept for
     everyone else: settingsPage() is owner-only, so deleting it outright would leave a
     receptionist with no in-app route at all — the ⚖️ 5.1.1(v) exposure v131 records. */
  assert.match(app, /\$\{S\.myRole==='owner'\?'':`<a href="\/data-request\.html" id="pmDeleteAccount">/,
    'the account menu row must be owner-suppressed, not deleted');
  assert.match(app, /function accountPrivacyFooterHtmlV593/,
    'Settings must carry the small button that reveals the card');
  assert.match(app, /accountPrivacyPanelV593.*innerHTML=accountDeletionCardHtml\(\)/s,
    'the footer must reveal the SAME card, not a second copy of the copy');
  assert.match(app, /\$\{accountPrivacyFooterHtmlV593\(\)\}<\/div>`;/,
    'the button belongs at the foot of the Settings page, outside the tab panels');
  /* The card still stands on its own on the pre-workspace and locked screens, where there is no
     Settings page to reach it from — the persona chooser is the one place it was REMOVED. */
  assert.match(app, /\$\{accountDeletionCardHtml\(\)\}\$\{legalLinks\(\)\}/,
    'the locked/onboarding screens keep the card inline');
});

test('a request submitted before the change is still visible to the person who made it', () => {
  const status = app.slice(app.indexOf('async function wireAccountDeletionButton'), app.indexOf('function renderPasswordUpdate'));
  assert.match(status, /get_account_deletion_request_v131/);
  assert.match(status, /Closure request received/);
  assert.match(status, /Closure request reviewed/);
  assert.match(status, /if\(error\|\|!host\.isConnected\)return/,
    'a failed status read must say nothing rather than imply no request exists');
  assert.match(status, /if\(!request\?\.status\)return/);
});

test('the database refuses the call, so the missing button is not the only control', () => {
  assert.match(migration, /revoke execute on function public\.request_account_deletion_v131\(text, text\) from authenticated;/);
  assert.doesNotMatch(migration, /drop function/, 'requests taken by email are still recorded server-side');
  assert.doesNotMatch(migration, /^\s*(revoke|grant)[^\n]*get_account_deletion_request_v131/mi,
    'the read path must keep its grant — it is only mentioned in the rationale');
  assert.match(migration, /guideline\s*\n?--\s*5\.1\.1\(v\)|5\.1\.1\(v\)/,
    'the App Store consequence must be written down where the change is');
});
