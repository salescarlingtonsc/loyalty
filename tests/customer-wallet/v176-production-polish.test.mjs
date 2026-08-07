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

const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));

test('an expired sign-in is recoverable instead of reading as a permission denial',()=>{
  assert.match(app,/function walletRpcDenied\(error\)\{return error\?\.code==='42501'\}/,
    'PGRST301 must no longer be folded into the denial branch');
  assert.match(app,/function walletSessionExpired\(error\)\{return error\?\.code==='PGRST301'\}/);
  assert.match(app,/async function customerSessionExpiredSignIn\(\)\{[\s\S]*signOut\(\{scope:'local'\}\)\.catch\(\(\)=>\{\}\)/);
  const sectionError=section(app,'function walletSectionError(','function walletRpcDenied(');
  assert.match(sectionError,/if\(walletSessionExpired\(error\)\)\{/);
  assert.match(sectionError,/Your sign-in expired\. Sign in again\./);
  assert.doesNotMatch(sectionError,/Section unavailable/,
    'the error heading must name the section, not a generic label');
  assert.match(sectionError,/didn’t load/);
  assert.match(app,/if\(event==='SIGNED_OUT'\)\{setTimeout\(\(\)=>route\(\),0\)\}/);
});

test('a failed customer sign-in leaves the button usable',()=>{
  const signIn=section(app,'function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  assert.match(signIn,/if\(error\|\|!data\?\.user\)\{[\s\S]*signIn\.disabled=false;/);
  assert.match(signIn,/if\(error\|\|!data\?\.user\)\{[\s\S]*textContent='Sign in';/);
  assert.doesNotMatch(signIn,/if\(error\|\|!data\?\.user\)\{[\s\S]{0,200}signIn\.disabled=true/);
});

test('the promotion popup dismisses optimistically and can never trap the customer',()=>{
  const popup=section(app,"const close=(operation='dismiss',afterClose=null)=>{","deactivate=CUI.activateDialog(dialog,");
  const removal=popup.indexOf('if(deactivate)deactivate();else dialog?.remove();');
  const rpc=popup.indexOf("sb.rpc('customer_set_in_app_inbox_state'");
  assert.ok(removal>=0&&rpc>removal,'the dialog must be removed before the state RPC is fired');
  assert.doesNotMatch(popup,/await sb\.rpc\('customer_set_in_app_inbox_state'/);
  assert.doesNotMatch(popup,/could not be dismissed/);
});

test('dark mode remaps outrank base rules and cover the previously light customer surfaces',()=>{
  assert.match(app,/<meta name="theme-color" media="\(prefers-color-scheme: dark\)" content="#0F1115">/);
  assert.match(app,/\.customer-surface\.customer-surface :is\(input,select,textarea/);
  assert.doesNotMatch(app,/\.customer-surface :where\(input,select,textarea/);
  for(const selector of [
    '\\.customer-surface\\.customer-surface \\.customer-first-quest\\{',
    '\\.customer-surface\\.customer-surface \\.customer-programme-logo\\{',
    '\\.customer-workspace-switch \\.menu\\)',
    '\\.customer-programme-switcher a,'
  ])assert.match(app,new RegExp(selector));
  assert.match(app,/\.modal\.customer-surface\{min-height:auto;background:rgba\(23,22,26,\.4\)\}/,
    'a customer modal must keep the scrim rather than paint the page background');
  assert.match(app,/modal\.className='modal customer-surface';/);
  assert.match(app,/overlay\.className='modal customer-surface customer-offer-detail-modal';/);
  assert.match(app,/<div class="modal customer-surface" id="customerPromotionPopupV122"/);
  assert.match(app,/\.customer-surface \.redemption-qr\{color-scheme:light/,
    'the redemption QR stays deliberately light for scanning');
});

test('customer copy speaks plainly instead of exposing system vocabulary',()=>{
  for(const dead of [
    'The end instant is exclusive',
    'More request history exists but a continuation is unavailable',
    "authentication provider’s policy",
    'for this Peekaa environment',
    'not linked to the current Peekaa domain',
    'This account uses the earlier customer identity path'
  ])assert.ok(!app.includes(dead),`system-voiced copy still present: ${dead}`);
  assert.match(app,/Use it before \$\{esc\(walletDate\(validity\.available_until,true\)\)\}\. Ask the team at the counter\./);
  assert.match(app,/We can’t show older requests right now\./);
  assert.match(app,/The code is valid for a few minutes\./);
  assert.match(app,/Face ID and passkeys aren’t available yet\. Use your password\./);
  assert.match(app,/This passkey no longer works here\. Add it again\./);
  assert.match(app,/Profile editing isn’t available for this account\./);
  assert.match(app,/Some booking info didn’t load\./);
  assert.match(app,/const CUSTOMER_REDEMPTION_STATUS_COPY=\{[\s\S]*limit_reached:'You have reached the limit for this reward\.'/);
  assert.doesNotMatch(app,/toast\('Redemption is '\+String\(intent\?\.status/,
    'raw redemption status enums must never reach a customer toast');
  assert.match(app,/return toast\('The change could not be saved\. Please try again\.'\)/);
  assert.match(app,/return toast\('Notification settings could not be saved\. Please try again\.'\)/);
});

test('customer dead ends resolve: offers shelf, QR fallback, contact panel, booking send', ()=>{
  const programmes=section(app,'async function renderCustomerProgrammes','const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');
  // v178: the owner removed the offers shelf from "My Rewards" entirely, so the route must
  // no longer fetch or render it — a shelf that is never painted cannot be left loading.
  assert.doesNotMatch(programmes,/customer_get_home_offers_v167/,
    'the programmes route must not fetch Home offers it no longer renders');
  assert.match(programmes,/renderActionableWalletHome\(data,\{surface:'programmes'/);
  assert.match(app,/const cards=Array\.isArray\(payload\?\.cards\)\?payload\.cards:\[\],isHome=surface!=='programmes'/);
  assert.match(app,/id="customerRedemptionFallback"[\s\S]{0,120}Show fallback token/);
  assert.match(app,/Loading contact details…/);
  assert.match(app,/Contact details unavailable\./);
  assert.match(app,/if\(\$\('psend'\)\)\$\('psend'\)\.disabled=false;/);
});

test('responsive and tap-target guards are in place across the customer surface',()=>{
  assert.match(app,/\.customer-primary-nav a,\.customer-primary-nav button\{flex-direction:column;gap:3px;min-height:58px/);
  assert.match(app,/\.customer-primary-nav a span,\.customer-primary-nav button span\{min-width:0;overflow-wrap:break-word;hyphens:auto\}/);
  assert.doesNotMatch(app,/\.customer-primary-nav a span,\.customer-primary-nav button span\{min-width:0;overflow-wrap:anywhere\}/);
  assert.match(app,/\.customer-surface summary\.small,\.customer-surface summary\.muted\{min-height:44px;display:flex;align-items:center\}/);
  assert.match(app,/\.wallet-line>div:first-child,\.wallet-appt>div:first-child\{min-width:0;overflow-wrap:anywhere\}/);
  /* v194 moved the balance into the Reward points tab and made the identity itself the tappable
     row; the overflow guard this line protects now belongs to that row. */
  assert.match(app,/\.customer-programme-identity\{[^}]*flex:1;min-width:0/);
  assert.match(app,/\.customer-programme-identity b\{[^}]*white-space:nowrap;overflow:hidden;text-overflow:ellipsis\}/);
  assert.match(app,/\.customer-programme-card-copy p\{line-height:1\.35;overflow-wrap:anywhere\}/);
  assert.match(app,/\.customer-merchant-hero h1\{[^}]*overflow-wrap:anywhere;word-break:break-word\}/);
  assert.match(app,/\.customer-first-quest h1\{[^}]*overflow-wrap:anywhere;word-break:break-word\}/);
  assert.doesNotMatch(app,/class="modal-card customer-offer-detail" style="width:480px"/,
    'the inline width defeats the min() guard on a 390px viewport');
  assert.match(app,/<section class="modal-card" style="width:min\(520px,calc\(100vw - 24px\)\)"/);
});

test('the install prompt remembers a dismissal and lifts above the mobile nav',async()=>{
  const [pwa,pwaCss,push]=await Promise.all([read('app/pwa.js'),read('app/pwa.css'),read('app/customer-push.js')]);
  assert.match(pwa,/const PWA_PROMPT_DISMISSED_KEY='peekaa-pwa-prompt-dismissed'/);
  assert.match(pwa,/const PWA_PROMPT_DISMISS_MS=30\*24\*60\*60\*1000/);
  assert.match(pwa,/setItem\(PWA_PROMPT_DISMISSED_KEY,String\(Date\.now\(\)\)\)/);
  assert.match(pwa,/function offerInstall\(\)\{[\s\S]{0,200}if\(promptDismissedRecently\(\)\)return;/);
  assert.match(pwaCss,/@media\(max-width:760px\)\{/);
  assert.doesNotMatch(pwaCss,/@media\(max-width:720px\)\{/);
  assert.match(push,/Notifications aren’t available yet\./);
});
