/* V261: emit sites are now inline `typeof recordProductInteractionV100==='function'&&…`
   guards, so a surface evaluated without the core chunk cannot throw and break the user's
   action. Which events fire, where, and with what context — what these tests protect — is
   unchanged. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
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
  // V256: one RPC per event became one RPC per batch (v255). The idempotency key is still
  // minted per event and still the server's only replay guard.
  assert.match(helper,/idempotency_key:`v100:\$\{crypto\.randomUUID\(\)\}`/);
  assert.match(helper,/session_id:productInteractionSessionV100\(\)/);
  assert.match(helper,/sb\.rpc\('record_product_interactions_batch_v255',\{p_events:events\}/);
  assert.match(helper,/\.catch\(\(\)=>\{\}\)/);
  // V256: the flush must stay non-blocking and must never fall back to sendBeacon, which
  // cannot carry the Authorization header the RPC needs.
  assert.match(helper,/keepalive:true/);
  assert.doesNotMatch(helper,/sendBeacon\s*\(/);
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
  assert.doesNotMatch(till,/typeof recordProductInteractionV100==='function'&&recordProductInteractionV100\('(?:sale|loyalty)\.(?:recorded|redeemed|completed)'/);

  const scanner=between('function openMerchantRedemptionScanner','function showPendingRedemptionQr');
  assert.match(scanner,/'merchant\.redemption_scan_started'/);
  assert.doesNotMatch(scanner,/recordProductInteractionV100\([^)]*(?:completed|redeemed)/);

  const wallet=between('async function renderCustomerWallet','/* ---------- auth ---------- */');
  /* v333: `&&!silent` — a background re-read of a page the customer never left is not a view. */
  assert.match(wallet,/if\(businessId&&!silent\)typeof recordProductInteractionV100==='function'&&recordProductInteractionV100\('customer\.programme_viewed',businessId/);
  assert.doesNotMatch(wallet,/'customer\.programme_viewed',b\.id/);

  const grow=between('async function growPage','/* ---------- Bring-back playbooks');
  assert.match(grow,/'merchant\.grow_opened'/);
  assert.match(grow,/'merchant\.grow_draft_started'/);
  assert.doesNotMatch(grow,/recordProductInteractionV100\([^)]*(?:published|completed|issued)/);
});

test('v100 interaction contexts remain short allowlisted dimensions with no customer input',()=>{
  const calls=[...app.matchAll(/recordProductInteractionV100\(\s*'(?:merchant|customer)\.[^']+'[\s\S]{0,420}?context:\{([\s\S]*?)\}\s*\}\s*\)/g)];
  // V256: 7 v100 call sites plus the 9 v255 emit points; V264 adds the promotion share; V286 moves
  // the wallet's "View details" onto the Home offer sheet and re-emits the SAME v255
  // customer.promotion_opened event from the new handler — a call site, not a new event name.
  // V300 adds customer.referral_shared (channel + surface_version only — the same fixed-handful
  // channel dimension the V264 share uses; no code, no identity, no free text).
  // v386 (owner photo 9, "why cannot click to see details") makes the offer CARD open the detail
  // sheet, for the businesses whose configured CTA is "Book now" and therefore render no "View
  // details" button at all. Like V286 before it, this is a new CALL SITE re-emitting the SAME
  // customer.promotion_opened event with the same four dimensions — not a new event or dimension.
  // v393 retires Explore (owner decision), taking customer.explore_searched's ONE call site with
  // the page: 20 -> 19. The event name and exploreQueryShapeV256 stay in the registry, which is
  // asserted in tests/business-ui/v255-interaction-batching.
  assert.equal(calls.length,19);
  for(const [,context] of calls){
    // V256: query_shape is deliberately allowed and deliberately NOT the typed text — the
    // shape helper is asserted separately in tests/business-ui/v255-interaction-batching.
    assert.doesNotMatch(context,/phone|email|\bname\b|token|raw_route/i);
    assert.doesNotMatch(context,/query\s*:|search\s*:|query_text|search_text/i);
    for(const key of context.matchAll(/([a-z_]+)\s*:/g)){
      assert.ok(
        /* V264: 'channel' is which share destination the customer chose — one of a fixed handful
           (device, whatsapp, telegram, facebook, copy). It is chosen from a list the app drew, so
           it can never carry customer-typed text, and it is what makes a share countable for the
           business the owner wants this feature to help. */
        ['action_key','entry_point','locale','surface_version','outcome',
          'surface_key','promotion_id','query_shape','channel'].includes(key[1]),
        `unexpected context key ${key[1]}`
      );
    }
  }
});
