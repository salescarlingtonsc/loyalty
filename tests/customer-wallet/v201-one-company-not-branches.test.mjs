import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V201 (owner): "customer just need to scan once for the business", "customer view only have 1
   company instead of multiple branch. if promo is specific to branch then state in T&C."
   Owner ruling on scope: hide branches from the customer EXCEPT on an appointment, because a
   customer who turns up at the wrong outlet has a bad day. */

const app = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', 'app/app.js'), 'utf8');

test('the customer reads promotions firm-wide, never through a workspace branch scope', () => {
  assert.match(app, /customer_get_promotions_v155',\{p_business:businessId,p_branch:null,p_locale:'en'\}/);
  // selectedBranchId is workspace state; a staff member who is also a customer must not carry
  // their branch scope into their own customer view and lose the other outlets' offers
  assert.doesNotMatch(app, /customer_get_promotions_v155'[^)]*p_branch:selectedBranchId/);
});

test('customer history does not name a branch', () => {
  assert.doesNotMatch(app,
    /walletDate\(item\.event_at,true\)\)\}\$\{item\.branch_name/,
    'points and visit history is one company, not one outlet');
});

test('an appointment still names its outlet', () => {
  // deliberate exception, per the owner's choice
  assert.ok((app.match(/item\.branch_name\?' · '\+esc\(item\.branch_name\)/g) || []).length >= 1);
  assert.match(app, /a\.branch_name\?' · '\+esc\(a\.branch_name\)/);
});

test('a sale is tagged to the branch that made it', () => {
  // "record sale will tag to the branch that done the sale" — already the contract
  assert.match(app, /sb\.rpc\('record_cart_sale',\{[\s\S]{0,200}p_branch:tillBranchId/);
});

test('a branch-specific promotion can say so in its own terms', () => {
  const card = app.slice(app.indexOf('function customerPromotionCardV104'));
  assert.match(card.slice(0, 2500), /terms/i,
    'the card must render terms, which is where a branch restriction is stated');
});
