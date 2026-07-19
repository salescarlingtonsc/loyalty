import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import { normalizeOriginList } from './validation.ts';
import { authoritativeClientIp, deriveManagementToken, sha256Hex } from './security.ts';

import { turnstileBindingValid } from './security.ts';

export { authoritativeClientIp, bookingChangeFingerprint, bookingRequestFingerprint, deriveManagementToken, sha256Hex, turnstileBindingValid } from './security.ts';

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };

function env(name) {
  return Deno.env.get(name) || '';
}

function allowedOrigins() {
  return normalizeOriginList(env('PUBLIC_GATEWAY_ALLOWED_ORIGINS'));
}

export function corsFor(req) {
  const origin = req.headers.get('origin') || '';
  if (!origin || !allowedOrigins().includes(origin)) return null;
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-headers': 'content-type, x-client-info',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-max-age': '600',
    'vary': 'Origin',
  };
}

export function json(req, status, body) {
  const cors = corsFor(req) || {};
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...cors } });
}

export function preflight(req) {
  if (req.method !== 'OPTIONS') return null;
  const cors = corsFor(req);
  return cors ? new Response(null, { status: 204, headers: cors }) : json(req, 403, { error: 'request not allowed' });
}

export function requireOrigin(req) {
  return corsFor(req) !== null;
}

export async function readJson(req, maxBytes = 16384) {
  const length = Number(req.headers.get('content-length') || '0');
  if (length > maxBytes || !req.headers.get('content-type')?.toLowerCase().includes('application/json')) {
    throw new Error('invalid request');
  }
  const text = await req.text();
  if (new TextEncoder().encode(text).length > maxBytes) throw new Error('invalid request');
  return JSON.parse(text);
}

function secretKey() {
  const current = env('SUPABASE_SECRET_KEYS');
  if (current) {
    const keys = JSON.parse(current);
    if (keys.default) return keys.default;
  }
  const legacy = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!legacy) throw new Error('gateway unavailable');
  return legacy;
}

export function adminClient() {
  const url = env('SUPABASE_URL');
  if (!url) throw new Error('gateway unavailable');
  return createClient(url, secretKey(), { auth: { persistSession: false, autoRefreshToken: false } });
}

function turnstileConfig() {
  const siteKey = env('TURNSTILE_SITE_KEY');
  const secretKey = env('TURNSTILE_SECRET_KEY');
  if (!siteKey || !secretKey) throw new Error('gateway unavailable');
  const testSiteKeys = new Set([
    '1x00000000000000000000AA', '2x00000000000000000000AB',
    '1x00000000000000000000BB', '2x00000000000000000000BB',
    '3x00000000000000000000FF',
  ]);
  const testSecretKeys = new Set([
    '1x0000000000000000000000000000000AA',
    '2x0000000000000000000000000000000AA',
    '3x0000000000000000000000000000000AA',
  ]);
  const testSite = testSiteKeys.has(siteKey);
  const testSecret = testSecretKeys.has(secretKey);
  if (testSite !== testSecret) throw new Error('gateway unavailable');
  return { siteKey, secretKey, testMode: testSite && testSecret };
}

export function turnstileSiteKey() {
  return turnstileConfig().siteKey;
}

export async function deriveBookingManagementToken(slug, submissionId) {
  return deriveManagementToken(env('PUBLIC_GATEWAY_TOKEN_SECRET'), slug, submissionId);
}

export async function ipHash(req) {
  const pepper = env('PUBLIC_GATEWAY_IP_PEPPER');
  if (pepper.length < 32) throw new Error('gateway unavailable');
  return sha256Hex(`${pepper}\0${authoritativeClientIp(req.headers)}`);
}

export async function enforceRateLimit(req, scope, limit, windowSeconds, extraKey = '') {
  const baseHash = await ipHash(req);
  const keyHash = extraKey ? await sha256Hex(`${baseHash}\0${extraKey}`) : baseHash;
  const { data, error } = await adminClient().rpc('internal_gateway_rate_limit', {
    p_scope: scope,
    p_key_hash: keyHash,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (error || !data) throw new Error('gateway unavailable');
  return data;
}

export async function verifyTurnstile(req, token, expectedAction) {
  const { secretKey, testMode } = turnstileConfig();
  if (!token || String(token).length > 2048) return false;
  const origin = req.headers.get('origin') || '';
  let expectedHostname = '';
  try {
    expectedHostname = new URL(origin).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (!expectedAction || !/^[a-z_]{1,32}$/.test(expectedAction)) return false;
  if (testMode && !normalizeOriginList(env('TURNSTILE_TEST_ALLOWED_ORIGINS')).includes(origin)) return false;
  const form = new FormData();
  form.set('secret', secretKey);
  form.set('response', String(token));
  const clientIp = authoritativeClientIp(req.headers);
  if (clientIp !== 'unknown') form.set('remoteip', clientIp);
  const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST', body: form,
  });
  if (!response.ok) return false;
  const result = await response.json();
  return turnstileBindingValid(result, expectedAction, expectedHostname, testMode);
}

export function publicError(req, status = 400) {
  return json(req, status, { error: 'We could not process that request.' });
}

export function conflictError(req) {
  return json(req, 409, { error: 'This request conflicts with an earlier submission.' });
}
