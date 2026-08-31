// NESTLY v199 — reads a receipt or supplier invoice and PROPOSES the bookkeeping entry.
//
// It never posts. The worker fills in what it can read (vendor, date, total, GST,
// a suggested category) and stops; a super admin confirms or corrects every figure,
// and only that confirmation posts through platform_post_receipt_expense_v199 ->
// the existing v147 expense path -> the journal. Letting an OCR write the books
// unreviewed is how bookkeeping goes quietly wrong, so the split is deliberate.
//
// MODEL CHOICE (owner asked whether Gemini Flash would be cheaper): at SME receipt
// volume the difference is cents a month, and ANTHROPIC_API_KEY is already
// configured and proven by the v176 report worker. Haiku is the cheapest Claude
// tier and easily strong enough to read a receipt. The model is a single constant
// below, so switching providers later is a contained change.

import Anthropic from 'npm:@anthropic-ai/sdk@0.115.0';
import {
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingJson,
  billingPreflight,
  authenticatedUserId,
} from '../_shared/billing-service.ts';

const MODEL = 'claude-haiku-4-5-20251001';
const MAX_RECEIPTS_PER_INVOCATION = 10;
const MAX_OUTPUT_TOKENS = 700;
const BUCKET = 'accounting-private';

// Categories must match the v147 expense contract exactly, or a confirmed post
// would be rejected at the last step.
const CATEGORIES = [
  'software', 'marketing', 'professional_services', 'banking', 'operations', 'other',
] as const;

const SYSTEM_PROMPT = [
  'You read a single receipt or supplier invoice and report only what is printed on it.',
  'The business is in Singapore; amounts are Singapore dollars unless stated otherwise.',
  '',
  'Rules:',
  '- Report only what you can actually see. Never infer, complete or invent a value.',
  '- Any field you cannot read must be null. A null is useful; a guess is harmful.',
  '- Money is integer CENTS. SGD 42.10 is 4210. Never return dollars.',
  '- total_cents is the amount actually payable, after discounts, including GST.',
  '- Do not use subtotal, amount before tax, cash tendered, change, balance carried',
  '  forward, or a line-item price as total_cents.',
  '- gst_cents is the GST/tax line only, null when the receipt does not show one.',
  '- document_date is the transaction date in YYYY-MM-DD. Singapore receipts are',
  '  usually DD/MM/YYYY, so 03/08/2026 is 2026-08-03, not 8 March.',
  '- For a supplier invoice, use the invoice date and the invoice number as the',
  '  payment_reference. Do not use a due date as the document date.',
  '- confidence is your own honest 0-1 reading of how legible this document was.',
  '  Report low confidence for a blurred, cropped or partial image.',
  `- category must be one of: ${CATEGORIES.join(', ')}. Use "other" when unsure.`,
].join('\n');

const EXTRACTION_SCHEMA = {
  name: 'receipt_extraction',
  description: 'Fields legible on the receipt. Anything unreadable is null.',
  input_schema: {
    type: 'object',
    properties: {
      vendor_name: { type: ['string', 'null'] },
      vendor_registration_number: { type: ['string', 'null'], description: 'UEN/GST no. if printed' },
      document_date: { type: ['string', 'null'], description: 'YYYY-MM-DD' },
      total_cents: { type: ['integer', 'null'] },
      gst_cents: { type: ['integer', 'null'] },
      currency: { type: ['string', 'null'] },
      payment_reference: { type: ['string', 'null'], description: 'card tail, invoice or receipt no.' },
      description: { type: ['string', 'null'], description: 'what was bought, one short line' },
      category: { type: ['string', 'null'], enum: [...CATEGORIES, null] },
      confidence: { type: 'number' },
    },
    required: ['confidence'],
    additionalProperties: false,
  },
} as const;

function imageMediaType(mime: string): string {
  // Claude accepts these image types; anything else is refused before the call.
  return ['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(mime) ? mime : '';
}

function sourceBlock(mime: string, data: string): Record<string, unknown> | null {
  const imageType = imageMediaType(mime);
  if (imageType) return { type: 'image', source: { type: 'base64', media_type: imageType, data } };
  if (mime === 'application/pdf') {
    return { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data } };
  }
  return null;
}

