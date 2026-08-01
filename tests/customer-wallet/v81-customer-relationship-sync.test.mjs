import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const sourcePath = 'db/migrations/20260726_nestly_v81_customer_relationship_sync.sql';
const canonicalPath = 'supabase/migrations/20260726160000_nestly_v81_customer_relationship_sync.sql';
const sqlTestPath = 'db/tests/v81_customer_relationship_sync.sql';
const read = (path) => readFile(new URL(path, root), 'utf8');

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(
    `create or replace function public\\.${name}\\s*\\(`, 'i'
  ));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

function customerSyncUiBlock(app) {
  const start = app.indexOf('async function syncVerifiedCustomerRelationshipsOnce');
  const end = app.indexOf('async function loadCustomerSurfaceContext', start);
  assert.ok(start >= 0 && end > start, 'customer relationship sync UI block is missing');
  return app.slice(start, end);
}

function customerSyncHarness(block, responses) {
  return Function('responses', `
    let S={user:{id:'customer-user'}};
    let customerRelationshipSyncState={userId:null,attempted:false,result:null};
    let callCount=0;
    const crypto={randomUUID:()=>\`attempt-\${callCount+1}\`};
    const sb={rpc:async()=>{callCount+=1;return responses.shift();}};
    ${block}
    return {
      sync:()=>syncVerifiedCustomerRelationshipsOnce(()=>true),
      state:()=>structuredClone(customerRelationshipSyncState),
      calls:()=>callCount,
      canRecover:()=>customerRelationshipSyncCanRecover(),
      action:()=>customerRelationshipCheckActionHtml()
    };
  `)(responses);
}

test('v81 source and canonical migrations are byte-identical forward-only contracts', async () => {
  const [source, canonical] = await Promise.all([
    read(sourcePath), read(canonicalPath)
  ]);
  assert.equal(source, canonical);
  assert.match(source, /^-- NESTLY v81[\s\S]*?\nbegin;/i);
  assert.match(source, /commit;\s*$/i);
});

