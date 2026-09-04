/* nestly_v764 — the subscription LIFECYCLE pieces Razorpay does not deliver as events.

   Five owner rulings sit behind this module, and each one runs into the same Razorpay fact: the
   REST API changes the subscription, but the webhook that would tell us what it did either never
   arrives or arrives without the money.

   - Add a branch mid-period. PATCH schedule_change_at 'now' charges the pro-rata difference on
     the card IMMEDIATELY and raises an "Updated invoice … charged due to subscription update".
     The ONLY event Razorpay emits is subscription.updated, whose payload has no payment. So the
     charge is read back from GET /subscriptions/:id/invoices and mirrored through the EXISTING
     synthesis pipeline (ingest_billing_event_v755 -> apply_razorpay_billing_event_v755). This
     module never writes billing truth itself.
   - Change the billing cycle. A plan with a different period cannot be PATCHed without
     remaining_count, and the change must land on the renewal date, so it is scheduled for
     cycle_end and the effective date is recorded locally for the page to say out loud.
   - Cancel renewal. cancel_at_cycle_end CANNOT be undone at Razorpay, so an owner's cancel is a
     LOCAL intent and only the due-date sweep is allowed to send it to the provider.
   - Update card / refresh the digits. Card change is a checkout in card-change mode; the new
     card's last4 is read back from the latest settled payment.

   Everything here is injectable (admin + razorpay + clock + sleep) so the Node suite EXECUTES
   each path against stubs rather than grepping the edge source. */

import {
  type RecoveryEventRecord,
  type RecoveryInvoice,
  type RecoveryInvoiceRecord,
  type RecoveryPayment,
  type RecoverySubscription,
  synthesizeChargedFromInvoice,
} from './razorpay-provider-recovery.ts';
import {
  type BackfillCardPayment,
  mapPaymentMethod,
} from './billing-payment-method-backfill.ts';

/* Razorpay refuses a plan change across periods without remaining_count ("remaining_count should
   be present to update to new plan which has different period"). It is the number of cycles yet
   to be CHARGED, and mirrors the total_count the checkout used: the practical forevers. */
export const REMAINING_COUNT_MONTHLY = 1200;
export const REMAINING_COUNT_ANNUAL = 100;

export function remainingCountForCadence(cadence: string): number {
  return String(cadence) === 'annual' ? REMAINING_COUNT_ANNUAL : REMAINING_COUNT_MONTHLY;
}

/* Two quick looks, not a retry loop. Razorpay raises the update invoice synchronously in the
   common case; a card that needs a second (3DS, a slow network) is caught by the 3s look, and
   anything slower is honestly 'uncertain' and healed by the nightly reconciliation. Waiting
   longer would hold an edge request open on a card decision we cannot influence. */
export const UPDATE_CHARGE_POLL_DELAYS_MS = [0, 3000];
export const UPDATE_CHARGE_HEAL_MAX_SUBSCRIPTIONS = 10;

export type LifecycleAdmin = {
  // deno-lint-ignore no-explicit-any
  from: (table: string) => any;
  // deno-lint-ignore no-explicit-any
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<any>;
};

export type LifecycleRazorpay = {
  getSubscription: (id: string) => Promise<RecoverySubscription>;
  getSubscriptionInvoices: (
    id: string,
    query?: Record<string, string | number | undefined>,
  ) => Promise<{ items?: RecoveryInvoice[] } | null>;
  getPayment: (
    id: string,
    options?: { expandCard?: boolean },
  ) => Promise<RecoveryPayment & BackfillCardPayment>;
  cancelSubscription?: (id: string, cancelAtCycleEnd: 0 | 1) => Promise<{ id?: string }>;
};

function isoFromEpoch(value: unknown): string | null {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? new Date(value * 1000).toISOString()
    : null;
}

const wait = (ms: number) =>
  ms > 0 ? new Promise<void>((resolve) => setTimeout(resolve, ms)) : Promise.resolve();

/* Which of a subscription's paid invoices this deployment has NOT mirrored yet, keyed on the
   payment id (billing_provider_invoices.provider_payment_intent_id). Keying on the payment and
   not the invoice matters: the applier falls back to the payment id when Razorpay issued no
   invoice, so the payment is the identifier both shapes share. */
