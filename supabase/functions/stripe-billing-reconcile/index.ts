import Stripe from 'npm:stripe@18.5.0';
import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';
import {
  billingReconciliationStatus,
  drainBoundedKeysetPages,
  drainBoundedProviderPages,
  newBillingReconciliationCursor,
  parseBillingReconciliationCursor,
  providerIdsMissingLocally,
  type BillingReconciliationCursor,
} from '../_shared/billing-reconciliation.ts';

const LOCAL_OBJECTS_PER_PAGE = 100;
const PROVIDER_OBJECTS_PER_PAGE = 100;
const MAX_PAGES_PER_STREAM = 1;
const MAX_PROVIDER_LOOKUP_CONCURRENCY = 8;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type ReconciliationResult =
  | 'match'
  | 'mismatch'
  | 'missing_local'
  | 'missing_provider'
  | 'failed';

type LocalSubscription = {
  business_id: string;
  provider_subscription_id: string;
  status: string;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
};

type LocalInvoice = {
  business_id: string;
  provider_invoice_id: string;
  status: string;
  paid_normalized: boolean;
  subtotal_ex_tax_cents: number;
  tax_cents: number;
  total_cents: number;
  amount_paid_cents: number;
  amount_remaining_cents: number;
  paid_at: string | null;
};

type RunCounts = {
  processed: number;
  matches: number;
  mismatches: number;
  missing_local: number;
  missing_provider: number;
  unscoped_provider: number;
  failures: number;
};

function epoch(value: unknown): string | null {
  return typeof value === 'number' && Number.isFinite(value)
    ? new Date(value * 1000).toISOString()
    : null;
}

function reconciliationAuthorized(req: Request): boolean {
  const expected = requiredEnv('BILLING_RECONCILIATION_SECRET');
  const supplied = req.headers.get('x-nestly-reconciliation-secret') || '';
  return expected.length >= 32 && supplied === expected;
}

async function digest(value: Record<string, unknown>): Promise<string> {
  const entries = Object.entries(value).sort(([left], [right]) =>
    left.localeCompare(right)
  );
  return sha256Hex(JSON.stringify(Object.fromEntries(entries)));
}

function stripeSubscriptionSnapshot(
  subscription: Stripe.Subscription,
): Record<string, unknown> {
  const raw = subscription as Stripe.Subscription & {
    current_period_end?: number;
  };
  const itemPeriodEnds = subscription.items.data
    .map((item) =>
      (item as typeof item & { current_period_end?: number }).current_period_end
    )
    .filter((value): value is number => typeof value === 'number');
  return {
    status: subscription.status,
    current_period_end: epoch(
      raw.current_period_end ??
        (itemPeriodEnds.length ? Math.max(...itemPeriodEnds) : null),
    ),
    cancel_at_period_end: subscription.cancel_at_period_end,
  };
}

function localSubscriptionSnapshot(
  subscription: LocalSubscription,
): Record<string, unknown> {
  return {
    status: subscription.status,
    current_period_end: subscription.current_period_end,
    cancel_at_period_end: subscription.cancel_at_period_end,
  };
}

function stripeInvoiceSnapshot(invoice: Stripe.Invoice): Record<string, unknown> {
  const raw = invoice as Stripe.Invoice & {
    subtotal_excluding_tax?: number | null;
    status_transitions?: { paid_at?: number | null };
  };
  return {
    status: invoice.status,
    paid_normalized:
      invoice.status === 'paid' && Boolean(raw.status_transitions?.paid_at),
    subtotal_ex_tax_cents:
      raw.subtotal_excluding_tax == null
        ? invoice.subtotal
        : raw.subtotal_excluding_tax,
    tax_cents: Math.max(
      invoice.total -
        (raw.subtotal_excluding_tax == null
          ? invoice.subtotal
          : raw.subtotal_excluding_tax),
      0,
    ),
    total_cents: invoice.total,
    amount_paid_cents: invoice.amount_paid,
    amount_remaining_cents: invoice.amount_remaining,
    paid_at: epoch(raw.status_transitions?.paid_at),
  };
}

