type StripeTaxReference = string | { id?: string };

type StripeSubscriptionItemLike = {
  id?: string;
  price?: string | { id?: string };
  quantity?: number;
  tax_rates?: StripeTaxReference[] | null;
};

type StripeSubscriptionLike = {
  automatic_tax?: { enabled?: boolean } | null;
  cancel_at_period_end?: boolean;
  default_tax_rates?: StripeTaxReference[] | null;
  pending_update?: unknown;
  items?: { data?: StripeSubscriptionItemLike[] } | null;
};

type StripePendingUpdateItemV125 = {
  id?: string;
  price?: string;
  quantity?: number;
};

type StripePendingUpdateMetadataV125 = Record<string, string>;

type StripeSubscriptionClientLike = {
  subscriptions: {
    retrieve(subscriptionId: string): Promise<StripeSubscriptionLike>;
    update(
      subscriptionId: string,
      params: {
        automatic_tax: { enabled: false };
        default_tax_rates: [];
        items: Array<{ id: string; tax_rates: [] }>;
        proration_behavior: 'none';
      },
      options: { idempotencyKey: string },
    ): Promise<StripeSubscriptionLike>;
  };
};

const hasTaxReferences = (value: StripeTaxReference[] | null | undefined): boolean =>
  Array.isArray(value) && value.length > 0;

export function stripePendingUpdateParamsV125(
  items: StripePendingUpdateItemV125[],
  metadata: StripePendingUpdateMetadataV125,
) {
  return {
    items,
    proration_behavior: 'always_invoice' as const,
    payment_behavior: 'pending_if_incomplete' as const,
    metadata,
  };
}

function stripeItemPriceIdV125(item: StripeSubscriptionItemLike): string {
  return typeof item.price === 'string' ? item.price : String(item.price?.id || '');
}

/* V202: expectedBaseQuantity defaults to 1, which is every caller that predates branches.
   A branch is billed as another UNIT of the base plan, so a firm with two paid branches
   carries base quantity 3 — and this matcher used to hard-assert 1, which would report a
   perfectly correct subscription as "does not match the command" and send recovery down the
   replay path forever. */
export function stripeSubscriptionMatchesCommandV125(
  subscription: StripeSubscriptionLike,
  commandType: string,
  data: Record<string, unknown>,
  expectedBaseQuantity = 1,
): boolean {
  if (!stripeSubscriptionHasNoTaxV125(subscription)) return false;
  if (commandType === 'cancel_at_period_end') {
    return subscription.cancel_at_period_end === true;
  }
  if (commandType === 'resume') {
    return subscription.cancel_at_period_end === false;
  }
  /* v621: change_branches was missing here, so a branch purchase that Stripe settled
     synchronously ALWAYS failed verification and was persisted 'uncertain' — no branch on a
     live subscription could ever complete. It verifies exactly like the other two item-shape
     commands: the caller passes planUnits (base + billable branches) as expectedBaseQuantity. */
  if (!['change_cadence', 'change_capacity', 'change_branches'].includes(commandType)) return false;
  const capacityModel = data.pricing_model === 'v124_customer_capacity';
  if (capacityModel && subscription.pending_update) return false;
  const items = subscription.items?.data || [];
  const baseItem = items.find(
    (item) => item.id === String(data.provider_base_item_id || ''),
  );
  if (
    !baseItem ||
    stripeItemPriceIdV125(baseItem) !== String(data.provider_base_price_id || '') ||
    baseItem.quantity !== expectedBaseQuantity
  ) {
    return false;
  }
  const extraItemQuantity = Number(
    capacityModel ? data.extra_capacity_blocks || 0 : data.extra_seats || 0,
  );
  const extraItemId = capacityModel
    ? data.provider_capacity_item_id
    : data.provider_seat_item_id;
  const extraPriceId = capacityModel
    ? data.provider_capacity_price_id
    : data.provider_seat_price_id;
  const providerExtraItemId = extraItemId ? String(extraItemId) : '';
  const extraItem = providerExtraItemId
    ? items.find((item) => item.id === providerExtraItemId)
    : undefined;
  return extraItemQuantity > 0
    ? Boolean(
        extraItem &&
          stripeItemPriceIdV125(extraItem) === String(extraPriceId || '') &&
          extraItem.quantity === extraItemQuantity
      )
    : !extraItem;
}

export function stripeSubscriptionHasNoTaxV125(
  subscription: StripeSubscriptionLike,
): boolean {
  if (subscription?.automatic_tax?.enabled === true) return false;
  if (hasTaxReferences(subscription?.default_tax_rates)) return false;
  return (subscription?.items?.data || []).every(
    (item) => !hasTaxReferences(item.tax_rates),
  );
}

export function stripeNoTaxItemUpdatesV125(
  subscription: StripeSubscriptionLike,
): Array<{ id: string; tax_rates: [] }> {
  return (subscription?.items?.data || [])
    .filter((item): item is StripeSubscriptionItemLike & { id: string } =>
      typeof item.id === 'string' && item.id.length > 0
    )
    .map((item) => ({ id: item.id, tax_rates: [] }));
}

export async function enforceProviderNoTaxV125<T extends StripeSubscriptionLike>(
  stripe: StripeSubscriptionClientLike,
  subscriptionId: string,
  idempotencyKey: string,
): Promise<T> {
  const current = await stripe.subscriptions.retrieve(subscriptionId);
  if (stripeSubscriptionHasNoTaxV125(current)) return current as T;
  const repaired = await stripe.subscriptions.update(
    subscriptionId,
    {
      automatic_tax: { enabled: false },
      default_tax_rates: [],
      items: stripeNoTaxItemUpdatesV125(current),
      proration_behavior: 'none',
    },
    { idempotencyKey: `v125-no-tax:${idempotencyKey}` },
  );
  if (!stripeSubscriptionHasNoTaxV125(repaired)) {
    throw new Error('Stripe subscription retained a tax configuration');
  }
  return repaired as T;
}
