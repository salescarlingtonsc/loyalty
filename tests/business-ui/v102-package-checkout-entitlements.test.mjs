import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app=(fs.readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+fs.readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migration=fs.readFileSync(new URL(
  '../../supabase/migrations/20260729150000_nestly_v102_package_checkout_entitlements.sql',
  import.meta.url
),'utf8');

const section=(start,end)=>{
  const a=app.indexOf(start),b=app.indexOf(end,a+start.length);
  assert.ok(a>=0&&b>a,`missing section ${start}`);
  return app.slice(a,b);
};

test('logo storage ownership helper is executable only by authenticated policy callers',()=>{
  assert.match(migration,/revoke all on function app\.v95_storage_path_owned\(text\) from public, anon;/);
  assert.match(migration,/grant execute on function app\.v95_storage_path_owned\(text\) to authenticated;/);
  assert.doesNotMatch(migration,/grant execute on function app\.v95_storage_path_owned\(text\) to (?:public|anon)/);
});

test('package plans snapshot their server-derived list value and expose an honest discount preview',()=>{
  assert.match(migration,/list_unit_cents_snapshot bigint/);
  assert.match(migration,/list_value_cents_snapshot bigint/);
  assert.match(migration,/v_service\.price_cents::bigint\*p_sessions::bigint/);
  const packages=section('async function packagesPage(options){','async function branchesPage(){');
  assert.match(packages,/Exact service \/ variation/);
  assert.match(packages,/Peekaa compares the package price with the exact service price × sessions/);
  assert.match(packages,/save_package_plan_v102/);
  assert.match(packages,/No discount/);
  assert.match(packages,/% discount/);
});

test('service variations flow into services, packages, appointments and Quick Earn labels',()=>{
  assert.match(migration,/add column if not exists variant_label text/);
  assert.match(app,/function serviceDisplayName\(service=\{\}\)/);
  assert.match(app,/Variation \(optional\)/);
  assert.match(app,/variant_label:variant/);
  assert.match(app,/select\('id,name,variant_label,duration_min,price_cents,active'(?:,\{count:'exact'\})?\)/);
});

test('Quick Earn shows owned packages and pending vouchers, and consumes sessions without payment',()=>{
  const till=section('async function tillPage(){','async function salesPage(){');
  assert.match(till,/staff_get_customer_entitlements_v102/);
  assert.match(till,/Use an existing customer package/);
  assert.match(till,/data-use-package/);
  assert.match(till,/use_package_session/);
  assert.match(till,/No payment is taken\. One session is deducted and recorded as a visit\./);
  assert.match(till,/Reward voucher ready/);
  assert.match(till,/Scan reward QR/);
});

test('package earning is owner-configurable and checkout points come from writer receipts',()=>{
  assert.match(migration,/set_package_points_policy_v102/);
  assert.match(migration,/app\.is_salon_owner\(p_business\)/);
  const packages=section('async function packagesPage(options){','async function branchesPage(){');
  assert.match(packages,/Make package purchases eligible for loyalty points/);
  assert.match(packages,/points are earned only when an active published loyalty programme applies/);
  assert.match(packages,/Using sessions never earns points again/);
  const till=section('async function tillPage(){','async function salesPage(){');
  assert.match(till,/checkoutPointsReceiptV102/);
  assert.match(till,/packageResults/);
  assert.match(till,/pointsEarned:pointsReceipt\.pointsEarned/);
  assert.doesNotMatch(till,/refreshedPoints-beforePoints/);
});

test('recommender is sector-aware and allows a custom target beyond eight percent',()=>{
  const loyalty=section('async function loyaltyPage(','async function referralsPage(){');
  assert.match(loyalty,/Suggested starting range for \$\{esc\(sectorProfile\.label\)\}/);
  assert.match(loyalty,/type="range" min="0\.5" max="30"/);
  assert.match(loyalty,/type="number" min="0\.5" max="50"/);
  assert.doesNotMatch(loyalty,/Typical café 2–8%/);
  assert.doesNotMatch(loyalty,/Most shops stay under 8%/);
});
