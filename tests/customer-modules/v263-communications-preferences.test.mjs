import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* v263 (owner, 2026-08-09): "they can switch off or on, default is all on", with Grab's
   Communications screen supplied as the reference shape, and "once check the box would approve all
   sorts of marketing including push notifications and calling or whatsapp or sms or email".

   The four things this file protects, because each of them is a way the feature could look built
   and be theatre:
   - the screen renders EFFECTIVE values from one server call and never recomputes the default;
   - a failed write reverts the switch and says so, so the UI cannot claim an unsaved preference;
   - the gate is in the send path (fan-out and push lease), server-side, in SQL;
   - nothing here can suppress a transactional message. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const customerChunk = readFileSync(resolve(repoRoot, 'app/app-customer.js'), 'utf8');
const migration = readFileSync(
  resolve(repoRoot, 'db/migrations/20260809_nestly_v263_customer_communication_preferences.sql'),
  'utf8'
);

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

const screen = section(
  'const CUSTOMER_COMMUNICATION_CATEGORIES_V263',
  '\nfunction renderPersonaResolutionUnavailable'
);

test('Communications is a real customer route inside the customer surface', () => {
  assert.match(appJs, /if\(h==='#\/customer\/communications'\)return renderCustomerCommunicationsV263\(\);/);
  assert.ok(
    customerChunk.includes('async function renderCustomerCommunicationsV263'),
    'the screen must ship in the customer chunk, not the workspace one'
  );
  assert.match(appJs, /href="#\/customer\/communications"/, 'the account area must link to it');
});

test('the screen renders the server matrix and never recomputes the default', () => {
  assert.match(screen, /sb\.rpc\('customer_get_communication_preferences_v263'\)/);
  assert.match(screen, /channel\.enabled===true\?'checked':''/,
    'a switch must reflect the effective value the server sent');
  assert.doesNotMatch(screen, /\?\?\s*true|\|\|\s*true/,
    'the client must not re-implement the default-on rule');
});

test('the three categories and five outbound channels the owner asked for are present', () => {
  for (const category of ['business_offers', 'rewards_and_points', 'peekaa_updates']) {
    assert.ok(screen.includes(`'${category}'`), `missing category ${category}`);
  }
  for (const channel of ['push', 'email', 'sms', 'whatsapp', 'call']) {
    assert.ok(screen.includes(`['${channel}',`), `missing channel ${channel}`);
  }
  assert.ok(screen.includes("['in_app','In-app message']"),
    'in_app is the sixth channel: it is the existing gate the promotion fan-out already reads');
});

