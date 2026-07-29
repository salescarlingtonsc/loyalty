import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const between=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('v100 interaction helper is UUID-scoped, privacy-minimized and fail-open',()=>{
  const helper=between('const PRODUCT_INTERACTION_EVENTS_V100','let customerFeatureCapabilities=');
  for(const event of [
    'merchant.workspace_viewed','merchant.grow_opened','merchant.grow_draft_started',
    'merchant.counter_action_opened','merchant.counter_action_started',
    'merchant.redemption_scan_started','customer.programme_viewed'
  ])assert.match(helper,new RegExp(`'${event.replaceAll('.','\\.')}'`));
  assert.match(helper,/sessionStorage\.getItem\(PRODUCT_INTERACTION_SESSION_KEY_V100\)/);
  assert.match(helper,/sessionStorage\.setItem\(PRODUCT_INTERACTION_SESSION_KEY_V100,productInteractionSessionIdV100\)/);
  assert.match(helper,/idempotencyKey=`v100:\$\{crypto\.randomUUID\(\)\}`/);
  assert.match(helper,/p_session_id:sessionId,p_idempotency_key:idempotencyKey/);
  assert.match(helper,/Promise\.resolve\(sb\.rpc\('record_product_interaction_v100'/);
  assert.match(helper,/\)\)\.catch\(\(\)=>\{\}\)/);
  assert.doesNotMatch(helper,/async function recordProductInteractionV100|await sb\.rpc/);
  for(const forbidden of ['phone','email','name','token','search','query','raw_route']){
    assert.doesNotMatch(
      between('const PRODUCT_INTERACTION_CONTEXT_KEYS_V100','const PRODUCT_INTERACTION_SESSION_KEY_V100'),
      new RegExp(`'${forbidden}'`)
    );
  }
});

test('v100 telemetry records interaction starts and views without asserting outcomes',()=>{
  const shell=between('function renderShell','const M=');
  assert.match(shell,/page\[0\]==='dashboard'[\s\S]+?'merchant\.workspace_viewed'/);

  const till=between('async function tillPage','async function salesPage');
  assert.match(till,/'merchant\.counter_action_opened'/);
  assert.match(till,/'merchant\.counter_action_started'/);
  assert.doesNotMatch(till,/recordProductInteractionV100\('(?:sale|loyalty)\.(?:recorded|redeemed|completed)'/);

  const scanner=between('function openMerchantRedemptionScanner','function showPendingRedemptionQr');
  assert.match(scanner,/'merchant\.redemption_scan_started'/);
  assert.doesNotMatch(scanner,/recordProductInteractionV100\([^)]*(?:completed|redeemed)/);

  const wallet=between('async function renderCustomerWallet','/* ---------- auth ---------- */');
  assert.match(wallet,/'customer\.programme_viewed',b\.id/);

  const grow=between('async function growPage','/* ---------- Bring-back playbooks');
  assert.match(grow,/'merchant\.grow_opened'/);
  assert.match(grow,/'merchant\.grow_draft_started'/);
  assert.doesNotMatch(grow,/recordProductInteractionV100\([^)]*(?:published|completed|issued)/);
});

test('v100 interaction contexts remain short allowlisted dimensions with no customer input',()=>{
  const calls=[...app.matchAll(/recordProductInteractionV100\('(?:merchant|customer)\.[^']+'[\s\S]{0,420}?context:\{([\s\S]*?)\}\s*\}\);/g)];
  assert.equal(calls.length,7);
  for(const [,context] of calls){
    assert.doesNotMatch(context,/phone|email|name|token|search|query|raw_route/i);
    for(const key of context.matchAll(/([a-z_]+)\s*:/g)){
      assert.ok(
        ['action_key','entry_point','locale','surface_version'].includes(key[1]),
        `unexpected context key ${key[1]}`
      );
    }
  }
});
