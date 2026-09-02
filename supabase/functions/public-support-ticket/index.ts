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
import { normalizePublicLocale, validSupportTicketPayload } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) {
    return publicError(req, 403);
  }

  try {
    /* GET exists only to hand the page its Turnstile site key. There is deliberately no
       status-by-reference read here: unlike a business application, a support ticket's
       reference would let anyone who guessed one read someone else's complaint. */
    if (req.method === 'GET') {
      const limit = await enforceRateLimit(req, 'support-ticket-page', 60, 300);
      if (!limit.allowed) {
        return json(req, 429, {
          error: 'Please wait before trying again.',
          retry_after: limit.retry_after,
        });
      }
      return json(req, 200, { turnstile_site_key: turnstileSiteKey() });
    }

    const body = await readJson(req);
    /* Pre-Turnstile limiter, sized the way public-join and the business application are: keyed
       on cf-connecting-ip, and SG mobile carriers put many unrelated subscribers behind one
       CGNAT IPv4. A support page is exactly where a stuck customer retries, so this is headroom
       for honest repetition, not an invitation — the post-captcha limiter below is the real cap. */
    const abuseLimit = await enforceRateLimit(req, 'support-ticket-abuse', 80, 3600);
    if (!abuseLimit.allowed) {
      return json(req, 429, {
        error: 'Please wait before trying again.',
        retry_after: abuseLimit.retry_after,
      });
    }

    if (
      !validSupportTicketPayload(body)
      || !await verifyTurnstile(req, body.turnstile_token, 'support_ticket')
    ) return publicError(req);

    const writeLimit = await enforceRateLimit(req, 'support-ticket-submit', 20, 3600);
    if (!writeLimit.allowed) {
      return json(req, 429, {
        error: 'Please wait before sending another message.',
        retry_after: writeLimit.retry_after,
      });
    }

    const phone = String(body.contact_phone || '').trim();
    const businessName = String(body.business_name || '').trim();
    const { data, error } = await adminClient().rpc('internal_submit_support_ticket_v672', {
      p_requester_kind: String(body.requester_kind),
      p_contact_name: String(body.contact_name).trim(),
      p_contact_email: String(body.contact_email).trim().toLowerCase(),
      p_contact_phone: phone || null,
      p_business_name: businessName || null,
      p_what_happened: String(body.what_happened).trim(),
      p_locale: normalizePublicLocale(body.locale) || 'en',
      p_idempotency_key: String(body.idempotency_key),
    });
    if (error || !data) return publicError(req);
    return json(req, 200, data);
  } catch {
    return publicError(req);
  }
});
