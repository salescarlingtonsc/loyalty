import { adminClient, bookingChangeFingerprint, conflictError, enforceRateLimit, json, preflight, publicError, readJson, requireOrigin, sha256Hex } from '../_shared/gateway.ts';
import { validManagePayload } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || req.method !== 'POST') return publicError(req, 403);

  try {
    const body = await readJson(req);
    if (!validManagePayload(body)) return publicError(req);
    const ipLimit = await enforceRateLimit(req, 'manage-booking-ip', 20, 600);
    if (!ipLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: ipLimit.retry_after });
    const tokenHash = await sha256Hex(String(body.token));
    const limit = await enforceRateLimit(req, 'manage-booking-token', 10, 600, tokenHash);
    if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });

    if (body.action === 'lookup') {
      const { data, error } = await adminClient().rpc('internal_public_booking_lookup', { p_token_hash: tokenHash });
      if (error || !data) return publicError(req);
      return json(req, 200, data);
    }

    const { data, error } = await adminClient().rpc('internal_public_booking_change', {
      p_token_hash: tokenHash,
      p_submission_id: body.submission_id,
      p_request_fingerprint: await bookingChangeFingerprint(body),
      p_kind: body.kind,
      p_proposed: body.proposed || null,
      p_note: body.note ? String(body.note).trim() : null,
    });
    if (error || !data) return publicError(req);
    if (data.conflict) return conflictError(req);
    return json(req, 200, data);
  } catch {
    return publicError(req);
  }
});
