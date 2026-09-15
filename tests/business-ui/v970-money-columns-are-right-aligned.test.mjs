import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const css=readFileSync(new URL('../../app/app.css',import.meta.url),'utf8');

/* nestly_v970 (production sweep II). A money column that is left-aligned does not just look wrong —
   the same rule that right-aligns it is the rule that gives it tabular-nums, so without the class the
   digits do not line up down the column and two amounts cannot be compared by eye. Business
   Intelligence shipped 90 money cells across 14 tables with no class at all, while the Sales ledger,
   the Daily report and Reports right-aligned every one of theirs — the same split this repo already
   closed once on the Customers table (F3, nestly_v920).

   This is a SCANNER rule rather than a list of the tables that were wrong: it reads every <table> in
   the bundle and fails on any money cell that is not right-aligned, so the next table someone writes
   is held to it too. */

const MONEY_CALL=/\$\{[^{}]*\b(?:money|scopeMoney|biMoney|studioMoney|fmtMoney)\s*\(/;
const RIGHT_ALIGNED=/\bclass\s*=\s*"[^"]*\bnum\b/;

/* Cells that legitimately hold money inside a wider sentence or next to a name. Right-aligning these
   would right-align the prose they lead with, so they are named here rather than silently skipped. */
const MIXED_CONTENT_CELLS=[
  // Packages catalogue: plan name, then the price as a muted inline span, then the service sub-line.
  '<td>${esc(k.plan_name||\'—\')} <span class="muted small">${money(k.price_cents)}</span>',
  // Business Intelligence concentration note: a full sentence that quotes a median and a mean.
  '<td colspan="3"><p class="muted small" style="margin:4px 0 0"><b>Concentration</b>',
];

function moneyCellsByTable(source){
  const tables=[];
  for(const table of source.matchAll(/<table\b[\s\S]{0,14000}?<\/table>/g)){
    const cells=[];
    for(const cell of table[0].matchAll(/<td\b([^>]*)>([\s\S]*?)<\/td>/g)){
      if(!MONEY_CALL.test(cell[2]))continue;
      if(MIXED_CONTENT_CELLS.some(allowed=>cell[0].startsWith(allowed)))continue;
      cells.push({attributes:cell[1],open:cell[0].slice(0,110),
        line:source.slice(0,table.index+cell.index).split('\n').length});
    }
    if(cells.length)tables.push(cells);
  }
  return tables;
}

test('the rule that right-aligns a money column is the one that gives it tabular figures',()=>{
  assert.match(css,/\.cui-table \.num,td\.num,th\.num\{text-align:right;font-variant-numeric:tabular-nums\}/,
    'the .num contract moved — this suite asserts against it');
});

test('every money cell in every table is right-aligned',()=>{
  const offenders=[];
  for(const cells of moneyCellsByTable(app))
    for(const cell of cells)
      if(!RIGHT_ALIGNED.test(cell.attributes))offenders.push(`app.js:${cell.line}  ${cell.open}`);
  assert.deepEqual(offenders,[],
    `${offenders.length} money cells are not right-aligned:\n  `+offenders.join('\n  '));
});

/* A second rule, because the first one can only see a cell whose money is spelled out inside it.
   "Your branches side by side" builds its amount in a helper — <td data-label="Revenue">${esc(
   revenueCellV778(row))}</td> — so the call-based scan walked straight past it and it shipped as the
   one left-aligned Revenue column on a page where sixteen others had just been squared up. A money
   column is identifiable by its LABEL however its text is produced, so this holds the label. */
const MONEY_COLUMN_LABELS=['Revenue','Outstanding','Cash collected','Identified customer revenue',
  'Revenue per visit','Average transaction value','Value'];

test('a cell in a money column is right-aligned however its text is produced',()=>{
  const offenders=[];
  for(const label of MONEY_COLUMN_LABELS){
    const cell=new RegExp(`<td data-label="${label}"([^>]*)>`,'g');
    for(const match of app.matchAll(cell)){
      if(RIGHT_ALIGNED.test(match[1]))continue;
      offenders.push(`app.js:${app.slice(0,match.index).split('\n').length}  ${match[0]}`);
    }
  }
  assert.deepEqual(offenders,[],
    `${offenders.length} cells sit in a money column without its alignment:\n  `+offenders.join('\n  '));
});

test('a money column right-aligns its header too, so the figures sit under their own label',()=>{
  /* A right-aligned column under a left-aligned header reads as two columns. Checked on the
     Business Intelligence brief, which is where the whole class lived. */
  for(const header of ['Outstanding','Value'])
    assert.match(app,new RegExp(`<th class="num">${header}</th>`),
      `the ${header} column header should carry the same alignment as its figures`);
});
