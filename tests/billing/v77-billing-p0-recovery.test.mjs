import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  billingReconciliationStatus,
  drainBoundedKeysetPages,
  drainBoundedProviderPages,
  newBillingReconciliationCursor,
  parseBillingReconciliationCursor,
  providerIdsMissingLocally,
} from '../../supabase/functions/_shared/billing-reconciliation.ts';
import {
  billingCommandFailureDisposition,
} from '../../supabase/functions/_shared/billing-command-recovery.ts';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const makeRows=(count,prefix)=>Array.from({length:count},(_,index)=>({
  id:`${prefix}_${String(index+1).padStart(4,'0')}`
}));

async function drain(rows,{after=null,maxPages=2}={}){
  const consumed=[];
  const result=await drainBoundedKeysetPages({
    after,pageSize:250,maxPages,keyOf:row=>row.id,
    fetchPage:async(cursor,limit)=>rows.filter(row=>!cursor||row.id>cursor).slice(0,limit),
    consumePage:async page=>consumed.push(...page)
  });
  return{result,consumed};
}

async function drainProvider(rows,{after=null,maxPages=1}={}){
  const consumed=[];
  const result=await drainBoundedProviderPages({
    after,maxPages,
    fetchPage:async cursor=>{
      const start=cursor?rows.findIndex(row=>row.id===cursor)+1:0;
      const data=rows.slice(start,start+100);
      return{data,has_more:start+data.length<rows.length};
    },
    consumePage:async page=>consumed.push(...page)
  });
  return{result,consumed};
}

test('251+ subscriptions alone reconcile through the second keyset page',async()=>{
  const rows=makeRows(251,'sub');
  const {result,consumed}=await drain(rows);
  assert.equal(result.pages,2);
  assert.equal(result.processed,251);
  assert.equal(result.complete,true);
  assert.equal(result.after,'sub_0251');
  assert.deepEqual(consumed,rows);
});

test('251+ invoices alone reconcile through the second keyset page',async()=>{
  const rows=makeRows(263,'inv');
  const {result,consumed}=await drain(rows);
  assert.equal(result.pages,2);
  assert.equal(result.processed,263);
  assert.equal(result.complete,true);
  assert.equal(result.after,'inv_0263');
  assert.deepEqual(consumed,rows);
});

test('bounded partial cycles resume durably without repeating or skipping rows',async()=>{
  const rows=makeRows(501,'invoice');
  const first=await drain(rows);
  assert.equal(first.result.processed,500);
  assert.equal(first.result.complete,false);
  const cursor=newBillingReconciliationCursor('2026-07-26T00:00:00.000Z');
  cursor.local_invoices_after=first.result.after;
  cursor.local_invoices_complete=first.result.complete;
  cursor.processed=first.result.processed;
  const restored=parseBillingReconciliationCursor(JSON.stringify(cursor));
  assert.ok(restored);
  const second=await drain(rows,{after:restored.local_invoices_after});
  assert.equal(second.result.complete,true);
  assert.equal(second.result.processed,1);
  assert.equal(second.consumed[0].id,'invoice_0501');
  assert.equal(new Set([...first.consumed,...second.consumed].map(row=>row.id)).size,501);
});

test('keyset drain refuses a non-advancing or unsorted page',async()=>{
  await assert.rejects(()=>drainBoundedKeysetPages({
    after:'item_0002',pageSize:250,maxPages:2,keyOf:row=>row.id,
    fetchPage:async()=>[{id:'item_0002'}],
    consumePage:async()=>{}
  }),/keyset did not advance/i);
});

test('101+ provider subscriptions resume with Stripe starting_after semantics',async()=>{
  const rows=makeRows(101,'sub');
  const first=await drainProvider(rows);
  assert.equal(first.result.complete,false);
  assert.equal(first.result.processed,100);
  assert.equal(first.result.after,'sub_0100');
  const cursor=newBillingReconciliationCursor('2026-07-26T00:00:00.000Z');
  cursor.provider_subscriptions_after=first.result.after;
  const restored=parseBillingReconciliationCursor(JSON.stringify(cursor));
  assert.ok(restored);
  const second=await drainProvider(rows,{after:restored.provider_subscriptions_after});
  assert.equal(second.result.complete,true);
  assert.deepEqual(second.consumed,[rows[100]]);
  assert.deepEqual([...first.consumed,...second.consumed],rows);
});

test('101+ provider invoices resume without repeats or skipped provider IDs',async()=>{
  const rows=makeRows(137,'inv');
  const first=await drainProvider(rows);
  const cursor=newBillingReconciliationCursor('2026-07-26T00:00:00.000Z');
  cursor.provider_invoices_after=first.result.after;
  const restored=parseBillingReconciliationCursor(JSON.stringify(cursor));
  assert.ok(restored);
  const second=await drainProvider(rows,{after:restored.provider_invoices_after});
  assert.equal(second.result.complete,true);
  assert.equal(new Set([...first.consumed,...second.consumed].map(row=>row.id)).size,137);
  assert.deepEqual([...first.consumed,...second.consumed],rows);
});

test('provider-only Nestly IDs emit missing-local discrepancies',()=>{
  assert.deepEqual(
    providerIdsMissingLocally(
      ['sub_present','sub_missing_1','sub_missing_2'],
      ['sub_present'],
    ),
    ['sub_missing_1','sub_missing_2'],
  );
});

