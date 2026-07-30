import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (relative) => readFile(new URL(`../../${relative}`, import.meta.url), 'utf8');
const migrationPath = 'db/migrations/20260729_nestly_v108_measured_bringback_loop.sql';
const mirrorPath = 'supabase/migrations/20260729171045_nestly_v108_measured_bringback_loop.sql';

test('v108 migration mirror is byte-identical and forward-only', async () => {
  const [migration, mirror] = await Promise.all([read(migrationPath), read(mirrorPath)]);
  assert.equal(mirror, migration);
  assert.match(migration, /^-- NESTLY v108 — MEASURED BRING-BACK LOOP/m);
  assert.doesNotMatch(
    migration,
    /drop\s+(?:table|function|schema)|disable\s+row\s+level\s+security/i,
  );
});

test('recommendations carry evidence, windows, confidence, cost and explicit limitations', async () => {
  const migration = await read(migrationPath);
  for (const field of [
    'observation_start', 'observation_end', 'comparison_start', 'comparison_end',
    'supporting_evidence', 'expected_incremental_revenue', 'confidence', 'assumptions',
    'estimated_cost_cents', 'data_freshness_at', 'data_coverage', 'suppression_reasons',
  ]) {
    assert.match(migration, new RegExp(`\\b${field}\\b`, 'i'), field);
  }
  assert.match(migration, /expected_incremental_gross_profit is null/i);
  assert.match(migration, /expected revenue is a range, not a guarantee/i);
  assert.match(migration, /gross profit is unavailable until item cost coverage is complete/i);
  assert.match(migration, /withheld_uncalibrated/i);
  assert.match(migration, /incremental_revenue_not_yet_available/i);
  assert.match(migration, /score_kind', 'data_quality_only'/i);
  assert.match(migration, /cold_start_under_50_sales/i);
  assert.match(migration, /identity_coverage_below_threshold/i);
  assert.match(migration, /experiment_arms_too_small/i);
});

test('the audience is reproducible from transparent cadence rules and safe exclusions', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /percentile_cont\(0\.5\)[\s\S]*interval_days/i);
  assert.match(migration, /minimum_prior_visits/i);
  assert.match(migration, /minimum_lapse_days/i);
  assert.match(
    migration,
    /cadence_days[\s\S]{0,120}v_effective_policy #>> '\{parameters,cadence_multiplier\}'/i,
  );
  for (const exclusion of [
    'insufficient_history', 'not_lapsed', 'no_verified_link',
    'no_marketing_consent', 'frequency_cap', 'active_experiment',
  ]) {
    assert.match(migration, new RegExp(`'${exclusion}'`, 'i'), exclusion);
  }
  assert.match(migration, /preview_growth_recommendation_v108/i);
  assert.match(migration, /excluded_by_reason/i);
});

