// nestly (check 81/90 enforcement requirement) — the PASS/FAIL DECISION that index.ts's
// processQueue makes after generating a narrative, extracted so it can be executed by a Node test
// instead of only ever being exercised inside a live Deno edge function invocation.
//
// WHY THIS EXISTS. validate.mjs (./validate.mjs) is already dual-runtime and already has an
// executing test suite — but the piece of index.ts that turns a validateNarrative() verdict into
// what actually gets STORED (a succeeded report with its narrative, or a failed report with a
// reason and no narrative) lived only inline in processQueue(), a Deno-only function this repo's
// Node test runner cannot import (npm: specifiers, Deno.serve, Deno.env - none of it resolves
// under `node --test`). That inline decision was therefore never executed by any test at all,
// source-regex or otherwise: `if (!verdict.ok) throw new Error(...)` was proven correct by eye,
// not by execution. This file is the same fix v677 already applied to the validator itself,
// applied one layer up, to the DECISION built on top of it.
//
// CONTRACT. One entry point, pure and synchronous, no imports of its own besides validate.mjs (the
// SAME dual-runtime pattern validate.mjs's own header describes, and the pattern
// _shared/whatsapp-send-boundaries.mjs already established): a plain .mjs file with no npm:/Deno
// specifics, so the exact same code runs here under Deno (imported by ./index.ts as
// './enforce.mjs') and under Node (`node --test tests/ai-reports/*.test.mjs`).
//
//   decideNarrativeOutcome(narrativeMd, evidencePack, opts) ->
//     { status: 'ready' | 'failed', narrative_md: string | null, failure_reason: string | null,
//       violations: Array<{rule, detail}> }
//
// BEHAVIOUR, kept byte-identical to what index.ts did inline before this extraction:
//   - validateNarrative(...).ok === true  -> status 'ready', narrative_md is the narrative
//     unchanged, failure_reason null, violations [].
//   - validateNarrative(...).ok === false -> status 'failed', narrative_md null, failure_reason is
//     the SAME truncated, rule-id-prefixed string validationFailureReason() always produced (moved
//     here verbatim, not reworded), violations is the validator's own array so a caller that wants
//     the untruncated detail still has it.
// index.ts's processQueue() used to do `if (!verdict.ok) throw new Error(validationFailureReason(
// verdict.violations))`, which the caller's own catch block turned into status:'failed',
// narrative_md: null, error: reason via internal_complete_ai_firm_report_v176. That RPC call still
// lives in index.ts (this file has no Supabase client and must not gain one) - this file only
// decides WHAT the outcome is, not how it gets persisted.
import { validateNarrative } from './validate.mjs';

// v677: the rule ids are stable (V1_NUMERIC_CLAIM ... V10B_ASSOCIATION_MARKER) so the platform
// console can group and count them without parsing English. Truncated well inside this function's
// own 400-character slice, moved here verbatim from index.ts's old validationFailureReason().
function narrativeFailureReason(violations) {
  const listed = violations
    .slice(0, 3)
    .map((violation) => `${violation.rule}: ${violation.detail}`)
    .join(' | ');
  const extra = violations.length > 3 ? ` (+${violations.length - 3} more)` : '';
  return `narrative_validation: ${listed}${extra}`.slice(0, 380);
}

/**
 * Decide whether a model-generated narrative is fit to store, by running it through the SAME
 * validateNarrative() control every other caller uses (./validate.mjs) — there is exactly one
 * validator, and this is the one place that turns its verdict into a stored-report decision.
 *
 * @param {string} narrativeMd   the markdown the model returned
 * @param {object} evidencePack  the SAME object handed to the model (report.evidence)
 * @param {object} [opts]        forwarded to validateNarrative unchanged (causalEvidence,
 *                                allowStrongClaims, confidenceClass, entityAllowlist)
 * @returns {{status: 'ready'|'failed', narrative_md: string|null, failure_reason: string|null,
 *            violations: Array<{rule: string, detail: string}>}}
 */
export function decideNarrativeOutcome(narrativeMd, evidencePack, opts = {}) {
  const verdict = validateNarrative(narrativeMd, evidencePack, opts);
  if (verdict.ok) {
    return { status: 'ready', narrative_md: narrativeMd, failure_reason: null, violations: [] };
  }
  return {
    status: 'failed',
    narrative_md: null,
    failure_reason: narrativeFailureReason(verdict.violations),
    violations: verdict.violations,
  };
}