test('snapshot membership retains a pre-snapshot row updated after the snapshot',()=>{
  const snapshot='2026-07-26T12:00:00.000Z';
  const row={
    provider_subscription_id:'sub_pre_snapshot',
    created_at:'2026-07-26T11:59:00.000Z',
    updated_at:'2026-07-26T12:01:00.000Z'
  };
  const members=[row].filter(
    candidate=>Date.parse(candidate.created_at)<=Date.parse(snapshot),
  );
  assert.deepEqual(members,[row]);
  assert.equal(Date.parse(row.updated_at)<=Date.parse(snapshot),false);
});

test('clean requires all four streams and no cumulative discrepancy',()=>{
  const cursor=newBillingReconciliationCursor('2026-07-26T00:00:00.000Z');
  assert.equal(billingReconciliationStatus(cursor),'partial');
  cursor.local_subscriptions_complete=true;
  cursor.local_invoices_complete=true;
  cursor.provider_subscriptions_complete=true;
  assert.equal(billingReconciliationStatus(cursor),'partial');
  cursor.provider_invoices_complete=true;
  assert.equal(billingReconciliationStatus(cursor),'clean');
  cursor.unscoped_provider=10;
  assert.equal(billingReconciliationStatus(cursor),'clean');
  cursor.missing_local=1;
  assert.equal(billingReconciliationStatus(cursor),'mismatch');
});

test('post-provider persistence and ambiguous Stripe failures stay uncertain',()=>{
  assert.equal(billingCommandFailureDisposition({
    providerCallStarted:true,nonExecutionProven:false
  }),'uncertain');
  assert.equal(billingCommandFailureDisposition({
    providerCallStarted:false,nonExecutionProven:true
  }),'failed');
  assert.equal(billingCommandFailureDisposition({
    providerCallStarted:true,nonExecutionProven:true
  }),'failed');
});

test('executor retrieves or replays the same Stripe idempotency evidence before completion',async()=>{
  const [executor,sql,reconcile]=await Promise.all([
    read('supabase/functions/stripe-billing-command/index.ts'),
    read('db/migrations/20260726_nestly_v77_stripe_billing.sql'),
    read('supabase/functions/stripe-billing-reconcile/index.ts')
  ]);
  assert.match(sql,/status in \('pending','processing','uncertain','completed','failed','canceled'\)/);
  assert.match(sql,/status in \('running','partial','clean','mismatch','failed'\)/);
  assert.match(sql,/v_recovery_required:=v_command\.status in \('processing','uncertain'\)/);
  assert.match(sql,/'provider_idempotency_key','nestly:v77:billing-command:'\|\|v_command\.id::text/);
  assert.match(sql,/'prior_provider_object_id',v_command\.provider_object_id/);
  assert.match(executor,/retrieveRecoveredProviderResult/);
  assert.match(
    executor,
    /data\.recovery_required[\s\S]{0,80}data\.prior_provider_object_id/,
  );
  assert.match(executor,/portalRecoveryReplay/);
  assert.doesNotMatch(executor,/billingPortal\.sessions\.retrieve/);
  assert.match(executor,/Billing Portal sessions have no retrieve endpoint/);
  assert.match(executor,/\{ idempotencyKey \}/);
  assert.match(executor,/p_status: disposition/);
  assert.match(executor,/provider_result_uncertain/);
  assert.match(executor,/retry_same_command_id/);
  assert.match(executor,/priorExecutionWasUncertain = claimed\?\.recovery_required === true/);
  assert.match(executor,/uncertain \? 202 : 500/);
  assert.doesNotMatch(executor,/p_status: 'failed'[\s\S]{0,260}completion persistence failed/);
  assert.match(reconcile,/billingReconciliationStatus\(cursor\)/);
  assert.match(reconcile,/p_cursor_end: JSON\.stringify\(cursor\)/);
  assert.match(reconcile,/\.gt\('provider_subscription_id', after\)/);
  assert.match(reconcile,/\.gt\('provider_invoice_id', after\)/);
  assert.match(reconcile,/stripe\.subscriptions\.list\(\{/);
  assert.match(reconcile,/status: 'all'/);
  assert.match(reconcile,/stripe\.invoices\.list\(\{/);
  assert.match(reconcile,/created: \{ lte: createdLte \}/);
  assert.match(reconcile,/starting_after: after/);
  assert.match(reconcile,/has_more: page\.has_more/);
  assert.match(reconcile,/result: 'missing_local'/);
  assert.match(reconcile,/existingBusinessIds/);
  assert.match(reconcile,/unscoped_provider/);
  assert.match(reconcile,/providerIdsMissingLocally/);
  assert.match(reconcile,/\.lte\('created_at', snapshotAt\)/);
  assert.equal(
    (reconcile.match(/\.lte\('created_at', cursor\.snapshot_at\)/g)||[]).length,
    2,
  );
  assert.doesNotMatch(reconcile,/\.lte\('updated_at', (?:snapshotAt|cursor\.snapshot_at)\)/);
  assert.match(reconcile,/snapshot pins membership, not historical row values/);
  assert.match(reconcile,/current\/live state at reconciliation time/);
});
