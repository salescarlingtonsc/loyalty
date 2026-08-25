/* v504 — Meta WhatsApp Cloud API webhook helpers.
 *
 * Every decision worth testing lives in whatsapp-webhook-boundaries.mjs and is
 * re-exported here, exactly as customer-push.ts re-exports from
 * customer-push-boundaries.mjs. What stays in this file is the handful of
 * things that genuinely need the Deno runtime.
 */
export {
  MIN_VERIFY_TOKEN_LENGTH,
  hmacSha256Hex,
  secretEquals,
  sha256Hex,
  signatureValid,
  summariseEnvelope,
  verificationOutcome,
} from './whatsapp-webhook-boundaries.mjs';

export function whatsappEnv(name: string): string {
  return Deno.env.get(name) || '';
}

export function whatsappJson(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}
