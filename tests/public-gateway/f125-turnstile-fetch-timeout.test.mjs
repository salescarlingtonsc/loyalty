/* Audit finding F125 — verifyTurnstile() called Cloudflare's siteverify
 * endpoint with a bare fetch() and no AbortController/timeout, unlike every
 * other third-party-adjacent outbound fetch in this codebase (e.g.
 * app/api/offer-share.js's fetchOffer, which wraps its fetch in a 4s
 * AbortController timeout). A slow/hanging challenges.cloudflare.com would
 * block every Turnstile-gated public write (join, booking, support ticket,
 * business application) for as long as the runtime allowed.
 *
 * gateway.ts is a Deno edge function and cannot be imported directly under
 * `node --test` (npm: specifiers, Deno.env) — this repo's own public-gateway
 * tests read it as source for the same reason. This test pins the fixed
 * shape: an AbortController with a timer, the abort/network-error path
 * returning false (never throwing, never hanging), and the timer being
 * cleared either way so a fast, successful response is never held up by
 * a background timer.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function verifyTurnstileSource(){
  const gateway=await read('supabase/functions/_shared/gateway.ts');
  const start=gateway.indexOf('export async function verifyTurnstile');
  assert.ok(start>=0,'verifyTurnstile must still exist in gateway.ts');
  const end=gateway.indexOf('\nexport ',start+10);
  return gateway.slice(start,end>0?end:undefined);
}

test('verifyTurnstile wraps the siteverify fetch in an AbortController with a bounded timeout',async()=>{
  const fn=await verifyTurnstileSource();
  assert.match(fn,/new AbortController\(\)/,
    'must use an AbortController, matching app/api/offer-share.js\'s fetchOffer pattern');
  assert.match(fn,/setTimeout\(\(\)\s*=>\s*controller\.abort\(\),\s*\d+\)/,
    'must schedule an abort after a bounded timeout');
  const timeoutMs=Number(fn.match(/setTimeout\(\(\)\s*=>\s*controller\.abort\(\),\s*(\d+)\)/)?.[1]);
  assert.ok(timeoutMs>0&&timeoutMs<=10000,
    `siteverify timeout ${timeoutMs}ms should be short — a public write must fail fast, not hang`);
  assert.match(fn,/signal:\s*controller\.signal/,'the fetch call must actually pass the abort signal');
});

test('an aborted or network-failed siteverify call returns false rather than throwing or hanging',async()=>{
  const fn=await verifyTurnstileSource();
  // The fetch must be inside a try/catch that returns false on failure (an uncaught throw here
  // would propagate as a 500 instead of the clean publicError() every gateway caller expects).
  assert.match(fn,/try\s*\{[\s\S]*fetch\('https:\/\/challenges\.cloudflare\.com\/turnstile\/v0\/siteverify'/,
    'the siteverify fetch must be inside a try block');
  assert.match(fn,/\}\s*catch\s*\{\s*return false;\s*\}/,
    'a caught abort/network error must return false, matching the existing !response.ok contract');
});

test('the timeout timer is cleared on both success and failure, so it cannot fire after a fast response',async()=>{
  const fn=await verifyTurnstileSource();
  assert.match(fn,/finally\s*\{\s*clearTimeout\(timer\);\s*\}/,
    'clearTimeout must run unconditionally (finally), not only on the success path');
});
