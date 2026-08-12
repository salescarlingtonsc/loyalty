import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V282 communications foundation (owner ruling 2026-08-12: "deferred by design — proceed to build
   all"). Four half-built promises, closed in one migration:

     1  web push had a subscription store, a consent gate, a claim/lease protocol and a dispatcher
        edge function — and nothing that ever called it, plus an empty VAPID public key;
     2  a parked bottle expired in silence: no sweep, no reminder, and a shelf full of rows still
        claiming to be in storage;
     3  both consent stores were append-only and unreadable by the person the evidence is about;
     4  the consent wording promises selected partners may receive contact details, and nothing
        recorded which partner, which customer, or when.

   This suite reads the shipped artefacts — the migration, the runtime config, the dispatcher, the
   service worker, the customer surface and the platform console — because the behaviour they
   encode is what the owner is being asked to trust. The DATABASE behaviour (idempotency, the
   consent gate, own-rows-only, append-only) is proven by execution in
   db/tests/v284_comms_foundation.sql. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = relative => readFileSync(resolve(repoRoot, relative), 'utf8');
const migration = read('db/migrations/20260812_nestly_v284_comms_foundation.sql');
const suite = read('db/tests/v284_comms_foundation.sql');
const app = `${read('app/index.html')}\n${read('app/app.js')}`;
const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// ---------------------------------------------------------------------------
// 1. Web push, end to end
// ---------------------------------------------------------------------------

test('the shipped runtime config carries a real VAPID public key and never a private one', () => {
  const config = JSON.parse(read('config/runtime/production.json'));
  /* A P-256 uncompressed public point is 65 bytes, which is 87 base64url characters. A VAPID
     PRIVATE key is 32 bytes / 43 characters — so the length check below is not cosmetic: it is the
     one cheap test that fails loudly if the two halves are ever swapped. */
  assert.equal(config.webPushPublicKey.length, 87);
  assert.match(config.webPushPublicKey, /^[A-Za-z0-9_-]{80,120}$/);
  assert.match(read('app/runtime-config.js'),
    new RegExp(`"webPushPublicKey": "${escapeRegExp(config.webPushPublicKey)}"`),
    'the generated runtime config must be regenerated from the checked-in source of truth');
  /* The private half must never reach the repository. Nothing under config/ or app/ may carry a
     43-character base64url value on a line that names the private key. */
  for (const file of ['config/runtime/production.json', 'app/runtime-config.js']) {
    assert.doesNotMatch(read(file), /PRIVATE|privateKey|VAPID_PRIVATE/i,
      `${file} must not mention a private key`);
  }
});

test('a pg_cron schedule actually ticks the dispatcher, and names its failure reasons', () => {
  assert.match(migration, /cron\.schedule\(\s*\n?\s*'nestly-v282-customer-push-dispatch',\s*\n?\s*'\*\/5 \* \* \* \*'/);
  assert.match(migration, /app\.v282_run_customer_push_dispatch\(\)/);
  assert.match(migration, /\/functions\/v1\/customer-push-dispatch/);
  /* The header name is compared in constant time by the edge function; the two must agree or the
     dispatcher answers 401 while looking perfectly healthy. */
  assert.match(migration, /x-nestly-push-dispatch-secret/);
  assert.match(read('supabase/functions/_shared/customer-push.ts'), /x-nestly-push-dispatch-secret/);
  for (const reason of ['extensions_unavailable', 'vault_unavailable', 'secret_unconfigured']) {
    assert.match(migration, new RegExp(`'${reason}'`),
      'a missing precondition must return a named reason, not raise');
  }
  assert.match(migration, /revoke all privileges on function app\.v282_run_customer_push_dispatch\(\)\s*\n\s*from public, anon, authenticated, service_role;/);
  assert.match(migration, /grant execute on function app\.v282_run_customer_push_dispatch\(\) to service_role;/);
});

test('the dispatcher can render every event type the database calls push-eligible', () => {
  const shared = read('supabase/functions/_shared/customer-push.ts');
  const eligible = migration.slice(
    migration.indexOf('function app.customer_push_event_eligible_v95'),
    migration.indexOf('revoke all on function app.customer_push_event_eligible_v95')
  );
  const pairs = [...eligible.matchAll(/\('([a-z0-9_]+)', '([a-z_]+)'\)/g)].map(match => [match[1], match[2]]);
  assert.equal(pairs.length, 9, 'the eight pre-existing pairs plus the bottle expiry reminder');
  assert.deepEqual(pairs.at(-1), ['v282_bottle_expiry', 'value_expiry']);
  /* The real defect this closes: promotion_alerts became eligible in v255/v263 and the dispatcher
     had no mapping for it, so customerPushEventTypeOrNull returned null and every promotional push
     was recorded as a permanent 'unsupported_push_event' failure — fifteen minutes apart, forever,
     invisibly. Each eligible topic must now map to a type the service worker will render. */
  const topics = new Set(pairs.map(([, topic]) => topic));
  const swTypes = read('app/sw.js').match(/const CUSTOMER_PUSH_TYPES=new Set\(\[([\s\S]*?)\]\)/)[1];
  for (const topic of topics) {
    if (topic === 'booking_updates') continue; // mapped from source_kind, asserted below
    const expected = topic === 'promotion_alerts' ? 'promotion_alert' : topic;
    assert.match(shared, new RegExp(`'${expected}'`), `the dispatcher cannot render ${topic}`);
    assert.match(swTypes, new RegExp(`'${expected}'`), `the service worker cannot render ${topic}`);
  }
  assert.match(shared, /lease\.topic === 'promotion_alerts'\) return 'promotion_alert'/);
  for (const type of ['booking_request_received', 'appointment_time_changed']) {
    assert.match(swTypes, new RegExp(`'${type}'`));
  }
});

// ---------------------------------------------------------------------------
// 2. Bottle expiry sweep and reminders
// ---------------------------------------------------------------------------

test('the sweep is scheduled daily in Singapore time and only touches bottles in storage', () => {
  assert.match(migration, /cron\.schedule\(\s*\n?\s*'nestly-v282-bottle-expiry-daily',\s*\n?\s*'10 16 \* \* \*'/,
    '16:10 UTC is 00:10 the following Singapore day');
  const sweep = migration.slice(
    migration.indexOf('function app.v282_sweep_bottle_expiry'),
    migration.indexOf('revoke all privileges on function app.v282_sweep_bottle_expiry')
  );
  /* 'called' and 'at_table' mean the bottle is physically in service. Expiring one mid-pour would
     be a claim about the room this function is in no position to make. */
  assert.doesNotMatch(sweep, /'called'|'at_table'|'retrieved'/);
  assert.equal((sweep.match(/bottle\.status = 'stored'/g) || []).length, 2,
    'both halves - expire and remind - are scoped to bottles in storage');
  assert.match(sweep, /set status = 'expired'/);
  assert.match(sweep, /'expire', null::uuid,\s*\n\s*'v282-expire:' \|\| lapsed\.id::text/);
});

test('both halves of the sweep are idempotent by construction, not by remembering to check', () => {
  const sweep = migration.slice(
    migration.indexOf('function app.v282_sweep_bottle_expiry'),
    migration.indexOf('revoke all privileges on function app.v282_sweep_bottle_expiry')
  );
  /* The expiry predicate destroys the thing it selects on, and the event carries an idem_key
     covered by bar_bottle_events' partial unique index. The reminder's dedupe_key includes
     expires_at and the inbox has a unique (identity_id, dedupe_key) — so extending a bottle's
     window correctly produces a NEW reminder rather than a suppressed one. */
  assert.equal((sweep.match(/on conflict do nothing/g) || []).length, 2);
  assert.match(sweep, /on conflict \(identity_id, dedupe_key\) do nothing/);
  assert.match(sweep, /'identity_id', due\.identity_id, 'bottle_id', due\.bottle_id,\s*\n\s*'expires_at', due\.expires_at/);
  assert.match(sweep, /'v282-remind:' \|\| due\.bottle_id::text \|\| ':' \|\| due\.expires_at::text/);
  // And it is proven by execution, not only by shape.
  assert.match(suite, /a second sweep must expire nothing/);
  assert.match(suite, /a second sweep must remind nobody/);
  assert.match(suite, /a second sweep must not add an inbox row/);
});

test('the reminder honours the v263 consent ruling in both stores', () => {
  const sweep = migration.slice(
    migration.indexOf('function app.v282_sweep_bottle_expiry'),
    migration.indexOf('revoke all privileges on function app.v282_sweep_bottle_expiry')
  );
  /* Absence is consent (owner ruling), an explicit withdrawal still wins. This is the same pair of
     conditions app.enqueue_promotion_alert_v122 uses, and deliberately NOT v278's manual-notify
     default of coalesce(opted_in,false) — a scheduled sweep gated on a row nothing writes is a
     sweep that never sends. */
  assert.match(sweep, /coalesce\(preference\.opted_in, true\)/);
  assert.match(sweep, /app\.customer_communication_allows_v263\(\s*\n\s*link\.identity_id, 'rewards_and_points', 'in_app'\s*\n\s*\)/);
  assert.match(sweep, /link\.state = 'verified'/);
  assert.match(sweep, /link\.unlinked_at is null/);
  assert.match(suite, /a withdrawn in-app switch must suppress the reminder/);
});

test('the new inbox row stays inside the closed customer-safe vocabulary', () => {
  assert.match(migration, /'v278_bottle_reminder', 'v282_bottle_expiry'/);
  assert.match(migration, /'Your bottle is waiting', 'Your bottle expires soon'/);
  assert.match(migration, /'Open this business wallet before the bottle kept for you is collected\.'/);
  /* Written and then filtered out of every read is the failure mode this function prevents. */
  const available = migration.slice(migration.indexOf('function app.c46_inbox_source_available'));
  assert.match(available.slice(0, 600), /'v282_bottle_expiry'/);
  // No price, no identifier, no customer name may enter a notification.
  const body = migration.match(/'Open this business wallet before[^']*'/)[0];
  assert.doesNotMatch(body, /\$|\d|\{|%/);
});

test('the reminder window is one number per business, owner-writable and bounded', () => {
  assert.match(migration, /add column if not exists expiry_reminder_days integer not null default 7/);
  assert.match(migration, /check \(expiry_reminder_days between 1 and 90\)/);
  assert.match(migration, /function app\.bar_expiry_reminder_days_v282\(p_business uuid\)/);
  assert.match(migration, /function public\.bar_save_expiry_reminder_days_v282\(/);
  assert.match(migration, /only an owner may change the reminder window/);
  assert.match(migration, /'reminder_days', app\.bar_expiry_reminder_days_v282\(p_business\)/);
  // The business surface can see it and set it.
  assert.match(app, /id="bkRemindDays"/);
  assert.match(app, /Number\(extraResultV278\.data\?\.reminder_days\)\|\|7/);
  assert.match(app, /sb\.rpc\('bar_save_expiry_reminder_days_v282',\{/);
  assert.match(app, /The reminder must be a whole number between 1 and 90 days before expiry\./);
});

// ---------------------------------------------------------------------------
// 3. Consent history, self-service
// ---------------------------------------------------------------------------

test('consent history resolves the caller from the session, never from an argument', () => {
  const rpc = migration.slice(
    migration.indexOf('create or replace function public.customer_get_consent_history_v282'),
    migration.indexOf('create table public.partner_registry_v282')
  );
  assert.match(rpc, /p_limit integer default 100/);
  assert.doesNotMatch(rpc, /p_identity|p_auth|p_customer/,
    'there must be no argument a caller could supply to widen the result');
  assert.match(rpc, /v_identity uuid := app\.customer_communication_identity_v263\(\)/);
  assert.equal((rpc.match(/identity_id = v_identity/g) || []).length, 2,
    'both stores are filtered by the session identity');
  assert.equal((rpc.match(/auth_user_id = v_actor/g) || []).length, 2);
  assert.match(rpc, /least\(greatest\(coalesce\(p_limit, 100\), 1\), 200\)/);
  assert.match(migration, /revoke all on function public\.customer_get_consent_history_v282\(integer\)\s*\n\s*from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.customer_get_consent_history_v282\(integer\) to authenticated;/);
  assert.match(suite, /the caller must see exactly their own %s rows/);
  assert.match(suite, /another customer''s consent evidence must never appear/);
});

test('the profile renders consent history read-only and in plain language', () => {
  assert.match(app, /id="customerConsentHistory"/);
  assert.match(app, /<h2>Your consent history<\/h2>/);
  assert.match(app, /sb\.rpc\('customer_get_consent_history_v282',\{p_limit:100\}\)/);
  assert.match(app, /hydrateCustomerConsentHistoryV282\(isCurrent\)/);
  const section = app.slice(
    app.indexOf('const CUSTOMER_CONSENT_CATEGORY_LABELS_V282'),
    app.indexOf('async function renderCustomerProfile')
  );
  /* Read-only is the point: this is a record of what was decided, not a second place to decide it.
     Communications remains the single writer. */
  assert.doesNotMatch(section, /customer_set_communication_preference_v263|customer_set_all_communications_v263|<input|<button/);
  assert.match(app, /to change something, open Communications above/);
});

test('every consent-history sentence is plain, escaped, and covers all three entry kinds', () => {
  const source = app.slice(
    app.indexOf('const CUSTOMER_CONSENT_CATEGORY_LABELS_V282'),
    app.indexOf('async function hydrateCustomerConsentHistoryV282')
  );
  const esc = value => String(value ?? '').replace(/[&<>"']/g,
    character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
  const walletDate = value => (value ? `SGT:${value}` : '');
  const markup = new Function('esc', 'walletDate',
    `${source}; return customerConsentHistoryMarkupV282;`)(esc, walletDate);

  assert.match(markup([]), /Nothing has changed yet/);
  assert.match(
    markup([{ entry_kind: 'marketing_channel', category: 'business_offers', channel: 'sms', enabled: false, occurred_at: 'T1' }]),
    /You turned off SMS for offers from businesses you follow\./);
  assert.match(
    markup([{ entry_kind: 'marketing_all_channels', enabled: true, occurred_at: 'T1' }]),
    /You turned on every marketing message, on every channel\./);
  assert.match(
    markup([{ entry_kind: 'platform_partner_marketing', enabled: false, occurred_at: 'T1' }]),
    /You withdrew your agreement to marketing from Peekaa and its selected partners\./);
  assert.match(markup([{ entry_kind: 'marketing_all_channels', enabled: true, occurred_at: 'T1' }]), /SGT:T1/);
  // A category or channel the client has never heard of degrades to its raw key, escaped.
  const hostile = markup([{ entry_kind: 'marketing_channel', category: '<img src=x>', channel: '<script>', enabled: true, occurred_at: 'T1' }]);
  assert.doesNotMatch(hostile, /<img src=x>|<script>/);
});

// ---------------------------------------------------------------------------
// 4. Partner obligations
// ---------------------------------------------------------------------------

test('the three partner tables are RPC-only, append-only, and platform-scoped', () => {
  for (const table of ['partner_registry_v282', 'partner_disclosures_v282', 'partner_suppressions_v282']) {
    assert.match(migration, new RegExp(`create table public\\.${table} \\(`));
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security;`));
    assert.match(migration, new RegExp(`revoke all privileges on table public\\.${table}\\s*\\n\\s*from public, anon, authenticated;`));
    assert.doesNotMatch(migration, new RegExp(`create policy [a-z_]+ on public\\.${table}`),
      'zero policies: the SECURITY DEFINER RPCs are the only door');
  }
  assert.match(migration, /create trigger partner_disclosures_v282_immutable\s*\n\s*before update or delete on public\.partner_disclosures_v282/);
  /* A suppression is NOT plain append-only: an acknowledgement legitimately arrives later. Exactly
     one transition is allowed and nothing else about the row may move. */
  const guard = migration.slice(
    migration.indexOf('function app.v282_partner_suppression_guard'),
    migration.indexOf('create trigger partner_suppressions_v282_guard')
  );
  assert.match(guard, /if tg_op = 'DELETE' then/);
  assert.match(guard, /already acknowledged/);
  assert.match(guard, /only an acknowledgement may amend a suppression instruction/);
  for (const column of ['partner_id', 'identity_id', 'reason', 'issued_at', 'issued_by', 'idempotency_key']) {
    assert.match(guard, new RegExp(`new\\.${column} is distinct from old\\.${column}`));
  }
});

test('every partner RPC is super-admin only and no tenant role can reach one', () => {
  const rpcs = [
    ['platform_list_partner_obligations_v282', 'integer'],
    ['platform_save_partner_v282', 'uuid, text, text, text'],
    ['platform_record_partner_suppression_v282', 'uuid, text, text, uuid'],
    ['platform_acknowledge_partner_suppression_v282', 'uuid, text']
  ];
  for (const [name, args] of rpcs) {
    assert.match(migration, new RegExp(`function public\\.${name}\\(`));
    assert.match(migration, new RegExp(`revoke all on function public\\.${name}\\(${escapeRegExp(args)}\\)`));
    assert.match(migration, new RegExp(`grant execute on function public\\.${name}\\(${escapeRegExp(args)}\\) to authenticated;`));
  }
  assert.equal((migration.match(/if not app\.is_super_admin\(\) then/g) || []).length, 4);
  assert.equal((migration.match(/using errcode = '42501'/g) || []).length, 5,
    'four super-admin gates plus the bar owner gate');
  assert.match(suite, /must refuse a business owner/);
});

test('the suppression instruction is idempotent and acknowledgeable exactly once', () => {
  assert.match(migration, /create unique index partner_suppressions_v282_idempotency_uk\s*\n\s*on public\.partner_suppressions_v282 \(partner_id, idempotency_key\)/);
  assert.match(migration, /'status', 'duplicate_ignored', 'suppression_id', v_id/);
  assert.match(migration, /and suppression\.acknowledged_at is null\s*\n\s*returning suppression\.id into v_id;/);
  assert.match(migration, /no unacknowledged suppression instruction with that id/);
  assert.match(suite, /a replayed suppression instruction must not be recorded twice/);
  assert.match(suite, /an acknowledgement must be recordable exactly once/);
});

test('the console section exists, is super-admin only, and never lists a customer', () => {
  const console_ = read('app/platform-console.js');
  assert.match(console_, /\{key:'partners',label:'Partner obligations',shortLabel:'Partners',hash:'#\/platform\/partners',icon:'setup',superAdminOnly:true\}/);
  assert.match(console_, /routeKeys:Object\.freeze\(\['sectors','partners','access'\]\)/);
  assert.match(console_, /if\(!task&&activeKey==='partners'\)task=renderPartnerObligations\(context\);/);
  for (const rpc of ['platform_list_partner_obligations_v282', 'platform_save_partner_v282',
    'platform_record_partner_suppression_v282', 'platform_acknowledge_partner_suppression_v282']) {
    assert.match(console_, new RegExp(`rpc\\(sb,'${rpc}'`));
  }
  /* The read counts customers and never returns one. A cross-tenant console has no reason to
     render the roster the partner ledger exists to protect, and a leak here would be
     self-defeating. */
  const listRpc = migration.slice(
    migration.indexOf('function public.platform_list_partner_obligations_v282'),
    migration.indexOf('function public.platform_save_partner_v282')
  );
  assert.match(listRpc, /'customers', count\(\*\)/);
  assert.doesNotMatch(listRpc, /identity\.|full_name|phone|email|identity_id',/);
  assert.match(console_, /This is the evidence layer the customer consent already promises\./);
});

test('the deep link to every registered console route resolves', () => {
  const console_ = read('app/platform-console.js');
  /* V282 replaced a hand-kept alternation that had fallen three routes behind — marketing, crm and
     companies were all real, reachable routes whose reload or deep link answered "Peekaa admin
     could not be loaded". Deriving it from the registry is what stops it drifting a fourth time. */
  assert.doesNotMatch(console_, /#\\\/platform\(\?:\\\/\(\?:onboarding\|/);
  assert.match(console_, /return routes\.some\(route=>route\.key!=='overview'&&route\.key===path\.slice\('#\/platform\/'\.length\)\);/);
});

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

test('the migration is registered in both plans under one coordinate', () => {
  const plan = JSON.parse(read('db/migrations/migration-order.plan.json'));
  const canonical = JSON.parse(read('supabase/canonical-migration-order.plan.json'));
  assert.deepEqual(plan.items.at(-1), {
    kind: 'executable',
    path: 'db/migrations/20260812_nestly_v284_comms_foundation.sql',
    /* V284 rename: a concurrent session took the v282/v283 names on main; the file is
       v284 while production keeps the applied name nestly_v282_comms_foundation. */
    semanticVersion: 'v284',
    proposedDeployVersion: '20260812000400'
  });
  assert.deepEqual(canonical.items.at(-1), {
    kind: 'pending',
    version: '20260812000400',
    name: 'nestly_v284_comms_foundation',
    sourcePath: 'db/migrations/20260812_nestly_v284_comms_foundation.sql'
  });
  // Atomic boundaries: exactly one transaction, and the suite rolls itself back.
  assert.equal((migration.match(/^\s*begin\s*;\s*$/gim) || []).length, 1);
  assert.equal((migration.match(/^\s*commit\s*;\s*$/gim) || []).length, 1);
  assert.equal((suite.match(/^\s*rollback\s*;\s*$/gim) || []).length, 1);
  assert.doesNotMatch(suite, /^\s*commit\s*;\s*$/im);
});
