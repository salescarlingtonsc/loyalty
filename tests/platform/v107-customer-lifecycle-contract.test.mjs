import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('v107 source and canonical migrations are exact mirrors',async()=>{
  const [source,canonical]=await Promise.all([
    read('db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'),
    read('supabase/migrations/20260729171010_nestly_v107_customer_lifecycle_contract.sql')
  ]);
  assert.equal(source,canonical);
});

test('v107 gives new, returning, repeat and reactivated separate definitions',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'
  );
  assert.match(source,/'first_ever_purchase'/);
  assert.match(source,/'new_customer'/);
  assert.match(source,/'existing_returning_customer'/);
  assert.match(source,/'repeat_purchaser_in_period'/);
  assert.match(source,/'reactivated_customer'/);
  assert.match(source,/not a synonym for returning/);
  assert.match(source,/gap_days > effective_lapse_days/);
  assert.match(source,/period_purchases >= 2/);
  assert.match(source,/purchased_before_period/);
});

test('v107 cadence is evidence based, versioned and safe on empty periods',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'
  );
  assert.match(source,/percentile_cont\(0\.5\)/);
  assert.match(source,/customer_interval_min_observations/);
  assert.match(source,/reactivation_multiplier/);
  assert.match(source,/customer_median_interval/);
  assert.match(source,/business_fallback/);
  assert.match(source,/Customer-specific cadence uses only pre-period intervals/);
  assert.match(source,/'status', case when x\.eligible_transactions = 0 then 'no_data'/);
  assert.match(source,/case when x\.eligible_transactions = 0 then null/);
  assert.match(source,/case when t\.transacting_identified_customers = 0 then null/g);
});

test('v107 branch reports reserve business identity history for global authority',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'
  );
  assert.match(source,/v_business_wide_identity := app\.can_see_branch\(p_business, null\)/);
  assert.match(source,/v_business_wide_identity[\s\S]*s\.branch_id = p_branch/);
  assert.match(source,/'identity_scope', case when v_business_wide_identity[\s\S]*'selected_branch'/);
  assert.match(source,/'period_activity_scope'/);
  assert.match(source,/app\.can_see_branch\(p_business, p_branch\)/);
  assert.match(source,/Lifecycle is aggregate reporting only and does not expose customer PII/);
  assert.match(source,/trg_customer_lifecycle_policy_v107_append_only/);
  assert.match(source,/trg_customer_lifecycle_policy_v107_business_insert/);
  assert.match(
    source,
    /revoke all on function public\.get_customer_lifecycle_v107\([\s\S]*from public, anon/
  );
});

test('v107 lifecycle groups immutable sales through the approved current attribution',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'
  );
  assert.match(
    source,
    /app\.v111_effective_client_id\(s\.business_id, s\.client_id\) as client_id/
  );
  assert.match(
    source,
    /immutable sales\.client_id is resolved through app\.v111_effective_client_id for current synchronized reporting/
  );
  assert.doesNotMatch(source,/update public\.sales[\s\S]*client_id/i);
});

test('v107 uses the shared half-open-period residual contract',async()=>{
  const source=await read(
    'db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql'
  );
  assert.match(source,/app\.v106_sale_residual_minor\(s\.id, p_to, p_as_of\)/);
  assert.doesNotMatch(
    source,
    /select coalesce\(sum\(reversal\.amount_cents\),0\)[\s\S]*reversal\.reversal_of=s\.id/
  );
});
