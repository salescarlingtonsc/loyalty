/* nestly_v894 — check the WhatsApp code, then create the confirmed account.
 *
 * WHY THIS FUNCTION CREATES THE USER. The SMS path gets its session from GoTrue:
 * signUp sends a code, verifyOtp returns a session, and the password the customer
 * typed is applied to the live session a moment later (audit F046). The WhatsApp
 * path cannot borrow that — GoTrue did not mint this code and will not accept it —
 * so the account is created here with the admin API, phone already confirmed, and
 * the browser signs in with the password it is still holding in memory. From the
 * next line onward the two paths are the same screen and the same registration RPC.
 *
 * THE PASSWORD CROSSES THIS FUNCTION. Once, over TLS, used immediately, never
 * stored and never logged. That is the price of not having a GoTrue session to
 * update; it is written down here so nobody has to rediscover it from the shape of
 * the request body.
 *
 * NEVER LOGGED: the code, the hash, the pepper, the password, the number. Log lines
 * carry the challenge uuid and a disposition.
 */
import {
  adminClient,
  enforceRateLimit,
  json,
  preflight,
  publicError,
  readJson,
  requireOrigin,
  sha256Hex,
} from '../_shared/gateway.ts';
import {
  otpDigestInput,
  publicVerifyResponse,
  validOtpCode,
} from '../_shared/whatsapp-otp-boundaries.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function env(name: string): string {
  return Deno.env.get(name) || '';
}

function log(event: string, detail: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: 'whatsapp-otp-verify', event, ...detail }));
}

function answer(req: Request, result: Record<string, unknown>): Response {
  const mapped = publicVerifyResponse(result);
  return json(req, mapped.status, mapped.body);
}

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || req.method !== 'POST') return publicError(req, 403);

  try {
    /* The real brute-force ceiling is the 5 attempts the challenge row counts, which an
       attacker cannot escape by changing IP. This is the coarse shield in front of it, so a
       script cannot walk thousands of challenge ids cheaply. */
    const abuse = await enforceRateLimit(req, 'whatsapp-otp-verify', 60, 600);
    if (!abuse.allowed) {
      return json(req, 429, { error: 'Please wait before trying again.', retry_after: abuse.retry_after });
    }

    const body = await readJson(req, 4096);
    const challengeId = String(body?.challenge_id || '');
    const code = String(body?.code || '').replace(/\s/g, '');
    const password = typeof body?.password === 'string' ? body.password : '';
    if (!UUID.test(challengeId) || !validOtpCode(code)) return publicError(req);
    /* GoTrue enforces the real policy (length, and the breach check that v289 reports as
       weak_password). This only refuses what cannot possibly be a password, so an empty
       field does not cost the customer their code. */
    if (password.length < 8 || password.length > 128) return publicError(req);

    const pepper = env('WHATSAPP_OTP_PEPPER');
    if (pepper.length < 32) {
      log('rejected', { reason: 'otp_pepper_unconfigured' });
      return answer(req, { ok: false, reason: 'unavailable' });
    }

    const admin = adminClient();
    const codeHash = await sha256Hex(otpDigestInput(pepper, challengeId, code));

    /* Consumed BEFORE the account is created, and that order is deliberate: a correct code
       must not survive to be used twice, even at the cost of making the customer ask for a
       new one if the create below fails. The alternative — consume on success only — leaves
       a verified code replayable for the rest of its five minutes. */
    const { data: consumed, error: consumeError } = await admin.rpc('internal_whatsapp_otp_consume_v894', {
      p_challenge_id: challengeId,
      p_code_hash: codeHash,
    });
    if (consumeError) {
      log('rejected', { reason: 'consume_failed' });
      return answer(req, { ok: false, reason: 'unavailable' });
    }
    if (!consumed?.ok) {
      log('refused', { challenge_id: challengeId, reason: String(consumed?.reason || 'unknown') });
      return answer(req, consumed);
    }

    const phoneNorm = String(consumed.phone_norm || '');
    if (!/^[3689][0-9]{7}$/.test(phoneNorm)) {
      log('rejected', { reason: 'phone_norm_invalid' });
      return answer(req, { ok: false, reason: 'unavailable' });
    }
    /* The '+65…' form the browser has used for GoTrue since v42. It must match exactly, or
       the sign-in that follows would look for a user this function did not create. */
    const phone = `+65${phoneNorm}`;

    const { error: createError } = await admin.auth.admin.createUser({
      phone,
      password,
      phone_confirm: true,
    });
    if (createError) {
      const reason = String((createError as { code?: string }).code || '').toLowerCase();
      const message = String(createError.message || '').toLowerCase();
      if (reason === 'phone_exists' || message.includes('already been registered') || message.includes('already exists')) {
        log('refused', { challenge_id: challengeId, reason: 'account_exists' });
        return answer(req, { ok: false, reason: 'account_exists' });
      }
      /* Everything else — a weak password GoTrue refused, a provider fault — is one
         sentence. The code is already spent, so the screen's Resend is the way back. */
      log('rejected', { challenge_id: challengeId, reason: 'create_failed' });
      return answer(req, { ok: false, reason: 'unavailable' });
    }

    log('verified', { challenge_id: challengeId });
    return answer(req, { ok: true });
  } catch {
    return publicError(req);
  }
});
