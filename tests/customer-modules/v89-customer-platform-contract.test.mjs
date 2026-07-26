import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const canonicalPath =
  "supabase/migrations/20260727010000_nestly_v89_customer_qr_redemption_platform_access.sql";
const sourcePath =
  "db/migrations/20260727_nestly_v89_customer_qr_redemption_platform_access.sql";
const rollbackPath = "db/tests/v89_customer_platform_contracts.sql";
const concurrencyPath =
  "db/tests/v89_customer_qr_redemption_concurrency.sh";
const v90Path = "db/migrations/20260727_nestly_v90_production_readiness.sql";
const v90RollbackPath = "db/tests/v90_production_readiness.sql";

const canonical = await readFile(canonicalPath, "utf8");
const source = await readFile(sourcePath, "utf8");
const rollback = await readFile(rollbackPath, "utf8");
const concurrency = await readFile(concurrencyPath, "utf8");
const v90 = await readFile(v90Path, "utf8");
const v90Rollback = await readFile(v90RollbackPath, "utf8");

test("v89 source and canonical migration are byte-identical", () => {
  assert.equal(source, canonical);
});

test("v89 replaces contact self-linking with merchant-issued QR enrolment", () => {
  for (const legacySignature of [
    "customer_claim_link_by_email(text,text)",
    "customer_claim_link_by_verified_phone(text,text)",
    "customer_sync_verified_relationships_v81(text)",
    "join_program(text,text,text,text,boolean)",
  ]) {
    assert.match(
      canonical,
      new RegExp(
        `revoke all on function public\\.${legacySignature.replace(
          /[().]/g,
          "\\$&",
        )}[\\s\\S]*?from public,anon,authenticated`,
        "i",
      ),
    );
  }
  assert.match(
    canonical,
    /create or replace function public\.business_create_customer_join_qr_v89\(/i,
  );
  assert.match(
    canonical,
    /create or replace function public\.customer_join_business_from_qr_v89\(/i,
  );
  assert.match(
    canonical,
    /v_link,v_qr\.business_id,v_identity,v_actor,v_client,'verified','qr_join',now\(\)/i,
  );
  assert.match(canonical, /token_hash=app\.v89_sha256\(p_join_token\)/i);
  assert.doesNotMatch(
    canonical,
    /business_customer_join_qr_v89[\s\S]{0,400}\bjoin_token\s+text/i,
  );
});

test("v89 merchant capabilities are default-closed and enforced at mutation gates", () => {
  assert.match(
    canonical,
    /booking_enabled boolean not null default false/i,
  );
  assert.match(
    canonical,
    /redemption_enabled boolean not null default false/i,
  );
  assert.match(
    canonical,
    /appointment_changes_enabled boolean not null default false/i,
  );
  assert.match(
    canonical,
    /create trigger trg_booking_requests_customer_gate_v89[\s\S]*?before insert on public\.booking_requests/i,
  );
  assert.match(
    canonical,
    /create trigger trg_customer_appointment_action_gate_v89[\s\S]*?before insert on public\.customer_appointment_action_requests/i,
  );
  assert.match(
    canonical,
    /coalesce\(capability\.booking_enabled,false\)[\s\S]{0,180}?v89_business_module_enabled\([^)]*,'bookings'\)[\s\S]{0,180}?show_on_booking_page/i,
  );
  assert.match(
    canonical,
    /create or replace function public\.get_business_public\(p_slug text\)[\s\S]*?service\.active[\s\S]*?service\.show_on_booking_page/i,
  );
});

test("v89 redemption is pending until a scoped merchant scan completes it atomically", () => {
  assert.match(
    canonical,
    /create or replace function public\.customer_create_redemption_intent_v89\(/i,
  );
  assert.match(
    canonical,
    /v_expires timestamptz:=now\(\)\+interval '5 minutes'/i,
  );
  assert.match(
    canonical,
    /create or replace function public\.merchant_scan_redemption_qr_v89\(/i,
  );
  assert.match(
    canonical,
    /select \* into v_intent from public\.customer_redemption_intents_v89 intent[\s\S]*?for update/i,
  );
  assert.match(canonical, /public\.redeem_reward\(/i);
  assert.match(canonical, /public\.redeem_points\(/i);
  assert.match(
    canonical,
    /redemption_kind in \('classic_points','catalog_reward'\)/i,
  );
  for (const quoteField of [
    "quoted_program_id",
    "quoted_config_version_id",
    "quoted_reward_version_id",
    "quoted_points_spent",
    "quoted_credit_cents",
    "quoted_terms",
    "completion_operation_id",
  ]) {
    assert.match(canonical, new RegExp(`\\b${quoteField}\\b`, "i"));
  }
  assert.match(
    canonical,
    /update public\.customer_redemption_intents_v89 set[\s\S]*?status='completed'/i,
  );
  assert.doesNotMatch(
    canonical,
    /customer_redemption_intents_v89[\s\S]{0,700}\bqr_token\s+text/i,
  );
  assert.match(
    canonical,
    /foreign key\(business_id,client_id\)[\s\S]*?references public\.clients\(business_id,id\)/i,
  );
});

test("v89 platform roles are module-aware and sales access is own-created or assigned", () => {
  assert.match(canonical, /role in \('admin','sales_staff'\)/i);
  assert.match(
    canonical,
    /permission_key not in\([\s\S]*?'overview'[\s\S]*?'automation'/i,
  );
  assert.match(
    canonical,
    /if app\.v89_platform_role\(\)<>'admin' then return false/i,
  );
  assert.match(
    canonical,
    /prospect\.created_by=auth\.uid\(\)[\s\S]*?or prospect\.assigned_consultant_id=app\.v89_sales_consultant_id\(\)/i,
  );
  assert.match(
    canonical,
    /create or replace function public\.platform_create_my_prospect_v89\(/i,
  );
  assert.match(
    canonical,
    /values\(v_company,'new_lead',v_consultant,auth\.uid\(\),auth\.uid\(\)\)/i,
  );
  assert.match(
    canonical,
    /create or replace function public\.platform_generate_my_report_v89\(/i,
  );
  assert.match(
    canonical,
    /report contains an out-of-scope business/i,
  );
  for (const rpc of [
    "platform_list_assignment_consultants_v89",
    "platform_lookup_access_user_v89",
    "platform_list_sector_firms_v89",
    "platform_list_commission_consultants_v89",
    "platform_get_billing_v89",
    "platform_get_automation_billing_v89",
  ]) {
    assert.match(
      canonical,
      new RegExp(`create or replace function public\\.${rpc}\\(`, "i"),
    );
  }
});

test("v89 private bearer, redemption, and platform access state is not browser-readable", () => {
  for (const table of [
    "business_customer_join_qr_v89",
    "customer_redemption_intents_v89",
    "customer_redemption_events_v89",
    "platform_access_grants_v89",
    "platform_access_audit_v89",
  ]) {
    assert.match(
      canonical,
      new RegExp(
        `revoke all privileges on table public\\.${table}[\\s\\S]*?from public,anon,authenticated`,
        "i",
      ),
    );
  }
  assert.match(
    canonical,
    /revoke all privileges on table app\.v89_token_secrets[\s\S]*?from public,anon,authenticated/i,
  );
});

test("v89 rollback evidence exercises role boundaries and leaves no fixture data", () => {
  assert.match(rollback, /^begin;/im);
  assert.match(rollback, /rollback;\s*$/i);
  assert.match(rollback, /customer capabilities did not default closed/i);
  assert.match(rollback, /sales staff read another sales representative prospect/i);
  assert.match(rollback, /sales staff bypassed scope through the legacy broad reader/i);
  assert.match(rollback, /read-only admin moved a prospect/i);
  assert.match(rollback, /disabled platform grant remained active/i);
  assert.match(rollback, /customer login auto-linked a business without a QR/i);
  assert.match(rollback, /pending redemption mutated canonical balances/i);
  assert.match(rollback, /merchant replay created a second redemption/i);
  assert.match(rollback, /failed balance recheck left partial redemption state/i);
  assert.match(rollback, /public booking GET exposed a non-bookable service/i);
  assert.match(rollback, /reports-only admin did not receive the core report/i);
  assert.match(rollback, /firms-only admin generated a report/i);
  assert.match(rollback, /classic merchant receipt\/value is inconsistent/i);
  assert.match(
    rollback,
    /untrusted PG_CONTEXT probe was accepted for %/i,
  );
});

test("v90 replaces the legacy verb heuristic with positive readers and denied writers", () => {
  assert.match(v90, /unknown caller is denied/i);
  assert.match(v90, /else\s+return false;\s+end if;/i);
  assert.match(v90Rollback, /read-only admin lost the legacy onboarding reader/i);
  for (const deniedWriter of [
    "read-only admin reached prospect conversion",
    "read-only admin reached invite reissue",
    "read-only admin reached onboarding start",
    "read-only admin reached import analysis",
  ]) {
    assert.match(v90Rollback, new RegExp(deniedWriter, "i"));
  }
  assert.match(v90Rollback, /trusted legacy allowlist/i);
});

test("v89 disposable concurrency evidence races claims and scans at stress volume", () => {
  assert.match(concurrency, /V89_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency, /while \[ "\$i" -le 25 \]/);
  assert.match(concurrency, /while \[ "\$i" -le 100 \]/);
  assert.match(concurrency, /1\|1\|25/);
  assert.match(concurrency, /1\|60\|1\|1/);
});
