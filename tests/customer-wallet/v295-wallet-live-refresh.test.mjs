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
  /* v319: still immediate on foreground. The read is now awaited so the window re-arms AFTER it
     rather than relying on the render to do it — which is what lets the refresh be silent. */
  assert.match(watcher, /ticks=0;[\s\S]{0,220}?try\{await refresh\(\)\}catch\{\}\n\s*arm\(\);/,
    'coming back to the foreground reads now and re-arms');
});

/* v319 (owner: "keep refreshing by itself — i need it to load seamlessly"). The watcher used to
   depend on its refresh rebuilding the whole page, because only a fresh render armed the next
   tick. Refreshes are silent now, so the watcher has to own its own schedule. */
test('the watcher re-arms itself rather than relying on a full re-render', () => {
  assert.match(watcher, /ticks\+=1;[\s\S]*?try\{await refresh\(\)\}catch\{\}\n\s*arm\(\);/);
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
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false}={}){', 'async function renderCustomerInAppInbox');
  /* v319: both refresh SILENTLY — no shell rebuild, no scroll jump, and no repaint at all unless
     a server answer actually moved. */
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,\(\)=>renderCustomerWallet\(null,\{silent:true\}\)\)/, 'Home');
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,\(\)=>renderCustomerWallet\(businessSlug,\{silent:true\}\)\)/, 'programme detail');
});

/* v319: the refresh is invisible unless something changed. These four are the whole contract. */
test('a silent refresh never rebuilds the shell, moves focus, re-counts a view or pops a sheet', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false}={}){', 'async function renderCustomerInAppInbox');
  assert.match(wallet, /if\(!silent\)renderCustomerShell\(/, 'the page on screen is the page that stays');
  assert.match(wallet, /if\(!silent\)focusCustomerRoute\(\);/);
  assert.match(wallet, /if\(!silent\)showCustomerPromotionPopupV122\(/);
  assert.match(wallet, /if\(businessId&&!silent\)\{/, 'no re-counted session start or DAU write');
  assert.match(wallet, /customerWalletFactsUnchangedV319\(silent,/,
    'an unchanged answer paints nothing at all');
  const paint = section('function customerWalletSilentPaintV319', 'async function renderCustomerWallet(');
  assert.match(paint, /scroller\.scrollTop=scrollTop/, 'a real update holds the scroll position');
  assert.match(paint, /host\.contains\(focused\)\)return false/,
    'and stands down entirely while the customer is interacting');
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
