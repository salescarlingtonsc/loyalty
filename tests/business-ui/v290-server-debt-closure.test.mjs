/* V290 — server-side debt closure. Six deferred server gaps, one test group each. The migration
   is spliced against DEPLOYED definitions, so most of what is pinned here is the exact needle and
   patch text: if a needle drifts the migration fails loudly at apply time, and if a needle is
   silently loosened this file fails first. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260812_nestly_v290_server_debt_closure.sql'), 'utf8');
const suite = readFileSync(join(root, 'db', 'tests', 'v290_server_debt_closure.sql'), 'utf8');
const v288Suite = readFileSync(join(root, 'db', 'tests', 'v288_a2_gap_closure.sql'), 'utf8');
const registry = JSON.parse(
  readFileSync(join(root, 'docs', 'design', 'ps0', 'writer-registry.json'), 'utf8'));
const occurrences = (haystack, needle) => haystack.split(needle).length - 1;

/* ------------------------------------------------------- 1. staff_services */

test('1 — staff_services is split per command: members read, only the owner writes', () => {
  /* The single FOR ALL policy is what made DELETE member-writable: a WITH CHECK clause is never
     evaluated for a DELETE, so the owner half simply did not apply to it. */
  assert.match(migration, /drop policy if exists staff_services_all on public\.staff_services;/);
  for (const [name, command] of [
    ['staff_services_select', 'select'],
    ['staff_services_insert', 'insert'],
    ['staff_services_update', 'update'],
    ['staff_services_delete', 'delete'],
  ]) {
    assert.match(migration,
      new RegExp(`create policy ${name} on public\\.staff_services\\s+for ${command} to authenticated`),
      `${name} must exist as a per-command policy`);
  }
  /* Read is for members; each of the three write commands must test OWNERSHIP, and the DELETE
     must test it in its USING clause because that is the only clause DELETE evaluates. */
  assert.match(migration,
    /create policy staff_services_select on public\.staff_services\s+for select to authenticated\s+using \(app\.is_salon_member\(business_id\)\);/);
  assert.match(migration,
    /create policy staff_services_delete on public\.staff_services\s+for delete to authenticated\s+using \(app\.is_salon_owner\(business_id\)\);/);
  assert.match(migration,
    /create policy staff_services_insert on public\.staff_services\s+for insert to authenticated\s+with check \(app\.is_salon_owner\(business_id\)\);/);
  assert.match(migration,
    /create policy staff_services_update on public\.staff_services\s+for update to authenticated\s+using \(app\.is_salon_owner\(business_id\)\)\s+with check \(app\.is_salon_owner\(business_id\)\);/);
  assert.match(migration, /revoke all on public\.staff_services from anon;/);
  /* No new policy may re-open the member write the split exists to close. */
  assert.doesNotMatch(migration,
    /create policy staff_services_(insert|update|delete)[\s\S]{0,160}is_salon_member/);
  /* The suite proves it behaviourally, not only by catalog shape. */
  assert.match(suite, /a non-owner member still deleted % staff_services row\(s\)/);
});

/* ------------------------------------------------- 2. the residual booking gate */

