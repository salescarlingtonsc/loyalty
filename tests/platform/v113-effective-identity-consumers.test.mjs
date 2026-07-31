import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../../", import.meta.url);
const canonicalUrl = new URL(
  "db/migrations/20260730_nestly_v113_effective_identity_consumers.sql",
  root,
);
const deployUrl = new URL(
  "supabase/migrations/20260729210000_nestly_v113_effective_identity_consumers.sql",
  root,
);
const regressionUrl = new URL(
  "db/tests/v113_effective_identity_consumers.sql",
  root,
);
const concurrencyUrl = new URL(
  "db/tests/v113_effective_identity_consumers_concurrency.sh",
  root,
);

const [canonical, deploy, regression, concurrency] = await Promise.all([
  readFile(canonicalUrl, "utf8"),
  readFile(deployUrl, "utf8"),
  readFile(regressionUrl, "utf8"),
  readFile(concurrencyUrl, "utf8"),
]);

function functionBody(source, signature) {
  const start = source.indexOf(`create or replace function ${signature}`);
  assert.notEqual(start, -1, `${signature} is missing`);
  const end = source.indexOf("\n$$;", start);
  assert.notEqual(end, -1, `${signature} body is not terminated`);
  return source.slice(start, end);
}

test("v113 canonical and deploy mirrors are byte-identical", () => {
  assert.equal(deploy, canonical);
  assert.equal((canonical.match(/^begin;$/gm) ?? []).length, 1);
  assert.equal((canonical.match(/^commit;$/gm) ?? []).length, 1);
  assert.equal((regression.match(/^begin;$/gm) ?? []).length, 1);
  assert.equal((regression.match(/^rollback;$/gm) ?? []).length, 1);
});

test("v113 only resolves attribution and does not rewrite immutable source rows", () => {
  assert.doesNotMatch(canonical, /update\s+public\.(clients|sales)\b/i);
  assert.doesNotMatch(canonical, /delete\s+from\s+public\.(clients|sales)\b/i);
  assert.doesNotMatch(canonical, /drop\s+(table|schema)\b/i);
  assert.match(
    canonical,
    /Historical sales, recommendation, execution, delivery and entitlement rows remain\s+-- immutable/,
  );
});

test("v113 internal resolvers are hardened and not public APIs", () => {
  for (const signature of [
    "app.v113_effective_client_id(",
    "app.v113_customer_effective_client_id(",
    "app.v113_guard_growth_execution_identity()",
    "app.v113_canonicalize_execution_member()",
  ]) {
    const body = functionBody(canonical, signature);
    assert.match(
      body,
      /security definer[\s\S]*set search_path to 'pg_catalog','public','app','pg_temp'/,
    );
  }
  for (const signature of [
    "app.v113_effective_client_id(uuid,uuid)",
    "app.v113_customer_effective_client_id(uuid,uuid)",
    "app.v113_guard_growth_execution_identity()",
    "app.v113_canonicalize_execution_member()",
  ]) {
    assert.match(
      canonical,
      new RegExp(
        `revoke all on function ${signature.replace(/[().]/g, "\\$&")}\\s+from public,anon,authenticated`,
      ),
    );
  }
});

