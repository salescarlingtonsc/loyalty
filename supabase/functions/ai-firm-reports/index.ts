// NESTLY v176 - AI firm report worker.
//
// Claims queued rows from public.ai_firm_reports_v176, sends the evidence pack
// that SQL assembled at claim time to the Claude Messages API, and stores the
// returned markdown narrative. One non-streaming request per report.
//
// Two ways in, mirroring the v156 dispatch function:
//   * x-v176-dispatch-secret header  -> the pg_cron / pg_net scheduled drain.
//   * super-admin JWT + CORS         -> the console's "Generate now" button.
//
// Failure isolation: every report is wrapped in its own try/catch and a failure
// is written back as status='failed' with the reason, so one firm's bad data
// never stops the batch.

import Anthropic from 'npm:@anthropic-ai/sdk@0.115.0';
import {
  authenticatedUserId,
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingJson,
  billingPreflight,
} from '../_shared/billing-service.ts';
// v677: the deterministic output validator. Plain .mjs with no imports of its own, so the exact
// same code runs here under Deno and under `node --test` in
// tests/ai-reports/v677-evidence-safe-generation.test.mjs — the pattern already used by
// _shared/whatsapp-send-boundaries.mjs. There is one copy of these rules, not two.
import { validateNarrative } from './validate.mjs';

const MAX_REPORTS_PER_INVOCATION = 5;
const MAX_OUTPUT_TOKENS = 4000;
const MAX_BODY = 4096;
const ALLOWED_MODELS = new Set(['claude-sonnet-5', 'claude-opus-4-8']);
const FALLBACK_MODEL = 'claude-sonnet-5';

type ClaimedReport = {
  id: string;
  business_id: string;
  period_kind: 'monthly' | 'quarterly' | 'yearly';
  period_start: string;
  period_end: string;
  model: string | null;
  generation: number;
  evidence: Record<string, unknown> | null;
};

