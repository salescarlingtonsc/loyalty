import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('system dark mode is scoped to customer and booking surfaces',()=>{
  assert.match(app,/@media\(prefers-color-scheme:dark\)\{[\s\S]*\.customer-surface\{/);
  assert.match(app,/wallet-shell customer-shell customer-surface/);
  assert.match(app,/portal customer-surface/);
  assert.match(app,/wallet-shell customer-surface/);
  assert.match(app,/function setCustomerSurfaceDocumentV167\(\)/);
  assert.match(app,/removeAttribute\('data-customer-surface'\)/);
  assert.doesNotMatch(app,/@media\(prefers-color-scheme:dark\)\{\s*:root\{/);
  assert.doesNotMatch(app,/@media\(prefers-color-scheme:dark\)\{\s*body\{/);
});

test('customer dark tokens preserve readable controls and a fixed light QR surface',()=>{
  assert.match(app,/color-scheme:dark/);
  assert.match(app,/html\[data-customer-surface="true"\] body\{background:#0F1115\}/);
  assert.match(app,/--bg:#0F1115;--card:#191C22;--ink:#F7F4EF/);
  assert.match(app,/\.customer-surface\.portal\{--coral:#FF8A7E!important;--grad:[^}]+!important\}/);
  assert.match(app,/\.customer-surface :where\(input,select,textarea/);
  assert.match(app,/\.customer-surface \.btn\.ghost,\.customer-surface \.svc\{background:var\(--card\)/);
  assert.match(app,/\.customer-surface \.svc\.sel\{background:var\(--tint\)/);
  assert.match(app,/\.customer-surface \.redemption-qr\{color-scheme:light;background:#fff;color:#17161A/);
  assert.match(app,/\.customer-surface \.brand-logo\{filter:invert\(1\)/);
});

test('customer dark mode follows the system without adding a brittle storage preference',()=>{
  assert.doesNotMatch(app,/customer-dark-mode|peekaa[^'"\n]*theme|localStorage\.(?:getItem|setItem)\([^\n]*dark/i);
});
