import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(`../../${path}`, import.meta.url), 'utf8');
const sourcePath = 'db/migrations/20260729_nestly_v110_growth_delivery_lifecycle.sql';
const mirrorPath =
  'supabase/migrations/20260729171130_nestly_v110_growth_delivery_lifecycle.sql';
const sqlTestPath = 'db/tests/v110_growth_delivery_lifecycle.sql';

test('v110 migration pair is exact and forward isolated', async () => {
  const [source, mirror] = await Promise.all([read(sourcePath), read(mirrorPath)]);
  assert.equal(source, mirror);
  assert.match(source, /^-- NESTLY v110 — PROVIDER-NEUTRAL/m);
  assert.doesNotMatch(source, /drop\s+(?:table|function|schema)/i);
  assert.match(
    source,
    /create or replace function app\.v110_request_hash\(p_value jsonb\)[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i,
  );
});

test('approval output is intercepted into queue or quiet-hours schedule', async () => {
  const source = await read(sourcePath);
  assert.match(source, /growth_deliveries_v110_prepare[\s\S]*before insert/i);
  assert.match(
    source,
    /new\.delivery_status := case[\s\S]*'quiet_hours' then 'scheduled'[\s\S]*else 'queued'/i,
  );
  assert.match(source, /v110_next_allowed_at/i);
  assert.match(source, /app\.c46_in_quiet_hours/i);
});

test('provider-neutral dispatch rechecks all mutable gates before claim', async () => {
  const source = await read(sourcePath);
  const claim = source.match(
    /create or replace function public\.service_claim_growth_deliveries_v110[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(claim, /auth\.jwt\(\) ->> 'role'[\s\S]*service_role/i);
  assert.match(claim, /for update skip locked/i);
  assert.match(claim, /platform_feature_enabled\('growth_closed_loop_v108'\)/i);
  assert.match(claim, /'retention' = any/i);
  assert.match(claim, /execution_expired/i);
  assert.match(claim, /link\.state = 'verified'/i);
  assert.match(claim, /preference\.opted_in/i);
  assert.match(claim, /c46_in_quiet_hours/i);
  assert.match(claim, /frequency_cap/i);
  assert.match(claim, /budget_cap_cents/i);
});

test('verified callback is the only path that issues an entitlement', async () => {
  const source = await read(sourcePath);
  const complete = source.match(
    /create or replace function public\.service_complete_growth_delivery_v110[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(complete, /service role required/i);
  assert.match(complete, /verified provider message id is required/i);
  assert.match(complete, /app\.v110_transition_delivery\([\s\S]*'delivered'/i);
  assert.match(complete, /insert into public\.growth_entitlements_v108/i);
  assert.match(complete, /on conflict \(delivery_id\) do nothing/i);
  assert.match(complete, /insert into public\.growth_entitlement_events_v108/i);
});

test('lifecycle supports owner cancellation, bounded retry and auditable events', async () => {
  const source = await read(sourcePath);
  assert.match(source, /growth_delivery_state_events_v110_idempotency_uk/i);
  assert.match(source, /request_hash text not null/i);
  assert.match(source, /cancel_growth_delivery_v110/i);
  assert.match(source, /retry_growth_delivery_v110/i);
  assert.match(source, /attempt_count >= 5/i);
  assert.match(source, /growth_delivery_state_events_v110_immutable/i);
  assert.match(source, /growth delivery transitions require the lifecycle service/i);
});

test('browser tables are read-only and service callbacks are service-role only', async () => {
  const source = await read(sourcePath);
  assert.match(
    source,
    /revoke all privileges on table[\s\S]*growth_delivery_dispatches_v110[\s\S]*from public, anon, authenticated/i,
  );
  assert.match(
    source,
    /grant execute on function[\s\S]*service_claim_growth_deliveries_v110[\s\S]*to service_role/i,
  );
  assert.doesNotMatch(
    source,
    /grant execute on function[\s\S]{0,500}service_complete_growth_delivery_v110[\s\S]{0,100}to authenticated/i,
  );
});

test('rollback-only SQL proves lifecycle gates, exact replay and scoped reads', async () => {
  const sql = await read(sqlTestPath);
  assert.match(sql, /^-- Rollback-only v110/m);
  assert.match(sql, /\nbegin;\n/i);
  assert.match(sql, /\nrollback;\s*$/i);
  assert.match(sql, /queued -> claim -> verified callback -> one entitlement/i);
  assert.match(sql, /provider-v110-success-1/i);
  assert.match(sql, /reused key/i);
  assert.match(sql, /Five verified provider failures permit four retries/i);
  assert.match(sql, /attempt_count[\s\S]*<> 5/i);
  assert.match(sql, /quiet-hour delivery was not scheduled forward/i);
  assert.match(sql, /cancellation was not replay-safe/i);
  assert.match(sql, /feature kill switch/i);
  assert.match(sql, /module kill switch/i);
  assert.match(sql, /consent withdrawal/i);
  assert.match(sql, /link loss/i);
  assert.match(sql, /budget cap/i);
  assert.match(sql, /frequency cap/i);
  assert.match(sql, /branch-scoped reader saw another branch/i);
  assert.match(sql, /browser session completed a provider callback/i);
  assert.match(sql, /transition history/i);
});
