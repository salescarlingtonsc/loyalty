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
  /* nestly_v786: every new branch is its own subscription; the RPC changed number, the rule did not. */
  assert.match(app, /sb\.rpc\('business_add_branch_v786',\{/);
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

test('the owner is told what the branch costs and where it is paid before it is created', () => {
  /* nestly_v666 kept the ordinal; nestly_v786 (owner ruling: a branch may pay on its own card,
     with its own renewal date) replaced the pro-rata charge on the card on file with the branch's
     OWN checkout: the form names the cycle and its flat price, and says the payment happens on
     Razorpay's page with any card. Nothing is charged by our code. */
  assert.match(app, /This is your \$\{branchOrdinalWordV666\(branchList\.length\+1\)\} branch\./);
  assert.match(app, /name="brCadenceV786" value="annual"/);
  assert.match(app, /name="brCadenceV786" value="monthly"/);
  assert.match(app, /Pay with any card on the next page\. This branch renews on its own date and switches on when the payment confirms\./);
  assert.match(app, /branchAddPriceNoteV786\(\)/);
  assert.match(app, /p_cadence:cadenceV786,p_idempotency_key:branchAddAttemptKey/);
  assert.doesNotMatch(app, /branchProrataPreviewV764/);
  assert.doesNotMatch(app, /openBranchProrataConfirmV764/);
});

test('a branch waiting on its own checkout has a door to pay from the Branches page', () => {
  assert.match(app, /String\(b\.billing_mode\|\|'shared'\)==='own'\?`<a class="btn sm" href="#\/settings">Pay now<\/a>`/);
});

test('the copy picker offers the branches, and says what copies', () => {
  assert.match(app, /id="brCopyFrom"/);
  assert.match(app, /p_copy_from:copyFrom/);
  /* nestly_v782: the picker's helper text no longer claims to copy staff. Owner ruling in
     4178ce99 (nestly_v772): "who works there should not be ported over" — business_copy_branch_
     settings_v202 stopped copying staff_branches, and the text was rewritten to say what it
     actually copies and where staff are assigned instead. nestly_v773 ("rewards are the same at
     every branch") removed loyalty overrides from the same list. The contract this test guards —
     the picker SAYS what copies — is unchanged; only the truthful list of what copies is. */
  assert.match(app, /Copies the opening hours, breaks and services offered from the branch you choose/);
  assert.match(app, /Who works there is assigned per branch on Staff Members/);
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
