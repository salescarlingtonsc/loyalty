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
  /* nestly_v584 (owner photo 15: BRANCH and APP ACCESS written in as two new headers, and the
     two chips under each name struck out). Both facts were already on the row — one as a pill in
     a wrapped strip below the grid, the other only inside the profile — so neither could be read
     down a column, which is the whole point V226 exists for. */
  /* nestly_v603 (owner photo: APP ACCESS ringed, "move back to after commission"; and "Put here"
     against the space beside Commission, with an arrow up from the row's Edit button). Branch,
     Position and Commission are the three facts about the JOB and now sit together; the column
     about the LOGIN comes after them; the last cell carries the Edit chip, so it is named for
     nothing and its header is deliberately blank. */
  assert.deepEqual(cols, ['Name', 'Phone', 'Email', 'Branch', 'Position', 'Commission', 'App access']);
  /* The eighth cell carries the Edit chip and is named for nothing, so the matcher above (which
     requires a non-empty name) does not see it. Asserted separately so it cannot vanish. */
  assert.match(row, /data-staff-col=""[^>]*>\$\{s\.role!=='owner'\?`<span class="pill">/);
  assert.ok(!row.includes('class="pill ok">App access active'), 'the access pill left the row for the column');
  assert.ok(!row.includes('class="pill on">Inherits enabled modules'), 'and so did the module pill');
  // Header and rows share one column template, so they cannot drift apart.
  assert.match(app, /<div class="staff-col-head-v226"[^>]*><span>Name<\/span><span>Phone<\/span><span>Email<\/span><span>Branch<\/span><span>Position<\/span><span>Commission<\/span><span>App access<\/span><span><\/span><\/div>/);
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
  // V249: the owner renamed this heading to "Redeem now!" and dropped the count.
  assert.match(block, /<p class="eyebrow"[^>]*>Redeem now!<\/p>/);
  // The explanation of the scheme that was crossed out must not lead any more.
  assert.doesNotMatch(block, /How rewards work/);
  // V249: the scheme facts moved into the Points KPI card; they are still built here, after the list.
  assert.ok(block.indexOf('Redeem now!') < block.indexOf('Balance and earning'),
    'redeemable rewards come before the scheme facts');
  assert.match(block, /<summary>Balance and earning<\/summary>/);
  assert.match(block, /<b>Balance:<\/b>/);
  /* nestly_v567: the Earn sentence is built ABOVE this block now (earnLineV567), because a
     missing rate must suppress or dash the line instead of inventing "$5.00" / "0 points" —
     the block renders it via the interpolation, and the literal lives with the fail-closed
     logic. Both halves are asserted so neither can silently leave. */
  assert.match(block, /\$\{earnLineV567\}/);
  assert.match(app, /<b>Earn:<\/b>/);
  // Not-yet-earned rewards are secondary, and the empty case still says how far off.
  assert.match(block, /<summary>Coming up · \$\{pendingRewards\.length\}<\/summary>/);
  assert.match(block, /Nothing ready to redeem yet/);
  // The scanner is the action, and only when there is something to scan for.
  // V249: the scan sentence was struck out; the scanner button itself is the action, same gate.
  assert.match(block, /canWriteLoyalty&&redemptionEnabled&&readyRewards\.length\?`<a class="btn sm" href="#\/till"/);
  assert.doesNotMatch(block, /Scan the customer's pending QR/);
  // Header renamed as annotated.
  /* V254: owner confirmed the annotation on the Mumu screenshot — the card is named
     "Available Customer Programmes". Same card, same gates; the label matches what it lists. */
  assert.match(app, /<b>Available Customer Programmes<\/b>/);
  assert.doesNotMatch(app, /Balance, earning and next unlock/);
});
