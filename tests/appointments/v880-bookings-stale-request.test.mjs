/* nestly_v880 — a booking request whose preferred time has passed must not offer a Confirm tick
   that can only fail ("appointment start must be in the future"); it offers the v329 move-and-
   confirm rescue instead, on the one page that still shows such rows. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

test('v880 the Bookings row renderer gates the Confirm tick on the request not being stale', () => {
  const src = section('function paintBookingRequestsV584(){', '\n  window.decideBookingRequestV73=');
  assert.match(src, /const staleV880=actionable&&Boolean\(b\.preferred_at\)&&Date\.parse\(b\.preferred_at\)<Date\.now\(\);/);
  assert.match(src, /canConvertBooking&&!staleV880\?`<button class="booking-decision booking-decision-yes-v584"/);
  assert.match(src, /canConvertBooking&&staleV880\?`<div class="booking-move-v880"/);
  assert.match(src, /data-booking-stale-v880>Time has passed/);
});

test('v880 moveAndConfirmBookingRequestV880 calls the v329 rescue with the picked time and repaints', async () => {
  const src = section('window.moveAndConfirmBookingRequestV880=async id=>{', '\n  window.decideCr=');
  const calls = [];
  const context = {
    window: {}, canConvertBooking: true, pendingDecisions: new Set(), isCurrent: () => true,
    decisionNotices: new Map(), loads: 0, toasts: [],
    document: { querySelector: () => ({ value: '2099-01-02T10:00' }), querySelectorAll: () => [] },
    CSS: { escape: s => s },
    sgIso: v => v ? new Date(v + ':00+08:00').toISOString() : null,
    Date, S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (name, args) => { calls.push({ name, args }); return { data: { status: 'confirmed' }, error: null }; } },
    bookingDecisionNotice: (data) => ({ ok: true, text: `ok:${data.status}` }),
    toast: t => context.toasts.push(t),
    load: async () => { context.loads += 1; },
  };
  vm.createContext(context);
  vm.runInContext(src, context);
  await context.window.moveAndConfirmBookingRequestV880('req-1');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'staff_reschedule_and_confirm_booking_request_v329');
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0].args)), { p_business: 'biz-1', p_request: 'req-1', p_preferred: '2099-01-02T02:00:00.000Z', p_staff: null, p_clear_staff: false });
  assert.equal(context.loads, 1, 'the list reloads after the decision');
  assert.equal(context.pendingDecisions.size, 0);
  assert.equal(context.decisionNotices.get('req-1').text, 'ok:confirmed');
});

test('v880 moveAndConfirmBookingRequestV880 refuses a time that is still in the past without calling the server', async () => {
  const src = section('window.moveAndConfirmBookingRequestV880=async id=>{', '\n  window.decideCr=');
  const calls = [];
  const context = {
    window: {}, canConvertBooking: true, pendingDecisions: new Set(), isCurrent: () => true,
    decisionNotices: new Map(), toasts: [],
    document: { querySelector: () => ({ value: '2000-01-02T10:00' }), querySelectorAll: () => [] },
    CSS: { escape: s => s }, sgIso: v => new Date(v + ':00+08:00').toISOString(), Date, S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (name) => { calls.push(name); return { data: null, error: null }; } },
    bookingDecisionNotice: () => ({ ok: true, text: '' }), toast: t => context.toasts.push(t), load: async () => {},
  };
  vm.createContext(context);
  vm.runInContext(src, context);
  await context.window.moveAndConfirmBookingRequestV880('req-1');
  assert.deepEqual(calls, []);
  assert.deepEqual(context.toasts, ['The new time must be in the future']);
});

test('v880 the scheduler refusal is translated into a next step rather than shown raw', () => {
  const src = section('window.decideBookingRequestV73=async(id,decision)=>{', '\n  /* nestly_v880: the Bookings-page door');
  assert.match(src, /must be in the future/i);
  assert.match(src, /Pick a new date and time and press Move & confirm, or decline the request\./);
});
