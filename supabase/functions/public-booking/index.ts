import { adminClient, bookingRequestFingerprint, conflictError, deriveBookingManagementToken, enforceRateLimit, json, preflight, publicError, readJson, requireOrigin, sha256Hex, turnstileSiteKey, verifyTurnstile } from '../_shared/gateway.ts';
import { SLUG_PATTERN, validBookingPayload } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) return publicError(req, 403);

  try {
    if (req.method === 'GET') {
      const limit = await enforceRateLimit(req, 'booking-page', 60, 60);
      if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });
      const slug = new URL(req.url).searchParams.get('slug') || '';
      if (!SLUG_PATTERN.test(slug)) return publicError(req, 404);
      const { data, error } = await adminClient().rpc('internal_public_booking_page', { p_slug: slug });
      if (error || !data) return publicError(req, 404);
      return json(req, 200, { ...data, turnstile_site_key: turnstileSiteKey() });
    }

    const body = await readJson(req);
    const abuseLimit = await enforceRateLimit(req, 'booking-submit-abuse', 80, 600);
    if (!abuseLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: abuseLimit.retry_after });
    if (!validBookingPayload(body) || !await verifyTurnstile(req, body.turnstile_token, 'public_booking')) return publicError(req);
    const writeLimit = await enforceRateLimit(req, 'booking-submit', 10, 600);
    if (!writeLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: writeLimit.retry_after });

    const manageToken = await deriveBookingManagementToken(body.slug, body.submission_id);
    const tokenHash = await sha256Hex(manageToken);
    const idempotencyHash = await sha256Hex(String(body.submission_id));
    const requestFingerprint = await bookingRequestFingerprint(body);
    const { data, error } = await adminClient().rpc('internal_public_booking_submit', {
      p_slug: body.slug,
      p_name: String(body.name).trim(),
      p_email: body.email ? String(body.email).trim() : null,
      p_phone: body.phone ? String(body.phone) : null,
      p_service: body.service || null,
      p_party: Number(body.party),
      p_preferred: body.preferred,
      p_notes: body.notes ? String(body.notes).trim() : null,
      p_table_type: body.table_type || null,
      p_consent: body.consent === true,
      p_token_hash: tokenHash,
      p_idempotency_hash: idempotencyHash,
      p_request_fingerprint: requestFingerprint,
    });
    if (error || !data) return publicError(req);
    if (data.conflict) return conflictError(req);
    return json(req, 200, { ...data, manage_token: manageToken });
  } catch {
    return publicError(req);
  }
});