function localInvoiceSnapshot(invoice: LocalInvoice): Record<string, unknown> {
  return {
    status: invoice.status,
    paid_normalized: invoice.paid_normalized,
    subtotal_ex_tax_cents: invoice.subtotal_ex_tax_cents,
    tax_cents: invoice.tax_cents,
    total_cents: invoice.total_cents,
    amount_paid_cents: invoice.amount_paid_cents,
    amount_remaining_cents: invoice.amount_remaining_cents,
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
  } else {
    cursor.failures += 1;
    run.failures += 1;
  }
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
    Array.from(
      { length: Math.min(concurrency, rows.length) },
      async () => {
        while (next < rows.length) {
          const index = next++;
          results[index] = await worker(rows[index]);
        }
      },
    ),
  );
  return results;
}

function metadataBusinessId(value: unknown): string | null {
  return typeof value === 'string' && UUID.test(value) ? value : null;
}

function providerBusinessId(
  provider: Stripe.Subscription | Stripe.Invoice,
): string | null {
  const raw = provider as unknown as {
    metadata?: Record<string, string>;
    subscription_details?: { metadata?: Record<string, string> } | null;
    parent?: {
      subscription_details?: { metadata?: Record<string, string> } | null;
    } | null;
  };
  return (
    metadataBusinessId(raw.metadata?.business_id) ||
    metadataBusinessId(raw.subscription_details?.metadata?.business_id) ||
    metadataBusinessId(
      raw.parent?.subscription_details?.metadata?.business_id,
    )
  );
}

async function existingLocalProviderIds(
  admin: ReturnType<typeof billingAdminClient>,
  table: 'billing_provider_subscriptions' | 'billing_provider_invoices',
  column: 'provider_subscription_id' | 'provider_invoice_id',
  providerIds: string[],
  snapshotAt: string,
): Promise<Set<string>> {
  if (!providerIds.length) return new Set();
  // Existence is evaluated against cycle membership. A post-snapshot update
  // must not make a pre-snapshot local row appear missing.
  const { data, error } = await admin
    .from(table)
    .select(column)
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
  return data?.status === 'partial'
    ? parseBillingReconciliationCursor(data.cursor_end)
    : null;
}

