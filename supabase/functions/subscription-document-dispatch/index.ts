import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import {
  authenticatedUserId,
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingJson,
  billingPreflight,
  requiredEnv,
} from '../_shared/billing-service.ts';
import { renderSubscriptionDocumentPdf } from '../_shared/subscription-document-pdf-v156.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BUCKET = 'sme-private';
const MAX_BODY = 8192;

type DocumentRow = {
  id: string;
  business_id?: string;
  prospect_id?: string;
  number: string;
  type: string;
  snapshot: Record<string, unknown>;
  template_version: string;
  file?: { object_path?: string } | null;
};

type DeliveryRow = {
  id: string;
  recipients: string[];
  cc_recipients: string[];
  subject: string;
  delivery_type: string;
  attempt_count: number;
};

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function escapeHtml(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[character] || character));
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(hash)].map((value) => value.toString(16).padStart(2, '0')).join('');
}

function emailHtml(delivery: DeliveryRow, documents: DocumentRow[]): string {
  const invoice = documents.find((item) => item.type === 'invoice');
  const snapshot = invoice?.snapshot || documents[0]?.snapshot || {};
  const customer = (snapshot.customer || snapshot.business || {}) as Record<string, unknown>;
  const name = String(customer.business_display_name || customer.legal_entity_name || 'your business');
  const amount = new Intl.NumberFormat('en-SG', { style: 'currency', currency: String(snapshot.currency || 'SGD') }).format(Number(snapshot.amount_paid_cents || snapshot.total_cents || 0) / 100);
  const next = snapshot.next_renewal ? new Intl.DateTimeFormat('en-SG', { dateStyle: 'medium', timeZone: 'Asia/Singapore' }).format(new Date(String(snapshot.next_renewal))) : 'shown in the attached subscription summary';
  return `<p>Payment was successful for the Peekaa subscription for ${escapeHtml(name)}.</p><p>Amount paid: ${escapeHtml(amount)}<br>Next renewal: ${escapeHtml(next)}</p><p>Your invoice and receipt are attached. You can access Peekaa using your existing authorised account.</p><p>Billing questions: Lee Chuan Seng, +65 8186 3833.</p><p>Peekaa<br>by NESTLY TECHNOLOGIES PTE. LTD.</p><p style="color:#666;font-size:12px">Delivery reference: ${escapeHtml(delivery.id)}</p>`;
}

async function ensurePdf(admin: ReturnType<typeof billingAdminClient>, document: DocumentRow): Promise<{ bytes: Uint8Array; filename: string }> {
  if (document.file?.object_path) {
    const { data, error } = await admin.storage.from(BUCKET).download(document.file.object_path, {}, { cache: 'no-store' });
    if (error || !data) throw new Error('stored_document_unavailable');
    return { bytes: new Uint8Array(await data.arrayBuffer()), filename: `${document.number}.pdf` };
  }
  const bytes = await renderSubscriptionDocumentPdf(document);
  const scope = document.business_id ? `businesses/${document.business_id}` : `prospects/${document.prospect_id}`;
  const objectPath = `platform-subscriptions/${scope}/${document.id}/r1.pdf`;
  const { error: uploadError } = await admin.storage.from(BUCKET).upload(objectPath, bytes, {
    contentType: 'application/pdf', cacheControl: 'private, max-age=0', upsert: false,
  });
  if (uploadError) throw new Error('document_storage_failed');
  const digest = await sha256(bytes);
  const { error: recordError } = await admin.rpc('v156_service_record_document_file', {
    p_document: document.id,
    p_path: objectPath,
    p_size: bytes.byteLength,
    p_sha256: digest,
    p_template: document.template_version,
  });
  if (recordError) {
    await admin.storage.from(BUCKET).remove([objectPath]);
    throw new Error('document_registration_failed');
  }
  return { bytes, filename: `${document.number}.pdf` };
}

async function finish(admin: ReturnType<typeof billingAdminClient>, deliveryId: string, status: string, providerMessageId = '', code = '', reason = '') {
  const { error } = await admin.rpc('v156_service_finish_delivery', {
    p_delivery: deliveryId, p_status: status, p_provider_message_id: providerMessageId,
    p_failure_code: code, p_failure_reason: reason,
  });
  if (error) throw new Error('delivery_completion_failed');
}

async function dispatch(): Promise<Response> {
  const admin = billingAdminClient();
  const { data, error } = await admin.rpc('v156_service_claim_dispatch', { p_limit: 10 });
  if (error) return billingJson(500, { error: 'dispatch_claim_failed' });
  const claimed = Array.isArray(data) ? data : [];
  const apiKey = Deno.env.get('RESEND_API_KEY') || '';
  const from = Deno.env.get('TRANSACTIONAL_EMAIL_FROM') || '';
  const results: Array<Record<string, unknown>> = [];
  for (const item of claimed) {
    const delivery = item.delivery as DeliveryRow;
    const documents = (item.documents || []) as DocumentRow[];
    try {
      const attachments = [];
      for (const document of documents) {
        const pdf = await ensurePdf(admin, document);
        attachments.push({ filename: pdf.filename, content: bytesToBase64(pdf.bytes) });
      }
      if (!apiKey || !from) {
        await finish(admin, delivery.id, 'provider_unconfigured', '', 'provider_unconfigured', 'RESEND_API_KEY and TRANSACTIONAL_EMAIL_FROM are required');
        results.push({ id: delivery.id, status: 'provider_unconfigured' });
        continue;
      }
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', 'idempotency-key': delivery.id },
        body: JSON.stringify({ from, to: delivery.recipients, cc: delivery.cc_recipients, subject: delivery.subject, html: emailHtml(delivery, documents), attachments }),
      });
      const payload = await response.json().catch(() => ({}));
      if (response.ok && typeof payload?.id === 'string') {
        await finish(admin, delivery.id, 'provider_accepted', payload.id);
        results.push({ id: delivery.id, status: 'provider_accepted' });
      } else {
        const permanent = response.status >= 400 && response.status < 500 && response.status !== 429;
        await finish(admin, delivery.id, permanent ? 'permanent_failed' : 'retryable_failed', '', `resend_${response.status}`, String(payload?.message || 'email provider rejected the request'));
        results.push({ id: delivery.id, status: permanent ? 'permanent_failed' : 'retryable_failed' });
      }
    } catch (error) {
      await finish(admin, delivery.id, 'retryable_failed', '', 'dispatcher_error', error instanceof Error ? error.message : 'dispatcher error').catch(() => undefined);
      results.push({ id: delivery.id, status: 'retryable_failed' });
    }
  }
  return billingJson(200, { claimed: claimed.length, results });
}

