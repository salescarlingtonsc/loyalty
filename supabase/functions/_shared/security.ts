const encoder = new TextEncoder();

function base64Url(bytes: Uint8Array) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

// A booking `preferred`/`proposed` value usually arrives as a bare `datetime-local` string
// ("YYYY-MM-DDTHH:mm[:ss]") with no zone — Frenly is SG-first, so that means Singapore wall-clock
// time, not the Deno runtime's UTC. Anchor it to +08:00 before parsing. A value that already
// carries a zone (a trailing Z, or a +hh:mm/-hh:mm offset) is left exactly as written.
function sgAnchoredIso(value: string): string {
  const raw = String(value ?? '').trim();
  const hasZone = /Z$|[+-]\d{2}:?\d{2}$/.test(raw);
  return new Date(hasZone ? raw : `${raw}+08:00`).toISOString();
}

export async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function deriveManagementToken(secret: string, slug: string, submissionId: string) {
  if (encoder.encode(secret).length < 32) throw new Error('gateway unavailable');
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const message = `frenly:booking-management:v1\0${slug}\0${submissionId}`;
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  return base64Url(new Uint8Array(signature));
}

export function canonicalBookingRequest(input: Record<string, unknown>) {
  const request: Record<string, unknown> = {
    slug: String(input.slug || ''),
    name: String(input.name || '').trim(),
    email: input.email ? String(input.email).trim() : null,
    phone: input.phone ? String(input.phone) : null,
    service: input.service || null,
    party: Number(input.party),
    preferred: sgAnchoredIso(String(input.preferred)),
    notes: input.notes ? String(input.notes).trim() : null,
    table_type: input.table_type || null,
    consent: input.consent === true,
  };
  // v183: a requested team member is part of what the customer asked for, so two submissions
  // that differ only by person are different requests. The key is appended ONLY when present,
  // so every pre-v183 payload still hashes to exactly its original fingerprint and an
  // in-flight retry across the deploy boundary is still recognised as a replay.
  if (input.staff) request.staff = String(input.staff);
  // v327: same reasoning, for a requested branch.
  if (input.branch) request.branch = String(input.branch);
  return request;
}

export function canonicalBookingChange(input: Record<string, unknown>) {
  return {
    kind: String(input.kind || ''),
    proposed: input.proposed ? sgAnchoredIso(String(input.proposed)) : null,
    note: input.note ? String(input.note).trim() : null,
  };
}

export async function bookingRequestFingerprint(
  input: Record<string, unknown>,
  authenticatedUserId: string | null = null,
) {
  const request = canonicalBookingRequest(input);
  // Keep the v1 guest fingerprint byte-for-byte so pre-v72 guest retries remain
  // valid. Authenticated requests use a domain-separated v2 fingerprint whose
  // identity is supplied only after server-side bearer validation.
  if (!authenticatedUserId) {
    return sha256Hex(`frenly:booking-request:v1\0${JSON.stringify(request)}`);
  }
  return sha256Hex(`frenly:booking-request:v2\0${JSON.stringify({
    ...request,
    authenticated_user_id: authenticatedUserId,
  })}`);
}

export async function bookingChangeFingerprint(input: Record<string, unknown>) {
  return sha256Hex(`frenly:booking-change:v1\0${JSON.stringify(canonicalBookingChange(input))}`);
}

export function idempotencyDecision(storedFingerprint: string, incomingFingerprint: string) {
  return storedFingerprint === incomingFingerprint ? 'replay' : 'conflict';
}

export function gatewayAuthorization(header: string | null, guestBearerKeys: string[] = []) {
  if (header === null) return { kind: 'guest' as const, token: null };
  if (header.length > 4096) return { kind: 'invalid' as const, token: null };
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return { kind: 'invalid' as const, token: null };
  const token = header.slice(prefix.length);
  const configuredGuests = new Set(guestBearerKeys.filter((key) => typeof key === 'string' && key.length > 0));
  if (configuredGuests.has(token)) return { kind: 'guest' as const, token: null };
  if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){2}$/.test(token)) {
    return { kind: 'invalid' as const, token: null };
  }
  return { kind: 'user' as const, token };
}

export function turnstileBindingValid(
  result: Record<string, unknown>,
  expectedAction: string,
  expectedHostname: string,
  testMode = false,
) {
  if (result?.success !== true) return false;
  if (testMode) return result.action === 'test' && result.hostname === 'localhost';
  return result.action === expectedAction
    && String(result.hostname || '').toLowerCase() === expectedHostname.toLowerCase();
}

function isIpv4(value: string) {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
}

function isIpv6(value: string) {
  if (!value.includes(':') || value.length > 45 || value.includes('%')) return false;
  const halves = value.split('::');
  if (halves.length > 2) return false;
  const groups = (half: string) => {
    if (!half) return [];
    const parts = half.split(':');
    if (parts.some((part) => !part)) return null;
    const last = parts.at(-1) || '';
    if (last.includes('.')) {
      if (!isIpv4(last)) return null;
      parts.splice(-1, 1, '0', '0');
    }
    return parts.every((part) => /^[0-9a-f]{1,4}$/i.test(part)) ? parts : null;
  };
  const left = groups(halves[0]);
  const right = groups(halves[1] || '');
  if (!left || !right) return false;
  const count = left.length + right.length;
  return halves.length === 2 ? count < 8 : count === 8;
}

export function authoritativeClientIp(headers: Headers) {
  // Supabase Edge Functions sit behind Cloudflare, which sets `cf-connecting-ip` to the
  // true connecting client and overwrites any client-supplied value, giving a stable,
  // non-spoofable per-client key. The rightmost `X-Forwarded-For` entry is an internal
  // edge/relay node that rotates per request (observed: many distinct AWS IPs for a
  // single client), so it must NOT key the limiter. When the trusted header is absent we
  // fall back to a single shared `unknown` bucket rather than trusting `X-Forwarded-For`.
  const cf = (headers.get('cf-connecting-ip') || '').trim().toLowerCase();
  return isIpv4(cf) || isIpv6(cf) ? cf : 'unknown';
}
