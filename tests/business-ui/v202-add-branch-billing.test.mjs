import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V202 (owner): "add a branch here - and user will top up (stripe payment) - and enable the
   access to the branch (settings will allow user to copy the main branch settings)". */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const fn = readFileSync(resolve(root, 'supabase/functions/stripe-billing-command/index.ts'), 'utf8');
const mig = readFileSync(resolve(root, 'db/migrations/20260807_nestly_v202_branch_add_and_billing.sql'), 'utf8');
const lock = readFileSync(resolve(root, 'db/migrations/20260807_nestly_v202b_branch_insert_only_via_paid_rpc.sql'), 'utf8');

/* V209 (owner annotation "move here", arrow pointing at Operations setup): Branches left the
   profile menu for the sidebar, beside Staff Members and Services where the rest of the setup
   lives. The account menu is for the account, not for operations. */
test('the owner reaches branches from Operations setup, not the account menu', () => {
  assert.match(app, /items:\['staffmembers','branches','services','inventory','packages'\]/);
  assert.doesNotMatch(app, /id="pmAddBranch"/);
});

test('creating a branch goes through the paid RPC, never a table insert', () => {
  assert.match(app, /sb\.rpc\('business_add_branch_v202',\{/);
  // the free path is gone from the create branch of the save handler
  assert.doesNotMatch(app, /sb\.from\('branches'\)\.insert\(/);
  // …and RLS makes that structural, not a convention
  assert.match(lock, /drop policy if exists branches_write/);
  assert.doesNotMatch(lock, /for insert/i);
});

test('one attempt key, so a double-tap cannot mint a second branch or a second charge', () => {
  assert.match(app, /if\(!branchAddAttemptKey\)branchAddAttemptKey=crypto\.randomUUID\(\);/);
  assert.match(app, /p_idempotency_key:branchAddAttemptKey/);
  // a failed payment KEEPS the key so retrying resumes the same branch and charge
  assert.match(app, /Your branch is saved and switched off — press Create branch again to retry the payment\./);
  assert.match(mig, /'status','replayed'/);
});

test('a branch is not usable until the payment confirms', () => {
  assert.match(mig, /false,false,'pending_payment'\)/);
  assert.match(mig, /b\.active and b\.billing_state in \('included','active'\)/);
  assert.match(app, /Awaiting payment/);
  assert.match(app, /switched off until payment confirms/);
});

test('the owner is told a charge is coming before it happens', () => {
  assert.match(app, /An extra branch is charged like another shop\./);
  assert.match(app, /shown on the secure payment page before anything is charged/);
});

test('the copy picker offers the branches, and says what copies', () => {
  assert.match(app, /id="brCopyFrom"/);
  assert.match(app, /p_copy_from:copyFrom/);
  assert.match(app, /Copies opening hours, which services it offers, who works there/);
  // products are firm-wide; the RPC says so rather than silently copying nothing
  assert.match(mig, /products are firm-wide and need no copy/);
});

test('the amount is never named in our code — it comes from the catalogue', () => {
  assert.doesNotMatch(app, /\$99|118800/);
  assert.doesNotMatch(mig, /^[^-].*118800/m);
  assert.match(mig, /billing_plan_catalog_v124/);
});

test('billing counts a branch as another unit of the base plan, and fails closed', () => {
  assert.match(fn, /let planUnits = 1;/);
  assert.match(fn, /\.in\('billing_state', \['pending_payment', 'active'\]\)/);
  assert.match(fn, /if \(!branchError && typeof count === 'number'\) planUnits = 1 \+ count;/);
  assert.match(fn, /quantity: planUnits,/);
  assert.match(fn, /'change_branches'/);
});

test('grandfathered branches are never back-charged', () => {
  assert.match(mig, /default 'included'/);
  // the billable filter is an allowlist of the two PAID states, so 'included' can never be
  // counted — checked on the filter itself, since the word also appears in the comment that
  // explains the exclusion
  const filter = fn.match(/\.in\('billing_state', \[([^\]]*)\]\)/);
  assert.ok(filter, 'the branch count must filter on billing_state');
  assert.doesNotMatch(filter[1], /included/);
});
