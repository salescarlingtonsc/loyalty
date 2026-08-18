import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

/* v190 (owner ruling 2026-08-07): "change the background to same as business background (beige)
   instead of black; black can be adjusted in profile module if needed". The customer surface no
   longer follows the DEVICE — beige is the default for everyone, and the dark tokens below apply
   only when the customer chose them in Profile → Appearance. The tokens themselves are unchanged
   and still have to be readable, which is what the second test guards. */

test('dark is scoped to the customer surface AND opt-in, never device-driven',()=>{
  assert.doesNotMatch(app,/@media\(prefers-color-scheme:dark\)/,
    'a customer must not be flipped to dark by their phone setting');
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface,\s*\n?html\[data-customer-theme="dark"\] \.customer-offer-detail-modal \.modal-card,\s*\n?html\[data-customer-theme="dark"\] \.customer-business-detail-modal \.modal-card\{/);
  assert.match(app,/wallet-shell customer-shell customer-surface/);
  assert.match(app,/portal customer-surface/);
  assert.match(app,/wallet-shell customer-surface/);
  assert.match(app,/function setCustomerSurfaceDocumentV167\(\)/);
  assert.match(app,/removeAttribute\('data-customer-surface'\)/);
  // the business workspace must never inherit these tokens
  assert.doesNotMatch(app,/html\[data-customer-theme="dark"\]\s*:root\{/);
  assert.doesNotMatch(app,/html\[data-customer-theme="dark"\] body\{/);
});

test('customer dark tokens preserve readable controls and a fixed light QR surface',()=>{
  assert.match(app,/color-scheme:dark/);
  assert.match(app,/html\[data-customer-theme="dark"\]\[data-customer-surface="true"\] body\{background:#0F1115\}/);
  assert.match(app,/--bg:#0F1115;--card:#191C22;--ink:#F7F4EF/);
  /* The dark-surface accent is now a documented step off --brand-red rather than a loose hex,
     so it moves with the brand instead of drifting from it. */
  assert.match(app,/--brand-red-on-dark:#E4776B;/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface\.portal\{--coral:var\(--brand-red-on-dark\)!important;--grad:[^}]+!important\}/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface\.customer-surface :is\(input,select,textarea/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface \.btn\.ghost,\s*\n?html\[data-customer-theme="dark"\] \.customer-surface \.svc\{background:var\(--card\)/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface \.svc\.sel\{background:var\(--tint\)/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface \.redemption-qr\{color-scheme:light;background:#fff;color:#17161A/);
  assert.match(app,/html\[data-customer-theme="dark"\] \.customer-surface \.brand-logo\{filter:invert\(1\)/);
});

test('the preference is stored, and beige is what an untouched account gets',()=>{
  // The v167 rule was "no stored preference, follow the system". The owner reversed it: the
  // wallet must match the business app unless the customer says otherwise.
  assert.match(app,/const CUSTOMER_THEME_KEY_V190='peekaa\.customer\.theme'/);
  assert.match(app,/return CUSTOMER_THEMES_V190\.includes\(stored\)\?stored:'light'/,
    'anything unrecognised — including nothing stored — is beige');
  assert.match(app,/if\(preference!=='device'\)return false/,
    'only the explicit "match my device" choice reads prefers-color-scheme');
});
