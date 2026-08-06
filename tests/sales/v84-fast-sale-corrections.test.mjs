import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root=new URL('../..',import.meta.url).pathname;
const read=file=>readFile(path.join(root,file),'utf8');
const sourcePath='db/migrations/20260726_nestly_v84_fast_sale_corrections.sql';
const canonicalPath='supabase/migrations/20260726190000_nestly_v84_fast_sale_corrections.sql';
const [sql,canonical,app,fixture]=await Promise.all([
  read(sourcePath),read(canonicalPath),Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),read('db/tests/v84_fast_sale_corrections.sql')
]);
const functionBlock=name=>sql.match(new RegExp(
  `create or replace function public\\.${name}\\([\\s\\S]+?\\n(?:end\\n)?\\$\\$;`,'i'
))?.[0]||'';

test('v84 source and canonical migrations are byte-identical',()=>{
  assert.equal(sql,canonical);
});

test('v84 amount correction is one append-only, tenant-scoped audit chain',()=>{
  assert.match(sql,/create table public\.sale_amount_corrections_v84/i);
  assert.match(sql,/original_sale_id uuid not null[\s\S]*reversal_sale_id uuid not null[\s\S]*replacement_sale_id uuid not null/i);
  assert.match(sql,/unique \(original_sale_id\)/i);
  assert.match(sql,/unique \(business_id,idempotency_key\)/i);
  assert.match(sql,/points_removed integer not null default 0/i);
  assert.match(sql,/points_compensation_ledger_id uuid/i);
  assert.match(sql,/sale_amount_corrections_v84_points_evidence_ck/i);
  assert.match(sql,/foreign key \(points_compensation_ledger_id,business_id\)[\s\S]*references public\.points_ledger/i);
  assert.match(sql,/enable row level security/i);
  assert.match(sql,/app\.has_perm\(business_id,'view_finance'\)[\s\S]*app\.can_see_branch\(business_id,branch_id\)/i);
  assert.match(sql,/trg_sale_amount_corrections_v84_append_only[\s\S]*app\.forbid_mutation\(\)/i);
  assert.match(sql,/revoke all privileges on table public\.sale_amount_corrections_v84[\s\S]*from public, anon, authenticated/i);
});

