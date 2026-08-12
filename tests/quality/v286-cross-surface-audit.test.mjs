/* V286 cross-surface audit fixes: the signed-out customer entry point, the two hand-rolled
   reward/tier dialogs, the router's error and unknown-page answers, the per-session nav badge
   cache, and the busy state on the customer entry's most important tap. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const app = await readFile(new URL('app/app.js', root), 'utf8');

const between = (start, end) => {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing: ${end}`);
  return app.slice(from, to);
};

test('a signed-out deep link to Communications lands on the customer entry, destination kept', () => {
  const set = between('const CUSTOMER_DIRECT_DESTINATIONS=new Set([', ']);');
  for (const route of ['#/wallet', '#/customer/programmes', '#/customer/bookings',
    '#/customer/messages', '#/customer/profile', '#/customer/communications']) {
    assert.ok(set.includes(`'${route}'`), `${route} must be a remembered customer destination`);
  }
  // every live customer route in the router is covered, so no other one can fall to renderAuth
  const router = between("if(h==='#/customer/programmes')", "if(h==='#/wallet'||");
  for (const match of router.matchAll(/h==='(#\/customer\/[a-z]+)'/g)) {
    if (match[1] === '#/customer/explore') continue; // CUSTOMER_EXPLORE_LIVE_V248===false, unlinked
    assert.ok(set.includes(`'${match[1]}'`), `${match[1]} is routable but not a remembered destination`);
  }
  assert.match(app, /const CUSTOMER_EXPLORE_LIVE_V248=false;/);
  // and the router still remembers before handing over to the customer sign-in
  const guard = between('const directCustomerDestination=normalizeCustomerDestination(h);', 'if(!S.user&&h===\'#/join\')');
  assert.match(guard, /rememberPendingCustomerDestination\(directCustomerDestination\)/);
  assert.match(guard, /return renderCustomerRegistration\(isRouteCurrent\)/);
});

test('the reward dialog uses the shared dialog helper for focus, Escape and Back', () => {
  const open = between('function openRewardDialogV238', 'function closeRewardDialogV238');
  assert.match(open, /rewardDialogDeactivateV238=CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#rwCustomerName'\}\)/);
  assert.doesNotMatch(open, /dialog\.onkeydown/, 'Escape belongs to activateDialog now');
  assert.doesNotMatch(open, /\$\('rwCustomerName'\)\?\.focus/, 'initial focus belongs to activateDialog now');
  const close = between('function closeRewardDialogV238', 'async function saveReward(');
  assert.match(close, /const deactivate=rewardDialogDeactivateV238;rewardDialogDeactivateV238=null;/);
  assert.match(close, /if\(deactivate\)deactivate\(\{restoreFocus:false\}\);else dialog\.remove\(\)/);
  // the editor node must go home BEFORE the deactivator removes the dialog
  assert.ok(close.indexOf('home.after(editor)') < close.indexOf('deactivate({restoreFocus:false})'));
});

test('the tier dialog uses the shared dialog helper too', () => {
  const open = between('function openTierDialogV236', 'function closeTierDialogV236');
  assert.match(open, /tierDialogDeactivateV236=CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#trName'\}\)/);
  assert.doesNotMatch(open, /dialog\.onkeydown/);
  assert.doesNotMatch(open, /\$\('trName'\)\?\.focus/);
  const close = between('function closeTierDialogV236', "['trName','trTh','trMul'");
  assert.match(close, /const deactivate=tierDialogDeactivateV236;tierDialogDeactivateV236=null;/);
  assert.match(close, /if\(deactivate\)deactivate\(\{restoreFocus:false\}\);else dialog\.remove\(\)/);
  assert.ok(close.indexOf('home.after(form)') < close.indexOf('deactivate({restoreFocus:false})'));
});

test('the router error card speaks owner language, not engine text', () => {
  assert.match(app, /<p class="muted small">\$\{esc\(ownerErrorText\(e\)\|\|'Please try again\.'\)\}<\/p>/);
  assert.doesNotMatch(app, /esc\(e&&e\.message\|\|String\(e\)\)/);
  assert.match(app, /\[\/failed to fetch\|networkerror/i);
});

test('a hash with no page is refused out loud instead of silently showing the dashboard', () => {
  const dispatch = between('const pageFn=', 'const pageResult=');
  assert.match(dispatch, /const pageFn=page\[0\]\?P\[page\[0\]\]:dashboard;/);
  assert.match(dispatch, /toast\('That page has moved\.'\)/);
  assert.match(dispatch, /return nav\('#\/dashboard'\)/);
});

test('the customer nav badge cache is cleared with the session', () => {
  const reset = between('function resetClientSessionState(', 'customerLocale=\'en\';');
  assert.match(reset, /customerNavCountsV194=\{programmes:0,bookings:0\};/);
  assert.match(app, /let customerNavCountsV194=\{programmes:0,bookings:0\};/);
});

test('Create account shows a busy state and cannot be double-fired', () => {
  const handler = between("$('customerCreateAccount').onclick=", "$('customerForgotPassword')");
  assert.match(handler, /CUI\.setButtonBusy\(button,\{label:'Opening…'\}\)/);
  assert.match(handler, /if\(button\.disabled\)return;/);
  assert.match(handler, /await renderCustomerOtpStart\(isRouteCurrent,'signup'\)/);
  assert.match(handler, /finally\{if\(button\.isConnected\)idle\(\)\}/);
  assert.match(app, /async function renderCustomerOtpStart\(/);
});
