/* v557/v581 — one-purpose admin plane: create/check Peekaa's UTILITY templates.
 *
 * Owner approved the appointment pair 2026-08-27 (amended same day because Meta
 * forbids a body that STARTS with a variable, subcode 2388299 — the business
 * name moved inside the sentence). Owner approved the short-notice reminder and
 * the reschedule notice 2026-08-28, wording supplied verbatim.
 *
 * The definitions live HERE, in code, so nothing outside this function can
 * submit arbitrary templates to Meta. Callable only with the internal dispatch
 * secret (same trust plane as the sender); the browser has no path here.
 *
 * SUBMITTING A TEMPLATE ACTIVATES NOTHING. The sender refuses any kind whose
 * whatsapp_template_registry_v551 row is not 'approved', and Meta — not this
 * function and not Peekaa — decides when that becomes true.
 *
 * NEVER LOGGED: the access token. Responses carry Meta's status fields only.
 */
const GRAPH = 'https://graph.facebook.com/v23.0';
const WABA_ID = '1725929281961827';

const TEMPLATES = [
  {
    key: 'appointment_confirmation',
    name: 'peekaa_appt_confirmation',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: 'Your appointment with {{1}} is confirmed — {{2}} on {{3}}. Reply to this chat if you need to change it.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', 'Fri 29 Aug, 3:00 PM']] },
    }],
  },
  {
    key: 'appointment_reminder',
    name: 'peekaa_appt_reminder',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: 'Reminder from {{1}} — {{2}} tomorrow at {{3}}. See you soon! Reply here to reschedule.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', '3:00 PM']] },
    }],
  },
  {
    // Owner wording 2026-08-28. Transactional only: no offer, no upsell.
    key: 'appointment_reminder_short',
    name: 'peekaa_appt_reminder_today',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: 'Reminder from {{1}}: {{2}} is today at {{3}}. We look forward to seeing you.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', '3:00 PM']] },
    }],
  },
  {
    // Owner wording 2026-08-28. Deliberately does NOT invite a reply: Peekaa
    // should not make an inbound conversation the primary workflow. The business
    // name appears twice on purpose — the customer is told who changed it and
    // who to contact. If Meta refuses a repeated placeholder, the fallback below
    // says the same thing with each variable used once.
    key: 'appointment_updated',
    name: 'peekaa_appt_updated',
    language: 'en',
    category: 'UTILITY',
    components: [{
      type: 'BODY',
      text: 'Update from {{1}}: Your appointment for {{2}} has been changed to {{3}}. Please contact {{1}} if this timing does not work for you.',
      example: { body_text: [['Cubbly SPA', 'Relax Massage 60 min', 'Sat 30 Aug, 11:00 AM']] },
    }],
    // Same meaning, no repeated placeholder, still no invitation to reply.
    fallbackText: 'Update from {{1}}: Your appointment for {{2}} has been changed to {{3}}. Please contact the shop if this timing does not work for you.',
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

function metaErr(body: Record<string, unknown> | null) {
  const e = (body as { error?: Record<string, unknown> } | null)?.error;
  if (!e) return null;
  return {
    code: e.code, subcode: e.error_subcode || null,
    message: String(e.message || '').slice(0, 300),
    user_title: String(e.error_user_title || '').slice(0, 300),
    user_msg: String(e.error_user_msg || '').slice(0, 600),
  };
}

async function submit(token: string, t: Record<string, unknown>, text: string) {
  const payload = {
    name: t.name, language: t.language, category: t.category,
    components: [{ ...(t.components as Record<string, unknown>[])[0], text }],
  };
  const r = await fetch(`${GRAPH}/${WABA_ID}/message_templates`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = await r.json().catch(() => ({}));
  return { http: r.status, body };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  if (!authorized(req)) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const token = Deno.env.get('WHATSAPP_ACCESS_TOKEN') || '';
  if (!token) return Response.json({ error: 'send_credentials_unconfigured' }, { status: 503 });

  let payload: { action?: string; keys?: string[] } = {};
  try { payload = await req.json(); } catch { /* default */ }
  const action = payload?.action || 'status';
  const wanted = Array.isArray(payload.keys) && payload.keys.length
    ? TEMPLATES.filter((t) => (payload.keys as string[]).includes(t.key))
    : TEMPLATES;

  if (action === 'create') {
    const results: Record<string, unknown>[] = [];
    for (const t of wanted) {
      const primary = (t.components as Record<string, unknown>[])[0].text as string;
      let attempt = await submit(token, t as Record<string, unknown>, primary);
      let usedFallback = false;
      // Only a wording refusal is retried, and only with the wording recorded
      // above — never with anything this function invents at run time.
      if (attempt.http >= 400 && t.fallbackText) {
        attempt = await submit(token, t as Record<string, unknown>, t.fallbackText);
        usedFallback = true;
      }
      results.push({
        key: t.key, name: t.name, http: attempt.http,
        submitted_body: usedFallback ? t.fallbackText : primary,
        used_fallback: usedFallback,
        id: (attempt.body as { id?: string })?.id || null,
        status: (attempt.body as { status?: string })?.status || null,
        error: metaErr(attempt.body),
      });
    }
    return Response.json({ action, results });
  }

  const names = TEMPLATES.map((t) => t.name);
  const r = await fetch(`${GRAPH}/${WABA_ID}/message_templates?fields=name,status,category,language,quality_score&limit=100`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const body = await r.json().catch(() => ({}));
  const rows = Array.isArray((body as { data?: unknown[] })?.data)
    ? (body as { data: Array<{ name?: string }> }).data.filter((d) => names.includes(String(d?.name || '')))
    : [];
  return Response.json({ action, http: r.status, templates: rows, error: metaErr(body) });
});
