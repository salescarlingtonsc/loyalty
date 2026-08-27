/* v557 — one-purpose admin plane: create/check the two C7 utility templates.
 *
 * Owner approved the exact wording 2026-08-27. The definitions live HERE, in
 * code, so nothing outside this function can submit arbitrary templates to
 * Meta. Callable only with the internal dispatch secret (same trust plane as
 * the sender); the browser has no path to this function.
 *
 * NEVER LOGGED: the access token. Responses carry Meta's status fields only.
 */
const GRAPH = 'https://graph.facebook.com/v23.0';
const WABA_ID = '1725929281961827';

const TEMPLATES = [
  {
    name: 'peekaa_appt_confirmation',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: '{{1}}: Your appointment is confirmed — {{2}} on {{3}}. Reply to this chat if you need to change it.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', 'Fri 29 Aug, 3:00 PM']] },
    }],
  },
  {
    name: 'peekaa_appt_reminder',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: '{{1}}: Reminder — {{2}} tomorrow at {{3}}. See you soon! Reply here to reschedule.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', '3:00 PM']] },
    }],
  },
];

function authorized(req: Request): boolean {
  const expected = Deno.env.get('WHATSAPP_DISPATCH_SECRET') || '';
  const supplied = req.headers.get('x-peekaa-whatsapp-dispatch-secret') || '';
  if (expected.length < 32 || supplied.length !== expected.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i += 1) mismatch |= expected.charCodeAt(i) ^ supplied.charCodeAt(i);
  return mismatch === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  if (!authorized(req)) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const token = Deno.env.get('WHATSAPP_ACCESS_TOKEN') || '';
  if (!token) return Response.json({ error: 'send_credentials_unconfigured' }, { status: 503 });

  let action = 'status';
  try { action = (await req.json())?.action || 'status'; } catch { /* default */ }

  if (action === 'create') {
    const results: Record<string, unknown>[] = [];
    for (const t of TEMPLATES) {
      const r = await fetch(`${GRAPH}/${WABA_ID}/message_templates`, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(t),
      });
      const body = await r.json().catch(() => ({}));
      results.push({
        name: t.name, http: r.status,
        id: body?.id || null, status: body?.status || null,
        error: body?.error ? { code: body.error.code, subcode: body.error.error_subcode || null, message: String(body.error.message || '').slice(0, 300) } : null,
      });
    }
    return Response.json({ action, results });
  }

  /* status: read back what Meta holds for our two names */
  const names = TEMPLATES.map((t) => t.name).join(',');
  const r = await fetch(`${GRAPH}/${WABA_ID}/message_templates?fields=name,status,category,language,quality_score&limit=50`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const body = await r.json().catch(() => ({}));
  const rows = Array.isArray(body?.data) ? body.data.filter((d: { name?: string }) => names.includes(String(d?.name || ''))) : [];
  return Response.json({ action, http: r.status, templates: rows, error: body?.error ? { code: body.error.code, message: String(body.error.message || '').slice(0, 300) } : null });
});
