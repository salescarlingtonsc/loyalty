#!/usr/bin/env node

const secret = process.env.STRIPE_SECRET_KEY || '';
const args = new Set(process.argv.slice(2));
const apply = args.has('--apply');
const allowLive = args.has('--allow-live');

if (!apply) {
  throw new Error('Refusing to mutate Stripe without --apply. Use a test key first.');
}
if (!/^sk_(?:test|live)_[A-Za-z0-9]+$/.test(secret)) {
  throw new Error('STRIPE_SECRET_KEY must be supplied through the environment.');
}
const livemode = secret.startsWith('sk_live_');
if (livemode && !allowLive) {
  throw new Error('Refusing live Stripe changes without --allow-live.');
}

const api = async (method, path, fields) => {
  const init = {
    method,
    headers: { Authorization: `Bearer ${secret}` },
  };
  if (fields) {
    init.headers['Content-Type'] = 'application/x-www-form-urlencoded';
    init.body = new URLSearchParams(fields);
  }
  const response = await fetch(`https://api.stripe.com${path}`, init);
  const body = await response.json();
  if (!response.ok) {
    throw new Error(`Stripe ${method} ${path} failed: ${body?.error?.message || response.status}`);
  }
  return body;
};

const products = await api('GET', '/v1/products?active=true&limit=100');
let product = products.data.find(
  (candidate) => candidate.metadata?.nestly_pricing_model === 'v124_customer_capacity',
);
if (!product) {
  product = await api('POST', '/v1/products', {
    name: 'Nestly Business Subscription',
    description: 'Nestly business workspace with customer-capacity billing; staff access included.',
    'metadata[nestly_pricing_model]': 'v124_customer_capacity',
    'metadata[included_customer_capacity]': '1000',
    'metadata[capacity_block_size]': '1000',
  });
}

const definitions = [
  {
    role: 'base', cadence: 'monthly', lookupKey: 'nestly_v124_monthly_base_sgd',
    unitAmount: 14900, interval: 'month', tax_behavior: 'exclusive', nickname: 'Nestly monthly base — 1,000 customers',
  },
  {
    role: 'capacity', cadence: 'monthly', lookupKey: 'nestly_v124_monthly_capacity_1000_sgd',
    unitAmount: 1000, interval: 'month', tax_behavior: 'exclusive', nickname: 'Nestly monthly — additional 1,000 customers',
  },
  {
    role: 'base', cadence: 'annual', lookupKey: 'nestly_v124_annual_base_sgd',
    unitAmount: 118800, interval: 'year', tax_behavior: 'exclusive', nickname: 'Nestly annual base — 1,000 customers',
  },
  {
    role: 'capacity', cadence: 'annual', lookupKey: 'nestly_v124_annual_capacity_1000_sgd',
    unitAmount: 12000, interval: 'year', tax_behavior: 'exclusive', nickname: 'Nestly annual — additional 1,000 customers',
  },
];

const result = { livemode, product_id: product.id, prices: {} };
for (const definition of definitions) {
  const existing = await api(
    'GET',
    `/v1/prices?active=true&limit=1&lookup_keys[]=${encodeURIComponent(definition.lookupKey)}`,
  );
  let price = existing.data[0];
  if (price) {
    const matches = price.product === product.id
      && price.currency === 'sgd'
      && price.unit_amount === definition.unitAmount
      && price.type === 'recurring'
      && price.recurring?.interval === definition.interval
      && price.recurring?.interval_count === 1
      && price.recurring?.usage_type === 'licensed'
      && price.tax_behavior === 'exclusive';
    if (!matches) {
      throw new Error(`Existing Stripe lookup key ${definition.lookupKey} conflicts with reviewed V125 no-GST pricing.`);
    }
  } else {
    price = await api('POST', '/v1/prices', {
      product: product.id,
      currency: 'sgd',
      unit_amount: String(definition.unitAmount),
      tax_behavior: definition.tax_behavior,
      lookup_key: definition.lookupKey,
      nickname: definition.nickname,
      'recurring[interval]': definition.interval,
      'recurring[interval_count]': '1',
      'recurring[usage_type]': 'licensed',
      'metadata[nestly_pricing_model]': 'v124_customer_capacity',
      'metadata[item_role]': definition.role,
      'metadata[cadence]': definition.cadence,
      'metadata[capacity_block_size]': '1000',
    });
  }
  result.prices[`${definition.cadence}_${definition.role}`] = price.id;
}

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
