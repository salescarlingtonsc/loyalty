import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const section=(source,start,end)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return source.slice(from,to);
};

test('standalone join is anonymous and cannot overwrite the primary customer session',async()=>{
  const join=await read('app/join.html');
  assert.match(join,/storageKey:'peekaa-public-join-anon-v1'/);
  assert.match(join,/persistSession:false/);
  assert.match(join,/autoRefreshToken:false/);
  assert.doesNotMatch(join,/localStorage\.clear|sessionStorage\.clear/);
  const invalid=section(join,'function renderInvalidLink','function renderLoadError');
  assert.match(join,/function customerAppUrl\(route='#\/'/);
  assert.match(invalid,/Open \$\{esc\(BRAND\.customerLabel\)\}/);
  assert.match(invalid,/Already a member\? Sign in/);
  assert.match(invalid,/customerAppUrl\('#\/wallet'\)/);
});

test('customer deep links persist through authentication and reject external destinations',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app,/CUSTOMER_DESTINATION_SESSION_KEY='peekaa\.customer\.pendingDestination\.v1'/);
  assert.match(app,/sessionStorage\.setItem\(CUSTOMER_DESTINATION_SESSION_KEY/);
  assert.match(app,/sessionStorage\.removeItem\(CUSTOMER_DESTINATION_SESSION_KEY/);
  assert.match(app,/function rememberPendingCustomerDestination/);
  assert.match(app,/function completePendingCustomerDestination/);
  assert.match(app,/function focusCustomerRoute\(\)\{[\s\S]*completePendingCustomerDestination\(location\.hash\)/);
  assert.doesNotMatch(section(app,'function takePendingCustomerDestination','function customerRegistrationDestinationPriority'),/pendingCustomerDestination=''/);
  assert.match(app,/normalizeCustomerDestination\([^)]*\)/);
  assert.doesNotMatch(app,/location\.(?:href|assign)\(pendingCustomerDestination/);
});

test('disabled messages route is honest and remains on the requested route',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const messages=section(app,'async function renderCustomerMessages','async function renderCustomerProfile');
  assert.doesNotMatch(messages,/nav\('#\/wallet'\)/);
  assert.match(messages,/Messages are not available/);
  assert.match(messages,/This feature is not available for your account right now/);
});

test('redemption cancellation uses an in-app decision and always renders canonical server state',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const qr=section(app,'function showPendingRedemptionQr','function showGrowthOfferQr');
  assert.match(qr,/customer-redemption-modal/);
  assert.match(qr,/Cancel this redemption\?/);
  assert.match(qr,/No points will be used\./);
  assert.match(qr,/Keep QR/);
  assert.match(qr,/Cancel redemption/);
  assert.doesNotMatch(qr,/\bconfirm\(/);
  assert.match(qr,/customer_get_redemption_intent_v89/);
  assert.match(qr,/reconcileRedemptionState/);
  assert.match(qr,/if\(pollInFlight\)\{[\s\S]*await pollInFlight;[\s\S]*reconcileRedemptionState\(\{afterCancellationFailure:true\}\)/);
  assert.match(qr,/try\{await pollInFlight\}finally\{pollInFlight=null\}/);
  assert.match(qr,/redemptionCountdownText/);
  assert.match(qr,/visibilitychange/);
  assert.match(qr,/clearInterval/);
  assert.match(qr,/If it is still pending, try again/);
});

test('customer account trust controls use positioned UI and shared capability truth',async()=>{
  const [app,push]=await Promise.all([Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),read('app/customer-push.js')]);
  /* v296: the account menu was removed (owner: "remove this — here got profile already").
     Profile is a nav tab, device notifications live with the inbox they govern, and Sign out is
     the last card on Profile. Nothing should re-introduce the dropdown this rule styled. */
  assert.doesNotMatch(app,/customer-account-menu|customerAccountMenuDetails/);
  /* The menu's hand-rolled Escape went with it. Escape now belongs to the shared dialog helper
     (v286 moved every customer dialog onto CUI.activateDialog, which owns the focus trap,
     Escape and the Android Back entry) — one implementation instead of per-widget copies. */
  assert.match(app,/CUI\.activateDialog\(/);
  const passkeys=section(app,'const loadPasskeys=async','passkeyAdd.onclick');
  assert.doesNotMatch(passkeys,/\bconfirm\(/);
  assert.match(passkeys,/Remove this passkey\?/);
  assert.match(passkeys,/Keep passkey/);
  assert.match(push,/function visible\(/);
  assert.match(push,/button\.hidden=!visible\(value\)/);
  assert.match(push,/setting\.hidden=!visible\(value\)/);
});

test('security readiness is explicit instead of allowing a silent sign-in no-op',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const signIn=section(app,'function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  /* V388: there is no security check to be ready FOR. The control is live on paint and says
     "Sign in", never "Checking…". A failed attempt must still leave the control usable. */
  assert.match(signIn,/id="customerPasswordSignIn" type="submit" style=[^>]*>[\s\S]*?<span>Sign in<\/span>/);
  assert.doesNotMatch(signIn,/id="customerPasswordSignIn"[^>]*disabled/);
  assert.doesNotMatch(signIn,/Waiting for security check|Security check is still running|captchaToken/);
  assert.match(signIn,/if\(error\|\|!data\?\.user\)\{[\s\S]*signIn\.disabled=false;[\s\S]*passkeyButton\.disabled=!passkeySupported;[\s\S]*textContent='Sign in'/);
  assert.doesNotMatch(signIn,/if\(error\|\|!data\?\.user\)\{[\s\S]{0,200}signIn\.disabled=true/);
});

test('customer Home does not expose operator ranking language',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.doesNotMatch(app,/cannot safely rank an action/i);
  /* v183 replaced the "Choose what you'd like to do" filler with a plain two-card jump-off;
     v194 removed even that, because the same two destinations are permanent navigation tabs.
     What must survive is the neutral destination itself, wherever it is rendered. */
  assert.doesNotMatch(app,/customerHomeQuickLinksV183/);
  // v244 put Scan and Explore between them; the neutral destinations themselves are the invariant.
  assert.match(app,/\{key:'programmes',href:'#\/customer\/programmes'[\s\S]{0,320}\{key:'bookings',href:'#\/customer\/bookings'/);
});

test('canonical cancellation remains row-locked, scoped and non-economic',async()=>{
  const migration=await read('supabase/migrations/20260727010000_nestly_v89_customer_qr_redemption_platform_access.sql');
  const cancel=section(migration,'create or replace function public.customer_cancel_redemption_intent_v89','create or replace function app.v89_redemption_intent_guard');
  assert.match(cancel,/identity_id=v_identity[\s\S]*auth_user_id=auth\.uid\(\)[\s\S]*for update/i);
  assert.doesNotMatch(cancel,/points_ledger|points_batches|loyalty_operations|loyalty_redemptions/i);
  assert.match(cancel,/status='cancelled'/i);
  assert.match(cancel,/on conflict\(intent_id,event_type,idempotency_key\) do nothing/i);
});

test('rollback and disposable database evidence cover cancellation terminal states and races',async()=>{
  const [rollback,race]=await Promise.all([
    read('db/tests/v89_customer_platform_contracts.sql'),
    read('db/tests/v89_customer_qr_redemption_concurrency.sh')
  ]);
  assert.match(rollback,/completed redemption was cancelled/);
  assert.match(rollback,/double cancellation was not idempotent and non-economic/);
  assert.match(rollback,/another customer cancelled a redemption intent/);
  assert.match(rollback,/cancelled redemption was completed/);
  assert.match(rollback,/expired redemption changed canonical redemption rows/);
  assert.match(race,/cancel_race_once/);
  assert.match(race,/scan_race_once/);
  assert.match(race,/merchant_scan_redemption_qr_v117/);
  assert.match(race,/cross-tenant branch denial changed redemption state or balance/);
  assert.match(race,/cancelled\\\|1\\\|60\\\|1\|completed\\\|2\\\|20\\\|1/);
  assert.match(race,/expected exactly one successful writer/);
});
