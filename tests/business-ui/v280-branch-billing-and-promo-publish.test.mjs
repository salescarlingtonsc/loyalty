import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V280 — two reports from the live bar tenant Bistro 999.
   1. "why when add branch = pay for 2 branch? i only added 1 new branch - the older one is
      manual payment"
   2. "promotions loading forever - cannot publish" */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/index.html'), 'utf8') +
  readFileSync(resolve(root, 'app/app.js'), 'utf8');
const fn = readFileSync(resolve(root, 'supabase/functions/razorpay-billing-command/index.ts'), 'utf8');
const mig = readFileSync(
  resolve(root, 'db/migrations/20260811_nestly_v280_branch_billing_units_and_promotion_version.sql'),
  'utf8',
);
const sqlTest = readFileSync(
  resolve(root, 'db/tests/v280_branch_billing_units_and_promotion_version.sql'),
  'utf8',
);

/* The two counting helpers are self-contained, so they are executed rather than merely grepped:
   the owner's complaint is about arithmetic, and a regex cannot check arithmetic. */
const evaluateBranchHelpers = () => {
  const counts = app.match(/function branchBillingCountsV280\(list\)\{[\s\S]*?\n\}/);
  const sentence = app.match(/function branchBillingSentenceV280\(counts\)\{[\s\S]*?\n\}/);
  assert.ok(counts && sentence, 'both branch counting helpers must exist in the application code');
  return new Function(`${counts[0]}\n${sentence[0]}\nreturn {branchBillingCountsV280,branchBillingSentenceV280};`)();
};

/* ---------------------------------------------------------------- 1. branch billing */

test('one added branch is one billable branch, and the screen says all three numbers', () => {
  const { branchBillingCountsV280, branchBillingSentenceV280 } = evaluateBranchHelpers();
  /* Bistro 999 exactly: the firm's own branch (grandfathered 'included') plus the one branch
     they bought. */
  const bistro = branchBillingCountsV280([
    { billing_state: 'included' },
    { billing_state: 'active' },
  ]);
  assert.deepEqual(bistro, { total: 2, included: 1, billable: 1, lapsed: 0, stopping: 0, unsubscribed: 0 });
  assert.equal(branchBillingSentenceV280(bistro), '2 branches · 1 included in your plan · 1 billable');

  /* A firm that has bought nothing pays for no branch at all. */
  assert.equal(
    branchBillingSentenceV280(branchBillingCountsV280([{ billing_state: 'included' }])),
    '1 branch · 1 included in your plan · 0 billable',
  );
  /* A branch that is saved but not paid for is already billable — it is what the checkout is for. */
  assert.equal(
    branchBillingCountsV280([{ billing_state: 'included' }, { billing_state: 'pending_payment' }]).billable,
    1,
  );
  /* A lapsed branch is stated separately rather than silently folded into either number. */
  assert.equal(
    branchBillingSentenceV280(branchBillingCountsV280([
      { billing_state: 'included' }, { billing_state: 'active' }, { billing_state: 'suspended' },
    ])),
    '3 branches · 1 included in your plan · 1 billable · 1 payment lapsed',
  );
});

test('the numbers are stated where branches are listed, bought, and paid for', () => {
  // the list
  assert.match(app, /\$\('brList'\)\.innerHTML=`<p class="muted small"[^`]*branchBillingSentenceV280\(branchCountsV280\)/);
  // the create form, before the owner is sent to Stripe
  /* nestly_v666: the create form now prices the branch instead of explaining the policy. */
  assert.match(app, /This is your \$\{branchOrdinalWordV666\(branchList\.length\+1\)\} branch\./);
  /* nestly_v664: the subscription card no longer quotes one unit and explains the rest in prose —
     the total IS the per-branch amount times the billable branch count, and the sentence beside it
     states the rule and the proration the owner asked for.
     nestly_v758 moved those two sentences into the Change plan drawer and the branch list, and
     dropped the word "tier" from owner-facing copy. The arithmetic and the two promises are
     unchanged, so they are pinned in their new wording rather than weakened. */
  /* nestly_v786: the company plan's arithmetic sentences left the page with the Change plan drawer;
     the main branch card says the plan covers it, and the Manage sheet prices every cycle per branch. */
  assert.match(app, /Includes your core Peekaa plan/);
  assert.match(app, /Billed annually · \$\{moneyShortV758\(annualCents\)\} \/ year per branch/);
  /* nestly_v764 (owner ruling 1 & 2): the same two promises, in the owner's words — "Added
     today" and "Switched off". Neither is weakened: the pro-rata rule and the "keeps working
     until renewal, not charged after" rule are both still stated. */
  assert.match(app, /Keeps working until renewal, not charged after\./);
  assert.match(app, /const total=unit\*units;/);
  // V202's promise is still made, in the shorter v666 wording
  /* nestly_v764: adding a branch is now charged on the card already on file (Razorpay charges the
     pro-rated difference immediately), so there is no payment page to send the owner to. The
     promise that the branch is off until the payment confirms is unchanged. */
  /* nestly_v786: a new branch pays for itself on Razorpay's page; the promise that it is off until
     that payment confirms is unchanged. */
  assert.match(app, /switches on when the payment confirms\./);
});

