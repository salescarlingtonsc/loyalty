/* nestly_v610 — scan-journey funnel telemetry (diagnosis instrumentation, owner-directed).
 *
 * The production trace for the real customer's phone currently ends at
 * "business lookup 200 → UNKNOWN". This endpoint exists to name UNKNOWN: the /join page and
 * the app emit one event per funnel boundary, correlated by a random per-scan id, and this
 * function writes each one as a single console line so the whole journey can be read back
 * from function_edge_logs with:
 *   select timestamp, event_message from logs where source='function_edge_logs'
 *    and event_message like 'JOIN_FUNNEL%' order by timestamp
 *
 * Deliberately log-only: no database table, no migration, nothing joined to a person.
 * The correlation id is random per scan; the raw join token is never accepted; detail is a
 * capped string. Delete the function when the diagnosis is done.
 */
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

/* Per-isolate soft limit — enough for any real diagnosis session, cheap to flood-proof.
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
    const body = JSON.parse((await req.text()).slice(0, 4000));
    const cid = String(body?.cid || '');
    const event = String(body?.event || '');
    const at = Number(body?.at) || 0;
    const detail = String(body?.detail || '').slice(0, 1400);
    if (!/^[A-Za-z0-9-]{8,64}$/.test(cid) || !EVENTS.has(event)) {
      return new Response(null, { status: 204, headers: cors(origin) });
    }
    /* One line per event; the correlation id groups a whole scan journey. */
    console.log(`JOIN_FUNNEL cid=${cid} event=${event} at=${at} detail=${detail}`);
  } catch {
    /* telemetry must never fail loudly */
  }
  return new Response(null, { status: 204, headers: cors(origin) });
});
