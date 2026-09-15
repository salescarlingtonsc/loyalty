import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const appJs = await readFile(new URL('app/app.js', root), 'utf8');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const profile = section(appJs, 'async function renderCustomerProfile(requestedView){', 'async function renderCustomerQrJoin');
const surfaceContext = section(appJs, 'async function loadCustomerSurfaceContext', 'async function renderCustomerProgrammes');

/* v286 (audit, customer Profile). Three failure states on this page told the customer something
   untrue or left them with nothing to press. Each assertion below pins the honest behaviour. */

test('v286: a failed customer_get_profile is carried out of the surface context', () => {
  /* Without the error, a blip and an account with no profile row are indistinguishable. */
  assert.match(surfaceContext, /profileError:profileResult\.error\|\|null/);
});

test('v286: a failed profile read is named as a failure with a retry, not as an account limitation', () => {
  assert.match(profile, /const detailsLoadFailedV286=!profile&&context\.features\.customer_phone_registration===true&&context\.profileError!=null/);
  assert.match(profile, /We couldn’t load your details/);
  assert.match(profile, /id="customerProfileDetailsRetry"/);
  /* The retry must actually re-run the read.
     Pin updated (audit F041): the re-render now carries `requestedView`, so a retry raised on
     #/customer/settings repaints the settings half instead of silently switching the page to
     Profile. Same requirement — it still re-runs renderCustomerProfile — with the view preserved. */
  assert.match(profile, /detailsRetry\.onclick=\(\)=>\{[^}]*renderCustomerProfile\(requestedView\)/);
  /* "Not available for this account" survives only as the genuine feature-off / no-row case. */
  assert.match(profile, /:'<section class="card"><h2>Profile editing is not available<\/h2>[\s\S]*?Profile editing isn’t available for this account\./);
});

test('v286: account-level controls do not depend on the profile row', () => {
  /* Appearance, sounds, marketing, communications, password, passkeys, device notifications are all
     rendered from one innerHTML that now holds the personal-details card as a variable, so a failed
     profile read can no longer take them off the page. */
  assert.match(profile, /\$\('walletBody'\)\.innerHTML=`<header class="customer-page-head customer-profile-head-v583">[\s\S]*?\$\{personalDetailsHtmlV286\}/);
  for (const id of ['customerAppearance', 'customerExperiencePreferences', 'customerMarketingPreference',
    'customerCommunicationsEntry', 'customerPasswordManage', 'customerPasskeys']) {
    const at = profile.indexOf(`id="${id}"`);
    assert.ok(at > profile.indexOf('${personalDetailsHtmlV286}'), `${id} must render after the personal-details slot, in the same body`);
  }
  /* The old early return that dropped every one of them must be gone. */
  assert.doesNotMatch(profile, /customer_phone_registration!==true\|\|!context\.profile/);
  /* The profile save handler is the only thing gated on the row being there. */
  assert.match(profile, /if\(\$\('customerProfileSave'\)\)\$\('customerProfileSave'\)\.onclick=async\(\)=>/);
});

test('v286: a failed marketing-preference read keeps a way back to the control', () => {
  assert.match(profile, /ct\('Your marketing choice could not be loaded\. No change has been made\.'\)\)\}<\/p><button class="btn ghost" id="customerMarketingRetry"/);
  /* Pin updated (audit F041): the marketing card lives inside #customerProfileSettingsV583, which is
     hidden unless requestedView==='settings' — a bare re-render hid the very card being retried. */
  assert.match(profile, /marketingRetry\.onclick=\(\)=>\{[\s\S]*?renderCustomerProfile\(requestedView\)/);
});

/* nestly_v980 — OWNER RULING 2026-09-15: "customer app = english only", restoring
   PRODUCT-TRUTH.md's standing "The customer portal is English-only at this stage".
   This test has tracked the preferred-language control through three positions: v286 pinned an
   honest EN-only LABEL over a control that changed nothing, v293 made the control real, and the
   ruling now removes the control altogether. The through-line v286 cared about is unchanged and is
   what this still asserts — the profile card must not claim to cover something it does not. */
test('v980: the profile card offers no language control, and claims none', () => {
  assert.doesNotMatch(profile, /id="customerProfileLanguage"/);
  assert.doesNotMatch(profile, /\$\{esc\(ct\('preferredLanguage'\)\)\}/);
  assert.doesNotMatch(profile, /\$\{esc\(ct\('languageHelp',\{product:BRAND\.productName\}\)\)\}/);
  assert.doesNotMatch(profile, /Keep your name and preferred language current across/);
  /* The save still SENDS a language, as the constant 'en', so a profile saved by anyone who had
     previously chosen another one converges the stored column back to English. */
  assert.match(profile, /language='en';/);
});

test('v286: the sound label follows the reduced-motion override', () => {
  /* nestly_v627 (owner photos 1+2: "when i click on or off - the overlapping issue will surface").
     v286's point is unchanged and is what these lines still pin — the label must state the state
     the override actually forces, not the stored preference. What changed is WHERE the label is:
     it used to be reached as the input's nextElementSibling, which is not the label at all — it
     is the <i> that draws the switch, so the word was being painted inside the pill. Both writers
     now go through one function that addresses the span by id. */
  assert.match(profile, /if\(reducedMotion\)\{[\s\S]*?successSound\.disabled=true[\s\S]*?setSuccessSoundLabelV627\(\)/);
  assert.match(profile, /const setSuccessSoundLabelV627=\(\)=>\{[\s\S]*?\$\('customerSuccessSoundLabelV627'\)[\s\S]*?ct\('soundOn'\):ct\('soundOff'\)/,
    'one writer, addressing the label by id');
  assert.doesNotMatch(profile, /successSound\.nextElementSibling/,
    'the switch that DRAWS the control must never be written to as if it were the label');
});
