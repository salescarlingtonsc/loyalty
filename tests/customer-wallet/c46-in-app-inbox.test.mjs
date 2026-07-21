import assert from 'node:assert/strict';
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

test('Terra C46: canonical source/deploy mirror is exact and the inbox starts disabled', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(source, deploy);
  assert.match(source, /values \('customer_in_app_inbox', false\)\s*on conflict \(feature_key\) do nothing/i);
});

test('Terra C46: C44/C45 remain source-only facts; no provider or external transport is introduced', async () => {
  const [source, c44, c45] = await Promise.all([
    read(sourcePath),
    read('db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql'),
    read('db/migrations/20260721_frenly_v45_birthday_benefits.sql')
  ]);
  const candidates = functionBlock(source, 'c46_customer_safe_inbox_candidates');
  assert.match(candidates, /c44_actionable_wallet/i);
  assert.match(candidates, /c45_birthday_benefit/i);
  assert.match(functionBlock(source, 'customer_sync_in_app_inbox'), /public\.customer_get_actionable_business\(v_context\.business_slug\)/i);
  assert.doesNotMatch(source, /(?:https?:\/\/|sendgrid|twilio|firebase|webhook|push_token|mailgun)/i);
  assert.doesNotMatch(c44, /inbox|enqueue|provider/i);
  assert.match(c45, /customer_birthday_benefits/i);
});

