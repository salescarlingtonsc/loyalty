/* Audit F036 + F082 (2026-09-02): opening a stamp gift from the card GRID (the primary — and
   for a gift that sits on the card, the ONLY — way in) rebuilt growPointsAddDraftV326 with just
   {name,points,description}, dropping whereItWorks/endsOn/expiryDays. The "Where it works" input
   therefore always rendered blank, and Save sent p_where_it_works:'' — which
   business_update_reward_v326 reads as an EXPLICIT clear (nullif(btrim(''),'')) — wiping the
   owner's stored text on ANY save from that dialog, even a pure rename (F036).
   Separately, the same save handler unconditionally sent p_clear_end_date:true on every edit
   (F082), because nestly_v487 removed the dialog's own end-date field but kept sending an
   explicit clear — even though the deep reward editor's "Ends at" field can still set (and the
   Points/Stamps row can still display) a claim_available_until on the very same reward.

   These tests EXECUTE the real handlers sliced verbatim out of app/app.js (no retyping), the same
   technique the audit itself used, rather than grepping for a draft literal — that is exactly
   what let the bug through a green suite (tests/business-ui/v326-points-system-page.test.mjs
   only pinned the RESET draft `{name:'',points:'',description:'',endsOn:'',whereItWorks:''}`,
   which the grid's three-key literal never matched). */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const between = (start, end) => {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing end marker: ${end}`);
  return app.slice(from, to);
};

const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[char]);

// ---- slice 1: the real growPointsEndDateInputV472 helper (pre-fill side of nestly_v472) -------
const endDateInputHelperSrc = between(
  'const growPointsEndDateInputV472=value=>{',
  'const DATA_API_PAGE_SIZE=1000;'
);
const growPointsEndDateInputV472 = new Function(`${endDateInputHelperSrc}\nreturn growPointsEndDateInputV472;`)();

// ---- slice 2: the grid-cell opener bound to [data-grow-stamps-cell-v416] -----------------------
const gridOpenerSrc = between(
  "outerMain.querySelectorAll('[data-grow-stamps-cell-v416]').forEach(cell=>cell.onclick=()=>{",
  "/* nestly_v416: the card's length."
);

// ---- slice 3: the "Where it works" input line from the shared Add/Edit form template -----------
const whereFieldMarker = 'id="growPointsAddWhereV477"';
const whereFieldIdx = app.indexOf(whereFieldMarker);
assert.ok(whereFieldIdx >= 0, 'Where it works field must exist');
const whereFieldLine = app.slice(app.lastIndexOf('\n', whereFieldIdx) + 1, app.indexOf('\n', whereFieldIdx));

// ---- slice 4: the Add/Edit dialog's Save handler (growPointsAddSave.onclick) -------------------
const saveHandlerSrc = between(
  'if(growPointsAddSave)growPointsAddSave.onclick=async()=>{',
  '/* ---- V356: Stamp Card inline row editing'
);

function openGridCellDraft(reward) {
  /* Runs the REAL sliced grid-opener source with a fake outerMain/cell, exactly like the app's
     own event delegation, and returns whatever it wrote into growPointsAddDraftV326. */
  const cellStub = { dataset: { growStampsCellV416: String(reward.cost_points) }, onclick: null };
  const harness = new Function(
    'growStampsLevelsSortedV350', 'growPointsEndDateInputV472', 'cellStub',
    `
    let growStampsPickedV416=null,growPointsAddOpenV326='',growPointsEditingV326=null,
        growPointsAddDraftV326=null,growPointsPhotoFileV343='sentinel',growPointsRemovePhotoV343=true,
        growPointsErrorV326='pending';
    let rerendered=false;
    const growRerenderV322=()=>{rerendered=true};
    const outerMain={querySelectorAll:sel=>sel==="[data-grow-stamps-cell-v416]"?[cellStub]:[]};
    ${gridOpenerSrc}
    cellStub.onclick();
    return {draft:growPointsAddDraftV326,editing:growPointsEditingV326,rerendered,
      photoFile:growPointsPhotoFileV343,removePhoto:growPointsRemovePhotoV343,error:growPointsErrorV326};
    `
  );
  return harness(reward ? [reward] : [], growPointsEndDateInputV472, cellStub);
}

function renderWhereInputValue(draft) {
  const CUSTOMER_REWARD_WHERE_DEFAULT_V477 = 'Valid across all eligible services and locations.';
  const render = new Function('esc', 'growPointsAddDraftV326', 'CUSTOMER_REWARD_WHERE_DEFAULT_V477',
    `return \`${whereFieldLine.trim()}\`;`);
  const html = render(esc, draft, CUSTOMER_REWARD_WHERE_DEFAULT_V477);
  const match = html.match(/id="growPointsAddWhereV477"[^>]*\svalue="([^"]*)"/);
  assert.ok(match, 'rendered input must carry a value attribute');
  return match[1];
}

