import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const week = app.slice(app.indexOf('function renderWeek'), app.indexOf('function renderWeek') + 13000);

test('the week grid draws blocked time, not just appointments', () => {
  // Owner: "I blocked here already, why not showing?" — the block rendered in the Day view but
  // renderWeek only ever mapped calendarItems, so the week looked empty and read as a sync bug.
  assert.match(week, /const dayBlocks=days\.map\(day=>calendarBlocks\.filter/);
  assert.match(week, /dayBlocks\[index\]\.map\(block=>\{/);
  assert.match(week, /week-blocked-window/);
});

test('a week block sits behind events and never offers Remove', () => {
  const i = week.indexOf('dayBlocks[index].map');
  const src = week.slice(i, i + 700);
  assert.ok(!src.includes('data-delete-block'),
    'removal stays in the Day view, where the row is large enough to be sure what is being deleted');
  assert.match(css, /\.week-blocked-window\{[^}]*z-index:1/);
  assert.match(css, /\.week-blocked-window\{[^}]*min-height:0/);
  // Blocks must be emitted before events so an appointment always wins the visual stack.
  assert.ok(week.indexOf('dayBlocks[index].map') < week.indexOf('dayEvents[index].map'));
});
