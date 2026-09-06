/* Audit finding F124 — enforceRateLimit() folded the caller's IP hash into the
 * bucket key even when a scope-specific extraKey (e.g. manage-booking's token
 * hash) was supplied, so the "manage-booking-token" limiter that
 * manage-booking/index.ts relies on as its real abuse control was actually
 * keyed on (IP, token) rather than on the token alone. An attacker holding a
 * leaked management token could reset their 10-request/10-minute budget
 * against that exact token just by rotating IP.
 *
 * gateway.ts is a Deno edge function (npm: specifiers, Deno.env) and cannot be
 * imported directly under `node --test` — this repo's own public-gateway
 * tests read it as source and pin exact invariants for the same reason (see
 * tests/public-gateway/public-gateway.test.mjs). This test does the same: it
 * pins the exact fixed keyHash derivation (extraKey alone, no ipHash folded
 * in) and confirms manage-booking's own per-IP ceiling still calls
 * enforceRateLimit with NO extraKey, so that separate, intentionally
 * IP-keyed limiter is untouched by the fix.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('enforceRateLimit keys a resource-scoped limiter on the resource alone, never on (IP, resource)',async()=>{
  const gateway=await read('supabase/functions/_shared/gateway.ts');
  const fn=gateway.slice(
    gateway.indexOf('export async function enforceRateLimit'),
    gateway.indexOf('\n}',gateway.indexOf('export async function enforceRateLimit'))
  );
  // The fixed derivation: extraKey alone when supplied, ipHash(req) only as the
  // no-extraKey fallback. Must NOT combine baseHash+extraKey (the F124 bug).
  assert.match(fn,/const keyHash\s*=\s*extraKey\s*\?\s*await sha256Hex\(extraKey\)\s*:\s*await ipHash\(req\);/,
    'keyHash must be derived from extraKey alone when supplied, with no ipHash folded in');
  assert.doesNotMatch(fn,/sha256Hex\(`\$\{baseHash\}/,
    'must not reintroduce the old baseHash+extraKey concatenation the finding identified as the bug');
});

test('manage-booking keeps a SEPARATE, genuinely IP-keyed coarse ceiling alongside the per-token limiter',async()=>{
  const manageBooking=await read('supabase/functions/manage-booking/index.ts');
  // The coarse per-IP ceiling: no 5th (extraKey) argument, so it still hits ipHash(req) — this
  // limiter is DELIBERATELY per-IP and must not be affected by the per-token fix.
  assert.match(manageBooking,/enforceRateLimit\(req,\s*'manage-booking-ip',\s*60,\s*600\)/,
    'the per-IP ceiling call must have no extraKey argument');
  // The real abuse control: the 5th argument (tokenHash) makes this the one call site the F124
  // fix must protect.
  assert.match(manageBooking,/enforceRateLimit\(req,\s*'manage-booking-token',\s*10,\s*600,\s*tokenHash\)/,
    'the per-token limiter must still pass tokenHash as extraKey');
});

test('no other gateway caller passes a 5th (extraKey) argument that the F124 fix could silently affect',async()=>{
  const functionsDir=new URL('../../supabase/functions/',import.meta.url);
  const names=['public-join','public-booking','public-business-application','public-support-ticket'];
  for(const name of names){
    const source=await read(`supabase/functions/${name}/index.ts`);
    const calls=[...source.matchAll(/enforceRateLimit\(([^)]*)\)/g)].map(m=>m[1]);
    for(const args of calls){
      const argCount=args.split(',').length;
      assert.ok(argCount<=4,
        `${name}/index.ts calls enforceRateLimit with an extraKey (${args}) — the per-resource ` +
        `keying fix now applies to it too; verify that is intended`);
    }
  }
});
