/* nestly_v758 — an unpaid checkout is not a mismatch.

   Razorpay creates the subscription object the moment the owner opens the hosted checkout, in
   status 'created'; it becomes 'expired' after expire_by if nobody pays. No webhook ever fires
   for either, so no local mirror exists and never should. Reporting that as missing_local made
   one abandoned checkout re-alert every night for the whole 7-day cycle.

   'authenticated' with paid_count 0 is the in-flight window: the mandate is authorised but the
   first charge has not settled, so the mirror legitimately does not exist yet. It is only treated
   as pending for 24h — after that, an authenticated subscription with no local row is a real gap.

   Everything else (notably 'active') with no local row stays missing_local: that IS money moving
   without a mirror, which is exactly what reconciliation exists to catch. */

export const PENDING_CHECKOUT_STATUSES = ['created', 'expired'] as const;
export const PENDING_AUTHENTICATED_WINDOW_MS = 24 * 60 * 60 * 1000;

export type ProviderSubscriptionAbsence = 'pending_checkout' | 'missing_local';

export function classifyProviderSubscriptionAbsence(
  subscription: {
    status?: string | null;
    paid_count?: number | null;
    created_at?: number | null;
  },
  nowMs: number = Date.now(),
): ProviderSubscriptionAbsence {
  const status = String(subscription?.status || '').toLowerCase();
  if ((PENDING_CHECKOUT_STATUSES as readonly string[]).includes(status)) {
    return 'pending_checkout';
  }
  if (status === 'authenticated' && Number(subscription?.paid_count || 0) === 0) {
    const createdMs = Number(subscription?.created_at || 0) * 1000;
    if (createdMs > 0 && nowMs - createdMs <= PENDING_AUTHENTICATED_WINDOW_MS) {
      return 'pending_checkout';
    }
  }
  return 'missing_local';
}
