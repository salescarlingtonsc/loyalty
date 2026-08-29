/* V548 — the dashboard attention list ("Customers to bring back").
   Strategy ruling 2026-08-26: the first screen must answer "who is overdue against their own
   visit rhythm, and how much monthly spend is fading". The SERVER owns every judgement
   (get_attention_list_v548 — cadence, status, monthly value); the card only prints it.

   These tests EXECUTE the extracted loader against a stub DOM and a fixture payload shaped
   exactly like the deployed RPC's output (v145 rule: the browser must not re-derive server
   judgements; a test that only greps the source proves nothing about behaviour). */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260827_nestly_v548_attention_list.sql'), 'utf8');

/* ---------------------------------------------------------------- extraction */

const blockStart = app.indexOf('function attentionWhatsAppUrlV548(');
const blockEnd = app.indexOf('/* V180 (owner instruction', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart, 'the V548 block must sit before the V180 schedule comment');
const block = app.slice(blockStart, blockEnd);
assert.ok(block.includes('async function loadAttentionListV571('), 'loader must live in the extracted block');

function makeHarness({ rpcResult, role = 'owner', canRead = true }) {
  const calls = [];
  const outreachHandlers = [];
  const host = {
    innerHTML: '<!-- untouched -->',
    /* nestly_v571: the loader's staleness guard is now `host.isConnected` — it can no longer
       assume the dashboard root, because the card mounts inside the Bring-back view. A real node
       carries this; the stub must too, or every render assertion below silently reads the
       untouched placeholder. */
    isConnected: true,
    /* V550: the loader wires a click recorder onto every Message link. The stub parses its own
       innerHTML for the outreach ids and hands back capturing link stubs, so a test can fire the
       captured handler and watch the RPC. */
    querySelectorAll(sel) {
      if (sel !== 'a[data-attention-outreach]') return [];
      return [...host.innerHTML.matchAll(/data-attention-outreach="([^"]+)"/g)].map((m) => ({
        dataset: { attentionOutreach: m[1] },
        addEventListener: (event, fn) => outreachHandlers.push({ id: m[1], event, fn })
      }));
    }
  };
  const domRoot = {
    isConnected: true,
    querySelector: (sel) => (sel === '#growBbAttentionV571' ? host : null)
  };
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    CUI: { icon: (name) => `<i data-icon="${name}"></i>` },
    canReadModule: () => canRead,
    S: { myRole: role, biz: { id: 'biz-1', name: 'Kaya & Co', currency: 'SGD' } },
    sb: { rpc: async (fn, args) => { calls.push({ fn, args }); return rpcResult; } },
    $: () => null
  };
  const context = vm.createContext(sandbox);
  const exportsRef = {};
  context.__exports = exportsRef;
  vm.runInContext(
    block + '\n__exports.load = loadAttentionListV571;\n__exports.wa = attentionWhatsAppUrlV548;',
    context
  );
  return { load: exportsRef.load, wa: exportsRef.wa, host, domRoot, calls, outreachHandlers };
}

const FIXTURE = {
  data: {
    summary: { considered: 12, due: 1, overdue: 2, slipping: 1, monthly_at_risk_cents: 78400, one_time_count: 9 },
    rows: [
      { client_id: 'c1', full_name: 'Jane Tan', phone: '+65 9123 4567', last_visit_at: '2026-07-12T04:00:00Z',
        last_visit_days: 45, cadence_days: 30.0, status: 'overdue', average_transaction_cents: 15000, monthly_value_cents: 15000 },
      { client_id: 'c2', full_name: 'Amanda <Lim>', phone: '81234567', last_visit_at: '2026-06-02T04:00:00Z',
        last_visit_days: 85, cadence_days: 14.0, status: 'slipping', average_transaction_cents: 8000, monthly_value_cents: 17143 },
      { client_id: 'c3', full_name: 'Michelle Ng', phone: null, last_visit_at: '2026-07-25T04:00:00Z',
        last_visit_days: 32, cadence_days: 31.0, status: 'due', average_transaction_cents: 6000, monthly_value_cents: 5806 }
    ]
  },
  error: null
};

/* ---------------------------------------------------------------- behaviour */

test('V548 the card prints the server judgement: names, rhythm line, status chips, money at risk', async () => {
  const h = makeHarness({ rpcResult: FIXTURE });
  await h.load(h.domRoot, null);
  assert.equal(h.calls.length, 1, 'exactly one RPC read');
  assert.equal(h.calls[0].fn, 'get_attention_list_v548');
  // The args object is born inside the vm realm; JSON round-trip avoids the cross-realm prototype.
  assert.deepEqual(JSON.parse(JSON.stringify(h.calls[0].args)), { p_business: 'biz-1', p_branch: null, p_limit: 8 });
  const html = h.host.innerHTML;
  assert.ok(html.includes('Customers to bring back'));
  assert.ok(html.includes('Jane Tan'));
  assert.ok(html.includes('Amanda &lt;Lim&gt;'), 'names are escaped, never raw');
  assert.ok(html.includes('3 customers overdue'), 'overdue headline = overdue + slipping');
  assert.ok(html.includes('SGD 784.00'), 'at-risk money comes from the summary, not re-added client-side');
  assert.ok(html.includes('Last visit 45d ago'), "Jane's lapse is the server's number");
  assert.ok(html.includes('usually every ~30d'), "Jane's rhythm is the server's cadence");
  assert.ok(html.includes('Overdue') && html.includes('Slipping away') && html.includes('Due back'),
    'all three status chips render from the status map');
  assert.ok(html.includes('9 customers visited once'), 'the one-time count reaches the card');
  assert.ok(html.includes('href="#/customers"'), 'the card leads into Customers');
});