export async function unmirroredPaidInvoices({
  admin,
  businessId,
  livemode,
  invoices,
}: {
  admin: LifecycleAdmin;
  businessId: string;
  livemode: boolean;
  invoices: RecoveryInvoice[];
}): Promise<RecoveryInvoice[]> {
  const paid = invoices.filter(
    (invoice) => String(invoice?.status || '') === 'paid' && Boolean(invoice?.payment_id),
  );
  if (!paid.length) return [];
  const paymentIds = paid.map((invoice) => String(invoice.payment_id));
  const { data, error } = await admin
    .from('billing_provider_invoices')
    .select('provider_payment_intent_id')
    .eq('business_id', businessId)
    .eq('livemode', livemode)
    .in('provider_payment_intent_id', paymentIds);
  /* Fail CLOSED on an unreadable mirror: synthesising a charge we may already hold would be a
     second write of the same money. An empty answer here means "capture nothing this pass"; the
     nightly heal re-reads and closes it. */
  if (error) throw new Error('mirrored invoice lookup failed');
  const mirrored = new Set(
    (data || []).map((row: { provider_payment_intent_id?: string | null }) =>
      String(row?.provider_payment_intent_id || '')
    ),
  );
  return paid
    .filter((invoice) => !mirrored.has(String(invoice.payment_id)))
    .sort((left, right) => Number(left.paid_at || 0) - Number(right.paid_at || 0));
}

export type UpdateChargeCapture = {
  invoices: RecoveryInvoiceRecord[];
  events: RecoveryEventRecord[];
  polls: number;
};

/* The branch-add capture. Poll the invoice list, mirror every paid invoice we do not already
   hold, and stop as soon as one is mirrored — a single update charge is what the PATCH raises.
   Returns an empty capture (never throws for "nothing yet") so the caller can decide between
   'completed' and 'uncertain'. */
export async function captureUpdateCharge({
  admin,
  razorpay,
  subscriptionId,
  businessId,
  livemode,
  subscription,
  extraNotes,
  eventIdPrefix = 'update',
  delays = UPDATE_CHARGE_POLL_DELAYS_MS,
  sleep = wait,
  now = () => new Date(),
}: {
  admin: LifecycleAdmin;
  razorpay: LifecycleRazorpay;
  subscriptionId: string;
  businessId: string;
  livemode: boolean;
  subscription?: RecoverySubscription;
  extraNotes?: Record<string, string>;
  eventIdPrefix?: string;
  delays?: number[];
  sleep?: (ms: number) => Promise<void>;
  now?: () => Date;
}): Promise<UpdateChargeCapture> {
  const captured: RecoveryInvoiceRecord[] = [];
  const events: RecoveryEventRecord[] = [];
  let polls = 0;
  let entity = subscription;
  for (const delay of delays) {
    await sleep(delay);
    polls += 1;
    const page = await razorpay.getSubscriptionInvoices(subscriptionId, { count: 100 });
    const pending = await unmirroredPaidInvoices({
      admin,
      businessId,
      livemode,
      invoices: page?.items || [],
    });
    if (!pending.length) continue;
    if (!entity) entity = await razorpay.getSubscription(subscriptionId);
    for (const invoice of pending) {
      const payment = await razorpay.getPayment(String(invoice.payment_id), { expandCard: true });
      /* The window this invoice pays for travels with the event, so the payments history can say
         "Branch East Coast · 5 Mar – 4 Sep 2027" instead of just a date and an amount. */
      const notes: Record<string, string> = { ...(extraNotes || {}) };
      const from = isoFromEpoch(invoice.billing_start);
      const until = isoFromEpoch(invoice.billing_end);
      if (from) notes.covers_from = from;
      if (until) notes.covers_until = until;
      events.push(
        await synthesizeChargedFromInvoice({
          admin,
          subscription: entity,
          invoice,
          payment,
          livemode,
          eventId: `${eventIdPrefix}_${subscriptionId}_${String(payment.id)}_charged`,
          extraNotes: notes,
          now,
        }),
      );
      captured.push({
        invoice_id: String(invoice.id),
        payment_id: String(payment.id),
        amount_cents: Number(invoice.amount ?? payment.amount ?? 0),
        currency: String(invoice.currency || payment.currency || 'SGD').toUpperCase(),
        paid_at: isoFromEpoch(invoice.paid_at),
      });
    }
    break;
  }
  return { invoices: captured, events, polls };
}

/* Which branch a change_branches command is paying for. The command row names it when
   business_add_branch_v202 wrote requested_branch_id; when it did not, the branch awaiting
   payment for this business is the answer — newest first, because the owner just created it. */
