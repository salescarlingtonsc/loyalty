/* nestly_v894 — issue a sign-up verification code and hand it to Meta.
 *
 * This is the SECOND thing in Peekaa that talks to Meta's send API, and it is
 * deliberately not the first one (v536's whatsapp-send-dispatch). That one is a
 * cron-woken queue drainer with leases, backoff and a 120-second claim: correct
 * for an appointment reminder, wrong for a code somebody is staring at a keypad
 * waiting for. This sends inline, once, and tells the browser whether it worked.
 *
 * NOT ON THE v824 PATH. The platform master switch whatsapp_outbound stays false
 * and is not read here. The owner's ruling switched off WhatsApp *messages* —
 * reminders, bring-back, retention. A sign-up code has its own switch, the c42
 * flag customer_whatsapp_otp, checked inside internal_whatsapp_otp_issue_v894.
 *
 * NEVER LOGGED: the code, its hash, the pepper, the access token, the phone number
 * id, the recipient number, the wamid. Log lines carry the challenge uuid and a
 * disposition, nothing else — and the wamid is not even stored, because it
 * base64-decodes to the customer's number.
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
import { classifyMetaResponse, sendPath } from '../_shared/whatsapp-send-boundaries.mjs';
import {
  buildOtpTemplateSend,
  generateOtpCode,
  normaliseSgPhone,
  otpDigestInput,
  publicStartResponse,
  templateSendable,
} from '../_shared/whatsapp-otp-boundaries.mjs';

const GRAPH_HOST = 'https://graph.facebook.com';
const TEMPLATE_KEY = 'signup_otp';
const TTL_SECONDS = 300;

function env(name: string): string {
  return Deno.env.get(name) || '';
}

function log(event: string, detail: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: 'whatsapp-otp-start', event, ...detail }));
}

function unavailable(req: Request, reason: string): Response {
  /* Fail CLOSED and loudly, the same shape v536 uses for missing credentials: a
     half-configured OTP path must not look like an idle one. The customer sees one
     sentence; the reason stays in the log, where it names no request value. */
  log('rejected', { reason });
  const answer = publicStartResponse({ ok: false, reason: 'unavailable' });
  return json(req, answer.status, answer.body);
}

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || req.method !== 'POST') return publicError(req, 403);

  try {
    /* Keyed on cf-connecting-ip, and sized for Singapore CGNAT the way public-join's
       v234 note explains: one carrier IP is routinely dozens of unrelated people. The
       per-NUMBER limit that actually stops an attacker (3 per 10 minutes, 8 per day)
       lives in internal_whatsapp_otp_issue_v894, because a number cannot be rotated. */
    const abuse = await enforceRateLimit(req, 'whatsapp-otp-start', 60, 600);
    if (!abuse.allowed) {
      return json(req, 429, { error: 'Please wait before requesting another code.', retry_after: abuse.retry_after });
    }

    const body = await readJson(req, 2048);
    const phone = normaliseSgPhone(body?.phone);
    if (!phone) {
      const answer = publicStartResponse({ ok: false, reason: 'phone_invalid' });
      return json(req, answer.status, answer.body);
    }
    /* v894 is sign-up only; password recovery keeps the SMS path. The database CHECK
       says the same thing, so a widened client cannot quietly start using this. */
    if (body?.purpose !== 'signup') return publicError(req);

    const token = env('WHATSAPP_ACCESS_TOKEN');
    const phoneNumberId = env('WHATSAPP_PHONE_NUMBER_ID');
    const pepper = env('WHATSAPP_OTP_PEPPER');
    const path = sendPath(phoneNumberId);
    if (!token || !path) return unavailable(req, 'send_credentials_unconfigured');
    if (pepper.length < 32) return unavailable(req, 'otp_pepper_unconfigured');

    const admin = adminClient();

    /* Read the template BEFORE issuing anything. An unapproved template comes back from
       Meta as an unknown-template error, and by then a code exists that the customer will
       never be sent — a resend budget spent on nothing. v894 ships the row as 'draft'
       on purpose, so this is the branch that holds until Meta approves it. */
    const { data: template, error: templateError } = await admin
      .from('whatsapp_template_registry_v551')
      .select('meta_name, language_code, category, status')
      .eq('template_key', TEMPLATE_KEY)
      .maybeSingle();
    if (templateError) return unavailable(req, 'template_lookup_failed');
    if (!templateSendable(template)) return unavailable(req, 'template_not_approved');

    const challengeId = crypto.randomUUID();
    const code = generateOtpCode((n: number) => crypto.getRandomValues(new Uint8Array(n)));
    const codeHash = await sha256Hex(otpDigestInput(pepper, challengeId, code));

    const { data: issued, error: issueError } = await admin.rpc('internal_whatsapp_otp_issue_v894', {
      p_challenge_id: challengeId,
      p_phone: phone.phoneNorm,
      p_purpose: 'signup',
      p_code_hash: codeHash,
      p_ttl_seconds: TTL_SECONDS,
    });
    if (issueError) return unavailable(req, 'issue_failed');
    if (!issued?.ok) {
      /* feature_disabled lands here too, and is answered as "unavailable" rather than
         "off": whether a platform flag is set is not a customer's business. */
      const answer = publicStartResponse(issued);
      if (answer.status === 503) log('rejected', { reason: String(issued?.reason || 'issue_refused') });
      return json(req, answer.status, answer.body);
    }

    const send = buildOtpTemplateSend({
      toE164: phone.e164,
      templateName: template.meta_name,
      languageCode: template.language_code,
      code,
    });
    if (!send.ok) {
      await admin.rpc('internal_whatsapp_otp_record_send_v894', {
        p_challenge_id: challengeId, p_status: 'failed', p_error_code: send.reason,
      });
      return unavailable(req, send.reason);
    }

    let response: Response;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      response = await fetch(`${GRAPH_HOST}${path}`, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(send.body),
        signal: controller.signal,
      });
    } catch {
      /* A transport failure is not retried here. The customer is on the screen and can
         press Resend, which is a cheaper and more honest recovery than this function
         holding the request open through a backoff they cannot see. */
      await admin.rpc('internal_whatsapp_otp_record_send_v894', {
        p_challenge_id: challengeId, p_status: 'failed', p_error_code: 'transport',
      });
      return unavailable(req, 'transport_failed');
    } finally {
      clearTimeout(timer);
    }

    let payload: unknown = null;
    try { payload = await response.json(); } catch { payload = null; }
    const outcome = classifyMetaResponse(response.status, payload, response.headers);

    if (outcome.disposition !== 'sent') {
      /* record_send also expires the challenge: an undelivered code must not stay
         guessable, and it must not count against the customer's next attempt. */
      await admin.rpc('internal_whatsapp_otp_record_send_v894', {
        p_challenge_id: challengeId, p_status: 'failed', p_error_code: outcome.code,
      });
      log('send_failed', { challenge_id: challengeId, disposition: outcome.disposition, code: outcome.code });
      return unavailable(req, 'send_failed');
    }

    await admin.rpc('internal_whatsapp_otp_record_send_v894', {
      p_challenge_id: challengeId, p_status: 'sent', p_error_code: null,
    });
    log('sent', { challenge_id: challengeId });

    const answer = publicStartResponse({
      ok: true, challenge_id: challengeId, expires_in: issued.expires_in ?? TTL_SECONDS,
    });
    return json(req, answer.status, answer.body);
  } catch {
    return publicError(req);
  }
});
