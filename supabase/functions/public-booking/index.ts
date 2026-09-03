import { adminClient, bookingRequestFingerprint, conflictError, deriveBookingManagementToken, enforceRateLimit, json, optionalAuthenticatedUserId, preflight, publicError, readJson, recordAccountOpen, requireOrigin, sha256Hex } from '../_shared/gateway.ts';
import { SLUG_PATTERN, UUID_PATTERN, validBookingPayload } from '../_shared/validation.ts';

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

Deno.serve(async (req) => {
  const options = preflight(req);
  if (options) return options;
  if (!requireOrigin(req) || !['GET', 'POST'].includes(req.method)) return publicError(req, 403);

  try {
    if (req.method === 'GET') {
      const params = new URL(req.url).searchParams;
      const slug = params.get('slug') || '';
      if (!SLUG_PATTERN.test(slug)) return publicError(req, 404);

      // v183: live availability for the customer-facing team + time steps. It is a read of the
      // same rows the business calendar uses, never a hold, and it is rate limited separately
      // because the portal refetches it whenever the customer changes service, person or day.
      if (params.get('availability') === '1') {
        const limit = await enforceRateLimit(req, 'booking-availability', 120, 60);
        if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });
        const service = params.get('service') || '';
        const staff = params.get('staff') || '';
        const branch = params.get('branch') || '';
        const from = params.get('from') || '';
        const days = Number(params.get('days') || '7');
        if ((service && !UUID_PATTERN.test(service)) || (staff && !UUID_PATTERN.test(staff))
          || (branch && !UUID_PATTERN.test(branch))) return publicError(req);
        if (from && !DATE_PATTERN.test(from)) return publicError(req);
        if (!Number.isInteger(days) || days < 1 || days > 14) return publicError(req);
        const { data, error } = await adminClient().rpc('internal_public_booking_availability', {
          p_slug: slug,
          p_service: service || null,
          p_staff: staff || null,
          p_from: from || null,
          p_days: days,
          // v327: the branch the customer picked, when this business has more than one.
          p_branch: branch || null,
        });
        if (error || !data) return publicError(req);
        /* v637: an availability read means the customer is picking a slot — funnel 'started'. */
        try { await adminClient().rpc('internal_public_funnel_hit_by_slug_v640', { p_slug: slug, p_surface: 'booking', p_step: 'started' }); } catch { /* ignore */ }
        return json(req, 200, data);
      }

      /* v234: read-only page fetch; raised to match booking-availability's 120/60 so a shared
         carrier IP cannot brown-out the booking page for everyone behind it. */
      const limit = await enforceRateLimit(req, 'booking-page', 120, 60);
      if (!limit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: limit.retry_after });
      const { data, error } = await adminClient().rpc('internal_public_booking_page', { p_slug: slug });
      if (error || !data) return publicError(req, 404);
      /* v637: identity-free funnel counter — telemetry never blocks the public surface. */
      try { await adminClient().rpc('internal_public_funnel_hit_by_slug_v640', { p_slug: slug, p_surface: 'booking', p_step: 'page_view' }); } catch { /* ignore */ }
      return json(req, 200, data);
    }

    const body = await readJson(req);
    /* v234 CGNAT headroom — see the note in public-join. Customers book from their own phones on
       shared carrier IPv4, so per-IP ceilings must not assume one IP is one person. This is now
       the OUTER of the two ceilings (see nestly_v747 below); the 30/600 write ceiling is the
       one that actually bounds abuse. */
    const abuseLimit = await enforceRateLimit(req, 'booking-submit-abuse', 150, 600);
    if (!abuseLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: abuseLimit.retry_after });
    /* nestly_v747 (owner directive 2026-09-03): Turnstile is REMOVED from the public booking
       path. This is the same ruling V388 already made for Supabase Auth, applied to the one
       remaining surface where it was costing real bookings: switching the widget to Invisible
       left it with no way to escalate to a checkbox, so any visitor Cloudflare was unsure about
       was hard-failed (client error code 600010) and could not book at all. A challenge that
       blocks paying customers is a worse outcome than the bots it stops.

       What still stands in front of this endpoint, unchanged: requireOrigin(), the 150/600
       'booking-submit-abuse' per-IP ceiling above, the 30/600 'booking-submit' per-IP WRITE
       ceiling below, the submission_id idempotency hash and the request fingerprint (so a
       replayed submit collapses instead of duplicating), and full server-side re-validation of
       tenant, service, staff and branch inside internal_public_booking_submit. public-join,
       public-support-ticket and public-business-application are NOT changed and still verify
       Turnstile server-side. body.turnstile_token is now ignored if a stale client sends it. */
    if (!validBookingPayload(body)) return publicError(req);
    let authenticatedUserId = null;
    try {
      authenticatedUserId = await optionalAuthenticatedUserId(req);
    } catch {
      return publicError(req, 401);
    }
    /* A duplicate submission is already collapsed by the submission_id
       fingerprint below, so this ceiling bounds distinct bookings per IP. Since nestly_v747 it
       is the primary abuse gate on this endpoint. */
    const writeLimit = await enforceRateLimit(req, 'booking-submit', 30, 600);
    if (!writeLimit.allowed) return json(req, 429, { error: 'Please wait before trying again.', retry_after: writeLimit.retry_after });

    const manageToken = await deriveBookingManagementToken(body.slug, body.submission_id);
    const tokenHash = await sha256Hex(manageToken);
    const idempotencyHash = await sha256Hex(String(body.submission_id));
    const requestFingerprint = await bookingRequestFingerprint(body, authenticatedUserId);
    const { data, error } = await adminClient().rpc('internal_public_booking_submit', {
      p_slug: body.slug,
      p_name: String(body.name).trim(),
      p_email: body.email ? String(body.email).trim() : null,
      p_phone: body.phone ? String(body.phone) : null,
      p_service: body.service || null,
      p_party: Number(body.party),
      p_preferred: body.preferred,
      p_notes: body.notes ? String(body.notes).trim() : null,
      p_table_type: body.table_type || null,
      p_consent: body.consent === true,
      p_token_hash: tokenHash,
      p_idempotency_hash: idempotencyHash,
      p_request_fingerprint: requestFingerprint,
      p_authenticated_user: authenticatedUserId,
      // v183: the requested team member. The database re-validates it against the tenant, the
      // customer-bookable flag and the service assignment before it is recorded.
      p_staff: body.staff || null,
      // v327: the requested branch. The database re-validates it against the tenant and its
      // active status, and that the requested staff member is actually assigned to it.
      p_branch: body.branch || null,
    });
    if (error || !data) return publicError(req);
    if (data.conflict) return conflictError(req);
    await recordAccountOpen('internal_record_account_open_booking_token_v175', { p_token_hash: tokenHash });
    /* v637: booking funnel completed. */
    try { await adminClient().rpc('internal_public_funnel_hit_by_slug_v640', { p_slug: body.slug, p_surface: 'booking', p_step: 'completed' }); } catch { /* ignore */ }
    return json(req, 200, { ...data, manage_token: manageToken });
  } catch {
    return publicError(req);
  }
});
