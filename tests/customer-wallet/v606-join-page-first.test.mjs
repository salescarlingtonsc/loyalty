/* nestly_v606 — the scan's first screen is a page, not the app.
 *
 * The owner's requirement: scanning the counter QR must pop the business IMMEDIATELY. The
 * in-app sheet sits behind the whole SPA boot (chunk downloads, session restore, router
 * epochs) and on the owner's own iPhone the business was fetched — gateway 200 in
 * function_edge_logs — yet the sheet never painted. So the QR now lands on /join, a small
 * standalone page: one fetch, one card, "Join <business>?" painted straight into a 25KB
 * document. Yes records a timestamped handoff and only then enters the app, whose signed-out
 * join route consumes the handoff instead of asking the same question again.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const join=readFileSync(new URL('../../app/join.html',import.meta.url),'utf8');
const vercel=JSON.parse(readFileSync(new URL('../../app/vercel.json',import.meta.url),'utf8'));

test('the QR encodes /join?token=…, and /join is a real route',()=>{
  assert.match(app,/publicUrl\(`\/join\?token=\$\{encodeURIComponent\(data\.join_token\)\}`\)/,
    'the printed QR opens the standalone page, not the SPA');
  assert.ok(vercel.rewrites.some(r=>r.source==='/join'&&r.destination==='/join.html'),
    'vercel must rewrite /join to join.html');
});

test('the join page confirms first: name, one Yes, and the counter fallback',()=>{
  assert.match(join,/function renderConfirm\(page,joinToken\)/);
  assert.match(join,/renderConfirm\(data, joinToken\);/,'init lands on the confirm card, not the legacy form');
  assert.match(join,/`Join \$\{esc\(name\)\}\?`/,'the business is named on the card');
  assert.match(join,/id="joinYes"/);
  assert.match(join,/renderForm\(page,joinToken\)/,'the counter form is one tap away, not gone');
});

test('Yes hands off to the app with all three records, then opens the join route',()=>{
  const yes=join.slice(join.indexOf("$('joinYes').onclick"),join.indexOf("$('joinNotNow')"));
  assert.match(yes,/sessionStorage\.setItem\('nestly\.customer\.pendingJoinToken',joinToken\)/);
  assert.match(yes,/'nestly\.customer\.joinConfirmedV596'/,'the signed-in resume must not re-ask');
  assert.match(yes,/'nestly\.customer\.joinHandoffV606'.*at:Date\.now\(\)/,'the handoff is timestamped');
  assert.match(yes,/name:name/,'v609: the handoff carries the display name the funnel shows');
  assert.match(yes,/location\.href='\/app#\/join\?token='\+encodeURIComponent\(joinToken\)/);
});

/* Executed: the handoff consumer's real behaviour, not its spelling. */
const consumerSource=app.slice(
  app.indexOf("const CUSTOMER_JOIN_HANDOFF_KEY_V606"),
  app.indexOf('function customerRecoveryVerified'));
function makeConsumer({record,now=1000000}={}){
  const store=new Map();
  if(record!==undefined)store.set('nestly.customer.joinHandoffV606',JSON.stringify(record));
  const remembered=[];
  const context={
    sessionStorage:{
      getItem:k=>store.has(k)?store.get(k):null,
      removeItem:k=>store.delete(k),
      setItem:(k,v)=>store.set(k,String(v))
    },
    Date:{now:()=>now},
    pendingCustomerJoinSlugV587:'',
    normalizeCustomerBusinessIntent:s=>String(s||'').trim().toLowerCase(),
    rememberCustomerJoinConfirmedV596:(token,slug)=>{remembered.push({token,slug});return {token,slug}}
  };
  vm.runInNewContext(consumerSource,vm.createContext(context));
  return {consume:context.consumeCustomerJoinHandoffV606,store,remembered};
}

test('a fresh handoff for the same token is consumed exactly once',()=>{
  const {consume,store,remembered}=makeConsumer({record:{token:'T'.repeat(24),slug:'jess-salon',at:1000000-5000}});
  assert.equal(consume('T'.repeat(24)),true);
  assert.equal(store.has('nestly.customer.joinHandoffV606'),false,'one-shot: removed on read');
  assert.deepEqual(remembered,[{token:'T'.repeat(24),slug:'jess-salon'}],
    'consuming also records the confirmation for the signed-in resume');
  assert.equal(consume('T'.repeat(24)),false,'a second consult finds nothing');
});

test('the sign-in funnel names the business the scan is about to join (v609)',()=>{
  const shell=app.slice(app.indexOf('function customerRegistrationShell'),app.indexOf('function renderCustomerOtpVerification'));
  assert.match(shell,/pendingCustomerJoinToken\s*\?/,'the strip renders only while a scan is pending');
  assert.match(shell,/Scan received — you will join <b>\$\{esc\(pendingCustomerJoinBusinessNameV609\|\|'this business'\)\}<\/b>/,
    'the scan must stay visible through sign-in, OTP and profile');
});

test('a stale or mismatched handoff never suppresses the question (the v599 lesson)',()=>{
  const stale=makeConsumer({record:{token:'T'.repeat(24),slug:'x',at:1000000-11*60*1000}});
  assert.equal(stale.consume('T'.repeat(24)),false,'older than the freshness window → ask normally');
  const other=makeConsumer({record:{token:'A'.repeat(24),slug:'x',at:1000000-5000}});
  assert.equal(other.consume('B'.repeat(24)),false,'a different token → ask normally');
  const none=makeConsumer({});
  assert.equal(none.consume('T'.repeat(24)),false,'no record → ask normally');
});
