import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* F069 — the Add/Edit bundle dialog template never emitted a container for the "Included
   products" checkbox list, so loadBR()'s `if(canWrite&&$('bpvV488'))$('bpvV488').innerHTML=...`
   guard was permanently false: $('bpvV488') always returned null. Consequently
   `document.querySelectorAll('[data-bp-v488]')` always matched nothing, pickedProductsV488 was
   always [], and no business could ever create or edit a bundle that includes a retail product,
   even though the server (create_bundle_v488 / update_bundle_v488, both taking p_product_ids)
   fully supports it. The fix adds the missing `<div id="bpvV488">` to the template, alongside
   the existing services container `#bsv`. */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const migration = readFileSync(
  resolve(root, 'db/migrations/20260824_nestly_v488_product_bundles_and_bottle_checkpoints.sql'), 'utf8');

test('the bundle dialog template now emits the #bpvV488 "Included products" container', () => {
  const templateStart = app.indexOf('id="bundleFormModalV613"');
  assert.notEqual(templateStart, -1, 'the bundle modal template must exist');
  const templateEnd = app.indexOf('</section></div>`', templateStart);
  const template = app.slice(templateStart, templateEnd);
  assert.match(template, /<label>Included services<\/label><div id="bsv" class="small"><\/div>/,
    'the pre-existing services container must still be there, unmoved');
  assert.match(template, /<label>Included products<\/label><div id="bpvV488" class="small"><\/div>/,
    'the products container loadBR() already expects must now be in the emitted markup');
});

test('loadBR() actually finds #bpvV488 and populates it (the guard is no longer dead)', () => {
  assert.match(app,
    /if\(canWrite&&\$\('bpvV488'\)\)\$\('bpvV488'\)\.innerHTML=\(productsResultV488\.data\|\|\[\]\)\.map\(pr=>/,
    'loadBR must still populate the products checkbox list into #bpvV488');
});

test('a picked product reaches create_bundle_v488 / update_bundle_v488 as p_product_ids', () => {
  assert.match(app,
    /const pickedProductsV488=\[\.\.\.document\.querySelectorAll\('\[data-bp-v488\]'\)\]\.filter\(x=>x\.checked\)\.map\(x=>x\.dataset\.bpV488\);/,
    'the checkboxes rendered into #bpvV488 must still be collected by data-bp-v488');
  assert.match(app,
    /sb\.rpc\('create_bundle_v488',\{\s*p_business:S\.biz\.id,p_name:name,p_price_cents:priceCents,\s*p_service_ids:picked,p_product_ids:pickedProductsV488,/,
    'creating a mixed bundle must send the picked product ids as p_product_ids');
  assert.match(app,
    /sb\.rpc\('update_bundle_v488',\{p_business:S\.biz\.id,\s*p_bundle:editingBundleIdV285,p_name:name,p_price_cents:priceCents,\s*p_service_ids:picked,p_product_ids:pickedProductsV488,/,
    'editing a mixed bundle must send the picked product ids as p_product_ids');
});

test('the server RPCs this wires into really accept p_product_ids (the feature is not a client-only fiction)', () => {
  assert.match(migration,
    /create or replace function public\.create_bundle_v488\(\s*p_business uuid, p_name text, p_price_cents integer,\s*p_service_ids uuid\[\], p_product_ids uuid\[\], p_idempotency_key text\)/);
  assert.match(migration,
    /create or replace function public\.update_bundle_v488\(\s*p_business uuid, p_bundle uuid, p_name text, p_price_cents integer,\s*p_service_ids uuid\[\], p_product_ids uuid\[\], p_active boolean\)/);
  assert.match(migration, /grant execute on function public\.create_bundle_v488\([^)]*\) to authenticated;/);
  assert.match(migration, /grant execute on function public\.update_bundle_v488\([^)]*\) to authenticated;/);
});

test('opening the edit form ticks the right #bpvV488 checkboxes from the bundle\'s existing product members', () => {
  assert.match(app,
    /const includedProductsV488=new Set\(\(bundle\.bundle_items\|\|\[\]\)\.map\(item=>item\.product_id\)\.filter\(Boolean\)\);/);
  assert.match(app,
    /document\.querySelectorAll\('\[data-bp-v488\]'\)\.forEach\(box=>\{box\.checked=includedProductsV488\.has\(box\.dataset\.bpV488\)\}\);/);
});
