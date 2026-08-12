import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

const dbMigration =
  'db/migrations/20260729_nestly_v103_customer_summary_business_identity.sql';
const canonicalMigration =
  'supabase/migrations/20260729160000_nestly_v103_customer_summary_business_identity.sql';

test('v103 canonical mirror is exact and repairs both verified summary projections', async () => {
  const [db, canonical] = await Promise.all([
    read(dbMigration),
    read(canonicalMigration)
  ]);

  assert.equal(canonical, db, 'canonical migration must exactly mirror the reviewed source');
  assert.match(db, /pg_get_functiondef\(\s*'public\.customer_get_business_summary\(text\)'::regprocedure\s*\)/i);
  assert.match(db, /v_old_n\s*<>\s*2\s+or\s+v_new_n\s*<>\s*0/i,
    'migration must fail closed unless both known predecessor projections are present');
  assert.match(db, /''id'',\s*v_context\.business_id/i,
    'projected ID must come from the verified wallet context');
  assert.match(db, /v_expected_n\s*<>\s*2/i,
    'both normal and defensive summary paths must receive the ID');
  assert.doesNotMatch(db, /create\s+or\s+replace\s+function\s+public\.customer_get_business_summary/i,
    'v103 must preserve the authoritative function body apart from its allowlist projection');
});

test('v103 preserves the authenticated-only summary signature and browser boundary', async () => {
  const db = await read(dbMigration);

  assert.match(db, /revoke\s+all\s+on\s+function\s+public\.customer_get_business_summary\(text\)\s+from\s+public,\s*anon,\s*authenticated/i);
  assert.match(db, /grant\s+execute\s+on\s+function\s+public\.customer_get_business_summary\(text\)\s+to\s+authenticated/i);
  assert.match(db, /has_function_privilege\(\s*'anon'[\s\S]*customer_get_business_summary\(text\)[\s\S]*'EXECUTE'/i);
  assert.match(db, /not\s+has_function_privilege\(\s*'authenticated'[\s\S]*customer_get_business_summary\(text\)[\s\S]*'EXECUTE'/i);
  assert.match(db, /acl\.grantee\s*=\s*0[\s\S]*acl\.privilege_type\s*=\s*'EXECUTE'/i,
    'postcondition must reject a residual PUBLIC execute grant');
});

test('v103 rollback-only SQL proves linked identity, cross-firm denial, outsider denial, and ACL', async () => {
  const sql = await read('db/tests/v103_customer_summary_business_identity.sql');

  assert.match(sql, /^begin\s*;/im);
  assert.match(sql, /^rollback\s*;/im);
  assert.match(sql, /customer_links[\s\S]*'verified'/i);
  assert.match(sql, /v_summary#>>'\{business,id\}'\s+is\s+distinct\s+from\s+v_business::text/i);
  assert.match(sql, /customer_get_business_summary\(v_other_slug\)[\s\S]*sqlstate\s+'42501'/i);
  assert.match(sql, /customer_get_business_summary\(v_business_slug\)[\s\S]*authenticated outsider[\s\S]*sqlstate\s+'42501'/i);
  assert.match(sql, /p_role text default 'authenticated'[\s\S]*'anon'/i);
  assert.match(sql, /v_overloads\s*<>\s*1/i);
});

test('customer programme RPC calls consume the UUID supplied by the repaired summary contract', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));

  assert.match(app, /const b=summary\.business\|\|\{\}/);
  assert.match(app, /customerBusinessIdV103[\s\S]{0,400}summaryBusiness\?\.id/,
    'the summary business ID must be the primary UUID source');
  assert.match(app, /customer_get_business_actions_v89'[\s\S]{0,100}\{p_business:businessId\}/);
  assert.match(app, /customer_get_business_presentation_v95'[\s\S]{0,100}\{p_business:businessId,p_branch:null,p_locale:customerLocale==='zh-CN'\?'zh-CN':'en'\}/);
});