test('2 — the smart-booking wrapper gate is conditional, with bookings in its place', () => {
  const needle = `$needle$  perform app.require_branch_module_v94(
    p_business,p_branch,'appointments','rw'
  );$needle$`;
  assert.equal(occurrences(migration, needle), 1,
    'the wrapper needle must appear exactly once, byte-identical to the deployed body');
  assert.match(migration,
    /if app\.business_has_appointments_module_v288\(p_business,p_branch\) then\s+perform app\.require_branch_module_v94\(\s+p_business,p_branch,'appointments','rw'/);
  /* Where the sector has no appointments the call is still authorised — by the module the
     request actually lives in. It must never simply fall through unguarded. */
  assert.match(migration,
    /else\s+perform app\.require_branch_module_v94\(\s+p_business,p_branch,'bookings','rw'/);
  assert.match(migration, /expected exactly 1 appointments gate in the v47 wrapper, found %/);
});

test('2 — the smart-booking BASE carries the same condition and keeps its branch check', () => {
  const needle = `$needle$  if auth.uid() is null
     or not app.can_module_write(p_business, 'appointments')
     or not app.can_see_branch(p_business, p_branch) then$needle$`;
  assert.equal(occurrences(migration, needle), 1,
    'the base needle must appear exactly once, byte-identical to the deployed body');
  assert.match(migration,
    /when app\.business_has_appointments_module_v288\(p_business, p_branch\)\s+then not app\.can_module_write\(p_business, 'appointments'\)\s+else not app\.can_module_write\(p_business, 'bookings'\)/);
  assert.match(migration, /expected exactly 1 appointments gate in the v47 base, found %/);
  /* auth.uid() and can_see_branch must survive the splice — the patch re-states both. */
  assert.match(migration, /\$needle\$  if auth\.uid\(\) is null\n     or \(case/);
  assert.match(migration, /the sector condition did not land in the v47 base, or a gate was lost/);
});

test('2 — the V288 suite\'s KNOWN OPEN section is now a positive assertion naming V290', () => {
  assert.doesNotMatch(v288Suite, /KNOWN OPEN: V288 does not actually unblock/);
  assert.match(v288Suite, /CLOSED BY V290/);
  assert.match(v288Suite, /20260812_nestly_v290_server_debt_closure/);
  /* It must now FAIL if confirm is refused, which is the opposite of what it used to assert. */
  assert.match(v288Suite, /V290 should have closed this gap; confirm still raised % \(%\)/);
  assert.doesNotMatch(v288Suite, /the known-open residual gate changed shape/);
});

/* --------------------------------------------- 3. the correction linkage */

test('3 — staff_get_reversal_workflows joins the v84 correction record', () => {
  assert.match(migration,
    /from public\.sale_amount_corrections_v84 corr\s+where corr\.business_id = s\.business_id/);
  /* One correction row is reachable from any of its three sales rows. */
  assert.match(migration,
    /and \(corr\.original_sale_id = s\.id\s+or corr\.replacement_sale_id = s\.id\s+or corr\.reversal_sale_id = s\.id\)/);
  assert.equal(occurrences(migration, `$needle$        ) pkg on true
       where s.business_id = p_business$needle$`), 1,
    'the lateral-join anchor must be an exactly-once needle');
});

test('3 — the client contract names are emitted and unchanged', () => {
  /* The browser already keyed on these three; the server simply never sent them. Renaming any of
     them would silently un-reach the Corrected state a second time. */
  assert.match(migration, /'correction_sale_id', case when corr\.corr_original_sale_id = s\.id/);
  assert.match(migration, /'corrected_sale_id', case when corr\.corr_replacement_sale_id = s\.id/);
  assert.match(migration, /'correction_role', case/);
  assert.match(app,
    /if\(w\.correction_sale_id\|\|w\.corrected_sale_id\|\|s\.corrected_by\)/,
    'the client must keep keying on the same three names');
  /* The splice must not disturb the keys the reader already emitted. */
  assert.equal(occurrences(migration, `$needle$               'is_reversal', s.reversal_of is not null,
               'original_sale_id', s.reversal_of,$needle$`), 1,
    'the json anchor must be an exactly-once needle');
  assert.match(migration, /the correction linkage did not land, or an existing key was lost/);
});

test('3 — a corrected original is reported as Corrected before it is reported as Reversed', () => {
  /* A v84 correction ALWAYS writes a reversal row, so w.reversal_sale_id is set on the original.
     If the Reversed branch stayed first, the linkage would be delivered and still never shown. */
  const status = app.slice(app.indexOf('function saleRecordStatusV154('));
  const correctedAt = status.indexOf('w.correction_sale_id||w.corrected_sale_id');
  const reversedAt = status.indexOf('if(w.reversal_sale_id)return');
  assert.notEqual(correctedAt, -1);
  assert.notEqual(reversedAt, -1);
  assert.ok(correctedAt < reversedAt,
    'the correction branch must be evaluated before the reversal branch');
});

/* ----------------------------------------- 4. server-side bucket counts */

test('4 — staff_customer_bucket_counts_v290 copies the v155 auth and scope shape', () => {
  assert.match(migration,
    /create or replace function public\.staff_customer_bucket_counts_v290\(/);
  assert.match(migration,
    /if auth\.uid\(\) is null or not app\.can_module_read\(p_business,'clients'\) then\s+raise exception 'customer read access required' using errcode='42501';/);
  assert.match(migration, /from app\.resolve_reporting_branch_scope_v155\(/);
  assert.match(migration, /app\.reporting_scope_label_v155\(/);
  /* Every bucket the directory can filter by must also be countable, or a card and its list part
     company again. */
  for (const bucket of ['30_59', '60_89', '90_plus', 'all_inactive', 'never', 'total']) {
    assert.ok(migration.includes(`'${bucket}',count(*)`),
      `the counts payload must carry ${bucket}`);
  }
  assert.match(migration,
    /revoke all on function public\.staff_customer_bucket_counts_v290\(uuid, text, text, uuid\[\], uuid\)\s+from public, anon;/);
  assert.match(migration,
    /grant execute on function public\.staff_customer_bucket_counts_v290\(uuid, text, text, uuid\[\], uuid\)\s+to authenticated;/);
});

test('4 — staff_list_customers_v155 gains all_inactive without losing a bucket', () => {
  assert.equal(occurrences(migration,
    `$needle$     and p_inactive_bucket not in ('30_59','60_89','90_plus','never') then$needle$`), 1);
  assert.match(migration,
    /not in \('30_59','60_89','90_plus','never','all_inactive'\) then\$needle\$/);
  assert.match(migration,
    /or \(p_inactive_bucket = 'all_inactive' and visit\.last_visit_at is not null[\s\S]{0,200}>= 30\)/);
  assert.match(migration, /the all_inactive bucket did not land, or an existing bucket was lost/);
});

test('4 — the Customers page counts buckets in ONE call, not by paging the directory', () => {
  const refresh = app.slice(app.indexOf('async function refreshInactiveCards(){'),
    app.indexOf('const customerDirectoryLoyaltyAvailableV248='));
  assert.match(refresh, /sb\.rpc\('staff_customer_bucket_counts_v290'/);
  assert.match(refresh, /currentReportingScopePayloadV155\(branches\)/);
  /* The whole directory may still be fetched for the audience actions, but ONLY once a bucket is
     actually selected — that is the difference between one call and 2*ceil(N/100) per open. */
  assert.match(refresh, /if\(!clientInactiveBucket\)\{renderSelectedAudienceActionsV154\(\[\],false\);return\}/);
  const beforeGuard = refresh.slice(0, refresh.indexOf('if(!clientInactiveBucket)'));
  assert.doesNotMatch(beforeGuard, /allCustomerDirectoryRows\(\)/,
    'the unconditional full-directory page must be gone from the counts path');
});

test('4 — the dashboard tile counts all inactive customers and lands on exactly them', () => {
  assert.match(app, /p_inactive_bucket:'all_inactive',p_limit:1,p_offset:0/);
  assert.match(app, /if\(key==='inactive'\)pendingCustomerInactivity='all_inactive';/);
  assert.match(app, /hint:'Last visit 30\+ days ago'/);
  /* The handoff must accept a named bucket, not only a number of days. */
  /* V290 merge note: folded into the V288 named-bucket resolver — 'all_inactive' is accepted
     there rather than via a typeof chain. */
  assert.match(app, /'all_inactive'\]\.includes\(raw\)|'never','all_inactive'/);
  /* The destination must exist in the filter, the classifier and the client-side matcher. */
  assert.match(app, /<option value="all_inactive">Inactive 30\+ days<\/option>/);
  assert.match(app, /if\(bucket==='all_inactive'\)return !never&&days>=30;/);
  assert.match(app, /'all_inactive':\{label:'Inactive 30\+ days'/);
});

/* ----------------------------------------------------- 5. PDPA erasure */

test('5 — erase_client_v290 is owner-only, anonymises in place and never hard-deletes', () => {
  assert.match(migration, /create or replace function public\.erase_client_v290\(/);
  assert.match(migration,
    /or not app\.is_salon_owner\(p_business\) then\s+raise exception 'customer erasure requires the workspace owner' using errcode = '42501';/);
  /* Anonymise, never delete: the append-only ledgers reference this row. */
  assert.match(migration, /set full_name = 'Erased customer',/);
  for (const field of ['phone = null', 'email = null', 'birth_date = null',
    'gender = null', 'notes = null', 'referral_code = null', 'marketing_consent = false']) {
    assert.ok(migration.includes(field), `erasure must clear ${field}`);
  }
  assert.match(migration, /tags = array\[\]::text\[\]/);
  assert.doesNotMatch(migration, /delete from public\.clients/,
    'erasure must never hard-delete a customer row');
  /* phone_norm is GENERATED, so it clears with phone rather than being written directly. */
  assert.match(migration, /phone_norm is a GENERATED column and clears itself with phone/);
});

test('5 — erasure refuses while the business still holds something of the customer\'s', () => {
  assert.match(migration, /from public\.credit_ledger ledger/);
  assert.match(migration, /from public\.bar_bottles bottle/);
  assert.match(migration, /from public\.sv_lots lot\s+join public\.sv_accounts account/);
  assert.match(migration,
    /if v_credit > 0 or v_bottles > 0 or v_sv > 0 then\s+return jsonb_build_object\('status','refused','reason','holdings_outstanding'/);
  /* Stored value fails CLOSED rather than guessing a balance from PS-2's sign convention. */
  assert.match(migration, /It fails closed\./);
});

test('5 — erasure is idempotent, audited, and claims no legal compliance', () => {
  assert.match(migration, /create table if not exists public\.client_erasures_v290/);
  assert.match(migration, /alter table public\.client_erasures_v290 enable row level security;/);
  assert.match(migration, /revoke all on public\.client_erasures_v290 from anon, authenticated;/);
  assert.match(migration, /client_erasures_v290_idem_uk/);
  assert.match(migration, /return jsonb_build_object\('status','duplicate_ignored'/);
  assert.match(migration, /'CLIENT_ERASED_V290', 'clients', p_client,/);
  assert.match(migration, /if not app\.is_super_admin\(\) then\s+raise exception 'platform administrator required'/);
  /* ⚖️ flagged for counsel, and never asserted as compliance. */
  assert.ok(migration.includes('⚖️ PDPA ERASURE, SERVER HALF'));
  assert.match(migration, /an engineering control, not a legal opinion/);
  assert.doesNotMatch(migration, /PDPA[- ]compliant|complies with the PDPA/i);
});

/* ------------------------------------------ 6. promotion redemption intents */

test('6 — the intent tables are append-only evidence with deny-all RLS', () => {
  for (const table of ['promotion_redemption_intents_v290', 'promotion_redemptions_v290']) {
    assert.match(migration, new RegExp(`create table if not exists public\\.${table}`));
    assert.match(migration,
      new RegExp(`alter table public\\.${table} enable row level security;`));
    assert.match(migration,
      new RegExp(`revoke all on public\\.${table} from anon, authenticated;`));
    assert.ok(!new RegExp(`create policy [a-z_]+ on public\\.${table}`).test(migration),
      `${table} must carry no policy at all`);
  }
  /* One live intent per promotion per customer, enforced by the database rather than by the UI. */
  assert.match(migration,
    /create unique index if not exists promotion_redemption_intents_v290_open_uk[\s\S]{0,160}where status = 'pending';/);
  assert.match(migration, /create unique index if not exists promotion_redemptions_v290_intent_uk/);
});

test('6 — the customer intent reuses the v89 token shape and refuses an unlinked caller', () => {
  assert.match(migration,
    /create or replace function public\.customer_create_promotion_intent_v290\(/);
  assert.match(migration, /v_identity := app\.v31_current_identity\(\);/);
  assert.match(migration,
    /raise exception 'verified customer link required' using errcode = '42501';/);
  assert.match(migration, /app\.v89_redemption_token\(v_identity,p_business,'promotion_v290',/);
  assert.match(migration, /app\.v89_sha256\(v_token\)/);
  /* Only a live, business-wide, in-window offer may be presented. */
  assert.match(migration,
    /and content\.content_type = 'offer'\s+and content\.active\s+and content\.branch_id is null/);
  /* usage_limit rides in the promotion's own metadata; a non-numeric value is ignored. */
  assert.match(migration, /v_promotion\.metadata->>'usage_limit'/);
  assert.match(migration, /raise exception 'offer usage limit reached' using errcode = '23514';/);
});

test('6 — the staff redemption records once and answers a second attempt with when', () => {
  assert.match(migration,
    /create or replace function public\.staff_redeem_promotion_intent_v290\(/);
  assert.match(migration,
    /perform pg_advisory_xact_lock\(\s+hashtextextended\(p_business::text\|\|':promotion-redeem-v290:'\|\|v_key,0\)\);/);
  assert.match(migration, /return jsonb_build_object\('status','duplicate_ignored','redemption_id'/);
  assert.match(migration,
    /if v_intent\.status = 'redeemed' then\s+return jsonb_build_object\('status','already_redeemed','intent_id',v_intent\.id,\s+'promotion_id',v_intent\.promotion_id,'redeemed_at',v_intent\.redeemed_at\);/);
  assert.match(migration, /return jsonb_build_object\('status','expired','intent_id'/);
  assert.match(migration, /'PROMOTION_REDEEMED_V290',/);
  /* It records an acceptance; it must not compute money. */
  assert.doesNotMatch(migration,
    /insert into public\.(sales|credit_ledger|points_ledger)[\s\S]{0,80}promotion_redeem/i);
});

test('6 — the customer button creates an intent and renders a QR the till already parses', () => {
  assert.match(app, /sb\.rpc\('customer_create_promotion_intent_v290',\{/);
  assert.match(app, /showPendingPromotionQrV290\(\{intent,businessName:b\.name,promotionName:offerName\}\)/);
  assert.match(app, /function showPendingPromotionQrV290\(/);
  assert.match(app, /text:`nestly:promotion:\$\{token\}`/);
  /* The scanner must recognise that exact prefix, or the QR is unreadable at the counter. */
  assert.match(app, /\/\^nestly:promotion:\(\[A-Za-z0-9_-\]\{20,512\}\)\$\/i/);
  assert.match(app, /if\(promotionPrefixed\)return \{kind:'promotion',token:promotionPrefixed\[1\]\};/);
});

test('6 — the till extends the scanner it already has rather than growing a second one', () => {
  /* An owner should not have to know which of three codes a customer holds before choosing a
     control, so the existing "Scan customer QR" affordance accepts all three. */
  assert.match(app, /payload\.kind==='promotion'\s*\?await sb\.rpc\('staff_redeem_promotion_intent_v290'/);
  assert.match(app, /if\(payload\.kind==='promotion'&&data\?\.status==='already_redeemed'\)/);
  assert.match(app, /\?data\?\.status==='redeemed'\|\|data\?\.status==='duplicate_ignored'/);
  assert.match(app, /redemption_kind:'promotion_offer'/);
  assert.match(app, /kind==='promotion_offer'\?'Offer':'Reward'/);
  /* The receipt must not invent a points line for something that spends no points. */
  assert.match(app,
    /receipt\.kind==='growth_offer'\|\|receipt\.kind==='promotion_offer'\?'':`<div><dt>Points spent<\/dt>/);
});

/* ------------------------------------------------------ housekeeping */

test('the migration is one atomic transaction and its suite rolls back', () => {
  assert.equal(occurrences(migration, '\nbegin;\n'), 1);
  assert.equal(occurrences(migration, '\ncommit;\n'), 1);
  assert.equal(occurrences(suite, '\nbegin;\n'), 1);
  assert.equal(occurrences(suite, '\nrollback;\n'), 1);
  assert.match(suite, /raise notice|raise exception 'V290_RESULT ALL PASS/);
  assert.match(migration, /raise notice 'v290:/);
});

test('every new browser RPC is curated in the PS-0 writer registry', () => {
  const ids = new Set([...registry.writers.map((w) => w.id),
    ...registry.allowlist.map((a) => a.id)]);
  for (const rpc of ['staff_customer_bucket_counts_v290',
    'customer_create_promotion_intent_v290', 'staff_redeem_promotion_intent_v290']) {
    assert.ok(ids.has(`browser.rpc:app/app.js:${rpc}`), `${rpc} must be curated or allowlisted`);
  }
  /* The read-only one is allowlisted; the two writers are curated with a migratability note. */
  assert.ok(registry.allowlist.some((a) =>
    a.id === 'browser.rpc:app/app.js:staff_customer_bucket_counts_v290'));
  for (const rpc of ['customer_create_promotion_intent_v290', 'staff_redeem_promotion_intent_v290']) {
    const entry = registry.writers.find((w) => w.id === `browser.rpc:app/app.js:${rpc}`);
    assert.ok(entry, `${rpc} must be a curated writer`);
    assert.match(entry.kernel_migratability, /^non-value/);
  }
});
