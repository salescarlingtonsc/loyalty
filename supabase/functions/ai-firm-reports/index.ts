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
  '',
  'Who you are writing for:',
  '- The owner may not be a native English speaker. Write in clear, simple English.',
  '- Use short sentences. Use everyday words. Avoid business jargon, acronyms and idioms.',
  '- Explain any number the moment you use it, in plain words.',
  '',
  'Structure your report with these markdown headings, in this order:',
  '## Summary',
  'Two or three sentences. Say plainly whether the business grew, stayed flat or slowed down.',
  '## What went well',
  'Two to four short bullet points, each tied to a number from the evidence.',
  '## What needs attention',
  'Two to four short bullet points, each tied to a number from the evidence.',
  '## Do these three things next',
  'Exactly three numbered actions for the next period. Each action must be concrete',
  '(who does what, and by when), and must name the evidence number that justifies it.',
  '',
  'Hard rules:',
  '- NEVER invent a number. Every figure you write must come from the evidence pack.',
  '- If the evidence does not contain something, say so plainly instead of guessing.',
  '- Money is Singapore dollars. Amounts in the evidence are in CENTS: divide by 100 and',
  '  write them as SGD, for example 1234567 cents becomes SGD 12,345.67.',
  '- Always cover these three things when the evidence has them: new customers,',
  '  sales growth against the period before, and customer account opens.',
  '- If a figure is zero or missing, say that clearly. Do not treat missing data as bad news.',
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
      const { error: completeError } = await admin.rpc(
        'internal_complete_ai_firm_report_v176',
        {
          p_report: report.id,
          p_status: 'succeeded',
          p_narrative_md: narrativeFrom(message),
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
  const supplied = req.headers.get('x-v176-dispatch-secret');
  if (req.method === 'POST' && supplied) {
    const expected = Deno.env.get('AI_FIRM_REPORT_DISPATCH_SECRET') || '';
    if (
      !expected || expected.length < 32 ||
      supplied.length !== expected.length || supplied !== expected
    ) {
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
