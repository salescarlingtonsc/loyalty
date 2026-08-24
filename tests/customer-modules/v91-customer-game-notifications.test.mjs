import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('v91 preserves consent-aware visit-triggered inbox facts with truthful urgent windows',async()=>{
  const sql=await read('supabase/migrations/20260727163752_nestly_v91_customer_game_notifications.sql');
  assert.match(sql,/create or replace function app\.c46_customer_safe_inbox_candidates/);
  assert.match(sql,/interval '3 days'/);
  assert.match(sql,/interval '1 day'/);
  assert.match(sql,/Points expire tomorrow/);
  assert.match(sql,/Points expire within 3 days/);
  assert.match(sql,/'window'.*'one_day'.*'three_days'/s);
  assert.match(sql,/business_get_customer_join_qr_status_v91/);
  assert.doesNotMatch(sql,/push_token|service_worker|vapid|firebase/i,
    'v91 must not pretend an external push provider exists before owner configuration');
});

test('reward feedback is driven only by a new confirmed earn event and uses its actual unit',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app,/function customerConfirmedEarnFeedback/);
  assert.match(app,/item\?\.event_type==='earn'&&Number\(item\?\.points_delta\|\|0\)>0/);
  assert.match(app,/safeUnit=unit==='stamps'\?'stamps':'points'/);
  assert.match(app,/toast\('\+'\+increase\+' '\+safeUnit\+' earned!'\)/);
  assert.doesNotMatch(app,/points added — quest progress updated/);
  assert.match(app,/prefers-reduced-motion: reduce/);
  assert.match(app,/AudioContext/);
  assert.match(app,/navigator\?\.vibrate/);
  assert.match(app,/function customerSuccessCue/);
  assert.match(app,/customer-redemption-complete/);
  assert.match(app,/customer-game-card/);
});

test('owner QR first-use creation is one atomic locked ensure operation',async()=>{
  const [app,sql]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('supabase/migrations/20260727163752_nestly_v91_customer_game_notifications.sql')
  ]);
  assert.match(app,/business_ensure_customer_join_qr_v91/);
  assert.doesNotMatch(app,/active_count\|\|0\)===0[\s\S]{0,220}generateJoinQr/,
    'the browser must never status-check then rotate as two operations');
  const ensure=sql.match(/create or replace function public\.business_ensure_customer_join_qr_v91[\s\S]*?revoke all on function public\.business_ensure_customer_join_qr_v91/)?.[0]||'';
  assert.match(ensure,/app\.is_salon_owner\(p_business\) or app\.is_super_admin\(\)/);
  assert.match(ensure,/pg_advisory_xact_lock[\s\S]*status='active'[\s\S]*if found then[\s\S]*'created',false[\s\S]*business_create_customer_join_qr_v89/,
    'the shared lock and active check must precede creation');
  assert.doesNotMatch(ensure,/business_revoke_customer_join_qrs_v90/,
    'ensuring an active QR must never revoke a concurrent or printed QR');
});

test('scanner releases its dialog trap and restores focus unless route navigation owns focus',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app,/dialogCleanup=CUI\.activateDialog/);
  assert.match(app,/dialogCleanup\(\{restoreFocus\}\)/);
  assert.match(app,/close\(\{restoreFocus:false\}\);[\s\S]{0,300}?if\(location\.hash==='#\/join'\)route\(\);else nav\('#\/join'\);/);
  assert.match(app,/activeCustomerJoinScannerCleanup\(\{restoreFocus:false\}\)/);
});

/* ==============================================================================================
 * nestly_v499 — the confirmation a customer sees for a transaction they just took part in
 *
 * Owner, 2026-08-25: "i still do not see the pop up for successful transaction". The banner was
 * built (V468-E2b) and it worked — but only for a page that was ALREADY OPEN when the sale was
 * rung up. Seed-then-fire records the first read of a session and stays silent, and it could not
 * tell an earn from last Tuesday apart from one ten seconds old. So the ordinary case — pay at
 * the counter, then open the app — showed nothing at all.
 *
 * These EXECUTE the shipped functions. A source grep would have stayed green through the whole
 * defect: every line it would have matched was present and correct.
 * ============================================================================================ */

