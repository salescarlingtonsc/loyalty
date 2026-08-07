/* V226 — two annotated screenshots.
   (a) Staff list: the owner drew Name | phone | email | Position | Commission and wrote
       "I want clear segmentation".
   (b) Customer 360 rewards: the owner crossed the whole block out as "too confusing" and wrote
       "show Redeemable Rewards for customer". */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

test('V226 the staff list is a real grid with one header per group', () => {
  const rowStart = app.indexOf('const staffRowV209=s=>{');
  const row = app.slice(rowStart, app.indexOf('const rows=st||[];', rowStart));
  // Every field is a named cell, in the order the owner drew.
  const cols = [...row.matchAll(/data-staff-col="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(cols, ['Name', 'Phone', 'Email', 'Position', 'Commission']);
  // Header and rows share one column template, so they cannot drift apart.
  assert.match(app, /<div class="staff-col-head-v226"[^>]*><span>Name<\/span><span>Phone<\/span><span>Email<\/span><span>Position<\/span><span>Commission<\/span><\/div>/);
  assert.match(shell, /--staff-cols-v226:/);
  assert.match(shell, /\.staff-row-open\{display:grid;grid-template-columns:var\(--staff-cols-v226\)/);
  assert.match(shell, /\.staff-col-head-v226\{display:grid;grid-template-columns:var\(--staff-cols-v226\)/);
  // It must still be readable on a phone, where columns cannot survive.
  assert.match(shell, /@media \(max-width:900px\)\{\s*\.staff-row-open\{grid-template-columns:1fr\}/);
  assert.match(shell, /\.staff-col-v226::before\{content:attr\(data-staff-col\)/);
  // Position is the job title, falling back to the role rather than going blank.
  assert.match(row, /esc\(s\.title\|\|ROLE_LABELS\[s\.role\]\|\|s\.role\)/);
});

test('V226 Customer 360 leads with what this customer can redeem now', () => {
  const start = app.indexOf('const readyRewards=redemptionEnabled?');
  const block = app.slice(start, app.indexOf('  }else{', start));
  assert.match(block, /Ready to redeem now · \$\{readyRewards\.length\}/);
  // The explanation of the scheme that was crossed out must not lead any more.
  assert.doesNotMatch(block, /How rewards work/);
  assert.ok(block.indexOf('Ready to redeem now') < block.indexOf('Balance and earning'),
    'redeemable rewards come before the scheme facts');
  // Those facts are kept, just folded away — staff do occasionally need them.
  assert.match(block, /<summary>Balance and earning<\/summary>/);
  assert.match(block, /<b>Balance:<\/b>/);
  assert.match(block, /<b>Earn:<\/b>/);
  // Not-yet-earned rewards are secondary, and the empty case still says how far off.
  assert.match(block, /<summary>Coming up · \$\{pendingRewards\.length\}<\/summary>/);
  assert.match(block, /Nothing ready to redeem yet/);
  // The scanner is the action, and only when there is something to scan for.
  assert.match(block, /readyRewards\.length\?`<p class="muted small"[^`]*Scan the customer's pending QR/);
  // Header renamed as annotated.
  assert.match(app, /<b>Rewards for customer<\/b>/);
  assert.doesNotMatch(app, /Balance, earning and next unlock/);
});
