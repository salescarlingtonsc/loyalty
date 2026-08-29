/* nestly_v611 — the in-app scan's close()-then-nav() history race.
 *
 * Named by the owner's real-device funnel trace (cid 903edba1…, build 8dd9585159af,
 * 2026-08-30 00:00 SGT): scanner opened → QR accepted → token saved → '#/join' entered →
 * business preview 200 → "confirm sheet refused: pending token or hash moved during preview"
 * → the customer left silently on My Rewards. The app was on the CURRENT build — not stale.
 *
 * activateDialog pushes a history entry so Android Back can dismiss the sheet; plain close()
 * unwinds it with history.back(), which is ASYNCHRONOUS. accept()'s nav('#/join') landed
 * first and the queued pop then removed it — the navigation happened and was immediately
 * undone. The v363 stamps-exclusivity dialog hit the identical race and established the cure:
 * a dismissal that PROCEEDS hands its history entry over (handOffHistory) instead of popping.
 * Desktop and emulated browsers order the traversal differently, which is why this only ever
 * reproduced on the real phone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const scanner=app.slice(app.indexOf('function openCustomerJoinScanner'),app.indexOf('function sortStaffWorkspaces'));

test('an accepted scan hands the dialog history entry over before navigating',()=>{
  assert.match(scanner,
    /close\(\{restoreFocus:false,handOffHistory:true\}\);[\s\S]{0,400}?if\(location\.hash==='#\/join'\)route\(\);else nav\('#\/join'\);/,
    'proceed = hand off, then navigate — nothing queued can pop #/join back out');
});

test('the scanner close forwards handOffHistory instead of swallowing it',()=>{
  assert.match(scanner,
    /const close=\(\{restoreFocus=true,handOffHistory=false\}=\{\}\)=>[\s\S]{0,200}?dialogCleanup\(\{restoreFocus,handOffHistory\}\)/,
    'the V468 lesson: a close() that swallows options silently reverts every hand-off behind it');
});

test('every other dismissal still unwinds its own history entry',()=>{
  /* ✕, backdrop, Esc and the till-watch all call close() with no handOffHistory — the default
     stays false, so a plain dismissal still pops the entry the dialog pushed. */
  assert.match(scanner,/close\(\{restoreFocus:false\}\);\s*customerTillWatchCelebrateV472/,
    'the till-watch close keeps the default');
  assert.doesNotMatch(scanner,/onclick=close\(\{handOffHistory/,'no dismissal control hands off');
});
