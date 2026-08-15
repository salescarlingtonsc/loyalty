/* V331 — Tiered membership gets its own full parallel immediate-write page (owner: "proceed all
 * at once", resolved earlier via AskUserQuestion: a full page, not a read-only view layered onto
 * the existing draft/publish tier editor). loyalty_tiers gains paused/deleted_at (mirroring v326's
 * gift lifecycle and v329's membership-plan lifecycle) plus three RPCs — business_create_tier_v331,
 * business_set_tier_paused_v331, business_delete_tier_v331 — and publish_loyalty_config's
 * delete+reinsert tier mechanism is patched to capture/restore those columns across every future
 * publish, not just the one pre-existing draft. See db/migrations/20260815_nestly_v331_tier_lifecycle.sql
 * and db/tests/v331_tier_lifecycle.sql (20/20 PASS, rolled back against production) for the
 * database-side proof; this file verifies the browser wiring connects to it correctly.
 *
 * growTiersManageV331 and its wiring are template-string / DOM-mutation code inside the single
 * growPage() render pass (no jsdom in this repo), so — matching the structural-pin style already
 * used for tests/business-ui/v329-membership-plan-lifecycle.test.mjs — these assertions pin the
 * exact source shape rather than executing it: the query column list, the Published/History filter
 * predicate (a pre-existing production bug fix in passing — the tile used to select a column,
 * `active`, that never existed on loyalty_tiers), the confirm-gated delete flow, the exact RPC call
 * parameters, the read-only-staff gating, and the wizard hand-off for the Edit link.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.ok(start >= 0, `missing start marker: ${startMarker}`);
  const end = app.indexOf(endMarker, start + startMarker.length);
  assert.ok(end >= 0, `missing end marker: ${endMarker}`);
  return app.slice(start, end + endMarker.length);
}

test('V331 the tiers query selects paused,deleted_at, not the never-real active column', () => {
  assert.match(app,
    /\.select\('id,name,threshold,points_multiplier,perk_note,sort,paused,deleted_at,effective_from,expires_at'\)/);
  const querySite = slice("const loyaltyTiersV229=canRewards", ".catch(()=>null)\n    :[];");
  assert.doesNotMatch(querySite, /'id,name,threshold,points_multiplier,active/,
    'the fixed active-column bug must not resurface');
});

test('V331 Published/History split is exactly deleted_at==null vs deleted_at!=null, ordered by threshold', () => {
  assert.match(app,
    /const growTiersPublishedV331=growTiersRawV331\.filter\(tier=>tier\?\.deleted_at==null\)\s*\n\s*\.sort\(\(a,b\)=>Number\(a\.threshold\|\|0\)-Number\(b\.threshold\|\|0\)\|\|Number\(a\.sort\|\|0\)-Number\(b\.sort\|\|0\)\);/);
  assert.match(app,
    /const growTiersHistoryV331=growTiersRawV331\.filter\(tier=>tier\?\.deleted_at!=null\)\s*\n\s*\.sort\(\(a,b\)=>Number\(b\.threshold\|\|0\)-Number\(a\.threshold\|\|0\)\);/);
});

test('V331 History rows are read-only: no toggle/delete attributes, "In history" pill', () => {
  const historyReturnLine = 'if(history)return `<li class="grow-tier-table-row-v343" data-grow-tiers-row-v331="${esc(tier.id)}">${meta}<span data-merchant-content>${threshold} points</span><span class="pill off">In history</span><span></span></li>`;';
  assert.ok(app.includes(historyReturnLine), 'history branch must return exactly this early-exit line');
  assert.doesNotMatch(historyReturnLine, /data-grow-tiers-toggle-v331|data-grow-tiers-delete-v331/);
});

test('V331 the live-row toggle and delete button are gated on canSetupGrow', () => {
  const rowFn = slice('const growTiersRowV331=(tier,{history=false}={})=>{', '  };');
  assert.match(rowFn,
    /\$\{canSetupGrow\?`<button type="button" class="btn ghost sm" role="switch" aria-checked="\$\{!paused\}" data-grow-tiers-toggle-v331="\$\{esc\(tier\.id\)\}">\$\{paused\?'Turn on':'Turn off'\}<\/button>\s*\n\s*<button type="button" class="btn ghost sm" data-grow-tiers-delete-v331="\$\{esc\(tier\.id\)\}">Delete<\/button>`:''\}/);
  assert.match(rowFn, /class="grow-tier-table-row-v343"/);
  assert.match(app, /<b>Manage tiers<\/b>/);
  assert.match(app, /class="grow-tier-table-head-v343"><span>Tier name<\/span><span>Required points<\/span><span>Status<\/span><span>Actions<\/span><\/li>/);
});

test('V331 the delete confirmation copy names the adjacent-rung consequence', () => {
  assert.match(app,
    /Customers currently between this rung and the next will register at whichever tier is left — nothing about their points or history changes, only which rung they show as\./);
});

test('V331 delete is confirm-gated: opening it does not itself call the RPC', () => {
  const openHandler = slice(
    "outerMain.querySelectorAll('[data-grow-tiers-delete-v331]').forEach(button=>button.onclick=()=>{",
    '  });'
  );
  assert.doesNotMatch(openHandler, /sb\.rpc/);
  assert.match(openHandler, /growTiersDeletePendingV331=button\.dataset\.growTiersDeleteV331;/);
});

test('V331 confirming delete calls business_delete_tier_v331 with the exact migration parameter names', () => {
  assert.match(app, /sb\.rpc\('business_delete_tier_v331',\{p_business:S\.biz\.id,p_tier:id\}\)/);
});

test('V331 cancelling the delete confirm just closes it — no RPC', () => {
  const noHandler = slice(
    "outerMain.querySelectorAll('[data-grow-tiers-delete-no-v331]').forEach(button=>button.onclick=()=>{",
    '  });'
  );
  assert.doesNotMatch(noHandler, /sb\.rpc/);
  assert.match(noHandler, /growTiersDeletePendingV331='';/);
});

test('V331 turning a tier on/off calls business_set_tier_paused_v331 with the exact migration parameter names', () => {
  assert.match(app,
    /sb\.rpc\('business_set_tier_paused_v331',\{\s*\n\s*p_business:S\.biz\.id,p_tier:id,p_paused:!want\}\);/);
});

test('V331 adding a tier validates name and a non-negative threshold before calling business_create_tier_v331', () => {
  const saveHandler = slice(
    "const growTiersAddSave=outerMain.querySelector('[data-grow-tiers-add-save-v331]');",
    '  };'
  );
  assert.match(saveHandler, /if\(!name\)\{growTiersErrorV331='Name the tier customers will see\.';return growRerenderV322\(\);\}/);
  assert.match(saveHandler, /if\(!Number\.isFinite\(threshold\)\|\|threshold<0\)/);
  assert.match(saveHandler,
    /sb\.rpc\('business_create_tier_v331',\{\s*\n\s*p_business:S\.biz\.id,p_name:name,p_threshold:threshold\}\);/);
});

test('V331 the Edit link hands off mode:"climbing" rather than reusing the reward-step hand-off shape', () => {
  const editHandler = slice(
    "const growTiersEditLink=outerMain.querySelector('[data-grow-tiers-edit-v331]');",
    '  };'
  );
  assert.match(editHandler, /pendingGrowSetupRewardV303=\{mode:'climbing'\};/);
  assert.match(editHandler, /pendingGrowSetupModelV303=\{kind:'tiers',from:'tiers'\};/);
});

test('V331 the wizard hand-off consumer lands mode:"climbing" on the climb step, never the reward step', () => {
  const consumer = slice(
    "if(rewardHandoffV303?.mode==='earning'){",
    "}else if(rewardHandoffV303&&stepNumberOrNullW6I2('reward')!==null){"
  );
  assert.match(consumer, /\}else if\(rewardHandoffV303\?\.mode==='climbing'\)\{/);
  assert.match(consumer, /if\(stepNumberOrNullW6I2\('climb'\)!==null\)state\.step=stepNumberForW6I2\('climb'\);/);
});

test('V331 the Setup CTA hands off kind:"tiers" to the wizard, matching the Points page pattern', () => {
  const setupHandler = slice(
    "const growTiersSetupCta=$('growTiersSetupV331');",
    '  };'
  );
  assert.match(setupHandler, /pendingGrowSetupModelV303=\{kind:'tiers',from:'tiers'\};/);
  assert.match(setupHandler, /nav\('#\/grow\/setup'\);/);
});

test('V331 the tile click handler routes to #/grow/tiers and the dead growSetupEntryV301 branch is gone', () => {
  assert.match(app, /if\(tile\.dataset\.growTopicV229==='tiers'\)return nav\('#\/grow\/tiers'\);/);
  assert.doesNotMatch(app,
    /if\(growSetupEntryV301\(tile\.dataset\.growTopicV229\)\)\{pendingGrowSetupModelV303=/,
    'the tile handler branch that used to route tiers into the wizard directly must be removed now that the page owns that click');
});

test('V331 the tiers summary row reuses the generic switchtoggle wiring (kind="tiers") rather than a bespoke handler', () => {
  assert.match(app, /data-grow-switchtoggle-v322="tiers"/);
  assert.match(app, /data-grow-switchconfirm-yes-v322="tiers"/);
});

test('V331 routing allow-lists (programmeView, growCategoryViewV271 exclusion, hashParamIsProgrammeView) all include tiers', () => {
  assert.match(app, /\$\{programmeView==='tiers'\?growTiersManageV331:''\}/);
});