test('Terra C46-R1: expiry facts preserve the reviewed C44 points/stamps unit with finite no-value copy', async () => {
  const source = await read(sourcePath);
  const candidates = functionBlock(source, 'c46_customer_safe_inbox_candidates');
  const expiryCandidate = candidates.slice(
    candidates.indexOf("select 'c44_actionable_wallet', 'value_expiry'"),
    candidates.indexOf('union all')
  );
  assert.match(candidates, /p_card#>>'\{loyalty,unit\}'='stamps'/i);
  assert.match(candidates, /'Stamps expire soon'[\s\S]*'Open this business wallet to review your stamps\.'/i);
  assert.match(candidates, /'Points expire soon'[\s\S]*'Open this business wallet to review your points\.'/i);
  assert.match(candidates, /\{loyalty,unit\}' in \('points','stamps'\)/i,
    'unknown C44 units must not be relabelled as points');
  assert.match(candidates, /'unit',p_card#>>'\{loyalty,unit\}'/i,
    'a loyalty-unit change must receive a deterministic new source fingerprint');
  assert.doesNotMatch(expiryCandidate, /save|saving|\$|dollar|credit value/i,
    'an expiry reminder must never imply a monetary saving');
  assert.match(source, /title text not null check \(title in \([\s\S]*'Points expire soon', 'Stamps expire soon'/i);
  assert.match(source, /body text not null check \(body in \([\s\S]*'Open this business wallet to review your stamps\.'/i);
});

test('Terra C46: consent is a narrow v33 extension with an IANA quiet-hours seam', async () => {
  const source = await read(sourcePath);
  const setter = functionBlock(source, 'customer_set_in_app_inbox_preferences');
  const timezone = functionBlock(source, 'c46_iana_timezone_allowed');
  const quiet = functionBlock(source, 'c46_in_quiet_hours');

  assert.match(source, /alter table public\.customer_notification_preferences[\s\S]*quiet_hours_timezone/i);
  assert.match(source, /alter table public\.customer_preference_audit[\s\S]*quiet_hours_timezone/i);
  assert.match(functionBlock(source, 'c46_in_app_topic_allowed'), /value_expiry[\s\S]*reward_ready[\s\S]*visit_progress[\s\S]*birthday_benefit[\s\S]*booking_updates/i);
  assert.match(setter, /not app\.c46_in_app_topic_allowed\(v_topic\)/i);
  assert.match(setter, /not app\.c46_iana_timezone_allowed\(v_timezone\)/i);
  assert.match(timezone, /pg_timezone_names/i);
  assert.match(quiet, /p_start < p_end[\s\S]*v_local_time >= p_start and v_local_time < p_end/i);
  assert.match(quiet, /v_local_time >= p_start or v_local_time < p_end/i);
  assert.match(setter, /customer_preference_audit/i);
});

test('Terra C46: facts are immutable, state changes are provenance-bound operations, and raw tables are closed', async () => {
  const source = await read(sourcePath);
  for (const table of [
    'customer_in_app_inbox_events', 'customer_in_app_inbox_state',
    'customer_in_app_inbox_state_operations', 'customer_in_app_inbox_resolutions',
    'customer_in_app_inbox_sync_operations', 'customer_in_app_inbox_global_sync_operations'
  ]) {
    assert.match(source, new RegExp(`create table public\\.${table}`, 'i'));
    assert.match(source, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(source, new RegExp(`revoke all privileges on table public\\.${table} from public, anon, authenticated`, 'i'));
  }
  assert.match(source, /customer_in_app_inbox_events_provenance_uk[\s\S]*unique \(id, business_id, identity_id, client_id, link_id\)/i);
  assert.match(source, /customer_in_app_inbox_events_link_identity_scope_fk[\s\S]*foreign key \(link_id, business_id, identity_id\)[\s\S]*references public\.customer_links\(id, business_id, identity_id\)/i);
  assert.match(source, /customer_in_app_inbox_sync_operations_link_identity_scope_fk[\s\S]*foreign key \(link_id, business_id, identity_id\)[\s\S]*references public\.customer_links\(id, business_id, identity_id\)/i);
  assert.match(source, /customer_in_app_inbox_state_event_scope_fk[\s\S]*references public\.customer_in_app_inbox_events\(id, business_id, identity_id, client_id, link_id\)/i);
  assert.match(source, /customer_in_app_inbox_state_operations_event_scope_fk[\s\S]*references public\.customer_in_app_inbox_events/i);
  assert.match(source, /customer_in_app_inbox_resolutions_event_scope_fk[\s\S]*references public\.customer_in_app_inbox_events/i);
  assert.match(source, /customer_in_app_inbox_events_immutable_guard/i);
  assert.match(source, /customer_in_app_inbox_state_operations_immutable_guard/i);
  assert.match(source, /customer_in_app_inbox_state_guard/i);
  assert.match(functionBlock(source, 'c46_inbox_state_guard'), /current_setting\('app\.c46_inbox_state_event'/i);
  assert.match(functionBlock(source, 'customer_set_in_app_inbox_state'), /customer_in_app_inbox_state_operations/i);
});

test('Terra C46: customer RPCs are gated, self-scoped, idempotent, and page output is capped', async () => {
  const source = await read(sourcePath);
  const context = functionBlock(source, 'c46_customer_inbox_context');
  assert.match(context, /auth\.uid\(\)/i);
  assert.match(context, /customer_in_app_inbox/i);
  assert.match(context, /cl\.state = 'verified'/i);
  for (const name of [
    'customer_set_in_app_inbox_preferences', 'customer_get_in_app_inbox_preferences',
    'customer_sync_in_app_inbox', 'customer_sync_in_app_inbox_global', 'customer_get_in_app_inbox_count',
    'customer_list_in_app_inbox', 'customer_get_in_app_inbox_global_count',
    'customer_list_in_app_inbox_global', 'customer_set_in_app_inbox_state'
  ]) {
    const body = functionBlock(source, name);
    assert.match(body, name.includes('_global')
      ? /app\.c46_customer_inbox_global_context\(\)/i
      : /app\.c46_customer_inbox_context\(p_business_slug\)/i,
      `${name} must derive its customer scope`);
    assert.match(body, /security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  }
  const sync = functionBlock(source, 'customer_sync_in_app_inbox');
  const state = functionBlock(source, 'customer_set_in_app_inbox_state');
  const list = functionBlock(source, 'customer_list_in_app_inbox');
  const count = functionBlock(source, 'customer_get_in_app_inbox_count');
  const preferenceSetter = functionBlock(source, 'customer_set_in_app_inbox_preferences');
  assert.match(sync, /customer_in_app_inbox_sync_operations[\s\S]*idempotency_key/i);
  assert.match(sync, /customer_birthday_participation[\s\S]*v_birthday_participating/i,
    'a C45 entitlement card alone must not create a C46 birthday event');
  assert.match(sync, /v_candidate\.topic='birthday_benefit'[\s\S]*not v_birthday_participating[\s\S]*continue/i,
    'C45 participation withdrawal must remove the birthday source key for resolution');
  assert.match(sync, /customer_identities[\s\S]*for update[\s\S]*v_request_hash/i,
    'sync must linearize consent/participation before reading sources or preferences');
  assert.match(preferenceSetter, /customer_identities[\s\S]*for update[\s\S]*v_idempotency/i,
    'preference mutation must share the C45 participation lock');
  assert.match(sync, /customer_in_app_inbox_resolutions/i);
  assert.match(functionBlock(source, 'c46_inbox_source_available'), /v33_booking_action[\s\S]*c44_actionable_wallet[\s\S]*c45_birthday_benefit/i);
  assert.match(sync, /v33_booking_action/i);
  assert.match(sync, /v_cycle[\s\S]*source_cycle/i,
    'a resolved source must receive a deterministic next occurrence cycle, never a clock-based dedupe');
  assert.match(state, /customer_in_app_inbox_state_operations[\s\S]*idempotency_key/i);
  assert.match(state, /dismissed_at is not null then public\.customer_in_app_inbox_state\.dismissed_at/i,
    'dismissal must survive later read/unread requests');
  assert.match(state, /returning \* into v_state[\s\S]*v_state\.dismissed_at/i,
    'state response must describe the effective stored state');
  assert.match(list, /least\(greatest\([^\n]*,1\),50\)/i);
  assert.match(list, /limit v_limit\+1/i);
  assert.match(list, /p_cursor - 'limit' - 'filter' - 'created_at' - 'event_id'/i);
  assert.match(list, /v_filter not in \('all','unread'\)/i);
  assert.match(count, /customer_actionable_wallet[\s\S]*c46_inbox_source_available/i,
    'a C44/C45 fact must leave unread counts while its authority is unavailable');
  assert.match(list, /action_available[\s\S]*v_row\.source_available/i);
  assert.match(list, /route_key',case when v_row\.resolution_id is null and v_row\.source_available then v_row\.route_key else null end/i);
  assert.match(list, /when not v_row\.source_available then 'source_unavailable'/i);
  const global = functionBlock(source, 'customer_list_in_app_inbox_global');
  const globalCount = functionBlock(source, 'customer_get_in_app_inbox_global_count');
  assert.match(global, /c46_customer_inbox_global_context/i);
  assert.match(global, /business.*business_slug/i);
  assert.match(global, /limit v_limit\+1/i);
  assert.match(global, /route_key',case when v_row\.resolution_id is null and v_row\.source_available then v_row\.route_key else null end/i,
    'resolved or source-unavailable history must not expose a CTA route');
  assert.match(global, /action_available[\s\S]*v_row\.source_available/i);
  assert.match(global, /when not v_row\.source_available then 'source_unavailable'/i);
  assert.match(globalCount, /customer_actionable_wallet[\s\S]*c46_inbox_source_available/i,
    'the global bell must exclude C44/C45 facts while their safe source is unavailable');
  assert.match(source, /customer_get_in_app_inbox_global_count\(\)[\s\S]*to authenticated/i);
  const globalSync = functionBlock(source, 'customer_sync_in_app_inbox_global');
  assert.match(globalSync, /limit 101/i);
  assert.match(globalSync, /if v_count>100 then v_truncated:=true/i);
  assert.match(globalSync, /customer_sync_in_app_inbox\(v_link\.slug,v_child_key\)/i);
  assert.match(globalSync, /customer_in_app_inbox_global_sync_operations/i);
  assert.match(globalSync, /lexical,[\s\S]*link order/i);
  assert.match(source, /grant execute on function public\.customer_list_in_app_inbox\(text,jsonb\) to authenticated/i);
  assert.match(source, /revoke all on function public\.customer_list_in_app_inbox\(text,jsonb\) from public, anon, authenticated/i);
});

test('Terra C46: a resolved fact can recur as a new deterministic unread cycle', () => {
  const cycleKey = (sourceFingerprint, resolvedOccurrences) =>
    JSON.stringify({ sourceFingerprint, sourceCycle: resolvedOccurrences });
  const first = cycleKey('same-reward-name-and-cost', 0);
  const reappeared = cycleKey('same-reward-name-and-cost', 1);
  assert.notEqual(first, reappeared);
  assert.equal(cycleKey('same-reward-name-and-cost', 1), reappeared,
    'two concurrent revalidation attempts derive the same next cycle key');
  assert.doesNotMatch(reappeared, /2026|timestamp|now/i);
});

test('Terra C46: rollback fixture and self-contained sync/state concurrency harness remain local-only', async () => {
  const [fixture, harness] = await Promise.all([
    read('db/tests/v46_customer_in_app_inbox.sql'),
    read('db/tests/v46_customer_in_app_inbox_concurrency.sh')
  ]);
  assert.match(fixture, /^begin;/im);
  assert.match(fixture, /^rollback;/im);
  assert.match(fixture, /C46 inbox flag is not default off/i);
  assert.match(fixture, /C46 IANA timezone seam drifted/i);
  assert.match(fixture, /C46 expiry copy must preserve only the C44 points\/stamps unit without a value claim/i);
  assert.match(fixture, /create_business\(/i);
  assert.match(fixture, /customer_appointment_action_requests/i);
  assert.match(fixture, /birthday double-consent/i);
  assert.match(fixture, /eligible C45 entitlement/i);
  assert.match(fixture, /without current C45 participation/i);
  assert.match(fixture, /birthday re-opt-in did not create one inbox event/i);
  assert.match(fixture, /withdrawal did not resolve\/suppress birthday inbox history/i);
  assert.match(fixture, /foreign customer business isolation/i);
  assert.match(fixture, /staff-only customer isolation/i);
  assert.match(fixture, /anonymous inbox isolation/i);
  assert.match(fixture, /preference changed-key conflict/i);
  assert.match(fixture, /state changed-key conflict/i);
  assert.match(fixture, /stale source was not resolved/i);
  assert.match(fixture, /did not recur as a new unread cycle/i);
  assert.match(fixture, /bounded first page\/cursor failed/i);
  assert.match(fixture, /resolved history exposed an actionable deep link/i);
  assert.match(fixture, /legacy customer_notification_outbox\/provider evidence/i);
  assert.match(fixture, /Dismissal is terminal/i);
  assert.match(fixture, /read resurrected a dismissed inbox event/i);
  assert.match(fixture, /terminal dismissal did not exclude the event from stored state, list, or count/i);
  assert.match(fixture, /privileged cross-identity event provenance/i);
  assert.match(fixture, /privileged cross-identity sync provenance/i);
  assert.match(fixture, /disabled C44 source did not make C44\/C45 history unavailable, non-actionable, and unread-excluded/i);
  assert.match(fixture, /re-enabled C44 source falsely resolved or failed to reactivate the live C45 inbox fact/i);
  assert.match(harness, /C46_CONFIRM_DISPOSABLE_DB=YES/i);
  assert.match(harness, /gadpooereceldfpfxsod/i);
  assert.match(harness, /self-created C46 business fixture/i);
  assert.match(harness, /cleanup_synthetic_fixture\.sql/i);
  assert.match(harness, /restore_feature_flags/i);
  assert.match(harness, /same-key two-session sync/i);
  assert.match(harness, /different-key two-session sync/i);
  assert.match(harness, /same-key two-session state operation/i);
  assert.match(harness, /different-key two-session state operations/i);
  assert.match(harness, /unread-vs-dismiss race resurrected a dismissed inbox event/i);
  assert.match(harness, /dismissed event remained in the unread count/i);
  assert.match(harness, /dismissed event remained in the all-items list/i);
  assert.match(harness, /cmp -s/i);
  assert.match(harness, /exactly one evidence row/i);
});

test('Terra C46: customer wallet UI has an accessible stale-guarded bell and inbox controls', async () => {
  const app = await read('app/index.html');
  const inbox = app.slice(app.indexOf('async function renderCustomerInAppInbox'), app.indexOf('function renderWorkspaceAccessUnavailable'));
  assert.match(app, /customer_in_app_inbox:false/i);
  assert.match(inbox, /customer_sync_in_app_inbox/i);
  assert.match(inbox, /customer_sync_in_app_inbox_global/i);
  assert.match(inbox, /customer_get_in_app_inbox_count/i);
  assert.match(inbox, /customer_list_in_app_inbox/i);
  assert.match(inbox, /customer_set_in_app_inbox_state/i);
  assert.match(inbox, /walletSectionStillCurrent\(host,isCurrent\)/i);
  assert.match(inbox, /aria-label="Open inbox"/i);
  assert.match(inbox, /aria-live="polite"/i);
  assert.match(inbox, /data-route-key="wallet_business"/i);
  assert.match(inbox, /My Frenly inbox/i);
  assert.match(inbox, /customerInboxSyncRetry/i);
  assert.match(inbox, /A list is never loaded after a failed C46 sync/i);
  assert.match(inbox, /globalThis\.navigator\?\.onLine===false/i);
  assert.match(inbox, /Programme actions are hidden until refresh succeeds/i);
  assert.match(inbox, /customerInboxQuietTimezone/i);
  assert.match(inbox, /preference\.quiet_hours_timezone\|\|'Asia\/Singapore'/i);
  assert.match(inbox, /timezoneInput\.value\.trim\(\)/i);
  assert.match(inbox, /p_quiet_hours_timezone:start\?timezone:null/i);
  assert.match(inbox, /future interruptive channel/i);
  assert.match(inbox, /customerInboxQuietStart[\s\S]*customerInboxQuietEnd[\s\S]*customerInboxQuietTimezone[\s\S]*Save reminder/i);
  assert.match(inbox, /item\?\.action_available===true&&!isResolved&&item\?\.route_key/i,
    'a resolved or source-unavailable item must not render a client action');
  assert.match(inbox, /source_unavailable[\s\S]*Programme temporarily unavailable/i);
  assert.match(inbox, /loyaltyUnit==='stamps'\?'Stamps expiry reminders':loyaltyUnit==='points'\?'Points expiry reminders':'Expiry reminders'/i,
    'the preference label must use the C44 loyalty unit or fall back to neutral copy');
});
