import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v295: the counter moment — a balance earned while the customer is holding the phone must
   appear without them hunting for it. Deliberately a bounded refresh, NOT a realtime socket:
   customers hold no SELECT policy on points_ledger/credit_ledger (staff-only), so
   postgres_changes would deliver nothing, and widening that policy for an animation would
   trade the most sensitive table in the system. */

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return appJs.slice(from, to);
}

const watcher = section('function watchCustomerWalletV295', 'async function renderCustomerWallet');

test('the wallet re-reads the moment the customer returns to the app', () => {
  assert.match(watcher, /document\.addEventListener\('visibilitychange',onVisibility\)/);
  assert.match(watcher, /ticks=0;refresh\(\);/, 'coming back to the foreground reads now and re-arms');
});

test('the poll is bounded, pauses when hidden, and cannot outlive its page', () => {
  assert.match(watcher, /CUSTOMER_WALLET_POLL_LIMIT_V295/, 'a wallet nobody watches stops polling');
  assert.match(appJs, /const CUSTOMER_WALLET_POLL_MS_V295=20000;/);
  assert.match(watcher, /document\.visibilityState!=='visible'\)return/, 'hidden tabs never poll');
  assert.match(watcher, /const alive=\(\)=>!stopped&&isCurrent\(\)&&!!\$\('walletBody'\)\?\.isConnected/,
    'epoch AND DOM guarded — a stale page can never repaint over a newer one');
});

test('it is torn down by the router, like every other customer overlay', () => {
  assert.match(appJs, /let activeCustomerWalletLiveCleanupV295=\(\)=>\{\};/);
  const dispose = section('function disposeCurrentRoute', '/* realtime notifications');
  assert.match(dispose, /activeCustomerWalletLiveCleanupV295\(\)/);
  assert.match(watcher, /activeCustomerWalletLiveCleanupV295\(\);/, 'starting one stops the previous');
});

test('both wallet surfaces are watched', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null){', 'async function renderCustomerInAppInbox');
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,\(\)=>renderCustomerWallet\(\)\)/, 'Home');
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,\(\)=>renderCustomerWallet\(businessSlug\)\)/, 'programme detail');
});

test('no customer-side realtime subscription on the ledgers was introduced', () => {
  assert.doesNotMatch(appJs, /postgres_changes[^\n]*points_ledger/);
  assert.doesNotMatch(appJs, /postgres_changes[^\n]*credit_ledger/);
});

test('the native app tells the truth about notifications instead of hiding them', () => {
  assert.match(appJs, /customerDeviceNotificationsNative/);
  assert.match(appJs, /Alerts on your lock screen are not switched on for this app yet/);
  assert.match(appJs, /id="customerDeviceNotificationsNative"[\s\S]{0,600}?href="#\/customer\/messages"/,
    'and points at the inbox that does work');
});
