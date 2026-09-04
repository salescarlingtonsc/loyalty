import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';
import {
  billingReconciliationStatus,
  drainBoundedKeysetPages,
  drainBoundedOffsetPages,
  newBillingReconciliationCursor,
  parseBillingReconciliationCursor,
  providerIdsMissingLocally,
  type BillingReconciliationCursor,
} from '../_shared/billing-reconciliation.ts';
import {
  livemodeFromKey,
  RazorpayApiError,
  razorpayClient,
  type RazorpayClient,
  type RazorpayPayment,
  type RazorpaySubscription,
} from '../_shared/razorpay-client.ts';
import {
  backfillPaymentMethods,
  PAYMENT_METHOD_BACKFILL_MAX_TENANTS,
  type PaymentMethodBackfillCounts,
} from '../_shared/billing-payment-method-backfill.ts';
import { classifyProviderSubscriptionAbsence } from '../_shared/razorpay-subscription-absence.ts';
import {
  isRecoverableProviderSubscription,
  PROVIDER_RECOVERY_MAX_PER_RUN,
  type ProviderRecoveryCounts,
  recoverProviderSubscription,
} from '../_shared/razorpay-provider-recovery.ts';

const LOCAL_OBJECTS_PER_PAGE = 100;
const PROVIDER_OBJECTS_PER_PAGE = 100;
const MAX_PAGES_PER_STREAM = 1;
const MAX_PROVIDER_LOOKUP_CONCURRENCY = 8;
const PROVIDER = 'razorpay';
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type ReconciliationResult =
  | 'match'
  | 'mismatch'
  | 'missing_local'
  | 'missing_provider'
  | 'repaired'
  | 'failed';

type LocalSubscription = {
  business_id: string;
  provider_subscription_id: string;
  status: string;
  current_period_end: string | null;
};

type LocalSubscriptionItem = {
  provider_subscription_id: string;
  provider_price_id: string;
  quantity: number;
};

type SubscriptionItemSnapshot = {
  price_id: string;
  quantity: number;
};

type LocalInvoice = {
  business_id: string;
  provider_invoice_id: string;
  status: string;
  total_cents: number;
  amount_paid_cents: number;
  paid_at: string | null;
};

type RunCounts = {
  processed: number;
  /* Abandoned or in-flight hosted checkouts. Reported so the run is honest about what it saw,
     but deliberately NOT a discrepancy: it must never drive status 'mismatch'. */
  pending_checkout: number;
  matches: number;
  mismatches: number;
  missing_local: number;
  missing_provider: number;
  unscoped_provider: number;
  /* nestly_v759 — paid subscriptions the webhook never delivered, replayed through the real
     pipeline this run. Bounded, and its failures never fail the run. */
  recovered: ProviderRecoveryCounts;
  failures: number;
};

function epoch(value: unknown): string | null {
  return typeof value === 'number' && Number.isFinite(value)
    ? new Date(value * 1000).toISOString()
    : null;
}

/* The SAME status map the v755 migration applies when it writes a subscription. Reconciliation
   compares like with like: comparing Razorpay's raw vocabulary against our stored vocabulary
   would report every healthy subscription as a mismatch. */
export function razorpayStatusToLocalV755(status: string): string {
  const map: Record<string, string> = {
    created: 'incomplete',
    authenticated: 'active',
    active: 'active',
    pending: 'past_due',
    halted: 'unpaid',
    paused: 'paused',
    cancelled: 'canceled',
    completed: 'canceled',
    expired: 'incomplete_expired',
  };
  return map[status] || status;
}

function reconciliationAuthorized(req: Request): boolean {
  const expected = requiredEnv('BILLING_RECONCILIATION_SECRET');
  const supplied = req.headers.get('x-nestly-reconciliation-secret') || '';
  return expected.length >= 32 && supplied === expected;
}

async function digest(value: Record<string, unknown>): Promise<string> {
  const entries = Object.entries(value).sort(([left], [right]) => left.localeCompare(right));
  return sha256Hex(JSON.stringify(Object.fromEntries(entries)));
}

function razorpaySubscriptionSnapshot(
  subscription: RazorpaySubscription,
): Record<string, unknown> {
  return {
    status: razorpayStatusToLocalV755(String(subscription.status)),
    current_period_end: epoch(subscription.current_end),
    has_scheduled_changes: subscription.has_scheduled_changes === true,
    items: [
      {
        price_id: String(subscription.plan_id || ''),
        quantity: Number(subscription.quantity || 0),
      },
    ],
  };
}

