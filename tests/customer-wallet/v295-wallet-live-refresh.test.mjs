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
  /* v333: still immediate on foreground. The read is now awaited so the window re-arms AFTER it
     rather than relying on the render to do it — which is what lets the refresh be silent.
     V370: still a FULL refresh on foreground (this is the counter moment), but the tick allowance
     is no longer reset — see the dedicated test below. */
  assert.match(watcher, /async function onVisibility\(\)\{[\s\S]*?try\{await refresh\(\)\}catch\{\}\n\s*arm\(\);/,
    'coming back to the foreground reads now and re-arms');
});

/* v333 (owner: "keep refreshing by itself — i need it to load seamlessly"). The watcher used to
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
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){', 'async function renderCustomerInAppInbox');
  /* v333: both refresh SILENTLY — no shell rebuild, no scroll jump, and no repaint at all unless
     a server answer actually moved.
     V370: each also hands the watcher its own pulse reader, so a tick costs one read instead of
     the whole pipeline. */
  /* nestly_v498: the refresh closure now carries a force flag — a doorbell ping bypasses the
     v333 fact-signature skip (a stamp-gift redemption moves no balance, so the eight facts can
     be unchanged while the Available list is stale); an idle tick never sets it. */
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,forceV498=>renderCustomerWallet\(null,\{silent:true,forceV498:forceV498===true\}\),\s*customerWalletHomePulseReaderV370\(\)\)/, 'Home');
  assert.match(wallet, /watchCustomerWalletV295\(isWalletCurrent,forceV498=>renderCustomerWallet\(businessSlug,\{silent:true,forceV498:forceV498===true\}\),\s*customerWalletProgrammePulseReaderV370\(businessSlug,/, 'programme detail');
});

/* ---------- V370: poll amplification regressions (Supabase load audit 2026-08-17) ----------
   Each of these pins a specific way the 20-second watcher used to multiply into database work. */
