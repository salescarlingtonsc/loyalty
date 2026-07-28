import {
  adminClient,
  enforceRateLimit,
  json,
  preflight,
  publicError,
  readJson,
  requireOrigin,
  turnstileSiteKey,
  verifyTurnstile,
} from '../_shared/gateway.ts';
import {
  UUID_PATTERN,
  validBusinessApplicationPayload,
} from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) {
    return publicError(req, 403);
  }

  try {
    if (req.method === 'GET') {
      const url = new URL(req.url);
      const invitationToken = url.searchParams.get('invite') || '';
      const scope = invitationToken
        ? 'business-application-invitation'
        : 'business-application-status';
      const limit = await enforceRateLimit(req, scope, invitationToken ? 20 : 30, 300);
      if (!limit.allowed) {
        return json(req, 429, {
          error: 'Please wait before checking again.',
          retry_after: limit.retry_after,
        });
      }
      if (invitationToken) {
        if (!/^[a-f0-9]{64}$/i.test(invitationToken)) return publicError(req, 404);
        const { data, error } = await adminClient().rpc(
          'internal_get_approved_business_invitation_v95',
          { p_invitation_token: invitationToken },
        );
        if (error || !data?.valid) return publicError(req, 404);
        return json(req, 200, data);
      }

      const reference = url.searchParams.get('reference') || '';
      if (!UUID_PATTERN.test(reference)) return publicError(req, 404);
      const { data, error } = await adminClient().rpc('get_business_application_status_v95', {
        p_public_reference: reference,
      });
      if (error || !data?.found) return publicError(req, 404);
      return json(req, 200, {
        ...data,
        turnstile_site_key: turnstileSiteKey(),
      });
    }

    const body = await readJson(req);
    const abuseLimit = await enforceRateLimit(req, 'business-application-abuse', 30, 3600);
    if (!abuseLimit.allowed) {
      return json(req, 429, {
        error: 'Please wait before trying again.',
        retry_after: abuseLimit.retry_after,
      });
    }
    if (
      !validBusinessApplicationPayload(body)
      || !await verifyTurnstile(req, body.turnstile_token, 'business_application')
    ) return publicError(req);

    const writeLimit = await enforceRateLimit(req, 'business-application-submit', 5, 3600);
    if (!writeLimit.allowed) {
      return json(req, 429, {
        error: 'Please wait before submitting another application.',
        retry_after: writeLimit.retry_after,
      });
    }

    const { data, error } = await adminClient().rpc('internal_submit_business_application_v95', {
      p_contact_name: String(body.contact_name).trim(),
      p_contact_email: String(body.contact_email).trim().toLowerCase(),
      p_contact_phone: String(body.contact_phone),
      p_business_name: String(body.business_name).trim(),
      p_sector_key: String(body.sector_key),
      p_registration_number: String(body.registration_number || '').trim() || null,
      p_locale: String(body.locale || 'en').toLowerCase() === 'zh-cn'
        ? 'zh-CN'
        : 'en',
      p_idempotency_key: String(body.idempotency_key),
    });
    if (error || !data) return publicError(req);
    return json(req, 200, data);
  } catch {
    return publicError(req);
  }
});