test('v81 relationship sync is self-scoped, exact-match, idempotent, and count-only', async () => {
  const sql = await read(sourcePath);
  const sync = functionBlock(sql, 'customer_sync_verified_relationships_v81');
  assert.match(sync, /v_actor uuid := auth\.uid\(\)/i);
  assert.match(sync, /app\.v31_current_identity\(\)/i);
  assert.match(sync, /select[\s\S]*auth_user\.email_confirmed_at[\s\S]*auth_user\.phone_confirmed_at[\s\S]*from auth\.users/i);
  assert.match(sync, /app\.norm_phone\(v_auth_phone\)/i);
  assert.match(sync, /lower\(btrim\(client\.email\)\) = v_auth_email/i);
  assert.match(sync, /v_candidate_count <> 1/i);
  assert.match(sync, /not exists \([\s\S]*from public\.customer_links prior[\s\S]*prior\.client_id = client\.id/i);
  assert.match(sync, /operation = 'relationship_sync'[\s\S]*idempotency_key = p_idempotency_key/i);
  assert.match(sync, /length\(btrim\(p_idempotency_key\)\) not between 8 and 160/i);
  assert.match(sync, /relationship-sync-rate:[\s\S]*pg_advisory_xact_lock|pg_advisory_xact_lock[\s\S]*relationship-sync-rate:/i);
  assert.match(sync, /pg_advisory_xact_lock/i);
  for (const key of [
    'linked_count', 'already_linked_count', 'ambiguous_count',
    'matched_business_count'
  ]) assert.match(sync, new RegExp(`'${key}'`, 'i'));
  assert.doesNotMatch(sync,
    /jsonb_build_object\([\s\S]{0,300}'(?:business_slug|business_name|client_id|email|phone)'/i,
    'the public reconciliation response must expose bounded counts, not matched records');
  assert.match(sql, /'relationship_sync_linked'/i);
  assert.match(sql,
    /grant execute on function public\.customer_sync_verified_relationships_v81\(text\)\s+to authenticated/i);
  assert.doesNotMatch(sql,
    /grant execute on function public\.customer_sync_verified_relationships_v81\(text\)\s+to anon/i);
});

test('v81 history is verified-link scoped, complete, and stably paginated', async () => {
  const sql = await read(sourcePath);
  const history = functionBlock(sql, 'customer_get_transaction_history_v81');
  assert.match(history, /auth\.uid\(\)/i);
  assert.match(history, /app\.v32_customer_wallet_context\(p_business_slug\)/i);
  assert.match(history, /least\(greatest\(coalesce\(\(v_cursor->>'limit'\)::integer, 20\), 1\), 50\)/i);
  for (const key of ['before_at', 'before_order', 'before_id', 'next_cursor'])
    assert.match(history, new RegExp(`'${key}'`, 'i'));
  assert.match(history,
    /\(event_at, event_order, source_id\)\s*<\s*\(v_before_at, v_before_order, v_before_id\)/i);
  assert.match(history, /limit v_limit \+ 1/i);
  assert.match(history, /sale\.reversal_of is not null then 'reversal'/i);
  assert.match(history, /when reversal\.id is not null then 'reversed'/i);
  assert.match(history, /branch\.name as branch_name/i);
  assert.match(history, /gross_cents/i);
  assert.match(history, /net_cents/i);
  assert.match(history, /points_earned/i);
  assert.match(history, /points_redeemed/i);
  assert.match(history, /points_removed/i);
  assert.match(history, /ledger\.entry_type = 'redeem'[\s\S]*as points_redeemed/i);
  assert.match(history, /ledger\.entry_type <> 'redeem'[\s\S]*as points_removed/i);
  assert.match(history, /public\.sale_items/i);
  assert.match(history, /ledger\.sale_id is null/i,
    'sale-linked point entries must be embedded in the sale, not duplicated as standalone history');
  assert.match(history, /'source_id'/i);
  assert.match(history, /'related_source_id'/i);
  assert.doesNotMatch(history, /'client_id'|'business_id'|'auth_user_id'|'actor'/i);
  assert.match(sql,
    /grant execute on function public\.customer_get_transaction_history_v81\(text, jsonb\)\s+to authenticated/i);
});

test('customer relationship sync retries a transient failure and caches only the successful recovery', async () => {
  const app = await read('app/index.html');
  const harness = customerSyncHarness(customerSyncUiBlock(app), [
    { data: null, error: { code: '503', message: 'temporary gateway failure' } },
    { data: { outcome: 'synchronized', linked_count: 1 }, error: null }
  ]);

  const failed = await harness.sync();
  assert.equal(failed.retryable, true);
  assert.equal(failed.attempted, false);
  assert.equal(harness.state().attempted, false);
  assert.equal(harness.state().result.outcome, 'try_later');
  assert.equal(harness.canRecover(), true);
  assert.match(harness.action(), /Retry programme check/);

  const recovered = await harness.sync();
  assert.equal(recovered.linked, true);
  assert.equal(harness.calls(), 2);
  assert.equal(harness.state().attempted, true);
  assert.equal(harness.canRecover(), false);

  const cached = await harness.sync();
  assert.equal(cached.linked, true);
  assert.equal(harness.calls(), 2, 'a successful recovery may be reused for this user session');
});

test('legacy relationship sync fallback remains bounded but customer surfaces never invoke it automatically', async () => {
  const app = await read('app/index.html');
  const harness = customerSyncHarness(customerSyncUiBlock(app), [
    { data: null, error: { code: 'PGRST202', message: 'function is not in the schema cache' } }
  ]);

  const fallback = await harness.sync();
  assert.equal(fallback.backendNotApplied, true);
  assert.equal(harness.state().attempted, true);
  assert.equal(harness.canRecover(), false);
  const cachedFallback = await harness.sync();
  assert.equal(cachedFallback.backendNotApplied, true);
  assert.equal(harness.calls(), 1, 'schema-unavailable compatibility fallback remains session-cached');

  const contextStart = app.indexOf('async function loadCustomerSurfaceContext');
  const contextEnd = app.indexOf('async function renderCustomerProgrammes', contextStart);
  const context = app.slice(contextStart, contextEnd);
  assert.doesNotMatch(context,/syncVerifiedCustomerRelationshipsOnce|customer_sync_verified_relationships_v81/);
  assert.match(context,/customerSurfaceQualifies\(profile,customer\)/);
  assert.match(context,/renderNoCustomerDestination\(staff\)/);

  const noDestination = app.slice(
    app.indexOf('function renderNoCustomerDestination'),
    app.indexOf('function customerSurfaceQualifies')
  );
  assert.match(noDestination,/const relationshipRetry=customerRelationshipSyncCanRecover\(\)/);
  assert.match(noDestination,/\$\{relationshipRetry\?[\s\S]*customerRelationshipCheckActionHtml\(\)/);
  assert.match(noDestination,/if\(relationshipRetry\)wireCustomerRelationshipCheck/);
  assert.match(app,/participating business[\s\S]{0,100}scan[\s\S]{0,50}Peekaa QR/i,
    'customer guidance must direct an in-person participating-business QR join without coupling the contract to exact copy');
  assert.ok((app.match(/customerRelationshipCheckActionHtml\(\)/g)||[]).length<=2,
    'the legacy retry helper may remain as a dormant compatibility fallback but not across customer programme surfaces');
});

test('v81 rollback suite covers ambiguity, historical evidence, replay, isolation, and pagination', async () => {
  const suite = await read(sqlTestPath);
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const term of [
    'ambiguous', 'historical', 'idempotency', 'cross-business',
    'standalone', 'double-count', 'next_cursor', 'raw table', 'anon'
  ]) assert.match(suite, new RegExp(term, 'i'), `missing SQL coverage: ${term}`);
});