test('owner approval creates deterministic treatment and holdout without autonomous sending', async () => {
  const migration = await read(migrationPath);
  const approve = migration.match(
    /create or replace function public\.approve_growth_recommendation_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(approve, /app\.is_salon_owner\(p_business\)/i);
  assert.match(approve, /recommendation is no longer executable/i);
  assert.match(approve, /offer exceeds configured economic guardrail/i);
  assert.match(approve, /sha256/i);
  assert.match(approve, /assignment_rank <= v_holdout then 'holdout' else 'treatment'/i);
  assert.match(approve, /minimum_arm_size/i);
  assert.match(
    approve,
    /\(v_rec\.data_coverage -> 'effective_policy'\) - 'source_availability'[\s\S]*v_effective_policy - 'source_availability'/i,
  );
  assert.doesNotMatch(
    approve,
    /v_rec\.data_coverage -> 'effective_policy' is distinct from v_effective_policy/i,
  );
  assert.match(approve, /consent_withdrawn/i);
  assert.match(approve, /quiet_hours/i);
  assert.match(approve, /frequency_cap/i);
  assert.match(approve, /delivery_gate\.can_deliver/i);
  assert.doesNotMatch(
    migration.match(
      /create or replace function public\.refresh_growth_recommendation_v108[\s\S]+?\nend \$\$;/i,
    )?.[0] || '',
    /insert into public\.growth_deliveries_v108/i,
  );
});

test('offer copy is selected from governed templates and locks branch-local expiry facts', async () => {
  const migration = await read(migrationPath);
  const approve = migration.match(
    /create or replace function public\.approve_growth_recommendation_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(
    approve,
    /p_offer_label not in \(\s*'welcome_back', 'member_thank_you', 'simple_saving'/i,
  );
  assert.match(approve, /app\.v106_reporting_contract\(/i);
  assert.match(approve, /v_offer_expires_at at time zone v_offer_timezone/i);
  assert.match(approve, /'template_id', p_offer_label/i);
  assert.match(approve, /'timezone', v_offer_timezone/i);
  assert.match(approve, /'cta_label', 'Redeem now'/i);
  assert.match(migration, /offer_timezone text not null/i);
  assert.match(migration, /offer_expires_at timestamptz not null/i);
  assert.match(
    migration,
    /governed_copy #>> '\{locked_facts,template_id\}' = offer_label/i,
  );
  assert.match(
    migration,
    /governed_copy #>> '\{locked_facts,timezone\}' = offer_timezone/i,
  );
  assert.doesNotMatch(approve, /at time zone 'Asia\/Singapore'/i);
});

test('approval and briefing expose the asynchronous lifecycle vocabulary', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /'queued', v_queued/i);
  assert.match(migration, /'scheduled', v_scheduled/i);
  assert.match(migration, /'held_out', v_heldout/i);
  assert.match(migration, /delivery_status = 'held_out'/i);
  assert.doesNotMatch(migration, /delivery_status = 'held'/i);
});

test('entitlements are single-use, expiry is evented and staff redemption is sale-bound', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /delivery_id uuid not null unique/i);
  assert.match(migration, /token_hash text not null unique/i);
  assert.match(migration, /unique \(identity_id, idempotency_key\)/i);
  assert.match(migration, /request_hash text not null check \(request_hash ~ '\^\[0-9a-f\]\{64\}\$'\)/i);
  assert.match(migration, /set status = 'expired'[\s\S]*returning id, business_id, expires_at/i);
  assert.match(migration, /event_type, actor, idempotency_key[\s\S]*'expired'/i);
  const redeem = migration.match(
    /create or replace function public\.redeem_growth_offer_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(redeem, /app\.has_perm\(p_business, 'create_sales'\)/i);
  assert.match(redeem, /token_hash = encode\(extensions\.digest/i);
  assert.match(redeem, /'entitlement_id', v_intent\.entitlement_id/i);
  assert.match(redeem, /v_sale\.client_id <> v_entitlement\.client_id/i);
  assert.match(redeem, /not v_sale\.counts_as_revenue/i);
  assert.match(redeem, /v_sale\.occurred_at > v_now/i);
  assert.match(redeem, /v_existing\.detail ->> 'request_hash' <> v_request_hash/i);
  assert.match(redeem, /return v_existing\.detail -> 'receipt'/i);
  assert.match(redeem, /status = 'redeemed', redeemed_at = v_now/i);
});

test('sale outcomes are reversal-aware and results distinguish association from inference', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /after insert on public\.sales/i);
  assert.match(migration, /after insert on public\.commerce_refund_allocations_v106/i);
  assert.match(migration, /if new\.reversal_of is not null/i);
  assert.match(migration, /set status = 'reversed', reversed_at = statement_timestamp\(\)/i);
  assert.match(migration, /randomized_intent_to_treat_holdout/i);
  assert.match(migration, /invalid_overlap/i);
  assert.match(migration, /inconclusive_small_sample/i);
  assert.match(migration, /incremental_gross_profit', null/i);
  assert.match(migration, /actual_redeemed_cost_cents/i);
  assert.match(migration, /reversed_offer_cost_cents/i);
  assert.match(migration, /app\.v106_sale_residual_minor\(outcome\.sale_id, p_as_of\) > 0/i);
});

test('result projection and finalization use one frozen cutoff and replay the stored result', async () => {
  const migration = await read(migrationPath);
  const finalize = migration.match(
    /create or replace function public\.finalize_growth_execution_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  const resultAt = migration.match(
    /create or replace function app\.get_growth_execution_result_at_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  const liveResult = migration.match(
    /create or replace function public\.get_growth_execution_result_v108[\s\S]+?\nend \$\$;/i,
  )?.[0] || '';
  assert.match(migration, /unique \(business_id, finalized_by, idempotency_key\)/i);
  assert.match(resultAt, /p_as_of timestamptz/i);
  assert.match(resultAt, /'as_of', p_as_of/i);
  assert.doesNotMatch(resultAt, /clock_timestamp\(\)|statement_timestamp\(\)/i);
  assert.match(liveResult, /v_as_of timestamptz := clock_timestamp\(\)/i);
  assert.match(
    liveResult,
    /app\.get_growth_execution_result_at_v108\(p_execution, v_as_of\)/i,
  );
  assert.match(finalize, /v_now timestamptz := clock_timestamp\(\)/i);
  assert.match(
    finalize,
    /app\.get_growth_execution_result_at_v108\(p_execution, v_now\)/i,
  );
  assert.match(finalize, /v_existing\.request_hash <> v_request_hash/i);
  assert.match(finalize, /execution was finalized with another idempotency key/i);
});

test('browser access is RPC-only with RLS and explicit grants', async () => {
  const migration = await read(migrationPath);
  const tables = [
    'growth_policies_v108',
    'growth_recommendations_v108',
    'growth_recommendation_members_v108',
    'growth_recommendation_decisions_v108',
    'growth_executions_v108',
    'growth_execution_members_v108',
    'growth_deliveries_v108',
    'growth_entitlements_v108',
    'growth_entitlement_events_v108',
    'growth_redemption_intents_v108',
    'growth_outcomes_v108',
    'growth_execution_results_v108',
  ];
  for (const table of tables) {
    assert.match(
      migration,
      new RegExp(`alter table public\\.${table} enable row level security`, 'i'),
      table,
    );
  }
  assert.match(
    migration,
    /revoke all privileges on table public\.growth_policies_v108,[\s\S]*public\.growth_execution_results_v108[\s\S]*from public, anon, authenticated/i,
  );
  assert.match(migration, /revoke all privileges on function public\.refresh_growth_recommendation_v108/i);
  assert.match(migration, /grant execute on function public\.refresh_growth_recommendation_v108[\s\S]*to authenticated/i);
  assert.doesNotMatch(migration, /grant execute[\s\S]{0,300}to anon/i);
});
