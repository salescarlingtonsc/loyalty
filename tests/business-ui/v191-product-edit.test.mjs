import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const inv = app.slice(app.indexOf('async function inventoryPage'), app.indexOf('async function inventoryPage') + 20000);

test('a mistyped product can be corrected', () => {
  // Owner: "how to edit and delete pricing or edit information etc". Products could only be
  // created — and a whole café menu now lives here after the V188 migration.
  assert.match(inv, /data-prod-edit=/);
  assert.match(inv, /data-prod-save=/);
  assert.match(inv, /prodEditName|prodEditPrice|prodEditCost/);
  assert.match(inv, /update\(\{name,sku,retail_price_cents:price,cost_cents:cost\}\)/);
});

test('cost may be cleared, and blank is not the same as zero', () => {
  const i = inv.indexOf("const costRaw=");
  const src = inv.slice(i, i + 260);
  assert.match(src, /costRaw===''\?null:/);
  assert.match(inv, /Cost must be 0 or more, or left blank/);
});

test('products are disabled, never deleted', () => {
  // product_stock, stock batches and past sale lines all reference the row.
  assert.match(inv, /data-prod-toggle=/);
  assert.ok(!/from\('products'\)\.delete/.test(inv),
    'deleting a product would orphan stock and past sale references');
  assert.match(inv, /Past sales keep the price they were sold at/);
});

test('a brand colour that cannot be used says so instead of silently changing', () => {
  // Owner: "changed colour but nothing shows". The colour saved (#F5EC00 is in production) but
  // the customer hero paints white text on it, so contrastSafeBrandColor substituted the
  // fallback with no explanation anywhere.
  assert.match(app, /id="programmeColourWarning"/);
  assert.match(app, /const paintProgrammeColourWarning=/);
  const i = app.indexOf('const paintProgrammeColourWarning=');
  const src = app.slice(i, i + 900);
  assert.match(src, /contrastSafeBrandColor\(chosen\)/);
  assert.match(src, /too light for the white title text/);
  assert.match(src, /Pick a darker shade/);
  // it must warn while choosing, not only after saving
  assert.match(app, /\$\('programmeHeroColor'\)\.oninput=paintProgrammeColourWarning/);
});

test('a paused programme explains the consequence and the fix, once', () => {
  // Owner: "why already active already - but still show inactive?" — loyalty_programs.active was
  // false, so all eight rows said "Programme paused" and none said how to turn it on. Publishing
  // a config does not activate the programme; they are separate switches.
  assert.match(app, /Paused — customers earn nothing and no reward below is claimable\. Open Edit to turn it on\./);
  assert.match(app, /const programmeActive=loyalty\?\.active===true/,
    'one master switch drives every row, which is why the message belongs on the earning row');
});
