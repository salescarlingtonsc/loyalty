import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260730_nestly_v115_effective_module_projection.sql';
const mirrorPath='supabase/migrations/20260730120000_nestly_v115_effective_module_projection.sql';

test('v115 source and deploy migration are exact forward-only mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- NESTLY v115 — EFFECTIVE MODULE PROJECTION/m);
  assert.doesNotMatch(
    source,
    /drop\s+(?:table|function|schema)|disable\s+row\s+level\s+security/i
  );
});

test('tenant module discovery projects platform-effective modes instead of raw sector modules',async()=>{
  const source=await read(sourcePath);
  assert.match(source,/create or replace function app\.staff_module_perms_at_v115/i);
  assert.match(source,/app\.staff_module_mode_v94\(\s*p_business,p_branch,module_keys\.module_key/i);
  assert.match(source,/from public\.platform_module_overrides_v94/i);
  assert.match(source,/resolved\.access_mode in \('r','rw'\)/i);
  assert.match(
    source,
    /create or replace function app\.staff_module_perms\(p_business uuid\)[\s\S]*app\.staff_module_perms_at_v115\(p_business,null\)/i
  );
  assert.doesNotMatch(
    source.match(
      /create or replace function app\.staff_module_perms\(p_business uuid\)[\s\S]+?\n\$\$;/i
    )?.[0]||'',
    /unnest\(business\.enabled_modules\)|unnest\(b\.enabled_modules\)/i
  );
});

test('branch-effective module projection is authenticated RPC-only and fail-closed',async()=>{
  const source=await read(sourcePath);
  assert.match(source,/create or replace function public\.get_my_modules_at_v115/i);
  assert.match(source,/'module_perms',app\.staff_module_perms_at_v115\(p_business,p_branch\)/i);
  assert.match(source,/revoke all on function public\.get_my_modules_at_v115\(uuid,uuid\)[\s\S]*public,anon,authenticated/i);
  assert.match(source,/grant execute on function public\.get_my_modules_at_v115\(uuid,uuid\)[\s\S]*to authenticated/i);
  assert.doesNotMatch(source,/grant execute[\s\S]{0,240}to anon/i);
  assert.doesNotMatch(source,/grant execute on function app\.staff_module_perms_at_v115/i);
});

test('Quick Earn resolves every assigned branch before showing write controls',async()=>{
  const app=await read('app/index.html');
  const till=app.slice(
    app.indexOf('async function tillPage()'),
    app.indexOf('/* ---------- sales ---------- */')
  );
  assert.match(till,/sb\.rpc\('get_my_modules_at_v115'/);
  assert.match(till,/branchModulePermsById=new Map/);
  assert.match(till,/branchCanWrite\(branch\.id,'till'\)&&branchCanRead\(branch\.id,'clients'\)/);
  assert.match(till,/giftcardsReadable:branchCanRead\(tillBranchId,'giftcards'\)/);
  assert.match(till,/giftcardsWritable:branchCanWrite\(tillBranchId,'giftcards'\)/);
  assert.match(till,/wantPackages=branchCanWrite\(tillBranchId,'packages'\)/);
  assert.match(till,/wantMemberships=branchCanWrite\(tillBranchId,'memberships'\)/);
  assert.match(till,/No purchase, redemption, package use, or gift card was recorded/);
});
