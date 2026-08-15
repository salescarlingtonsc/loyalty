/* V244 — owner: "ongoing program - should follow this UI UX" and "i need a Pending Program -
   for those (non) ongoing program - so business can easily set up".
   The tile itself is unchanged (the owner endorsed it); the seven tiles are now grouped into
   what is reaching customers and what still needs the owner, and a pending tile's call to
   action names the actual job. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

/* The real helpers, executed — a grouping rule asserted only by regex can be wrong and green. */
function loadHelpersV244() {
  const ongoing = topic => topic.status[1] === 'on';
  const start = app.indexOf('const growTopicActionV244=topic=>{');
  assert.notEqual(start, -1, 'growTopicActionV244 must exist');
  const body = app.slice(start, app.indexOf('\n  };', start) + 4);
  /* V301 (owner 2026-08-13: "Business owners cannot set up rewards"). The two point-engine cards
     open the setup wizard while nothing is live, so the helper asks growSetupEntryV301 first. It
     is stubbed FALSE here — that is the "programme is already live" branch, which is exactly the
     world the six assertions below describe, so every V244 expectation is preserved rather than
     weakened. The wizard branch has its own coverage in v301-programmes-setup-wizard.test.mjs. */
  /* V303 (owner 2026-08-13, third round): the wizard branch now also consults
     growTopicOngoingV244 (it says "Edit →" for a live card and "Set up →" otherwise), so the
     substitution has to replace EVERY occurrence, not the first. growSetupEntryV301 stays stubbed
     false for the same reason as V301 — these six assertions describe the non-wizard cards. */
  // eslint-disable-next-line no-eval
  const action = eval(`(${body.replace('const growTopicActionV244=', '').replace(/;$/, '')})`
    .replaceAll('growTopicOngoingV244(topic)', 'topic.status[1]===\'on\'')
    .replaceAll('growSetupEntryV301(topic.key)', 'false'));
  return { ongoing, action };
}

test('V244 only a live tone counts as ongoing; everything else is pending', () => {
  const { ongoing } = loadHelpersV244();
  assert.match(app, /const growTopicOngoingV244=topic=>topic\.status\[1\]==='on';/);
  // Every status the seven tiles can actually carry, classified.
  assert.equal(ongoing({ status: ['Active', 'on'] }), true);
  assert.equal(ongoing({ status: ['Live', 'on'] }), true);
  for (const st of [['Off', 'off'], ['Not set up', 'off'], ['Draft', 'new'],
    ['Paused', 'off'], ['Not included', 'off'], ['Active · paused', 'off']]) {
    assert.equal(ongoing({ status: st }), false, `${st[0]} is not ongoing`);
  }
});

test('V244 a pending tile says which job it is, not a generic View', () => {
  const { action } = loadHelpersV244();
  assert.equal(action({ status: ['Live', 'on'] }), 'View →');
  assert.equal(action({ status: ['Not set up', 'off'] }), 'Set up →');
  assert.equal(action({ status: ['Draft', 'new'] }), 'Finish setup →');
  assert.equal(action({ status: ['Paused', 'off'] }), 'Resume →');
  /* W6 increment 2: 'Switch to this →' promised a replacement, which is what an exclusive model
     pick was. Nothing is replaced any more — a programme is turned on beside the others. */
  assert.equal(action({ status: ['Off', 'off'] }), 'Turn on →');
  assert.equal(action({ status: ['Not included', 'off'] }), 'See plan →');
});

test('V343 the programme landing renders the owner mockup status strip and five-card grid', () => {
  const tiles = app.slice(app.indexOf('const growTilesHtmlV229='));
  assert.match(app, /growDisplayTopicsV343=growTopicDefsV229\.filter\(topic=>topic\.key!=='recurring'\)/);
  assert.match(tiles, /All \(\$\{growDisplayTopicsV343\.length\}\)/);
  assert.match(tiles, /Live \(\$\{growDisplayLiveV343\.length\}\)/);
  assert.match(tiles, /Not set up \(\$\{growDisplayPendingV343\.length\}\)/);
  assert.match(tiles, /History \(\$\{growDisplayHistoryCountV343\}\)/);
  assert.match(tiles, /<div class="grow-topic-card-grid-v343">\$\{growDisplayTopicsV343\.map\(growTileHtmlV244\)\.join\(''\)\}<\/div>/);
});

test('V343 the tile keeps its topic hook and becomes the screenshot card shape', () => {
  /* V335 (owner markup, photo 1: "remove the explanation below '3 redeemable rewards'" +
     "shift the edit button to the top right corner — applies to all"). The status-line summary
     text and the bottom "Edit →" text link are gone; the action is now a small round arrow in
     the tile's top-right corner (decorative — the action word moved to the tile's own
     aria-label instead, so assistive tech still gets it). */
  /* V343 (owner markup: "photo 1 change to become photo 2"): the tile became a compact row —
     class renamed grow-topic-row-v343, icon size 22->20, and a new name wrapper span — every
     other contract this test protects (data attr, aria-label, corner button, pill, no summary
     text) is unchanged. */
  const tile = app.slice(app.indexOf('const growTileHtmlV244='), app.indexOf('const growOngoingTopicsV244='));
  assert.match(tile, /class="grow-topic-card-v343/);
  assert.match(tile, /data-grow-topic-v229="\$\{topic\.key\}"/, 'the existing click contract survives');
  assert.match(tile, /aria-label="\$\{esc\(topic\.title\)\} — \$\{esc\(growTopicActionV244\(topic\)\)\}"/);
  assert.match(tile, /<span class="grow-topic-tile-corner-v335" aria-hidden="true">\$\{CUI\.icon\('forward',\{size:18\}\)\}<\/span>/);
  assert.match(tile, /<span class="grow-topic-tile-icon-v229">\$\{CUI\.icon\(topic\.icon,\{size:28\}\)\}<\/span>/);
  assert.match(tile, /<span class="pill \$\{topic\.status\[1\]\}">\$\{esc\(topic\.status\[0\]\)\}<\/span>/);
  assert.match(tile, /<small>\$\{esc\(topic\.blurb\)\}<\/small>/);
  assert.match(tile, /growTopicButtonLabelV343\(topic\)/);
  // Pending tiles are marked for styling without changing the tile's structure.
  assert.match(tile, /\$\{growTopicOngoingV244\(topic\)\?'':' grow-topic-tile-pending-v244'\}/);
  assert.match(shell, /\.grow-topic-tile-pending-v244\{border-style:dashed\}/);
  assert.match(shell, /\.grow-topic-card-grid-v343\{/);
  assert.match(shell, /\.grow-topic-tile-corner-v335\{/);
});

test('V244 the grid is not double-wrapped at the render site', () => {
  // Each section owns its own .grow-topic-tiles-v229 grid now.
  assert.match(app, /\$\{growTilesModeV229\?growTilesHtmlV229:''\}/);
  assert.doesNotMatch(app, /\$\{growTilesModeV229\?`<div class="grow-topic-tiles-v229">\$\{growTilesHtmlV229\}<\/div>`:''\}/);
});
