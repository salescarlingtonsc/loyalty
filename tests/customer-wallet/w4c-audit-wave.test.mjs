/* W4C audit wave — regressions for the customer-wallet findings F040, F041, F043, F044,
   F045/F111, F047, F049, F050, F051, F052, F053, F054, F055, F112, F114 and F115.

   Wherever the unit is small enough to be lifted out, the REAL source is extracted and EXECUTED
   against stubs, so an assertion fails when the behaviour regresses rather than when the spelling
   moves. The three findings whose unit is a several-hundred-line renderer (F053's watcher install,
   F054's paint-then-commit ordering, part of F112) are pinned by position instead — the ordering
   IS the fix in those cases, and an index comparison is the honest way to state it.

   F051's other half lives in tests/customer-wallet/v676-gift-qr-retap.test.mjs, which already
   executes the gift handler end to end and now proves the in-flight guard is raised and released. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}
/* One line of the shipped source, matched by a pattern, so the executed fragment is the real one. */
function sourceLine(pattern) {
  const match = appJs.match(pattern);
  assert.ok(match, `missing source line: ${pattern}`);
  return match[0];
}

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ct = value => String(value);
const walletSection = section(
  'async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){',
  'async function renderCustomerInAppInbox');

/* ------------------------------------------------------------------ F040 */

const marketingErrorText = vm.runInNewContext(
  `${section('function customerMarketingSaveErrorTextV4C(error){', '\nfunction renderCustomerRecoveryPasswordSetup')}\ncustomerMarketingSaveErrorTextV4C`,
  {});

test('F040 a 42501 from customer_set_platform_marketing_preference is named, not sold as "try again"', () => {
  /* The setter is a plain UPDATE on customer_registration_preferences and raises 42501 when the
     caller has no row — which is every identity minted by customer_create_identity (QR join /
     claim), because only customer_register_verified_phone ever inserts one. Telling that customer
     to "try again" asks them to repeat the one action that cannot succeed. */
  const denied = marketingErrorText({ code: '42501', message: 'customer marketing preference is unavailable' });
  assert.match(denied, /register your mobile number/i);
  assert.doesNotMatch(denied, /try again/i);
  /* The message alone is enough — PostgREST does not always carry the SQLSTATE. */
  assert.equal(marketingErrorText({ message: 'customer marketing preference is unavailable' }), denied);
});

test('F040 an ordinary failure still gets the retry prompt it deserves', () => {
  assert.match(marketingErrorText({ message: 'Failed to fetch' }), /could not be saved\. Please try again\./);
  assert.match(marketingErrorText(null), /could not be saved\. Please try again\./);
});

test('F040 the Save handler renders that reason instead of the old fixed sentence', () => {
  const save = section("  const marketingSave=$('customerProfileMarketingSave');", '  /* v286: re-runs the profile render');
  assert.match(save, /customerMarketingSaveErrorTextV4C\(error\)/);
  assert.doesNotMatch(save, /'<div class="err">Your marketing choice could not be saved\. Please try again\.<\/div>'/);
});

/* ------------------------------------------------------------------ F041 */

const runProfileRetries = requestedView => {
  const rendered = [];
  const nodes = {
    customerProfileDetailsRetry: { disabled: false, onclick: null },
    customerMarketingRetry: { disabled: false, onclick: null }
  };
  const src =
    section("  const detailsRetry=$('customerProfileDetailsRetry');", '  if($(\'customerProfileSave\'))') +
    section('  const marketingRetry=$(\'customerMarketingRetry\');', "  $('customerProfilePasswordSave').onclick");
  vm.runInNewContext(src, {
    requestedView,
    $: id => nodes[id] || null,
    CUI: { announce: () => {} },
    renderCustomerProfile: view => rendered.push(view)
  });
  return { nodes, rendered };
};

test('F041 the marketing Retry re-renders the SETTINGS view it was pressed on', () => {
  /* The card holding this button is inside #customerProfileSettingsV583, which renderCustomerProfile
     hides unless requestedView==='settings'. A bare re-render therefore repainted the page as
     Profile: the card being retried vanished, the shell's back chevron changed destination, and the
     URL still said #/customer/settings, so a refresh showed a different page than the screen did. */
  const { nodes, rendered } = runProfileRetries('settings');
  nodes.customerMarketingRetry.onclick();
  assert.deepEqual(rendered, ['settings']);
  assert.equal(nodes.customerMarketingRetry.disabled, true, 'and the button still guards a double tap');
});

test('F041 the details Retry stays on the profile view when that is where it was pressed', () => {
  const { nodes, rendered } = runProfileRetries(undefined);
  nodes.customerProfileDetailsRetry.onclick();
  assert.deepEqual(rendered, [undefined], 'no view argument invented for the plain profile route');
});

test('F041 a language change re-renders the route the customer is standing on', () => {
  const save = section("  if($('customerProfileSave'))$('customerProfileSave').onclick=async()=>{", '  const marketingSave=');
  assert.match(save, /renderCustomerProfile\(requestedView\)/);
  assert.doesNotMatch(save, /renderCustomerProfile\(\);/);
});

/* ------------------------------------------------------------------ F043 */

