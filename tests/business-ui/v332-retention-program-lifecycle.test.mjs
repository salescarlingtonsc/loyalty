/* V332 — Lifestyle bring-back rules get a real delete -> History state, overriding the V291
 * "there is deliberately still NO delete" ruling (owner: "proceed all at once"). Mirrors the
 * shape already shipped for gifts (v326), memberships (v329) and tiers (v331): a soft-delete
 * axis separate from the pre-existing Pause/Resume toggle, moving a rule to a read-only History
 * tab. See db/migrations/20260815_nestly_v332_retention_program_lifecycle.sql and
 * db/tests/v332_retention_program_lifecycle.sql (20/20 PASS, rolled back against production) for
 * the database-side proof — this file verifies the browser wiring connects to it correctly.
 *
 * retentionPage() is a standalone async function that mutates the DOM directly (routeMain.
 * innerHTML=...), so — matching the structural-pin style already used for
 * tests/business-ui/v329-membership-plan-lifecycle.test.mjs — these assertions pin the exact
 * source shape rather than executing it: the query's deleted_at inclusion, the Published/History
 * filter predicate, the confirm-gated delete flow, the exact RPC call parameters, and that the
 * draft-side editor (which has no deleted_at of its own to split on) is left untouched.
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

const retentionPageSrc = slice('async function retentionPage(', '\nfunction pbStatusChip(');

test('V332 the live-programs query includes deleted_at via select(\'*\', ...) and matches deleted rows regardless of a stale current_config_version_id', () => {
  assert.match(retentionPageSrc,
    /sb\.from\('retention_programs'\)\.select\('\*, firm_reward_taxonomy\(label,fulfillment_kind,active,sort\)'\)/);
  assert.match(retentionPageSrc,
    /\.or\(`current_config_version_id\.eq\.\$\{currentVersion\},deleted_at\.not\.is\.null`\)/);
});

test('V332 Published/History split is exactly deleted_at==null vs deleted_at!=null, only on the live (non-draft) view', () => {
  assert.match(retentionPageSrc,
    /const publishedPrograms=programs\.filter\(r=>r\.deleted_at==null\);/);
  assert.match(retentionPageSrc,
    /const historyPrograms=programs\.filter\(r=>r\.deleted_at!=null\);/);
  assert.match(retentionPageSrc, /const renderRetentionListV332=\(\)=>\{\s*\n\s*if\(draftVersionId\)return;/,
    'the draft-side editor must never call the live Published/History renderer');
});

test('V332 History rows are read-only: no edit/toggle/delete attributes, "In history" pill', () => {
  assert.match(retentionPageSrc,
    /if\(retentionTabV332==='history'\)return `<div class="row" data-retention-program-id="\$\{esc\(r\.program_id\|\|r\.id\)\}" style="padding:10px 0;border-bottom:1px solid var\(--line\)">\$\{meta\}<span class="spacer"><\/span><span class="pill off">In history<\/span><\/div>`;/);
});

test('V332 the live row keeps Edit/Pause AND gains a Delete button, all owner-gated', () => {
  const rowFn = slice('const rowHtml=r=>{', '    };');
  assert.match(rowFn,
    /\$\{isOwner\?`<button class="retentionEditLiveV291 btn ghost sm" data-id="\$\{r\.program_id\|\|r\.id\}">Edit<\/button>\s*\n\s*<button class="retentionToggleLiveV291 btn ghost sm" data-id="\$\{r\.program_id\|\|r\.id\}" data-to="\$\{!r\.active\}">\$\{r\.active\?'Pause':'Resume'\}<\/button>\s*\n\s*<button type="button" class="btn ghost sm" data-retention-delete-v332="\$\{esc\(r\.program_id\|\|r\.id\)\}">Delete<\/button>`:''\}/);
});

test('V332 delete is confirm-gated: opening it does not itself call the RPC', () => {
  const openHandler = slice(
    "document.querySelectorAll('[data-retention-delete-v332]').forEach(button=>button.onclick=()=>{",
    '    });'
  );
  assert.doesNotMatch(openHandler, /sb\.rpc/, 'opening the confirm must not itself call the delete RPC');
  assert.match(openHandler, /retentionDeletePendingV332=button\.dataset\.retentionDeleteV332;renderRetentionListV332\(\);/);
});

test('V332 confirming delete calls business_delete_retention_program_v332 with the exact migration parameter names', () => {
  assert.match(retentionPageSrc,
    /sb\.rpc\('business_delete_retention_program_v332',\{p_business:S\.biz\.id,p_program:id\}\)/);
});

test('V332 a successful delete toasts and refetches through the same refreshRetentionPanel every other write on this page already uses', () => {
  const confirmYesHandler = slice(
    "document.querySelectorAll('[data-retention-delete-yes-v332]').forEach(button=>button.onclick=async()=>{",
    '    });'
  );
  assert.match(confirmYesHandler, /toast\('Bring-back rule deleted — moved to History'\);/);
  assert.match(confirmYesHandler,
    /refreshRetentionPanel\(null,null,'Bring-back rule deleted — moved to History\.',false\);/);
});

test('V332 cancelling the delete confirm just closes it — no RPC, no refetch', () => {
  const noHandler = slice(
    "document.querySelectorAll('[data-retention-delete-no-v332]').forEach(button=>button.onclick=()=>{",
    '    });'
  );
  assert.doesNotMatch(noHandler, /sb\.rpc|refreshRetentionPanel/);
  assert.match(noHandler, /retentionDeletePendingV332='';renderRetentionListV332\(\);/);
});

test('V332 tab switching re-renders locally with no network call', () => {
  const tabHandler = slice(
    "document.querySelectorAll('[data-retention-tab-v332]').forEach(button=>button.onclick=()=>{",
    '    });'
  );
  assert.doesNotMatch(tabHandler, /sb\.rpc|sb\.from/);
  assert.match(tabHandler, /retentionTabV332=tab;retentionDeletePendingV332='';renderRetentionListV332\(\);/);
});

test('V332 read-only staff (isOwner=false) sees the Published/History tabs but no Edit/Pause/Delete controls', () => {
  const rowFn = slice('const rowHtml=r=>{', '    };');
  const controlsBranch = slice('${isOwner?`<button class="retentionEditLiveV291', "`:''}");
  assert.ok(rowFn.includes(controlsBranch.split('`:')[0]));
  const renderFn = slice('const renderRetentionListV332=()=>{', "wireLiveRetentionActionsV332();");
  assert.match(renderFn, /if\(!isOwner\)return;/,
    'the tab-switch handler must attach regardless of isOwner (tabs are read-only-safe), but delete/edit wiring must bail out before it');
});

test('V332 the delete confirmation copy states rewards/credit already granted are unaffected', () => {
  assert.match(retentionPageSrc,
    /No new visit can qualify for this rule from now on\. Rewards and credit already granted are not affected\./);
});

test('V332 the superseded V291 comment is corrected in place, not left claiming delete is impossible', () => {
  assert.doesNotMatch(app, /There is deliberately still NO delete/);
  assert.match(retentionPageSrc, /V332 override \(owner ruling, "proceed all at once"\)/);
});

test('V332 the draft-side (editable-draft) program list is untouched: no tabs, no delete, same Edit/Pause classes as before', () => {
  const draftBranch = slice(
    "${draftVersionId?(programs.length?programs.map(r=>",
    "'There are no programs in this draft.'})):''"
  );
  assert.doesNotMatch(draftBranch, /data-retention-delete-v332|data-retention-tab-v332/);
  assert.match(draftBranch, /class="btn ghost sm retentionEdit"/);
  assert.match(draftBranch, /class="btn ghost sm retentionToggle"/);
});
