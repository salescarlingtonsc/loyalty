/* Audit finding F127 — accounting-receipt-ocr/index.ts only checked
 * `writeError` after calling internal_record_receipt_extraction_v199, never
 * `data.updated`. That RPC (db/migrations/20260831_nestly_v661_receipt_ocr_
 * claim_lease.sql) returns {updated:false} WITHOUT a Postgres error whenever
 * the claim lease has moved on (a second worker reclaimed the same receipt
 * after the 5-minute lease expired, or already resolved it) — so a worker
 * whose write was silently dropped still reported that receipt as
 * successfully 'extracted' in the batch summary.
 *
 * This is a Deno edge function (npm: specifier, no Deno runtime under
 * `node --test`), so — matching this repo's own convention for edge
 * functions it cannot execute directly (see tests/public-gateway/
 * public-gateway.test.mjs) — this test reads the real source and pins the
 * exact fixed control flow: the RPC's `data` is captured, `data?.updated`
 * is checked, and a false updated is reported as a failure (not 'extracted')
 * without also raising a spurious error via fail().
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function processQueueSource(){
  const source=await read('supabase/functions/accounting-receipt-ocr/index.ts');
  const start=source.indexOf('async function processQueue');
  assert.ok(start>=0,'processQueue must still exist');
  // There are two internal_record_receipt_extraction_v199 call sites in this function: the
  // fail() helper (writes an error, p_extracted:null) defined near the top, and the SUCCESS
  // write this finding is about, further down. Skip past the first to reach the second.
  const firstCall=source.indexOf('internal_record_receipt_extraction_v199',start);
  assert.ok(firstCall>=0,'the extraction-recording RPC call must still exist');
  const rpcCallIndex=source.indexOf('internal_record_receipt_extraction_v199',firstCall+1);
  assert.ok(rpcCallIndex>=0,'the success-path extraction-recording RPC call must still exist');
  return source.slice(rpcCallIndex-100,rpcCallIndex+700);
}

test('the extraction-write RPC result is captured, not just its error',async()=>{
  const region=await processQueueSource();
  assert.match(region,/const\s*\{\s*data:\s*writeResult\s*,\s*error:\s*writeError\s*\}\s*=\s*await admin\.rpc\(/,
    'the RPC\'s data (not just its error) must be destructured so `updated` can be inspected');
});

test('a false `updated` is reported as a failed/stale attempt, never as "extracted"',async()=>{
  const region=await processQueueSource();
  assert.match(region,/if\s*\(!writeResult\?\.\s*updated\)\s*\{/,
    'must check writeResult.updated in addition to writeError');
  // The false-updated branch must push a non-extracted status directly (matching the shape of
  // `processed.push({receipt: receipt.id, status: 'extracted'})` below it) rather than routing
  // through fail(), which raises a real extraction_failed status the operator would investigate
  // as if the receipt genuinely could not be read — it was read fine, this worker's write just
  // lost the race.
  assert.match(region,/processed\.push\(\{\s*receipt:\s*receipt\.id\s*,\s*status:\s*'failed'\s*,\s*error:\s*'claim_lost'\s*\}\)/,
    'a lost claim must be reported with a distinguishable status/error, not silently as extracted');
  assert.match(region,/continue;/,'the loop must move on to the next receipt without falling through to the extracted push');
});

test('a genuinely successful write is still reported as extracted', async () => {
  const region = await processQueueSource();
  assert.match(region, /processed\.push\(\{\s*receipt:\s*receipt\.id\s*,\s*status:\s*'extracted'\s*\}\)/,
    'the success path must be unchanged — only a false `updated` should divert from it');
});