const appSrcV499 = await read('app/app.js');
const blockV499 = (start, end) => {
  const i = appSrcV499.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = appSrcV499.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return appSrcV499.slice(i, j + end.length);
};
const celebrationSrcV499 = [
  blockV499('const CUSTOMER_CELEBRATION_FRESH_MS_V499=', '\n}'),
  blockV499('function customerCelebrationNewV468(', '\n}'),
  blockV499('function customerConfirmedEarnFeedback(', '\n}')
].join('\n');

function celebrationHarnessV499() {
  const store = {};
  const fired = [];
  const scope = {
    S: { user: { id: 'u1' } },
    sessionStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
    customerPointTotalV103: v => String(v),
    customerUnitNounV429: (unit, n) => (unit === 'stamps' ? (n === 1 ? 'stamp' : 'stamps') : 'points'),
    customerCelebrateV468: o => { fired.push(String(o.headline)); return true; },
    toast: () => { fired.push('toast'); },
    customerSuccessCue: () => {}
  };
  const names = Object.keys(scope);
  const api = new Function(...names,
    `${celebrationSrcV499}\nreturn {earn:customerConfirmedEarnFeedback,gate:customerCelebrationNewV468};`
  )(...names.map(n => scope[n]));
  return { ...api, fired, reset: () => { for (const k of Object.keys(store)) delete store[k]; fired.length = 0; } };
}

const agoV499 = ms => new Date(Date.now() - ms).toISOString();
const earnV499 = (at, delta = 2) => ({ event_type: 'earn', points_delta: delta, event_at: at });

test('v499 a sale rung up while the page is open still confirms itself (unchanged)', () => {
  const h = celebrationHarnessV499();
  h.earn('biz', [earnV499(agoV499(600_000))], 'stamps');   // session opens on older history
  assert.deepEqual(h.fired, [], 'opening on history must stay silent');
  h.earn('biz', [earnV499(agoV499(5_000)), earnV499(agoV499(600_000))], 'stamps');
  assert.deepEqual(h.fired, ['+2 stamps'], 'the earn that just landed is announced');
});

test('v499 opening the app AFTER the sale confirms it — the case the owner photographed', () => {
  const h = celebrationHarnessV499();
  /* No prior session: the customer paid at the counter and then opened their app. Before v499
     this recorded the earn as "history" and said nothing. */
  h.earn('biz', [earnV499(agoV499(20_000)), earnV499(agoV499(600_000))], 'stamps');
  assert.deepEqual(h.fired, ['+2 stamps'],
    'a first-of-session read must speak for a transaction that just happened');
});

test('v499 a cold open on genuinely old history still says nothing, and never repeats', () => {
  const h = celebrationHarnessV499();
  h.earn('biz', [earnV499(agoV499(2 * 24 * 60 * 60 * 1000))], 'stamps');
  assert.deepEqual(h.fired, [], 'a plain reload must not re-celebrate last week');
  h.earn('biz', [earnV499(agoV499(2 * 24 * 60 * 60 * 1000))], 'stamps');
  assert.deepEqual(h.fired, [], 'and an idle poll re-reading the same answer stays quiet');
});

test('v499 the freshness window is absolute, so a phone running fast still knows its own sale', () => {
  const h = celebrationHarnessV499();
  h.earn('biz', [earnV499(new Date(Date.now() + 30_000).toISOString())], 'stamps');
  assert.deepEqual(h.fired, ['+2 stamps'],
    'a server timestamp slightly AHEAD of the device clock is still this customer\'s transaction');
});

test('v499 the redemption gate takes the same rule, and callers passing no time are unchanged', () => {
  const h = celebrationHarnessV499();
  assert.equal(h.gate('redeemed', 'biz', 'fp-1', agoV499(20_000)), true,
    'a reward handed over at the counter confirms itself when the app is opened after');
  const h2 = celebrationHarnessV499();
  assert.equal(h2.gate('redeemed', 'biz', 'fp-1', agoV499(2 * 24 * 60 * 60 * 1000)), false,
    'an old redemption on a cold open stays silent');
  const h3 = celebrationHarnessV499();
  assert.equal(h3.gate('redeemed', 'biz', 'fp-1'), false,
    'no timestamp = the original seed-then-fire behaviour, exactly');
  assert.equal(h3.gate('redeemed', 'biz', 'fp-2'), true, 'and the second, changed answer fires');
  assert.equal(h3.gate('redeemed', 'biz', 'fp-2'), false, 'while the same answer never repeats');
});
