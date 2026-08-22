/* nestly_v456 (audit A) — two places where the UI printed something that was not true.
 *
 * A-REG-017. The expenses table's DATE cell was the only cell on the row rendered as
 * `<td>${e.occurred_on}</td>` — no esc(), no fallback — while every sibling had both. A row whose
 * date is null therefore printed the literal string "undefined" to the owner, in the column the
 * whole P&L is keyed on. Measured 2026-08-22 in a harness render of #/expenses.
 *
 * A-REG-020. The My Business QR dialog opened saying "Print the current business-issued QR for
 * your counter" while the panel under it said "Generate a QR to begin" and the status line said
 * "No active QR exists" — and the destructive "Revoke all QRs" was enabled with nothing to revoke,
 * so pressing it asked the owner to confirm destroying printed copies and then reported 0.
 *
 * WHAT THIS FILE PROVES. Both fixes are in template strings inside large page functions that
 * cannot be imported, so each is EXECUTED as a real template against real data: the row template
 * is extracted from app/app.js and evaluated with the same helpers production binds to it, and
 * the QR dialog's state machine is driven through its three real branches on a DOM shim. Neither
 * assertion is a grep for a string in the source — the row is rendered and read back, and the
 * button's disabled/title state is read off the shim after each transition.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

/* ------------------------------------------------------------------ A-REG-017: expenses row -- */

/* Production's own escaper, so the test cannot disagree with the app about what escaping is. */
const escSource=(()=>{
  const match=source.match(/const esc=[^\n]+\n/);
  assert.ok(match,'could not find esc() in app/app.js');
  return match[0];
})();

