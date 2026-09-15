// NESTLY v199 — reads a receipt or supplier invoice and PROPOSES the bookkeeping entry.
//
// It never posts. The worker fills in what it can read (vendor, date, total, GST,
// a suggested category) and stops; a super admin confirms or corrects every figure,
// and only that confirmation posts through platform_post_receipt_expense_v199 ->
// the existing v147 expense path -> the journal. Letting an OCR write the books
// unreviewed is how bookkeeping goes quietly wrong, so the split is deliberate.
//
// MODEL CHOICE (nestly_v985, owner ruling 2026-09-16): Gemini, cheapest tier. The
// earlier note here argued Haiku on the grounds that the saving was cents a month
// and ANTHROPIC_API_KEY was "already configured and proven" — the second half of
// that stopped being true (the key now returns 401 "API key is invalid", and no
// receipt has ever been read). The owner has chosen Gemini; at the measured shape
// of this request, roughly 3.4k input and 200 output tokens per receipt, it costs
// about 0.03 US cents against Haiku's 0.44.
//
// NOT the cheapest tier, and here is the receipt that settled it. gemini-2.5-flash-lite
// ($0.10/$0.40) was tried first and failed on the only field that really matters. Given a
// real Koufu food-court receipt — TOTAL 16.57, CDCVoucher 15.00, VISAMASTER 1.57 — it
// returned total_cents 157: the card payment, not the bill. Its own gst_cents of 137 was
// arithmetically impossible against that (GST cannot be 87% of a total), and it called
// itself 90% confident. It also dropped a digit from the receipt number and named the food
// court instead of the GST-registered entity.
//
// The SPLIT TENDER and GST self-check rules below were written for that failure and did fix
// the total on 2.5 — but it still lost the digit. gemini-3.5-flash-lite ($0.30/$2.50) read
// the same photo perfectly first time, every field, needing no prompt crutch: still about a
// quarter of Haiku 4.5's price, a tenth of a US cent per receipt.
//
// So the default is the model that read the receipt correctly, and RECEIPT_OCR_MODEL exists
// to go cheaper only if someone can show 2.5 is good enough on a real sample. The whole
// spread here is under a dollar a month at this volume; legibility is the only thing worth
// choosing on, and an OCR that is confidently wrong about a total is worse than none.
//
// maxOutputTokens is generous rather than tight: on models that think before
// answering, a tight cap is spent reasoning and the response comes back truncated
// with finishReason MAX_TOKENS and no JSON at all. Output is $0.40/MTok; headroom
// is cheaper than a failed read.

import {
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingJson,
  billingPreflight,
  authenticatedUserId,
} from '../_shared/billing-service.ts';

const MODEL = Deno.env.get('RECEIPT_OCR_MODEL') || 'gemini-3.5-flash-lite';
const GEMINI_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models';
const MAX_RECEIPTS_PER_INVOCATION = 10;
const MAX_OUTPUT_TOKENS = 2048;
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
  '- SPLIT TENDER. The TOTAL line is what was spent, even when it was settled in',
  '  parts. A CDC voucher, card, cash, NETS or points line UNDER the total is HOW it',
  '  was paid, not what it cost. A receipt reading TOTAL 16.57 / CDCVoucher 15.00 /',
  '  VISAMASTER 1.57 has total_cents 1657 — never 157.',
  '- CHECK YOURSELF AGAINST THE GST LINE before you answer. Singapore GST is 9%, so',
  '  a GST-inclusive total satisfies gst_cents ~= total_cents * 9 / 109. If the GST',
  '  printed on the receipt is far larger than that, you have taken a payment line as',
  '  the total. Re-read the TOTAL line.',
  '- gst_cents is the GST/tax line only, null when the receipt does not show one.',
  '- document_date is the transaction date in YYYY-MM-DD. Singapore receipts are',
  '  usually DD/MM/YYYY, so 03/08/2026 is 2026-08-03, not 8 March.',
  '- For a supplier invoice, use the invoice date and the invoice number as the',
  '  payment_reference. Do not use a due date as the document date.',
  '- confidence is your own honest 0-1 reading of how legible this document was.',
  '  Report low confidence for a blurred, cropped or partial image.',
  `- category must be one of: ${CATEGORIES.join(', ')}. Use "other" when unsure.`,
].join('\n');

/* Gemini's responseSchema is an OpenAPI 3.0 subset, not JSON Schema: types are
   upper-case, a nullable field is `nullable: true` rather than a ['string','null']
   union, and additionalProperties is not accepted. Paired with
   responseMimeType 'application/json' this constrains the decoder itself, so the
   model cannot answer with prose — the failure mode that would otherwise reach
   normalizeExtraction as a wall of nulls. */
const RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    vendor_name: { type: 'STRING', nullable: true },
    vendor_registration_number: { type: 'STRING', nullable: true, description: 'UEN/GST no. if printed' },
    document_date: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' },
    total_cents: { type: 'INTEGER', nullable: true },
    gst_cents: { type: 'INTEGER', nullable: true },
    currency: { type: 'STRING', nullable: true },
    payment_reference: { type: 'STRING', nullable: true, description: 'card tail, invoice or receipt no.' },
    description: { type: 'STRING', nullable: true, description: 'what was bought, one short line' },
    category: { type: 'STRING', nullable: true, enum: [...CATEGORIES] },
    confidence: { type: 'NUMBER' },
  },
  required: ['confidence'],
  propertyOrdering: [
    'vendor_name', 'vendor_registration_number', 'document_date', 'total_cents',
    'gst_cents', 'currency', 'payment_reference', 'description', 'category', 'confidence',
  ],
} as const;

/* What Gemini will accept inline. This deliberately tracks the upload controls in
   the console (jpeg/png/webp/heic + pdf) rather than the previous provider's list,
   which allowed gif — never offered by the UI — and refused heic, which an iPhone
   produces by default. */
const READABLE_TYPES = [
  'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf',
];

function canRead(mime: string): boolean {
  return READABLE_TYPES.includes(mime);
}

function sourceBlock(mime: string, data: string): Record<string, unknown> | null {
  return canRead(mime) ? { inlineData: { mimeType: mime, data } } : null;
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
  const apiKey = Deno.env.get('GEMINI_API_KEY') || '';
  if (!apiKey) throw new Error('receipt_reading_unavailable');
  const admin = billingAdminClient();
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
      if (!canRead(receipt.mime_type)) {
        await fail(`unsupported_for_reading:${receipt.mime_type}`);
        continue;
      }
      const { data: file, error: downloadError } = await admin.storage
        .from(BUCKET).download(receipt.storage_path);
      if (downloadError || !file) { await fail('download_failed'); continue; }

      const encoded = await base64Of(new Uint8Array(await file.arrayBuffer()));
      const document = sourceBlock(receipt.mime_type, encoded);
      if (!document) { await fail(`unsupported_for_reading:${receipt.mime_type}`); continue; }

      /* temperature 0: this is transcription, not composition. The same receipt
         must read the same way twice, or a figure can change between a retry and
         the copy a human confirmed. */
      const response = await fetch(`${GEMINI_ENDPOINT}/${MODEL}:generateContent`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
          contents: [{
            role: 'user',
            parts: [document, { text: 'Read this receipt or supplier invoice. Leave unreadable fields null.' }],
          }],
          generationConfig: {
            responseMimeType: 'application/json',
            responseSchema: RESPONSE_SCHEMA,
            maxOutputTokens: MAX_OUTPUT_TOKENS,
            temperature: 0,
          },
        }),
      });
      if (!response.ok) {
        /* The status and the provider's own words, the way the previous 401 told us
           the key was invalid. Never swallow this into a generic failure. */
        await fail(`${response.status} ${(await response.text()).slice(0, 300)}`);
        continue;
      }

      const payload = await response.json();
      const candidate = payload?.candidates?.[0];
      const text = (candidate?.content?.parts ?? [])
        .map((part: { text?: string }) => part?.text ?? '')
        .join('')
        .trim();
      if (!text) {
        /* Empty with a reason attached: MAX_TOKENS means the cap was spent before
           any JSON, SAFETY means the image was refused. Both are worth telling
           apart when a receipt will not read. */
        await fail(`model_returned_no_extraction:${candidate?.finishReason ?? payload?.promptFeedback?.blockReason ?? 'empty'}`);
        continue;
      }
      let extracted: unknown;
      try {
        extracted = JSON.parse(text);
      } catch {
        await fail('model_returned_unparsable_json');
        continue;
      }

      const { data: writeResult, error: writeError } = await admin.rpc(
        'internal_record_receipt_extraction_v199',
        { p_receipt: receipt.id, p_extracted: normalizeExtraction(extracted), p_error: null },
      );
      if (writeError) { await fail('extraction_store_failed'); continue; }
      if (!writeResult?.updated) {
        // The claim lease moved on (reclaimed by a second worker, or already
        // resolved) before this worker's write landed. Nothing was persisted by
        // THIS attempt, so it must not be reported as extracted.
        processed.push({ receipt: receipt.id, status: 'failed', error: 'claim_lost' });
        continue;
      }
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