function normalizeExtraction(input: unknown): Record<string, unknown> {
  const raw = input && typeof input === 'object' ? input as Record<string, unknown> : {};
  const nullableText = (value: unknown, max: number) =>
    typeof value === 'string' && value.trim() ? value.trim().slice(0, max) : null;
  const nullableCents = (value: unknown) =>
    Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= 100_000_000_00
      ? Number(value) : null;
  const date = typeof raw.document_date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(raw.document_date) &&
      !Number.isNaN(Date.parse(`${raw.document_date}T00:00:00Z`)) ? raw.document_date : null;
  const category = CATEGORIES.includes(raw.category as typeof CATEGORIES[number]) ? raw.category : 'other';
  const confidence = Number(raw.confidence);
  return {
    vendor_name: nullableText(raw.vendor_name, 200),
    vendor_registration_number: nullableText(raw.vendor_registration_number, 40),
    document_date: date,
    total_cents: nullableCents(raw.total_cents),
    gst_cents: nullableCents(raw.gst_cents),
    currency: nullableText(raw.currency, 3)?.toUpperCase() || null,
    payment_reference: nullableText(raw.payment_reference, 200),
    description: nullableText(raw.description, 240),
    category,
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
  };
}

async function base64Of(bytes: Uint8Array): Promise<string> {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function processQueue(): Promise<Record<string, unknown>> {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY') || '';
  if (!apiKey) throw new Error('receipt_reading_unavailable');
  const admin = billingAdminClient();
  const anthropic = new Anthropic({ apiKey });
  const processed: Array<Record<string, unknown>> = [];

  for (let i = 0; i < MAX_RECEIPTS_PER_INVOCATION; i += 1) {
    const { data: claim, error: claimError } = await admin.rpc(
      'internal_claim_receipt_for_extraction_v199',
    );
    if (claimError) throw new Error('receipt_claim_failed');
    if (!claim?.claimed) break;
    const receipt = claim.receipt as { id: string; storage_path: string; mime_type: string };

    const fail = async (reason: string) => {
      await admin.rpc('internal_record_receipt_extraction_v199', {
        p_receipt: receipt.id, p_extracted: null, p_error: reason,
      });
      processed.push({ receipt: receipt.id, status: 'failed', error: reason });
    };

    try {
      if (!imageMediaType(receipt.mime_type) && receipt.mime_type !== 'application/pdf') {
        await fail(`unsupported_for_reading:${receipt.mime_type}`);
        continue;
      }
      const { data: file, error: downloadError } = await admin.storage
        .from(BUCKET).download(receipt.storage_path);
      if (downloadError || !file) { await fail('download_failed'); continue; }

      const encoded = await base64Of(new Uint8Array(await file.arrayBuffer()));
      const document = sourceBlock(receipt.mime_type, encoded);
      if (!document) { await fail(`unsupported_for_reading:${receipt.mime_type}`); continue; }

      const message = await anthropic.messages.create({
        model: MODEL,
        max_tokens: MAX_OUTPUT_TOKENS,
        system: SYSTEM_PROMPT,
        tools: [EXTRACTION_SCHEMA as unknown as Anthropic.Tool],
        tool_choice: { type: 'tool', name: 'receipt_extraction' },
        messages: [{
          role: 'user',
          content: [document, { type: 'text', text: 'Read this receipt or supplier invoice. Leave unreadable fields null.' }] as Anthropic.ContentBlockParam[],
        }],
      });

      const use = message.content.find(
        (block): block is Anthropic.ToolUseBlock => block.type === 'tool_use',
      );
      if (!use) { await fail('model_returned_no_extraction'); continue; }

      const { error: writeError } = await admin.rpc(
        'internal_record_receipt_extraction_v199',
        { p_receipt: receipt.id, p_extracted: normalizeExtraction(use.input), p_error: null },
      );
      if (writeError) { await fail('extraction_store_failed'); continue; }
      processed.push({ receipt: receipt.id, status: 'extracted' });
    } catch (error) {
      await fail(String(error instanceof Error ? error.message : error).slice(0, 200));
    }
  }

  return {
    processed: processed.length,
    extracted: processed.filter((r) => r.status === 'extracted').length,
    failed: processed.filter((r) => r.status === 'failed').length,
    receipts: processed,
  };
}

async function isSuperAdmin(userId: string): Promise<boolean> {
  const { data, error } = await billingAdminClient()
    .from('super_admins').select('user_id').eq('user_id', userId).maybeSingle();
  return !error && Boolean(data?.user_id);
}

Deno.serve(async (req) => {
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) {
    return billingJson(403, { error: 'origin_not_allowed' });
  }
  if (req.method !== 'POST') {
    return billingCorsJson(req, 405, { error: 'method_not_allowed' });
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
    return billingCorsJson(req, 200, await processQueue());
  } catch {
    return billingCorsJson(req, 503, { error: 'receipt_worker_unavailable' });
  }
});
