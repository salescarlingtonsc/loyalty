import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260730_nestly_v116_classic_reward_projection.sql';
const mirrorPath='supabase/migrations/20260730130000_nestly_v116_classic_reward_projection.sql';

test('v116 source and deploy migration are exact forward-only mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- NESTLY v116 — CLASSIC REWARD PROJECTION/m);
  assert.doesNotMatch(
    source,
    /drop\s+(?:table|function|schema)|disable\s+row\s+level\s+security/i
  );
});

test('classic reward capability comes from the active programme without a catalog row',async()=>{
  const source=await read(sourcePath);
  const rewards=source.slice(
    source.indexOf("'rewards',"),
    source.indexOf("'activity',")
  );
  assert.match(rewards,/program\.loyalty_model='classic'/);
  assert.match(rewards,/program\.kind='points'/);
  assert.match(rewards,/program\.redeem_points>0/);
  assert.match(rewards,/program\.reward_credit_cents>0/);
  assert.match(rewards,/or exists\([\s\S]*public\.loyalty_reward_versions/);
  assert.match(rewards,/'loyalty'=any\(v_context\.enabled_modules\)/);
  assert.match(rewards,/program\.active/);
});

test('customer wallet merges the v89 classic action and renders a direct redeem control',async()=>{
  const app=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const rewards=app.slice(
    app.indexOf('const loadRewards=async()=>'),
    app.indexOf('const loadPackages=async')
  );
  assert.match(rewards,/customer_get_business_actions_v89/);
  assert.match(rewards,/redemption\?\.classic/);
  assert.match(rewards,/action_key:'classic_points'/);
  assert.match(rewards,/Show QR at counter/);
});

test('capability RPC remains customer-authenticated and does not broaden table access',async()=>{
  const source=await read(sourcePath);
  assert.match(source,/if auth\.uid\(\) is null/);
  assert.match(source,/verified customer link required/);
  assert.match(
    source,
    /revoke all on function public\.customer_portal_capabilities\(text\)[\s\S]*from public,anon,authenticated/
  );
  assert.match(
    source,
    /grant execute on function public\.customer_portal_capabilities\(text\)[\s\S]*to authenticated/
  );
  assert.doesNotMatch(source,/grant\s+(?:select|insert|update|delete)\s+on/i);
});
