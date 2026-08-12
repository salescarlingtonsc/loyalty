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

const profile = section(appJs, 'async function renderCustomerProfile(){', 'async function renderCustomerQrJoin');
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
  /* The retry must actually re-run the read. */
  assert.match(profile, /detailsRetry\.onclick=\(\)=>\{[^}]*renderCustomerProfile\(\)/);
  /* "Not available for this account" survives only as the genuine feature-off / no-row case. */
  assert.match(profile, /:'<section class="card"><h2>Profile editing is not available<\/h2>[\s\S]*?Profile editing isn’t available for this account\./);
});

test('v286: account-level controls do not depend on the profile row', () => {
  /* Appearance, sounds, marketing, communications, password, passkeys, device notifications are all
     rendered from one innerHTML that now holds the personal-details card as a variable, so a failed
     profile read can no longer take them off the page. */
  assert.match(profile, /\$\('walletBody'\)\.innerHTML=`<header class="customer-page-head">[\s\S]*?\$\{personalDetailsHtmlV286\}/);
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
  assert.match(profile, /Your marketing choice could not be loaded\. No change has been made\.<\/p><button class="btn ghost" id="customerMarketingRetry"/);
  assert.match(profile, /marketingRetry\.onclick=\(\)=>\{[\s\S]*?renderCustomerProfile\(\)/);
});

test('v286: the preferred-language control does not claim to change the app', () => {
  /* CUSTOMER_LOCALES is ['en'] and normalizeCustomerLocale hard-returns 'en', so the select stores
     a preference nothing reads yet. It says so rather than implying the surface will translate. */
  assert.match(appJs, /const CUSTOMER_LOCALES=Object\.freeze\(\['en'\]\)/);
  assert.match(profile, /Preferred language for messages \(English only today\)/);
  assert.match(profile, /is in English for every customer today\. We store your choice for when other languages arrive/);
  assert.doesNotMatch(profile, /Keep your name and preferred language current across/);
});

test('v286: the sound label follows the reduced-motion override', () => {
  assert.match(profile, /if\(reducedMotion\)\{[\s\S]*?successSound\.disabled=true[\s\S]*?label\.textContent=ct\('soundOff'\)/);
});
