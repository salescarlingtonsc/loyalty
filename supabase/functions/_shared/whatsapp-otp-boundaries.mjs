/* nestly_v894 — every decision the WhatsApp sign-up OTP makes, with no I/O in sight.
 *
 * Same split as v517's whatsapp-send-boundaries.mjs, for the same reason: the edge
 * functions that import this are plumbing that cannot be unit-tested without a
 * network and a database, and the rules below are exactly the part worth testing.
 *
 * NOTHING HERE LOGS. The code, the number and the hash pass through these functions
 * and none of them may reach a log line — v536's standing rule, restated because an
 * OTP is the one value in Peekaa that is a credential on its own.
 */

// ---------------------------------------------------------------------------
// Phone
// ---------------------------------------------------------------------------

// A deliberate transcription of app.norm_phone(text), which is IMMUTABLE and is the
// single canonical normaliser in the database. It is restated here rather than called
// because the edge function must reject a malformed number BEFORE it spends a database
// round trip — and because a WhatsApp send needs the E.164 form that norm_phone does
// not return. If norm_phone's domain ever widens beyond Singapore, this must follow it
// in the same commit; the v894 tests assert the two agree on the documented cases.
export function normaliseSgPhone(input) {
  const digits = String(input ?? '').replace(/[^0-9]/g, '');
  let phoneNorm = null;
  if (/^[3689][0-9]{7}$/.test(digits)) phoneNorm = digits;
  else if (digits.length === 10 && digits.startsWith('65') && /^[3689]/.test(digits.slice(2))) phoneNorm = digits.slice(2);
  else if (digits.length === 11 && digits.startsWith('065') && /^[3689]/.test(digits.slice(3))) phoneNorm = digits.slice(3);
  if (!phoneNorm) return null;
  return { phoneNorm, e164: `65${phoneNorm}` };
}

// ---------------------------------------------------------------------------
// The code
// ---------------------------------------------------------------------------

// Six digits, uniform. `value % 1000000` is NOT uniform over 4 random bytes — the low
// codes would come up very slightly more often than the high ones. That bias is far too
// small to matter against a 5-attempt lockout, and it is still not written here, because
// the cost of doing it correctly is one loop and the cost of being wrong is a credential.
//
// `nextBytes` is injected so the test can force the rejection branch; production passes
// crypto.getRandomValues.
export function generateOtpCode(nextBytes) {
  const LIMIT = 4294000000; // largest multiple of 1e6 below 2^32
  for (let guard = 0; guard < 64; guard += 1) {
    const bytes = nextBytes(4);
    if (!bytes || bytes.length !== 4) throw new Error('entropy unavailable');
    const value = ((bytes[0] << 24) >>> 0) + (bytes[1] << 16) + (bytes[2] << 8) + bytes[3];
    if (value >= LIMIT) continue;
    return String(value % 1000000).padStart(6, '0');
  }
  throw new Error('entropy unavailable');
}

export function validOtpCode(code) {
  return /^[0-9]{6}$/.test(String(code ?? ''));
}

// The stored hash binds the code to ITS OWN challenge and to a pepper that lives only in
// the edge function's environment. Binding to the challenge id means a hash lifted from
// one row cannot be replayed against another; the pepper means a database dump — or
// anything else holding service_role — cannot brute-force six digits offline, which
// otherwise takes a fraction of a second.
export function otpDigestInput(pepper, challengeId, code) {
  if (typeof pepper !== 'string' || pepper.length < 32) throw new Error('pepper unavailable');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(challengeId || ''))) {
    throw new Error('challenge id invalid');
  }
  if (!validOtpCode(code)) throw new Error('code invalid');
  return `${pepper} ${String(challengeId).toLowerCase()} ${code}`;
}

// ---------------------------------------------------------------------------
// The Meta payload
// ---------------------------------------------------------------------------