export async function branchIdentityForCommand({
  admin,
  businessId,
  requestedBranchId,
}: {
  admin: LifecycleAdmin;
  businessId: string;
  requestedBranchId?: string | null;
}): Promise<{ branch_id: string; branch_name: string } | null> {
  try {
    if (requestedBranchId) {
      const { data, error } = await admin
        .from('branches')
        .select('id,name')
        .eq('id', requestedBranchId)
        .maybeSingle();
      if (!error && data?.id) {
        return { branch_id: String(data.id), branch_name: String(data.name || '') };
      }
    }
    const { data, error } = await admin
      .from('branches')
      .select('id,name,created_at')
      .eq('business_id', businessId)
      .eq('billing_state', 'pending_payment')
      .order('created_at', { ascending: false })
      .limit(1);
    if (error) return null;
    const row = (data || [])[0];
    return row?.id ? { branch_id: String(row.id), branch_name: String(row.name || '') } : null;
  } catch {
    /* Identity is a LABEL on the payment, never a precondition for it. A branch we cannot name
       still gets its charge mirrored; the history line just falls back to "Subscription". */
    return null;
  }
}

/* A cancel_at_period_end command may only reach Razorpay when the DUE-DATE SWEEP raised it,
   because cancel_at_cycle_end cannot be undone. An owner pressing "Cancel renewal" records a
   local intent (set_renewal_intent_v764) and must NOT touch the provider — otherwise Resume,
   which the owner is promised, would be impossible from the moment they clicked.

   Two independent signals, either of which proves the system path:
   - an explicit marker on the command row (no human requester / a system origin flag), and
   - the business appearing in list_due_renewal_cancels_v764(), which is the sweep's own list.
   The second is the authority even when A's column names drift, and it is also a correctness
   gate: a cancel that is not yet due must not be sent early. */
export function commandLooksSystemOriginated(row: Record<string, unknown> | null): boolean {
  if (!row) return false;
  if (row.requested_by === null) return true;
  for (const key of ['system_initiated', 'is_system', 'system_actor']) {
    if (row[key] === true) return true;
  }
  for (const key of ['origin', 'actor_kind', 'requested_by_kind', 'source']) {
    if (String(row[key] || '').toLowerCase() === 'system') return true;
  }
  return false;
}

export type DueRenewalCancel = {
  business_id: string;
  provider_subscription_id: string;
};

export function normalizeDueRenewalCancels(data: unknown): DueRenewalCancel[] {
  /* v765's list_due_renewal_cancels_v764 answers {status:'ok', due:[...]}; a bare array is
     also accepted so a future reshaping cannot silently empty the sweep. */
  const envelope = data && typeof data === 'object' && !Array.isArray(data)
    ? (data as Record<string, unknown>)
    : null;
  const source = envelope && Array.isArray(envelope.due) ? envelope.due : data;
  const rows = Array.isArray(source) ? source : source ? [source] : [];
  return rows
    .map((row) => {
      const record = (row || {}) as Record<string, unknown>;
      return {
        business_id: String(record.business_id || ''),
        provider_subscription_id: String(
          record.provider_subscription_id || record.subscription_id || '',
        ),
      };
    })
    .filter((row) => row.business_id && row.provider_subscription_id);
}

export async function listDueRenewalCancels(
  admin: LifecycleAdmin,
): Promise<DueRenewalCancel[]> {
  const { data, error } = await admin.rpc('list_due_renewal_cancels_v764', {});
  if (error) throw new Error('due renewal cancel list unavailable');
  return normalizeDueRenewalCancels(data);
}

export type RenewalCancelCounts = { attempted: number; sent: number; failed: number };

/* The nightly enforcement: for every intent whose period end is close enough that the sweep
   listed it, tell Razorpay to stop at cycle end and record that we did. Marking comes AFTER the
   provider call and only on success, so a failure is retried tomorrow rather than leaving a
   tenant marked "sent" whose renewal will actually still charge. Failures are counted, never
   thrown: one tenant must not end the run. */
export async function runDueRenewalCancels({
  admin,
  razorpay,
  limit = 50,
}: {
  admin: LifecycleAdmin;
  razorpay: LifecycleRazorpay;
  limit?: number;
}): Promise<RenewalCancelCounts> {
  const counts: RenewalCancelCounts = { attempted: 0, sent: 0, failed: 0 };
  let due: DueRenewalCancel[];
  try {
    due = await listDueRenewalCancels(admin);
  } catch {
    counts.failed += 1;
    return counts;
  }
  for (const row of due.slice(0, limit)) {
    counts.attempted += 1;
    try {
      if (!razorpay.cancelSubscription) throw new Error('cancel unsupported');
      await razorpay.cancelSubscription(row.provider_subscription_id, 1);
      const { error } = await admin.rpc('mark_renewal_cancel_sent_v764', {
        p_business: row.business_id,
      });
      if (error) throw new Error('renewal cancel mark failed');
      counts.sent += 1;
    } catch {
      counts.failed += 1;
    }
  }
  return counts;
}

