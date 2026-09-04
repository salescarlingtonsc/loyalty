import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V202 (owner): "add a branch here - and user will top up (stripe payment) - and enable the
   access to the branch (settings will allow user to copy the main branch settings)". */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const fn = readFileSync(resolve(root, 'supabase/functions/razorpay-billing-command/index.ts'), 'utf8');
const mig = readFileSync(resolve(root, 'db/migrations/20260807_nestly_v202_branch_add_and_billing.sql'), 'utf8');
const lock = readFileSync(resolve(root, 'db/migrations/20260807_nestly_v202b_branch_insert_only_via_paid_rpc.sql'), 'utf8');

/* V209 (owner annotation "move here", arrow pointing at Operations setup): Branches left the
   profile menu for the sidebar, beside Staff Members and Services where the rest of the setup
   lives. The account menu is for the account, not for operations. */
test('the owner reaches branches from Operations setup, not the account menu', () => {
  /* V275: the Operations setup group gained a bar-only "Bottle keep" row. This assertion guards
     that the setup surfaces live HERE rather than in the account menu, not that the group is
     frozen, so the new row is admitted explicitly and everything it protects still holds. */
  assert.match(app, /items:\['staffmembers','branches','services','inventory','packages'(?:,'bottlesetup')?(?:,'remindernotify')?\]/);
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
  /* nestly_v666 (owner: "the wordings too chunky - just indicate this new branch is the second
     branch ... = $1,188 / year and total = $xx / year"). The warning is the same warning, said in
     figures instead of paragraphs: which branch this is, what it costs, what the total becomes,
     and that the payment page charges it. Assert those, not the retired sentences. */
  assert.match(app, /This is your \$\{branchOrdinalWordV666\(branchList\.length\+1\)\} branch\./);
  /* nestly_v764 (owner ruling 1): the charge now happens on the card already on file, and the
     owner confirms the pro-rated amount in a dialog BEFORE the branch is created — so the promise
     is stated twice, and neither statement is weaker than the sentence it replaces. */
  assert.match(app, /Charged today on the card you already pay with; the branch switches on when that payment confirms\./);
  assert.match(app, /branchProrataPreviewV764\(payload\.name\)/);
  assert.match(app, /openBranchProrataConfirmV764\(previewV764,payload\.name\)/);
  assert.match(app, /confirm:`Set up today and pay \$\{amount\}`/);
  assert.match(app, /branchAddPriceNoteV666/);
  assert.match(app, /Total for \$\{quote\.branches\}/);
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
  /* V280 retarget (owner: "why when add branch = pay for 2 branch?"). V202 asserted the literal
     `planUnits = 1 + count`. The COUNT is unchanged and still asserted above; what changed is the
     constant 1 — the firm's own base unit now enters the quantity only when Stripe is the thing
     collecting the base plan, because Bistro 999 pays for the firm outside Stripe and was being
     charged for it a second time inside a branch purchase. The V202 guarantee this test exists to
     protect — a branch is billed as another UNIT OF THE BASE PLAN, never as a new price — is
     asserted here directly. */
  assert.match(fn, /planUnits = Math\.max\(1, baseUnits \+ branchUnits\);/);
  assert.match(fn, /const branchUnits = !branchError && typeof count === 'number'/);
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
