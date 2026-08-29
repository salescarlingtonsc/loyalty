/* nestly_v602 — the scan was never broken; the message was.
 *
 * ROOT CAUSE, reproduced against production with the owner's own account
 * (leechuanseng.biz@gmail.com) and their own live token:
 *   - the gateway returns the business:  {"name":"KKY demo","slug":"kky-demo", ...}  HTTP 200
 *   - the QR row is status=active, unexpired, join_enabled=true
 *   - customer_join_business_from_qr_v89 refuses with
 *       42501 :: an independent active customer identity is required
 * because a Peekaa BUSINESS login has no customer side: both of the owner's auth users have zero
 * rows in customer_identities and zero customer_links.
 *
 * And the client turned that refusal into "This QR is expired, paused, or no longer valid. Ask the
 * business for its current Peekaa QR." — every error that was not a missing-function code landed in
 * that one sentence. So the owner went hunting for a broken QR, pressed Replace (which killed their
 * real printed one, see v597), scanned again, and was told the same thing. Three waves of work went
 * into a QR that was fine the whole time.
 *
 * The lesson this file exists to hold: a catch-all error sentence that NAMES A CAUSE is a liability.
 * It does not merely fail to help — it sends people to fix something that is not broken.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const join=app.slice(app.indexOf('async function renderCustomerQrJoin'),app.indexOf('function businessApplicationCopy'));

test('a missing customer account is recognised, not swept into "the QR is expired"',()=>{
  assert.match(join,/const noCustomerAccountV602=String\(error\.code\|\|''\)==='42501'/);
  assert.match(join,/customer identity is required\|customer session required/,
    'matched on the message too, because a SECURITY DEFINER can surface this under more than one code');
});

test('the message says what is actually true, and clears the QR of blame',()=>{
  assert.match(join,/You are signed in with a business account/);
  assert.match(join,/This QR is fine\./,'the owner must stop hunting a broken QR');
  assert.doesNotMatch(join.slice(join.indexOf('noCustomerAccountV602'),join.indexOf('Back to my workspace')),
    /expired, paused, or no longer valid/,
    'the old sentence must not also render on this branch');
});

test('the scan survives the hand-off, so nothing has to be scanned twice',()=>{
  /* Everything else clears the token on failure. This branch keeps it, because the customer
     sign-up on the other side of the hand-off is what completes the join. */
  assert.match(join,/if\(!noCustomerAccountV602&&error\.code!=='PGRST202'&&error\.code!=='42883'\)rememberPendingCustomerJoinToken\(''\)/);
  assert.match(join,/resetClientSessionState\(\{preserveInvitation:true\}\)/,
    'preserveInvitation is what carries the scanned token past the sign-out');
});

test('the way out is offered, not just described',()=>{
  assert.match(join,/id="customerJoinSwitchV602">Continue as a customer</);
  assert.match(join,/await sb\.auth\.signOut\(\)/);
  assert.match(join,/customerWalletRenderEpoch\+=1/,
    'the epoch is bumped so this screen cannot repaint over the one replacing it');
  assert.match(join,/Back to my workspace/,'and a business owner who only wanted their workspace can leave');
});

test('the other refusals are untouched',()=>{
  assert.match(join,/Something’s not working right now\. Please try again shortly\./,
    'a missing function is still reported as a temporary fault');
  assert.match(join,/This QR is expired, paused, or no longer valid/,
    'and a genuinely dead QR is still named as one');
});
