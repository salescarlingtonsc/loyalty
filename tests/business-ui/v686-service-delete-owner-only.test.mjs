/* nestly_v686 (audit finding F068). Deleting a service permanently is the owner's alone:
   policy services_delete_v636 said so, business_manage_catalogue_item_v660 routed around it as
   SECURITY DEFINER, and the Services row rendered Delete for anyone with Services WRITE.

   This test EXECUTES the row's action-cell template rather than grepping for the guard, because
   a source regex stays green while the behaviour is dead. The cell is lifted verbatim out of
   app/app.js and evaluated as a template literal for three personas. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const CELL_START = '<td>${canWrite?`<div class="row" style="gap:6px;flex-wrap:wrap"><button class="btn ghost sm" data-svc-edit=';
const CELL_END = "'<span class=\"muted small\">View only</span>'}</td>";

function serviceActionCell({ canWrite, canDeleteServiceV682 }) {
  const from = app.indexOf(CELL_START);
  assert.ok(from >= 0, 'the Services row action cell moved — this test is pinned to it');
  const to = app.indexOf(CELL_END, from);
  assert.ok(to > from, 'the Services row action cell lost its read-only branch');
  const source = app.slice(from, to + CELL_END.length);
  return vm.runInNewContext('`' + source + '`', {
    canWrite,
    canDeleteServiceV682,
    s: { id: 'svc-1' },
    esc: (v) => String(v),
    serviceDisplayName: () => 'Signature Facial',
  });
}

test('an owner still sees Edit and Delete on a service row', () => {
  const html = serviceActionCell({ canWrite: true, canDeleteServiceV682: true });
  assert.match(html, /data-svc-edit="svc-1"/);
  assert.match(html, /data-catalogue-delete-v660="svc-1"/);
  assert.match(html, /data-catalogue-kind-v660="service"/);
});

test('a non-owner with Services write may edit but is never offered Delete', () => {
  const html = serviceActionCell({ canWrite: true, canDeleteServiceV682: false });
  assert.match(html, /data-svc-edit="svc-1"/, 'editing stays open to Services write');
  assert.doesNotMatch(html, /data-catalogue-delete-v660/,
    'a services-write teammate must not be offered a delete the server refuses (F068)');
  assert.doesNotMatch(html, />Delete</);
});

test('read-only Services access still renders the View only state', () => {
  const html = serviceActionCell({ canWrite: false, canDeleteServiceV682: false });
  assert.match(html, /View only/);
  assert.doesNotMatch(html, /data-svc-edit/);
  assert.doesNotMatch(html, /data-catalogue-delete-v660/);
});

test('the Delete gate is the page’s owner test, not the module-write test', () => {
  const from = app.indexOf('async function servicesPage(){');
  const to = app.indexOf('/* ---------- bookings ---------- */', from);
  assert.ok(from >= 0 && to > from, 'servicesPage moved');
  const page = app.slice(from, to);
  assert.match(page, /const canDeleteServiceV682=S\.myRole==='owner';/,
    'the Delete gate must read the owner role, matching app.is_salon_owner in the RPC');
});