test('v84 correction composes existing reversal and sale writers atomically and idempotently',()=>{
  const fn=functionBlock('correct_quick_sale_amount_v84');
  assert.match(fn,/security definer/i);
  assert.match(fn,/set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(fn,/app\.has_perm\(p_business,'refund_sales'\)[\s\S]*app\.has_perm\(p_business,'create_sales'\)/i);
  assert.match(fn,/pg_advisory_xact_lock/i);
  assert.match(fn,/request_hash is distinct from v_hash[\s\S]*using errcode='23505'/i);
  assert.match(fn,/completed sale correction is missing exact sale-chain evidence/i);
  assert.match(fn,/completed sale correction is missing exact loyalty compensation evidence/i);
  assert.ok(fn.indexOf('v_reverse := public.reverse_sale(')<fn.indexOf('v_replacement := public.record_quick_sale('));
  assert.match(fn,/p_client=>v_original\.client_id[\s\S]*p_staff=>v_original\.staff_id[\s\S]*p_branch=>v_original\.branch_id[\s\S]*p_note=>v_original\.note/i);
  assert.match(fn,/operation\.request_payload->>'method'/i);
  assert.match(fn,/return v_existing\.result \|\| jsonb_build_object\('replayed',true\)/i);
  assert.match(fn,/sale_amount_correction_v84/i);
  assert.match(fn,/insert into public\.points_ledger[\s\S]*-v_original_points[\s\S]*v_reversal_sale/i);
  assert.match(fn,/update public\.points_batches batch[\s\S]*set remaining=0[\s\S]*batch\.sale_id=v_original\.id/i);
  assert.match(fn,/original loyalty points are not wholly unspent/i);
  assert.match(fn,/points ledger and batch cache diverged during sale correction/i);
  assert.doesNotMatch(fn,/\bupdate\s+public\.sales\b/i);
  assert.doesNotMatch(fn,/\bdelete\s+from\s+public\.(?:sales|payments|points_ledger)\b/i);
});

test('v84 keeps the proven reversal engine while removing minimum-word UI burden',()=>{
  const wrapper=functionBlock('reverse_sale_fast_v84');
  assert.match(wrapper,/security invoker/i);
  assert.match(wrapper,/public\.reverse_sale\(/i);
  assert.match(wrapper,/Staff-confirmed sale reversal/i);
  assert.match(wrapper,/Staff note:/i);
  assert.match(sql,/revoke all privileges on function public\.reverse_sale_fast_v84[\s\S]*from public, anon, authenticated/i);
  assert.match(app,/Correction note \(optional\)/);
  assert.match(app,/reverse_sale_fast_v84/);
  assert.doesNotMatch(app,/id="revReference"/);
});

test('v84 derives current payment truth and refuses states the replacement writer cannot represent',()=>{
  const fn=functionBlock('correct_quick_sale_amount_v84');
  assert.match(fn,/with method_nets as \([\s\S]*sum\(payment\.amount_cents\)::integer as net_cents/i);
  assert.match(fn,/v_payment_net_cents=v_original\.amount_cents[\s\S]*v_nonzero_payment_methods=1[\s\S]*v_method='cash'/i);
  assert.match(fn,/v_payment_net_cents=0 and v_nonzero_payment_methods=0/i);
  assert.match(fn,/fast correction supports only net-unpaid or fully-paid single-method cash sales/i);
  assert.match(fn,/'current_payment_cents',v_payment_net_cents/i);
  assert.doesNotMatch(fn,/request_payload->>'paid'/i);
});

test('sales UX tags by team-member name and uses stable double-confirm correction attempts',()=>{
  assert.match(app,/from\('staff'\)\.select\('id,full_name,user_id',\{count:'exact'\}\)/);
  // The Record-sale staff dropdown (qstaff) was retired: a sale is now attributed to the acting
  // staff member automatically (p_staff:staffId, resolved from the signed-in user), which is
  // stronger than letting the operator pick. The team-member NAME still drives the Sales filter.
  assert.match(app,/id="salesStaff"[\s\S]{0,200}person\.full_name/);
  assert.match(app,/p_staff:staffId/);
  assert.match(app,/data-correct-sale/);
  assert.match(app,/id="saleCorrectionChecked"/);
  assert.match(app,/Final check: replace/);
  assert.match(app,/const saleCorrectionAttempts=new Map\(\)/);
  assert.match(app,/if\(!attempt\|\|attempt\.fingerprint!==fingerprint\)[\s\S]*crypto\.randomUUID\(\)[\s\S]*p_idempotency_key:attempt\.key/);
  assert.match(app,/correct_quick_sale_amount_v84/);
});

test('workspace navigation cannot horizontally clip and route focus no longer scrolls the page',()=>{
  assert.match(app,/overflow-y:auto;overflow-x:hidden;overscroll-behavior:contain/);
  assert.match(app,/const priorSideScroll=priorSide\?\.scrollTop\|\|0/);
  assert.match(app,/side\.scrollTop=priorSideScroll/);
  assert.match(app,/target\.focus\(\{preventScroll:true\}\)/);
});

test('customer UI uses QR-authorized joining and exposes paginated transaction truth',()=>{
  const surface=app.slice(
    app.indexOf('async function loadCustomerSurfaceContext'),
    app.indexOf('async function renderCustomerProgrammes')
  );
  assert.doesNotMatch(surface,/customer_sync_verified_relationships_v81|syncVerifiedCustomerRelationshipsOnce/);
  assert.match(app,/customer_join_business_from_qr_v89/);
  assert.match(app,/pendingCustomerJoinToken/);
  assert.match(app,/No verified business links yet/);
  // The wallet surface moved to the v167 reader; the SQL acceptance file below still exercises
  // v81, which is the function that migration created and which still exists in production.
  assert.match(app,/customer_get_transaction_history_v167/);
  assert.match(app,/p_business_slug:businessSlug,p_cursor:requestedCursor/);
  assert.match(app,/walletTransactionsMore/);
  assert.match(app,/points_earned/);
  assert.match(app,/points_redeemed/);
  assert.match(app,/points_removed/);
  assert.match(app,/line_items/);
});

test('customer intelligence is implemented and reachable again from the business workspace',()=>{
  assert.match(app,/customerintel:\['customers','Customer intelligence'\]/);
  assert.match(app,/const HIDDEN_BUSINESS_SURFACES=new Set\(\[\]\)/);
  assert.match(app,/if\(HIDDEN_BUSINESS_SURFACES\.has\(pageKey\)\)/);
  assert.match(app,/filter\(module=>!HIDDEN_BUSINESS_SURFACES\.has\(module\)\)/);
  assert.match(app,/get_customer_intelligence_v83/);
  assert.match(app,/p_snapshot_at:lastPayload\.snapshot_at/);
  assert.match(app,/p_after_created_at:cursor\.customer_since,p_after_client:cursor\.client_id/);
  assert.match(app,/pagination\?\.next_cursor/);
  assert.match(app,/id="ciMore"/);
  assert.match(app,/create_customer_intelligence_export_v83/);
  assert.match(app,/get_customer_intelligence_export_page_v83/);
  assert.match(app,/p_export:exportId,p_after_ordinal:afterOrdinal,p_limit:500/);
  assert.match(app,/page\.next_ordinal/);
  assert.doesNotMatch(app,/CUSTOMER_INTELLIGENCE_EXPORT_CAP/);
  assert.match(app,/No partial CSV was downloaded/);
  assert.match(app,/get_revenue_truth_v106/);
  assert.match(app,/get_customer_lifecycle_v107/);
  assert.match(app,/get_growth_daily_briefing_v108/);
  assert.match(app,/RevenueTruthUI\.buildViewModel/);
  assert.match(app,/Repeat this period/);
  assert.match(app,/Identified customer revenue/);
  assert.match(app,/>Returning customers</);
  assert.match(app,/Expected cash collected · next 90 days/);
  assert.match(app,/13 complete Singapore calendar weeks/);
  assert.match(app,/Forecast withheld until the selected scope has enough valid history/);
  assert.match(app,/href="#\/client\/\$\{encodeURIComponent\(customer\.client_id\)\}"/);
});

test('rollback fixture covers replay, payment truth, point compensation, wallet history and fail-closed cases',()=>{
  assert.match(fixture,/^begin;[\s\S]*rollback;\n$/m);
  assert.match(fixture,/v84 exact correction replay changed the result/);
  assert.match(fixture,/v84 changed request reused the correction key/);
  assert.match(fixture,/v84 corrected a pre-reversed original/);
  assert.match(fixture,/v84 unpaid original gained a payment during correction/);
  assert.match(fixture,/did not remove original earn and expose replacement earn/);
  assert.match(fixture,/append-only loyalty compensation evidence is missing/);
  assert.match(fixture,/customer_get_transaction_history_v81/);
  assert.match(fixture,/customer wallet history did not expose the exact correction point chain/);
  assert.match(fixture,/did not derive and preserve later full cash payment state/);
  assert.match(fixture,/did not fail closed on a partial payment journal/);
  assert.match(fixture,/did not fail closed on a mixed payment journal/);
  assert.match(fixture,/did not fail closed on provider-settled payment state/);
  assert.match(fixture,/did not fail closed when original loyalty points were spent/);
  assert.match(fixture,/reverse_sale_fast_v84\(\s*v_business,v_second,null/);
  assert.match(fixture,/v84 non-staff principal corrected a sale/);
});