test('the branch checkout stops charging for the base plan a second time', () => {
  // the constant 1 is gone; the base unit is now a decision
  assert.doesNotMatch(fn, /planUnits = 1 \+ count;/);
  assert.match(fn, /provider_covers_base_unit/);
  assert.match(fn, /requested_branch_id/);
  assert.match(fn, /const isBranchCommand = commandType === 'change_branches' \|\|\s*Boolean\(commandRow\?\.data\?\.requested_branch_id\)/);
  // unknown coverage resolves by intent: a branch command bills branches only
  assert.match(fn, /typeof declaredBaseCoverage === 'boolean' \? declaredBaseCoverage : !isBranchCommand/);
  assert.match(fn, /planUnits = Math\.max\(1, baseUnits \+ branchUnits\);/);
  // an unreadable branch count still never invents units to charge for
  assert.match(fn, /\? count\s*\n\s*: \(isBranchCommand \? 1 : 0\)/);
  // grandfathered branches are still excluded from the paid states
  const filter = fn.match(/\.in\('billing_state', \['pending_payment', 'active'\]\)/);
  assert.ok(filter, 'the paid-state allowlist must survive');
});

test('who collects the base plan is recorded when it is decided, not guessed later', () => {
  assert.match(mig, /add column if not exists provider_covers_base_unit boolean not null default true/);
  // an existing firm is never retro-classified
  assert.match(mig, /default true/);
  // only a checkout minted to pay for a branch clears it
  assert.match(mig, /if v_command_type = 'create_checkout' then\s*\n\s*update public\.subscriptions\s*\n\s*set provider_covers_base_unit = false/);
  // the owner-facing numbers come from one place, with no price in them
  assert.match(mig, /business_branch_billing_units_v280/);
  assert.match(mig, /'plan_units',greatest\(1,\(case when coalesce\(v_covers,true\) then 1 else 0 end\)\+v_billable\)/);
  assert.match(mig, /owner access is required/);
  // no amount is ever named in our own code
  assert.doesNotMatch(mig, /\$99|118800|2376/);
  assert.doesNotMatch(fn, /118800|2376/);
});

/* ------------------------------------------------------- 2. promotions: publish, and never stick */

