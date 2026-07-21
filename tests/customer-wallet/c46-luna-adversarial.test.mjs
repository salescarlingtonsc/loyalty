import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260722_frenly_v46_customer_in_app_inbox.sql';
const deployPath = 'supabase/migrations/20260721170000_frenly_v46_customer_in_app_inbox.sql';

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(`create or replace function (?:public|app)\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

function shellFunction(script, name) {
  const start = script.indexOf(`${name}(){`);
  assert.ok(start >= 0, `${name} is missing`);
  const end = script.indexOf('\n}', start);
  assert.ok(end > start, `${name} is incomplete`);
  return script.slice(start, end + 2);
}

const sha256 = (value) => createHash('sha256').update(value).digest('hex');

test('Luna C46: deploy mirror is exact and the independently accepted C45 authority is unchanged', async () => {
  const [source, deploy, c45, c45Deploy] = await Promise.all([
    read(sourcePath),
    read(deployPath),
    read('db/migrations/20260721_frenly_v45_birthday_benefits.sql'),
    read('supabase/migrations/20260721163000_frenly_c45_birthday_benefits.sql')
  ]);
  assert.equal(source, deploy, 'C46 canonical source and deploy mirror diverged');
  assert.equal(c45, c45Deploy, 'C45 canonical source and deploy mirror diverged');
  assert.equal(
    sha256(c45),
    '2326d2dac76d3f8b3e99a543fb16e0e39146aa13b4911328491279367213ca76',
    'C46 must not rewrite the independently accepted C45 birthday authority'
  );
});

test('Luna C46: birthday inbox creation requires both C45 participation and the precise C46 reminder consent', async () => {
  const [source, fixture] = await Promise.all([
    read(sourcePath),
    read('db/tests/v46_customer_in_app_inbox.sql')
  ]);
  const sync = functionBlock(source, 'customer_sync_in_app_inbox');

  assert.match(sync, /customer_birthday_participation/i,
    'birthday reminder creation must consult the C45 participation authority, not only the C46 topic preference');
  assert.match(sync, /select\s+coalesce\(p\.opted_in\s*,\s*false\)\s+into\s+v_birthday_participating[\s\S]{0,300}customer_birthday_participation/i,
    'birthday candidate creation must require active C45 participation');
  assert.match(sync, /if\s+v_candidate\.topic\s*=\s*'birthday_benefit'\s+and\s+not\s+v_birthday_participating/i,
    'the C45 participation check must be tied specifically to birthday candidates');

  // The C45 projection intentionally preserves an already activated promise
  // after participation withdrawal. The rollback fixture therefore has to
  // create that real source and prove that the separate reminder gate still
  // prevents a fresh C46 event while participation is off.
  assert.match(fixture, /customer_set_birthday_participation\(true/i,
    'fixture must first enable C45 participation');
  assert.match(fixture, /customer_activate_birthday_benefit/i,
    'fixture must create an authoritative eligible/activated birthday source');
  assert.match(fixture, /customer_set_birthday_participation\(false/i,
    'fixture must withdraw C45 participation while the source remains visible');
  assert.match(fixture, /created a birthday inbox event without current C45 participation/i,
    'fixture must assert that no birthday inbox event is created after C45 participation withdrawal');
  assert.match(fixture, /birthday re-opt-in did not create one inbox event/i,
    'fixture must prove that both consents together create exactly one birthday event');
  assert.match(fixture, /withdrawal did not resolve\/suppress birthday inbox history while retaining the entitlement/i,
    'fixture must prove later C45 withdrawal suppresses C46 without erasing the C45 promise');
});

test('Luna C46: dismissal is terminal and a later read/unread response reports effective persisted state', async () => {
  const [source, fixture, harness] = await Promise.all([
    read(sourcePath),
    read('db/tests/v46_customer_in_app_inbox.sql'),
    read('db/tests/v46_customer_in_app_inbox_concurrency.sh')
  ]);
  const state = functionBlock(source, 'customer_set_in_app_inbox_state');

  assert.doesNotMatch(state,
    /dismissed_at\s*=\s*case\s+when\s+v_operation\s*=\s*'dismiss'[\s\S]{0,220}else\s+null\s+end/i,
    'read/unread must never clear a prior dismissal without an explicit restore operation');
  assert.match(state,
    /dismissed_at\s*=\s*case[\s\S]{0,300}when\s+public\.customer_in_app_inbox_state\.dismissed_at\s+is\s+not\s+null\s+then\s+public\.customer_in_app_inbox_state\.dismissed_at/i,
    'the state transition must preserve an existing dismissed_at value');
  assert.match(state, /returning\s+\*\s+into\s+v_state/i,
    'the RPC must derive its response from the persisted row');
  assert.match(state,
    /case\s+when\s+v_state\.dismissed_at\s+is\s+not\s+null\s+then\s+'dismissed'/i,
    'response state must report effective persisted dismissal, not merely echo the requested operation');

  assert.match(fixture, /customer_set_in_app_inbox_state\([^;]*'dismiss'/i,
    'rollback fixture must dismiss a real event');
  assert.match(fixture, /customer_set_in_app_inbox_state\([^;]*'unread'/i,
    'rollback fixture must attempt unread after dismissal');
  assert.match(fixture, /terminal dismissal did not exclude the event from stored state, list, or count/i,
    'rollback fixture must assert terminal stored state and truthful response after dismiss then unread');

  assert.match(harness, /select[^\n]*dismissed_at[^\n]*from public\.customer_in_app_inbox_state/i,
    'two-session harness must inspect the converged persisted state');
  assert.match(harness, /unread-vs-dismiss race resurrected a dismissed inbox event/i,
    'two-session unread-vs-dismiss harness must assert a terminal dismissed outcome');
});

test('Luna C46: concurrency birthday source is current-window and consent ordering is exercised by two sessions', async () => {
  const harness = await read('db/tests/v46_customer_in_app_inbox_concurrency.sh');

  assert.match(harness,
    /'C46 synthetic customer'\s*,\s*\(timezone\('Asia\/Singapore'\s*,\s*statement_timestamp\(\)\)\)::date/i,
    'a zero-day birthday window needs a synthetic DOB in the current Singapore birthday window');
  assert.doesNotMatch(harness,
    /'C46 synthetic customer'\s*,\s*date\s+'1990-01-01'/i,
    'a fixed January DOB makes the birthday activation harness fail for most of the year');

  assert.match(harness, /participation_with_identity_lock\s+false[^\n]*>[^\n]*&/i,
    'C45 withdrawal must overlap another session rather than be only sequential setup');
  assert.match(harness, /withdraw-first participation race created a new birthday inbox event/i,
    'harness must prove withdrawal-first ordering creates no birthday event');
  assert.match(harness, /post-withdraw revalidation did not resolve the C46 birthday event/i,
    'harness must prove sync-first ordering converges after withdrawal revalidation');
  assert.match(harness, /rm -f[^\n]*[\s\S]{0,500}\$work_dir\/race-first[\s\S]{0,120}\$work_dir\/race-second/i,
    'self-contained harness cleanup must remove its consent-race response files');

  for (const name of [
    'preference_with_identity_lock',
    'sync_with_identity_lock',
    'participation_with_identity_lock'
  ]) {
    const helper = shellFunction(harness, name);
    const lock = helper.search(/select\s+1\s+from\s+public\.customer_identities[\s\S]*for update/i);
    const browserRole = helper.search(/set local role authenticated/i);
    assert.ok(lock >= 0 && browserRole > lock,
      `${name} must acquire its test-only raw identity lock as the DB owner before switching to the raw-table-denied browser role`);
  }
});

test('Luna C46: customer output remains finite, self-scoped, and transport-free', async () => {
  const source = await read(sourcePath);
  for (const reader of [
    'customer_get_in_app_inbox_count',
    'customer_list_in_app_inbox',
    'customer_get_in_app_inbox_global_count',
    'customer_list_in_app_inbox_global'
  ]) {
    const block = functionBlock(source, reader);
    assert.match(block, /c46_customer_inbox_(?:global_)?context/i, `${reader} must derive customer scope`);
    assert.doesNotMatch(block, /birth_date|date_of_birth|phone|email|source_fingerprint|dedupe_key/i,
      `${reader} must not expose private profile or internal dedupe evidence`);
  }
  assert.doesNotMatch(source,
    /insert\s+into\s+public\.customer_notification_outbox|https?:\/\/|sendgrid|twilio|webhook|push_token/i,
    'C46 must not write an external/provider transport');
  assert.match(source, /title text not null check \(title in \(/i);
  assert.match(source, /body text not null check \(body in \(/i);
});

test('Luna C46-R1: expiry facts preserve the finite C44 unit without claiming money value', async () => {
  const [source, fixture] = await Promise.all([
    read(sourcePath),
    read('db/tests/v46_customer_in_app_inbox.sql')
  ]);
  const candidates = functionBlock(source, 'c46_customer_safe_inbox_candidates');
  const expiryStart = candidates.indexOf("select 'c44_actionable_wallet', 'value_expiry'");
  const expiry = candidates.slice(expiryStart, candidates.search(/\n\s*union all/i));

  assert.match(expiry, /case\s+when\s+p_card#>>'\{loyalty,unit\}'='stamps'\s+then\s+'Stamps expire soon'\s+else\s+'Points expire soon'/i);
  assert.match(expiry, /review your stamps[\s\S]*review your points/i);
  assert.match(expiry, /'unit',p_card#>>'\{loyalty,unit\}'/i,
    'changing between points and stamps must create a distinct immutable source fingerprint');
  assert.match(expiry, /where\s+p_card#>>'\{loyalty,unit\}'\s+in\s*\('points','stamps'\)/i,
    'an unknown loyalty unit must not be silently relabelled as points');
  assert.doesNotMatch(expiry, /\$|dollar|saving|save money|cash value|credit value/i,
    'expiry copy must not invent a monetary value or saving');
  assert.match(fixture, /unit','stamps'[\s\S]*Stamps expire soon[\s\S]*unit','points'[\s\S]*Points expire soon/i,
    'rollback fixture must exercise both accepted unit labels');
  assert.match(fixture, /unit','currency'[\s\S]*candidate\.topic='value_expiry'/i,
    'rollback fixture must reject an unsupported unit rather than mislabel it');
});

test('Luna C46-R1: event and sync roots reject a real cross-identity link tuple', async () => {
  const [source, v31, fixture] = await Promise.all([
    read(sourcePath),
    read('db/migrations/20260720_frenly_v31_customer_links_claims.sql'),
    read('db/tests/v46_customer_in_app_inbox.sql')
  ]);

  assert.match(v31, /customer_links_id_business_identity_uk\s+unique\s*\(id,\s*business_id,\s*identity_id\)/i,
    'the referenced customer-link provenance tuple must be an actual unique key');
  for (const table of ['events', 'sync_operations']) {
    const tableBlock = source.slice(
      source.indexOf(`create table public.customer_in_app_inbox_${table}`),
      source.indexOf('\n);', source.indexOf(`create table public.customer_in_app_inbox_${table}`)) + 3
    );
    assert.match(tableBlock,
      /foreign key\s*\(link_id,\s*business_id,\s*identity_id\)[\s\S]*references public\.customer_links\(id,\s*business_id,\s*identity_id\)/i,
      `${table} must prove link/business/identity provenance at its root`);
  }
  assert.match(fixture,
    /insert into public\.customer_in_app_inbox_events[\s\S]{0,800}v_foreign_link[\s\S]{0,250}privileged cross-identity event provenance','23503'/i,
    'fixture must attempt and reject a privileged event using another identity\'s authentic link');
  assert.match(fixture,
    /insert into public\.customer_in_app_inbox_sync_operations[\s\S]{0,700}v_foreign_link[\s\S]{0,250}privileged cross-identity sync provenance','23503'/i,
    'fixture must attempt and reject the same root-provenance attack against sync evidence');
});

test('Luna C46-R1: disabled C44 authority preserves history but removes unread and actionability on both readers', async () => {
  const [source, fixture] = await Promise.all([
    read(sourcePath),
    read('db/tests/v46_customer_in_app_inbox.sql')
  ]);
  const sync = functionBlock(source, 'customer_sync_in_app_inbox');
  const sourceAvailable = functionBlock(source, 'c46_inbox_source_available');

  assert.match(sourceAvailable, /select\s+\$1\s*=\s*'v33_booking_action'/i,
    'booking history must remain independently available');
  assert.match(sourceAvailable, /coalesce\(\$2,\s*false\)[\s\S]*c44_actionable_wallet[\s\S]*c45_birthday_benefit/i,
    'C44 and C45 actionability must fail closed together');
  assert.match(sync,
    /and\s*\(e\.source_kind='v33_booking_action'\s+or\s+v_actionable_source_available\)[\s\S]*not\s*\(e\.source_kind\|\|':'\|\|e\.source_fingerprint\s*=\s*any\(v_active_source_keys\)\)/i,
    'disabled C44/C45 sources must not be falsely resolved during unavailable-source sync');

  for (const reader of ['customer_get_in_app_inbox_count', 'customer_get_in_app_inbox_global_count']) {
    assert.match(functionBlock(source, reader),
      /c46_inbox_source_available\(e\.source_kind,\s*v_actionable_source_available\)/i,
      `${reader} must omit unavailable C44/C45 facts from unread totals`);
  }
  for (const reader of ['customer_list_in_app_inbox', 'customer_list_in_app_inbox_global']) {
    const block = functionBlock(source, reader);
    assert.match(block, /when\s+not\s+v_row\.source_available\s+then\s+'source_unavailable'/i);
    assert.match(block, /'route_key',case\s+when\s+v_row\.resolution_id\s+is\s+null\s+and\s+v_row\.source_available\s+then\s+v_row\.route_key\s+else\s+null\s+end/i);
    assert.match(block, /'action_available',v_row\.resolution_id\s+is\s+null\s+and\s+v_row\.source_available/i);
    assert.match(block, /v_filter='all'\s+or\s*\([\s\S]*c46_inbox_source_available\(e\.source_kind,\s*v_actionable_source_available\)[\s\S]*s\.read_at\s+is\s+null/i,
      `${reader} unread filter must exclude source-unavailable history`);
  }

  assert.match(fixture, /where feature_key='customer_actionable_wallet'[\s\S]*customer_sync_in_app_inbox\(v_slug,gen_random_uuid\(\)\)/i);
  assert.match(fixture, /customer_list_in_app_inbox_global[\s\S]*'state'\s*<>\s*'source_unavailable'[\s\S]*'route_key'\s+is\s+not\s+null[\s\S]*'action_available'/i,
    'fixture must verify unavailable state, null route, and false action on the global reader');
  assert.match(fixture, /re-enabled C44 source falsely resolved or failed to reactivate the live C45 inbox fact/i,
    'reenabling C44 must revalidate the real C45 entitlement rather than falsely resolve it');
});

test('Luna C46-R1: UI sync/offline failure clears stale actions and retry repeats sync before list', async () => {
  const app = await read('app/index.html');
  const inbox = app.slice(
    app.indexOf('async function renderCustomerInAppInbox'),
    app.indexOf('function renderCustomerNotificationPreferences')
  );
  const unavailable = inbox.slice(
    inbox.indexOf('const renderRefreshUnavailable='),
    inbox.indexOf('const load=async')
  );
  const refresh = inbox.slice(
    inbox.indexOf('refreshInbox=async()=>'),
    inbox.indexOf('const renderPreferences=async')
  );

  assert.match(unavailable, /globalThis\.navigator\?\.onLine===false/i);
  assert.match(unavailable, /items=\[\];nextCursor=null;bell=null/i,
    'failure view must discard every previously rendered actionable item');
  assert.match(unavailable, /slot\.innerHTML=''/i,
    'failure view must remove a possibly stale unread bell');
  assert.match(unavailable, /id="customerInboxSyncRetry"/i);
  assert.match(unavailable, /await\s+refreshInbox\(\)/i,
    'retry must repeat authoritative sync rather than directly loading stale history');

  const syncRequest = refresh.indexOf("global?'customer_sync_in_app_inbox_global':'customer_sync_in_app_inbox'");
  const syncErrorGuard = refresh.indexOf('if(error){renderRefreshUnavailable();return;}');
  const bellRefresh = refresh.indexOf('await refreshBell()');
  const listLoad = refresh.indexOf('await load(null)');
  assert.ok(syncRequest >= 0 && syncErrorGuard > syncRequest && bellRefresh > syncErrorGuard && listLoad > bellRefresh,
    'sync must succeed before unread count and list are fetched');
  assert.match(refresh, /if\(!refreshedBell\|\|refreshedBell\.error\)\{renderRefreshUnavailable\(\);return;\}/i,
    'count failure must also withhold the list and all programme actions');
});
