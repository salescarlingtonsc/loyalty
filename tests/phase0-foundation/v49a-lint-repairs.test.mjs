import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const [source,deploy,fixture]=await Promise.all([
  readFile(new URL('db/migrations/20260722_frenly_v49a_lint_and_rehearsal_repairs.sql',root),'utf8'),
  readFile(new URL('supabase/migrations/20260722140000_frenly_v49a_lint_and_rehearsal_repairs.sql',root),'utf8'),
  readFile(new URL('db/tests/v49a_lint_and_rehearsal_repairs.sql',root),'utf8')
]);

test('v49a is a byte-identical atomic forward migration after v49',()=>{
  assert.equal(deploy,source);
  assert.equal((source.match(/^begin;$/gim)||[]).length,1);
  assert.equal((source.match(/^commit;$/gim)||[]).length,1);
  assert.match(source,/pg_get_functiondef\([\s\S]*reclassify_sale_policy/);
  assert.match(source,/unexpected reclassify_sale_policy predecessor definition/);
  assert.match(source,/unexpected reverse_sale_v20_base predecessor definition/);
  assert.match(source,/unexpected save_loyalty_reward_draft predecessor definition/);
});

test('v49a repairs the five findings without weakening attributes or ACLs',()=>{
  assert.match(source,/v_reversal_ids uuid\[\] := ''\{\}''::uuid\[\];/);
  assert.match(source,/v_payment_ids uuid\[\] := ''\{\}''::uuid\[\];/);
  assert.match(source,/v_needle := E'  v_key text;\\n'/);
  assert.match(source,/v_now timestamptz := statement_timestamp\(\)/);
  assert.doesNotMatch(source,/clock_timestamp\(\)/);
  assert.match(source,/create or replace function app\.suggest_appointment_reschedule_v48[\s\S]*stable[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(source,/revoke all privileges on function app\.suggest_appointment_reschedule_v48[\s\S]*from public, anon, authenticated/i);
  assert.match(source,/revoke all privileges on function public\.reverse_sale_v20_base[\s\S]*from public, anon, authenticated/i);
  assert.match(source,/grant execute on function public\.reclassify_sale_policy\(uuid,boolean,text\)[\s\S]*to authenticated/i);
});

test('v49a rollback suite proves final catalog definitions and least privilege',()=>{
  assert.equal((fixture.match(/^begin;$/gim)||[]).length,1);
  assert.equal((fixture.match(/^rollback;$/gim)||[]).length,1);
  assert.match(fixture,/provolatile<>'s'/);
  assert.match(fixture,/statement_timestamp\(\)/);
  assert.match(fixture,/v_reversal_ids uuid\[\] := ''\{\}''::uuid\[\];/);
  assert.match(fixture,/v_payment_ids uuid\[\] := ''\{\}''::uuid\[\];/);
  assert.match(fixture,/position\('v_key text;' in v_proc\.prosrc\)>0/);
  assert.match(fixture,/has_function_privilege\('authenticated',v_proc\.oid,'execute'\)/);
});
