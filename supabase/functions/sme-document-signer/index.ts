import {
  authenticatedUserId,
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingPreflight,
} from '../_shared/billing-service.ts';

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EXCHANGE_TOKEN = /^[0-9a-f]{48}$/;
const PRIVATE_BUCKET = 'sme-private';
const PRIVATE_PATH =
  /^prospects\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/v[0-9]+\/[^/]+$/i;
const MAX_DOCUMENT_BYTES = 25 * 1024 * 1024;

type SigningTarget = {
  purpose?: unknown;
  bucket_id?: unknown;
  object_path?: unknown;
  mime_type?: unknown;
  size_bytes?: unknown;
  original_filename?: unknown;
  expires_at?: unknown;
  document_version_id?: unknown;
  requested_by?: unknown;
};

function validTarget(
  value: SigningTarget | null,
  actor: string,
  expectedPurpose?: 'upload' | 'read',
): value is Required<SigningTarget> {
  const size = Number(value?.size_bytes);
  return Boolean(
    value &&
      (value.purpose === 'upload' || value.purpose === 'read') &&
      (!expectedPurpose || value.purpose === expectedPurpose) &&
      value.bucket_id === PRIVATE_BUCKET &&
      typeof value.object_path === 'string' &&
      PRIVATE_PATH.test(value.object_path) &&
      typeof value.mime_type === 'string' &&
      Number.isSafeInteger(size) &&
      size >= 1 &&
      size <= MAX_DOCUMENT_BYTES &&
      typeof value.expires_at === 'string' &&
      Number.isFinite(Date.parse(value.expires_at)) &&
      Date.parse(value.expires_at) > Date.now() &&
      typeof value.document_version_id === 'string' &&
      UUID.test(value.document_version_id) &&
      value.requested_by === actor,
  );
}

async function digestHex(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

Deno.serve(async (req) => {
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) {
    return billingCorsJson(req, 403, { error: 'origin_not_allowed' });
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

  let action = '';
  let requestId = '';
  let exchangeToken = '';
  try {
    const length = Number(req.headers.get('content-length') || '0');
    if (
      length > 4096 ||
      !req.headers.get('content-type')?.includes('application/json')
    ) {
      return billingCorsJson(req, 400, { error: 'invalid_request' });
    }
    const body = await req.json();
    action = typeof body?.action === 'string' ? body.action : '';
    requestId = typeof body?.request_id === 'string' ? body.request_id : '';
    exchangeToken =
      typeof body?.exchange_token === 'string' ? body.exchange_token : '';
  } catch {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }
  if (
    !UUID.test(requestId) ||
    !['exchange', 'finalize'].includes(action) ||
    (action === 'exchange' && !EXCHANGE_TOKEN.test(exchangeToken))
  ) {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }

  const admin = billingAdminClient();
  try {
    if (action === 'exchange') {
      const { data, error } = await admin.rpc(
        'service_consume_document_signing_request_v86',
        {
          p_request: requestId,
          p_exchange_token: exchangeToken,
          p_actor: actor,
        },
      );
      const target = data as SigningTarget | null;
      if (error || !validTarget(target, actor)) {
        return billingCorsJson(req, 403, {
          error: 'signing_request_not_available',
        });
      }

      if (target.purpose === 'upload') {
        const { data: signed, error: signingError } = await admin.storage
          .from(String(target.bucket_id))
          .createSignedUploadUrl(String(target.object_path), { upsert: false });
        if (signingError || !signed?.token) {
          throw new Error('document upload signing failed');
        }
        return billingCorsJson(req, 200, {
          purpose: 'upload',
          document_version_id: target.document_version_id,
          bucket_id: target.bucket_id,
          object_path: target.object_path,
          mime_type: target.mime_type,
          size_bytes: Number(target.size_bytes),
          signed_upload_token: signed.token,
          reservation_expires_at: target.expires_at,
        });
      }

      const secondsRemaining = Math.max(
        1,
        Math.min(
          300,
          Math.floor((Date.parse(String(target.expires_at)) - Date.now()) / 1000),
        ),
      );
      const { data: signed, error: signingError } = await admin.storage
        .from(String(target.bucket_id))
        .createSignedUrl(String(target.object_path), secondsRemaining, {
          download:
            typeof target.original_filename === 'string'
              ? target.original_filename
              : true,
        });
      if (signingError || !signed?.signedUrl) {
        throw new Error('document read signing failed');
      }
      return billingCorsJson(req, 200, {
        purpose: 'read',
        document_version_id: target.document_version_id,
        signed_url: signed.signedUrl,
        expires_at: new Date(Date.now() + secondsRemaining * 1000).toISOString(),
      });
    }

    const { data, error } = await admin.rpc(
      'service_get_consumed_document_upload_v86',
      { p_request: requestId, p_actor: actor },
    );
    const target = data as SigningTarget | null;
    if (error || !validTarget(target, actor, 'upload')) {
      return billingCorsJson(req, 403, {
        error: 'upload_reservation_not_available',
      });
    }

    const { data: storedObject, error: downloadError } = await admin.storage
      .from(String(target.bucket_id))
      .download(String(target.object_path), {}, { cache: 'no-store' });
    if (downloadError || !storedObject) {
      return billingCorsJson(req, 409, { error: 'uploaded_object_not_found' });
    }
    const bytes = await storedObject.arrayBuffer();
    if (bytes.byteLength !== Number(target.size_bytes)) {
      return billingCorsJson(req, 409, {
        error: 'uploaded_object_size_mismatch',
      });
    }

    const { data: finalized, error: finalizeError } = await admin.rpc(
      'service_finalize_document_upload_v86',
      {
        p_request: requestId,
        p_sha256: await digestHex(bytes),
        p_observed_size_bytes: bytes.byteLength,
        p_actor: actor,
      },
    );
    if (finalizeError || !finalized) {
      return billingCorsJson(req, 409, {
        error: 'upload_could_not_be_finalized',
      });
    }
    return billingCorsJson(req, 200, finalized);
  } catch {
    return billingCorsJson(req, 500, { error: 'document_signer_unavailable' });
  }
});