test('V548 the WhatsApp action is a staff-tap wa.me draft with a normalised 65 number', async () => {
  const h = makeHarness({ rpcResult: FIXTURE });
  await h.load(h.domRoot, null);
  const html = h.host.innerHTML;
  assert.ok(html.includes('https://wa.me/6591234567?text='), "Jane's +65 formatted number folds to 6591234567");
  assert.ok(html.includes('https://wa.me/6581234567?text='), "Amanda's bare 8-digit number gains the 65 prefix");
  const encoded = decodeURIComponent(html.split('https://wa.me/6591234567?text=')[1].split('"')[0]);
  assert.ok(encoded.includes('Hi Jane!'), 'the draft greets by first name');
  assert.ok(encoded.includes('Kaya & Co'), "the draft names the business");
  // Michelle has no phone: her row renders with no dead Message button.
  const michelleRow = html.split('Michelle Ng')[1].split('</li>')[0];
  assert.ok(!michelleRow.includes('wa.me'), 'no phone, no Message action');
});

test('V548 the wa helper refuses non-Singapore-mobile shapes rather than drafting to a wrong number', () => {
  const h = makeHarness({ rpcResult: FIXTURE });
  assert.equal(h.wa('12345', 'X', 'Y'), null);
  assert.equal(h.wa('62345678', 'X', 'Y'), null, 'landline-shaped 6xxxxxxx is refused');
  assert.ok(h.wa('9123 4567', 'X', 'Y').startsWith('https://wa.me/6591234567?text='));
});

test('V548 an employee without the clients module sees nothing and no read is even attempted', async () => {
  const h = makeHarness({ rpcResult: FIXTURE, role: 'staff', canRead: false });
  await h.load(h.domRoot, null);
  assert.equal(h.calls.length, 0, 'no RPC call without clients scope');
  assert.equal(h.host.innerHTML, '', 'the card is absent, not an empty shell');
});

test('V548 a business with nothing to act on gets no card at all', async () => {
  const h = makeHarness({ rpcResult: { data: { summary: { due: 0, overdue: 0, slipping: 0, considered: 2, monthly_at_risk_cents: 0, one_time_count: 0 }, rows: [] }, error: null } });
  await h.load(h.domRoot, null);
  assert.equal(h.host.innerHTML, '', 'an empty attention panel is noise, not information');
});

test('V548 an RPC error leaves the dashboard silent rather than broken', async () => {
  const h = makeHarness({ rpcResult: { data: null, error: { message: 'boom' } } });
  await h.load(h.domRoot, null);
  assert.equal(h.host.innerHTML, '', 'errors render nothing');
});


test('V550 a Message tap records outreach evidence without blocking the wa.me navigation', async () => {
  const h = makeHarness({ rpcResult: FIXTURE });
  await h.load(h.domRoot, null);
  // Jane and Amanda have phones; Michelle does not — exactly two recorders wired.
  assert.equal(h.outreachHandlers.length, 2);
  assert.ok(h.outreachHandlers.every((x) => x.event === 'click'));
  h.outreachHandlers[0].fn();
  const record = h.calls.find((c) => c.fn === 'record_attention_outreach_v550');
  assert.ok(record, 'the tap issues the outreach-record RPC');
  assert.deepEqual(JSON.parse(JSON.stringify(record.args)), { p_business: 'biz-1', p_client: 'c1' });
});

/* ---------------------------------------------------------------- wiring + server authority */

/* nestly_v571 (owner ruling): the card left the Dashboard for the Bring-back module in Rewards
   Programme, where the vouchers this audience is being argued for are configured. These assertions
   move with it — and the Dashboard one is kept as a negative, so the card cannot drift back. */
/* nestly_v613 (owner photo: the whole "Customers to bring back" card struck corner to corner —
   "delete this"). The card no longer mounts anywhere. The loader and every assertion above it are
   deliberately kept: they still execute the real renderer against the real RPC shape, so the
   server contract stays under test and re-mounting the card is one line. What this test now
   guards is that it is mounted NOWHERE — neither in Bring-back nor back on the Dashboard. */
test('V613 the attention card is mounted nowhere, and its loader is still whole', () => {
  assert.ok(!app.includes('<div id="growBbAttentionV571"></div>'),
    'the Bring-back view no longer hosts the card');
  assert.ok(!app.includes('loadAttentionListV571(outerMain'),
    'nothing calls the loader at paint any more');
  assert.ok(!app.includes('dashboardAttentionV548'),
    'the Dashboard does not host or load the attention card either');
  assert.ok(block.includes('async function loadAttentionListV571('),
    'the loader itself is intact, so the server contract above stays under test');
});

test('V548 the browser never re-derives the server judgement', () => {
  // The loader may round and print, but the bucketing thresholds live in SQL only.
  assert.ok(!block.includes('1.5') && !block.includes('2.5'),
    'cadence multipliers exist only in the migration');
  assert.ok(migration.includes("then 'slipping'") && migration.includes("then 'overdue'")
    && migration.includes("then 'due'"), 'the migration owns the status buckets');
  assert.ok(migration.includes("require_module_scope_v145(p_business, p_branch, 'clients')"),
    'the RPC is gated on the clients module scope');
});
