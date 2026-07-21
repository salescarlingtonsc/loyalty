import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const [migration,suite,concurrency,app,v21,v21suite]=await Promise.all([
  readFile(path.join(root,'db/migrations/20260721_frenly_v40_staff_reversal_workflows.sql'),'utf8'),
  readFile(path.join(root,'db/tests/v40_staff_reversal_workflows.sql'),'utf8'),
  readFile(path.join(root,'db/tests/v40_reversal_credit_concurrency.sh'),'utf8'),
  readFile(path.join(root,'app/index.html'),'utf8'),
  readFile(path.join(root,'db/migrations/20260719_frenly_v21_security_hardening.sql'),'utf8'),
  readFile(path.join(root,'db/tests/v21_security_hardening.sql'),'utf8')
]);

test('v40 keeps mutation entry points authenticated-only and the v34 base internal',()=>{
  assert.match(migration,/alter function public\.reverse_sale\(uuid,uuid,text,text,text,text\)\s+rename to reverse_sale_v34_base/i);
  assert.match(migration,/revoke all privileges on function public\.reverse_sale_v34_base[^;]+from public, anon, authenticated/i);
  assert.match(migration,/alter function public\.reverse_loyalty_redemption\(uuid,uuid,text,text\)\s+rename to reverse_loyalty_redemption_v34_base/i);
  assert.match(migration,/revoke all privileges on function public\.reverse_loyalty_redemption_v34_base[^;]+from public, anon, authenticated/i);
  for(const name of ['reverse_sale','reverse_loyalty_redemption','staff_get_reversal_workflows']){
    assert.match(migration,new RegExp(`create or replace function public\\.${name}\\(`,'i'));
    assert.match(migration,new RegExp(`revoke all privileges on function public\\.${name}[\\s\\S]{0,180}from public, anon(?:, authenticated)?`,'i'));
    assert.match(migration,new RegExp(`grant execute on function public\\.${name}[\\s\\S]{0,180}to authenticated`,'i'));
  }
  assert.match(migration,/security definer[\s\S]{0,120}search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
});

test('loyalty reversal enforces permission, active staff, and immutable selected branch before compensation',()=>{
  const wrapper=migration.match(/create or replace function public\.reverse_loyalty_redemption\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(wrapper,/auth\.uid\(\)/i);
  assert.match(wrapper,/app\.has_perm\(p_business, 'refund_sales'\)/i);
  assert.match(wrapper,/public\.staff[\s\S]*s\.active[\s\S]*refund_sales/i);
  assert.match(wrapper,/eligibility_snapshot\s*#>>\s*'\{selected,branch_id\}'/i);
  assert.ok((wrapper.match(/app\.can_see_branch\(p_business, v_branch\)/gi)||[]).length>=2);
  assert.match(wrapper,/for update/i);
  assert.match(wrapper,/app\.role_class\(v_role\) not in \('owner','admin'\)[\s\S]*public\.staff_branches[\s\S]*for share/i);
  const staffLock=wrapper.indexOf('for update;');
  const redemptionLock=wrapper.indexOf('select lr.* into v_redemption');
  const clientLock=wrapper.indexOf('from public.clients c',redemptionLock);
  assert.ok(staffLock>=0&&redemptionLock>staffLock&&clientLock>redemptionLock,'lock order must be staff -> redemption -> client');
  assert.match(wrapper,/credit_ledger_id is null[\s\S]*entry_type='loyalty_earn'[\s\S]*amount_cents=v_redemption\.credit_cents[\s\S]*config_version_id=v_redemption\.config_version_id/i);
  assert.match(wrapper,/amount_cents<0 and spend\.created_at>=v_source_credit\.created_at/i);
  const replayGuard=wrapper.indexOf('select * into v_existing');
  const provenanceCheck=wrapper.indexOf('select * into v_provenance');
  assert.ok(replayGuard>=0&&provenanceCheck>replayGuard,'completed replay/conflict must bypass its own compensation debit');
  assert.match(wrapper,/return public\.reverse_loyalty_redemption_v34_base/i);
});

test('package replay lookup assigns composite and scalar values in separate PL/pgSQL statements',()=>{
  const wrapper=migration.match(/create or replace function public\.reverse_sale\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.doesNotMatch(wrapper,/select\s+pr\s*,\s*r\.note\s+into\s+v_existing\s*,\s*v_reversal_note/i);
  assert.match(wrapper,/select pr\.\* into v_existing[\s\S]*select r\.note into v_reversal_note/i);
});

test('bounded read model is stable-compatible, branch filtered, and exposes only workflow fields',()=>{
  const reader=migration.match(/create or replace function public\.staff_get_reversal_workflows\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(reader,/stable[\s\S]*security definer/i);
  assert.doesNotMatch(reader,/for\s+(?:update|share)/i,'STABLE reader must not acquire row locks');
  assert.match(reader,/least\(greatest\(coalesce\(p_limit, 50\), 1\), 100\)/i);
  assert.match(reader,/p_mode text default 'all'/i);
  assert.match(reader,/v_mode not in \('all','package'\)/i);
  assert.ok((reader.match(/app\.can_see_branch\(/gi)||[]).length>=2);
  for(const field of ['net_amount_cents','original_sale_id','reversal_sale_id','no_money_refund','completed_result','has_exact_provenance','credit_may_be_spent','refusal_reason']){
    assert.match(reader,new RegExp(`'${field}'`));
  }
  assert.doesNotMatch(reader,/jsonb_build_object\([^)]*request_payload/i);
  assert.doesNotMatch(reader,/select\s+fo\.result/i,'raw financial operation result must not be returned');
  assert.doesNotMatch(reader,/'(?:operation_id|payment_refund_ids|effects)'/i);
  assert.match(reader,/source\.entry_type='loyalty_earn'[\s\S]*source\.amount_cents=lr\.credit_cents[\s\S]*source\.config_version_id=lr\.config_version_id/i);
  assert.match(reader,/spend\.id is distinct from rr\.reversed_credit_ledger_id/i);
  assert.match(reader,/pc\.sale_id = coalesce\(s\.reversal_of, s\.id\)/i);
  assert.match(reader,/v_mode = 'all' or pkg\.consumption_id is not null/i);
  assert.match(reader,/count\(\*\) over\(\) as total_count/i);
  assert.match(reader,/'may_have_more', v_sales_total > v_limit/i);
  assert.match(reader,/else coalesce\(original\.amount_cents, 0\) \+ s\.amount_cents/i);
});

test('staff UI requires reason, stable key, confirmation, explicit reference and shows replay/conflict/result',()=>{
  assert.match(app,/const reversalKeys=new Map\(\)/);
  assert.match(app,/crypto\.randomUUID\(\)/);
  assert.match(app,/Reason \(required, at least 10 characters\)/);
  assert.match(app,/Reference \(required\)/);
  assert.match(app,/p_restock_policy:'none'/);
  assert.match(app,/if\(!isReplay&&!confirm\(/);
  assert.match(app,/reverse_sale':'reverse_loyalty_redemption/);
  assert.match(app,/Changed-request conflict/);
  assert.match(app,/Verify exact replay/);
  assert.match(app,/No payment refund was created/);
  assert.match(app,/reward credit may have been spent/i);
  assert.doesNotMatch(app,/refund\/reversal state deferred|no reversal rows exist yet/i);
});

test('quick sale uses the atomic RPC and browser code cannot mutate financial evidence tables',()=>{
  const quickSale=app.match(/async function salesPage\(\)\{[\s\S]*?\/\* ---------- services ---------- \*\//)?.[0]||'';
  assert.match(quickSale,/sb\.rpc\('record_quick_sale'/);
  for(const input of ['p_amount_cents','p_method','p_client','p_staff','p_branch','p_note','p_paid','p_idempotency_key']){
    assert.match(quickSale,new RegExp(input));
  }
  assert.match(quickSale,/quickSaleAttempt\.fingerprint!==fingerprint[\s\S]*crypto\.randomUUID\(\)/);
  assert.match(quickSale,/Payment state/);
  assert.match(quickSale,/Payment method/);
  assert.match(quickSale,/No active permitted branch/);
  const protectedTables=['sales','points_ledger','credit_ledger','points_batches',
    'loyalty_redemption_provenance','loyalty_redemption_batch_drains','financial_operations',
    'package_session_consumptions','package_session_reversals','loyalty_redemption_reversals'];
  for(const table of protectedTables){
    const directMutation=new RegExp(`\\.from\\(\\s*(['"])${table}\\1\\s*\\)\\s*\\.\\s*(?:insert|update|delete|upsert)\\s*\\(`,'i');
    assert.doesNotMatch(app,directMutation,`browser must not directly mutate ${table}`);
  }
});

test('histories, reports, daily report and CSV carry reversal relationships and signed/net values',()=>{
  for(const token of ['Session correction history','reversal_sale_id','relationship_net','signed_amount','Reversal reconciliation','Net revenue from immutable rows']){
    assert.match(app,new RegExp(token,'i'));
  }
  assert.match(app,/rows\.filter\(r=>r\.counts_as_visit\)\.reduce\(\(n,r\)=>n\+\(r\.reversal_of\?-1:1\),0\)/);
  assert.match(app,/const netVisits=\(allSl\|\|\[\]\)\.filter\(s=>s\.counts_as_visit\)\.reduce\(\(n,s\)=>n\+\(s\.reversal_of\?-1:1\),0\)/);
  assert.match(app,/relationship_net_original_only/);
  assert.doesNotMatch(app,/Net visits on record[\s\S]{0,120}\?\s*'\+'/);
  assert.match(app,/const from=sgDateBoundary\(day\),toExclusive=sgDateBoundary\(day,1\)/);
  assert.match(app,/\.gte\('occurred_at',from\)\.lt\('occurred_at',toExclusive\)/);
  assert.match(app,/sl=await fetchAllRows\(\(\)=>\{[\s\S]*count:'exact'[\s\S]*order\('occurred_at'\)\.order\('id'\)/);
  assert.match(app,/loadReversalWorkflows\(null,100,'package'\)/);
  assert.match(app,/Showing the newest[\s\S]*server limit[\s\S]*older rows are not shown/);
});

test('report CSV encoder follows RFC4180 quoting for commas, quotes and line breaks',()=>{
  const fieldBlock=app.match(/function csvField\(value\)\{[\s\S]*?\n\}/)?.[0]||'';
  const rowsBlock=app.match(/function csvRows\(rows\)\{[^\n]+\}/)?.[0]||'';
  const {csvField,csvRows}=new Function(`${fieldBlock}\n${rowsBlock}\nreturn {csvField,csvRows}`)();
  assert.equal(csvField('plain'),'plain');
  assert.equal(csvField('A, B'),'"A, B"');
  assert.equal(csvField('say "yes"'),'"say ""yes"""');
  assert.equal(csvRows([['name','note'],['A, B','line1\nline2']]),'name,note\r\n"A, B","line1\nline2"\r\n');
  assert.ok((app.match(/new Blob\(\[csvRows\(rows\)\]/g)||[]).length>=2);
});

test('rollback suite covers principals, exact replay/conflict, package and loyalty compensation, branch scope and reconciliation',()=>{
  for(const token of ['restricted ordinary staff','inactive owner','customer/non-staff','anon executed','authorized manager','unsupported reversal workflow mode','package mode did not remain bounded and package-only','changed package reversal request','changed package reversal reference','restored_sessions','no_money_refund','public.payments','same zero relationship net','exact loyalty reversal replay','changed loyalty reversal request','FEFO batches','restricted staff crossed redemption branch scope','business/tenant boundary']){
    assert.match(suite,new RegExp(token,'i'));
  }
  assert.match(suite,/sum\(points\)[\s\S]*sum\(remaining\)/i);
  assert.doesNotMatch(suite,/values\([^;]*'staff'\s*,\s*'V40 restricted/i);
  for(const phrase of ['missing source credit provenance was reversible','mismatched source credit provenance was reversible','spent reward credit was reversible']){
    assert.match(suite,new RegExp(phrase,'i'));
  }
});

test('two-session harness races credit tender against redemption reversal at one client balance',()=>{
  assert.match(concurrency,/V40_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency,/fixture_name="V40 concurrency"/);
  assert.match(concurrency,/public\.create_business\(:'fixture_name',:'fixture_slug'/);
  assert.match(concurrency,/create_loyalty_config_draft\(:'biz'/);
  assert.doesNotMatch(concurrency,/from public\.staff s[\s\S]*where s\.role='owner'/i);
  assert.match(concurrency,/run_tender[\s\S]*record_credit_tender/i);
  assert.match(concurrency,/run_reversal[\s\S]*reverse_loyalty_redemption/i);
  assert.match(concurrency,/tender_app="v40-credit-tender-\$owner_prefix"/);
  assert.match(concurrency,/reversal_app="v40-credit-reversal-\$owner_prefix"/);
  assert.match(concurrency,/set application_name=:'tender_app'/);
  assert.match(concurrency,/set application_name=:'reversal_app'/);
  assert.doesNotMatch(concurrency,/pg_terminate_backend/i);
  assert.match(concurrency,/cleanup_synthetic_fixture\.sql/i);
  assert.match(concurrency,/select pg_sleep\(5\)/i);
  assert.match(concurrency,/tenders\+reversals/);
  assert.match(concurrency,/ledger.*batches/);
});

test('v21 registries include the new authenticated read RPC',()=>{
  assert.match(v21,/'staff_get_reversal_workflows'/);
  assert.match(v21suite,/'staff_get_reversal_workflows'/);
});
