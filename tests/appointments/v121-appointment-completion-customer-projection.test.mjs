import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const [
  migration,mirror,sqlFixture,ledger,trace,fixtures,registry,
  sourcePlan,canonicalPlan
]=await Promise.all([
  read('db/migrations/20260731_nestly_v121_effective_loyalty_sale_earn_boundary.sql'),
  read('supabase/migrations/20260731130000_nestly_v121_effective_loyalty_sale_earn_boundary.sql'),
  read('db/tests/v121_appointment_completion_customer_projection.sql'),
  read('docs/qa/OWNER-ISSUE-LEDGER.md'),
  read('docs/qa/TRACEABILITY-MATRIX.md'),
  read('docs/qa/REALISTIC-FIXTURES.md'),
  read('docs/design/ps0/writer-registry.json'),
  read('db/migrations/migration-order.plan.json'),
  read('supabase/canonical-migration-order.plan.json')
]);

test('v121 source and Supabase migration are exact forward-only mirrors',()=>{
  assert.equal(mirror,migration);
  assert.match(
    migration,
    /^-- NESTLY v121 — EFFECTIVE LOYALTY SALE-EARN BOUNDARY/m
  );
  assert.match(
    migration,
    /unexpected on_sale_recorded predecessor/
  );
  assert.doesNotMatch(
    migration,
    /drop\s+(?:table|schema)|disable\s+row\s+level\s+security/i
  );
});

test('sale earn resolves exact-branch effective Loyalty mode and requires rw',()=>{
  assert.match(
    migration,
    /app\.effective_platform_module_mode_v94\(/
  );
  assert.match(
    migration,
    /new\.business_id,new\.branch_id,''loyalty'''/
  );
  assert.match(migration,/effective\.mode=''rw''/);
  assert.match(
    migration,
    /execute replace\(v_def,v_old,v_new\)/
  );
  assert.match(
    migration,
    /insert into public\.points_ledger/
  );
  assert.doesNotMatch(
    migration,
    /delete from public\.points_ledger|update public\.points_ledger/
  );
});

test('rollback SQL proves enabled completion, replay and all customer readers',()=>{
  assert.match(
    sqlFixture,
    /public\.set_appointment_status_v47\([\s\S]*v_enabled_appointment[\s\S]*'completed'/
  );
  assert.match(
    sqlFixture,
    /appointment_id=v_enabled_appointment\)<>1/
  );
  assert.match(
    sqlFixture,
    /entry_type='earn'\)<>1/
  );
  assert.match(
    sqlFixture,
    /customer_get_wallet\(\)[\s\S]*customer_get_business_summary\(v_slug\)[\s\S]*customer_get_loyalty_details/
  );
  assert.match(sqlFixture,/loyalty,balance}'\)::integer<>600/);
  assert.match(sqlFixture,/items,0,points_delta}'\)::integer<>600/);
});

test('rollback SQL covers disabled, read-only and wrong-branch zero mutation',()=>{
  assert.match(sqlFixture,/wrong-branch completion mutated persistent state/);
  assert.match(
    sqlFixture,
    /"module":"loyalty","mode":"disabled"/
  );
  assert.match(
    sqlFixture,
    /branch-disabled Loyalty completion created % point/
  );
  assert.match(
    sqlFixture,
    /'module','loyalty','mode','r'/
  );
  assert.match(
    sqlFixture,
    /branch-read-only Loyalty completion created % point/
  );
  assert.match(
    sqlFixture,
    /where business_id=v_business\)<>4/
  );
  assert.match(
    sqlFixture,
    /entry_type='earn'\)<>1/
  );
});

test('durable QA memory records the concrete SPA-GLOW defect and acceptance',()=>{
  assert.match(
    ledger,
    /\| `OPSUX-004` \|[\s\S]*firm-level effective Loyalty disable[\s\S]*600 hidden points/
  );
  assert.match(
    trace,
    /\| `OPSUX-004` \|[\s\S]*firm `disabled`[\s\S]*branch `disabled`[\s\S]*branch `r`/
  );
  assert.match(fixtures,/Appointment completion truth/);
  assert.match(fixtures,/one \+600 earn/);
  assert.match(fixtures,/Farah, assigned only to Orchard/);
});

test('writer registry and both migration plans bind v121',()=>{
  const registryJson=JSON.parse(registry);
  const saleWriter=registryJson.writers.find(
    ({id})=>id==='db.fn:app.on_sale_recorded/0'
  );
  assert.ok(saleWriter);
  // V311 (W5a) re-stated app.on_sale_recorded from the v37b + v121 lineage to land the
  // per-programme earn loop; V332 re-stated it again, adding a join on the live
  // retention_programs row (deleted_at is null) to the retention grant loop so a deleted
  // Bring-back rule stops granting immediately even though its published retention_program_
  // versions snapshot is immutable. Either restate is why it is now the defining migration.
  // The v121 boundary itself is unchanged and still asserted — every restate has kept the
  // predicate verbatim, and each migration re-runs v121's own postcondition battery.
  assert.equal(
    saleWriter.latest_file,
    '20260815090300_nestly_v332_retention_program_lifecycle.sql'
  );
  assert.match(saleWriter.loyalty_boundary,/resolves exactly rw/);
  assert.match(saleWriter.programme_scope,/ON CONFLICT arbiter NAMES/);
  assert.match(
    sourcePlan,
    /20260731_nestly_v121_effective_loyalty_sale_earn_boundary\.sql/
  );
  assert.match(
    canonicalPlan,
    /20260731130000[\s\S]*nestly_v121_effective_loyalty_sale_earn_boundary/
  );
});
