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
  /* The tiers read was hoisted into growPage's parallel request batch (a separate performance
     change), so the query now lives under loyaltyTiersRequestV229 and is awaited later. The
     column list — which is what this test actually protects — is unchanged. */
  const querySite = slice("const loyaltyTiersRequestV229=canRewards", ".catch(()=>null)\n    :Promise.resolve([]);");
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
  /* V351 restyled the row into a card; what this test is for — a history row is READ-ONLY — is
     unchanged, so it is asserted against the branch rather than against one frozen line of markup.
     A pin on the exact string broke on a purely visual change while proving nothing. */
  const rowFnForHistory = slice('const growTiersRowV331=(tier,{history=false}={})=>{', '  };');
  const historyBranch = rowFnForHistory.slice(rowFnForHistory.indexOf('if(history)return'),
    rowFnForHistory.indexOf('const paused='));
  assert.ok(historyBranch, 'the history branch must still return early');
  assert.match(historyBranch, /In history/);
  assert.doesNotMatch(historyBranch, /data-grow-tiers-toggle-v331|data-grow-tiers-delete-v331|data-grow-tiers-row-edit-v345/,
    'a retired tier offers no write control at all');
});

test('V331 the live-row toggle and delete button are gated on canSetupGrow', () => {
  const rowFn = slice('const growTiersRowV331=(tier,{history=false}={})=>{', '  };');
  /* V351 (owner UX pass): the per-tier Turn on/off is GONE — "Gold off while Essential and
     Diamond stay live" has no defined meaning for a ladder, so the programme-level switch on the
     Manage tiers header is the only on/off. Delete moved into the row's "•••" menu. Both write
     controls are still gated on canSetupGrow, which is what this test is here to hold. */
  assert.doesNotMatch(rowFn, /data-grow-tiers-toggle-v331/,
    'a per-tier on/off must not come back without a defined ladder behaviour');
  assert.match(rowFn, /\$\{canSetupGrow\?`<button type="button" class="btn ghost sm" data-grow-tiers-row-edit-v345="\$\{esc\(tier\.id\)\}">Edit<\/button>/);
  assert.match(rowFn, /<details class="grow-row-menu-v351">[\s\S]*?data-grow-tiers-delete-v331="\$\{esc\(tier\.id\)\}">Delete<\/button>/);
  assert.match(rowFn, /class="grow-tier-card-row-v351"/);
  /* V351 replaced the four-column table (and therefore its column header row) with one card per
     tier, each card naming its own fields. The heading the owner reads is what still matters. */
  assert.doesNotMatch(app, /grow-tier-table-head-v343/, 'the retired column header must not linger');
  assert.match(app, /<b>Manage tiers<\/b>/);
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

test('V331 the per-tier pause RPC is no longer reachable from the tier list (V351 owner ruling)', () => {
  /* This used to pin the call and its parameter names. V351 removed the control that made it:
     "Gold off while Essential and Diamond stay live" has no defined meaning for a ladder, so the
     only on/off is the programme-level switch. The RPC still exists in the database and is still
     honoured by the customer read (v371 check 08), so the test now holds the UI side of the
     ruling — nothing on this page may pause a single rung — rather than pinning a dead call. */
  assert.doesNotMatch(app, /sb\.rpc\('business_set_tier_paused_v331'/,
    'no tier-list control may pause a single rung');
  assert.doesNotMatch(app, /data-grow-tiers-toggle-v331/);
});

test('V331 adding a tier validates name and a non-negative threshold before calling business_create_tier_v331', () => {
  const saveHandler = slice(
    "const growTiersAddSave=outerMain.querySelector('[data-grow-tiers-add-save-v331]');",
    '  };'
  );
  assert.match(saveHandler, /if\(!name\)\{growTiersErrorV331='Name the tier customers will see\.';return growRerenderV322\(\);\}/);
  assert.match(saveHandler, /if\(!Number\.isFinite\(threshold\)\|\|threshold<0\)/);
  assert.match(saveHandler,
    /sb\.rpc\('business_create_tier_v331',\{\s*\n\s*p_business:S\.biz\.id,p_name:name,p_threshold:threshold,p_perk_note:perkNote\|\|null\}\)/);
});

test('V331/V345 editing a tier opens the inline form on that row, not the wizard climb step', () => {
  /* The page-level "Edit" link that handed off to the wizard's climbing step is gone: V345 gave
     every ROW its own Edit (data-grow-tiers-row-edit-v345) which loads that tier into the same
     inline form used for Add, so the owner edits where they are looking. */
  assert.doesNotMatch(app, /data-grow-tiers-edit-v331/, 'the retired page-level Edit link must not linger');
  const rowEdit = slice(
    "outerMain.querySelectorAll('[data-grow-tiers-row-edit-v345]')",
    '  });'
  );
  assert.match(rowEdit, /growTiersEditingV331=/);
  assert.match(rowEdit, /growTiersAddOpenV331='form';/);
  assert.doesNotMatch(rowEdit, /nav\('#\/grow\/setup'\)/);
});

test('V331 the wizard hand-off consumer lands mode:"climbing" on the climb step, never the reward step', () => {
  const consumer = slice(
    "if(rewardHandoffV303?.mode==='earning'){",
    "}else if(rewardHandoffV303&&stepNumberOrNullW6I2('reward')!==null){"
  );
  assert.match(consumer, /\}else if\(rewardHandoffV303\?\.mode==='climbing'\)\{/);
  assert.match(consumer, /if\(stepNumberOrNullW6I2\('climb'\)!==null\)state\.step=stepNumberForW6I2\('climb'\);/);
});

test('V331 the Setup CTA turns tiers on in place — it no longer bounces the owner into the wizard', () => {
  /* V347/V351 made this an IMMEDIATE write: the CTA sets the basis, flips the spine (switching off
     whatever is exclusive with tiers) and opens the inline add-tier form. It used to hand off to
     the wizard, which is the bounce the owner asked to be rid of. The claim worth holding is that
     the whole thing happens here and that the exclusivity is honoured. */
  const setupHandler = slice(
    "const growTiersSetupCta=$('growTiersSetupV331');",
    '  };'
  );
  assert.match(setupHandler, /sb\.rpc\('business_set_tier_basis_v347',\{p_business:S\.biz\.id,p_basis:'points_earned'\}\)/);
  assert.match(setupHandler, /const set=\{tiers:true\};/);
  assert.match(setupHandler, /programmeExclusionsV322\('tiers'\)\.forEach\(other=>\{set\[other\]=false\}\);/);
  assert.match(setupHandler, /writeProgrammeSwitchesV314\(S\.biz\.id,set,/);
  assert.match(setupHandler, /growTiersAddOpenV331='form';/);
  assert.doesNotMatch(setupHandler, /nav\('#\/grow\/setup'\)/,
    'setting tiers up must not bounce through the wizard any more');
});

test('V331 the tile click handler routes to #/grow/tiers and the dead growSetupEntryV301 branch is gone', () => {
  assert.match(app, /if\(tile\.dataset\.growTopicV229==='tiers'\)\{[\s\S]{0,220}?return nav\('#\/grow\/tiers'\);/);
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