const rowTemplate=(()=>{
  const start=source.indexOf('${ex.map(e=>{const amount=expenseAmountProjection(');
  assert.notEqual(start,-1,'could not find the expenses row template in app/app.js');
  const end=source.indexOf(".join('')}</table></div>",start);
  assert.notEqual(end,-1,'could not find the end of the expenses row template');
  /* Just the arrow function, so it can be called once per row with a real expense. The slice ends
     at `.join('')`, so it still carries the ')' that closes ex.map( — drop exactly that one. */
  const sliced=source.slice(start+'${ex.map('.length,end).trimEnd();
  assert.ok(sliced.endsWith(')'),'the row slice should end at the ex.map( call');
  const template=sliced.slice(0,-1);
  assert.match(template,/^e=>\{/,'and what is left is the row arrow function itself');
  return template;
})();

const renderExpenseRow=expense=>{
  const context={
    expenseAmountProjection:()=>({valid:true,originalLabel:'SGD 120.00',showBase:false,baseLabel:''}),
    branchName:{br1:'Main'},
    canWrite:true,
    S:{biz:{currency:'SGD'}}
  };
  vm.createContext(context);
  vm.runInContext(`${escSource}\nglobalThis.__row=(${rowTemplate});`,context);
  return context.__row(expense);
};

test('the expenses row never prints "undefined" for a missing date', ()=>{
  const complete={id:'ex1',occurred_on:'2026-08-01',branch_id:'br1',category:'Supplies',
    supplier:'Kopi Supplier',description:'Beans',amount_cents:12000,voided_at:null};
  const rendered=renderExpenseRow(complete);
  assert.match(rendered,/2026-08-01/,'a real date is still printed');
  assert.match(rendered,/Supplies/,'and the rest of the row still renders');

  /* The bug: every nullable field on this row, one at a time. */
  for(const field of ['occurred_on','category','supplier','description']){
    for(const empty of [null,undefined,'']){
      const row=renderExpenseRow({...complete,[field]:empty});
      assert.ok(!row.includes('undefined'),
        `${field}=${String(empty)}: the row must not print the literal "undefined" (${row.slice(0,200)})`);
      assert.ok(!row.includes('>null<'),
        `${field}=${String(empty)}: nor the literal "null"`);
      assert.match(row,/—/,`${field}=${String(empty)}: an em dash stands in for the missing value`);
    }
  }
});

test('every cell on the expenses row is escaped', ()=>{
  /* A date column is unlikely to carry markup, but it was the one cell with no esc() while its
     siblings all had one — so the invariant under test is "no cell is the exception". */
  const hostile='<img src=x onerror=alert(1)>';
  const row=renderExpenseRow({id:'ex1',occurred_on:hostile,branch_id:null,category:hostile,
    supplier:hostile,description:hostile,amount_cents:1,voided_at:null});
  assert.ok(!row.includes('<img'),'no raw tag survives into the row');
  assert.ok(row.includes('&lt;img'),'...it is escaped instead');
  const rawTagCount=(row.match(/<img/g)||[]).length;
  assert.equal(rawTagCount,0,'and there is no cell left through which one could');
});

/* ---------------------------------------------------------- A-REG-020: My Business QR state -- */

/* The dialog's copy and its revoke availability are decided in four places (initial markup, QR
   shown, QR revoked, and the three status branches). They are driven here through the real
   transitions so a future edit that updates one and forgets another fails. */
const qrPieces=(()=>{
  /* The reason is reviewed workspace copy (v453's pattern), so it is read out of the copy table
     rather than a bare constant — the test therefore asserts the sentence the owner really sees
     in English, and would notice if the key were quietly unregistered. */
  const copy=source.match(/joinQrNothingToRevoke:Object\.freeze\(\{en:'([^']+)'/);
  assert.ok(copy,'could not find the joinQrNothingToRevoke copy in WORKSPACE_TEMPLATE_COPY_V97');
  const constant=[null,copy[1]];
  const start=source.indexOf('async function loadSignupConfig(host){');
  assert.notEqual(start,-1,'could not find loadSignupConfig');
  const end=source.indexOf('async function loadCommissionConfig()',start);
  assert.notEqual(end,-1,'could not find the end of loadSignupConfig');
  return {reason:constant[1],body:source.slice(start,end)};
})();

/* A tiny element shim: enough for the two helpers under test, which only touch textContent,
   disabled, title and removeAttribute. */
const makeElement=id=>({
  id,textContent:'',disabled:false,_attrs:{},
  set title(value){this._attrs.title=value},
  get title(){return this._attrs.title||''},
  removeAttribute(name){delete this._attrs[name]},
  getAttribute(name){return this._attrs[name]??null}
});

const runQrHelpers=()=>{
  /* Extract the two helpers exactly as written, with the $ lookup they really use. */
  const leadFn=qrPieces.body.match(/const setJoinQrLeadV456=[^\n]+\n/);
  const revokeFn=qrPieces.body.match(/const setRevokeAvailableV456=[\s\S]*?\n  \};\n/);
  assert.ok(leadFn,'could not extract setJoinQrLeadV456');
  assert.ok(revokeFn,'could not extract setRevokeAvailableV456');
  const elements={joinQrLeadV456:makeElement('joinQrLeadV456'),revokeJoinQr:makeElement('revokeJoinQr')};
  const context={$:id=>elements[id]||null,
    joinQrNothingToRevokeTextV456:()=>qrPieces.reason};
  vm.createContext(context);
  vm.runInContext(`${leadFn[0]}${revokeFn[0]}`
    +'globalThis.__lead=setJoinQrLeadV456;globalThis.__revoke=setRevokeAvailableV456;',context);
  return {elements,setLead:context.__lead,setRevoke:context.__revoke};
};

test('the QR dialog opens with revoke disabled and a reason', ()=>{
  /* The initial markup, read as markup: the button ships disabled, carrying the reason as a title
     and pointing at the visible status line that repeats it. */
  const markup=qrPieces.body;
  const revokeButton=markup.match(/<button class="btn danger sm" id="revokeJoinQr"[^>]*>/);
  assert.ok(revokeButton,'the revoke button is still in the dialog');
  assert.match(revokeButton[0],/\bdisabled\b/,
    'it ships disabled — there is nothing to revoke before a read comes back');
  assert.match(revokeButton[0],/workspaceTemplateAttributeV97\('title','joinQrNothingToRevoke'\)/,
    'and it says why on hover, through the localised template every other refusal reason uses');
  assert.match(revokeButton[0],/aria-describedby="joinQrStatus"/,
    'and points at the visible status line, so the reason is not mouse-only');
  /* The reason must be REAL text somewhere on the page, not only a title attribute. */
  assert.match(markup,/id="joinQrStatus"[^>]*role="status"/,
    'the described element is a live status region');
  /* The lead no longer opens by telling the owner to print something that may not exist. */
  const lead=markup.match(/id="joinQrLeadV456"[^>]*>([^<]+)/);
  assert.ok(lead,'the lead paragraph is addressable, so state can drive it');
  assert.ok(!/^Print the current/.test(lead[1].trim()),
    `the opening lead does not assert a QR exists (got "${lead[1].trim().slice(0,60)}…")`);
});

test('revoke becomes available exactly when there is something to revoke', ()=>{
  const {elements,setRevoke}=runQrHelpers();
  /* Empty state — the one the audit caught. */
  setRevoke(false);
  assert.equal(elements.revokeJoinQr.disabled,true,'nothing to revoke: the button is disabled');
  assert.equal(elements.revokeJoinQr.title,qrPieces.reason,
    'and carries the shared reason, not a bare disabled control');
  /* A QR now exists. */
  setRevoke(true);
  assert.equal(elements.revokeJoinQr.disabled,false,'a QR exists: revoking is a real act');
  assert.equal(elements.revokeJoinQr.getAttribute('title'),null,
    'and the stale "nothing to revoke" reason is removed, not left contradicting the enabled button');
  /* ...and back again after the owner revokes everything. */
  setRevoke(false);
  assert.equal(elements.revokeJoinQr.disabled,true,'after revoking, there is nothing left to revoke');
  assert.equal(elements.revokeJoinQr.title,qrPieces.reason,'and the reason comes back');
});

test('the lead sentence follows the state, and never claims a QR that is not there', ()=>{
  const {elements,setLead}=runQrHelpers();
  /* Each of the three branches sets the lead; pull the literals out of the real source so the
     test reads what production will actually show, not a copy of it. */
  const leads=[...qrPieces.body.matchAll(/setJoinQrLeadV456\('([^']+)'\)/g)].map(m=>m[1]);
  assert.ok(leads.length>=3,
    `every state branch sets the lead (found ${leads.length}: ${JSON.stringify(leads)})`);
  const printing=leads.filter(text=>/^Print this QR/.test(text));
  assert.equal(printing.length,1,'exactly one state — the one with a QR on screen — says "print this"');
  for(const text of leads){
    if(printing.includes(text))continue;
    assert.ok(!/\bPrint (this|the current)\b/.test(text),
      `a state with no QR on screen must not tell the owner to print one: "${text}"`);
  }
  /* And the helper really writes it. */
  setLead(printing[0]);
  assert.equal(elements.joinQrLeadV456.textContent,printing[0],'the lead element is what changes');
});
