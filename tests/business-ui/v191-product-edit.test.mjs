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
  assert.match(inv, /prodEditName|prodEditPrice/);
  assert.match(inv, /update\(\{name,sku,retail_price_cents:price\}/);
});

test('V222 the Products page does not ask about cost at all', () => {
  /* Owner: "scrap the cost - just put selling price for products - if not will be complex".
     This test used to assert that a cost could be cleared and that blank was not zero. That
     nuance was real, but it belonged to a field that should never have been on this page —
     cost was REQUIRED to add a product, so a hawker could not enter chicken rice without
     first answering a question about margin. The field is gone from Products.
     cost_cents itself is untouched in the database, and cost is still collected in
     Programmes -> More reward settings, where it decides what a reward can safely cost.
     That path is asserted below, so the capability is still covered — just in one place. */
  const page = inv.replace(/\/\*[\s\S]*?\*\//g, ' ');
  assert.doesNotMatch(page, /cost/i, 'Products asks for a name and a selling price, nothing else');
  assert.doesNotMatch(page, /profit/i);

  // The one remaining place cost is entered still guards the value it writes.
  assert.match(app, /data-product-cost-save/);
  assert.match(app, /Enter a product cost, for example 24\.00/);
  assert.match(app, /p_expected_cost_cents:expectedRaw===''\?null:Number\(expectedRaw\)/,
    'blank still means "not set", never zero, on the path that survived');
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
  // V336 (owner: "some colours are not being recognised — every company have their unique
  // colour"): the fixed universal fallback is gone — the colour is now darkened toward the
  // owner's own choice instead of replaced, so the message says "darken", not "pick a darker
  // shade" (there is no longer a rejected colour to steer the owner away from).
  assert.match(app, /id="programmeColourWarning"/);
  assert.match(app, /const paintProgrammeColourWarning=/);
  const i = app.indexOf('const paintProgrammeColourWarning=');
  const src = app.slice(i, i + 900);
  assert.match(src, /contrastSafeBrandColor\(chosen\)/);
  assert.match(src, /too light for the white title text/);
  assert.match(src, /Peekaa will darken it slightly/);
  // it must warn while choosing, not only after saving
  assert.match(app, /\$\('programmeHeroColor'\)\.oninput=paintProgrammeColourWarning/);
});

test('a paused programme explains the consequence and the fix, once', () => {
  // Owner: "why already active already - but still show inactive?" — loyalty_programs.active was
  // false, so all eight rows said "Programme paused" and none said how to turn it on. Publishing
  // a config does not activate the programme; they are separate switches.
  /* V271 superseded the SENTENCE (the owner struck it with "remove wording") but not the fact it
     was protecting. The paused state is still said once, on the row that owns the switch — now as
     the status pill rather than a paragraph, and the pill is what the Ongoing filter reads. */
  assert.doesNotMatch(app, /customers earn nothing and no reward below is claimable/);
  assert.match(app, /programmeStatus\(rewardJourney\.earning\.availableToCustomers\?'Live':'Paused',rewardJourney\.earning\.availableToCustomers\?'on':'off'\)/);
  /* V314 (W6i1, 2026-08-14): still ONE master switch driving every row — that is the fact this
     assertion protects — but the switch moved. loyalty_programs.active became a published SETTING
     when the switchboard inverted, and the engine reads public.business_programmes instead, so a
     pill sourced from the old column disagreed with what customers experienced in BOTH
     directions: a firm that published active=true with no switch thrown earned nothing under a
     "Live" pill, and a firm switched on over a paused published version earned under a "Paused"
     one. Same single source, read from the spine, legacy column kept only as the fallback for a
     session that could not read it. */
  assert.match(app, /const programmeActive=spineAccruingV314===null\?loyalty\?\.active===true:spineAccruingV314;/,
    'one master switch drives every row, which is why the message belongs on the earning row');
});
