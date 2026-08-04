import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../../db/migrations/20260804_nestly_v155_multibranch_foundation.sql', import.meta.url), 'utf8');
const docs = readFileSync(new URL('../../docs/insights/V155-MULTI-BRANCH-FOUNDATION.md', import.meta.url), 'utf8');

function appSection(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

test('V155 defines one canonical server-side reporting branch-scope contract', () => {
  assert.match(migration, /create or replace function app\.resolve_reporting_branch_scope_v155/);
  assert.match(migration, /p_scope_mode text/);
  assert.match(migration, /p_branch_ids uuid\[\]/);
  assert.match(migration, /p_operational_branch uuid/);
  assert.match(migration, /empty_selected_branch_scope/);
  assert.match(migration, /foreign_or_inactive_branch_scope/);
  assert.match(migration, /unauthorised_branch_scope/);
  assert.match(migration, /select distinct unnest\(coalesce\(p_branch_ids,array\[\]::uuid\[\]\)\)/);
  assert.match(migration, /app\.can_see_branch\(p_business,branch\.id\)/);
  assert.match(docs, /Operational branch/);
  assert.match(docs, /Reporting scope/);
});

test('V155 dashboard and retention use selected/all branch scope without changing operational branch', () => {
  assert.match(migration, /create or replace function public\.get_dashboard_summary_v155/);
  assert.match(migration, /create or replace function public\.staff_list_customers_v155/);
  assert.match(migration, /deduplicated canonical customer/i);
  assert.match(migration, /last valid visit within that selected scope/i);
  assert.match(app, /reportingScopeV155/);
  assert.match(app, /renderReportingScopeSelectorV155/);
  const dashboard = appSection('async function dashboard()', 'async function clientsPage()');
  assert.match(dashboard, /get_dashboard_summary_v155/);
  assert.match(dashboard, /currentReportingScopePayloadV155/);
  assert.doesNotMatch(dashboard, /selectedBranchId\s*=\s*reportingScopeV155/);
  const customers = appSection('async function clientsPage()', 'async function clientDetail');
  assert.match(customers, /staff_list_customers_v155/);
});

test('V155 aggregation rules are explicit and avoid unsafe percentage summing', () => {
  assert.match(docs, /Additive metrics/);
  assert.match(docs, /Deduplicated metrics/);
  assert.match(docs, /Non-additive metrics/);
  assert.match(docs, /Do not sum percentages/);
  assert.match(migration, /count\(distinct s\.client_id\)/);
  assert.match(migration, /repeat_customer_percentage/);
  assert.match(migration, /case when .*unique_customers.* = 0 then null/s);
});

test('V155 promotions support all or selected branches with server-side enforcement', () => {
  assert.match(migration, /create table(?: if not exists)? public\.promotion_branch_scopes_v155/);
  assert.match(migration, /promotion_branch_scopes_v155_unique/);
  assert.match(migration, /create or replace function app\.promotion_available_at_branch_v155/);
  assert.match(migration, /create or replace function public\.assert_promotion_redeemable_at_branch_v155/);
  assert.match(migration, /This promotion is not available at the selected branch/);
  assert.match(migration, /business_create_promotion_draft_v155/);
  assert.match(migration, /business_finalize_promotion_v155/);
  assert.match(migration, /customer_get_promotions_v155/);
  assert.match(app, /Promotion availability/);
  assert.match(app, /promotionScopeModeV155/);
  assert.match(app, /business_finalize_promotion_v155/);
});

test('V155 campaign preparation is branch-scoped and remains preparation-only', () => {
  assert.match(migration, /create or replace function public\.preview_campaign_audience_v155/);
  assert.match(migration, /matching_customers/);
  assert.match(migration, /unique_customers_after_deduplication/);
  assert.match(app, /Campaign delivery is not enabled yet/);
  assert.match(app, /campaignScopeLabelV155/);
  assert.doesNotMatch(appSection('function openCampaignPrepV153', 'function insightCardV153'), />Send</);
});

test('V155 documents preserved business semantics and remaining package ambiguity', () => {
  assert.match(docs, /Post-V155 readiness score: 74 \/ 100/);
  assert.match(docs, /Packages remain ambiguous/);
  assert.match(docs, /No financial, loyalty, credit, ledger, reversal, expense, P&L, appointment, billing, authentication, tenant, or role-authority semantics were changed/);
});
