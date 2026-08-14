import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

test('team access is discoverable and distinguishes roster-only from signed-in access',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  /* V209 (owner annotation "remove this"): the profile menu no longer links to the team page.
     Staff Members is in the sidebar, and two doors to one page is the duplicated navigation the
     owner flagged at V180. What this test protects — that team access is REACHABLE and that the
     two kinds of teammate are told apart — still holds, on the sidebar route. */
  /* V275: the Operations setup group gained a bar-only "Bottle keep" row. This assertion guards
     that the setup surfaces live HERE rather than in the account menu, not that the group is
     frozen, so the new row is admitted explicitly and everything it protects still holds. */
  assert.match(source,/items:\['staffmembers','branches','services','inventory','packages'(?:,'bottlesetup')?\]/);
  assert.match(source,/Add staff without app access/);
  assert.match(source,/No app access/);
  assert.match(source,/Invite pending/);
  assert.match(source,/App access active/);
  assert.match(source,/create_invite/);
  assert.match(source,/set_staff_module_permissions_v74/);
  assert.match(source,/Off \/ Read \/ Edit/);
});

test('workspace sessions persist on the canonical origin and local sign-out is explicit',async()=>{
  const [source,bridge,vercelRaw]=await Promise.all([Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),read('app/native-bridge.js'),read('app/vercel.json')]);
  const vercel=JSON.parse(vercelRaw);
  assert.match(source,/persistSession:true/);
  assert.match(source,/autoRefreshToken:true/);
  assert.match(source,/sb\.auth\.signOut\(\{scope:'local'\}\)/);
  assert.doesNotMatch(source,/pmSignout'[\s\S]{0,220}sb\.auth\.signOut\(\)/);
  assert.match(bridge,/publicOrigin = 'https:\/\/www\.peekaa\.asia'/);
  assert.match(source,/publicAppUrl\(`join\?token=/);
  const bareHostRedirects=vercel.redirects.filter(rule=>rule.has?.some(condition=>condition.type==='host'&&condition.value==='peekaa.asia'));
  assert.equal(bareHostRedirects.length,2);
  assert.ok(bareHostRedirects.every(rule=>rule.permanent===true&&rule.destination.startsWith('https://www.peekaa.asia/')));
});

test('owner customer preview renders published programme without customer authentication',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const editor=source.match(/async function loadCustomerProgrammePresentationEditorV95[\s\S]+?\nasync function settingsPage/)?.[0]||'';
  assert.match(editor,/id="previewCustomerProgramme"/);
  assert.match(editor,/openCustomerProgrammePreview/);
  assert.doesNotMatch(editor,/href="#\/wallet\//);
  assert.match(source,/Owner preview/);
  assert.match(source,/No customer account is required/);
});

test('Grow overview exposes the existing promotions workflow and customer projection stays capped at two',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const grow=source.match(/async function growPage[\s\S]+?\nasync function retentionPage/)?.[0]||source.match(/async function growPage[\s\S]+?\/\* ----------/)?.[0]||'';
  assert.match(grow,/programmeRow\(\{kind:'promotions'/);
  assert.match(grow,/href:'#\/promotions'/);
  assert.match(source,/customer_get_promotions_v155/);
  assert.match(source,/offers\.slice\(0,2\)|slice\(0,\s*2\)/);
});

test('reward editor can start from a product or service and shows business economics',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(source,/Reward name customers see/);
  assert.match(source,/Start from a product or service/);
  assert.match(source,/rwCatalogueSource/);
  assert.match(source,/selling price/);
  assert.match(source,/company cost/i);
  assert.match(source,/owner_list_reward_profitability_products_v122/);
  assert.match(source,/services/);
});

test('reward and tier editors preserve effective boundaries and show truthful states',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(source,/id="rwFrom" type="datetime-local"/);
  assert.match(source,/id="rwUntil" type="datetime-local"/);
  assert.match(source,/claim_available_from:boundaryInstant\(\$\('rwFrom'\)\.value\)/);
  assert.match(source,/claim_available_until:boundaryInstant\(\$\('rwUntil'\)\.value\)/);
  assert.match(source,/id="trFrom" type="datetime-local"/);
  assert.match(source,/id="trUntil" type="datetime-local"/);
  assert.match(source,/effective_from:boundaryInstant\(\$\('trFrom'\)\.value\)/);
  assert.match(source,/expires_at:boundaryInstant\(\$\('trUntil'\)\.value\)/);
  assert.match(source,/label:'Scheduled'/);
  assert.match(source,/label:'Ended'/);
  assert.match(source,/validBoundaryWindow/);
});

test('recommended tier setup creates Gold Platinum and Diamond drafts idempotently',async()=>{
  const [source,migration]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('db/migrations/20260803_nestly_v148_owner_launch_closure.sql')
  ]);
  assert.match(source,/Add recommended tiers/);
  for(const name of ['Gold','Platinum','Diamond']){
    assert.match(source,new RegExp(name));
    assert.match(migration,new RegExp(`'${name}'`));
  }
  assert.match(migration,/p_idempotency_key uuid/);
  assert.match(migration,/unique\(business_id,actor_id,idempotency_key\)/i);
  assert.match(migration,/status[^\n]*draft/i);
});

test('published tier benefits cross from owner drafts into the verified customer wallet',async()=>{
  const [source,migration]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('db/migrations/20260803_nestly_v148_owner_launch_closure.sql')
  ]);
  assert.match(source,/customer_get_effective_tier_v143/);
  assert.match(source,/presentation\.tier=effectiveTierResult\.error\s*\n?\s*\?\{unavailable:/);
  /* V174 turned the flat "Current tier benefits" section into a card; V194 split that card into
     the Tier tab (customerTierPanelMarkupV194) and folded the per-tier benefits into the ladder,
     where the owner asked for every tier's benefits, not just the customer's own. The invariant
     this test protects is unchanged: published tier benefits reach the verified wallet. */
  assert.match(source,/customerTierPanelMarkupV194\(tier\)/);
  /* v322: the ladder is called with the stack's localize flag and C3's vertical shape; the
     invariant this test protects — published benefits reach the verified wallet — is unchanged. */
  assert.match(source,/customerTierLadderMarkupV186\(tier,\{localize:localizeV310,vertical:compactV322\}\)/);
  assert.match(source,/const benefits=\(Array\.isArray\(rung\.benefits\)\?rung\.benefits:\[\]\)/);
  assert.match(source,/benefits\.map\(benefit=>`<li>\$\{esc\(benefit\)\}<\/li>`\)/);
  assert.match(migration,/create or replace function public\.customer_get_effective_tier_v143/);
  assert.match(migration,/verified customer link required/);
  assert.match(migration,/regexp_split_to_table\(coalesce\(v_current\.perk_note/);
});

test('public booking exits its skeleton on timeout and offers retry',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const portal=source.match(/async function renderPortal[\s\S]+?\nasync function boot/)?.[0]||'';
  assert.match(portal,/AbortController/);
  assert.match(portal,/portalLoadTimeout/);
  assert.match(portal,/Retry booking page/);
  assert.match(portal,/renderPortal\(slug\)/);
});

test('heavy optional browser libraries are loaded only by the workflows that need them',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(source,/warmRuntimeOrigin\(SB_URL\)/);
  assert.doesNotMatch(source,/<script[^>]+chart\.umd\.min\.js/);
  assert.doesNotMatch(source,/<script[^>]+qrcode\.min\.js/);
  assert.doesNotMatch(source,/<script[^>]+jsQR\.js/);
  assert.doesNotMatch(source,/<script[^>]+xlsx\.full\.min\.js/);
  assert.match(source,/loadOptionalLibrary/);
  assert.match(source,/loadChartLibrary/);
  assert.match(source,/loadQrLibrary/);
  assert.match(source,/loadScannerLibrary/);
  assert.match(source,/loadSpreadsheetLibrary/);
});
