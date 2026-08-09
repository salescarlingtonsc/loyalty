import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V248 — owner screenshot: every Customers row showed Points/Credit = "Unavailable" under the
   banner "Points and spendable credit are unavailable because complete Loyalty access could not
   be confirmed."

   V145 returned `loyalty_available` from the directory RPC. V155 rewrote that RPC for branch
   scopes and dropped the key; the client kept reading `data.loyalty_available === true`, and
   `undefined === true` is false — so the honest "we could not confirm" state was reported for
   every business, for every caller, forever, while the payload carried real points all along.

   Server: the migration re-adds the key with the V145 authority. Client: an ABSENT key now falls
   back to the evidence in the rows, so an older server can never blank the column again — while
   an EXPLICIT false is still honoured, because refusing to infer zero is the whole point. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const migration = readFileSync(resolve(repoRoot,
  'db/migrations/20260809_nestly_v248_customer_directory_reports_loyalty_availability.sql'), 'utf8');

test('the migration splices loyalty_available on a comment-free anchor', () => {
  assert.match(migration, /^begin;/m);
  assert.match(migration, /^commit;/m);
  assert.match(migration, /pg_get_functiondef\(p\.oid\) into v_def/);
  assert.match(migration, /proname='staff_list_customers_v155'/);
  assert.match(migration, /execute replace\(v_def, v_old, v_new\);/);

  // the needle and the replacement must carry no `--`: the MCP apply strips full-line comments,
  // so a comment-anchored needle matches a psql-replayed rehearsal and not production.
  const literals = [...migration.matchAll(/v_(?:old|new) := ((?:'(?:[^']|'')*'\s*(?:\|\|)?\s*)+);/g)]
    .map((m) => m[1]);
  assert.equal(literals.length, 2, 'both the needle and the replacement must be parsable literals');
  for (const literal of literals) assert.doesNotMatch(literal, /--/);
});

test('the migration is idempotent and refuses to guess', () => {
  assert.match(migration, /if position\('''loyalty_available''' in v_def\) > 0 then\s*\n\s*return;/);
  assert.match(migration, /raise exception 'v248: the v155 payload anchor was not found/);
  assert.match(migration, /raise exception 'v248: the rewrite did not land/);
});

test('loyalty_available is derived from module authority, never hardcoded true', () => {
  assert.match(migration,
    /''loyalty_available'',app\.metric_module_scope_available_v145\(p_business,null,''loyalty''\)/);
  assert.doesNotMatch(migration, /''loyalty_available'',\s*true/);
});

test('an absent flag falls back to the rows; an explicit false is still honoured', () => {
  const start = app.indexOf('const customerDirectoryLoyaltyAvailableV248=data=>{');
  assert.ok(start > 0, 'the V248 helper must exist');
  const end = app.indexOf('};', start) + 2;
  const available = Function(`${app.slice(start, end)};return customerDirectoryLoyaltyAvailableV248`)();

  // the regression itself: v155's payload has no such key, and the rows carry real points
  assert.equal(available({ customers: [{ id: 'a', points: 45, balance_cents: 0 }] }), true);
  // the honest unavailable state survives — an explicit false must never be inferred away
  assert.equal(available({ loyalty_available: false, customers: [{ points: 45 }] }), false);
  assert.equal(available({ loyalty_available: true, customers: [] }), true);
  // no key AND no evidence stays unavailable rather than guessing
  assert.equal(available({ customers: [] }), false);
  assert.equal(available({ customers: [{ points: null }] }), false);
  assert.equal(available(null), false);
});

test('the directory and the export agree on one availability decision', () => {
  const customers = app.slice(app.indexOf('async function clientsPage()'),
    app.indexOf('async function clientDetail(id)'));
  assert.match(customers, /const pageAvailable=customerDirectoryLoyaltyAvailableV248\(data\);/);
  assert.match(customers, /const loyaltyAvailable=customerDirectoryLoyaltyAvailableV248\(result\);/);
  // the export still refuses to stitch pages that disagree about the authority
  assert.match(customers,
    /else if\(loyaltyAvailable!==pageAvailable\)throw new Error\('Customer balance authority changed during export/);
});
