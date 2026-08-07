import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

// Geometry cannot be asserted without a layout engine, so these lock the two
// facts the fix rests on: the drop zone is the COLUMN, and the column is laid
// out so that zone actually fills the lane.

test('the drop zone is the whole lane column, not the card list inside it',async()=>{
  const source=await read('app/platform-console.js');
  const column=source.match(/<section class="platform-kanban-column" data-lane-column="\$\{lane\.key\}"[^>]*>/);
  assert.ok(column,'the onboarding lane column markup must still exist');
  assert.match(column[0],/data-lane-drop="\$\{lane\.key\}"/,
    'the lane column must carry the drop target');

  // The old target: a card list a few pixels tall in a lane holding one card.
  assert.doesNotMatch(source,/<div class="platform-card-list" data-lane-drop=/,
    'the card list must no longer be the drop target');
});

test('dragging across a card does not clear the lane highlight',async()=>{
  const source=await read('app/platform-console.js');
  const handler=source.slice(source.indexOf('zone.ondragleave='),source.indexOf('zone.ondrop='));
  // dragleave fires on the column whenever the pointer crosses into a child,
  // so an unconditional remove() makes the highlight flicker for the whole drag.
  assert.match(handler,/relatedTarget&&zone\.contains\(event\.relatedTarget\)\)return/,
    'dragleave must ignore moves into the column’s own children');
});

test('lane columns stretch so every lane is a full-height target',async()=>{
  const styles=await read('app/platform-console.css');
  const kanban=styles.match(/\.platform-kanban\{[^}]*\}/);
  assert.ok(kanban,'the kanban grid rule must exist');
  assert.match(kanban[0],/align-items:stretch/,
    'align-items:start would collapse a short lane back to its content height');

  const column=styles.match(/\.platform-kanban-column\{[^}]*\}/);
  assert.match(column[0],/display:flex/);
  assert.match(column[0],/flex-direction:column/);

  const list=styles.match(/\.platform-kanban-column>\.platform-card-list\{[^}]*\}/);
  assert.ok(list,'the stretched card-list rule must exist');
  assert.match(list[0],/flex:1 1 auto/,'the list must fill the column');
  assert.match(list[0],/min-height:72px/,'an empty lane must still be a real target');
  // Without this the stretched grid grows its implicit rows and a lane holding
  // one card renders it as a full-column slab.
  assert.match(list[0],/align-content:start/,'cards must keep their natural height');

  assert.match(styles,/\.platform-kanban-column\.is-drop-target\{|\.platform-kanban-column\.is-drop-target,/,
    'the column must show the drop highlight');
});