async function reconcileSubscriptions({
  admin,
  stripe,
  runId,
  cursor,
  run,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  stripe: Stripe;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
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
      // The snapshot pins membership, not historical row values: rows created
      // by the boundary stay in the cycle even if a later webhook updates them.
      let query = admin
        .from('billing_provider_subscriptions')
        .select(
          'business_id,provider_subscription_id,status,current_period_end,cancel_at_period_end',
        )
        .lte('created_at', cursor.snapshot_at)
        .order('provider_subscription_id', { ascending: true })
        .limit(limit);
      if (after) query = query.gt('provider_subscription_id', after);
      const { data, error } = await query;
      if (error) throw new Error('local subscription projection unavailable');
      return (data || []) as LocalSubscription[];
    },
    consumePage: async (rows) => {
      const outcomes = await mapWithConcurrency(
        rows,
        MAX_PROVIDER_LOOKUP_CONCURRENCY,
        async (local) => {
          try {
            const provider = await stripe.subscriptions.retrieve(
              local.provider_subscription_id,
            );
            const expected = stripeSubscriptionSnapshot(provider);
            const actual = localSubscriptionSnapshot(local);
            const [expectedDigest, actualDigest] = await Promise.all([
              digest(expected),
              digest(actual),
            ]);
            const result =
              expectedDigest === actualDigest ? 'match' : 'mismatch';
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
                detail:
                  result === 'match'
                    ? {}
                    : { provider: expected, nestly: actual },
              },
            };
          } catch (error) {
            const result: ReconciliationResult =
              error instanceof Stripe.errors.StripeInvalidRequestError
                ? 'missing_provider'
                : 'failed';
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
  stripe,
  runId,
  cursor,
  run,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  stripe: Stripe;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
}) {
  if (cursor.local_invoices_complete) {
    return {
      after: cursor.local_invoices_after,
      complete: true,
      pages: 0,
      processed: 0,
    };
  }
  return drainBoundedKeysetPages<LocalInvoice>({
    after: cursor.local_invoices_after,
    pageSize: LOCAL_OBJECTS_PER_PAGE,
    maxPages: MAX_PAGES_PER_STREAM,
    keyOf: (row) => row.provider_invoice_id,
    fetchPage: async (after, limit) => {
      // Membership is snapshot-pinned by creation time. Selected projection
      // fields remain the current/live state at reconciliation time.
      let query = admin
        .from('billing_provider_invoices')
        .select(
          'business_id,provider_invoice_id,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,amount_remaining_cents,paid_at',
        )
        .lte('created_at', cursor.snapshot_at)
        .order('provider_invoice_id', { ascending: true })
        .limit(limit);
      if (after) query = query.gt('provider_invoice_id', after);
      const { data, error } = await query;
      if (error) throw new Error('local invoice projection unavailable');
      return (data || []) as LocalInvoice[];
    },
    consumePage: async (rows) => {
      const outcomes = await mapWithConcurrency(
        rows,
        MAX_PROVIDER_LOOKUP_CONCURRENCY,
        async (local) => {
          try {
            const provider = await stripe.invoices.retrieve(
              local.provider_invoice_id,
            );
            const expected = stripeInvoiceSnapshot(provider);
            const actual = localInvoiceSnapshot(local);
            const [expectedDigest, actualDigest] = await Promise.all([
              digest(expected),
              digest(actual),
            ]);
            const result =
              expectedDigest === actualDigest ? 'match' : 'mismatch';
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
                detail:
                  result === 'match'
                    ? {}
                    : { provider: expected, nestly: actual },
              },
            };
          } catch (error) {
            const result: ReconciliationResult =
              error instanceof Stripe.errors.StripeInvalidRequestError
                ? 'missing_provider'
                : 'failed';
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
  stripe,
  runId,
  cursor,
  run,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  stripe: Stripe;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
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
  return drainBoundedProviderPages<Stripe.Subscription>({
    after: cursor.provider_subscriptions_after,
    maxPages: MAX_PAGES_PER_STREAM,
    fetchPage: async (after) => {
      const page = await stripe.subscriptions.list({
        status: 'all',
        created: { lte: createdLte },
        limit: PROVIDER_OBJECTS_PER_PAGE,
        ...(after ? { starting_after: after } : {}),
      });
      return { data: page.data, has_more: page.has_more };
    },
    consumePage: async (providers) => {
      const candidates = new Map(
        providers.map((provider) => [provider.id, providerBusinessId(provider)]),
      );
      const businessIds = await existingBusinessIds(
        admin,
        [...candidates.values()],
      );
      const scoped = providers.filter((provider) => {
        const candidate = candidates.get(provider.id);
        return Boolean(candidate && businessIds.has(candidate));
      });
      const unscoped = providers.length - scoped.length;
      cursor.unscoped_provider += unscoped;
      run.unscoped_provider += unscoped;
      const localIds = await existingLocalProviderIds(
        admin,
        'billing_provider_subscriptions',
        'provider_subscription_id',
        scoped.map(({ id }) => id),
        cursor.snapshot_at,
      );
      const missingIds = new Set(
        providerIdsMissingLocally(
          scoped.map(({ id }) => id),
          localIds,
        ),
      );
      const missing = scoped.filter(({ id }) => missingIds.has(id));
      const items = await Promise.all(
        missing.map(async (provider) => {
          const candidate = candidates.get(provider.id);
          if (!candidate || !businessIds.has(candidate)) {
            throw new Error('scoped provider subscription lost business mapping');
          }
          recordResult(cursor, run, 'missing_local');
          return {
            run_id: runId,
            business_id: candidate,
            object_type: 'subscription',
            provider_object_id: provider.id,
            result: 'missing_local',
            expected_digest: await digest(
              stripeSubscriptionSnapshot(provider),
            ),
            actual_digest: null,
            detail: {
              reason: 'provider_subscription_missing_local',
              provider_created_at: epoch(provider.created),
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
  stripe,
  runId,
  cursor,
  run,
}: {
  admin: ReturnType<typeof billingAdminClient>;
  stripe: Stripe;
  runId: string;
  cursor: BillingReconciliationCursor;
  run: RunCounts;
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
  return drainBoundedProviderPages<Stripe.Invoice>({
    after: cursor.provider_invoices_after,
    maxPages: MAX_PAGES_PER_STREAM,
    fetchPage: async (after) => {
      const page = await stripe.invoices.list({
        created: { lte: createdLte },
        limit: PROVIDER_OBJECTS_PER_PAGE,
        ...(after ? { starting_after: after } : {}),
      });
      return { data: page.data, has_more: page.has_more };
    },
    consumePage: async (providers) => {
      const candidates = new Map(
        providers.map((provider) => [provider.id, providerBusinessId(provider)]),
      );
      const businessIds = await existingBusinessIds(
        admin,
        [...candidates.values()],
      );
      const scoped = providers.filter((provider) => {
        const candidate = candidates.get(provider.id);
        return Boolean(candidate && businessIds.has(candidate));
      });
      const unscoped = providers.length - scoped.length;
      cursor.unscoped_provider += unscoped;
      run.unscoped_provider += unscoped;
      const localIds = await existingLocalProviderIds(
        admin,
        'billing_provider_invoices',
        'provider_invoice_id',
        scoped.map(({ id }) => id),
        cursor.snapshot_at,
      );
      const missingIds = new Set(
        providerIdsMissingLocally(
          scoped.map(({ id }) => id),
          localIds,
        ),
      );
      const missing = scoped.filter(({ id }) => missingIds.has(id));
      const items = await Promise.all(
        missing.map(async (provider) => {
          const candidate = candidates.get(provider.id);
          if (!candidate || !businessIds.has(candidate)) {
            throw new Error('scoped provider invoice lost business mapping');
          }
          recordResult(cursor, run, 'missing_local');
          return {
            run_id: runId,
            business_id: candidate,
            object_type: 'invoice',
            provider_object_id: provider.id,
            result: 'missing_local',
            expected_digest: await digest(stripeInvoiceSnapshot(provider)),
            actual_digest: null,
            detail: {
              reason: 'provider_invoice_missing_local',
              provider_created_at: epoch(provider.created),
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
      return billingJson(401, {
        error: 'reconciliation_authentication_required',
      });
    }

    const admin = billingAdminClient();
    const stripe = new Stripe(requiredEnv('STRIPE_SECRET_KEY'), {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const resume = await priorCursor(admin);
    const cursor =
      resume || newBillingReconciliationCursor(completedSecondSnapshot());
    const { data: runId, error: startError } = await admin.rpc(
      'start_billing_reconciliation_v77',
      { p_run_mode: 'scheduled', p_cursor_start: JSON.stringify(cursor) },
    );
    if (startError || !runId) {
      return billingJson(500, { error: 'reconciliation_start_failed' });
    }

    const run: RunCounts = {
      processed: 0,
      matches: 0,
      mismatches: 0,
      missing_local: 0,
      missing_provider: 0,
      unscoped_provider: 0,
      failures: 0,
    };
    try {
      const subscriptionPage = await reconcileSubscriptions({
        admin,
        stripe,
        runId,
        cursor,
        run,
      });
      cursor.local_subscriptions_after = subscriptionPage.after;
      cursor.local_subscriptions_complete = subscriptionPage.complete;

      const invoicePage = await reconcileInvoices({
        admin,
        stripe,
        runId,
        cursor,
        run,
      });
      cursor.local_invoices_after = invoicePage.after;
      cursor.local_invoices_complete = invoicePage.complete;

      const providerSubscriptionPage = await reconcileProviderSubscriptions({
        admin,
        stripe,
        runId,
        cursor,
        run,
      });
      cursor.provider_subscriptions_after = providerSubscriptionPage.after;
      cursor.provider_subscriptions_complete =
        providerSubscriptionPage.complete;

      const providerInvoicePage = await reconcileProviderInvoices({
        admin,
        stripe,
        runId,
        cursor,
        run,
      });
      cursor.provider_invoices_after = providerInvoicePage.after;
      cursor.provider_invoices_complete = providerInvoicePage.complete;

      const status = billingReconciliationStatus(cursor);
      const partial = status === 'partial';
      const summary = {
        partial,
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
      const { error: finishError } = await admin.rpc(
        'finish_billing_reconciliation_v77',
        {
          p_run: runId,
          p_status: status,
          p_cursor_end: JSON.stringify(cursor),
          p_summary: summary,
        },
      );
      if (finishError) throw new Error('reconciliation completion failed');
      return billingJson(200, { run_id: runId, status, ...summary });
    } catch {
      await admin.rpc('finish_billing_reconciliation_v77', {
        p_run: runId,
        p_status: 'failed',
        p_cursor_end: JSON.stringify(cursor),
        p_summary: {
          partial: true,
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