function localSubscriptionSnapshot(
  subscription: LocalSubscription,
  items: SubscriptionItemSnapshot[],
  hasScheduledChanges: boolean,
): Record<string, unknown> {
  return {
    status: subscription.status,
    current_period_end: subscription.current_period_end,
    has_scheduled_changes: hasScheduledChanges,
    items: [...items].sort(
      (left, right) =>
        left.price_id.localeCompare(right.price_id) || left.quantity - right.quantity,
    ),
  };
}

/* Razorpay has no invoice object on the Subscriptions API that we consume; the captured PAYMENT
   is the settled money, and v755 stores it as one billing_provider_invoices row. The digest
   therefore only compares what a payment can express. */
function razorpayPaymentSnapshot(payment: RazorpayPayment): Record<string, unknown> {
  return {
    status: payment.status === 'captured' ? 'paid' : String(payment.status),
    total_cents: Number(payment.amount || 0),
    amount_paid_cents: payment.status === 'captured' ? Number(payment.amount || 0) : 0,
    paid_at: payment.status === 'captured' ? epoch(payment.created_at) : null,
  };
}

function localInvoiceSnapshot(invoice: LocalInvoice): Record<string, unknown> {
  return {
    status: invoice.status,
    total_cents: invoice.total_cents,
    amount_paid_cents: invoice.amount_paid_cents,
    paid_at: invoice.paid_at,
  };
}

function recordResult(
  cursor: BillingReconciliationCursor,
  run: RunCounts,
  result: ReconciliationResult,
): void {
  cursor.processed += 1;
  run.processed += 1;
  if (result === 'match') {
    cursor.matches += 1;
    run.matches += 1;
  } else if (result === 'mismatch') {
    cursor.mismatches += 1;
    run.mismatches += 1;
  } else if (result === 'missing_local') {
    cursor.missing_local += 1;
    run.missing_local += 1;
  } else if (result === 'missing_provider') {
    cursor.missing_provider += 1;
    run.missing_provider += 1;
  } else if (result === 'repaired') {
    /* The cycle counters are the v77 cursor's fixed shape and carry no 'repaired' slot. A
       repaired object is IN agreement by the end of the run, so it counts as a cycle match; the
       repair itself is reported separately as run.recovered and as the item's own result. */
    cursor.matches += 1;
    run.matches += 1;
  } else {
    cursor.failures += 1;
    run.failures += 1;
  }
}

/* A 4xx from Razorpay is the object genuinely not being there; anything else (timeout, 429, 5xx)
   is our own inability to look, which is a failure, not evidence of a missing object. */
function lookupResult(error: unknown): ReconciliationResult {
  return error instanceof RazorpayApiError && error.status >= 400 && error.status < 500 &&
      error.status !== 429
    ? 'missing_provider'
    : 'failed';
}

async function insertEvidence(
  admin: ReturnType<typeof billingAdminClient>,
  items: Record<string, unknown>[],
): Promise<void> {
  if (!items.length) return;
  const { error } = await admin.from('billing_reconciliation_items').insert(items);
  if (error) throw new Error('reconciliation evidence write failed');
}

async function mapWithConcurrency<T, R>(
  rows: T[],
  concurrency: number,
  worker: (row: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(rows.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, rows.length) }, async () => {
      while (next < rows.length) {
        const index = next++;
        results[index] = await worker(rows[index]);
      }
    }),
  );
  return results;
}

function notesBusinessId(notes: Record<string, string> | undefined): string | null {
  const value = notes?.business_id;
  return typeof value === 'string' && UUID.test(value) ? value : null;
}

/* nestly_v755 fix — the mirror tables carry NO `provider` column. Only
   billing_provider_customers, billing_provider_events and billing_reconciliation_runs do;
   billing_provider_subscriptions / _subscription_items / _invoices never did. Filtering on it
   returned PostgREST 42703, which surfaced as 'local subscription projection unavailable' and
   would have failed the 03:30 SGT cron every night behind the v634 reconcile_failed alert.

   Two real scopes replace the imaginary one:
   - `livemode`, which these tables DO carry. A test-mode mirror row must never be judged against
     the live Razorpay account, or the other way round: the object simply does not exist in the
     other account and every row would be reported missing_provider forever.
   - the tenant's own `subscriptions.billing_provider`, which is where "this business is on
     Razorpay" is actually recorded. That is how the Stripe history rows stay out of a Razorpay
     run without a column that does not exist. */
