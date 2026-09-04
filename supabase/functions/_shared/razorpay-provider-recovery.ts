/* nestly_v759 — the reconciliation run REPAIRS a paid subscription the webhook never delivered.

   The live incident this exists for: Razorpay retried subscription.activated / .authenticated /
   .charged for a real payment, every attempt was answered 400 (a secret rotation — see the
   rotation window in razorpay-client.ts), and after 24h Razorpay disabled the endpoint and
   stopped retrying. The money had moved; nothing local knew. Reconciliation saw it, recorded
   `missing_local`, and re-recorded it every night forever without ever closing it.

   The rules this module keeps:

   - It NEVER invents payment truth. Every field it writes comes from a fresh GET against the
     Razorpay REST API, and it writes nothing itself: it synthesises the exact webhook-shaped
     envelope Razorpay would have delivered and pushes it through the EXISTING pipeline
     (ingest_billing_event_v755 -> apply_razorpay_billing_event_v755). There is no second writer
     of billing truth, so every invariant the applier enforces — out-of-order rejection, the
     business mapping, the "already linked to another business" guards — applies unchanged.
   - It only recovers a subscription that is unambiguously PAID: 'active', or 'authenticated'
     with paid_count > 0. A 'created' or 'expired' subscription is an abandoned hosted checkout
     (v758) and stays classified pending_checkout; recovering one would fabricate a tenant.
   - It is idempotent. The event ids are deterministic (`recovery_<sub>_activated`,
     `recovery_<sub>_<payment>_charged`), so the inbox's unique(provider,event_id) collapses a
     re-run onto the same rows and reports duplicate:true. The apply is still called on a
     duplicate: the applier's own duplicate branch is a no-op that also re-converges workspace
     and branch activation, so a run that died between ingest and apply heals on the next pass.
   - It is bounded and never fails the run. At most PROVIDER_RECOVERY_MAX_PER_RUN per run, and a
     failure is a counter in the summary, because an integrity run that dies on one bad
     subscription stops checking every other tenant. */

export const PROVIDER_RECOVERY_MAX_PER_RUN = 10;

export type ProviderRecoveryCounts = {
  attempted: number;
  succeeded: number;
  failed: number;
};

export type RecoverySubscription = {
  id: string;
  status?: string | null;
  paid_count?: number | null;
  created_at?: number | null;
  current_start?: number | null;
  current_end?: number | null;
  notes?: Record<string, string> | null;
  [key: string]: unknown;
};

export type RecoveryInvoice = {
  id: string;
  payment_id?: string | null;
  status?: string | null;
  amount?: number | null;
  currency?: string | null;
  paid_at?: number | null;
  billing_start?: number | null;
  billing_end?: number | null;
  [key: string]: unknown;
};

export type RecoveryPayment = {
  id: string;
  amount?: number | null;
  currency?: string | null;
  created_at?: number | null;
  notes?: Record<string, string> | null;
  [key: string]: unknown;
};

export type RecoveryEnvelope = {
  eventId: string;
  eventType: 'subscription.activated' | 'subscription.charged';
  objectId: string;
  eventCreatedAt: string;
  payload: Record<string, unknown>;
};

export type RecoveryEventRecord = {
  event_id: string;
  event_type: string;
  duplicate: boolean;
  status: string | null;
};

export type RecoveryInvoiceRecord = {
  invoice_id: string;
  payment_id: string;
  amount_cents: number;
  currency: string;
  paid_at: string | null;
};

export type RecoveryOutcome = {
  invoices: RecoveryInvoiceRecord[];
  events: RecoveryEventRecord[];
};

function isoFromEpoch(value: unknown): string | null {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? new Date(value * 1000).toISOString()
    : null;
}

/* 'active' is money moving on a live mandate. 'authenticated' with paid_count > 0 is the same
   thing seen a moment before Razorpay flips the status. Everything else — 'created', 'expired',
   an authenticated mandate that has never charged — is a checkout, not a customer. */
export function isRecoverableProviderSubscription(
  subscription: { status?: string | null; paid_count?: number | null },
): boolean {
  const status = String(subscription?.status || '').toLowerCase();
  if (status === 'active') return true;
  return status === 'authenticated' && Number(subscription?.paid_count || 0) > 0;
}

export async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  /* WebCrypto wants a concrete ArrayBuffer; a TextEncoder result is typed over ArrayBufferLike.
     Copying the exact byte range out gives the buffer the signature asks for. */
  const buffer = bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/* The synthesised envelopes are byte-shaped like a real Razorpay delivery — `entity:'event'`, the
   event name, and payload.<object>.entity — because that is the only shape the v755 applier
   reads (`payload #> '{payload,subscription,entity}'`). The two extra keys, `recovered_from` and
   `recovered_at`, are additive provenance: the durable inbox row keeps the whole payload, so an
   auditor can always tell a recovered event from a delivered one. */
