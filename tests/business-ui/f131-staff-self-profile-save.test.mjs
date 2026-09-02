/* Audit F131 — the account menu's "Your display name" form is rendered for EVERY signed-in staff
   member, not just the owner. It mirrored the new name into public.staff.full_name with

     await sb.from('staff').update({full_name:name}).eq('business_id',…).eq('user_id',…)

   whose result was not even assigned to a variable. Policy staff_update on public.staff is
   `for update to authenticated using (app.is_salon_owner(business_id))` — there is no self-row
   predicate — so for every non-owner role (manager, staff, frontdesk, bookkeeper) the statement
   matched ZERO rows. PostgREST reports a zero-row UPDATE as a 204, not an error, so nothing was
   thrown and the handler unconditionally printed "Name saved." while the name every colleague
   reads (Team roster, till staff picker, sales/commission report, calendar) never changed.

   Fix (nestly_v687): the mirror goes through public.staff_update_my_profile_v687, a SECURITY
   DEFINER RPC that writes full_name on the caller's own active row and nothing else, and its
   error is read and shown.

   This test EXECUTES the real submit handler lifted out of app/app.js — not a re-implementation
   of it — against stubbed sb/CUI/DOM, because the defect was precisely that a returned error was
   never looked at, and only running the code can prove it is looked at now. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const section = (source, from, to) => {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
};

const HANDLER_SRC = section(
  app,
  "const profileNameForm=$('profileNameFormV158');",
  "    $('pmSignout').onclick="
);

/* The fix's own comment quotes the statement it replaced, so the regression check reads the CODE
   with comments stripped — otherwise the explanation of the bug would look like the bug. */
const HANDLER_CODE = HANDLER_SRC.replace(/\/\*[\s\S]*?\*\//g, '');

test('F131: the handler no longer writes public.staff through PostgREST at all', () => {
  assert.ok(
    !/sb\.from\(['"]staff['"]\)\.update/.test(HANDLER_CODE),
    'the display-name handler is back to a raw staff UPDATE, which RLS silently drops for every non-owner role'
  );
  assert.ok(
    HANDLER_CODE.includes('staff_update_my_profile_v687'),
    'the display-name handler must mirror the name through the v687 RPC'
  );
});

/* Lift the handler out of its enclosing render function: drop the element lookup (we supply the
   stub as a global) and bind the assignment to a name this test can call. */
function loadHandler(context) {
  const src = HANDLER_SRC
    .replace("const profileNameForm=$('profileNameFormV158');", '')
    .replace('if(profileNameForm)profileNameForm.onsubmit=', 'globalThis.__submit=');
  assert.ok(src.includes('globalThis.__submit='), 'the submit handler assignment moved');
  vm.createContext(context);
  vm.runInContext(src, context);
  return context.__submit;
}

function harness({authError = null, rpcError = null, value = 'Siti Rahayu'} = {}) {
  const calls = {rpc: [], auth: [], rendered: 0};
  const status = {textContent: ''};
  const input = {value};
  const button = {};
  const context = {
    console: {error() {}},
    page: 'dashboard',
    profileNameForm: {querySelector: () => button},
    $: id => (id === 'profileDisplayNameV158' ? input : id === 'profileNameStatusV158' ? status : null),
    CUI: {setButtonBusy() {}},
    S: {biz: {id: 'biz-1'}, user: {id: 'user-1', user_metadata: {}}},
    renderProfile: () => {calls.rendered += 1},
    // The real one, so the surfaced text is the app's own vocabulary rather than a test double.
    ownerErrorText: error => String(error?.message || '').trim() || 'Something went wrong. Nothing was changed.',
    sb: {
      auth: {
        updateUser: async payload => {
          calls.auth.push(payload);
          return authError ? {data: null, error: authError} : {data: {user: {id: 'user-1'}}, error: null};
        }
      },
      rpc: async (name, args) => {
        calls.rpc.push({name, args});
        return rpcError ? {data: null, error: rpcError} : {data: {status: 'ok'}, error: null};
      }
    }
  };
  return {submit: loadHandler(context), calls, status};
}

test('F131: a successful save calls the v687 RPC with the current business and the typed name', async () => {
  const {submit, calls, status} = harness();
  await submit({preventDefault() {}});

  assert.equal(calls.rpc.length, 1, 'the RPC must be the one and only staff write');
  assert.equal(calls.rpc[0].name, 'staff_update_my_profile_v687');
  // The args object is created inside the vm realm, so compare by value, not by prototype.
  assert.deepEqual(JSON.parse(JSON.stringify(calls.rpc[0].args)), {p_business: 'biz-1', p_name: 'Siti Rahayu'});
  assert.equal(status.textContent, 'Name saved.');
  assert.equal(calls.rendered, 1, 'the menu must repaint so the new name is visible');
});

test('F131: a server refusal is NOT reported as a save — this is the whole bug', async () => {
  const {submit, calls, status} = harness({
    rpcError: {message: 'no active staff record for you in this business', code: '42501'}
  });
  await submit({preventDefault() {}});

  assert.equal(calls.rpc.length, 1);
  assert.notEqual(status.textContent, 'Name saved.',
    'a refused mirror must never print "Name saved." — that is exactly what F131 did');
  assert.equal(status.textContent, 'no active staff record for you in this business',
    "the server's own reason must reach the person, not a blanket sentence");
  assert.equal(calls.rendered, 0, 'nothing was saved, so nothing should be repainted as saved');
});

test('F131: a validation refusal from the server is surfaced verbatim too', async () => {
  const {submit, status} = harness({
    rpcError: {message: 'a display name is between 2 and 120 characters', code: '22023'}
  });
  await submit({preventDefault() {}});
  assert.equal(status.textContent, 'a display name is between 2 and 120 characters');
});

test('F131: the auth.users write still gates the mirror — no staff write when the account update fails', async () => {
  const {submit, calls, status} = harness({authError: {message: 'auth is down'}});
  await submit({preventDefault() {}});
  assert.equal(calls.rpc.length, 0, 'the mirror must not run when the account write failed');
  assert.notEqual(status.textContent, 'Name saved.');
});

test('F131: a name shorter than two characters is refused before any network call', async () => {
  const {submit, calls, status} = harness({value: ' S '});
  await submit({preventDefault() {}});
  assert.equal(calls.auth.length, 0);
  assert.equal(calls.rpc.length, 0);
  assert.equal(status.textContent, 'Enter your name.');
});
