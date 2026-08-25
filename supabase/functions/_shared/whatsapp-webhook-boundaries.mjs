// v504 — the decisions the Meta WhatsApp webhook makes, with no Deno, no
// network and no database in them.
//
// Plain .mjs rather than .ts for the same reason customer-push-boundaries.mjs
// is: `node --test` can import it directly, so the rules below are covered by
// tests/whatsapp/v504-webhook.test.mjs without a Deno runtime or a live Meta
// app. WebCrypto is used, which Node 22+ and Deno both expose globally.
// whatsapp-webhook.ts re-exports everything here; index.ts keeps only plumbing.

const encoder = new TextEncoder();

// Constant-time compare. Mirrors pushDispatchAuthorized in customer-push.ts.
// Length is compared first and non-constant-time on purpose: the length of a
// verify token is not the secret, and a variable-length loop would be worse.
export function secretEquals(expected, supplied) {
  if (typeof expected !== 'string' || typeof supplied !== 'string') return false;
  if (expected.length === 0 || expected.length !== supplied.length) return false;
  let mismatch = 0;
  for (let index = 0; index < expected.length; index += 1) {
    mismatch |= expected.charCodeAt(index) ^ supplied.charCodeAt(index);
  }
  return mismatch === 0;
}

/* ---------------------------------------------------------------------------
 * GET — Meta's subscription challenge.
 *
 * Meta sends hub.mode=subscribe, hub.verify_token=<what you typed into the
 * dashboard> and hub.challenge=<random string>. The challenge must come back as
 * PLAIN TEXT, bare, status 200. Returning JSON, or the challenge wrapped in
 * quotes, fails verification even though the token matched — a genuinely
 * confusing 20 minutes if you hit it, so index.ts sets the content type by hand.
 * ------------------------------------------------------------------------- */

// 32 chars is the same floor deriveManagementToken imposes on its secret. A
// verify token shorter than that is refused rather than accepted weakly.
export const MIN_VERIFY_TOKEN_LENGTH = 32;

export function verificationOutcome(params, expectedToken) {
  if (typeof expectedToken !== 'string' || expectedToken.length < MIN_VERIFY_TOKEN_LENGTH) {
    // 503, not 403: this is our misconfiguration, not Meta's, and the
    // difference is what tells you which side to go and fix.
    return { ok: false, status: 503, error: 'verify_token_unconfigured' };
  }
  const mode = params.get('hub.mode') || '';
  const token = params.get('hub.verify_token') || '';
  const challenge = params.get('hub.challenge') || '';
  if (mode !== 'subscribe') return { ok: false, status: 403, error: 'unsupported_hub_mode' };
  if (!secretEquals(expectedToken, token)) {
    return { ok: false, status: 403, error: 'verify_token_mismatch' };
  }
  // Meta's challenge is its own value; bound it so a caller who somehow knew
  // the token could not use this endpoint to reflect an arbitrary body.
  if (!/^[A-Za-z0-9_-]{1,256}$/.test(challenge)) {
    return { ok: false, status: 400, error: 'invalid_hub_challenge' };
  }
  return { ok: true, challenge };
}

/* ---------------------------------------------------------------------------
 * POST — X-Hub-Signature-256.
 *
 * Meta signs the RAW request body with the Meta APP SECRET (not the access
 * token, not the verify token) and sends `sha256=<hex>`. The body must be
 * hashed exactly as received: re-serialising parsed JSON changes the bytes and
 * every signature then fails, which is the classic way to lose an afternoon.
 * ------------------------------------------------------------------------- */

export async function hmacSha256Hex(secret, body) {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(body));
  return [...new Uint8Array(signature)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function signatureValid(header, rawBody, appSecret) {
  if (!appSecret || typeof header !== 'string' || !header) return false;
  const prefix = 'sha256=';
  if (!header.startsWith(prefix)) return false;
  const supplied = header.slice(prefix.length).trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(supplied)) return false;
  const expected = await hmacSha256Hex(appSecret, rawBody);
  return secretEquals(expected, supplied);
}

/* ---------------------------------------------------------------------------
 * Envelope summary — observability only.
 *
 * Reads the ids a human needs in order to find a delivery later. It makes NO
 * routing decision and deliberately never looks at phone numbers or message
 * text: with a single Peekaa-owned sender there is no phone_number_id -> tenant
 * mapping yet, and inventing one here is exactly the assumption this phase was
 * told not to make.
 *
 * Every field is best-effort. An unrecognised shape yields kind 'other' with
 * null ids, which still stores and still returns 200 — a webhook that rejects
 * an undocumented field is a webhook Meta eventually disables.
 * ------------------------------------------------------------------------- */

function boundedId(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 64 ? value : null;
}

export function summariseEnvelope(payload) {
  const summary = { wabaId: null, phoneNumberId: null, entryKinds: [], metaMessageIds: [] };
  const kinds = new Set();
  const ids = new Set();
  const entries = Array.isArray(payload?.entry) ? payload.entry : [];

  for (const entry of entries) {
    summary.wabaId = summary.wabaId ?? boundedId(entry?.id);
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const value = change?.value;
      summary.phoneNumberId = summary.phoneNumberId
        ?? boundedId(value?.metadata?.phone_number_id);
      let matched = false;
      for (const key of ['statuses', 'messages']) {
        const rows = value?.[key];
        if (!Array.isArray(rows)) continue;
        matched = true;
        kinds.add(key);
        for (const row of rows) {
          const id = boundedId(row?.id);
          if (id) ids.add(id);
        }
      }
      if (!matched) kinds.add('other');
    }
    if (changes.length === 0) kinds.add('other');
  }
  if (entries.length === 0) kinds.add('other');

  // Bounded so a malformed or hostile body cannot make these arrays unbounded.
  // The full envelope is stored in payload regardless, so nothing is lost.
  summary.entryKinds = [...kinds].slice(0, 8);
  summary.metaMessageIds = [...ids].slice(0, 200);
  return summary;
}