export function buildRecoveryEnvelopes({
  subscription,
  paidInvoices,
  recoveredAt,
}: {
  subscription: RecoverySubscription;
  paidInvoices: Array<{ invoice: RecoveryInvoice; payment: RecoveryPayment }>;
  recoveredAt: string;
}): RecoveryEnvelope[] {
  const subscriptionId = String(subscription.id);
  const envelope = (
    eventType: RecoveryEnvelope['eventType'],
    eventId: string,
    eventCreatedAt: string,
    payload: Record<string, unknown>,
  ): RecoveryEnvelope => ({
    eventId,
    eventType,
    objectId: subscriptionId,
    eventCreatedAt,
    payload: {
      entity: 'event',
      event: eventType,
      recovered_from: 'provider_api',
      recovered_at: recoveredAt,
      payload,
    },
  });

  const envelopes: RecoveryEnvelope[] = [
    /* activated first, and at the subscription's creation time: rank 30 against rank 100, so the
       charged events that follow can never be undone by it whatever order they are applied in. */
    envelope(
      'subscription.activated',
      `recovery_${subscriptionId}_activated`,
      isoFromEpoch(subscription.created_at) || recoveredAt,
      { subscription: { entity: subscription } },
    ),
  ];

  for (const { invoice, payment } of paidInvoices) {
    envelopes.push(
      buildChargedEnvelope({
        subscription,
        invoice,
        payment,
        eventId: `recovery_${subscriptionId}_${String(payment.id)}_charged`,
        recoveredAt,
      }),
    );
  }
  return envelopes;
}

/* nestly_v764 — ONE synthesised subscription.charged, extracted from the v759 recovery loop so
   the billing-command path can reuse it verbatim for the invoice Razorpay raises when a
   subscription is UPDATED mid-period (a branch added: PATCH schedule_change_at 'now' charges the
   pro-rata immediately and emits only subscription.updated, without a payment). Same envelope,
   same pipeline, same applier — the only difference is the event id prefix and the extra notes
   that say WHY the charge happened, which the applier reads into the invoice's reason/detail. */
export function buildChargedEnvelope({
  subscription,
  invoice,
  payment,
  eventId,
  recoveredAt,
  extraNotes,
}: {
  subscription: RecoverySubscription;
  invoice: RecoveryInvoice;
  payment: RecoveryPayment;
  eventId: string;
  recoveredAt: string;
  extraNotes?: Record<string, string>;
}): RecoveryEnvelope {
  const notes = subscription.notes || {};
  const paidAt = isoFromEpoch(invoice.paid_at) || isoFromEpoch(payment.created_at) || recoveredAt;
  return {
    eventId,
    eventType: 'subscription.charged',
    objectId: String(subscription.id),
    eventCreatedAt: paidAt,
    payload: {
      entity: 'event',
      event: 'subscription.charged',
      recovered_from: 'provider_api',
      recovered_at: recoveredAt,
      payload: {
        /* A real subscription.charged carries the subscription as it stood for THAT cycle. The
           invoice's billing window is that cycle, so it replaces current_start/current_end;
           without it every recovered cycle would claim the newest period. */
        subscription: {
          entity: {
            ...subscription,
            current_start: typeof invoice.billing_start === 'number'
              ? invoice.billing_start
              : subscription.current_start ?? null,
            current_end: typeof invoice.billing_end === 'number'
              ? invoice.billing_end
              : subscription.current_end ?? null,
          },
        },
        payment: {
          entity: {
            ...payment,
            /* The applier stores the invoice id as provider_invoice_id and falls back to the
               payment id; giving it Razorpay's real invoice id means a later genuine webhook
               for the same cycle updates the SAME row instead of creating a second one. */
            invoice_id: String(invoice.id),
            /* The subscription's notes are authoritative for business_id — they are what
               razorpay_business_v755 reads first, and what the command wrote at checkout. A
               payment's own notes are kept underneath for provenance, and the v764 reason /
               branch keys ride on top so the applier can label the invoice. */
            notes: { ...(payment.notes || {}), ...notes, ...(extraNotes || {}) },
          },
        },
      },
    },
  };
}

type AdminLike = {
  rpc: (name: string, args: Record<string, unknown>) => PromiseLike<
    { data: unknown; error: { message?: string; code?: string } | null }
  >;
};

type RazorpayLike = {
  getSubscription: (id: string) => Promise<RecoverySubscription>;
  getSubscriptionInvoices: (
    id: string,
    query?: Record<string, string | number | undefined>,
  ) => Promise<{ items?: RecoveryInvoice[] } | null>;
  getPayment: (id: string, options?: { expandCard?: boolean }) => Promise<RecoveryPayment>;
};

/* The single writer of a synthesised event: ingest into the durable inbox, then apply. Nothing
   here invents truth — every field came from a fresh GET against Razorpay — and both calls are
   the EXISTING pipeline, so every invariant the applier enforces still applies. */