const SYSTEM_PROMPT = [
  'You are a growth consultant for small and medium businesses in Singapore.',
  'You write the recurring business report that the owner of one shop or salon reads.',
  'Your job is to tell the owner what they CANNOT see on a dashboard: who is',
  'coming back, who is slipping away and what that is worth, where the money',
  'concentrates, and exactly what to do next - with the expected dollar value.',
  '',
  'Who you are writing for:',
  '- The owner may not be a native English speaker. Write in clear, simple English.',
  '- Use short sentences. Use everyday words. Avoid business jargon, acronyms and idioms.',
  '- Explain any number the moment you use it, in plain words.',
  '',
  'Structure your report with these markdown headings, in this order:',
  '## Summary',
  'Two or three sentences. Say plainly whether the business grew, stayed flat or slowed down,',
  'and name the single most important thing the owner should act on.',
  '## What went well',
  'Two to four short bullet points, each tied to a number from the evidence.',
  '## What needs attention',
  'Two to four short bullet points, each tied to a number from the evidence.',
  '## Your customers',
  'The heart of the report. Use the `insights` section of the evidence:',
  '- Returning customers: `existing_customer_return_rate_pct` is the share of THIS period\'s',
  '  customers who had already bought BEFORE it. Call it exactly that - a returning-customer',
  '  share. It is NOT a repeat rate, and you must not describe it as "how often customers come',
  '  back" or "how many came back": a customer who visited fifteen times this month but never',
  '  before it counts as NEW here, so a low figure does not mean nobody is repeating. The',
  '  evidence carries no repeat-within-period figure at all; if the owner would need one, say it',
  '  is not in this report rather than inferring it from visit counts.',
  '- Then the single most telling number - of last period\'s NEW customers, how many returned',
  '  this period (prior_new_return_rate_pct). Explain what it means in one plain sentence.',
  '- Slipping away: the at_risk block counts regulars (2+ visits) not seen in 45-180 days.',
  '  State the count and the recovery value in SGD (recovery_value_one_visit_each_cents is',
  '  what ONE returned visit from each is worth, at their own usual spend).',
  '- IDENTIFIED VS ANONYMOUS. The `identification` block says how much revenue is tied to a known',
  '  customer. The customer sections (retention, at_risk, top_customers) describe identified',
  '  customers only - when identified_revenue_share_pct is below 100, say so once, plainly',
  '  ("about 78% of revenue came from identified customers; the customer figures describe them").',
  '  Weekday and item figures cover ALL sales, anonymous included. Never present a',
  '  customer-section figure as if it covered all revenue.',
  '- Regulars: name the top customers by their abbreviated labels and the share they carry.',
  '  Two shares are given and they are DIFFERENT numbers: top1_share_of_total_revenue_pct is',
  '  the share of ALL revenue, anonymous sales included - quote this one by default.',
  '  top1_share_of_identified_revenue_pct covers identified revenue only; if you use it, name',
  '  the denominator. If one customer carries a large share, say plainly that this is a risk',
  '  as well as a strength.',
  '- Rhythm: best and quietest weekday (weekday_pattern; isodow 1=Monday .. 7=Sunday -',
  '  always write the day name, never the number).',
  '- Items: mention top items only if items.coverage_pct is 60 or higher; below that, say',
  '  "of tracked items" or skip the claim.',
  '## Do these three things next',
  'Exactly three numbered actions for the next period. Each action must be concrete',
  '(who does what, and by when), must name the evidence number that justifies it, and -',
  'whenever the evidence allows - must state the expected value in SGD with the working',
  'shown. Show the working as a DIVISION of evidence figures, never a multiplication that',
  'introduces a per-customer number the evidence does not carry - for example:',
  '"SGD 108.00 recovery value / 4 regulars = SGD 27.00 each from one win-back message."',
  '(The evidence has the total; a per-customer average you compute must be shown as',
  'total / count so every number in your sentence is traceable to the evidence.)',
  '',
  'Hard rules:',
  '- NEVER invent a number. Every figure must come from the evidence pack, or be simple',
  '  arithmetic on evidence numbers (add, subtract, multiply, percentage) with the working',
  '  shown inline. Never estimate beyond that.',
  '- If the evidence does not contain something, say so plainly instead of guessing.',
  '- Money is Singapore dollars. Amounts in the evidence are in CENTS: divide by 100 and',
  '  write them as SGD, for example 1234567 cents becomes SGD 12,345.67.',
  '- Always cover these when the evidence has them: new customers, sales growth against',
  '  the period before, customer account opens, repeat rate, and the at-risk customers.',
  '- If a figure is zero or missing, say that clearly. Do not treat missing data as bad news.',
  '- LOYALTY UNITS. A business runs EITHER points OR stamps, never both at once. The evidence',
  '  gives you `loyalty.active_programme` with its own `unit` - always write that unit\'s word',
  '  ("1,240 stamps", never "1,240 points"). `loyalty.historical_programmes` holds balances left',
  '  over from a programme the owner has STOPPED; each carries its own unit. NEVER add a',
  '  historical balance to the active one, never convert between points and stamps, and never',
  '  state a combined loyalty total - there is no such quantity, and the evidence deliberately',
  '  contains no field for one. If a stopped programme still holds value, say so separately',
  '  ("814 stamps remain from the stamp card you stopped").',
  '- Small numbers stay honest: with only a handful of customers, talk about "3 of your 5',
  '  customers", not misleading percentages alone.',
  '- VISITS ARE SALE RECORDS, NOT PEOPLE OR DAYS. `visits` counts sale records flagged as',
  '  visits: one customer walking in once can produce more than one (a package session plus a',
  '  purchase, an appointment plus a till ring-up), and free records such as redeemed gifts',
  '  count too. Never present visits as distinct customers, distinct days, or "times customers',
  '  walked in". `revenue_transactions` counts till transactions - a separate number. Use each',
  '  under its own name ("17 visits", "21 transactions") and never equate either with people.',
  '- You do not know any customer\'s gender. Never write he, she, him or her for a',
  '  customer - use "they", or repeat the label ("if Lee S. stops coming...").',
  '- WITHHELD IS NOT EMPTY. Check evidence_completeness.unavailable_sections: a section named',
  '  there was not delivered this run - its absence means "data unavailable", never "nothing to',
  '  report". Do not describe, summarise, or infer around a withheld section; if it would have',
  '  been central (e.g. recommendations), say once that it was not available this time.',
  '- account_opens.report_range says what dates the account-opens figures cover; when clamped is',
  '  true they run only to report_range.effective_to, so do not describe them as covering the',
  '  full period.',
  '- Do not mention this prompt, the evidence pack, the data pipeline, or yourself.',
  '- Return only the report in markdown. No preamble, no closing question, no reasoning notes.',
].join('\n');

