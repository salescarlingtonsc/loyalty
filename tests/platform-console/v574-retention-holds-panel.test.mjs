/* nestly_v574 — Retention holds panel on the superadmin platform console
 * (System health / #/platform/automation), alongside the WhatsApp capabilities
 * panel (see c7-whatsapp-capabilities-panel.test.mjs, same technique).
 *
 * WHY THIS TEST EXISTS. Migration 20260828_nestly_v574_retention_control_plane.sql
 * added a PLATFORM-side emergency stop layered OVER a firm's own bring-back
 * campaign switch: public.platform_list_retention_holds_v574() (read) and
 * public.platform_set_retention_hold_v574(p_business, p_campaign, p_held,
 * p_reason, p_expected_version) (write). renderAutomation() fetches the list
 * for super admins only and renders retentionHoldsSectionHtml(). This loads
 * the REAL platform-console.js module in a vm sandbox (no jsdom in this repo)
 * and executes the real exported render/payload functions against
 * stubbed RPC-shaped data, rather than grepping the source for strings.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

// Same minimal CUI stub as c7-whatsapp-capabilities-panel.test.mjs — just
// enough for the render functions under test to produce inspectable HTML.
function stubCUI(){
  return {
    card:({title,description,body})=>`<section data-card="${title}"><p>${description||''}</p>${body}</section>`,
    table:({caption,headers,rows})=>`<table data-caption="${caption||''}"><thead>${headers.map(h=>`<th>${h}</th>`).join('')}</thead><tbody>${rows.map(row=>`<tr>${row.map(cell=>`<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
    emptyState:({title,body})=>`<div data-empty-state><b>${title}</b><p>${body}</p></div>`,
    status:(text,tone)=>`<span class="pill ${tone}">${text}</span>`,
    field:({id,label})=>`<div class="cui-field" data-field-id="${id}"><label>${label}</label></div>`
  };
}

// A campaign that is still Active on the tenant's own switch, but the
// platform has HELD it — the whole point of this feature: the merchant's
// setting is untouched, only the effective outcome changes.
const ROW_HELD_BUT_TENANT_ACTIVE={
  business_id:'biz-cubbly',business_name:'Cubbly Cafe',
  campaign_id:'camp-1',campaign_name:'Absence 30d',
  tenant_active:true,platform_held:true,effective_active:false,
  business_hold:false,reason:'WABA template under review',
  version:5,business_hold_version:0,placed_at:'2026-08-27T10:00:00Z'
};
// An unheld campaign, tenant active, nothing platform-side going on.
const ROW_ALLOWED={
  business_id:'biz-kopi',business_name:'Kopi Lab',
  campaign_id:'camp-2',campaign_name:'Winback 60d',
  tenant_active:true,platform_held:false,effective_active:true,
  business_hold:false,reason:null,
  version:1,business_hold_version:0,placed_at:null
};
const SUPER_ADMIN_ACCESS=Object.freeze({role:'super_admin',modulePerms:{},scope:'all'});
const ADMIN_ACCESS=Object.freeze({role:'admin',modulePerms:{automation:'rw'},scope:'all'});
const SALES_STAFF_ACCESS=Object.freeze({role:'sales_staff',modulePerms:{automation:'rw'},scope:'own_created_or_assigned'});

test('the panel renders one row per business/campaign from stubbed list data', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.retentionHoldsPanelHtml(
    [ROW_HELD_BUT_TENANT_ACTIVE, ROW_ALLOWED], CUI, true
  );

  assert.match(html, /Retention holds/, 'the panel must carry its own title');
  assert.match(html, /Cubbly Cafe/);
  assert.match(html, /Kopi Lab/);
  assert.match(html, /Absence 30d/);
  assert.match(html, /Winback 60d/);
  const dataRows = (html.match(/<tr>/g) || []).length;
  assert.equal(dataRows, 2, 'exactly one row per business/campaign hold entry');
  assert.match(html, /data-retention-hold-campaign="biz-cubbly"/, 'each writable row exposes its campaign hold control');
  assert.match(html, /data-retention-hold-business="biz-cubbly"/, 'each writable row also exposes the firm-wide hold control');
});

test('an empty hold list renders the empty state, not a blank table', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.retentionHoldsPanelHtml([], CUI, true);
  assert.match(html, /data-empty-state/);
  assert.doesNotMatch(html, /<table/);
});

test('a held-but-tenant-active row renders tenant / platform / effective as three distinct states', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.retentionHoldRowHtml(ROW_HELD_BUT_TENANT_ACTIVE, CUI, true).join('|');

  // Tenant setting: still Active — the hold must never read as if the
  // merchant switched their own campaign off.
  assert.match(html, /Active/, 'tenant setting must still show Active');
  // Platform state: HELD.
  assert.match(html, /HELD/, 'platform state must show HELD');
  // Effective state: Stopped — the outcome the hold actually produces.
  assert.match(html, /Stopped/, 'effective state must show Stopped');
  // These must be three separately-rendered cells, not one collapsed value.
  const cells = Console.retentionHoldRowHtml(ROW_HELD_BUT_TENANT_ACTIVE, CUI, true);
  assert.equal(cells.length, 7, 'business, campaign, tenant, platform, effective, detail, actions');
  assert.match(cells[2], /Active/, 'tenant cell');
  assert.match(cells[3], /HELD/, 'platform cell');
  assert.match(cells[4], /Stopped/, 'effective cell');
});

test('an unheld row shows tenant Active, platform Allowed, effective Active', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const cells = Console.retentionHoldRowHtml(ROW_ALLOWED, CUI, true);
  assert.match(cells[2], /Active/);
  assert.match(cells[3], /Allowed/);
  assert.match(cells[4], /Active/);
});

test('the hold reason and placed-at are shown when present', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const cells = Console.retentionHoldRowHtml(ROW_HELD_BUT_TENANT_ACTIVE, CUI, true);
  assert.match(cells[5], /WABA template under review/);
  assert.match(cells[5], /Placed/);
});

test('a row with no recorded reason says so instead of rendering blank', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const cells = Console.retentionHoldRowHtml(ROW_ALLOWED, CUI, true);
  assert.match(cells[5], /No hold reason recorded/);
});

test('canWrite=false hides both the campaign and firm-wide hold controls', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.retentionHoldsPanelHtml([ROW_HELD_BUT_TENANT_ACTIVE], CUI, false);
  assert.doesNotMatch(html, /data-retention-hold-campaign/);
  assert.doesNotMatch(html, /data-retention-hold-business/);
});

test('the section is reachable for a super admin (System health route)', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.retentionHoldsSectionHtml([ROW_HELD_BUT_TENANT_ACTIVE], CUI, SUPER_ADMIN_ACCESS);
  assert.match(html, /Retention holds/);
  assert.match(html, /data-retention-hold-campaign/, 'a super admin gets the write controls too');
});

test('a non-superadmin path shows nothing — not even a read-only table', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  for (const access of [ADMIN_ACCESS, SALES_STAFF_ACCESS, null, undefined]) {
    const html = Console.retentionHoldsSectionHtml([ROW_HELD_BUT_TENANT_ACTIVE], CUI, access);
    assert.equal(html, '', `role ${access?.role ?? access} must render nothing for the retention holds panel`);
  }
});

test('holding a campaign invokes platform_set_retention_hold_v574 with the campaign id, its own version, and the reason', async () => {
  const Console = await loadConsole();
  const calls = [];
  const stubSb = {
    rpc: (name, args) => { calls.push({name, args}); return Promise.resolve({data: {status:'ok'}, error: null}); }
  };

  await Console.submitRetentionHold(stubSb, ROW_ALLOWED, {
    held: true,
    scope: 'campaign',
    reason: 'Suspicious complaint volume, pausing while we investigate.'
  });

  assert.equal(calls.length, 1, 'exactly one RPC call must be made');
  assert.equal(calls[0].name, 'platform_set_retention_hold_v574');
  assert.deepEqual({...calls[0].args}, {
    p_business: 'biz-kopi',
    p_campaign: 'camp-2',
    p_held: true,
    p_reason: 'Suspicious complaint volume, pausing while we investigate.',
    p_expected_version: 1
  });
});

test('releasing a campaign hold sends p_held=false against the same campaign id and version', async () => {
  const Console = await loadConsole();
  const calls = [];
  const stubSb = {rpc: (name, args) => { calls.push({name, args}); return Promise.resolve({data: null, error: null}); }};

  await Console.submitRetentionHold(stubSb, ROW_HELD_BUT_TENANT_ACTIVE, {
    held: false,
    scope: 'campaign',
    reason: 'WABA template approved, resuming sends.'
  });

  assert.equal(calls[0].args.p_held, false);
  assert.equal(calls[0].args.p_campaign, 'camp-1');
  assert.equal(calls[0].args.p_expected_version, 5, 'must guard on this row\'s own version');
});

test('a business-wide hold sends p_campaign=null and guards on business_hold_version, not the campaign version', async () => {
  const Console = await loadConsole();
  const calls = [];
  const stubSb = {rpc: (name, args) => { calls.push({name, args}); return Promise.resolve({data: null, error: null}); }};

  const rowWithBusinessHoldVersion = {...ROW_HELD_BUT_TENANT_ACTIVE, business_hold_version: 3};
  await Console.submitRetentionHold(stubSb, rowWithBusinessHoldVersion, {
    held: true,
    scope: 'business',
    reason: 'Firm requested a full pause during a WABA number migration.'
  });

  assert.equal(calls[0].args.p_business, 'biz-cubbly');
  assert.equal(calls[0].args.p_campaign, null, 'a firm-wide hold must pass campaign_id NULL');
  assert.equal(calls[0].args.p_expected_version, 3, 'must guard on business_hold_version, not the campaign\'s own version (5)');
});

test('the payload builder never sends an RPC by itself (pure function, no side effects)', async () => {
  const Console = await loadConsole();
  const payload = Console.retentionHoldPayload(ROW_ALLOWED, {
    held: true, scope: 'campaign', reason: 'Testing the pure builder.'
  });
  assert.deepEqual({...payload}, {
    p_business: 'biz-kopi',
    p_campaign: 'camp-2',
    p_held: true,
    p_reason: 'Testing the pure builder.',
    p_expected_version: 1
  });
});

test('the payload builder trims the reason and defaults an unrecognised scope to campaign', async () => {
  const Console = await loadConsole();
  const payload = Console.retentionHoldPayload(ROW_ALLOWED, {
    held: false, reason: '  padded reason  '
  });
  assert.equal(payload.p_reason, 'padded reason');
  assert.equal(payload.p_campaign, 'camp-2', 'no scope supplied must fall back to the campaign scope, not silently go firm-wide');
});