const signInNoticeHelpers = section('let pendingCustomerSignInNoticeV4C=null;', 'function renderCustomerPasswordSignIn(');
const noticeRig = () => {
  const context = {};
  vm.runInNewContext(`${signInNoticeHelpers}
    const remember=rememberCustomerSignInNoticeV4C,take=takeCustomerSignInNoticeV4C;
    const adopt=(notice,noticeTone,now)=>{
      ${sourceLine(/if\(!notice\)\{const adoptedV4C=takeCustomerSignInNoticeV4C\(\);notice=adoptedV4C\.notice;noticeTone=adoptedV4C\.noticeTone\}/)}
      return {notice,noticeTone};
    };
    globalThis.rig={remember,take,adopt};`, context);
  return context.rig;
};

test('F043 a notice parked before signOut survives the SIGNED_OUT re-route', () => {
  /* supabase-js awaits _notifyAllSubscribers('SIGNED_OUT') inside signOut(); our listener schedules
     route() on a 0ms timer, and the hash never changes during these in-place flows — so route()
     landed back on this same sign-in card with no notice and replaced root.innerHTML. The sentence
     was on screen for one task. "Password updated" was the costly one: not seeing it sends people
     back through Forgot password and burns another OTP. */
  const rig = noticeRig();
  rig.remember('Password updated. Sign in with your mobile number and new password.', 'success');
  const adopted = rig.adopt('', 'success');
  assert.match(adopted.notice, /^Password updated\./);
  assert.equal(adopted.noticeTone, 'success');
});

test('F043 the parked notice is consumed once and never leaks onto a later sign-in', () => {
  const rig = noticeRig();
  rig.remember('Signed out. Tap Create account to start again.', 'info');
  assert.equal(rig.adopt('', 'success').notice, 'Signed out. Tap Create account to start again.');
  assert.equal(rig.adopt('', 'success').notice, '', 'a second render must not repeat it');
});

test('F043 a caller that supplies its own notice is never overwritten by the parked one', () => {
  const rig = noticeRig();
  rig.remember('parked', 'info');
  const kept = rig.adopt('explicit', 'success');
  assert.equal(kept.notice, 'explicit');
  assert.equal(rig.take().notice, 'parked', 'and the parked copy is still there for the re-route');
});

test('F043 a stale parked notice expires instead of surfacing on an unrelated screen', () => {
  const rig = noticeRig();
  rig.remember('Password updated.', 'success', 0);
  const found = vm.runInNewContext(`${signInNoticeHelpers}CUSTOMER_SIGNIN_NOTICE_TTL_MS_V4C`, {});
  assert.equal(found, 15000);
  assert.equal(rig.take(found + 1).notice, '', 'a notice older than the window is dropped');
});

test('F043 all three sign-out handlers park the notice BEFORE signOut resolves', () => {
  for (const [label, from, to] of [
    ['recovery save', "    const phone=customerRegistrationState.phone;", '  };\n}\n/* v193'],
    ['start again', '  if(startOver)startOver.onclick=async()=>{', '  if(signupStash&&customerSignupConsentRecorded())'],
    ['stranded session', '    if(!customerSignupConsentRecorded()){', '    return renderCustomerRegistrationProfile(isRouteCurrent);']
  ]) {
    const handler = section(from, to);
    const parked = handler.indexOf('rememberCustomerSignInNoticeV4C(');
    const signedOut = handler.indexOf('await sb.auth.signOut()');
    assert.ok(parked >= 0, `${label}: no notice is parked`);
    assert.ok(signedOut > parked, `${label}: the notice must be parked before the sign-out, not after`);
  }
});

/* ------------------------------------------------------------------ F044 */

const restorePasskeyButton = vm.runInNewContext(
  `(nativeShell,biometricEnrolled,passkeySupported)=>{const passkeyButton={};` +
  `${sourceLine(/passkeyButton\.disabled=nativeShell\?!biometricEnrolled:!passkeySupported;/)}` +
  `return passkeyButton.disabled}`, {});

test('F044 one wrong password does not disable Face ID for the rest of the session', () => {
  /* customerPasskeySupported() is hard-wired false in the Capacitor shell (v669: WebAuthn is
     impossible in a WKWebView), so restoring from passkeySupported evaluated to disabled=true on
     the one surface where the button is real — while the status line underneath still read
     "Sign in with Face ID." Nothing else re-enabled it. */
  assert.equal(restorePasskeyButton(true, true, false), false, 'shell + enrolled credential: usable');
  assert.equal(restorePasskeyButton(true, false, false), true, 'shell + nothing enrolled: still hidden/disabled');
});

test('F044 the browser rule is untouched', () => {
  assert.equal(restorePasskeyButton(false, false, true), false, 'web + passkeys supported: usable');
  assert.equal(restorePasskeyButton(false, false, false), true, 'web + no passkey support: disabled');
});

/* ------------------------------------------------------------------ F045 / F111 */

const runClaimOutcome = (outcome, data) => {
  const nodes = { claimResult: { innerHTML: '' } };
  const announced = [];
  const body = section("    if(outcome==='try_later'){", "    if(!invitationToken&&outcome==='linked'){");
  const run = vm.runInNewContext(`(outcome,data)=>{${body}return 'fell-through'}`, {
    $: id => nodes[id], esc, CUI: { announce: message => announced.push(String(message)) }
  });
  return { result: run(outcome, data), html: nodes.claimResult.innerHTML, announced };
};

