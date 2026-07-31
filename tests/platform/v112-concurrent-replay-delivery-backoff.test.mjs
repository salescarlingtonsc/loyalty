import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../../", import.meta.url);
const canonicalUrl = new URL(
  "db/migrations/20260730_nestly_v112_concurrent_replay_delivery_backoff.sql",
  root,
);
const deployUrl = new URL(
  "supabase/migrations/20260729200000_nestly_v112_concurrent_replay_delivery_backoff.sql",
  root,
);
const v110Url = new URL(
  "db/migrations/20260729_nestly_v110_growth_delivery_lifecycle.sql",
  root,
);

const [canonical, deploy, v110] = await Promise.all([
  readFile(canonicalUrl, "utf8"),
  readFile(deployUrl, "utf8"),
  readFile(v110Url, "utf8"),
]);

test("v112 canonical and deploy mirrors are byte-identical", () => {
  assert.equal(deploy, canonical);
});

test("v112 serializes each reviewed mutation by request and canonical record", () => {
  for (const operation of [
    "ingest_external_commerce_event_v106",
    "dismiss_growth_recommendation_v108",
    "approve_growth_recommendation_v108",
    "finalize_growth_execution_v108",
    "set_effective_cost_rule_v109",
    "set_business_sector_policy_override_v109",
    "service_claim_growth_deliveries_v110",
    "service_complete_growth_delivery_v110",
    "cancel_growth_delivery_v110",
    "retry_growth_delivery_v110",
  ]) {
    const start = canonical.indexOf(
      `create or replace function public.${operation}(`,
    );
    assert.notEqual(start, -1, `${operation} wrapper is missing`);
    const end = canonical.indexOf("end $$;", start);
    const body = canonical.slice(start, end);
    assert.match(body, /perform app\.v112_lock_pair\(/);
    assert.match(body, /app\.v112_get_receipt|concurrent_operation_receipts_v112/);
  }

  const transitionStart = canonical.indexOf(
    "create or replace function app.v110_transition_delivery(",
  );
  const transitionEnd = canonical.indexOf("end $$;", transitionStart);
  const transition = canonical.slice(transitionStart, transitionEnd);
  assert.match(transition, /perform app\.v112_lock_pair\(/);
  assert.match(transition, /app\.v112_get_receipt/);
});

test("v112 checks current authority and scope before authenticated receipt replay", () => {
  const requiredPrechecks = new Map([
    [
      "ingest_external_commerce_event_v106",
      [
        "app.has_perm(p_business, 'create_sales')",
        "app.can_see_branch(p_business, p_branch)",
      ],
    ],
    [
      "cancel_growth_delivery_v110",
      [
        "app.is_salon_owner(p_business)",
        "app.can_module_write(p_business, 'retention')",
        "app.can_see_branch(p_business, v_dispatch_branch)",
      ],
    ],
    [
      "dismiss_growth_recommendation_v108",
      [
        "app.is_salon_owner(p_business)",
        "app.can_see_branch(p_business, v_branch)",
      ],
    ],
    [
      "approve_growth_recommendation_v108",
      [
        "app.is_salon_owner(p_business)",
        "app.can_module_read(p_business, 'retention')",
        "app.can_see_branch(p_business, v_branch)",
      ],
    ],
    [
      "finalize_growth_execution_v108",
      [
        "app.is_salon_owner(p_business)",
        "app.has_perm(p_business, 'view_finance')",
        "app.can_module_read(p_business, 'retention')",
        "app.can_see_branch(p_business, v_branch)",
      ],
    ],
    [
      "set_effective_cost_rule_v109",
      [
        "app.v109_require_feature()",
        "app.v109_require_finance_scope(p_business, p_branch)",
      ],
    ],
    [
      "set_business_sector_policy_override_v109",
      [
        "app.v109_require_feature()",
        "app.is_salon_owner(p_business)",
        "app.can_see_branch(p_business, null)",
      ],
    ],
    [
      "retry_growth_delivery_v110",
      [
        "app.is_salon_owner(p_business)",
        "app.can_module_write(p_business, 'retention')",
        "app.can_see_branch(p_business, v_dispatch_branch)",
      ],
    ],
  ]);

  for (const [operation, markers] of requiredPrechecks) {
    const start = canonical.indexOf(
      `create or replace function public.${operation}(`,
    );
    const end = canonical.indexOf("end $$;", start);
    const body = canonical.slice(start, end);
    const receiptLookup = Math.max(
      body.indexOf("app.v112_get_receipt"),
      body.indexOf("from public.concurrent_operation_receipts_v112"),
    );
    assert.notEqual(receiptLookup, -1, `${operation} receipt lookup is missing`);
    for (const marker of markers) {
      const position = body.indexOf(marker);
      assert.notEqual(position, -1, `${operation} is missing ${marker}`);
      assert.ok(
        position < receiptLookup,
        `${operation} must check ${marker} before receipt lookup`,
      );
    }
  }
});

test("v112 service claim has an immutable exact-batch receipt boundary", () => {
  const start = canonical.indexOf(
    "create or replace function public.service_claim_growth_deliveries_v110(",
  );
  const end = canonical.indexOf("end $$;", start);
  const body = canonical.slice(start, end);
  const roleCheck = body.indexOf("service role required");
  const receiptLookup = body.indexOf("app.v112_get_receipt");
  const innerCall = body.indexOf(
    "public.service_claim_growth_deliveries_v110_v112_inner(",
  );
  const receiptWrite = body.indexOf("app.v112_put_receipt");

  assert.match(body, /'idempotency_key', p_idempotency_key/);
  assert.match(body, /'limit', p_limit,\s*'worker_id', p_worker_id/);
  assert.match(body, /v112-v110-claim-request/);
  assert.ok(roleCheck >= 0 && roleCheck < receiptLookup);
  assert.ok(receiptLookup >= 0 && receiptLookup < innerCall);
  assert.ok(innerCall >= 0 && innerCall < receiptWrite);
  assert.match(
    canonical,
    /revoke all on function public\.service_claim_growth_deliveries_v110\([\s\S]*?\) from public, anon, authenticated/,
  );
  assert.match(
    canonical,
    /grant execute on function public\.service_claim_growth_deliveries_v110\([\s\S]*?\) to service_role/,
  );
});

test("v112 replays the immutable first response without response mutation", () => {
  assert.doesNotMatch(
    canonical,
    /return\s+v_receipt\s*\|\|/i,
  );
  assert.doesNotMatch(
    canonical,
    /v_receipt\s*\|\|\s*jsonb_build_object\(\s*'replayed'/i,
  );
  assert.match(
    canonical,
    /if v_existing_hash = v_hash then\s+return v_receipt;/,
  );
});

test("v106 locks both source identity and idempotency identity", () => {
  assert.match(canonical, /v112-v106-source/);
  assert.match(canonical, /v112-v106-idempotency/);
  assert.match(
    canonical,
    /Let the canonical source identity decide this conflict[\s\S]*quarantined by v106/,
  );
});

test("v112 retry policy is versioned, deterministic, auditable, and bounded", () => {
  assert.match(
    canonical,
    /create table public\.growth_delivery_backoff_policies_v112/,
  );
  assert.match(
    canonical,
    /array\[60, 300, 900, 3600\]::integer\[\]/,
  );
  assert.match(canonical, /v112_backoff/);
  assert.match(canonical, /'policy_version'/);
  assert.match(canonical, /'completed_attempts'/);
  assert.match(canonical, /'delay_seconds'/);
  assert.match(canonical, /'next_attempt_at'/);
  assert.match(
    canonical,
    /growth_delivery_dispatches_v112_retry_bound_check[\s\S]*attempt_count < 5/,
  );
  assert.doesNotMatch(canonical, /\brandom\s*\(/i);
});

test("v110 claim remains due-time gated", () => {
  assert.match(
    v110,
    /dispatch\.next_attempt_at <= statement_timestamp\(\)/,
  );
});

test("v112 delivery mutations share dispatch-advisory then row lock order", () => {
  assert.match(
    canonical,
    /create or replace function app\.v112_lock_dispatch\([\s\S]*?hashtextextended\('v112-v110-dispatch:' \|\| p_dispatch::text, 112\)/,
  );

  for (const operation of [
    "app.v110_transition_delivery",
    "public.service_complete_growth_delivery_v110",
    "public.cancel_growth_delivery_v110",
    "public.retry_growth_delivery_v110",
  ]) {
    const start = canonical.indexOf(`create or replace function ${operation}(`);
    assert.notEqual(start, -1, `${operation} is missing`);
    const end = canonical.indexOf("end $$;", start);
    const body = canonical.slice(start, end);
    const dispatchLock = body.indexOf("app.v112_lock_dispatch(p_dispatch)");
    const receiptLookup = body.indexOf("app.v112_get_receipt");
    const innerCall = body.indexOf("_v112_inner(");
    assert.ok(dispatchLock >= 0, `${operation} lacks the dispatch advisory`);
    assert.ok(
      receiptLookup < 0 || dispatchLock < receiptLookup,
      `${operation} must lock dispatch before receipt replay`,
    );
    assert.ok(
      innerCall < 0 || dispatchLock < innerCall,
      `${operation} must lock dispatch before entering its row-locking inner`,
    );
  }

  for (const operation of [
    "app.v110_transition_delivery_v112_inner",
    "public.service_complete_growth_delivery_v110_v112_inner",
    "public.cancel_growth_delivery_v110_v112_inner",
    "public.retry_growth_delivery_v110_v112_inner",
  ]) {
    const start = canonical.indexOf(`create or replace function ${operation}(`);
    assert.notEqual(start, -1, `${operation} safe inner is missing`);
    const end = canonical.indexOf("end $$;", start);
    const body = canonical.slice(start, end);
    assert.ok(
      body.indexOf("app.v112_lock_dispatch(p_dispatch)") <
        body.indexOf("_v112_unsafe_row_inner("),
      `${operation} must acquire dispatch advisory before unsafe row inner`,
    );
  }

  const claimStart = canonical.indexOf(
    "create or replace function public.service_claim_growth_deliveries_v110_v112_inner(",
  );
  const claimEnd = canonical.indexOf("end $$;", claimStart);
  const claim = canonical.slice(claimStart, claimEnd);
  const executionLock = claim.indexOf(
    "hashtextextended('v110-dispatch:' || v_candidate.execution_id::text, 0)",
  );
  const dispatchLock = claim.indexOf(
    "app.v112_lock_dispatch(v_candidate.id)",
  );
  const rowLock = claim.indexOf("for update;");
  assert.ok(executionLock >= 0 && executionLock < dispatchLock);
  assert.ok(dispatchLock >= 0 && dispatchLock < rowLock);
  assert.doesNotMatch(claim, /for update skip locked/i);
});

test("v112 cancel preserves authority, exact replay, and fail-closed grants", () => {
  const start = canonical.indexOf(
    "create or replace function public.cancel_growth_delivery_v110(",
  );
  const end = canonical.indexOf("end $$;", start);
  const body = canonical.slice(start, end);
  const receiptLookup = body.indexOf("app.v112_get_receipt");
  for (const marker of [
    "app.is_salon_owner(p_business)",
    "app.can_module_write(p_business, 'retention')",
    "where d.id = p_dispatch and d.business_id = p_business",
    "app.can_see_branch(p_business, v_dispatch_branch)",
    "cancellation reason and idempotency are required",
  ]) {
    const position = body.indexOf(marker);
    assert.ok(position >= 0 && position < receiptLookup, marker);
  }
  assert.match(body, /'reason', btrim\(p_reason\)/);
  assert.match(body, /app\.v112_put_receipt\(/);
  assert.match(
    canonical,
    /revoke all on function public\.cancel_growth_delivery_v110\(\s*uuid,uuid,text,uuid\s*\) from public, anon/,
  );
  assert.match(
    canonical,
    /grant execute on function[\s\S]*public\.cancel_growth_delivery_v110\(uuid,uuid,text,uuid\)[\s\S]*to authenticated/,
  );
});

test("v112 successful callback records late delivery without minting entitlement", () => {
  const start = canonical.indexOf(
    "create or replace function public.service_complete_growth_delivery_v110_v112_inner(",
  );
  const end = canonical.indexOf("end $$;", start);
  const body = canonical.slice(start, end);
  const dispatchLock = body.indexOf("app.v112_lock_dispatch(p_dispatch)");
  const rowLock = body.indexOf("where id = p_dispatch for update");
  assert.ok(dispatchLock >= 0 && dispatchLock < rowLock);
  for (const marker of [
    "app.platform_feature_enabled('growth_closed_loop_v108')",
    "'retention' = any",
    "v_execution.status <> 'running'",
    "v_execution.ends_at <= v_now",
    "branch.active",
    "link.state = 'verified'",
    "preference.opted_in",
  ]) {
    assert.ok(body.includes(marker), `late callback is missing ${marker}`);
  }
  assert.match(
    body,
    /p_dispatch, 'delivered', v_suppression_reason,[\s\S]*?'entitlement_suppressed', true/,
  );
  assert.match(body, /'entitlement_id', null/);
  assert.match(body, /'suppression_reason', v_suppression_reason/);
  assert.ok(
    body.indexOf("if v_suppression_reason is not null") <
      body.indexOf(
        "service_complete_growth_delivery_v110_v112_unsafe_row_inner",
      ),
  );
});

test("v112 receipt and policy data are append-only and not directly mutable", () => {
  assert.match(
    canonical,
    /concurrent_operation_receipts_v112_immutable/,
  );
  assert.match(
    canonical,
    /growth_delivery_backoff_policies_v112_immutable/,
  );
  assert.match(
    canonical,
    /revoke all on table[\s\S]*concurrent_operation_receipts_v112[\s\S]*from public, anon, authenticated/,
  );
  assert.doesNotMatch(
    canonical,
    /grant\s+(insert|update|delete)[\s\S]*concurrent_operation_receipts_v112/i,
  );
});

test("owner delivery status projects delivered-without-entitlement truth", () => {
  assert.match(
    canonical,
    /create or replace function public\.get_growth_delivery_status_v110\(/,
  );
  assert.match(
    canonical,
    /'entitlement_status'[\s\S]*?'entitlement_suppressed'[\s\S]*?'suppression_reason'/,
  );
  assert.match(
    canonical,
    /latest_event\.detail ->> 'entitlement_suppressed' = 'true'/,
  );
  assert.match(
    canonical,
    /left join public\.growth_entitlements_v108 entitlement[\s\S]*left join lateral/,
  );
  assert.doesNotMatch(
    canonical.match(
      /create or replace function public\.get_growth_delivery_status_v110\([\s\S]*?end \$\$;/,
    )?.[0] ?? "",
    /provider_message_id/,
  );
});

test("v112 preserves fail-closed public and service grants", () => {
  assert.match(
    canonical,
    /grant execute on function public\.ingest_external_commerce_event_v106\([\s\S]*\) to authenticated/,
  );
  assert.match(
    canonical,
    /revoke all on function public\.service_complete_growth_delivery_v110\([\s\S]*\) from public, anon, authenticated/,
  );
  assert.match(
    canonical,
    /revoke all on function public\.service_claim_growth_deliveries_v110\([\s\S]*\) from public, anon, authenticated/,
  );
  assert.match(
    canonical,
    /grant execute on function public\.service_claim_growth_deliveries_v110\([\s\S]*\) to service_role/,
  );
  assert.match(
    canonical,
    /grant execute on function public\.service_complete_growth_delivery_v110\([\s\S]*\) to service_role/,
  );
  assert.match(
    canonical,
    /public\.cancel_growth_delivery_v110\(uuid,uuid,text,uuid\)[\s\S]*to authenticated/,
  );
});