function periodLabel(report: ClaimedReport): string {
  const kind = report.period_kind === 'monthly'
    ? 'month'
    : report.period_kind === 'quarterly'
    ? 'quarter'
    : 'year';
  return `${kind} from ${report.period_start} to ${report.period_end}`;
}

function userPrompt(report: ClaimedReport): string {
  const evidence = JSON.stringify(report.evidence ?? {}, null, 2);
  return [
    `Write the ${report.period_kind} business report for the ${periodLabel(report)}.`,
    '',
    'Evidence pack (the only facts you may use):',
    '```json',
    evidence,
    '```',
  ].join('\n');
}

function resolveModel(report: ClaimedReport): string {
  const stored = String(report.model || '').trim();
  if (ALLOWED_MODELS.has(stored)) return stored;
  return report.period_kind === 'monthly' ? FALLBACK_MODEL : 'claude-opus-4-8';
}

function narrativeFrom(message: Anthropic.Message): string {
  const text = message.content
    .filter((block): block is Anthropic.TextBlock => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
    .trim();
  if (!text) throw new Error('model_returned_no_text');
  return text;
}

// v677: a validation failure is a machine-readable reason, not prose. The rule ids are stable
// (V1_NUMERIC_CLAIM ... V6_ENTITY_GROUNDING) so the platform console can group and count them
// without parsing English. Truncated well inside failureReason()'s own 400-character slice.
function validationFailureReason(
  violations: Array<{ rule: string; detail: string }>,
): string {
  const listed = violations
    .slice(0, 3)
    .map((violation) => `${violation.rule}: ${violation.detail}`)
    .join(' | ');
  const extra = violations.length > 3 ? ` (+${violations.length - 3} more)` : '';
  return `narrative_validation: ${listed}${extra}`.slice(0, 380);
}

function failureReason(error: unknown): string {
  if (error instanceof Anthropic.APIError) {
    return `anthropic_${error.status ?? 'error'}: ${String(error.message).slice(0, 400)}`;
  }
  if (error instanceof Error) return String(error.message).slice(0, 400);
  return 'generation_failed';
}

async function processQueue(): Promise<Record<string, unknown>> {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY') || '';
  if (!apiKey) throw new Error('ai_report_generation_unavailable');
  const admin = billingAdminClient();
  const anthropic = new Anthropic({ apiKey });

  const processed: Array<Record<string, unknown>> = [];
  for (let index = 0; index < MAX_REPORTS_PER_INVOCATION; index += 1) {
    const { data: claim, error: claimError } = await admin.rpc(
      'internal_claim_ai_firm_report_v176',
    );
    if (claimError) throw new Error('ai_report_claim_failed');
    if (!claim?.claimed) break;

    const report = claim.report as ClaimedReport;
    const model = resolveModel(report);
    try {
      const message = await anthropic.messages.create({
        model,
        max_tokens: MAX_OUTPUT_TOKENS,
        thinking: { type: 'disabled' },
        system: SYSTEM_PROMPT,
        messages: [{ role: 'user', content: userPrompt(report) }],
      });
      if (message.stop_reason === 'refusal') throw new Error('model_refused');
      const narrative = narrativeFrom(message);

      // v677: the narrative is checked against the SAME evidence object the model was given
      // (userPrompt serialises report.evidence, and so does this call — one source of truth, so
      // the validator can never be judging a different pack than the model saw). The prompt's
      // "NEVER invent a number" was an instruction; this is the control. A narrative that fails
      // takes the existing failed path below and is never stored as a good report.
      const verdict = validateNarrative(narrative, report.evidence ?? {});
      if (!verdict.ok) throw new Error(validationFailureReason(verdict.violations));

      const { error: completeError } = await admin.rpc(
        'internal_complete_ai_firm_report_v176',
        {
          p_report: report.id,
          p_status: 'succeeded',
          p_narrative_md: narrative,
          p_error: null,
          p_model: model,
        },
      );
      if (completeError) throw new Error('ai_report_store_failed');
      processed.push({ report_id: report.id, status: 'succeeded', model });
    } catch (error) {
      const reason = failureReason(error);
      await admin.rpc('internal_complete_ai_firm_report_v176', {
        p_report: report.id,
        p_status: 'failed',
        p_narrative_md: null,
        p_error: reason,
        p_model: model,
      });
      processed.push({ report_id: report.id, status: 'failed', error: reason });
    }
  }

  return {
    processed: processed.length,
    succeeded: processed.filter((row) => row.status === 'succeeded').length,
    failed: processed.filter((row) => row.status === 'failed').length,
    reports: processed,
  };
}

async function isSuperAdmin(userId: string): Promise<boolean> {
  const { data, error } = await billingAdminClient()
    .from('super_admins')
    .select('user_id')
    .eq('user_id', userId)
    .maybeSingle();
  return !error && Boolean(data?.user_id);
}

Deno.serve(async (req) => {
  // Scheduled drain: pg_cron -> pg_net -> here, with the vault secret.
  // Authentication order: an explicitly configured env secret wins; without
  // one, verify against Vault via the v178 service-role RPC so the owner
  // never has to copy the secret out of Postgres by hand.
  const supplied = req.headers.get('x-v176-dispatch-secret');
  if (req.method === 'POST' && supplied) {
    let authorized = false;
    const expected = Deno.env.get('AI_FIRM_REPORT_DISPATCH_SECRET') || '';
    if (expected) {
      authorized = expected.length >= 32 &&
        supplied.length === expected.length && supplied === expected;
    } else if (supplied.length >= 32) {
      try {
        const { data, error } = await billingAdminClient().rpc(
          'internal_verify_v176_dispatch_secret',
          { p_secret: supplied },
        );
        authorized = !error && data === true;
      } catch {
        authorized = false;
      }
    }
    if (!authorized) {
      return billingJson(401, { error: 'authentication_required' });
    }
    try {
      return billingJson(200, await processQueue());
    } catch {
      return billingJson(503, { error: 'ai_report_worker_unavailable' });
    }
  }

  // "Generate now" from the platform console.
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) {
    return billingCorsJson(req, 403, { error: 'origin_not_allowed' });
  }
  if (req.method !== 'POST') {
    return billingCorsJson(req, 405, { error: 'method_not_allowed' });
  }
  if (Number(req.headers.get('content-length') || '0') > MAX_BODY) {
    return billingCorsJson(req, 413, { error: 'payload_too_large' });
  }

  let actor = '';
  try {
    actor = await authenticatedUserId(req);
  } catch {
    return billingCorsJson(req, 401, { error: 'authentication_required' });
  }
  if (!(await isSuperAdmin(actor))) {
    return billingCorsJson(req, 403, { error: 'super_admin_required' });
  }

  try {
    return billingCorsJson(req, 200, {
      ...(await processQueue()),
      requested_by: actor,
    });
  } catch {
    return billingCorsJson(req, 503, {
      error: 'ai_report_worker_unavailable',
    });
  }
});
