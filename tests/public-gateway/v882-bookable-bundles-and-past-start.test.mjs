/* nestly_v882 — bookable bundles reach the customer picker, the gateway and the request; a
   request whose preferred time has passed is a structured outcome, not a raw database sentence.
   The database half (bundle_id on requests/appointments, summed duration, bundle price on the
   appointment, past_start outcome, preferred_at expiry) is proven by the rolled-back suite
   db/tests/v882_booking_past_start_expiry_and_bookable_bundles.sql against production. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { validBookingPayload } from '../../supabase/functions/_shared/validation.ts';
import { canonicalBookingRequest } from '../../supabase/functions/_shared/security.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const gateway = await readFile(path.join(root, 'supabase/functions/public-booking/index.ts'), 'utf8');
const migration = await readFile(path.join(root, 'db/migrations/20261010_nestly_v882_booking_past_start_expiry_and_bookable_bundles.sql'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};
const base = {
  slug: 'kky-demo', name: 'Kiat Ke Ying', party: 1, preferred: '2099-01-02T02:00:00.000Z',
  submission_id: '3f9d2c1e-4b6a-4c8d-9e0f-1a2b3c4d5e6f', phone: '+6591241917',
};
const BUNDLE = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
const SERVICE = 'b1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';

test('v882 the gateway accepts a bundle request, and refuses a bundle alongside a service or a table hold', () => {
  assert.equal(validBookingPayload({ ...base, bundle: BUNDLE }), true);
  assert.equal(validBookingPayload({ ...base, bundle: 'not-a-uuid' }), false);
  assert.equal(validBookingPayload({ ...base, bundle: BUNDLE, service: SERVICE }), false, 'a request names a service OR a bundle');
  assert.equal(validBookingPayload({ ...base, bundle: BUNDLE, table_type: SERVICE }), false, 'a bundle is not a table hold');
  assert.equal(validBookingPayload({ ...base, service: SERVICE }), true, 'services keep working');
});

test('v882 the fingerprint carries the bundle append-only, so every pre-v882 payload hashes as before', () => {
  const without = canonicalBookingRequest({ ...base });
  assert.equal('bundle' in without, false, 'no bundle key when none was asked for');
  const withBundle = canonicalBookingRequest({ ...base, bundle: BUNDLE });
  assert.equal(withBundle.bundle, BUNDLE);
  assert.notDeepEqual(withBundle, without, 'two submissions differing only by bundle are different requests');
});

test('v882 the gateway hands p_bundle to both RPCs and refuses a bundle with a service on the availability read', () => {
  assert.match(gateway, /p_bundle: body\.bundle \|\| null/);
  assert.match(gateway, /p_bundle: bundle \|\| null/);
  assert.match(gateway, /\(bundle && \(!UUID_PATTERN\.test\(bundle\) \|\| service\)\)\) return publicError\(req\)/);
});

test('v882 the migration threads the bundle through page, submit, availability and confirm, with one duration authority', () => {
  assert.match(migration, /create or replace function app\.bundle_booking_duration_v882\(p_business uuid, p_bundle uuid\)/);
  assert.match(migration, /'bundles', v_bundles,/);
  assert.match(migration, /p_branch uuid DEFAULT NULL::uuid, p_bundle uuid DEFAULT NULL::uuid\)/);
  assert.match(migration, /drop function if exists public\.internal_public_booking_submit\(\n  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid\);/);
  assert.match(migration, /drop function if exists public\.internal_public_booking_availability\(text, uuid, uuid, date, integer, uuid\);/);
  assert.match(migration, /bundle_id = v_request\.bundle_id,\n\s+total_cents = case when v_bundle\.id is not null then v_bundle\.price_cents else total_cents end/);
  assert.match(migration, /'past_start', false/);
  assert.match(migration, /preferred_at < now\(\) - interval '1 day'/);
  assert.match(migration, /check \(service_id is null or bundle_id is null\)/);
});

test('v882 the customer picker lists bundles, sends the pick as `bundle`, and never a service with it', () => {
  const portal = section('async function renderPortal(slug){', '\nasync function hydrateCustomerAppLockSettingV860(');
  assert.match(portal, /const bundles=Array\.isArray\(biz\.bundles\)\?biz\.bundles\.filter\(/);
  assert.match(portal, /const hasServices=services\.length>0\|\|bundles\.length>0;/, 'a business with bundles only still gets a picker');
  assert.match(portal, /data-bundle="\$\{esc\(b\.id\)\}"/);
  assert.match(portal, /bundle:selBundle,/, 'the submit body carries the bundle');
  assert.match(portal, /selSvc=el\.dataset\.svc\|\|null;selBundle=null;/, 'picking a service clears the bundle');
  assert.match(portal, /selBundle=el\.dataset\.bundle\|\|null;selSvc=null;/, 'picking a bundle clears the service');
  assert.match(portal, /&bundle=\$\{encodeURIComponent\(selBundle\)\}/, 'availability is asked for the bundle length');
  assert.match(portal, /\[selBundle&&s\?'Bundle':'Service'/, 'the summary names the bundle as a bundle');
});

test('v882 team choice for a bundle keeps only people assigned to every member service (unassigned = anyone)', () => {
  const src = section('  const staffForService=()=>bookableStaff.filter(member=>{', '\n  const staffName=');
  const run = (selBundle, selSvc, bundleObj, bookableStaff) => {
    const context = { bookableStaff, branchChoice: false, selBranch: null, selSvc, selBundle, bundleObj: () => bundleObj };
    vm.createContext(context);
    return vm.runInContext(`${src.replace('const staffForService=', 'globalThis.staffForService=')}\n staffForService()`, context).map(m => m.id);
  };
  const staff = [
    { id: 'anyone', service_ids: [] },
    { id: 'both', service_ids: ['s1', 's2'] },
    { id: 'only-s1', service_ids: ['s1'] },
  ];
  assert.deepEqual(run('b1', null, { id: 'b1', service_ids: ['s1', 's2'] }, staff), ['anyone', 'both']);
  assert.deepEqual(run(null, 's1', null, staff), ['anyone', 'both', 'only-s1'], 'single-service rule unchanged');
});

test('v882 the business reads a bundle request by its own name everywhere the service name was printed', () => {
  /* nestly_v884 (owner: no differentiation): the helper returns the plain name, no prefix. */
  assert.match(appJs, /function bookingRequestForNameV882\(row\)\{\n(?:\s*\/\*[^\n]*\*\/\n)?\s+return row\?\.services\?\.name\|\|row\?\.bundles\?\.name\|\|null;/);
  const embeds = appJs.match(/bundles!booking_requests_bundle_id_fkey\(name\)/g) || [];
  assert.equal(embeds.length, 4, 'the Bookings list, the popup, and both pending-request reads embed the bundle name');
  assert.match(appJs, /if\(outcome==='past_start'\)return \{ok:false,text:'This time has already passed\./);
});