// An authentication template is not shaped like the utility ones v517 builds. Meta requires
// the code to appear TWICE in the request — once as the body variable and once as the
// parameter of the copy-code button — and rejects the message with a parameter-count error
// if either is missing. The button index is a string, not a number; that is Meta's API, not
// a typo here.
export function buildOtpTemplateSend({ toE164: to, templateName, languageCode, code }) {
  if (!/^[1-9][0-9]{7,14}$/.test(String(to || ''))) return { ok: false, reason: 'recipient_invalid' };
  if (!/^[a-z0-9_]{1,512}$/.test(String(templateName || ''))) return { ok: false, reason: 'template_name_invalid' };
  if (!/^[a-zA-Z]{2}(_[a-zA-Z]{2,4})?$/.test(String(languageCode || ''))) return { ok: false, reason: 'language_code_invalid' };
  if (!validOtpCode(code)) return { ok: false, reason: 'code_invalid' };
  return {
    ok: true,
    body: {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: String(to),
      type: 'template',
      template: {
        name: templateName,
        language: { code: languageCode },
        components: [
          { type: 'body', parameters: [{ type: 'text', text: String(code) }] },
          { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: String(code) }] },
        ],
      },
    },
  };
}

// A registry row is only sendable once Meta has approved it. 'draft' and 'submitted' are the
// states v894 ships in, and a send attempted in either comes back as an unknown-template error
// after we have already issued a code the customer will never receive — so it is refused here
// instead, before the code exists.
export function templateSendable(row) {
  return !!row
    && row.status === 'approved'
    && row.category === 'authentication'
    && typeof row.meta_name === 'string'
    && typeof row.language_code === 'string';
}

// ---------------------------------------------------------------------------
// What the browser is told
// ---------------------------------------------------------------------------

// The start endpoint is unauthenticated, so its answer must not distinguish "this number has
// no WhatsApp", "the feature is off" and "you have asked three times" any more finely than the
// customer needs to act — and must never confirm whether an account exists. Three outcomes:
// it worked, wait a bit, or it is unavailable. `retry_after` is safe to return; it is a
// property of the request, not of the account.
export function publicStartResponse(result) {
  if (result?.ok === true) {
    return { status: 200, body: { challenge_id: result.challenge_id, expires_in: result.expires_in } };
  }
  if (result?.reason === 'rate_limited') {
    return {
      status: 429,
      body: { error: 'Please wait before requesting another code.', retry_after: result.retry_after ?? 600 },
    };
  }
  if (result?.reason === 'phone_invalid') {
    return { status: 400, body: { error: 'Enter a valid Singapore mobile number.' } };
  }
  return { status: 503, body: { error: 'WhatsApp verification is unavailable right now.' } };
}

export function publicVerifyResponse(result) {
  if (result?.ok === true) return { status: 200, body: { verified: true } };
  if (result?.reason === 'code_invalid') {
    return {
      status: 400,
      body: { error: 'That code is not right.', attempts_left: result.attempts_left ?? 0 },
    };
  }
  if (result?.reason === 'too_many_attempts') {
    return { status: 429, body: { error: 'Too many attempts. Request a new code.' } };
  }
  if (result?.reason === 'challenge_invalid') {
    return { status: 400, body: { error: 'That code has expired. Request a new one.' } };
  }
  if (result?.reason === 'account_exists') {
    // Not an oracle: this answer is only ever reached by someone who has just proved they
    // control the number, by reading a code that was sent to it.
    return { status: 409, body: { error: 'An account already exists for this number. Please sign in.' } };
  }
  return { status: 503, body: { error: 'WhatsApp verification is unavailable right now.' } };
}

/* nestly_v973 — what GoTrue's refusal to create the account means, lifted out of the handler.
 *
 * This branch decides whether somebody who already has an account is told so ("An account already
 * exists for this number. Please sign in.") or fobbed off with a generic 503 — and it was the one
 * piece of whatsapp-otp-verify with no executed coverage at all, because it lived inline in the
 * Deno.serve body and was only ever asserted against by source-text matching.
 *
 * It is deliberately generous about HOW GoTrue says it. The structured `code` is the reliable
 * signal on current versions, but the message has carried the same fact in several wordings across
 * releases, and getting this wrong strands a returning customer on an error that tells them
 * nothing. Everything unrecognised stays 'unavailable' — the safe, uninformative answer.
 */
export function classifyCreateUserFailure(error) {
  if (!error) return null;
  const code = String(error.code ?? '').trim().toLowerCase();
  const message = String(error.message ?? '').trim().toLowerCase();
  const status = Number(error.status ?? 0);

  if (code === 'phone_exists' || code === 'user_already_exists') return 'account_exists';
  if (status === 422 && message.includes('already')) return 'account_exists';
  if (message.includes('already been registered')
    || message.includes('already exists')
    || message.includes('already registered')) {
    return 'account_exists';
  }
  return 'unavailable';
}