test('loading, error, empty and saved states all exist', () => {
  assert.match(screen, /CUI\.loadingState\(/);
  assert.match(screen, /CUI\.errorState\(/);
  assert.match(screen, /CUI\.emptyState\(/);
  assert.match(screen, /say\(ct\('Saved\.'\)\)/);
  assert.match(screen, /customerCommsRetry/, 'the error state must be retryable');
});

test('a failed write reverts the switch instead of lying about it', () => {
  assert.match(screen, /if\(setError\)\{input\.checked=!wanted;syncMaster\(\);say\(/);
  assert.match(screen, /before\.forEach\(\(\[input,was\]\)=>\{input\.checked=was\}\)/,
    'a failed master tick must restore every individual switch it optimistically moved');
});

test('the master tick is one call in both directions', () => {
  assert.match(screen, /sb\.rpc\('customer_set_all_communications_v263',\{p_enabled:wanted\}\)/);
  assert.match(screen, /sb\.rpc\('customer_set_communication_preference_v263',\{/);
});

test('the wrong customer-facing copy is gone', () => {
  assert.doesNotMatch(appJs, /Businesses cannot send promotional push notifications/,
    'the old sentence contradicted the ruling that promotional push is intended');
  assert.doesNotMatch(customerChunk, /Businesses cannot send promotional push notifications/);
});

test('default-on is stored as deviations only, so nothing needs a backfill', () => {
  assert.match(migration, /select p_category is null or not exists/,
    'the gate must be "no explicit false row", which makes absence mean on');
  assert.doesNotMatch(migration, /insert into public\.customer_communication_preferences_v263[\s\S]{0,400}from public\.customer_identities/,
    'no backfill may populate the matrix');
  assert.match(migration, /delete from public\.customer_communication_preferences_v263 preference\s*\n\s*where preference\.identity_id = v_identity;/,
    'granting everything must clear deviations rather than write true rows');
});

test('the gate is enforced in both send paths, server-side', () => {
  const fanout = migration.slice(migration.indexOf('create or replace function app.enqueue_promotion_alert_v122'));
  assert.match(fanout, /left join public\.customer_notification_preferences preference/,
    'the v33 preference must stop being a required row');
  assert.match(fanout, /coalesce\(preference\.opted_in,true\)/,
    'absence is consent, but an explicit v33 withdrawal still wins');
  assert.match(fanout, /app\.customer_communication_allows_v263\(\s*\n?\s*link\.identity_id,'business_offers','in_app'\s*\n?\s*\)/);

  const push = migration.slice(migration.indexOf('create or replace function public.internal_customer_push_claim_v95'));
  assert.equal(
    (push.match(/app\.customer_communication_topic_allows_v263\(/g) || []).length,
    2,
    'both the delivery enqueue and the lease candidates must consult the gate'
  );
  assert.equal(
    (push.match(/coalesce\(preference\.opted_in,true\)/g) || []).length,
    2
  );
});

test('promotional push becomes possible at all, which is what the switch then governs', () => {
  assert.match(migration, /\('v122_promotion_new','promotion_alerts'\),\s*\n\s*\('v122_promotion_expiry','promotion_alerts'\)/);
});

test('transactional messages cannot be suppressed from here', () => {
  assert.match(
    migration,
    /check \(category in \('business_offers', 'rewards_and_points', 'peekaa_updates'\)\)/,
    'the category domain admits only marketing categories, so no transactional row can be stored'
  );
  const mapper = migration.slice(
    migration.indexOf('create or replace function app.communication_category_for_topic_v263'),
    migration.indexOf('create table public.customer_communication_preferences_v263')
  );
  assert.doesNotMatch(mapper, /booking_updates/,
    'booking_updates must fall through to the NULL category');
  assert.match(mapper, /else null/);
  const clientCategories = screen.slice(
    screen.indexOf('const CUSTOMER_COMMUNICATION_CATEGORIES_V263'),
    screen.indexOf('const CUSTOMER_COMMUNICATION_CHANNELS_V263')
  );
  assert.deepEqual(
    [...clientCategories.matchAll(/\n\s*\['([a-z_]+)'/g)].map((match) => match[1]),
    ['business_offers', 'rewards_and_points', 'peekaa_updates'],
    'the screen may only offer the three marketing categories as switches'
  );
  assert.match(screen, /never stops receipts, booking confirmations or security messages/,
    'and it must say so, because a customer turning everything off needs to know what still arrives');
});

test('the RPCs revoke the default execute grant and are customer-only', () => {
  for (const signature of [
    'public.customer_get_communication_preferences_v263()',
    'public.customer_set_communication_preference_v263(text, text, boolean)',
    'public.customer_set_all_communications_v263(boolean)'
  ]) {
    const escaped = signature.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(
      migration,
      new RegExp(`revoke all on function ${escaped}\\s*\\n?\\s*from public, anon, authenticated;`),
      `${signature} must revoke PUBLIC, anon and authenticated`
    );
    assert.match(
      migration,
      new RegExp(`grant execute on function ${escaped}\\s*\\n?\\s*to authenticated;`),
      `${signature} must then grant only authenticated`
    );
  }
  assert.match(migration, /grant execute on function public\.internal_customer_push_claim_v95\(uuid, integer, integer\)\s*\n?\s*to service_role;/);
});

test('both new tables enable RLS and are unreachable from the browser roles', () => {
  for (const table of [
    'public.customer_communication_preferences_v263',
    'public.customer_communication_preference_audit_v263'
  ]) {
    const escaped = table.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(migration, new RegExp(`alter table ${escaped} enable row level security;`));
    assert.match(migration, new RegExp(`revoke all privileges on table ${escaped}\\s*\\n?\\s*from public, anon, authenticated;`));
  }
  assert.match(
    migration,
    /create trigger customer_communication_preference_audit_v263_immutable[\s\S]{0,160}app\.v33_append_only_guard\(\)/,
    'consent evidence must reuse the reviewed append-only guard'
  );
});
