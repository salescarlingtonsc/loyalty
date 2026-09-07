/* nestly_w4b1 — join-funnel body handling, extracted so it runs (and is tested) in plain
 * Node, exactly as whatsapp-webhook-boundaries.mjs / customer-push-boundaries.mjs do for their
 * own edge functions: the Deno-only glue (Deno.serve, the real rate limiter's DB round trip)
 * stays in supabase/functions/join-funnel/index.ts, which imports this file; everything that
 * decides what gets logged lives here where a Node test can call it directly with fakes.
 */

/* Strip the full C0 and C1 control-character ranges (covers \r \n \t and everything else that
 * could put a real line break, or an ANSI/terminal escape, into an edge log line), collapse
 * whatever whitespace is left to single spaces, then cap length. This is the only thing that
 * stands between a caller-supplied `detail` and forging a fake JOIN_FUNNEL log line. */
export function sanitiseJoinFunnelLogField(value, maxLen) {
  return String(value ?? '')
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, maxLen);
}

/* JSON-encoding the whole record is the second, independent guarantee: even if a future
 * control character slipped past sanitiseJoinFunnelLogField, JSON.stringify turns an embedded
 * newline into the two literal characters `\` and `n`, never a real line break — so the log
 * line this produces is always exactly one line no matter what the field sanitiser missed. */
export function buildJoinFunnelLogLine({ cid, event, at, detail }) {
  return `JOIN_FUNNEL ${JSON.stringify({ cid, event, at, detail })}`;
}

/* The whole POST-body pipeline. The real rate limiter (gateway.ts's enforceRateLimit, a DB
 * round trip) and the real event/cid validators are injected so this can run in Node against
 * fakes; index.ts wires the real ones. Every code path is a plain outcome tag, never a thrown
 * error and never a raw console.log call from inside here — the caller decides what to log and
 * when, via the `log` callback, so a test can capture it without touching process.stdout. */
export async function handleJoinFunnelRequest({ rawText, isValidCid, isValidEvent, checkRateLimit, log }) {
  const limit = await checkRateLimit();
  if (!limit || !limit.allowed) return { outcome: 'rate_limited' };

  let body;
  try {
    body = JSON.parse(String(rawText).slice(0, 4000));
  } catch {
    return { outcome: 'parse_error' };
  }

  const cid = sanitiseJoinFunnelLogField(body?.cid, 64);
  const event = sanitiseJoinFunnelLogField(body?.event, 64);
  const at = Number(body?.at) || 0;
  const detail = sanitiseJoinFunnelLogField(body?.detail, 1400);

  if (!isValidCid(cid) || !isValidEvent(event)) return { outcome: 'rejected' };

  const line = buildJoinFunnelLogLine({ cid, event, at, detail });
  log(line);
  return { outcome: 'logged', line };
}
