/* V221 — Products is a price list, not a warehouse.
   Owner: "i want products (not inventory tracking) - products is like selling
   1. chicken rice for $5 and cost $2".
   The page already held exactly that — name, sell price, cost, gross profit, edit — but was
   dressed as inventory: titled Inventory, subtitled with batches, expiry and FEFO, and leading
   with "Receive stock". Selling never needed stock: v8 records that insufficient stock is
   tolerated ("deduct what exists, never below zero, never raise"), so a product with no stock
   row sells normally. Stock keeping is therefore optional and folded away. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const start = app.indexOf('async function inventoryPage(){');
assert.notEqual(start, -1);
/* Comments are stripped: the note recording this very change quotes the old wording, and
   prose about a bug must never be mistaken for the bug. */
const page = app
  .slice(start, app.indexOf('\nasync function ', start + 1))
  .replace(/\/\*[\s\S]*?\*\//g, ' ');

test('V221 the page presents itself as Products, not Inventory', () => {
  assert.match(page, /<h1>Products<\/h1>/);
  assert.match(page, /What you sell and what you charge for it\. Stock keeping is optional\./);
  // The batch/expiry/FEFO framing is gone from the heading.
  assert.doesNotMatch(page, /Stock in batches with expiry/);
  assert.doesNotMatch(page, /FEFO/);
  assert.doesNotMatch(page, /<h1>Inventory<\/h1>/);
});

test('V222 the form asks only what you sell it for', () => {
  assert.match(page, /<label for="pp2">Sell for/);
  assert.match(page, /placeholder="5\.00"/);
  /* Owner: "scrap the cost - just put selling price for products - if not will be complex".
     Cost was not optional here — adding a product refused without it — so a hawker could not
     enter chicken rice without first answering a question about margin. */
  assert.doesNotMatch(page, /cost/i, 'the Products page must not ask about cost');
  assert.doesNotMatch(page, /profit/i);
  // Adding a product must not require anything beyond a name.
  const add = page.slice(page.indexOf("$('padd2').onclick"), page.indexOf("$('badd2').onclick"));
  assert.match(add, /if\(\$\('pn2'\)\.value\.trim\(\)\.length<2\) return toast\('Name required'\);/);
  assert.doesNotMatch(add, /return toast\('Add the product cost/);
  // And it must not write a cost, so no zero masquerades as a real figure.
  assert.doesNotMatch(add, /cost_cents/);
});

test('V221 stock keeping is optional and says so', () => {
  assert.match(page, /<summary>Count stock too \(optional\)<\/summary>/);
  assert.match(page, /a product with no stock recorded still sells normally/);
  // The batch controls still exist for businesses that do count goods.
  assert.match(page, /id="badd2"/);
  assert.match(page, /Receive batch/);
  // But they no longer sit above the fold as the second thing on the page.
  assert.ok(page.indexOf('id="padd2"') < page.indexOf('Count stock too'),
    'adding a product comes before counting stock');
  assert.match(page, /<b>Your products<\/b>/);
  assert.doesNotMatch(page, /<b>Stock on hand<\/b>/);
});

test('V221 empty and error states speak about products', () => {
  assert.match(page, /No products yet\. Add what you sell — for example chicken rice at/);
  assert.doesNotMatch(page, /that costs you/);
  assert.match(page, /Products could not be loaded/);
  assert.doesNotMatch(page, /Inventory could not be loaded/);
  assert.match(page, /Read-only product access/);
});