type ReconciliationScope = {
  livemode: boolean;
  businessIds: string[];
};

const TENANT_SCOPE_PAGE = 1000;
const TENANT_SCOPE_MAX_PAGES = 20;

async function razorpayTenantScope(
  admin: ReturnType<typeof billingAdminClient>,
  livemode: boolean,
): Promise<ReconciliationScope> {
  const businessIds: string[] = [];
  let after: string | null = null;
  for (let page = 0; page < TENANT_SCOPE_MAX_PAGES; page += 1) {
    let query = admin
      .from('subscriptions')
      .select('business_id')
      .eq('billing_provider', 'razorpay')
      .order('business_id', { ascending: true })
      .limit(TENANT_SCOPE_PAGE);
    if (after) query = query.gt('business_id', after);
    const { data, error } = await query;
    if (error) throw new Error('razorpay tenant scope unavailable');
    const rows = (data || []) as Array<{ business_id: string }>;
    for (const row of rows) businessIds.push(String(row.business_id));
    if (rows.length < TENANT_SCOPE_PAGE) break;
    after = String(rows[rows.length - 1].business_id);
  }
  return { livemode, businessIds: [...new Set(businessIds)] };
}

async function existingLocalProviderIds(
  admin: ReturnType<typeof billingAdminClient>,
  table: 'billing_provider_subscriptions' | 'billing_provider_invoices',
  column: 'provider_subscription_id' | 'provider_invoice_id',
  providerIds: string[],
  snapshotAt: string,
  scope: ReconciliationScope,
): Promise<Set<string>> {
  if (!providerIds.length) return new Set();
  // Existence is evaluated against cycle membership. A post-snapshot update
  // must not make a pre-snapshot local row appear missing.
  const { data, error } = await admin
    .from(table)
    .select(column)
    .eq('livemode', scope.livemode)
    .in('business_id', scope.businessIds)
    .in(column, providerIds)
    .lte('created_at', snapshotAt);
  if (error) throw new Error('local provider identity projection unavailable');
  return new Set(
    (data || []).map((row) => String((row as Record<string, unknown>)[column])),
  );
}

async function existingBusinessIds(
  admin: ReturnType<typeof billingAdminClient>,
  candidateIds: Array<string | null>,
): Promise<Set<string>> {
  const ids = [...new Set(candidateIds.filter((id): id is string => Boolean(id)))];
  if (!ids.length) return new Set();
  const { data, error } = await admin.from('businesses').select('id').in('id', ids);
  if (error) throw new Error('provider business metadata mapping unavailable');
  return new Set((data || []).map((row) => String(row.id)));
}

