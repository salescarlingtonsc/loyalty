import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('a receipt identifies the company that was actually paid', () => {
  // businesses.legal_name and registration_number already existed but nothing ever asked for
  // them, so every receipt in production printed only a workspace nickname.
  assert.match(app, /id="blegal"/);
  assert.match(app, /id="buen"/);
  assert.match(app, /legal_name:legalName,registration_number:registrationNumber/);
  assert.match(app, /S\.biz\.legal_name\|\|d\.businessName\|\|S\.biz\.name/);
  assert.match(app, /Reg\. no\. \$\{esc\(S\.biz\.registration_number\)\}/);
});

test('the trading name is kept when it differs from the registered name', () => {
  assert.match(app, /trading as \$\{esc\(d\.businessName\|\|S\.biz\.name\)\}/);
  // and a non-GST business says so, rather than leaving the customer to wonder
  assert.match(app, /Not GST registered/);
});

test('the customer sees their points balance as its own line', () => {
  /* nestly_v430: the line is unit-aware now — 'Stamps balance after this visit' for a stamps
     firm. The pin follows the ternary rather than the single-unit literal. */
  assert.match(app, /\?'Stamps':'Points'\} balance after this visit/);
  assert.ok(!app.includes('· now ${d.pointsTotal} points total'),
    'the balance should not be buried in a tail clause');
});
