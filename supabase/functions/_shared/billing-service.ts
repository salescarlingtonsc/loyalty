import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import { publicGatewayOrigins } from './validation.ts';

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
  return publicGatewayOrigins(env('PUBLIC_GATEWAY_ALLOWED_ORIGINS'));
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

/* V208: this used to throw one undifferentiated Error, which the callers turn into a bare 401.
   A branch purchase failed in production with exactly that 401 and there was no way to tell
   whether the browser sent no token, the token was rejected, or the function's own service key
   was missing — three completely different faults with one indistinguishable symptom. The reason
   is now on the thrown error so the caller can report it. It names the FAULT, never the token. */
export async function authenticatedUserId(req: Request): Promise<string> {
  const authorization = req.headers.get('authorization') || '';
  const match = authorization.match(/^Bearer\s+(\S+)$/i);
  if (!match) throw new Error('auth_no_bearer_token');
  let admin;
  try {
    admin = billingAdminClient();
  } catch {
    throw new Error('auth_service_key_unavailable');
  }
  const { data, error } = await admin.auth.getUser(match[1]);
  const userId = data?.user?.id || '';
  if (error) throw new Error('auth_token_rejected');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    throw new Error('auth_user_id_unusable');
  }
  return userId;
}

export function requiredEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error('billing service unavailable');
  return value;
}