test('F045/F111 a rate-limited claim says so, with the server’s own window', () => {
  /* All three claim RPCs answer {outcome:'try_later',retry_after_seconds:900} after five attempts
     in fifteen minutes. That refusal was painted as the success-styled "Request received — … the
     business link will appear here", so the customer waited for a link nobody had requested, or
     edited the slug and tried again — each of those also refused. */
  const { result, html, announced } = runClaimOutcome('try_later', { retry_after_seconds: 900 });
  assert.equal(result, undefined, 'the pending-request card must not be reached');
  assert.match(html, /class="err"/, 'and it is a refusal, not a success card');
  assert.match(html, /about 15 minutes/);
  assert.doesNotMatch(html, /Request received/);
  assert.equal(announced.length, 1, 'a screen reader is told too');
});

test('F045/F111 the window is rounded up and singular when it should be', () => {
  assert.match(runClaimOutcome('try_later', { retry_after_seconds: 61 }).html, /about 2 minutes/);
  assert.match(runClaimOutcome('try_later', { retry_after_seconds: 30 }).html, /about 1 minute\./);
  assert.match(runClaimOutcome('try_later', {}).html, /about 1 minute\./, 'a missing figure never says "0 minutes"');
});

test('F045/F111 a genuine no-match still falls through to the pending-request card', () => {
  assert.equal(runClaimOutcome('no_link_created', {}).result, 'fell-through');
  assert.equal(runClaimOutcome('linked', {}).result, 'fell-through');
});

/* ------------------------------------------------------------------ F047 */

const emailClaimAvailable = vm.runInNewContext(
  `S=>{${section('  const emailClaimAvailableV4C=', '\n  renderCustomerShell({active:\'programmes\'')};return emailClaimAvailableV4C}`, {});

test('F047 the email claim method is offered only to an account that actually has a confirmed email', () => {
  /* customer_create_identity raises 42501 unless auth.users carries a confirmed email, and everyone
     who signed up on this surface has a phone and no email — so "Use my confirmed email instead"
     always failed, and reported the failure as a Peekaa outage. */
  assert.equal(emailClaimAvailable({ user: { email: 'a@b.sg', email_confirmed_at: '2026-01-01T00:00:00Z' } }), true);
  assert.equal(emailClaimAvailable({ user: { email: 'a@b.sg' } }), false, 'unconfirmed is not confirmed');
  assert.equal(emailClaimAvailable({ user: { email: 'a@b.sg', confirmed_at: '2026-01-01T00:00:00Z' } }), false,
    'GoTrue\u2019s generic confirmed_at is set by a confirmed PHONE — it is not an email confirmation');
  assert.equal(emailClaimAvailable({ user: { email: '', email_confirmed_at: '2026-01-01T00:00:00Z' } }), false);
  assert.equal(emailClaimAvailable({ user: null }), false);
  assert.equal(emailClaimAvailable({}), false, 'and no session fails closed');
});

