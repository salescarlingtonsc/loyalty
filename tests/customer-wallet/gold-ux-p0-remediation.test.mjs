import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const app = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');

test('customer capability and profile failures stay retryable and never masquerade as missing registration', () => {
  const registration = app.match(/async function renderCustomerRegistration\(\)[\s\S]*?(?=async function renderCustomerClaim)/)?.[0] || '';
  const wallet = app.match(/async function renderCustomerWallet\([\s\S]*?(?=async function renderCustomerNotificationPreferences)/)?.[0] || '';
  assert.match(app, /if\(error\)return unavailableCustomerCapabilities\(true\)/);
  assert.match(app, /_load_error:loadError/);
  assert.match(app, /customerCapabilities\._load_error\)return renderCustomerCapabilityRetry/);
  assert.match(app, /customerFeatures\._load_error\)return renderCustomerCapabilityRetry/);
  assert.match(registration, /if\(profileError\)return renderCustomerCapabilityRetry\('We could not load your customer profile/);
  assert.doesNotMatch(registration, /profileError[\s\S]*renderCustomerWalletUnavailable/);
  assert.match(wallet, /if\(profileError\)return renderCustomerCapabilityRetry\('We could not load your customer profile/);
  assert.match(wallet, /if\(profile\?\.profile===null\)\{\s*nav\('#\/customer'\)/);
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
  assert.match(source, /close\(\);toast\('Request sent to the business'\)/);
});

test('public booking uses semantic choices, safe contrast and the exact result host', () => {
  const source = app.match(/function contrastSafeBrandColor[\s\S]*?(?=async function renderPortal)/)?.[0] || '';
  const safeColor = new Function(`${source}\nreturn contrastSafeBrandColor`)();
  assert.equal(safeColor('#000000'), '#000000');
  assert.equal(safeColor('#FFB86B'), '#C24135');
  assert.equal(safeColor('not-a-color'), '#C24135');

  const portal = app.match(/async function renderPortal[\s\S]*?(?=async function boot)/)?.[0] || '';
  assert.match(portal, /<button class="svc[^>]*type="button"[^>]*aria-pressed=/);
  assert.match(portal, /data-tbl="\$\{t\.table_type_id\}" \$\{full\?'disabled':''\}/);
  assert.doesNotMatch(portal, /<div class="svc/);
  for (const id of ['pn', 'pp', 'pe', 'ps', 'pt', 'pnotes', 'pconsent']) {
    assert.match(portal, new RegExp(`<label for="${id}"`));
  }
  assert.match(portal, /id="bookingFormCard"/);
  assert.match(portal, /const bookingFormCard=\$\('bookingFormCard'\);\s*if\(!bookingFormCard\)return;\s*bookingFormCard\.innerHTML=/);
  assert.doesNotMatch(portal, /root\.querySelector\('\.card'\)\.innerHTML=`<div class="empty"><div class="big">\$\{m\.em\}/,
    'booking success must not overwrite the signed-in context card');
  assert.match(portal, /--grad:linear-gradient\(100deg,\$\{bc\},\$\{bc\}\)/);
});
