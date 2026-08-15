/* V329 — Memberships gets a real delete -> History state, mirroring the loyalty gift lifecycle
 * (v326): save_membership_plan's own active/off flag (the pre-existing Enable/Disable button) is
 * unchanged; this only adds a second axis — business_delete_membership_plan_v329 — that moves a
 * plan to a read-only History tab. See docs/qa/evidence/V329-MEMBERSHIP-PLAN-LIFECYCLE-ACCEPTANCE.md
 * and db/tests/v329_membership_plan_lifecycle.sql (12/12 PASS, rolled back against production)
 * for the database-side proof; this file verifies the browser wiring connects to it correctly.
 *
 * membershipsPage() is a standalone async function that mutates the DOM directly (document.
 * querySelectorAll / $('plist').innerHTML=...) rather than growPage's pure string-building style,
 * so it cannot be exercised with the same `new Function` + synthetic-snapshot harness used for
 * tests/business-ui/v326-points-system-page.test.mjs without a DOM (no jsdom dependency in this
 * repo). These assertions instead pin the exact source shape: the RPC call parameters, the
 * Published/History filter predicate, the confirm-before-delete flow, and the read/write gating —
 * the same structural-pin style already used for v326's own "click wiring" tests.
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

const membershipsPageSrc = slice('async function membershipsPage(){', '\n}\n\n/* ---------- gift cards ---------- */');

test('V329 the plans query selects * (so deleted_at rides along with every other column)', () => {
  assert.match(membershipsPageSrc,
    /sb\.from\('membership_plans'\)\.select\('\*',\{count:'exact'\}\)\.eq\('business_id',S\.biz\.id\)/);
});

test('V329 Published/History split is exactly deleted_at==null vs deleted_at!=null', () => {
  assert.match(membershipsPageSrc, /const publishedPlans=\(plans\|\|\[\]\)\.filter\(p=>p\.deleted_at==null\);/);
  assert.match(membershipsPageSrc, /const historyPlans=\(plans\|\|\[\]\)\.filter\(p=>p\.deleted_at!=null\);/);
});

test('V329 History rows are read-only: no toggle, no delete button, "In history" pill', () => {
  const historyBranch = slice("if(plansTabV329==='history')return", 'span></div>`;');
  assert.doesNotMatch(historyBranch, /togglePlan|data-plan-delete-v329/);
  assert.match(historyBranch, /pill off">In history/);
});

test('V329 delete is confirm-gated: clicking Delete opens an inline confirm, does not call the RPC directly', () => {
  const wiring = slice(
    "document.querySelectorAll('[data-plan-delete-v329]')",
    "document.querySelectorAll('[data-plan-delete-yes-v329]')"
  );
  assert.doesNotMatch(wiring, /sb\.rpc/, 'opening the confirm must not itself call the delete RPC');
  assert.match(wiring, /plansDeletePendingV329=btn\.dataset\.planDeleteV329;renderPlansV329\(\);/);
});

test('V329 confirming delete calls business_delete_membership_plan_v329 with the exact migration parameter names', () => {
  assert.match(membershipsPageSrc,
    /sb\.rpc\('business_delete_membership_plan_v329',\{p_business:S\.biz\.id,p_plan:id\}\)/);
});

test('V329 a successful delete toasts and does a full page reload, matching every other mutation on this page', () => {
  const confirmYesHandler = slice(
    "document.querySelectorAll('[data-plan-delete-yes-v329]')",
    '});\n  };'
  );
  assert.match(confirmYesHandler, /toast\('Plan deleted — moved to History'\);/);
  assert.match(confirmYesHandler, /membershipsPage\(\);/);
});

test('V329 Cancel on the confirm just closes it — no RPC, no reload', () => {
  const noHandler = slice(
    "document.querySelectorAll('[data-plan-delete-no-v329]')",
    "document.querySelectorAll('[data-plan-delete-yes-v329]')"
  );
  assert.doesNotMatch(noHandler, /sb\.rpc|membershipsPage\(\)/);
  assert.match(noHandler, /plansDeletePendingV329='';renderPlansV329\(\);/);
});

test('V329 read-only staff (canWrite=false) gets no Delete button, and delete/tab wiring bails out before touching them', () => {
  const rowFn = slice('const rowHtml=p=>{', 'confirmOpen?\'\':\' hidden\'}>');
  assert.match(rowFn, /\$\{canWrite\?`<button class="btn ghost sm" onclick="togglePlan\('\$\{p\.id\}',\$\{!p\.active\}\)">\$\{p\.active\?'Disable':'Enable'\}<\/button>\s*<button type="button" class="btn ghost sm" data-plan-delete-v329="\$\{esc\(p\.id\)\}">Delete<\/button>`:''\}/);
  const renderFn = slice('const renderPlansV329=()=>{', 'renderPlansV329();\n  if(canWrite)window.togglePlan=');
  assert.match(renderFn, /if\(!canWrite\)return;/,
    'the tab-switch handler must attach regardless of canWrite (tabs are read-only-safe), but delete wiring must bail out before it');
});

test('V329 the Delete confirmation copy explains the renewal consequence, matching the migration header\'s own claim', () => {
  assert.match(membershipsPageSrc,
    /No new customer can join, and any current member is not renewed at their next period\. Past payments and credits are not affected\./);
});