Deno.serve(async (req) => {
  if (req.method === 'POST' && req.headers.get('x-v156-dispatch-secret')) {
    const supplied = req.headers.get('x-v156-dispatch-secret') || '';
    const expected = Deno.env.get('SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET') || '';
    if (!expected || supplied.length !== expected.length || supplied !== expected) return billingJson(401, { error: 'authentication_required' });
    return dispatch();
  }
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) return billingCorsJson(req, 403, { error: 'origin_not_allowed' });
  if (req.method !== 'POST') return billingCorsJson(req, 405, { error: 'method_not_allowed' });
  const length = Number(req.headers.get('content-length') || '0');
  if (length > MAX_BODY) return billingCorsJson(req, 413, { error: 'payload_too_large' });
  let actor = '';
  try { actor = await authenticatedUserId(req); } catch { return billingCorsJson(req, 401, { error: 'authentication_required' }); }
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return billingCorsJson(req, 400, { error: 'invalid_request' }); }
  const authorization = req.headers.get('authorization') || '';
  const publicKey = Deno.env.get('SUPABASE_PUBLISHABLE_KEY') || Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!publicKey) return billingCorsJson(req, 503, { error: 'document_signing_unavailable' });
  const user = createClient(requiredEnv('SUPABASE_URL'), publicKey, { global: { headers: { authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  if (body.action === 'manual_evidence_upload') {
    if (typeof body.invoice_id !== 'string' || !UUID.test(body.invoice_id) || typeof body.operation_key !== 'string' || !UUID.test(body.operation_key) || typeof body.filename !== 'string' || typeof body.content_type !== 'string') return billingCorsJson(req, 400, { error: 'invalid_request' });
    const { data: target, error } = await user.rpc('platform_prepare_manual_evidence_upload_v156', {
      p_invoice: body.invoice_id, p_filename: body.filename.slice(0, 180), p_content_type: body.content_type, p_idempotency_key: body.operation_key,
    });
    if (error || !target?.object_path || target?.bucket_id !== BUCKET) return billingCorsJson(req, 403, { error: 'evidence_upload_denied' });
    const { data: signed, error: signError } = await billingAdminClient().storage.from(BUCKET).createSignedUploadUrl(target.object_path, { upsert: false });
    if (signError || !signed?.signedUrl) return billingCorsJson(req, 503, { error: 'evidence_upload_unavailable' });
    return billingCorsJson(req, 200, { bucket_id: BUCKET, object_path: target.object_path, signed_url: signed.signedUrl, token: signed.token, expires_in: 300, requested_by: actor });
  }
  if (body.action === 'manual_evidence_read') {
    if (typeof body.payment_id !== 'string' || !UUID.test(body.payment_id)) return billingCorsJson(req, 400, { error: 'invalid_request' });
    const { data: target, error } = await user.rpc('platform_request_manual_evidence_read_v156', { p_payment: body.payment_id });
    if (error || !target?.object_path || target?.bucket_id !== BUCKET) return billingCorsJson(req, 403, { error: 'evidence_access_denied' });
    const { data: signed, error: signError } = await billingAdminClient().storage.from(BUCKET).createSignedUrl(target.object_path, 300);
    if (signError || !signed?.signedUrl) return billingCorsJson(req, 503, { error: 'evidence_signing_failed' });
    return billingCorsJson(req, 200, { signed_url: signed.signedUrl, expires_at: new Date(Date.now() + 300_000).toISOString(), requested_by: actor });
  }
  if (body.action !== 'read' || typeof body.document_id !== 'string' || !UUID.test(body.document_id)) return billingCorsJson(req, 400, { error: 'invalid_request' });
  const { data: target, error } = await user.rpc('platform_request_document_read_v156', { p_document: body.document_id });
  if (error || !target?.object_path || !target?.bucket_id) return billingCorsJson(req, 403, { error: 'document_access_denied' });
  const { data: signed, error: signError } = await billingAdminClient().storage.from(target.bucket_id).createSignedUrl(target.object_path, Math.min(Number(target.expires_in || 300), 300), { download: target.filename || true });
  if (signError || !signed?.signedUrl) return billingCorsJson(req, 503, { error: 'document_signing_failed' });
  return billingCorsJson(req, 200, { signed_url: signed.signedUrl, expires_at: new Date(Date.now() + 300_000).toISOString(), requested_by: actor });
});
