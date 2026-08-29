/* nestly_v604 — the silent scan: gateway 200, blank screen.
 *
 * The owner scanned a live QR and "nothing popped up" — while function_edge_logs recorded
 * GET public-join?token=… returning 200 WITH the business, three times in 25 seconds. The
 * sheet's own guard was the killer: `if(!isCurrent())return false` after the preview fetch.
 * On a real phone another render routinely starts during that fetch (session-restore re-route,
 * a wallet watcher repaint), so the epoch was stale, the fetched sheet was discarded unshown,
 * and the router's ask-once flag — latched BEFORE the fetch — then suppressed every retry on
 * the same visit. A clean desktop profile never races, which is why every wave of fixes
 * "worked here" and failed on the owner's phone.
 *
 * The sheet is a body-level modal that outlives page repaints by construction. What genuinely
 * invalidates it is the scan being abandoned (token cleared/replaced) or navigation off
 * '#/join' — so that is what it tests now. And both callers record the Yes BEFORE their own
 * staleness bail, so an answer can never die with a stale route invocation again.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

const confirmSheet=app.slice(
  app.indexOf('async function confirmCustomerJoinV571'),
  app.indexOf('function customerReferralReasonTextV571'));

test('the sheet survives a competing repaint: its guard is the scan, not the render epoch',()=>{
  assert.match(confirmSheet,
    /if\(pendingCustomerJoinToken!==token\|\|location\.hash!=='#\/join'\)return false;/,
    'validity = same token still pending AND still on the join route');
  const afterFetch=confirmSheet.slice(confirmSheet.indexOf('publicGateway'));
  /* Anchored to a code line (the v604 note above it quotes the old statement in prose). */
  assert.doesNotMatch(afterFetch,/^\s*if\(!isCurrent\(\)\)return false;/m,
    'the epoch bail after the preview fetch is the exact line that ate the owner’s scan');
});

test('signed-out flow: the Yes is recorded before the staleness bail',()=>{
  const branch=app.slice(app.indexOf('consumeCustomerJoinHandoffV606(pendingCustomerJoinToken)'),app.indexOf('nestly_v588'));
  const record=branch.indexOf('rememberCustomerJoinConfirmedV596(pendingCustomerJoinToken');
  const bail=branch.indexOf('if(!isRouteCurrent())return;');
  assert.ok(record>=0&&bail>=0&&record<bail,
    'record first: a stale invocation must not lose an answer the person actually gave');
});

test('signed-in flow: a Yes on a stale invocation re-enters the route instead of dying',()=>{
  const joinRender=app.slice(
    app.indexOf('async function renderCustomerQrJoin'),
    app.indexOf('async function renderCustomerClaim'));
  const record=joinRender.indexOf('rememberCustomerJoinConfirmedV596(token');
  const stale=joinRender.indexOf('if(!isCurrent()){',record);
  assert.ok(record>=0&&stale>record,'record first, then handle staleness');
  assert.match(joinRender.slice(stale,stale+120),/if\(location\.hash==='#\/join'\)route\(\);/,
    'the fresh invocation finds customerJoinAlreadyConfirmedV596 and joins without re-asking');
});

test('the ask-once flag still prevents a second sheet stacking on the first',()=>{
  /* v606 added the /join-page handoff consult to the same condition; the ask-once latch itself
     is unchanged and still guards the sheet. */
  assert.match(app,/if\(pendingCustomerJoinToken&&!customerJoinAskedThisVisitV599\s*&&!consumeCustomerJoinHandoffV606\(pendingCustomerJoinToken\)\)\{\s*customerJoinAskedThisVisitV599=true;/,
    'one ask per visit, re-armed on every fresh scan (v599), skipped when /join already asked (v606)');
});
