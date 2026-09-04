/* nestly_v758 — the stored payment method (brand + last 4) exists so the owner's Billing page can
   answer "which card will be charged" without a click. The webhook applier captures it whenever
   Razorpay includes `card` in the charged payload; when it does not, this bounded backfill asks
   Razorpay for the payment with `expand[]=card` and hands the answer to the service-role RPC.

   Two rules this module exists to keep:
   - It NEVER writes payment truth. It only fills brand/last4 on a row a paid invoice already
     proves exists; amounts, statuses and periods are untouched.
   - It never fails the reconciliation run. Every tenant is attempted independently and a failure
     is a counter in the run summary, because a cosmetic card label must not turn the nightly
     integrity run red. */

export type PaymentMethodBackfillCounts = {
  attempted: number;
  updated: number;
  failed: number;
};

export type BackfillCardPayment = {
  id: string;
  method?: string;
  card?: { last4?: string | null; network?: string | null } | null;
};

export type PaymentMethodMapping = {
  kind: string;
  brand: string | null;
  last4: string | null;
} | null;

/* Only the two methods we can describe honestly are mapped. Anything else (netbanking, wallet,
   upi…) returns null and the row stays empty rather than being labelled with a guess. */
export function mapPaymentMethod(payment: BackfillCardPayment | null | undefined): PaymentMethodMapping {
  const method = String(payment?.method || '').toLowerCase();
  if (method === 'card') {
    const last4 = String(payment?.card?.last4 || '');
    if (!/^[0-9]{4}$/.test(last4)) return null;
    const network = payment?.card?.network ? String(payment.card.network) : null;
    return { kind: 'card', brand: network, last4 };
  }
  if (method === 'paynow') return { kind: 'paynow', brand: null, last4: null };
  return null;
}

export const PAYMENT_METHOD_BACKFILL_MAX_TENANTS = 25;

/* Deliberately structural and loose: this module is executed in the Node test suite against a
   hand-built stub as well as in Deno against the real supabase-js client, whose builders are lazy
   thenables rather than Promises. Pinning the concrete client type here would make the stub
   untypeable and the test unwritable. */
// deno-lint-ignore no-explicit-any
type AdminClient = {
  // deno-lint-ignore no-explicit-any
  from: (table: string) => any;
  // deno-lint-ignore no-explicit-any
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<any>;
};

export async function backfillPaymentMethods({
  admin,
  razorpay,
  scope,
  provider = 'razorpay',
  limit = PAYMENT_METHOD_BACKFILL_MAX_TENANTS,
}: {
  admin: AdminClient;
  razorpay: { getPayment: (id: string, options?: { expandCard?: boolean }) => Promise<BackfillCardPayment> };
  scope: { livemode: boolean; businessIds: string[] };
  provider?: string;
  limit?: number;
}): Promise<PaymentMethodBackfillCounts> {
  const counts: PaymentMethodBackfillCounts = { attempted: 0, updated: 0, failed: 0 };
  if (!scope.businessIds.length) return counts;
  const bound = Math.max(0, Math.min(limit, PAYMENT_METHOD_BACKFILL_MAX_TENANTS));
  if (!bound) return counts;

  let candidates: Array<{ business_id: string }> = [];
  try {
    const { data, error } = await admin
      .from('billing_provider_customers')
      .select('business_id')
      .eq('provider', provider)
      .eq('livemode', scope.livemode)
      .in('business_id', scope.businessIds)
      .is('payment_method_last4', null)
      .order('business_id', { ascending: true })
      .limit(bound);
    if (error) throw new Error('payment method backfill candidates unavailable');
    candidates = (data || []) as Array<{ business_id: string }>;
  } catch {
    counts.failed += 1;
    return counts;
  }

  for (const candidate of candidates.slice(0, bound)) {
    const businessId = String(candidate.business_id);
    counts.attempted += 1;
    try {
      const { data: invoices, error: invoiceError } = await admin
        .from('billing_provider_invoices')
        .select('provider_payment_intent_id,paid_at')
        .eq('business_id', businessId)
        .eq('livemode', scope.livemode)
        .eq('status', 'paid')
        .not('provider_payment_intent_id', 'is', null)
        .order('paid_at', { ascending: false })
        .limit(1);
      if (invoiceError) throw new Error('paid invoice lookup failed');
      const paymentId = String(
        (invoices || [])[0]?.provider_payment_intent_id || '',
      );
      if (!paymentId) continue;
      const payment = await razorpay.getPayment(paymentId, { expandCard: true });
      const mapped = mapPaymentMethod(payment);
      if (!mapped) continue;
      const { error: rpcError } = await admin.rpc('set_billing_payment_method_v758', {
        p_business: businessId,
        p_payment_id: paymentId,
        p_kind: mapped.kind,
        p_brand: mapped.brand,
        p_last4: mapped.last4,
      });
      if (rpcError) throw new Error('payment method write rejected');
      counts.updated += 1;
    } catch {
      counts.failed += 1;
    }
  }
  return counts;
}