test("v113 reserves one current effective identity at the approval boundary", () => {
  const guard = functionBody(
    canonical,
    "app.v113_guard_growth_execution_identity()",
  );
  assert.match(
    guard,
    /count\(distinct app\.v113_effective_client_id\(member\.business_id,member\.client_id\)\)/,
  );
  assert.match(
    guard,
    /recommendation identity snapshot is stale; refresh before approval[\s\S]*errcode='55000'/,
  );
  assert.match(
    guard,
    /app\.v113_effective_client_id\([\s\S]*active_execution\.status='running'/,
  );
  assert.match(
    guard,
    /recommendation overlaps an active effective-customer experiment[\s\S]*errcode='23P01'/,
  );
  assert.match(
    canonical,
    /create trigger growth_executions_v113_identity_guard[\s\S]*before insert on public\.growth_executions_v108/,
  );
  assert.match(
    canonical,
    /new\.client_id:=app\.v113_effective_client_id\(new\.business_id,new\.client_id\)/,
  );
  assert.match(
    canonical,
    /create trigger growth_execution_members_v113_effective_identity[\s\S]*before insert on public\.growth_execution_members_v108/,
  );
  const correctionApproval = functionBody(
    canonical,
    "public.approve_customer_identity_correction_v111(",
  );
  assert.match(
    correctionApproval,
    /growth-v108-membership:[\s\S]*v_active_members>1[\s\S]*identity correction would overlap active customer experiments[\s\S]*errcode='23P01'/,
  );
  assert.match(
    canonical,
    /alter function public\.approve_customer_identity_correction_v111\(uuid,uuid\)[\s\S]*rename to approve_customer_identity_correction_v111_v113_inner/,
  );
});

test("v113 two-session harness proves both correction/growth commit orderings", () => {
  assert.match(concurrency, /V113_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency, /qadpooereceldfpfxsod/);
  assert.match(
    concurrency,
    /correction-first[\s\S]*approve_customer_identity_correction_v111[\s\S]*approve_growth_recommendation_v108/,
  );
  assert.match(
    concurrency,
    /growth-first[\s\S]*approve_growth_recommendation_v108[\s\S]*approve_customer_identity_correction_v111/,
  );
  assert.match(concurrency, /recommendation identity snapshot is stale/);
  assert.match(
    concurrency,
    /identity correction would overlap active customer experiments/,
  );
  assert.match(
    concurrency,
    /approved\|presented\|proof_attached\|executed/,
  );
});

test("v113 recommendation refresh partitions every live exclusion by effective identity", () => {
  const refresh = functionBody(
    canonical,
    "public.refresh_growth_recommendation_v108(",
  );
  assert.match(
    refresh,
    /with canonical_sales as \([\s\S]*app\.v113_effective_client_id\(sale\.business_id,sale\.client_id\) as client_id/,
  );
  assert.match(
    refresh,
    /v_candidates jsonb:='\[\]'::jsonb/,
  );
  assert.doesNotMatch(refresh, /pg_temp\.growth_candidates_v113/);
  assert.match(
    refresh,
    /jsonb_agg\(jsonb_build_object\([\s\S]*order by judged\.client_id\)[\s\S]*into v_candidates/,
  );
  const typedCandidateProjection =
    /jsonb_to_recordset\(v_candidates\) as candidate\(\s*client_id uuid,\s*prior_visits integer,\s*last_visit_at timestamptz,\s*cadence_days numeric,\s*lapse_days integer,\s*average_transaction_cents bigint,\s*historical_revenue_cents bigint,\s*eligible boolean,\s*exclusion_reason text\s*\)/g;
  assert.equal(
    (refresh.match(typedCandidateProjection) ?? []).length,
    3,
    "candidate counts, fingerprint and member insert must share one typed projection",
  );
  for (const consumer of [
    "customer_links link",
    "customer_notification_preferences preference",
    "growth_deliveries_v108 delivery",
    "growth_execution_members_v108 member",
  ]) {
    assert.match(refresh, new RegExp(consumer.replaceAll(".", "\\.")));
  }
  assert.match(
    refresh,
    /app\.v113_effective_client_id\([\s\S]*='running'/,
  );
  assert.match(refresh, /concat_ws\(':'[\s\S]*'v113'/);
  assert.match(
    refresh,
    /select v_recommendation,p_business,candidate\.client_id,candidate\.eligible/,
  );
});

test("v113 customer offer and redemption follow the current unambiguous identity", () => {
  const offers = functionBody(
    canonical,
    "public.customer_get_growth_offers_v108(",
  );
  const prepare = functionBody(
    canonical,
    "public.customer_prepare_growth_offer_qr_v108(",
  );
  const redeem = functionBody(
    canonical,
    "public.redeem_growth_offer_v108(",
  );
  assert.match(offers, /app\.v113_customer_effective_client_id/);
  assert.match(
    offers,
    /identity_row\.status='active'[\s\S]*app\.v113_effective_client_id/,
  );
  assert.match(prepare, /app\.v113_customer_effective_client_id/);
  assert.match(prepare, /'effective_client_id',v_client/);
  assert.match(
    redeem,
    /app\.v113_effective_client_id\(v_sale\.business_id,v_sale\.client_id\)[\s\S]*app\.v113_effective_client_id/,
  );
  assert.match(
    redeem,
    /v_execution\.branch_id is not null[\s\S]*v_sale\.branch_id is distinct from v_execution\.branch_id/,
  );
  assert.match(
    canonical,
    /grant execute on function public\.customer_get_growth_offers_v108\(uuid\)[\s\S]*to authenticated/,
  );
  assert.match(
    canonical,
    /revoke all on function public\.customer_get_growth_offers_v108\(uuid\)[\s\S]*from public,anon/,
  );
});

test("v113 measurement and finance consumers use current attribution", () => {
  const capture = functionBody(
    canonical,
    "app.capture_growth_outcome_v108()",
  );
  const result = functionBody(
    canonical,
    "app.get_growth_execution_result_at_v108(",
  );
  const driver = functionBody(
    canonical,
    "public.get_revenue_driver_decomposition_v109(",
  );
  assert.match(
    capture,
    /select member\.execution_id,member\.execution_member_id,new\.business_id,\s*member\.client_id,new\.id/,
  );
  assert.match(
    capture,
    /app\.v113_effective_client_id\(member\.business_id,member\.client_id\)[\s\S]*app\.v113_effective_client_id\(new\.business_id,new\.client_id\)/,
  );
  assert.match(capture, /select count\(\*\) into v_overlap/);
  assert.match(
    capture,
    /row_number\(\) over \([\s\S]*partition by execution\.id[\s\S]*execution_rank=1/,
  );
  assert.match(capture, /on conflict do nothing/);
  assert.match(result, /with effective_members as/);
  assert.match(result, /count\(\*\) over \([\s\S]*effective_client_id/);
  assert.match(result, /when v_identity_overlap>0 then 'invalid_overlap'/);
  assert.match(
    result,
    /'identity_attribution','v111_current_effective_identity'/,
  );
  assert.ok(
    (
      driver.match(
        /app\.v113_effective_client_id\(sale\.business_id,sale\.client_id\) as client_id/g,
      ) ?? []
    ).length >= 2,
  );
  assert.match(
    driver,
    /'identity_attribution','v111_current_effective_identity'/,
  );
  assert.match(driver, /from public\.sale_items item/);
  assert.match(driver, /'current_itemized_transaction_bps'/);
  assert.match(driver, /'current_itemized_revenue_bps'/);
  assert.match(driver, /'price_volume_mix_status','not_claimed'/);
});

test("v113 rollback E2E proves correction, reversal, denials, and immutability", () => {
  assert.match(
    regression,
    /collapsed immutable members did not emit one fail-closed outcome/,
  );
  assert.match(regression, /outcome\.overlap_count=2/);
  assert.match(
    regression,
    /v_result->>'measurement_status'<>'invalid_overlap'/,
  );
  for (const evidence of [
    /propose_customer_identity_correction_v111/,
    /'verified_contact_pair'/,
    /approve_customer_identity_correction_v111/,
    /reverse_customer_identity_correction_v111/,
    /stale duplicate-effective recommendation was executed/,
    /effective target entered an overlapping experiment/,
    /disabled identity read an effective-client offer/,
    /customer offer access crossed a tenant boundary/,
    /branch-mismatched target sale redeemed the offer/,
    /later target purchase was not attributed to source member/,
    /driver counts\/frequency split corrected identity/,
    /driver decomposition did not restore source\/target split/,
    /current_itemized_transaction_bps/,
    /price_volume_mix_status/,
    /v113 changed immutable source identifiers/,
  ]) {
    assert.match(regression, evidence);
  }
  assert.match(regression, /customer_prepare_growth_offer_qr_v108/);
  assert.match(regression, /redeem_growth_offer_v108/);
  assert.match(regression, /customer_get_growth_offers_v108/);
});