test('F047 the method radios appear only when both methods are real', () => {
  const claim = section('async function renderCustomerClaim(){', 'function renderCustomerWalletUnavailable');
  assert.match(claim, /\$\{phoneClaimAvailable&&emailClaimAvailableV4C\?`<fieldset/);
  assert.match(claim, /id="claimByEmail"/, 'the control itself is unchanged when it is offered');
});

const identityErrorText = vm.runInNewContext(
  `error=>{const identity={error};${section('        const identityProbeV4C=', '        $(\'claimResult\').innerHTML=')}return identityTextV4C}`,
  { ct });

test('F047 a refused identity is explained as an account fact, not an outage', () => {
  assert.match(identityErrorText({ code: '42501', message: 'a verified email is required to create a customer identity' }),
    /no confirmed email/i);
  assert.match(identityErrorText({ message: 'a verified email is required to create a customer identity' }),
    /no confirmed email/i);
  assert.match(identityErrorText({ message: 'Failed to fetch' }), /unavailable\. Please try again later\./,
    'a genuine outage keeps the outage sentence');
});

/* ------------------------------------------------------------------ F049 */

const runDecisionDialog = ({ openDialogId = 0 } = {}) => {
  const activated = [];
  const closes = [];
  const controls = {};
  const makeNode = () => {
    const node = {
      className: '', innerHTML: '', isConnected: true, onclick: null,
      setAttribute: () => {}, addEventListener: () => {}, remove: () => {},
      querySelector: selector => (controls[selector] ||= { onclick: null, focus: () => {} })
    };
    return node;
  };
  const context = {
    /* audit F049: the module-level open-confirmation counter the sheet underneath reads. */
    customerDecisionDialogDepthV4C: 0,
    document: { createElement: makeNode, body: { appendChild: () => {} } },
    esc,
    CUI: {
      currentDialogHistoryId: () => openDialogId,
      activateDialog: (dialog, options) => {
        activated.push(options);
        return closeOptions => closes.push(closeOptions);
      }
    }
  };
  const src = section('function showCustomerDecisionDialog({title,body,keepLabel=\'Keep\'',
    '/* V290: the promotion twin of showPendingRedemptionQr');
  const show = vm.runInNewContext(`${src}\nshowCustomerDecisionDialog`, context);
  const promise = show({ title: 'Cancel this redemption?', body: 'No points will be used.' });
  return { activated, closes, controls, promise, context };
};

test('F049 a confirmation raised over the QR sheet borrows that sheet’s history entry', () => {
  /* Stacking a second entry meant one Back pop was heard by BOTH popstate listeners: the
     confirmation closed, and the QR overlay underneath saw itself still connected and closed too.
     So the gesture that means "no, keep my QR" threw the QR away while the intent stayed pending
     server-side — and for a gift, the re-tap is then refused for fifteen minutes. */
  const { activated } = runDecisionDialog({ openDialogId: 7 });
  assert.equal(activated.length, 1);
  assert.equal(activated[0].inheritHistoryId, 7, 'the open dialog’s entry, not a second one');
});

test('F049 while it is open the sheet underneath can tell a Back is answering IT, not dismissing them', async () => {
  const rig = runDecisionDialog({ openDialogId: 7 });
  assert.equal(rig.context.customerDecisionDialogDepthV4C, 1, 'raised for as long as the question stands');
  rig.controls['#customerDecisionKeep'].onclick();
  await rig.promise;
  assert.equal(rig.context.customerDecisionDialogDepthV4C, 0, 'and released once it is answered');
  rig.controls['#customerDecisionConfirm'].onclick();
  assert.equal(rig.context.customerDecisionDialogDepthV4C, 0, 'a second settle cannot drive it negative');
});

test('F049 answering it hands that entry back untouched', async () => {
  const rig = runDecisionDialog({ openDialogId: 7 });
  rig.controls['#customerDecisionKeep'].onclick();
  assert.equal(await rig.promise, false);
  assert.equal(rig.closes.length, 1);
  assert.equal(rig.closes[0].handOffHistory, true,
    'the entry belongs to the dialog that is staying — closing must not unwind it');
  assert.equal(rig.closes[0].restoreFocus, true);
});

test('F049 standing alone, it pushes and pops exactly as it always did', async () => {
  const rig = runDecisionDialog({ openDialogId: 0 });
  assert.equal(rig.activated[0].inheritHistoryId, 0);
  rig.controls['#customerDecisionConfirm'].onclick();
  assert.equal(await rig.promise, true);
  assert.equal(rig.closes.length, 1);
  assert.equal(rig.closes[0].handOffHistory, false, 'with nothing underneath it unwinds its own entry');
});

const qrBackRig = ({ depth }) => {
  const listeners = [];
  const stack = [{ cuiDialog: 4 }];
  const closes = [];
  const context = {
    customerDecisionDialogDepthV4C: depth,
    closed: false,
    close: () => { closes.push(1); context.closed = true },
    overlay: { isConnected: true },
    window: {
      addEventListener: (type, handler) => listeners.push({ type, handler }),
      removeEventListener: (type, handler) => {
        const at = listeners.findIndex(entry => entry.handler === handler);
        if (at >= 0) listeners.splice(at, 1);
      }
    },
    history: {
      get state() { return stack[stack.length - 1] },
      pushState: value => stack.push(value)
    }
  };
  const src = section('  let qrHistoryIdV4C=0,qrBackRearmV4C=null;', '  const updateCountdown=()=>{');
  const api = vm.runInNewContext(
    `${src}\nqrHistoryIdV4C=4;\n({guard:closeUnlessConfirmingV4C,drop:dropQrBackRearmV4C})`, context);
  return { api, listeners, stack, closes };
};

test('F049 Back answering the stacked confirmation keeps the QR sheet and its entry', () => {
  /* Borrowing the history entry stops the DOUBLE pop, but not this: the QR overlay's own popstate
     listener hears the same single pop, sees itself connected and closes — so "no, keep my QR"
     destroyed the QR while the intent stayed pending server-side, and a gift re-tap is refused for
     fifteen minutes. */
  const rig = qrBackRig({ depth: 1 });
  rig.api.guard();
  assert.equal(rig.closes.length, 0, 'the sheet the customer said to keep is kept');
  assert.equal(rig.stack[rig.stack.length - 1].cuiDialog, 4, 'and its entry is re-pushed');
  assert.equal(rig.stack.length, 2);
  assert.equal(rig.listeners.length, 1, 'with a listener back in place of the one that self-removed');
  rig.listeners[0].handler();
  assert.equal(rig.closes.length, 1, 'so the NEXT Back still closes the sheet');
  assert.equal(rig.listeners.length, 0, 'exactly once');
});

test('F049 with no confirmation open, Back closes the sheet exactly as it always did', () => {
  const rig = qrBackRig({ depth: 0 });
  rig.api.guard();
  assert.equal(rig.closes.length, 1);
  assert.equal(rig.stack.length, 1, 'nothing is re-pushed');
  assert.equal(rig.listeners.length, 0, 'and no listener is left behind');
});

test('F049 the redemption sheet routes its dialog dismissals through that guard', () => {
  const sheet = section('function showPendingRedemptionQr({intent,businessName,rewardName,onClose=()=>{},',
    'function showGrowthOfferQr');
  assert.match(sheet, /CUI\.activateDialog\(overlay,\{onClose:closeUnlessConfirmingV4C,/);
  assert.match(sheet, /qrHistoryIdV4C=Number\(CUI\.currentDialogHistoryId\?\.\(\)\|\|0\);/);
  assert.match(sheet, /dropQrBackRearmV4C\(\); \/\/ audit F049/,
    'and a real close takes the re-armed listener with it');
});

test('F049 the confirmation counts itself open only while it is open', async () => {
  const depthOf = () => vm.runInNewContext(
    `${section('let customerDecisionDialogDepthV4C=0;', 'function showCustomerDecisionDialog(')}customerDecisionDialogDepthV4C`, {});
  assert.equal(depthOf(), 0, 'the counter starts closed');
  const decision = section('function showCustomerDecisionDialog({title,body,keepLabel=\'Keep\'',
    '/* V290: the promotion twin of showPendingRedemptionQr');
  const raised = decision.indexOf('customerDecisionDialogDepthV4C+=1;');
  const released = decision.indexOf('customerDecisionDialogDepthV4C=Math.max(0,customerDecisionDialogDepthV4C-1);');
  assert.ok(raised > 0 && released > raised, 'raised on open, released inside finish()');
  assert.ok(decision.indexOf('const finish=value=>{') < released, 'released by the settle path, not by a caller');
});

/* ------------------------------------------------------------------ F046 */

const syncSignupPassword = vm.runInNewContext(
  `${section('async function customerSyncSignupPasswordV4C(password,updateUser){', '\nfunction renderCustomerOtpVerification')}\ncustomerSyncSignupPasswordV4C`,
  {});

test('F046 the password the customer just typed is what the account ends up holding', async () => {
  /* GoTrue's signUp on an existing UNCONFIRMED phone resends the code and deliberately leaves the
     password alone. The client showed the OTP screen as though the new password had been accepted;
     the first sign-in with it was then refused as incorrect, and only Forgot password got them in. */
  const sent = [];
  assert.equal(await syncSignupPassword('Correct-Horse-1!', payload => { sent.push(payload); return {} }), 'synced');
  assert.equal(sent.length, 1, 'exactly one auth write');
  assert.equal(sent[0].password, 'Correct-Horse-1!');
});

test('F046 a failure is reported, never swallowed, and nothing is written when there is nothing to write', async () => {
  assert.equal(await syncSignupPassword('Correct-Horse-1!', async () => ({ error: { message: 'weak' } })), 'failed');
  let called = 0;
  assert.equal(await syncSignupPassword('', () => { called += 1; return {} }), 'skipped');
  assert.equal(await syncSignupPassword(null, () => { called += 1; return {} }), 'skipped');
  assert.equal(called, 0, 'the recovery flow, which carries no typed password, makes no auth write');
});

test('F046 the typed password is held for one hop, wiped before it is used, and never persisted', () => {
  const verify = section('    S.user=data.user;', '  resend.onclick=async()=>{');
  const wiped = verify.indexOf("customerRegistrationState={...customerRegistrationState,signupPassword:''};");
  const used = verify.indexOf('customerSyncSignupPasswordV4C(');
  assert.ok(wiped > 0 && used > wiped, 'the state slot is cleared before the await, not after it');
  assert.match(verify, /if\(passwordSyncV4C==='failed'\)\{/, 'and a failed sync is told to the customer');
  const send = section('    customerRegistrationState={\n      phone,channel,purpose,', '    rememberCustomerSignupConsent(');
  assert.match(send, /signupPassword:recovering\?'':password/);
  assert.doesNotMatch(appJs, /sessionStorage[^\n]*signupPassword/, 'a password must not survive a reload');
});

/* ------------------------------------------------------------------ F050 */

const cancelGuard = vm.runInNewContext(
  `(confirmed,isConnected,terminal)=>{const overlay={isConnected};` +
  `${sourceLine(/if\(!confirmed\|\|!overlay\.isConnected\|\|terminal\)return;/)}` +
  `return 'proceeded'}`, {});

test('F050 a cancellation confirmed after the counter has already scanned is dropped', () => {
  /* finish() has by then painted "Redeemed" and removed the Cancel button. Carrying on wrote
     "Cancelling this redemption…" underneath that pill, called an RPC the server refuses
     ("completed redemption cannot be cancelled"), and landed in an error branch whose reconcile
     returns immediately because terminal is set — so the contradiction was never corrected. */
  assert.equal(cancelGuard(true, true, true), undefined);
});

test('F050 a live pending redemption is still cancellable', () => {
  assert.equal(cancelGuard(true, true, false), 'proceeded');
  assert.equal(cancelGuard(false, true, false), undefined, 'and "Keep QR" still keeps it');
  assert.equal(cancelGuard(true, false, false), undefined, 'and a dismissed sheet still stands down');
});

/* ------------------------------------------------------------------ F051 */

const silentPaintRig = () => {
  const host = { innerHTML: '', querySelectorAll: () => [] };
  const context = {
    $: id => (id === 'walletBody' ? host : null),
    document: { querySelector: () => null, activeElement: null, scrollingElement: { scrollTop: 0 }, documentElement: {} }
  };
  const src = section('let customerRedeemInFlightV4C=0;', '/* nestly_v574: a per-business WhatsApp marketing switch.');
  const api = vm.runInNewContext(`${src}\n({paint:customerWalletSilentPaintV333,begin:customerRedeemInFlightBeginV4C,end:customerRedeemInFlightEndV4C})`, context);
  return { host, api };
};

test('F051 a redemption already in flight blocks the silent repaint that would drop it', () => {
  /* Both redemption handlers mint the intent and then bail silently if the section was repainted
     mid-request — no QR, no message, and a gift re-tap refused for fifteen minutes because a
     pending intent already exists. The .modal / focused-control guards do not cover that window:
     the QR sheet is not open yet, and on iOS Safari a tapped button takes no focus. */
  const { host, api } = silentPaintRig();
  api.begin();
  assert.equal(api.paint('<p>new</p>'), false);
  assert.equal(host.innerHTML, '', 'the section the customer is redeeming from is left alone');
  api.end();
  assert.equal(api.paint('<p>new</p>'), true);
  assert.equal(host.innerHTML, '<p>new</p>');
});

test('F051 the guard is a counter, so two overlapping taps cannot release it early', () => {
  const { api } = silentPaintRig();
  api.begin(); api.begin(); api.end();
  assert.equal(api.paint('<p>x</p>'), false, 'still one round trip outstanding');
  api.end();
  assert.equal(api.paint('<p>x</p>'), true);
  api.end();
  assert.equal(api.paint('<p>x</p>'), true, 'and it can never go negative and jam the wallet open');
});

/* ------------------------------------------------------------------ F052 */

const watchWallet = () => {
  const timers = new Map();
  let nextTimer = 1;
  const channels = [];
  const removed = [];
  const context = {
    activeCustomerWalletLiveCleanupV295: () => {},
    activeCustomerWalletCounterMomentV468: async () => {},
    customerWalletPulseSignatureV370: '',
    customerWalletSlugOnScreenV524: () => null,
    CUSTOMER_WALLET_POLL_LIMIT_V295: 9,
    CUSTOMER_WALLET_POLL_MS_V295: 20000,
    CUSTOMER_WALLET_COUNTER_POLL_MS_V468: 4000,
    CUSTOMER_WALLET_COUNTER_WINDOW_MS_V468: 60000,
    $: () => ({ isConnected: true }),
    document: { visibilityState: 'hidden', addEventListener: () => {}, removeEventListener: () => {} },
    S: { user: { id: 'user-1' } },
    setTimeout: (fn, delay) => { const id = nextTimer++; timers.set(id, { fn, delay }); return id },
    clearTimeout: id => timers.delete(id),
    sb: {
      channel(name) {
        const channel = {
          name, state: 'closed', statusCallback: null,
          on() { return channel },
          subscribe(callback) { channel.statusCallback = callback; return channel }
        };
        channels.push(channel);
        return channel;
      },
      removeChannel(channel) {
        removed.push(channel.name);
        channel.state = 'closed';
        /* supabase-js leave() fires phx_close, and subscribe() registered _onClose(cb('CLOSED')). */
        channel.statusCallback?.('CLOSED');
      }
    }
  };
  const src = section('function watchCustomerWalletV295(isCurrent,refresh,pulse=null,walletSlugV524=null){',
    '/* v333 (owner, 2026-08-15:');
  const watch = vm.runInNewContext(`${src}\nwatchCustomerWalletV295`, context);
  const handle = watch(() => true, async () => {}, null, null);
  const runTimers = () => { const due = [...timers.entries()]; timers.clear(); for (const [, t] of due) t.fn() };
  return { handle, channels, removed, timers, runTimers };
};

test('F052 a healthy channel is never torn down by a rebuild queued from its predecessor', () => {
  /* removeChannel calls leave(), which fires CLOSED on the OLD channel — the callback read that as
     a failure and scheduled another rebuild. The new channel then joined, reset the retry counter
     to 0 WITHOUT cancelling that pending timer, the timer removed the healthy channel, and its
     CLOSED scheduled the next one. Because SUBSCRIBED reset the counter every time, the >=5 cap was
     never reached: the wallet left and rejoined customer_wallet_signals_v479 every ~2s for the rest
     of the page view, dropping any doorbell that landed in a join gap. */
  const rig = watchWallet();
  assert.equal(rig.channels.length, 1, 'one channel on install');
  rig.channels[0].statusCallback('CHANNEL_ERROR');
  assert.equal(rig.timers.size, 1, 'a cold tenant still earns one bounded retry');
  rig.runTimers();
  assert.equal(rig.channels.length, 2, 'the retry rebuilt the channel from scratch');
  assert.deepEqual(rig.removed, ['wallet-signal-user-1'], 'and tore the old one down first');
  assert.equal(rig.timers.size, 0, 'the old channel’s CLOSED must NOT have queued a ghost rebuild');
  rig.channels[1].state = 'joined';
  rig.channels[1].statusCallback('SUBSCRIBED');
  assert.equal(rig.timers.size, 0, 'and nothing is pending that could remove the joined channel');
  rig.runTimers();
  assert.equal(rig.channels.length, 2, 'the loop is closed: no third channel, ever');
  rig.handle.stop();
});

test('F052 SUBSCRIBED cancels a rebuild still queued from this channel’s own bad start', () => {
  const rig = watchWallet();
  rig.channels[0].statusCallback('TIMED_OUT');
  assert.equal(rig.timers.size, 1);
  rig.channels[0].state = 'joined';
  rig.channels[0].statusCallback('SUBSCRIBED');
  assert.equal(rig.timers.size, 0, 'a join that recovered must not be undone two seconds later');
  rig.handle.stop();
});

test('F052 a genuinely refused join is still retried, and still bounded', () => {
  const rig = watchWallet();
  for (let attempt = 0; attempt < 8; attempt += 1) {
    rig.channels[rig.channels.length - 1].statusCallback('CHANNEL_ERROR');
    rig.runTimers();
  }
  assert.ok(rig.channels.length <= 6, `bounded at five retries, saw ${rig.channels.length} channels`);
  assert.ok(rig.channels.length >= 3, 'but it genuinely does retry');
  rig.handle.stop();
});

/* ------------------------------------------------------------------ F053 */

test('F053 the actionable Home installs a wallet watcher before it returns', () => {
  /* watchCustomerWalletV295 was installed in exactly two places — the legacy fallback Home and the
     business page — and the actionable branch, which every customer with a linked business takes
     and which is ON in production, returned without one. So a sale rung at the counter appeared on
     the business page within seconds and on Home not at all: no foreground re-read, no 20s pulse,
     no doorbell, until the customer navigated away and back. */
  const install = walletSection.indexOf('customerWalletActionableHomePulseReaderV370(),null);');
  assert.ok(install > 0, 'the actionable Home has no watcher install');
  const paint = walletSection.indexOf('customerWalletFactsPaintedV333(homeSignatureV333);');
  assert.ok(paint > 0 && paint < install, 'it is installed after the paint that established the baseline');
  const branchEnd = walletSection.indexOf('\n      return;\n      }', install);
  assert.ok(branchEnd > install, 'and before the branch returns');
  assert.match(walletSection.slice(install - 260, install), /if\(!silent\)watchCustomerWalletV295\(isWalletCurrent,/,
    'a silent pass must never build a second watcher');
});

/* ------------------------------------------------------------------ F054 */

test('F054 the poll baseline is committed with the paint, never before it', () => {
  /* customerWalletSilentPaintV333 refuses to paint while a sheet is open or a control inside
     #walletBody has focus — and closing a QR dialog puts focus straight back on the redeem button.
     Recording the baseline before that refusal meant every later tick saw an unchanged signature
     and stood down, so the change was never painted by the watcher at all. */
  for (const [label, remember, paint] of [
    ['actionable Home', 'rememberCustomerWalletPulseV370(data?.cards??null);', 'customerWalletFactsPaintedV333(homeSignatureV333);'],
    ['programme page', 'rememberCustomerWalletPulseSignatureV370(programmePulseBaselineV4C)', 'customerWalletFactsPaintedV333(programmeSignatureV333);']
  ]) {
    const at = walletSection.indexOf(remember);
    const painted = walletSection.indexOf(paint);
    assert.ok(at > 0 && painted > 0, `${label}: markers not found`);
    assert.ok(at > painted, `${label}: the baseline must be committed after the paint, not before`);
  }
  /* And the two pre-paint writers really are gone from the render. */
  assert.doesNotMatch(walletSection, /if\(!error\)rememberCustomerWalletPulseV370\(data\?\.cards\?\?null\);/);
  assert.doesNotMatch(walletSection, /if\(!actionableCard\)rememberCustomerWalletPulseSignatureV370\(/);
});

/* ------------------------------------------------------------------ F055 */

const counterMomentWiring = () => {
  const fired = [];
  const context = { customerCounterMomentV468: async () => { fired.push(1) } };
  const wire = vm.runInNewContext(
    `${section('function wireCustomerCounterMomentV468(root){', 'function wireCustomerBusinessShortcutPageV348')}\nwireCustomerCounterMomentV468`,
    context);
  const listeners = [];
  const root = { dataset: {}, addEventListener: (type, handler) => listeners.push({ type, handler }) };
  return { wire, root, listeners, fired };
};

test('F055 re-wiring the same #walletBody does not stack a second counter-moment listener', () => {
  /* A full render rebuilds the shell so the node is fresh — but a SILENT repaint keeps the same
     #walletBody and only swaps its innerHTML, and the render re-wires afterwards either way. Every
     doorbell ping, every closed redemption QR and every changed-fact tick therefore added another
     listener, and one tap on a redeem control then fired N counter moments: N concurrent forced
     wallet renders (~27 requests each) repainting the page under the customer's thumb. */
  const rig = counterMomentWiring();
  rig.wire(rig.root);
  rig.wire(rig.root);
  rig.wire(rig.root);
  assert.equal(rig.listeners.length, 1);
  assert.equal(rig.root.dataset.counterMomentWiredV468, '1');
});

test('F055 a genuinely new body still gets its listener', () => {
  const rig = counterMomentWiring();
  rig.wire(rig.root);
  const second = { dataset: {}, addEventListener: (type, handler) => rig.listeners.push({ type, handler }) };
  rig.wire(second);
  assert.equal(rig.listeners.length, 2);
  const event = { target: { closest: selector => (selector.includes('data-customer-redeem') ? {} : null) } };
  rig.listeners[0].handler(event);
  assert.equal(rig.fired.length, 1, 'and it still means a counter moment');
});

/* ------------------------------------------------------------------ F112 */

const offerSheet = section('function showCustomerOfferDetailV173(item,{inheritHistoryId=0}={}){',
  'function wireCustomerHomeOffersV167');

test('F112 the offer sheet never renders Book now straight from the offer’s own metadata', () => {
  /* The list CARD downgrades a 'book' CTA to 'programme' when the business's booking capability is
     off (customerPromotionCtaV104, the v183 fail-closed rule). Tapping that same card opened this
     sheet, which re-read the raw metadata.cta.kind and rendered a working Book now regardless — and
     nothing on the server refuses such a request: get_business_public, internal_public_booking_page
     and internal_public_booking_submit gate on per-service show_on_booking_page, never on
     business_customer_capabilities_v89.booking_enabled. */
  assert.doesNotMatch(offerSheet, /cta\.kind==='book'\?`<a class="btn" href="#\/b\//);
  assert.match(offerSheet, /<span data-offer-book><\/span>/, 'the button has one placeholder, filled after the live read');
  assert.match(offerSheet, /if\(business\.slug\)\{ \/\/ audit F112/, 'every CTA kind goes through that read');
  assert.match(offerSheet, /if\(!host\|\|error\|\|data\?\.booking\?\.enabled!==true\)return;/, 'fail closed');
});

const offerBookLabel = vm.runInNewContext(
  `(cta,ctaLabel)=>${sourceLine(/cta\.kind==='book'\?\(ctaLabel\|\|'Book now'\):ct\('bookNow'\)/)}`, { ct });

test('F112 the business’s configured wording still lands on the button that books', () => {
  assert.equal(offerBookLabel({ kind: 'book' }, 'Reserve a table'), 'Reserve a table');
  assert.equal(offerBookLabel({ kind: 'book' }, ''), 'Book now');
  assert.equal(offerBookLabel({ kind: 'programme' }, 'Reserve a table'), 'bookNow',
    'a non-book CTA keeps the generic v195 label it always had');
});

/* ------------------------------------------------------------------ F114 */

const bookingRow = (() => {
  const context = {
    esc, ct, walletDate: value => `date:${value}`, walletClockV580: () => '2:30 pm',
    customerBookingBusinessLogoV195: () => '<span class="logo"></span>',
    customerBookingCancelledV654: () => false,
    customerBookingStatusWordV654: status => String(status),
    CUI: { icon: name => `<i data-icon="${name}"></i>` },
    JSON
  };
  return vm.runInNewContext(
    `${section('function customerBookingRowV580(group,item,tab){', '/* Every appointment across every business on this tab')}\ncustomerBookingRowV580`,
    context);
})();

const confirmedAppointment = {
  appointment_id: 'appt-1', starts_at: '2026-09-10T06:30:00.000Z', status: 'booked',
  service_name: 'Facial', branch_name: 'Orchard'
};

test('F114 pausing NEW bookings does not take Reschedule and Cancel away from a confirmed one', () => {
  /* group.bookingEnabled is customer_get_business_actions_v89's booking.enabled, which additionally
     requires at least one service with show_on_booking_page — a completely different question from
     "may a customer change a confirmed appointment". Both server RPCs authorise on
     business_customer_capabilities_v89.appointment_changes_enabled alone
     (customer_reschedule_appointment_v508, customer_cancel_appointment_v655), and the wallet page's
     own Change control has always gated on that flag by itself. */
  const paused = { business_slug: 'cubbly', business_name: 'Cubbly', bookingEnabled: false, appointmentChangesEnabled: true };
  const html = bookingRow(paused, confirmedAppointment, 'bookings');
  assert.match(html, /data-reschedule-v508="appt-1"/);
  assert.match(html, /data-cancel-appointment-v655="appt-1"/);
  assert.match(html, /can_change&quot;:true/, 'and the detail sheet is told the same thing');
});

test('F114 a business that switched appointment changes OFF still offers neither', () => {
  const locked = { business_slug: 'cubbly', business_name: 'Cubbly', bookingEnabled: true, appointmentChangesEnabled: false };
  const html = bookingRow(locked, confirmedAppointment, 'bookings');
  assert.doesNotMatch(html, /data-reschedule-v508/);
  assert.doesNotMatch(html, /data-cancel-appointment-v655/);
  assert.match(html, /can_change&quot;:false/);
});

test('F114 the two controls remain confined to a confirmed appointment on the Confirmed tab', () => {
  const open = { business_slug: 'cubbly', business_name: 'Cubbly', bookingEnabled: false, appointmentChangesEnabled: true };
  assert.doesNotMatch(bookingRow(open, confirmedAppointment, 'history'), /data-reschedule-v508/);
  assert.doesNotMatch(bookingRow(open, { ...confirmedAppointment, status: 'completed' }, 'bookings'), /data-reschedule-v508/);
  assert.doesNotMatch(bookingRow(open, { ...confirmedAppointment, appointment_id: '' }, 'bookings'), /data-reschedule-v508/);
});

/* ------------------------------------------------------------------ F115 */

const bookingEmptyMarkup = vm.runInNewContext(
  `${section('const CUSTOMER_BOOKING_TABS_V178', 'function customerBookingTablistMarkupV178')}\ncustomerBookingEmptyMarkupV183`,
  { esc, ct, CUI: { icon: name => `<i data-icon="${name}"></i>` } });

test('F115 the empty Confirmed tab invites the customer to book with a business that has nothing booked', () => {
  /* The invites were never rendered, on any tab, in any state: the function only builds them when
     its tab argument is 'bookings', and the call site passed [] for exactly that case while handing
     allGroups to every tab that ignores the parameter. With customerBookingChooserV291 superseded
     (nestly_v577) these buttons are the only way to start a booking from this screen. */
  const groups = [
    { business_slug: 'cubbly', business_name: 'Cubbly', bookingEnabled: true },
    { business_slug: 'bistro', business_name: 'Bistro 88', bookingEnabled: false },
    { business_slug: '', business_name: 'No slug', bookingEnabled: true }
  ];
  const html = bookingEmptyMarkup('bookings', 'No confirmed bookings yet.', groups);
  assert.match(html, /Book with Cubbly/);
  assert.doesNotMatch(html, /Book with Bistro 88/, 'a business that is not taking bookings is not offered');
  assert.doesNotMatch(html, /Book with No slug/);
  assert.doesNotMatch(bookingEmptyMarkup('history', 'Nothing yet.', groups), /Book with/,
    'History is a record — it gets no invites');
});

test('F115 the call site hands the real group list to the tab that uses it', () => {
  const paint = section('const paintBookings', 'async function renderCustomerMessages');
  assert.match(paint, /customerBookingEmptyMarkupV183\(currentBookingTab,emptyCopy,currentBookingTab==='bookings'\?allGroups:\[\]\)/);
});
