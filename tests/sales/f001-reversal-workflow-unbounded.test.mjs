/* Audit F001 — the Sales page asked staff_get_reversal_workflows for
   Math.max(100, sl.length) rows. The server (public.staff_get_reversal_workflows, last
   definition db/migrations/20260828_nestly_v573_module_off_reaches_the_rpcs.sql, prod-confirmed
   via pg_get_functiondef) clamps ANY non-zero p_limit to 100 and applies no date/staff/type/
   branch predicate — so the call was never more than the 100 newest sales in the whole
   business, no matter how large the filtered ledger was. Once a business passes 100 lifetime
   sales, older painted rows silently lost Reverse/Amend and painted the wrong status/Net.

   Fix: pass 0 — the RPC's explicit "unbounded" value, already used by Customer 360 — so W
   covers every painted row regardless of ledger size, and surface may_have_more instead of
   silently trusting an empty {}. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const section = (source, from, to) => {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
};

test('F001: loadRecent asks the reversal-workflow RPC for an UNBOUNDED window, not a value the server clamps to 100', () => {
  const loadRecent = section(app, 'async function loadRecent(){', 'function renderSalesRowsV291(){');
  // The old defect: `Math.max(100,(sl||[]).length)` — every value is >=100 and the server
  // clamps any non-zero p_limit to 100, so this line could never cover a ledger past 100 rows.
  assert.doesNotMatch(loadRecent, /loadReversalWorkflows\(null,\s*Math\.max\(100/,
    'must not regress to a call the server always clamps to 100 rows');
  assert.match(loadRecent, /loadReversalWorkflows\(null,\s*0\)/,
    'must pass the RPC\'s explicit unbounded value (0), the same one Customer 360 uses');

  // Execute the actual call-site expression (not a re-implementation of it) with a vm, for a
  // few different ledger sizes, and assert the limit sent to the RPC is unconditionally 0 —
  // proving the fix is not merely textual but holds for any ledger size, including one well
  // past the old 100-row cap.
  const callMatch = loadRecent.match(/const workflow=await loadReversalWorkflows\(null,([^)]*)\)\.catch/);
  assert.ok(callMatch, 'could not locate the loadReversalWorkflows call expression');
  const limitExpr = callMatch[1];
  for (const n of [0, 1, 100, 101, 5000]) {
    const sentLimit = vm.runInNewContext(limitExpr, {sl: new Array(n).fill({})});
    assert.equal(sentLimit, 0, `ledger of ${n} rows must still request the unbounded window`);
  }
});

test('F001: a may_have_more RPC flag is captured and surfaced, not silently discarded', () => {
  const loadRecent = section(app, 'async function loadRecent(){', 'function renderSalesRowsV291(){');
  assert.match(loadRecent, /salesWorkflowMayHaveMoreV291=!!workflow\?\.may_have_more/,
    'the RPC\'s own may_have_more guard must be read, not ignored the way it was before');
  assert.match(loadRecent, /salesWorkflowMayHaveMoreV291\?/,
    'the filter-summary line must change when the workflow data could be incomplete');
});

test('F001: saleRecordStatusV154 (the render logic the fix protects) correctly reports Reversed when W is populated, vs the wrong-status defect when W is empty', () => {
  // Extract the real, unmodified status function (start-anchored on its own declaration, end-
  // anchored on the very next top-level function so the slice is a complete, directly runnable
  // function declaration) and execute it in a vm — not a re-implementation of its logic.
  const statusFn = section(app, 'function saleRecordStatusV154(s,w={}){', 'async function salesPage(){');
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(statusFn, ctx);
  assert.equal(typeof ctx.saleRecordStatusV154, 'function');
  const reversedOriginal = {reversal_of: null, corrected_by: null};
  const withWorkflow = ctx.saleRecordStatusV154(reversedOriginal, {reversal_sale_id: 'REV-1'});
  assert.equal(withWorkflow.label, 'Reversed');
  const withoutWorkflow = ctx.saleRecordStatusV154(reversedOriginal, {});
  assert.equal(withoutWorkflow.label, 'Sale',
    'sanity check: this is exactly the wrong-status defect an empty W (the pre-fix outcome for rows past the old 100-row cap) produces — it is why the fix must make W cover every painted row');
});