test('the busy state is released on every failure path, including an unexpected throw', () => {
  // the handler body is wrapped; nothing can leave Publish disabled with no error
  /* V373 put the single-flight guard and the trigger-disable ahead of the try, so the two are no
     longer adjacent. The property this test holds — the busy state is released on EVERY exit — is
     now guaranteed harder than before, by a finally rather than by the catch alone. */
  assert.match(app, /const save=async\(publish,options=\{\}\)=>\{[\s\S]{0,320}?try\{return await runSave\(publish,options\)\}/);
  assert.match(app, /finally\{[\s\S]{0,400}?promotionSaveInFlightV373=false;/,
    'the in-flight flag and the controls must be released however the save ended');
  assert.match(app, /catch\(error\)\{[\s\S]{0,400}?\.forEach\(button=>\{button\.disabled=false\}\)/);
  assert.match(app, /This did not finish: \$\{ownerErrorText\(error\)\} Nothing was lost — press again\./);
  // every storage call is bounded, because storage-js rethrows anything that is not a StorageError
  assert.match(app, /const withDeadlineV280=\(work,ms,timeoutMessage\)=>/);
  assert.match(app, /uploaded=await withDeadlineV280\(\s*\n\s*sb\.storage\.from\('business-public'\)\.upload\(/);
  assert.match(app, /return withDeadlineV280\(NestlyMediaSyncV95\.removeOrQueue\(\{/);
  assert.match(app, /await withDeadlineV280\(NestlyMediaSyncV95\.removeOrQueue\(\{/);
  // the deadline resolves rather than rejects, so a throw becomes an ordinary handled error
  assert.match(app, /Promise\.resolve\(work\)\.then\(finish,error=>finish\(\{data:null,error\}\)\)/);
});

test('an oversized photo is refused in plain words before anything is uploaded', () => {
  assert.match(app, /const PROMOTION_MEDIA_MAX_BYTES_V280=10485760;/);
  assert.match(app, /That photo is \$\{\(Number\(file\.size\|\|0\)\/1048576\)\.toFixed\(1\)\} MB\. The limit is 10 MB/);
  assert.match(app, /const photoRefusalV280=promotionPhotoRefusalV280\(file\);/);
  // the refusal is also written where the owner is looking, not only into a toast
  assert.match(app, /refusedStatus\.textContent=photoRefusalV280/);
});

test('a large photo is downscaled client-side instead of being uploaded whole', () => {
  assert.match(app, /const PROMOTION_MEDIA_MAX_EDGE_V280=1600;/);
  assert.match(app, /if\(!file\|\|file\.type==='image\/gif'\)return file;/); // animation is never destroyed
  assert.match(app, /if\(Number\(file\.size\|\|0\)<=PROMOTION_MEDIA_DOWNSCALE_ABOVE_BYTES_V280\)return file;/);
  assert.match(app, /context\.fillStyle='#ffffff';context\.fillRect\(0,0,width,height\);/); // no black transparency
  assert.match(app, /if\(!blob\|\|blob\.size>=Number\(file\.size\|\|0\)\)return file;/); // never larger than the original
  // the path suffix, the declared mime type and the bytes sent must agree, or the RPC refuses it
  assert.match(app, /const sending=await downscalePromotionPhotoV280\(file\);/);
  assert.match(app, /objectPath=`\$\{businessId\}\/offer\/\$\{crypto\.randomUUID\(\)\}\.\$\{extension\}`/);
  assert.match(app, /mimeType:sending\.type,width:dimensions\.width,height:dimensions\.height,alt/);
});

test('the photo status line stops lying about what is happening', () => {
  assert.match(app, /field\('promotionImageStatus'\)\.textContent='Photo uploaded\. Saving the promotion…';/);
  assert.match(app, /imageStatus\.textContent='The photo did not finish\. Your draft is safe; choose it again and retry\.'/);
});

test('a photo that will not upload cannot take the draft down with it', () => {
  assert.match(app, /This draft was saved without it\./);
  // publishing genuinely needs a photo, so that still stops
  assert.match(app, /if\(publish\)\{\s*\n\s*buttons\.forEach\(button=>button\.disabled=false\);\s*\n\s*status\.textContent='Your draft is safe\. The photo needs another try\.'/);
});

test('a stale version is re-read and retried instead of bricking the promotion', () => {
  assert.match(app, /function promotionVersionConflictV280\(error\)\{/);
  assert.match(app, /code==='40001'\|\|\/promotion_version_conflict/);
  /* The uploaded photo the retry needs is NOT deleted on a conflict. V462 added a THIRD retryable
     refusal to the same condition — the live-offer cap, which the owner clears in a dialog before
     the identical save is sent again — so the pin names all three rather than freezing the pair. */
  assert.match(app, /if\(!promotionRpcErrorIsAmbiguousV104\(result\.error\)\s*\n\s*&&!promotionVersionConflictV280\(result\.error\)\s*\n\s*&&!promotionPublishLimitRefusalV462\(result\.error\)\)\{/);
  // re-read, then retry exactly once, with a NEW attempt key because the arguments changed
  assert.match(app, /const refreshPromotionV280=async promotionId=>/);
  assert.match(app, /pendingFinalize=buildPendingFinalizeV280\(refreshed,crypto\.randomUUID\(\)\);/);
  // a second conflict releases the held receipt rather than replaying it forever
  assert.match(app, /pendingFinalize=null;writeSessionValue\(pendingStorageKey,null\);\s*\n\s*await cleanFailedUpload\(abandoned\);/);
  assert.match(app, /This promotion was changed somewhere else while you were editing\./);
  /* The resume branch runs first on every press and after every reload. A held receipt whose
     versions are stale can never succeed, so it is released there too — otherwise the editor
     replays an impossible request for as long as the owner keeps pressing. */
  assert.match(app, /if\(resumed\.error&&promotionVersionConflictV280\(resumed\.error\)\)\{/);
  assert.match(app, /This promotion changed since that save was interrupted\./);
});

test('the wrapper reports the version it actually left behind', () => {
  assert.match(mig, /create or replace function app\.promotion_version_sync_v280/);
  // the returned payload and the embedded item
  assert.match(mig, /v_payload := v_payload \|\| jsonb_build_object\('content_version',v_version\);/);
  assert.match(mig, /jsonb_set\(v_payload,'\{item,content_version\}',to_jsonb\(v_version\),true\)/);
  // and the receipt, which is what a replay reads
  assert.match(mig, /update public\.business_promotion_attempt_receipts_v104 receipt/);
  // both wrappers, because both of them bump the row after building their answer
  assert.match(mig, /create or replace function public\.business_create_promotion_draft_v155/);
  assert.match(mig, /create or replace function public\.business_finalize_promotion_v155/);
  assert.equal(
    (mig.match(/app\.promotion_version_sync_v280\(p_business,p_promotion_id,p_attempt_key,v_result\)/g) || []).length,
    2,
  );
  // the private helper stays private
  assert.match(mig, /revoke all on function app\.promotion_version_sync_v280\(uuid,uuid,uuid,jsonb\) from public, anon, authenticated;/);
});

test('the rolled-back SQL suite proves both fixes and leaves nothing behind', () => {
  assert.match(sqlTest, /^begin;/m);
  assert.match(sqlTest, /^rollback;/m);
  assert.match(sqlTest, /a branch-only checkout must say it does not carry the base unit/);
  assert.match(sqlTest, /a branch-only subscription bills one unit per billable branch and nothing else/);
  assert.match(sqlTest, /a firm billed through Stripe still pays for its own base unit/);
  assert.match(sqlTest, /the draft must report the version the row actually holds after the scope write/);
  assert.match(sqlTest, /the finalize must succeed and stay a draft/);
});