async function priorCursor(
  admin: ReturnType<typeof billingAdminClient>,
): Promise<BillingReconciliationCursor | null> {
  const { data, error } = await admin
    .from('billing_reconciliation_runs')
    .select('status,cursor_end')
    .eq('run_mode', 'scheduled')
    .order('started_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw new Error('reconciliation cursor unavailable');
  return data?.status === 'partial' ? parseBillingReconciliationCursor(data.cursor_end) : null;
}

async function reconcileSubscriptions({
  admin,
  razorpay,
  runId,
  cursor,
  run,
  scope,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  razorpay: RazorpayClient;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
  scope: ReconciliationScope;
}) {
  if (cursor.local_subscriptions_complete) {
    return {
      after: cursor.local_subscriptions_after,
      complete: true,
      pages: 0,
      processed: 0,
    };
  }
  return drainBoundedKeysetPages<LocalSubscription>({
    after: cursor.local_subscriptions_after,
    pageSize: LOCAL_OBJECTS_PER_PAGE,
    maxPages: MAX_PAGES_PER_STREAM,
    keyOf: (row) => row.provider_subscription_id,
    fetchPage: async (after, limit) => {
      /* Scoped by mode and by the tenants actually on Razorpay: the Stripe history rows stay in
         this table untouched, and asking Razorpay about a `sub_...` id would report every one of
         them missing forever. There is no `provider` column here to filter on. */
      let query = admin
        .from('billing_provider_subscriptions')
        .select('business_id,provider_subscription_id,status,current_period_end')
        .eq('livemode', scope.livemode)
        .in('business_id', scope.businessIds)
        .lte('created_at', cursor.snapshot_at)
        .order('provider_subscription_id', { ascending: true })
        .limit(limit);
      if (after) query = query.gt('provider_subscription_id', after);
      const { data, error } = await query;
      if (error) throw new Error('local subscription projection unavailable');
      return (data || []) as LocalSubscription[];
    },
    consumePage: async (rows) => {
      const providerSubscriptionIds = rows.map(
        ({ provider_subscription_id }) => provider_subscription_id,
      );
      /* This table carries neither `provider` nor `livemode` nor `business_id`; its only scope
         is the parent subscription ids, which are already scoped by the page above. */
      const { data: itemRows, error: itemError } = await admin
        .from('billing_provider_subscription_items')
        .select('provider_subscription_id,provider_price_id,quantity')
        .in('provider_subscription_id', providerSubscriptionIds);
      if (itemError) throw new Error('local subscription item projection unavailable');
      const itemsBySubscription = new Map<string, SubscriptionItemSnapshot[]>();
      for (const item of (itemRows || []) as LocalSubscriptionItem[]) {
        const items = itemsBySubscription.get(item.provider_subscription_id) || [];
        items.push({
          price_id: item.provider_price_id,
          quantity: Number(item.quantity || 0),
        });
        itemsBySubscription.set(item.provider_subscription_id, items);
      }
      const outcomes = await mapWithConcurrency(
        rows,
        MAX_PROVIDER_LOOKUP_CONCURRENCY,
        async (local) => {
          try {
            const provider = await razorpay.getSubscription(local.provider_subscription_id);
            const expected = razorpaySubscriptionSnapshot(provider);
            const actual = localSubscriptionSnapshot(
              local,
              itemsBySubscription.get(local.provider_subscription_id) || [],
              provider.has_scheduled_changes === true,
            );
            const [expectedDigest, actualDigest] = await Promise.all([
              digest(expected),
              digest(actual),
            ]);
            const result: ReconciliationResult = expectedDigest === actualDigest
              ? 'match'
              : 'mismatch';
            return {
              result,
              item: {
                run_id: runId,
                business_id: local.business_id,
                object_type: 'subscription',
                provider_object_id: local.provider_subscription_id,
                result,
                expected_digest: expectedDigest,
                actual_digest: actualDigest,
                detail: result === 'match' ? {} : { provider: expected, nestly: actual },
              },
            };
          } catch (error) {
            const result = lookupResult(error);
            return {
              result,
              item: {
                run_id: runId,
                business_id: local.business_id,
                object_type: 'subscription',
                provider_object_id: local.provider_subscription_id,
                result,
                detail: { reason: 'provider_subscription_lookup_failed' },
              },
            };
          }
        },
      );
      for (const outcome of outcomes) recordResult(cursor, run, outcome.result);
      await insertEvidence(admin, outcomes.map(({ item }) => item));
    },
  });
}

async function reconcileInvoices({
  admin,
  razorpay,
  runId,
  cursor,
  run,
  scope,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  razorpay: RazorpayClient;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
  scope: ReconciliationScope;
}) {
  if (cursor.local_invoices_complete) {
    return { after: cursor.local_invoices_after, complete: true, pages: 0, processed: 0 };
  }
  return drainBoundedKeysetPages<LocalInvoice>({
    after: cursor.local_invoices_after,
    pageSize: LOCAL_OBJECTS_PER_PAGE,
    maxPages: MAX_PAGES_PER_STREAM,
    keyOf: (row) => row.provider_invoice_id,
    fetchPage: async (after, limit) => {
      let query = admin
        .from('billing_provider_invoices')
        .select(
          'business_id,provider_invoice_id,status,total_cents,amount_paid_cents,paid_at,provider_payment_intent_id',
        )
        .eq('livemode', scope.livemode)
        .in('business_id', scope.businessIds)
        .lte('created_at', cursor.snapshot_at)
        .order('provider_invoice_id', { ascending: true })
        .limit(limit);
      if (after) query = query.gt('provider_invoice_id', after);
      const { data, error } = await query;
      if (error) throw new Error('local invoice projection unavailable');
      return (data || []) as unknown as LocalInvoice[];
    },
    consumePage: async (rows) => {
      const outcomes = await mapWithConcurrency(
        rows,
        MAX_PROVIDER_LOOKUP_CONCURRENCY,
        async (local) => {
          /* v755 writes provider_payment_intent_id = the captured payment id and uses the
             Razorpay invoice id (or that same payment id) as the invoice key, so the payment is
             always reachable from the local row. */
          const paymentId = String(
            (local as unknown as { provider_payment_intent_id?: string })
              .provider_payment_intent_id || local.provider_invoice_id,
          );
          try {
            const provider = await razorpay.getPayment(paymentId);
            const expected = razorpayPaymentSnapshot(provider);
            const actual = localInvoiceSnapshot(local);
            const [expectedDigest, actualDigest] = await Promise.all([
              digest(expected),
              digest(actual),
            ]);
            const result: ReconciliationResult = expectedDigest === actualDigest
              ? 'match'
              : 'mismatch';
            return {
              result,
              item: {
                run_id: runId,
                business_id: local.business_id,
                object_type: 'invoice',
                provider_object_id: local.provider_invoice_id,
                result,
                expected_digest: expectedDigest,
                actual_digest: actualDigest,
                detail: result === 'match' ? {} : { provider: expected, nestly: actual },
              },
            };
          } catch (error) {
            const result = lookupResult(error);
            return {
              result,
              item: {
                run_id: runId,
                business_id: local.business_id,
                object_type: 'invoice',
                provider_object_id: local.provider_invoice_id,
                result,
                detail: { reason: 'provider_invoice_lookup_failed' },
              },
            };
          }
        },
      );
      for (const outcome of outcomes) recordResult(cursor, run, outcome.result);
      await insertEvidence(admin, outcomes.map(({ item }) => item));
    },
  });
}

async function reconcileProviderSubscriptions({
  admin,
  razorpay,
  runId,
  cursor,
  run,
  scope,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  razorpay: RazorpayClient;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
  scope: ReconciliationScope;
}) {
  if (cursor.provider_subscriptions_complete) {
    return {
      after: cursor.provider_subscriptions_after,
      complete: true,
      pages: 0,
      processed: 0,
    };
  }
  const createdLte = Math.floor(Date.parse(cursor.snapshot_at) / 1000);
  return drainBoundedOffsetPages<RazorpaySubscription>({
    after: cursor.provider_subscriptions_after,
    pageSize: PROVIDER_OBJECTS_PER_PAGE,
    maxPages: MAX_PAGES_PER_STREAM,
    fetchPage: async (skip, count) => {
      const page = await razorpay.listSubscriptions({ count, skip });
      return page?.items || [];
    },
    consumePage: async (providers) => {
      /* Razorpay's list has no created-at filter, so the snapshot boundary is applied here.
         A subscription created after the boundary belongs to the NEXT cycle and must not be
         reported missing from a projection that had not been written yet. */
      const inCycle = providers.filter(
        (provider) => Number(provider.created_at || 0) <= createdLte,
      );
      const candidates = new Map(
        inCycle.map((provider) => [provider.id, notesBusinessId(provider.notes)]),
      );
      const businessIds = await existingBusinessIds(admin, [...candidates.values()]);
      /* The RUN's Razorpay tenant scope — the businesses whose `subscriptions.billing_provider`
         is razorpay. `businessIds` above only proves the business row exists; recovery writes
         billing truth, so it is additionally gated on the tenant this run is actually for. */
      const scopedBusinessIds = new Set(scope.businessIds);
      const scoped = inCycle.filter((provider) => {
        const candidate = candidates.get(provider.id);
        return Boolean(candidate && businessIds.has(candidate));
      });
      const unscoped = inCycle.length - scoped.length;
      cursor.unscoped_provider += unscoped;
      run.unscoped_provider += unscoped;
      const localIds = await existingLocalProviderIds(
        admin,
        'billing_provider_subscriptions',
        'provider_subscription_id',
        scoped.map(({ id }) => id),
        cursor.snapshot_at,
        scope,
      );
      const missingIds = new Set(
        providerIdsMissingLocally(scoped.map(({ id }) => id), localIds),
      );
      const missing = scoped.filter(({ id }) => missingIds.has(id));
      const items = await Promise.all(
        missing.map(async (provider) => {
          const candidate = candidates.get(provider.id);
          if (!candidate || !businessIds.has(candidate)) {
            throw new Error('scoped provider subscription lost business mapping');
          }
          /* v758 — billing_reconciliation_items.result carries a CHECK constraint
             ('match','missing_local','missing_provider','mismatch','repaired','failed'), so a
             pending checkout CANNOT get its own result value without a migration. It is written
             as 'match' — nothing is out of agreement — and identified by detail.reason, with the
             count surfaced in the run summary as `pending_checkout`. */
          const absence = classifyProviderSubscriptionAbsence(provider);
          const pending = absence === 'pending_checkout';
          if (pending) run.pending_checkout += 1;
          const expectedDigest = await digest(razorpaySubscriptionSnapshot(provider));

          /* nestly_v759 — a PAID subscription with no local mirror is not something to report
             once a night forever; it is a delivery the webhook never got, and everything needed
             to close it is still readable from Razorpay. Recovery is attempted only for a paid
             subscription belonging to a tenant already in this run's Razorpay scope, is bounded
             at PROVIDER_RECOVERY_MAX_PER_RUN, and a failure falls back to the missing_local
             record rather than ending the run. */
          if (
            !pending &&
            isRecoverableProviderSubscription(provider) &&
            scopedBusinessIds.has(candidate) &&
            run.recovered.attempted < PROVIDER_RECOVERY_MAX_PER_RUN
          ) {
            run.recovered.attempted += 1;
            try {
              const outcome = await recoverProviderSubscription({
                admin,
                razorpay,
                subscriptionId: provider.id,
                livemode: scope.livemode,
              });
              run.recovered.succeeded += 1;
              recordResult(cursor, run, 'repaired');
              return {
                run_id: runId,
                business_id: candidate,
                object_type: 'subscription',
                provider_object_id: provider.id,
                result: 'repaired',
                expected_digest: expectedDigest,
                actual_digest: null,
                detail: {
                  reason: 'provider_subscription_recovered',
                  provider_status: String(provider.status || ''),
                  metadata_business_id: candidate,
                  invoices: outcome.invoices,
                  events: outcome.events,
                },
              };
            } catch (error) {
              /* An integrity run must still report every other tenant. The attempt and its
                 reason are recorded on the item, and the object stays missing_local so the next
                 run tries again. */
              run.recovered.failed += 1;
              recordResult(cursor, run, 'missing_local');
              return {
                run_id: runId,
                business_id: candidate,
                object_type: 'subscription',
                provider_object_id: provider.id,
                result: 'missing_local',
                expected_digest: expectedDigest,
                actual_digest: null,
                detail: {
                  reason: 'provider_subscription_missing_local',
                  provider_status: String(provider.status || ''),
                  provider_created_at: epoch(provider.created_at),
                  metadata_business_id: candidate,
                  recovery_error: String((error as Error)?.message || 'recovery_failed'),
                },
              };
            }
          }

          recordResult(cursor, run, pending ? 'match' : 'missing_local');
          return {
            run_id: runId,
            business_id: candidate,
            object_type: 'subscription',
            provider_object_id: provider.id,
            result: pending ? 'match' : 'missing_local',
            expected_digest: expectedDigest,
            actual_digest: null,
            detail: pending
              ? {
                reason: 'provider_subscription_unpaid_checkout',
                provider_status: String(provider.status || ''),
                provider_created_at: epoch(provider.created_at),
                metadata_business_id: candidate,
                command_id: provider.notes?.command_id || null,
              }
              : {
                reason: 'provider_subscription_missing_local',
                provider_created_at: epoch(provider.created_at),
                metadata_business_id: candidate,
              },
          };
        }),
      );
      await insertEvidence(admin, items);
    },
  });
}

async function reconcileProviderInvoices({
  admin,
  razorpay,
  runId,
  cursor,
  run,
  scope,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  razorpay: RazorpayClient;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
  scope: ReconciliationScope;
}) {
  if (cursor.provider_invoices_complete) {
    return {
      after: cursor.provider_invoices_after,
      complete: true,
      pages: 0,
      processed: 0,
    };
  }
  const createdLte = Math.floor(Date.parse(cursor.snapshot_at) / 1000);
  return drainBoundedOffsetPages<RazorpayPayment>({
    after: cursor.provider_invoices_after,
    pageSize: PROVIDER_OBJECTS_PER_PAGE,
    maxPages: MAX_PAGES_PER_STREAM,
    fetchPage: async (skip, count) => {
      const page = await razorpay.listPayments({ to: createdLte, count, skip });
      return page?.items || [];
    },
    consumePage: async (providers) => {
      /* Only a CAPTURED payment is money we should hold an invoice row for. An authorized or
         failed payment is not settled revenue and its absence locally is correct. */
      const inCycle = providers.filter(
        (payment) =>
          payment.status === 'captured' && Number(payment.created_at || 0) <= createdLte,
      );
      const candidates = new Map(
        inCycle.map((payment) => [payment.id, notesBusinessId(payment.notes)]),
      );
      const businessIds = await existingBusinessIds(admin, [...candidates.values()]);
      const scoped = inCycle.filter((payment) => {
        const candidate = candidates.get(payment.id);
        return Boolean(candidate && businessIds.has(candidate));
      });
      const unscoped = inCycle.length - scoped.length;
      cursor.unscoped_provider += unscoped;
      run.unscoped_provider += unscoped;
      /* v755 keys an invoice on payment.invoice_id when Razorpay issued one and on the payment
         id otherwise, so both candidates are checked before calling a payment unprojected. */
      const localKeys = scoped.flatMap((payment) =>
        [payment.invoice_id || '', payment.id].filter(Boolean) as string[]
      );
      const localIds = await existingLocalProviderIds(
        admin,
        'billing_provider_invoices',
        'provider_invoice_id',
        localKeys,
        cursor.snapshot_at,
        scope,
      );
      const missing = scoped.filter(
        (payment) => !localIds.has(payment.id) && !localIds.has(String(payment.invoice_id || '')),
      );
      const items = await Promise.all(
        missing.map(async (payment) => {
          const candidate = candidates.get(payment.id);
          if (!candidate || !businessIds.has(candidate)) {
            throw new Error('scoped provider invoice lost business mapping');
          }
          recordResult(cursor, run, 'missing_local');
          return {
            run_id: runId,
            business_id: candidate,
            object_type: 'invoice',
            provider_object_id: String(payment.invoice_id || payment.id),
            result: 'missing_local',
            expected_digest: await digest(razorpayPaymentSnapshot(payment)),
            actual_digest: null,
            detail: {
              reason: 'provider_invoice_missing_local',
              provider_created_at: epoch(payment.created_at),
              metadata_business_id: candidate,
            },
          };
        }),
      );
      await insertEvidence(admin, items);
    },
  });
}

function completedSecondSnapshot(): string {
  return new Date((Math.floor(Date.now() / 1000) - 1) * 1000).toISOString();
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return billingJson(405, { error: 'method_not_allowed' });
  }
  try {
    if (!reconciliationAuthorized(req)) {
      return billingJson(401, { error: 'reconciliation_authentication_required' });
    }

    const admin = billingAdminClient();
    const razorpay = razorpayClient({
      keyId: requiredEnv('RAZORPAY_KEY_ID'),
      keySecret: requiredEnv('RAZORPAY_KEY_SECRET'),
    });
    /* Fail closed on an unrecognised key prefix. Every local projection is scoped by livemode,
       so a run that cannot say which mode it is in would either compare test rows against the
       live account or silently reconcile nothing — both of which look like a clean run. */
    const livemode = livemodeFromKey(requiredEnv('RAZORPAY_KEY_ID'));
    if (livemode === null) {
      return billingJson(500, { error: 'razorpay_key_mode_unknown' });
    }
    const scope = await razorpayTenantScope(admin, livemode);
    const resume = await priorCursor(admin);
    const cursor = resume || newBillingReconciliationCursor(completedSecondSnapshot());
    const { data: runId, error: startError } = await admin.rpc(
      'start_billing_reconciliation_v757',
      { p_run_mode: 'scheduled', p_cursor_start: JSON.stringify(cursor), p_provider: PROVIDER },
    );
    if (startError || !runId) {
      return billingJson(500, { error: 'reconciliation_start_failed' });
    }

    const run: RunCounts = {
      processed: 0,
      pending_checkout: 0,
      matches: 0,
      mismatches: 0,
      missing_local: 0,
      missing_provider: 0,
      unscoped_provider: 0,
      recovered: { attempted: 0, succeeded: 0, failed: 0 },
      failures: 0,
    };
    try {
      const subscriptionPage = await reconcileSubscriptions({
        admin,
        razorpay,
        runId,
        cursor,
        run,
        scope,
      });
      cursor.local_subscriptions_after = subscriptionPage.after;
      cursor.local_subscriptions_complete = subscriptionPage.complete;

      const invoicePage = await reconcileInvoices({
        admin,
        razorpay,
        runId,
        cursor,
        run,
        scope,
      });
      cursor.local_invoices_after = invoicePage.after;
      cursor.local_invoices_complete = invoicePage.complete;

      const providerSubscriptionPage = await reconcileProviderSubscriptions({
        admin,
        razorpay,
        runId,
        cursor,
        run,
        scope,
      });
      cursor.provider_subscriptions_after = providerSubscriptionPage.after;
      cursor.provider_subscriptions_complete = providerSubscriptionPage.complete;

      const providerInvoicePage = await reconcileProviderInvoices({
        admin,
        razorpay,
        runId,
        cursor,
        run,
        scope,
      });
      cursor.provider_invoices_after = providerInvoicePage.after;
      cursor.provider_invoices_complete = providerInvoicePage.complete;

      /* v758 — bounded, best-effort card-label backfill. It runs AFTER the invoice streams so it
         can only ever see tenants whose paid invoices are already projected, and its failures are
         counted rather than thrown: a missing card label must never fail an integrity run. */
      const paymentMethodBackfill: PaymentMethodBackfillCounts = await backfillPaymentMethods({
        admin,
        razorpay,
        scope,
        provider: PROVIDER,
        limit: PAYMENT_METHOD_BACKFILL_MAX_TENANTS,
      });

      const status = billingReconciliationStatus(cursor);
      const partial = status === 'partial';
      const summary = {
        partial,
        provider: PROVIDER,
        livemode,
        scoped_businesses: scope.businessIds.length,
        payment_method_backfill: paymentMethodBackfill,
        pending_checkout: run.pending_checkout,
        recovered: run.recovered,
        snapshot_at: cursor.snapshot_at,
        cycle_started_at: cursor.cycle_started_at,
        run,
        cycle: {
          processed: cursor.processed,
          matches: cursor.matches,
          mismatches: cursor.mismatches,
          missing_local: cursor.missing_local,
          missing_provider: cursor.missing_provider,
          unscoped_provider: cursor.unscoped_provider,
          failures: cursor.failures,
        },
        pages: {
          local_subscriptions: subscriptionPage.pages,
          local_invoices: invoicePage.pages,
          provider_subscriptions: providerSubscriptionPage.pages,
          provider_invoices: providerInvoicePage.pages,
        },
        scanned: {
          local_subscriptions: subscriptionPage.processed,
          local_invoices: invoicePage.processed,
          provider_subscriptions: providerSubscriptionPage.processed,
          provider_invoices: providerInvoicePage.processed,
        },
        complete: {
          local_subscriptions: cursor.local_subscriptions_complete,
          local_invoices: cursor.local_invoices_complete,
          provider_subscriptions: cursor.provider_subscriptions_complete,
          provider_invoices: cursor.provider_invoices_complete,
        },
      };
      const { error: finishError } = await admin.rpc('finish_billing_reconciliation_v77', {
        p_run: runId,
        p_status: status,
        p_cursor_end: JSON.stringify(cursor),
        p_summary: summary,
      });
      if (finishError) throw new Error('reconciliation completion failed');
      return billingJson(200, { run_id: runId, status, ...summary });
    } catch {
      await admin.rpc('finish_billing_reconciliation_v77', {
        p_run: runId,
        p_status: 'failed',
        p_cursor_end: JSON.stringify(cursor),
        p_summary: {
          partial: true,
          provider: PROVIDER,
          snapshot_at: cursor.snapshot_at,
          run,
          cycle: {
            processed: cursor.processed,
            matches: cursor.matches,
            mismatches: cursor.mismatches,
            missing_local: cursor.missing_local,
            missing_provider: cursor.missing_provider,
            unscoped_provider: cursor.unscoped_provider,
            failures: cursor.failures + 1,
          },
        },
      });
      return billingJson(500, {
        run_id: runId,
        status: 'failed',
        error: 'billing_reconciliation_failed',
      });
    }
  } catch {
    return billingJson(500, { error: 'billing_reconciliation_unavailable' });
  }
});