export async function pushRecoveryEnvelope({
  admin,
  envelope,
  livemode,
}: {
  admin: AdminLike;
  envelope: RecoveryEnvelope;
  livemode: boolean;
}): Promise<RecoveryEventRecord> {
  const payloadDigest = await sha256Hex(JSON.stringify(envelope.payload));
  const { data: inbox, error: inboxError } = await admin.rpc('ingest_billing_event_v755', {
    p_provider: 'razorpay',
    p_event_id: envelope.eventId,
    p_event_type: envelope.eventType,
    p_object_id: envelope.objectId,
    p_event_created_at: envelope.eventCreatedAt,
    p_livemode: livemode,
    p_payload: envelope.payload,
    p_payload_sha256: payloadDigest,
  });
  if (inboxError) {
    throw new Error(`recovery ingest failed: ${inboxError.code || inboxError.message || 'rpc'}`);
  }
  const duplicate = (inbox as { duplicate?: boolean } | null)?.duplicate === true;

  /* Applied even when the ingest deduped: the applier's duplicate branch is a no-op for the
     mirrors and re-converges the v94 workspace / v621 branch activation, so a run that died
     between ingest and apply heals here instead of leaving a durable-but-unapplied event. */
  const { data: applied, error: applyError } = await admin.rpc(
    'apply_razorpay_billing_event_v755',
    { p_event_id: envelope.eventId },
  );
  const status = (applied as { status?: string } | null)?.status || null;
  if (applyError || status === 'failed') {
    throw new Error(
      `recovery apply failed: ${applyError?.code || applyError?.message || 'apply_failed'}`,
    );
  }
  return {
    event_id: envelope.eventId,
    event_type: envelope.eventType,
    duplicate,
    status,
  };
}

/* nestly_v764 — mirror ONE settled invoice as a subscription.charged. Used by the branch-add
   command (the update charge Razorpay never sends an event for) and by the reconciliation heal
   for a known subscription whose paid invoice has no local row. */
export async function synthesizeChargedFromInvoice({
  admin,
  subscription,
  invoice,
  payment,
  livemode,
  eventId,
  extraNotes,
  now = () => new Date(),
}: {
  admin: AdminLike;
  subscription: RecoverySubscription;
  invoice: RecoveryInvoice;
  payment: RecoveryPayment;
  livemode: boolean;
  eventId: string;
  extraNotes?: Record<string, string>;
  now?: () => Date;
}): Promise<RecoveryEventRecord> {
  const envelope = buildChargedEnvelope({
    subscription,
    invoice,
    payment,
    eventId,
    recoveredAt: now().toISOString(),
    extraNotes,
  });
  return await pushRecoveryEnvelope({ admin, envelope, livemode });
}

/* One subscription, start to finish: read it back from Razorpay (never trust the list page we
   were handed — it may be a page old), read its invoices, expand each settled payment, then push
   the envelopes through the real pipeline in rank order. Throws on any failure; the caller counts
   it rather than letting it end the run. */
export async function recoverProviderSubscription({
  admin,
  razorpay,
  subscriptionId,
  livemode,
  now = () => new Date(),
}: {
  admin: AdminLike;
  razorpay: RazorpayLike;
  subscriptionId: string;
  livemode: boolean;
  now?: () => Date;
}): Promise<RecoveryOutcome> {
  const subscription = await razorpay.getSubscription(subscriptionId);
  const invoicePage = await razorpay.getSubscriptionInvoices(subscriptionId, { count: 100 });
  /* Only a PAID invoice with a payment id is settled money. An issued-but-unpaid invoice is the
     next cycle's bill and must not become a paid mirror row. */
  const paid = (invoicePage?.items || []).filter(
    (invoice) => String(invoice?.status || '') === 'paid' && Boolean(invoice?.payment_id),
  );
  const invoiceOrder = [...paid].sort(
    (left, right) => Number(left.paid_at || 0) - Number(right.paid_at || 0),
  );
  const paidInvoices: Array<{ invoice: RecoveryInvoice; payment: RecoveryPayment }> = [];
  for (const invoice of invoiceOrder) {
    const payment = await razorpay.getPayment(String(invoice.payment_id), { expandCard: true });
    paidInvoices.push({ invoice, payment });
  }

  const recoveredAt = now().toISOString();
  const envelopes = buildRecoveryEnvelopes({ subscription, paidInvoices, recoveredAt });

  const events: RecoveryEventRecord[] = [];
  for (const item of envelopes) {
    events.push(await pushRecoveryEnvelope({ admin, envelope: item, livemode }));
  }

  return {
    invoices: paidInvoices.map(({ invoice, payment }) => ({
      invoice_id: String(invoice.id),
      payment_id: String(payment.id),
      amount_cents: Number(invoice.amount ?? payment.amount ?? 0),
      currency: String(invoice.currency || payment.currency || 'SGD').toUpperCase(),
      paid_at: isoFromEpoch(invoice.paid_at),
    })),
    events,
  };
}
