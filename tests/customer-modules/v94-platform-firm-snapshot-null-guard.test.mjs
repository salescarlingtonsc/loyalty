import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sha256=value=>createHash('sha256').update(value).digest('hex');

test('v94 repairs the nullable snapshot boundary without rewriting production v88',async()=>{
  const [source,canonical,v88]=await Promise.all([
    read('db/migrations/20260728_nestly_v94_platform_firm_snapshot_null_guard.sql'),
    read('supabase/migrations/20260728130000_nestly_v94_platform_firm_snapshot_null_guard.sql'),
    read('db/migrations/20260726_nestly_v88_platform_firm_onboarding.sql')
  ]);

  assert.equal(source,canonical);
  assert.equal(
    sha256(v88),
    '5a0c55bee25b6676dcde50e0d9cda1bea9b1487c9fe0e04e81ecce3a94bcb1e7'
  );
  assert.match(source,/v94 requires the reviewed v88 snapshot predecessor/);
  assert.match(
    source,
    /p_actor,p_snapshot_at,firm\.row_id,firm\.updated_at,firm\.days_unattended,\s+coalesce\(firm\.attention_due,false\),firm\.attention_severity/
  );
  assert.match(source,/to_jsonb\(firm\)\|\|jsonb_build_object/);
  assert.match(source,/'attention_due',coalesce\(firm\.attention_due,false\)/);
  assert.match(
    source,
    /revoke all on function app\.ensure_platform_firm_snapshot_v88\([\s\S]*from public,anon,authenticated/
  );
});

test('v94 migration self-verifies the exact repaired definition and private grants',async()=>{
  const source=await read(
    'db/migrations/20260728_nestly_v94_platform_firm_snapshot_null_guard.sql'
  );

  assert.match(source,/regexp_replace\(lower\(v_def\),'\[\[:space:\]\]\+'/);
  assert.match(source,/position\('coalesce\(firm\.attention_due,false\)' in v_compact_def\)>0/);
  assert.match(source,/length\('coalesce\(firm\.attention_due,false\)'\)<>2/);
  assert.match(source,/has_function_privilege\(\s*'authenticated'/);
  assert.match(source,/has_function_privilege\(\s*'anon'/);
  assert.match(source,/v94 final snapshot guard or grants are not exact/);
});

test('v94 rollback acceptance proves fail-closed attention and both writer guards',async()=>{
  const suite=await read('db/tests/v94_platform_firm_snapshot_null_guard.sql');

  assert.match(suite,/^begin;/m);
  assert.match(suite,/if v_raw_attention is true then/);
  assert.match(
    suite,
    /pg_get_functiondef\([\s\S]*\) into v_writer_definition/
  );
  assert.match(
    suite,
    /length\(v_writer_definition\)[\s\S]*length\(replace\(v_writer_definition,\s*'coalesce\(firm\.attention_due,false\)',''\)\)[\s\S]*<>\s*2 \* length\('coalesce\(firm\.attention_due,false\)'\)/
  );
  assert.match(suite,/public\.platform_list_firm_onboarding_v88/);
  assert.match(suite,/snapshot\.attention_due=false/);
  assert.match(suite,/snapshot\.payload->>'attention_due'='false'/);
  assert.match(suite,/V94 SUITE PASS/);
  assert.match(suite,/rollback;\s*$/);
});
