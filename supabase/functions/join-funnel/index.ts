/* nestly_v610 — scan-journey funnel telemetry (diagnosis instrumentation, owner-directed).
 *
 * The production trace for the real customer's phone currently ends at
 * "business lookup 200 -> UNKNOWN". This endpoint exists to name UNKNOWN: the /join page and
 * the app emit one event per funnel boundary, correlated by a random per-scan id, and this
 * function writes each one as a single console line so the whole journey can be read back
 * from function_edge_logs with:
 *   select timestamp, event_message from logs where source='function_edge_logs'
 *    and event_message like 'JOIN_FUNNEL%' order by timestamp
 *
 * No table of its own, no PII joined to a person; the raw join token is never accepted and
 * every request-derived string is capped and sanitised before it reaches the log line (see
 * join-funnel-boundaries.mjs). It IS on the shared gateway rate limiter now (nestly_w4b1
 * hardening -- this was anon-reachable behind only a per-isolate counter that resets on
 * isolate recycle, which is not a real ceiling). Delete the function when the diagnosis is
 * done.
 */
import { enforceRateLimit } from '../_shared/gateway.ts';
import { handleJoinFunnelRequest } from '../_shared/join-funnel-boundaries.mjs';

const EVENTS = new Set([
  'join_page_loaded',
  'join_token_received',
  'join_business_lookup_started',
  'join_business_lookup_succeeded',
  'join_business_lookup_failed',
  'join_confirmation_render_attempted',
  'join_confirmation_visible',
  'join_yes_pointerdown',
  'join_yes_click',
  'join_pending_scan_saved',
  'join_navigation_started',
  'join_app_loaded',
  'join_pending_scan_found',
  'join_auth_screen_shown',
  'join_auth_completed',
  'join_rpc_started',
  'join_rpc_succeeded',
  'join_rpc_failed',
  'join_business_visible',
  'join_client_error',
  'join_inapp_scan_opened',
  'join_inapp_scan_result',
]);

const ORIGINS = new Set(['https://www.peekaa.asia', 'https://peekaa.asia']);

/* Per-isolate soft limit -- enough for any real diagnosis session, cheap to flood-proof.
   Isolates recycle, so this is a brake, not an accounting system. */
let served = 0;
const SERVE_CAP = 4000;

function cors(origin: string) {
  return {
    'access-control-allow-origin': ORIGINS.has(origin) ? origin : 'https://www.peekaa.asia',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'content-type',
    'access-control-max-age': '86400',
  };
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== 'POST' || !ORIGINS.has(origin)) return new Response(null, { status: 403 });
  if (served >= SERVE_CAP) return new Response(null, { status: 204, headers: cors(origin) });
  served += 1;
  try {
    /* Everything that decides what gets logged -- sanitising every request-derived string,
       validating cid/event, and building the one JSON-encoded log line -- lives in
       join-funnel-boundaries.mjs so it can be exercised directly in a Node test. What stays
       here is Deno-only glue: the real request body, and the real rate limiter (a cross-isolate
       DB round trip keyed on the authoritative client IP, the same
       ipHash(authoritativeClientIp(...)) path public-join uses), which replaces the per-isolate
       `served` counter above as the actual ceiling. `served`/SERVE_CAP stays as a cheap extra
       brake within one isolate's lifetime; it was never sufficient alone. */
    await handleJoinFunnelRequest({
      rawText: await req.text(),
      isValidCid: (cid: string) => /^[A-Za-z0-9-]{8,64}$/.test(cid),
      isValidEvent: (event: string) => EVENTS.has(event),
      checkRateLimit: () => enforceRateLimit(req, 'join-funnel', 120, 60),
      log: (line: string) => console.log(line),
    });
  } catch {
    /* telemetry must never fail loudly */
  }
  return new Response(null, { status: 204, headers: cors(origin) });
});