test('V370 a poll tick reads ONE thing and only pays for the full refresh when it moved', () => {
  assert.match(watcher, /const observed=await pulse\(\)/, 'a tick asks the pulse first');
  assert.match(watcher, /if\(observed===customerWalletPulseSignatureV370\)\{arm\(\);return\}/,
    'an unchanged pulse must re-arm WITHOUT calling refresh — this is the whole saving');
  assert.match(watcher, /if\(observed===null\|\|observed===undefined\)\{arm\(\);return\}/,
    'a failed pulse is not "nothing changed" and must not repaint either');
  /* The pulse readers are single-RPC by construction. If either ever grows a second read, the
     tick stops being cheap and this test is the thing that should fail. */
  const home = section('function customerWalletHomePulseReaderV370', 'function watchCustomerWalletV295');
  const programme = section('function customerWalletProgrammePulseReaderV370', 'function customerWalletHomePulseReaderV370');
  assert.equal((home.match(/customerRpc\(|sb\.rpc\(/g) || []).length, 1, 'Home pulse is exactly one read');
  assert.equal((programme.match(/customerRpc\(|sb\.rpc\(/g) || []).length, 2,
    'programme pulse is one read per branch (actionable card, or the summary when that feature is off)');
});

test('V370 the tick allowance is a budget for the page, not for each glance', () => {
  const foreground = watcher.slice(watcher.indexOf('async function onVisibility'));
  assert.doesNotMatch(foreground, /ticks=0/,
    'returning to the foreground must NOT buy a fresh 3-minute polling window — a phone picked up '
    + 'and put down twenty times used to buy twenty of them, which is why the cap was not a cap');
  assert.match(foreground, /try\{await refresh\(\)\}catch\{\}/,
    'but the immediate full re-read on return is preserved');
});

test('V370 the pulse baseline is seeded from data the render already fetched', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){', 'async function renderCustomerInAppInbox');
  assert.match(wallet, /rememberCustomerWalletPulseSignatureV370\(customerWalletProgrammePulseOfV370\(actionableCard,null\)\)/,
    'no extra round trip to establish the baseline');
  /* `as_of` is statement_timestamp() — including it would make every tick look changed. */
  assert.match(wallet, /rememberCustomerWalletPulseV370\(data\?\.cards\?\?null\)/,
    'the envelope carries a moving as_of and must never be part of the signature');
});

test('V370 the global inbox sync no longer rides every silent 20-second poll', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){', 'async function renderCustomerInAppInbox');
  assert.match(wallet, /if\(customerInboxSyncDueV370\(silent\)\)\{[\s\S]{0,200}?customer_sync_in_app_inbox_global/,
    'the sync is gated');
  assert.match(wallet, /return customerRpc\('customer_get_in_app_inbox_global_count'\)/,
    'the COUNT still runs every pass — the bell must stay honest');
  const gate = section('function customerInboxSyncDueV370', 'function customerWalletHomePulseReaderV370');
  assert.match(gate, /if\(!silent\)\{customerInboxSyncedAtV370=now;return true\}/, 'a real render always syncs');
  assert.match(gate, /now-customerInboxSyncedAtV370<CUSTOMER_INBOX_SYNC_MIN_MS_V370/, 'a silent pass is throttled');
});

test('V370 the reward catalogue reuses the business actions this render already fetched', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){', 'async function renderCustomerInAppInbox');
  const rewards = wallet.slice(wallet.indexOf('const loadRewards='), wallet.indexOf('const loadTransactions='));
  assert.match(rewards, /const actionsResult=businessId\?businessActionsResult:await unavailableBusinessId\(\)/,
    'no second customer_get_business_actions_v89 in the same render');
  assert.doesNotMatch(rewards, /customerRpc\('customer_get_business_actions_v89'/);
});

/* v333: the refresh is invisible unless something changed. These four are the whole contract. */
test('a silent refresh never rebuilds the shell, moves focus, re-counts a view or pops a sheet', () => {
  const wallet = section('async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){', 'async function renderCustomerInAppInbox');
  assert.match(wallet, /if\(!silent\)renderCustomerShell\(/, 'the page on screen is the page that stays');
  assert.match(wallet, /if\(!silent\)focusCustomerRoute\(\);/);
  assert.match(wallet, /if\(!silent\)showCustomerPromotionPopupV122\(/);
  assert.match(wallet, /if\(businessId&&!silent\)\{/, 'no re-counted session start or DAU write');
  /* nestly_v498: the skip is bypassed only under a doorbell/counter-moment force — an idle tick
     still pays nothing for an unchanged answer. */
  assert.match(wallet, /customerWalletFactsUnchangedV333\(silent&&!forceV498,/,
    'an unchanged answer paints nothing at all (unless a ping said it changed)');
  const paint = section('function customerWalletSilentPaintV333', 'async function renderCustomerWallet(');
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

/* ---------- nestly_v498: the doorbell that failed silently (owner, 2026-08-25) ----------
   "why record sale does not reflect immediately to customer app?" Production logs told the story:
   the app opened at 01:19:06 into a COLD Realtime tenant, the channel's first join failed with no
   status callback watching, realtime.subscription held no customer row until 01:30:48, and the
   poll budget then ran the page fully quiet. Three rules, pinned: */

test('v498 a refused channel join is retried with bounded backoff, never abandoned silently', () => {
  assert.match(watcher, /\.subscribe\(status=>\{/,
    'subscribe must observe its own outcome — the naked .subscribe() is the shape that failed');
  assert.match(watcher, /if\(status==='SUBSCRIBED'\)\{signalRetriesV498=0;return\}/,
    'a successful join resets the budget so a later drop starts its backoff fresh');
  assert.match(watcher, /if\(signalRetriesV498>=5\|\|signalRetryTimerV498\)return;/,
    'bounded: five attempts, one timer — a genuinely-down tenant is not hammered');
  assert.match(watcher, /1000\*\(2\*\*signalRetriesV498\)/, 'exponential backoff: 2s,4s,8s,16s,32s');
  assert.match(watcher, /if\(signalChannelV479\)\{try\{sb\.removeChannel\(signalChannelV479\)\}catch\{\}signalChannelV479=null\}\s*\r?\n\s*try\{\s*\r?\n?\s*signalChannelV479=sb\.channel/,
    'each attempt rebuilds the channel from scratch — an errored postgres_changes channel does not recover');
  assert.match(watcher, /if\(!signalChannelUpV498\(\)\)\{signalRetriesV498=0;joinSignalChannelV498\(\)\}/,
    'a return to the foreground gives the doorbell its chance back');
});

test('v498 the poll budget applies only while the doorbell is standing', () => {
  assert.match(watcher, /if\(ticks>=CUSTOMER_WALLET_POLL_LIMIT_V295&&signalChannelUpV498\(\)\)return;/,
    'with the channel joined, nine ticks then silence is the right economy; without it, the 20s pulse is the only ear left and must keep going');
  assert.doesNotMatch(watcher, /!alive\(\)\|\|ticks>=CUSTOMER_WALLET_POLL_LIMIT_V295\|\|/,
    'the old combined guard — budget enforced even with the doorbell dead — must be gone');
});

test('v498 a doorbell ping forces the repaint through the fact-signature skip', () => {
  const moment = watcher.slice(watcher.indexOf('const counterMomentV468=async()=>{'));
  assert.match(moment.slice(0, moment.indexOf('};')), /await refresh\(true\)/,
    'a counter moment is a positive statement that something changed — redeeming a stamp gift moves no balance, so the eight summary facts alone would skip the very repaint the ping exists for');
});
