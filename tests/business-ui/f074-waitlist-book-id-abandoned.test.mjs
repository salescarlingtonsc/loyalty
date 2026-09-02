/* Audit F074 — pendingWaitlistBookIdV571 (a module-level global set when staff click "Book" on a
   waitlist row, app/app.js:853) was consumed exactly once, unconditionally, inside the
   New-appointment form's "Book appointment" success handler, which marks THAT stored waitlist
   row 'booked'. Nothing cleared it if the booking that set it was abandoned: closing the form,
   opening a fresh New-appointment form for someone else, or navigating away all left it standing.
   The next, entirely unrelated appointment booked in the same session then silently marked the
   original waitlist row 'booked' even though that walk-in was never actually seated.

   Fix, two parts:
   1. openNewAppointmentForm() now takes a `fromWaitlist` flag (default false) and clears
      pendingWaitlistBookIdV571 whenever a form is opened WITHOUT it — the toolbar "New
      appointment" button, a calendar day-slot click, and the Customer-360 hand-off (which reuses
      the same `apptPrefillClient||apptPrefillV575` branch as the real waitlist prefill, but can
      fire with apptPrefillClient alone). Only the waitlist's own call site passes
      fromWaitlist:!!apptPrefillV575. closeNewAppointmentForm() also clears it directly, covering
      Close and any other route that ends the form without booking.
   2. Even a form legitimately opened from the waitlist can be re-pointed at a different customer
      before saving, so the consume site now re-fetches the waitlist row's own client_id and only
      marks it 'booked' when it matches the appointment's actual client (or the row has no client
      on record to compare, which is trusted as before).

   This suite executes the real functions out of app/app.js in a vm sandbox: openNewAppointmentForm
   / closeNewAppointmentForm behaviourally (does the flag actually survive/clear?), and the
   consume-site guard behaviourally (does a mismatched client_id actually skip the write?). */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(source, from, to) {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
}

function formFnsSandbox() {
  const block = section(
    app,
    'function closeNewAppointmentForm(){',
    'function closeBlockedTimeDialog('
  );
  assert.match(block, /function openNewAppointmentForm\(\{date='',staffId='',time='',serviceId='',fromWaitlist=false\}=\{\}\)/,
    'openNewAppointmentForm must accept fromWaitlist, default false');
  assert.match(block, /if\(!fromWaitlist\)pendingWaitlistBookIdV571='';/,
    'opening the form without fromWaitlist must clear a leftover waitlist id');
  assert.match(section(app, 'function closeNewAppointmentForm(){', '}\n  function openNewAppointmentForm'),
    /pendingWaitlistBookIdV571='';/,
    'closing the form (e.g. Close, or abandoning it) must also clear a leftover waitlist id');

  const els = {
    ad: {value: ''}, at: {value: ''}, astf: {value: '', options: []}, as: {value: '', options: []},
    generalDuration: {hidden: false}, appointmentCustomerSearch: {focus() {}}, openAppointmentForm: {focus() {}}
  };
  const ctx = {
    pendingWaitlistBookIdV571: 'wl-1',
    $: id => els[id],
    appointmentLayout: {classList: {add() {}, remove() {}}},
    appointmentFormCard: {hidden: true, scrollIntoView() {}},
    matchMedia: () => ({matches: true}),
    requestAnimationFrame: fn => fn()
  };
  vm.createContext(ctx);
  vm.runInContext(
    `${block}\nglobalThis.__open=openNewAppointmentForm;globalThis.__close=closeNewAppointmentForm;globalThis.__get=()=>pendingWaitlistBookIdV571;globalThis.__set=v=>{pendingWaitlistBookIdV571=v};`,
    ctx
  );
  return ctx;
}

test('F074: opening the form the ordinary way (toolbar button / day-slot click) clears a stale waitlist id', () => {
  const ctx = formFnsSandbox();
  ctx.__set('wl-abandoned');
  ctx.__open({date: '2026-09-05'});
  assert.equal(ctx.__get(), '', 'a plain form-open must not inherit a leftover pendingWaitlistBookIdV571');
});

