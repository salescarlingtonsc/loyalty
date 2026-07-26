import { createClient } from 'npm:@supabase/supabase-js@2.110.7';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

function env(name: string): string {
  return Deno.env.get(name) || '';
}

function secretKey(): string {
  const current = env('SUPABASE_SECRET_KEYS');
  if (current) {
    const keys = JSON.parse(current);
    if (typeof keys.default === 'string' && keys.default) return keys.default;
  }
  const legacy = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!legacy) throw new Error('billing service unavailable');
  return legacy;
}

export function billingAdminClient() {
  const url = env('SUPABASE_URL');
  if (!url) throw new Error('billing service unavailable');
  return createClient(url, secretKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function billingJson(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function allowedOrigins(): string[] {
  return (env('PUBLIC_GATEWAY_ALLOWED_ORIGINS') || '')
    .split(',')
    .map((value) => value.trim())
    .filter((value) => {
      try {
        const parsed = new URL(value);
        return (
          parsed.origin === value &&
          parsed.protocol === 'https:' &&
          !parsed.username &&
          !parsed.password
        );
      } catch {
        return false;
      }
    });
}

export function billingCorsFor(req: Request): Record<string, string> | null {
  const origin = req.headers.get('origin') || '';
  if (!origin || !allowedOrigins().includes(origin)) return null;
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-headers':
      'authorization, content-type, apikey, x-client-info',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-max-age': '600',
    vary: 'Origin',
  };
}

export function billingCorsJson(
  req: Request,
  status: number,
  body: unknown,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...(billingCorsFor(req) || {}) },
  });
}

export function billingPreflight(req: Request): Response | null {
  if (req.method !== 'OPTIONS') return null;
  const cors = billingCorsFor(req);
  return cors
    ? new Response(null, { status: 204, headers: cors })
    : billingJson(403, { error: 'origin_not_allowed' });
}

export async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function authenticatedUserId(req: Request): Promise<string> {
  const authorization = req.headers.get('authorization') || '';
  const match = authorization.match(/^Bearer\s+(\S+)$/i);
  if (!match) throw new Error('authentication required');
  const { data, error } = await billingAdminClient().auth.getUser(match[1]);
  const userId = data?.user?.id || '';
  if (
    error ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)
  ) {
    throw new Error('authentication required');
  }
  return userId;
}

export function requiredEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error('billing service unavailable');
  return value;
}
