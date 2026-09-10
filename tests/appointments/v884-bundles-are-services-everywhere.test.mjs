/* nestly_v884 — a bundle is a service everywhere, no differentiation (owner, 2026-09-10).
   The database half is proven by db/tests/v884_bundles_are_services_everywhere.sql against
   production. This pins the client half: the staff picker offers bundles as ordinary options,
   every appointment read embeds the bundle name, and the two name helpers return a plain name. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const migration = await readFile(path.join(root, 'db/migrations/20261010_nestly_v884_bundles_are_services_everywhere.sql'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

test('v884 the two name helpers return the plain name of a service or a bundle, never a prefix', () => {
  const src = section('function bookingRequestForNameV882(row){', '\nfunction bookingDecisionNotice(');
  const context = {};
  vm.createContext(context);
  vm.runInContext(`${src}\nglobalThis.a=bookingRequestForNameV882;globalThis.b=appointmentServiceNameV884;`, context);
  assert.equal(context.a({ services: { name: 'Facial' } }), 'Facial');
  assert.equal(context.a({ bundles: { name: 'The Elen Ritual' } }), 'The Elen Ritual');
  assert.equal(context.a({}), null);
  assert.equal(context.b({ services: null, bundles: { name: 'The Elen Ritual' } }), 'The Elen Ritual');
  assert.equal(context.b({ services: { name: 'Facial' }, bundles: null }), 'Facial');
});

test('v884 every appointment read that names the service also embeds the bundle name', () => {
  const serviceEmbeds = (appJs.match(/services!appointments_service_id_fkey\(name[^)]*\)/g) || []).length;
  const bundleEmbeds = (appJs.match(/bundles!appointments_bundle_id_fkey\(name\)/g) || []).length;
  assert.ok(serviceEmbeds >= 6, `expected the six name-bearing appointment reads, found ${serviceEmbeds}`);
  assert.equal(bundleEmbeds, serviceEmbeds, 'each name-bearing appointment read carries the bundle embed');
  assert.equal((appJs.match(/\.services\?\.name\|\|'General visit'/g) || []).length, 0,
    'no appointment or request render prints the raw services name with a General visit fallback any more');
});

test('v884 the staff New-appointment picker lists bundles as options when every member is bookable at the branch', () => {
  const src = section('  const bookableBundlesV884=', '\n  const staffOpts=');
  const context = {};
  vm.createContext(context);
  vm.runInContext(`const bundleError=null;const bundleRows=[
    {id:'b1',name:'Ritual',price_cents:15800,active:true,bundle_items:[
      {service_id:'s1',services:{duration_min:30,buffer_before_min:5,buffer_after_min:0}},
      {service_id:'s2',services:{duration_min:45,buffer_before_min:0,buffer_after_min:10}},
      {service_id:null,product_id:'p1',services:null}]},
    {id:'b2',name:'Products only',price_cents:900,active:true,bundle_items:[{service_id:null,product_id:'p2',services:null}]}];
    ${src}
    globalThis.out=bookableBundlesV884;`, context);
  assert.equal(context.out.length, 1, 'a product-only bundle is not schedulable');
  assert.deepEqual(JSON.parse(JSON.stringify(context.out[0])), {
    id: 'b1', name: 'Ritual', price_cents: 15800, duration_min: 75, buffer_before_min: 5, buffer_after_min: 10,
    member_service_ids: ['s1', 's2'],
  });
  const wiring = section('  function syncFormOptions(){', '\n  const selectedDuration=');
  assert.match(wiring, /bookableBundlesV884/, 'the picker draws from the bundle list');
  assert.match(wiring, /data-duration="\$\{b\.duration_min\}"/, 'a bundle option carries its summed duration like a service option');
  assert.match(wiring, /every\(/, 'a bundle is offered only when every member service is bookable at the branch');
});

test('v884 the migration routes every scheduling path through one resolver', () => {
  assert.match(migration, /create or replace function app\.booking_item_v884\(p_business uuid, p_item uuid\)/);
  assert.match(migration, /create or replace function app\.staff_can_do_item_v884\(p_business uuid, p_staff uuid, p_item uuid\)/);
  for (const fn of ['book_appointment_smart_v47_v94_base', 'staff_free_for_appointment_v120_base', 'staff_free_for_appointment_v47',
    'suggest_appointment_staff_v47_v94_base', 'v660_autoapprove_booking_request', 'on_appointment_completed',
    'customer_get_appointments_page', 'customer_get_booking_requests', 'customer_get_repeat_booking_preference_v167',
    'internal_public_booking_lookup', 'whatsapp_enqueue_appointment_notice_v557']) {
    assert.match(migration, new RegExp(`CREATE OR REPLACE FUNCTION (public|app)\\.${fn}\\(`), `${fn} is replaced`);
  }
  assert.match(migration, /app\.ps1c_bundle_lines_v204\(new\.business_id, new\.bundle_id, 1\)/, 'completion itemises through the till allocator');
});