test('F074: opening the form with fromWaitlist:true (the real waitlist Book prefill) preserves the id', () => {
  const ctx = formFnsSandbox();
  ctx.__set('wl-1');
  ctx.__open({date: '2026-09-05', fromWaitlist: true});
  assert.equal(ctx.__get(), 'wl-1', 'the waitlist-originated open is the one legitimate case that must survive');
});

test('F074: closing the form (abandon / Close) clears a leftover waitlist id', () => {
  const ctx = formFnsSandbox();
  ctx.__set('wl-1');
  ctx.__close();
  assert.equal(ctx.__get(), '', 'closing the form after opening it from the waitlist must not leave the id standing for a later unrelated booking');
});

function consumeSiteSandbox({waitlistRow, waitlistError} = {}) {
  const block = section(
    app,
    'if(pendingWaitlistBookIdV571){',
    "/* A4: \"Book next visit\""
  );
  const calls = {select: [], update: []};
  const ctx = {
    pendingWaitlistBookIdV571: 'wl-1',
    S: {biz: {id: 'biz-1'}},
    request: {p_client: 'client-B'},
    sb: {
      from: table => ({
        select: cols => ({
          eq: () => ({
            eq: () => ({
              maybeSingle: () => {
                calls.select.push(table);
                return waitlistError
                  ? Promise.resolve({data: null, error: waitlistError})
                  : Promise.resolve({data: waitlistRow, error: null});
              }
            })
          })
        }),
        update: patch => ({
          eq: () => ({
            eq: () => {
              calls.update.push([table, patch]);
              return Promise.resolve({error: null});
            }
          })
        })
      })
    }
  };
  vm.createContext(ctx);
  vm.runInContext(block, ctx);
  ctx.__calls = calls;
  return ctx;
}

const settle = () => new Promise(resolve => setImmediate(resolve));

test('F074: the waitlist row is marked booked when its client matches the appointment that was actually saved', async () => {
  const ctx = consumeSiteSandbox({waitlistRow: {client_id: 'client-B'}});
  await settle(); await settle();
  assert.equal(ctx.__calls.update.length, 1, 'a matching client must still mark the row booked');
  assert.equal(ctx.__calls.update[0][0], 'waitlist');
  assert.equal(JSON.stringify(ctx.__calls.update[0][1]), JSON.stringify({status: 'booked'}));
});

test('F074: the waitlist row is NOT marked booked when the saved appointment is for a different customer', async () => {
  // This is the exact failure scenario the audit named: staff opened the form from waitlist row
  // A (client A), got interrupted, picked a different existing customer B in the SAME open form,
  // and saved. Without this check, row A would be wrongly marked booked for B's appointment.
  const ctx = consumeSiteSandbox({waitlistRow: {client_id: 'client-A'}});
  await settle(); await settle();
  assert.equal(ctx.__calls.update.length, 0,
    'a mismatched client must skip the write — the waitlist row must stay in the queue for staff to notice');
});

test('F074: a walk-in waitlist row with no client on record is trusted as before (nothing to compare)', async () => {
  const ctx = consumeSiteSandbox({waitlistRow: {client_id: null}});
  await settle(); await settle();
  assert.equal(ctx.__calls.update.length, 1,
    'a row that was never linked to a customer record has no client_id to compare, so the pre-fix behaviour is kept');
});

test('F074: the waitlist row having vanished (deleted) or the lookup erroring must not throw or write', async () => {
  const gone = consumeSiteSandbox({waitlistRow: null});
  await settle(); await settle();
  assert.equal(gone.__calls.update.length, 0);

  const errored = consumeSiteSandbox({waitlistError: {message: 'boom'}});
  await settle(); await settle();
  assert.equal(errored.__calls.update.length, 0);
});
