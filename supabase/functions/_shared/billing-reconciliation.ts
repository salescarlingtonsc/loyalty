export type BillingReconciliationCursor = {
  version: 2;
  snapshot_at: string;
  cycle_started_at: string;
  local_subscriptions_after: string | null;
  local_subscriptions_complete: boolean;
  local_invoices_after: string | null;
  local_invoices_complete: boolean;
  provider_subscriptions_after: string | null;
  provider_subscriptions_complete: boolean;
  provider_invoices_after: string | null;
  provider_invoices_complete: boolean;
  processed: number;
  matches: number;
  mismatches: number;
  missing_local: number;
  missing_provider: number;
  unscoped_provider: number;
  failures: number;
};

export type KeysetDrainResult = {
  after: string | null;
  complete: boolean;
  pages: number;
  processed: number;
};

export type ProviderPage<T> = {
  data: T[];
  has_more: boolean;
};

export type BillingReconciliationStatus = 'partial' | 'clean' | 'mismatch';

export function newBillingReconciliationCursor(
  snapshotAt: string,
): BillingReconciliationCursor {
  return {
    version: 2,
    snapshot_at: snapshotAt,
    cycle_started_at: snapshotAt,
    local_subscriptions_after: null,
    local_subscriptions_complete: false,
    local_invoices_after: null,
    local_invoices_complete: false,
    provider_subscriptions_after: null,
    provider_subscriptions_complete: false,
    provider_invoices_after: null,
    provider_invoices_complete: false,
    processed: 0,
    matches: 0,
    mismatches: 0,
    missing_local: 0,
    missing_provider: 0,
    unscoped_provider: 0,
    failures: 0,
  };
}

export function parseBillingReconciliationCursor(
  value: unknown,
): BillingReconciliationCursor | null {
  if (typeof value !== 'string' || !value) return null;
  try {
    const parsed = JSON.parse(value) as Partial<BillingReconciliationCursor>;
    if (
      parsed.version !== 2 ||
      typeof parsed.snapshot_at !== 'string' ||
      !Number.isFinite(Date.parse(parsed.snapshot_at)) ||
      typeof parsed.cycle_started_at !== 'string' ||
      !Number.isFinite(Date.parse(parsed.cycle_started_at))
    ) {
      return null;
    }
    return {
      version: 2,
      snapshot_at: parsed.snapshot_at,
      cycle_started_at: parsed.cycle_started_at,
      local_subscriptions_after:
        typeof parsed.local_subscriptions_after === 'string'
          ? parsed.local_subscriptions_after
          : null,
      local_subscriptions_complete:
        parsed.local_subscriptions_complete === true,
      local_invoices_after:
        typeof parsed.local_invoices_after === 'string'
          ? parsed.local_invoices_after
          : null,
      local_invoices_complete: parsed.local_invoices_complete === true,
      provider_subscriptions_after:
        typeof parsed.provider_subscriptions_after === 'string'
          ? parsed.provider_subscriptions_after
          : null,
      provider_subscriptions_complete:
        parsed.provider_subscriptions_complete === true,
      provider_invoices_after:
        typeof parsed.provider_invoices_after === 'string'
          ? parsed.provider_invoices_after
          : null,
      provider_invoices_complete: parsed.provider_invoices_complete === true,
      processed: Math.max(0, Number(parsed.processed) || 0),
      matches: Math.max(0, Number(parsed.matches) || 0),
      mismatches: Math.max(0, Number(parsed.mismatches) || 0),
      missing_local: Math.max(0, Number(parsed.missing_local) || 0),
      missing_provider: Math.max(0, Number(parsed.missing_provider) || 0),
      unscoped_provider: Math.max(
        0,
        Number(parsed.unscoped_provider) || 0,
      ),
      failures: Math.max(0, Number(parsed.failures) || 0),
    };
  } catch {
    return null;
  }
}

export async function drainBoundedKeysetPages<T>({
  after,
  pageSize,
  maxPages,
  keyOf,
  fetchPage,
  consumePage,
}: {
  after: string | null;
  pageSize: number;
  maxPages: number;
  keyOf: (row: T) => string;
  fetchPage: (after: string | null, limit: number) => Promise<T[]>;
  consumePage: (rows: T[]) => Promise<void>;
}): Promise<KeysetDrainResult> {
  let cursor = after;
  let pages = 0;
  let processed = 0;
  while (pages < maxPages) {
    const fetched = await fetchPage(cursor, pageSize + 1);
    const rows = fetched.slice(0, pageSize);
    if (rows.length) {
      const keys = rows.map(keyOf);
      if (
        keys.some((key) => !key) ||
        keys.some((key, index) => index > 0 && key <= keys[index - 1]) ||
        (cursor !== null && keys[0] <= cursor)
      ) {
        throw new Error('billing reconciliation keyset did not advance');
      }
      await consumePage(rows);
      cursor = keys[keys.length - 1];
      processed += rows.length;
    }
    pages += 1;
    if (fetched.length <= pageSize) {
      return { after: cursor, complete: true, pages, processed };
    }
    if (!rows.length) {
      throw new Error('billing reconciliation page did not advance');
    }
  }
  return { after: cursor, complete: false, pages, processed };
}

export async function drainBoundedProviderPages<T extends { id: string }>({
  after,
  maxPages,
  fetchPage,
  consumePage,
}: {
  after: string | null;
  maxPages: number;
  fetchPage: (after: string | null) => Promise<ProviderPage<T>>;
  consumePage: (rows: T[]) => Promise<void>;
}): Promise<KeysetDrainResult> {
  let cursor = after;
  let pages = 0;
  let processed = 0;
  while (pages < maxPages) {
    const page = await fetchPage(cursor);
    const rows = page.data;
    const ids = rows.map((row) => row.id);
    if (
      ids.some((id) => !id) ||
      new Set(ids).size !== ids.length ||
      (cursor !== null && ids.includes(cursor))
    ) {
      throw new Error('billing provider pagination did not advance');
    }
    if (page.has_more && !rows.length) {
      throw new Error('billing provider pagination returned an empty continuation');
    }
    await consumePage(rows);
    if (rows.length) cursor = rows[rows.length - 1].id;
    processed += rows.length;
    pages += 1;
    if (!page.has_more) {
      return { after: cursor, complete: true, pages, processed };
    }
  }
  return { after: cursor, complete: false, pages, processed };
}

export function billingReconciliationStatus(
  cursor: BillingReconciliationCursor,
): BillingReconciliationStatus {
  const complete =
    cursor.local_subscriptions_complete &&
    cursor.local_invoices_complete &&
    cursor.provider_subscriptions_complete &&
    cursor.provider_invoices_complete;
  if (!complete) return 'partial';
  return cursor.mismatches ||
      cursor.missing_local ||
      cursor.missing_provider ||
      cursor.failures
    ? 'mismatch'
    : 'clean';
}

export function providerIdsMissingLocally(
  providerIds: string[],
  localProviderIds: Iterable<string>,
): string[] {
  const local = new Set(localProviderIds);
  return providerIds.filter((id) => !local.has(id));
}
