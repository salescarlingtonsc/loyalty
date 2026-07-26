import { enforceRateLimit, json, preflight, publicError, readJson, requireOrigin, turnstileSiteKey, verifyTurnstile, adminClient } from '../_shared/gateway.ts';
import { TOKEN_PATTERN, validJoinTokenPayload } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) return publicError(req, 403);

  try {
    if (req.method === 'GET') {
      const limit = await enforceRateLimit(req, 'join-page', 60, 60);
      if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });
      const joinToken = new URL(req.url).searchParams.get('token') || '';
      if (!TOKEN_PATTERN.test(joinToken)) return publicError(req, 404);
      const { data, error } = await adminClient().rpc('internal_public_join_page_v89', { p_join_token: joinToken });
      if (error || !data) return publicError(req, 404);
      return json(req, 200, { ...data, turnstile_site_key: turnstileSiteKey() });
    }

    const body = await readJson(req);
    const abuseLimit = await enforceRateLimit(req, 'join-submit-abuse', 60, 600);
    if (!abuseLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: abuseLimit.retry_after });
    if (!validJoinTokenPayload(body) || !await verifyTurnstile(req, body.turnstile_token, 'public_join')) return publicError(req);
    const writeLimit = await enforceRateLimit(req, 'join-submit', 8, 600);
    if (!writeLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: writeLimit.retry_after });
    const { data, error } = await adminClient().rpc('internal_public_join_v89', {
      p_join_token: body.join_token,
      p_name: String(body.name).trim(),
      p_phone: String(body.phone),
      p_email: body.email ? String(body.email).trim() : null,
      p_consent: body.consent === true,
    });
    if (error || !data) return publicError(req);
    return json(req, 200, data);
  } catch {
    return publicError(req);
  }
});
