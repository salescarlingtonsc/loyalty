/* v557/v581 — one-purpose admin plane: create/check Peekaa's templates.
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
 * nestly_v899: and 'reconcile' is how that decision reaches the database. Until it
 * existed, 'status' asked Meta and told the caller — a read with no writer — so an
 * approval only landed in the registry if a human noticed and typed it in. Twice one
 * did not, and v898 found two templates our own gate had been refusing for seventeen
 * days. Reconcile writes what Meta said, updates only, never inserts, and never
 * touches the body or the parameter contract.
 *
 * NEVER LOGGED: the access token. Responses carry Meta's status fields only.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import { reconcileTemplateStatuses } from '../_shared/whatsapp-template-status-boundaries.mjs';

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
  {
    /* nestly_v894 — the sign-up verification code, and the first AUTHENTICATION template Peekaa
       has. Meta writes the copy for this category, not us: the body text is fixed and localised
       by Meta, we only choose whether the security line appears, how the expiry is worded, and
       what the button says. That is why this entry has no `text` and no `example` — supplying
       either is what gets an authentication template refused.

       The button is not decoration. Meta requires an authentication template to carry a COPY_CODE
       or one-tap button, and the sender must then pass the code TWICE (body parameter and button
       parameter) — see buildOtpTemplateSend in _shared/whatsapp-otp-boundaries.mjs. */
    key: 'signup_otp',
    name: 'peekaa_signup_otp',
    language: 'en',
    category: 'AUTHENTICATION',
    components: [
      { type: 'BODY', add_security_recommendation: true },
      { type: 'FOOTER', code_expiration_minutes: 5 },
      { type: 'BUTTONS', buttons: [{ type: 'OTP', otp_type: 'COPY_CODE', text: 'Copy code' }] },
    ],
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

async function submit(token: string, t: Record<string, unknown>, text: string | undefined) {
  const components = t.components as Record<string, unknown>[];
  /* nestly_v894: a UTILITY template is one BODY whose wording this function substitutes (that is
     what the fallback retry needs). An AUTHENTICATION template has three components and no body
     text of ours at all, so it is submitted verbatim. The `text === undefined` test is the
     difference between the two, and it is the template definition above that decides it. */
  const payload = {
    name: t.name, language: t.language, category: t.category,
    components: typeof text === 'string'
      ? [{ ...components[0], text }, ...components.slice(1)]
      : components,
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
      const primary = (t.components as Record<string, unknown>[])[0].text as string | undefined;
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
  const allMetaRows = Array.isArray((body as { data?: unknown[] })?.data)
    ? (body as { data: Array<{ name?: string }> }).data
    : [];
  const rows = allMetaRows.filter((d) => names.includes(String(d?.name || '')));

  if (action !== 'reconcile') {
    return Response.json({ action, http: r.status, templates: rows, error: metaErr(body) });
  }

  /* nestly_v899. A reconcile that ran on a FAILED read would conclude that every template had
     vanished from Meta and pause the lot, which is the one outcome worse than the drift it exists
     to fix. So: refuse unless Meta actually answered. */
  if (!r.ok) {
    return Response.json(
      { action, http: r.status, reconciled: false, reason: 'meta_read_failed', error: metaErr(body) },
      { status: 502 },
    );
  }

  /* An empty list from a 200 is not evidence that every template was deleted — it is far more
     likely a scoping or permission oddity on the read. Pausing the entire lane on that reading is
     the same destructive mistake as reconciling from a failed call, so it gets the same refusal. */
  if (allMetaRows.length === 0) {
    return Response.json(
      { action, http: r.status, reconciled: false, reason: 'meta_returned_no_templates' },
      { status: 502 },
    );
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL') || '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const { data: registry, error: registryError } = await admin
    .from('whatsapp_template_registry_v551')
    .select('template_key, meta_name, status');
  if (registryError || !Array.isArray(registry)) {
    return Response.json({ action, reconciled: false, reason: 'registry_read_failed' }, { status: 503 });
  }

  /* nestly_v900, and this line is the whole of the bug it fixes. Reconcile used to be handed
     `rows` — Meta's list ALREADY filtered down to the TEMPLATES array above. That array is this
     function's submission catalogue, not the registry: peekaa_bring_back_v1 is registered by
     migration v551 and has never appeared in it. So the first live reconcile saw a Meta list with
     bring_back missing, concluded it had been deleted at Meta, and paused a template Meta had
     approved. Fail-closed, and caught within a minute, but wrong.
     `allMetaRows` is what Meta actually said. reconcileTemplateStatuses already ignores names the
     registry does not hold, so the registry — the thing being reconciled — decides what matters,
     and "absent from Meta" now means absent from META. */
  const plan = reconcileTemplateStatuses(allMetaRows, registry);
  const { data: result, error: writeError } = await admin.rpc(
    'internal_whatsapp_template_reconcile_v899',
    { p_observations: plan.observations },
  );
  if (writeError || !result?.ok) {
    return Response.json({ action, reconciled: false, reason: 'reconcile_write_failed' }, { status: 503 });
  }

  /* absent_at_meta, unrecognised and ignored are reported rather than buried: each one is a
     question for a human (a template deleted at Meta, a status Meta added since this was written,
     a template created in Business Manager that Peekaa does not know about). */
  return Response.json({
    action,
    http: r.status,
    reconciled: true,
    changed: result.changed,
    changed_count: result.changed_count,
    unmappable: result.unmappable,
    absent_at_meta: plan.absentAtMeta,
    unrecognised_meta_status: plan.unrecognised,
    ignored_unregistered: plan.ignored,
  });
});
