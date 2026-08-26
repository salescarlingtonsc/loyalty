import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* nestly_v553 — the Daily report's "All sales" table total totals the table (TRUTH-001).

   The table lists EVERY row for the day — reversals and non-revenue kinds included, amounts
   signed — but its Total printed money(revenue), the revenue-policy subset. Measured on
   production (Cubbly, 22 Jul): 9 listed rows summing SGD 450.00 under a printed Total of 400.00.

   These tests EXECUTE the real total-row template lifted from app.js against fixture rows — a
   revert to money(revenue) in the first total line makes the arithmetic assertion fail; a grep
   for the label alone would stay green. (See the repo's source-regex-tests-are-vacuous rule.) */

const here=path.dirname(fileURLToPath(import.meta.url));
const app=fs.readFileSync(path.resolve(here,'../../app/app.js'),'utf8');

function totalRowsTemplate(){
  const start=app.indexOf('<tr class="total-row"><td colspan="5"><b>Total of listed rows (signed)</b>');
  assert.notEqual(start,-1,'the v553 total row is gone from the Daily report');
  const end=app.indexOf('</table></div>`',start);
  assert.notEqual(end,-1,'the all-sales table no longer closes where v553 expects');
  return app.slice(start,end);
}

const money=cents=>`SGD ${(cents/100).toFixed(2)}`;

function render(rows,revenueCents){
  // Evaluate the REAL template fragment with the same free variables the app gives it.
  const fn=new Function('rows','revenue','money','return `'+totalRowsTemplate()+'`;');
  return fn(rows,revenueCents,money);
}

/* The production shape: a gift-card sale (cash collected, NOT revenue) beside two revenue sales
   and a signed reversal. Listed sum 450.00; revenue subset 400.00. */
const DAY=[
  {amount_cents:25000,kind:'service',counts_as_revenue:true},
  {amount_cents:20000,kind:'quick_sale',counts_as_revenue:true},
  {amount_cents:5000,kind:'gift_card',counts_as_revenue:false},
  {amount_cents:-5000,kind:'service',counts_as_revenue:true,reversal_of:'x'},
];
const REVENUE=40000;

test('V553 the Total line equals the sum of the listed signed amounts, not the revenue subset',()=>{
  const html=render(DAY,REVENUE);
  assert.match(html,/Total of listed rows \(signed\)<\/b><\/td><td class="num"><b>SGD 450\.00<\/b>/,
    'the first total line must sum the column above it (450.00), and 400.00 here is the TRUTH-001 defect back again');
});

test('V553 the revenue subset is its own labelled line, so both quantities stay visible',()=>{
  const html=render(DAY,REVENUE);
  assert.match(html,/Of which revenue \(per sale policy\)<\/td><td class="num">SGD 400\.00</);
});

test('V553 a day where every row is revenue shows the two lines agreeing',()=>{
  const rows=[{amount_cents:1000,counts_as_revenue:true},{amount_cents:2500,counts_as_revenue:true}];
  const html=render(rows,3500);
  assert.match(html,/SGD 35\.00<\/b>/);
  assert.match(html,/Of which revenue \(per sale policy\)<\/td><td class="num">SGD 35\.00</);
});