async function runSaveHandler({ growPointsEditingV326, whereInputValue, isStamps }) {
  const calls = [];
  const fieldValues = {
    growPointsAddNameV326: 'Free coffee (typo fixed)',   // the ONLY thing the owner touched
    growPointsAddPointsV326: '10',
    growPointsAddDescV343: 'A free coffee.',
    growPointsAddWhereV477: whereInputValue,
    growPointsAddExpiryV520: ''
  };
  const harness = new Function(
    '$', 'S', 'sb', 'isGrowCurrent', 'growRerenderV322', 'ownerErrorText',
    'uploadRewardPhotoV326', 'growStampPublishToastV433', 'GROW_STAMPS_MAX_LEN_V463',
    'growPointsIsStampsV326', 'growPointsEditingV326In', 'growPointsSpineIdV326',
    `
    let growPointsBusyV326=false,growPointsErrorV326='',growPointsEditingV326=growPointsEditingV326In,
        growPointsPhotoFileV343=null,growPointsRemovePhotoV343=false,growPointsAddDraftV326=null,
        growPointsAddOpenV326='form',growStampsPickedV416=1;
    const growPointsAddSave={};
    ${saveHandlerSrc}
    return growPointsAddSave.onclick;
    `
  )(
    id => ({ value: fieldValues[id] }),
    { biz: { id: 'biz-1' } },
    { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { ok: true }, error: null }); } },
    () => true,
    () => {},
    err => String(err),
    async () => { throw new Error('no photo expected in this test'); },
    () => {},
    15,
    isStamps,
    growPointsEditingV326,
    'spine-1'
  );
  await harness();
  return calls;
}

test('F036: opening a stamp gift from the card grid pre-fills where_it_works (and endsOn/expiryDays) exactly like the Edit-chip path', () => {
  const reward = {
    id: 'reward-1',
    customer_name: 'Free coffee',
    cost_points: 10,
    description: 'A free coffee.',
    where_it_works: 'Orchard outlet only',
    claim_available_until: '2026-12-31T15:59:59.999Z',
    entitlement_expiry_days: 7
  };
  const { draft, editing } = openGridCellDraft(reward);
  assert.equal(editing, 'reward-1');
  assert.equal(draft.whereItWorks, 'Orchard outlet only', 'grid opener must carry over where_it_works');
  assert.equal(draft.endsOn, '2026-12-31', 'grid opener must carry over the end date');
  assert.equal(draft.expiryDays, '7', 'grid opener must carry over the reward expiry');

  const rendered = renderWhereInputValue(draft);
  assert.equal(rendered, 'Orchard outlet only', 'the form must render the stored text, not a blank box');
});

test('F036: a gift with no stored where_it_works still opens with a clean, non-throwing draft', () => {
  const reward = { id: 'reward-2', customer_name: 'Free muffin', cost_points: 5, description: '' };
  const { draft } = openGridCellDraft(reward);
  assert.equal(draft.whereItWorks, '');
  assert.equal(draft.endsOn, '');
  assert.equal(draft.expiryDays, '');
});

test('F036+F082: saving a gift opened from the grid (renaming it) sends the pre-filled where_it_works unchanged and never claims the end date was cleared', async () => {
  const reward = {
    id: 'reward-1',
    customer_name: 'Free coffee',
    cost_points: 10,
    description: 'A free coffee.',
    where_it_works: 'Orchard outlet only',
    claim_available_until: '2026-12-31T15:59:59.999Z',
    entitlement_expiry_days: 7
  };
  const { draft, editing } = openGridCellDraft(reward);
  const whereInputValue = renderWhereInputValue(draft);

  const calls = await runSaveHandler({ growPointsEditingV326: editing, whereInputValue, isStamps: true });
  const updateCall = calls.find(call => call.name === 'business_update_reward_v326');
  assert.ok(updateCall, 'business_update_reward_v326 must be called');
  assert.equal(updateCall.args.p_where_it_works, 'Orchard outlet only',
    'F036 regression: a save from the grid path must not send an empty where_it_works');
  assert.equal(updateCall.args.p_clear_end_date, false,
    'F082 regression: this dialog has no end-date field, so it must never send an explicit clear');
  assert.equal(updateCall.args.p_claim_available_until, null,
    'F082 regression: null means "leave the stored end date alone"');
});
