import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v296 (owner, three annotated screenshots):
   "remove this — here got profile already"  → the header avatar menu is gone;
   "put here" over the Messages page          → device notifications live with the inbox;
   "Sign out put here" under Account & privacy → Sign out ends the Profile page. */

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');
const indexHtml = await read('app/index.html');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return appJs.slice(from, to);
}

test('the avatar menu is gone from the app, markup and styles alike', () => {
  assert.doesNotMatch(appJs, /customer-account-menu|customer-avatar|customerPushMenuControl|wireCustomerAccountMenu/);
  assert.doesNotMatch(indexHtml, /customer-account-menu|customer-avatar/);
});

test('the wallet header keeps only the bell — Profile is reached by its own tab', () => {
  const shell = section('function renderCustomerShell', 'function focusCustomerRoute');
  assert.match(shell, /id="customerInboxBellSlot"/);
  assert.doesNotMatch(shell, /href="#\/customer\/profile"/, 'no second door to the Profile tab');
  assert.doesNotMatch(shell, /id="walletSignOut"/);
  assert.match(appJs, /\{key:'profile',href:'#\/customer\/profile'/, 'the tab that replaced it');
});

test('device notifications sit with the inbox they govern', () => {
  const messages = section('async function renderCustomerMessages', '/* V282 consent history');
  assert.match(messages, /id="customerMessagesNotifications"/);
  assert.match(messages, /id="customerPushMessagesControl"[^>]*aria-pressed="false"/);
  assert.match(messages, /messagesPush\.bindButton\(\$\('customerPushMessagesControl'\)/);
  assert.match(messages, /statusHost:\$\('customerMessagesNotifications'\)\?\.querySelector\('\[data-push-status\]'\)/);
  assert.match(messages, /NestlyNativeBridge\.isNative\?'':/,
    'the native shell cannot do web push, so it must not offer the switch');
});

test('Sign out is the last card on Profile, and it really signs out', () => {
  const profile = section('async function renderCustomerProfile', 'async function renderCustomerCommunicationsV263');
  /* nestly_v749 (owner 2026-09-04, App Store 5.1.1(v)): the customer profile now renders the
     customer-only self-service deletion card instead of the business mailto card. The ordering
     invariant is unchanged — Sign out still ends the page, after account & privacy. */
  assert.ok(profile.indexOf('customerAccountDeletionCardHtmlV749()') < profile.indexOf('customerProfileSignOutCard'),
    'it comes after account & privacy — reached by finishing the page');
  assert.match(profile, /\$\('customerProfileSignOut'\)\.onclick=async\(\)=>\{killChannels\(\);await sb\.auth\.signOut\(\);resetClientSessionState\(\);location\.hash='#\/';route\(\)\}/,
    'the same teardown the header button did: channels killed, session state reset');
});

test('the screen with no navigation keeps its only exit, as a plain button', () => {
  const shell = section('function renderCustomerFirstProgrammeQuest(){', 'function renderActionableWalletHome');
  assert.match(shell, /id="walletSignOut" type="button"/);
  assert.doesNotMatch(shell, /customer-account-menu/);
  assert.doesNotMatch(shell, /profilePasskeys/, 'a half-registered customer has no profile to open');
});
