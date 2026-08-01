import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('v106 source and canonical migrations are exact mirrors',async()=>{
  const [source,canonical]=await Promise.all([
    read('db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'),
    read('supabase/migrations/20260729171008_nestly_v106_revenue_truth_foundation.sql')
  ]);
  assert.equal(source,canonical);
});

test('v106 makes known total, identity coverage and empty-state math explicit',async()=>{
  const [source,v134]=await Promise.all([
    read('db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'),
    read('db/migrations/20260802_nestly_v134_peekaa_brand_legal.sql')
  ]);
  assert.match(
    source,
    /known_revenue_minor = identified_revenue_minor \+ anonymous_revenue_minor/
  );
  assert.match(source,/'identity_revenue_pct', case when t\.known_revenue = 0 then null/);
  assert.match(
    source,
    /'identity_transaction_pct', case when t\.completed_transactions = 0 then null/
  );
  assert.match(source,/'status', case when t\.completed_transactions = 0 then 'no_data'/);
  assert.match(source,/'interval', '\[from,to\)'/);
  assert.match(source,/per_outlet_effective_timezone/);
  assert.match(source,/cross-currency reporting periods are not supported/);
  assert.match(source,/legacy_assumption/);
  assert.match(
    source,
    /Known revenue covers the Nestly sales ledger; it is not merchant-total revenue/
  );
  assert.match(v134,/'Known revenue covers the Nestly sales ledger',\s*\n\s*'Known revenue covers the Peekaa sales ledger'/);
});

test('v106 external envelope is idempotent, append-only and never rewrites old ledgers',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'
  );
  assert.match(
    source,
    /unique \(business_id, source_system, source_event_id, event_type\)/
  );
  assert.match(source,/'status', 'replayed'/);
  assert.match(source,/'status', 'quarantined'/);
  assert.match(source,/'ledger_changed', false/g);
  assert.match(source,/trg_v106_event_append_only/);
  assert.match(source,/trg_v106_reconciliation_append_only/);
  assert.match(source,/trg_v106_refund_alloc_append_only/);
  assert.doesNotMatch(source,/insert into public\.sales/i);
  assert.doesNotMatch(source,/update public\.sales/i);
  assert.doesNotMatch(source,/delete from public\.sales/i);
  assert.match(source,/cumulative external refunds exceed the original sale/);
  assert.match(source,/refund allocations % do not equal event amount %/);
  assert.match(source,/sale already has a native full reversal/);
  assert.match(source,/foreign key \(supersedes_event_id, business_id\)/);
  assert.match(source,/foreign key \(payment_id, business_id\)/);
  assert.match(
    source,
    /event_type in \('transaction_voided', 'refund_completed', 'chargeback_opened'\)[\s\S]*amount_minor < 0/
  );
  assert.match(source,/event_type = 'chargeback_reversed' and amount_minor > 0/);
});

test('v106 reconciliation coverage requires the exact completed event and amount',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'
  );
  assert.match(source,/join public\.commerce_events_v106 e[\s\S]*e\.event_type = 'transaction_completed'/);
  assert.match(source,/e\.branch_id is not distinct from s\.branch_id/);
  assert.match(source,/e\.currency = c\.currency/);
  assert.match(source,/e\.amount_minor = s\.amount_cents/);
});

test('v106 resolves approved current attribution without rewriting the sales ledger',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'
  );
  assert.match(
    source,
    /app\.v111_effective_client_id\(s\.business_id, s\.client_id\) as client_id/
  );
  assert.match(
    source,
    /immutable sales\.client_id is resolved through app\.v111_effective_client_id for current synchronized reporting/
  );
  assert.match(
    source,
    /create or replace function app\.v111_effective_client_id\([\s\S]*select p_client/
  );
  assert.match(
    source,
    /revoke all on function app\.v111_effective_client_id\(uuid, uuid\)[\s\S]*from public, anon, authenticated/
  );
});

test('v106 assigns refunds and reversals to the half-open reporting period they occur in',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'
  );
  assert.match(
    source,
    /app\.v106_sale_residual_minor\(\s*p_sale uuid,\s*p_period_to date,\s*p_as_of timestamptz\s*\)/
  );
  assert.match(
    source,
    /reversal_contract\.timezone\)::date\s*< p_period_to/
  );
  assert.match(
    source,
    /event_row\.business_date\s*< p_period_to/
  );
  assert.match(
    source,
    /app\.v106_sale_residual_minor\(id, p_to, p_as_of\) as net_minor/
  );
});

test('v106 privileges fail closed and preserve outlet scope',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql'
  );
  for(const table of [
    'reporting_contract_versions_v106',
    'commerce_events_v106',
    'commerce_event_conflicts_v106',
    'commerce_event_reconciliations_v106',
    'commerce_refund_allocations_v106'
  ]){
    assert.match(source,new RegExp(`alter table public\\.${table} enable row level security`));
  }
  assert.match(source,/app\.can_see_branch\(p_business, p_branch\)/);
  assert.match(source,/sale-write permission required for this external event/);
  assert.match(source,/sale-write permission required to reconcile this event/);
  assert.match(
    source,
    /revoke all on function public\.get_revenue_truth_v106\([\s\S]*from public, anon/
  );
});
