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
  assert.doesNotMatch(app, /function openAccountDeletionDialog/);
  assert.doesNotMatch(app, /Type DELETE to confirm/);
  assert.doesNotMatch(app, /Submit deletion request/);
  assert.doesNotMatch(app, /request_account_deletion_v131/,
    'the browser must not call the submit RPC at all');
  assert.doesNotMatch(app, /Delete your Peekaa account/);
});

test('the route to close an account is still obvious', () => {
  const card = app.slice(app.indexOf('function accountDeletionCardHtml'), app.indexOf('async function wireAccountDeletionButton'));
  assert.match(card, /mailto:admin\.peekaa@gmail\.com/, 'the same address the Privacy Notice gives');
  assert.match(card, /speak to your assigned consultant/);
  assert.match(card, /replies within 30 days/);
  assert.match(card, /href="\/data-request\.html"/);
  assert.match(card, /Legally required financial, fraud-prevention and security records may be retained/);
  assert.match(app, /<a href="\/data-request\.html" id="pmDeleteAccount">/,
    'the profile menu links to the request page instead of opening a dialog');
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
