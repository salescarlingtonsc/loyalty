import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const appJs = await readFile(new URL('app/app.js', root), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

/* ---------------------------------------- 1 · the inbox badge must not gate Home's first paint */

const wallet = section('async function renderCustomerWallet', 'function renderCustomerNotificationPreferences');

test('the global inbox sync carries the v177 abort deadline like every other customer read', () => {
  assert.doesNotMatch(wallet, /sb\.rpc\('customer_sync_in_app_inbox_global'/,
    'the inbox sync must not bypass customerRpc — a raw sb.rpc has no abortSignal and can hang Home forever');
  assert.doesNotMatch(wallet, /sb\.rpc\('customer_get_in_app_inbox_global_count'/);
  assert.match(wallet, /customerRpc\('customer_sync_in_app_inbox_global',\{p_idempotency_key:crypto\.randomUUID\(\)\}\)/);
  assert.match(wallet, /return customerRpc\('customer_get_in_app_inbox_global_count'\)/);
});

test('Home paints from the wallet reads and hydrates the bell afterwards', () => {
  const blocking = wallet.slice(wallet.indexOf('const [legacyResult'), wallet.indexOf('customerHomeOverview={'));
  assert.doesNotMatch(blocking, /messagePromise/,
    'messagePromise must not sit inside the Promise.all that gates renderActionableWalletHome');
  assert.match(wallet, /customerRpc\('customer_get_wallet'\)/);
  assert.match(wallet, /messageCount:null/, 'first paint claims no count, it does not guess one');
  const hydrateAt = wallet.indexOf('messagePromise.then(');
  const renderAt = wallet.indexOf('renderActionableWalletHome(data,{');
  assert.ok(renderAt >= 0 && hydrateAt > renderAt, 'the badge must hydrate after the render, not before it');
  const hydrate = wallet.slice(hydrateAt, hydrateAt + 500);
  assert.match(hydrate, /if\(!isWalletCurrent\(\)\)return/,
    'the late badge write must keep the epoch guard so a stale render cannot repaint a newer surface');
  assert.match(hydrate, /paintCustomerInboxBellV286\(/);
  assert.match(wallet, /\}\)\(\)\.catch\(error=>\(\{data:null,error\}\)\)/,
    'a rejected sync must resolve into the {data,error} shape, never an unhandled rejection');
});

/* ------------------------------------- 2 · the expiring pill counts the real total, not the slice */

const expiring = section('function customerExpiringRewardsMarkupV195', 'function customerHomeOffersMarkupV167');

const renderExpiring = new Function('esc', 'ct', 'CUI', 'customerPointTotalV103', 'walletDate', `
  ${expiring}
  return customerExpiringRewardsMarkupV195;`)(
  (value) => String(value ?? ''), () => 'Local business', { icon: () => '' },
  (value) => String(value), (value) => `on ${String(value).slice(0, 10)}`);

const expiringCard = (name, day) => ({
  business: { name }, loyalty: { unit: 'points' },
  expiry: { expiring_units: 100, expiring_within_7_days: 0, next_expiry_at: `2026-09-0${day}T00:00:00+08:00` }
});

test('seven expiring balances are counted as seven, not as the four that fit', () => {
  const html = renderExpiring([1, 2, 3, 4, 5, 6, 7].map((n) => expiringCard(`Biz ${n}`, n)));
  assert.match(html, /7 to use/, 'the pill must report every expiring balance the customer holds');
  assert.doesNotMatch(html, /4 to use/);
  assert.match(html, /See all 7/, 'the balances that fall off the slice need a way through');
  assert.match(html, /Biz 1/);
  assert.doesNotMatch(html, /Biz 5/, 'display stays capped at four rows');
});

test('a short list keeps its exact count and offers no see-all', () => {
  const html = renderExpiring([expiringCard('Cubbly', 1), expiringCard('Kopi Tiam', 2)]);
  assert.match(html, /2 to use/);
  assert.doesNotMatch(html, /See all/);
});

/* ------------------------------------------- 3 · an all-empty Home still offers one next action */

const home = section('function renderActionableWalletHome', 'async function renderCustomerWallet');

test('Home falls through to the scan action instead of stacking two negatives', () => {
  assert.match(home, /const homeEmpty=isHome&&!homeGuidance&&offersState\.status==='ready'/,
    'the empty state may only be claimed once offers actually resolved — never while loading or on error');
  assert.match(home, /!customerExpiringRowsV286\(cards\)\.length/,
    'an expiring balance is itself an action, so it must suppress the fallback');
  assert.match(home, /\$\{homeGuidance\}\$\{homeEmpty\?customerHomeEmptyActionV286\(\):''\}/);
});

test('the empty action reuses the existing scan copy keys and scan wiring', () => {
  const empty = section('function customerHomeEmptyActionV286', 'function renderActionableWalletHome');
  for (const key of ['scanLoyaltyQr', 'firstQuestBody', 'scanBusinessQr', 'qrOnlyHelp'])
    assert.match(empty, new RegExp(`ct\\('${key}'\\)`), `the empty action must reuse the existing ${key} copy key`);
  assert.match(empty, /id="customerHomeScan"/,
    'the button must carry the id renderActionableWalletHome already binds to openCustomerJoinScanner');
  assert.match(home, /if\(\$\('customerHomeScan'\)\)\$\('customerHomeScan'\)\.onclick=openCustomerJoinScanner/);
});