export type PaymentMethodRefresh = {
  refreshed: boolean;
  payment_id: string | null;
  kind: string | null;
  brand: string | null;
  last4: string | null;
};

/* 'refresh_payment_method' — after a card change the owner should see the new digits in seconds,
   not after the nightly backfill. The latest SETTLED payment is the card Razorpay will charge
   next, so its expanded card body is the answer. Nothing about money is written: only the label. */
export async function refreshPaymentMethodFromProvider({
  admin,
  razorpay,
  businessId,
  subscriptionId,
}: {
  admin: LifecycleAdmin;
  razorpay: LifecycleRazorpay;
  businessId: string;
  subscriptionId: string;
}): Promise<PaymentMethodRefresh> {
  const empty: PaymentMethodRefresh = {
    refreshed: false,
    payment_id: null,
    kind: null,
    brand: null,
    last4: null,
  };
  const page = await razorpay.getSubscriptionInvoices(subscriptionId, { count: 100 });
  const paid = (page?.items || []).filter(
    (invoice) => String(invoice?.status || '') === 'paid' && Boolean(invoice?.payment_id),
  );
  if (!paid.length) return empty;
  const latest = paid.reduce((newest, invoice) =>
    Number(invoice.paid_at || 0) >= Number(newest.paid_at || 0) ? invoice : newest
  );
  const paymentId = String(latest.payment_id);
  const payment = await razorpay.getPayment(paymentId, { expandCard: true });
  const mapped = mapPaymentMethod(payment);
  if (!mapped) return { ...empty, payment_id: paymentId };
  const { error } = await admin.rpc('set_billing_payment_method_v758', {
    p_business: businessId,
    p_payment_id: paymentId,
    p_kind: mapped.kind,
    p_brand: mapped.brand,
    p_last4: mapped.last4,
  });
  if (error) throw new Error('payment method write rejected');
  return {
    refreshed: true,
    payment_id: paymentId,
    kind: mapped.kind,
    brand: mapped.brand,
    last4: mapped.last4,
  };
}

export type UpdateChargeHealCounts = { attempted: number; recovered: number; failed: number };

/* Reconciliation heal (v764): a subscription we ALREADY know locally can still have a paid
   invoice we never mirrored — exactly what an update charge is, and what the v759 recovery could
   not see, because that path only looks at subscriptions with no local row at all. Bounded, and
   a failure is a counter. */
export async function healMissingUpdateCharges({
  admin,
  razorpay,
  scope,
  provider = 'razorpay',
  limit = UPDATE_CHARGE_HEAL_MAX_SUBSCRIPTIONS,
}: {
  admin: LifecycleAdmin;
  razorpay: LifecycleRazorpay;
  scope: { livemode: boolean; businessIds: string[] };
  provider?: string;
  limit?: number;
}): Promise<UpdateChargeHealCounts> {
  const counts: UpdateChargeHealCounts = { attempted: 0, recovered: 0, failed: 0 };
  if (!scope.businessIds.length || limit <= 0) return counts;
  let rows: Array<{ business_id: string; provider_subscription_id: string }> = [];
  try {
    const { data, error } = await admin
      .from('billing_provider_subscriptions')
      .select('business_id,provider_subscription_id')
      .eq('provider', provider)
      .eq('livemode', scope.livemode)
      .in('business_id', scope.businessIds)
      .order('business_id', { ascending: true })
      .limit(limit);
    if (error) throw new Error('known subscription lookup failed');
    rows = (data || []) as Array<{ business_id: string; provider_subscription_id: string }>;
  } catch {
    counts.failed += 1;
    return counts;
  }
  for (const row of rows.slice(0, limit)) {
    counts.attempted += 1;
    try {
      const capture = await captureUpdateCharge({
        admin,
        razorpay,
        subscriptionId: String(row.provider_subscription_id),
        businessId: String(row.business_id),
        livemode: scope.livemode,
        extraNotes: { reason: 'other' },
        delays: [0],
      });
      if (capture.invoices.length) counts.recovered += capture.invoices.length;
    } catch {
      counts.failed += 1;
    }
  }
  return counts;
}
