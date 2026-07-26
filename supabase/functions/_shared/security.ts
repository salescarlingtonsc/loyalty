const encoder = new TextEncoder();

function base64Url(bytes: Uint8Array) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
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
  return {
    slug: String(input.slug || ''),
    name: String(input.name || '').trim(),
    email: input.email ? String(input.email).trim() : null,
    phone: input.phone ? String(input.phone) : null,
    service: input.service || null,
    party: Number(input.party),
    preferred: new Date(String(input.preferred)).toISOString(),
    notes: input.notes ? String(input.notes).trim() : null,
    table_type: input.table_type || null,
    consent: input.consent === true,
  };
}

export function canonicalBookingChange(input: Record<string, unknown>) {
  return {
    kind: String(input.kind || ''),
    proposed: input.proposed ? new Date(String(input.proposed)).toISOString() : null,
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
