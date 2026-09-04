import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const app = (await read('app/index.html')) + '\n' + (await read('app/app.js'));
const migration = await read('db/migrations/20260924_nestly_v749_customer_self_service_account_deletion.sql');
const migrationV750 = await read('db/migrations/20260924_nestly_v750_bottle_does_not_block_deletion.sql');
const migrationV751 = await read('db/migrations/20260924_nestly_v751_deleted_phone_marks_block_rejoin_rewards.sql');

const section = (src, start, end) => {
  const from = src.indexOf(start);
  assert.notEqual(from, -1, `missing section start ${start}`);
  const to = src.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing section end ${end}`);
  return src.slice(from, to);
};

/* -------------------------------------------------- (a) renderCustomerProfile wiring */

test('renderCustomerProfile renders the v749 customer deletion card, not the business mailto card', () => {
  const profile = section(app, 'async function renderCustomerProfile', 'async function confirmCustomerJoinV571');
  assert.match(profile, /\$\{customerAccountDeletionCardHtmlV749\(\)\}/);
  assert.doesNotMatch(profile, /\$\{accountDeletionCardHtml\(\)\}/,
    'the customer profile must not also render the business closure card');
});

/* -------------------------------------------------- (b) the card itself */

test('customerAccountDeletionCardHtmlV749 renders the delete-account affordance and the data-request link', () => {
  const card = section(app, 'function customerAccountDeletionCardHtmlV749', 'let customerDeleteAccountAttemptV749');
  assert.match(card, /id="customerDeleteAccountV749"/);
  assert.match(card, /Ask what data is held/);
});

/* -------------------------------------------------- (c)/(d) the dialog */

const dialog = section(app, 'function openCustomerDeleteAccountDialogV749', 'function accountPrivacyFooterHtmlV593');

test('the dialog calls customer_delete_account_v749 with confirmation DELETE and the per-attempt key', () => {
  assert.match(dialog, /sb\.rpc\(\s*'customer_delete_account_v749'\s*,\s*\{\s*p_confirmation:\s*'DELETE'\s*,\s*p_idempotency_key:\s*customerDeleteAccountAttemptV749\s*\}\s*\)/);
  assert.match(dialog, /if\(!customerDeleteAccountAttemptV749\)customerDeleteAccountAttemptV749=crypto\.randomUUID\(\)/,
    'the key must be generated once per attempt and reused verbatim on retry');
});

test('a refused outcome prints the business name and does not sign the customer out', () => {
  const refusalBranch = section(dialog, "result?.status==='refused'", 'customerDeleteAccountAttemptV749=null');
  assert.match(refusalBranch, /businesses\|\|\[\]\)\.map\(b=>esc\(b\.business_name/);
  assert.doesNotMatch(refusalBranch, /signOut/, 'a refusal must never sign the customer out');
  assert.doesNotMatch(refusalBranch, /killChannels/, 'a refusal must never tear down channels');
});

test('a successful outcome kills channels, signs out, resets client session state, and routes home', () => {
  const successBranch = section(app, 'close();\n    killChannels();', 'function accountPrivacyFooterHtmlV593');
  assert.match(successBranch, /killChannels\(\)/);
  assert.match(successBranch, /sb\.auth\.signOut\(\)/);
  assert.match(successBranch, /resetClientSessionState\(\)/);
  assert.match(successBranch, /location\.hash='#\/'/);
});

/* -------------------------------------------------- (e) the migration itself */

test('the migration is transaction-wrapped and grants/revokes as documented', () => {
  assert.match(migration, /\n\nbegin;\n/, 'the SQL body must be wrapped in begin; after the comment header');
  assert.match(migration.trim(), /commit;$/);
  assert.match(migration, /grant execute on function public\.customer_delete_account_v749\(text, text\) to authenticated, service_role;/);
  assert.match(migration, /revoke all on function public\.customer_delete_account_v749\(text, text\) from public, anon;/);
});

test('the migration refuses a business login with 42501 and calls the v473 unlink helper', () => {
  assert.match(migration, /using errcode = '42501'/);
  assert.match(migration, /app\.unlink_client_links_for_erasure_v473\(/);
  assert.match(migration, /banned_until = 'infinity'::timestamptz/);
  assert.match(migration, /deleted_at = now\(\)/);
});

test('the original v749 migration guarded on both stored-value and kept-property tables (historical)', () => {
  // Verified against the shipped file rather than assumed: sv_lots/sv_accounts (stored value) and
  // bar_bottles (kept property) were the tables the original refusal branch read. v750 (below)
  // supersedes the live function and drops the bar_bottles refusal; this file is unmodified.
  assert.match(migration, /from public\.sv_lots lot join public\.sv_accounts account on account\.id = lot\.account_id/);
  assert.match(migration, /from public\.bar_bottles bottle/);
  assert.match(migration, /bottle\.status in \('stored','called','at_table','expired'\)/);
});

test('nestly_v750 keeps the sv_lots refusal and drops the bar_bottles refusal', () => {
  // The header comment names bar_bottles in prose (explaining why the refusal was dropped), so
  // check the executable SQL body (from `begin;` on) rather than the whole file.
  const body = migrationV750.slice(migrationV750.indexOf('create or replace function public.customer_delete_account_v749'));
  assert.match(body, /sv_lots/);
  assert.doesNotMatch(body, /bar_bottles/);
});

test('the customer profile dialog copy names a stored bottle as kept property, not a blocker', () => {
  assert.match(app, /stored bottle/);
});

test('the migration never touches the value ledgers directly', () => {
  const lower = migration.toLowerCase();
  assert.doesNotMatch(lower, /delete from public\.sales/);
  assert.doesNotMatch(lower, /delete from public\.points_ledger/);
  assert.doesNotMatch(lower, /delete from public\.credit_ledger/);
});

/* -------------------------------------------------- (e2) nestly_v751: deletion marks block rejoin rewards */

test('nestly_v751 creates customer_deletion_marks_v751 with RLS enabled in the same statement', () => {
  assert.match(migrationV751,
    /create table if not exists public\.customer_deletion_marks_v751[\s\S]*?;\s*[\s\S]*?alter table public\.customer_deletion_marks_v751 enable row level security;/);
});

test('nestly_v751 never grants the marks table to anon or authenticated', () => {
  assert.match(migrationV751,
    /revoke all on table public\.customer_deletion_marks_v751 from public, anon, authenticated;/);
});

test('nestly_v751 defines app.phone_recently_deleted_v751 with a 365-day window', () => {
  const body = migrationV751.slice(migrationV751.indexOf('create or replace function app.phone_recently_deleted_v751'));
  assert.match(body, /interval '365 days'/);
});

test('nestly_v751 wires both join-time reward gates through phone_recently_deleted_v751', () => {
  const welcomeBody = migrationV751.slice(
    migrationV751.indexOf('create or replace function app.issue_welcome_offer_v215'),
    migrationV751.indexOf('create or replace function app.referral_referred_is_new_v683'));
  assert.match(welcomeBody, /phone_recently_deleted_v751\(/);

  const referralBody = migrationV751.slice(
    migrationV751.indexOf('create or replace function app.referral_referred_is_new_v683'),
    migrationV751.indexOf('create or replace function public.customer_delete_account_v749'));
  assert.match(referralBody, /phone_recently_deleted_v751\(/);
});

test('nestly_v751 writes the deletion marks before the client row is anonymised', () => {
  const deletionBody = migrationV751.slice(migrationV751.indexOf('create or replace function public.customer_delete_account_v749'));
  const insertIndex = deletionBody.indexOf('insert into public.customer_deletion_marks_v751');
  const updateIndex = deletionBody.indexOf("set full_name = 'Erased customer'");
  assert.notEqual(insertIndex, -1, 'must insert into customer_deletion_marks_v751');
  assert.notEqual(updateIndex, -1, 'must anonymise the client row');
  assert.ok(insertIndex < updateIndex, 'the mark must be taken before the client row is erased');
});

test('nestly_v751 never stores a raw phone in the marks table, only a hash', () => {
  const deletionBody = migrationV751.slice(migrationV751.indexOf('create or replace function public.customer_delete_account_v749'));
  assert.match(deletionBody, /insert into public\.customer_deletion_marks_v751\(business_id, phone_hash(?:, request_id)?\)\s*\n\s*values \([^)]*app\.v89_sha256\(/);
  assert.doesNotMatch(deletionBody,
    /insert into public\.customer_deletion_marks_v751\([^)]*\)\s*\n\s*values \([^)]*,\s*(?:v_client\.phone_norm|v_auth_phone|app\.norm_phone\(v_auth_phone\))\s*[,)]/);
});

test('the OTP-send failure branch tells the customer to wait 10 minutes (nestly_v751)', () => {
  assert.match(app, /wait 10 minutes/);
});

/* -------------------------------------------------- (f) the business route is untouched */

test('the business account-closure button still reads the v131 status RPC', () => {
  const status = section(app, 'async function wireAccountDeletionButton', 'function renderPasswordUpdate');
  assert.match(status, /get_account_deletion_request_v131/);
});
