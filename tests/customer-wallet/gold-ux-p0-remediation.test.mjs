import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const app = ((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

test('customer capability and profile failures stay retryable and never masquerade as missing registration', () => {
  const registration = app.match(/async function renderCustomerRegistration\([^\n]*\)[\s\S]*?(?=const CUSTOMER_PRIMARY_NAV|async function renderCustomerClaim)/)?.[0] || '';
  const context = app.match(/async function loadCustomerSurfaceContext\([^\n]*\)[\s\S]*?(?=async function renderCustomerProgrammes)/)?.[0] || '';
  const wallet = app.match(/async function renderCustomerWallet\([\s\S]*?(?=async function renderCustomerNotificationPreferences)/)?.[0] || '';
  /* nestly_v579 (owner: "keep not able to log in ... i cannot afford to have this in during live
     run"). A capability failure is still marked retryable — that is the invariant this test
     protects — but a SINGLE failure no longer produces the dead-end card. An auth-shaped error
     refreshes the session and retries once, anything else transient is retried with a backoff,
     and only a failure that survives all of that is surfaced (with the reason). */
  const capabilities = app.match(/async function loadCustomerFeatureCapabilities\([\s\S]*?\n\}/)?.[0] || '';
  assert.match(capabilities, /unavailableCustomerCapabilities\(true\)/,
    'a surviving failure must still be marked retryable, never cached as a real answer');
  assert.match(capabilities, /for\(let attempt=0;attempt<3;attempt\+\+\)/,
    'a single transient failure must not become a permanent card');
  assert.match(capabilities, /await sb\.auth\.refreshSession\(\)/,
    'an expired token must be refreshed and retried rather than shown as an outage');
  assert.match(capabilities, /if\(refreshed\)break/,
    'a genuine permission denial must not loop on refresh');
  assert.match(app, /_load_error_reason/,
    'the card must say which failure it was, so the next report identifies itself');
  assert.match(app, /_load_error:loadError/);
  assert.match(app, /customerCapabilities\._load_error\)return renderCustomerCapabilityRetry/);
  assert.match(app, /customerFeatures\._load_error\)\{[\s\S]{0,160}return renderCustomerCapabilityRetry/);
  assert.match(registration, /if\(profileError\)\{[\s\S]*renderCustomerCapabilityRetry\('We could not load your customer profile/);
  assert.doesNotMatch(registration, /profileError[\s\S]*renderCustomerWalletUnavailable/);
  assert.match(context, /profileResult\.error&&!customer\.length[\s\S]*renderCustomerCapabilityRetry\('We could not load your customer profile/);
  assert.match(context, /customerSurfaceQualifies\(profile,customer\)/);
  assert.doesNotMatch(app, /profileReady=!profileError/,
    'a network error must not be treated as an absent profile');
  assert.match(app, /id="customerCapabilityRetry"/);
  assert.match(app, /customerFeatureCapabilities=null;route\(\)/);
});

test('Singapore customer OTP accepts mobile prefixes only', () => {
  const source = app.match(/function normalizeSingaporeCustomerPhone[\s\S]*?\n\}/)?.[0] || '';
  assert.match(source, /\^\[89\]\[0-9\]\{7\}\$/);
  const normalize = new Function(`${source}\nreturn normalizeSingaporeCustomerPhone`)();
  assert.equal(normalize('9123 4567'), '+6591234567');
  assert.equal(normalize('+65 8123 4567'), '+6581234567');
  assert.equal(normalize('6123 4567'), null);
  assert.equal(normalize('3123 4567'), null);
});

test('appointment change is a labelled keyboard-complete modal', () => {
  const source = app.match(/function wireWalletAppointmentActions[\s\S]*?(?=function actionableWalletExpiryText)/)?.[0] || '';
  assert.match(source, /setAttribute\('role','dialog'\)/);
  assert.match(source, /setAttribute\('aria-modal','true'\)/);
  assert.match(source, /aria-labelledby','walletChangeTitle'/);
  assert.match(source, /aria-label="Close change appointment"/);
  assert.match(source, /<label for="walletChangeKind">/);
  assert.match(source, /<label for="walletChangeAt">/);
  assert.match(source, /<label for="walletChangeNote">/);
  assert.match(source, /CUI\.activateDialog\(modal,\{onClose:close,initialFocus:'#walletChangeKind'\}\)/);
  /* nestly_v509: 'Choose another time' became a REPLACING reschedule (v508), so the close+toast
     line branches on kind. Both outcomes still close first and speak second. */
  assert.match(source, /close\(\);toast\(kind==='reschedule'\?'Request sent — the business will confirm your new time\.':'Request sent to the business'\)/);
});

test('public booking uses semantic choices, safe contrast and the exact result host', () => {
  /* V336 (owner: "some colours are not being recognised — every company have their unique
     colour"): an under-contrast colour is now darkened toward the OWNER'S OWN hue rather than
     replaced with one shared fallback, so #FFB86B no longer collapses to #C24135 — it darkens to
     its own legible shade. Only a genuinely invalid value still falls back. */
  const source = app.match(/function relativeLuminanceHexV336[\s\S]*?(?=async function renderPortal)/)?.[0] || '';
  const safeColor = new Function(`${source}\nreturn contrastSafeBrandColor`)();
  assert.equal(safeColor('#000000'), '#000000');
  const darkened = safeColor('#FFB86B');
  assert.notEqual(darkened, '#FFB86B', 'an under-contrast colour must not pass through unchanged');
  assert.notEqual(darkened, '#C24135', 'it darkens toward its OWN hue, not the shared fallback');
  assert.match(darkened, /^#[0-9A-F]{6}$/);
  assert.equal(safeColor('not-a-color'), '#C24135');

  const portal = app.match(/async function renderPortal[\s\S]*?(?=async function boot)/)?.[0] || '';
  assert.match(portal, /<button class="svc[^>]*type="button"[^>]*aria-pressed=/);
  assert.match(portal, /data-tbl="\$\{t\.table_type_id\}" \$\{full\?'disabled':''\}/);
  assert.doesNotMatch(portal, /<div class="svc/);
  for (const id of ['pn', 'pp', 'pe', 'ps', 'pt', 'pnotes', 'pconsent']) {
    assert.match(portal, new RegExp(`<label for="${id}"`));
  }
  assert.match(portal, /id="bookingFormCard"/);
  /* nestly_v747: the challenge teardown between the guard and the innerHTML is gone — the
     booking form no longer mounts a Turnstile widget. The invariant this line protects is that
     success is written into the BOOKING CARD (not the whole portal, which would blow away the
     signed-in context card), and that is still asserted here and on the next line. */
  assert.match(portal, /const bookingFormCard=\$\('bookingFormCard'\);\s*if\(!bookingFormCard\)return;\s*bookingFormCard\.innerHTML=/);
  assert.doesNotMatch(portal, /root\.querySelector\('\.card'\)\.innerHTML=`<div class="empty"><div class="big">\$\{m\.em\}/,
    'booking success must not overwrite the signed-in context card');
  assert.match(portal, /--grad:linear-gradient\(100deg,\$\{bc\},\$\{bc\}\)/);
});
