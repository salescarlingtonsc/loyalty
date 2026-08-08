import { enforceRateLimit, json, preflight, publicError, readJson, recordAccountOpen, requireOrigin, turnstileSiteKey, verifyTurnstile, adminClient } from '../_shared/gateway.ts';
import { TOKEN_PATTERN, validJoinTokenPayload } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) return publicError(req, 403);

  try {
    if (req.method === 'GET') {
      /* v234: read-only page fetch, one per customer per session. Raised to match
         booking-availability's 120/60 so a shared carrier IP cannot brown-out the QR landing
         page for everyone behind it. */
      const limit = await enforceRateLimit(req, 'join-page', 120, 60);
      if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });
      const joinToken = new URL(req.url).searchParams.get('token') || '';
      if (!TOKEN_PATTERN.test(joinToken)) return publicError(req, 404);
      const { data, error } = await adminClient().rpc('internal_public_join_page_v89', { p_join_token: joinToken });
      if (error || !data) return publicError(req, 404);
      return json(req, 200, { ...data, turnstile_site_key: turnstileSiteKey() });
    }

    const body = await readJson(req);
    /* v234 CGNAT headroom. These limits key on cf-connecting-ip, and Singapore mobile carriers
       (Singtel / StarHub / M1) put many subscribers behind shared CGNAT IPv4 addresses — so one
       IP is routinely dozens of unrelated customers joining from their own phones, not one person
       retrying. Café counter WiFi has the same shape. The old 8-per-10-minutes blocked exactly the
       self-serve traffic the launch depends on.
       This one runs BEFORE verifyTurnstile: it is the first line against an unverified flood and
       shields the Turnstile API and the DB, so it keeps the tighter ratio. */
    const abuseLimit = await enforceRateLimit(req, 'join-submit-abuse', 150, 600);
    if (!abuseLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: abuseLimit.retry_after });
    if (!validJoinTokenPayload(body) || !await verifyTurnstile(req, body.turnstile_token, 'public_join')) return publicError(req);
    /* Everything counted below has ALREADY solved a Turnstile challenge, so a script cannot reach
       this line cheaply. That is what makes the higher ceiling safe: exhausting it means defeating
       the captcha 30 times per 10 minutes from one IP. */
    const writeLimit = await enforceRateLimit(req, 'join-submit', 30, 600);
    if (!writeLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: writeLimit.retry_after });
    const { data, error } = await adminClient().rpc('internal_public_join_v89', {
      p_join_token: body.join_token,
      p_name: String(body.name).trim(),
      p_phone: String(body.phone),
      p_email: body.email ? String(body.email).trim() : null,
      p_consent: body.consent === true,
    });
    if (error || !data) return publicError(req);
    await recordAccountOpen('internal_record_account_open_join_v175', {
      p_join_token: body.join_token,
      p_phone: String(body.phone),
    });
    return json(req, 200, data);
  } catch {
    return publicError(req);
  }
});
