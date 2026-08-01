import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';
import {
  enforceProviderNoTaxV125,
  stripeNoTaxItemUpdatesV125,
  stripePendingUpdateParamsV125,
  stripeSubscriptionHasNoTaxV125,
  stripeSubscriptionMatchesCommandV125,
} from '../../supabase/functions/_shared/billing-tax-policy-v125.ts';
import { publicGatewayOrigins } from '../../supabase/functions/_shared/validation.ts';
import { turnstileBindingValid } from '../../supabase/functions/_shared/security.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

test('V125 records one fail-closed no-GST platform policy and catalogue contract', async () => {
  const sql = await read('supabase/migrations/20260731182246_nestly_v125_no_gst_and_native_store_readiness.sql');
  assert.match(sql, /create table public\.platform_billing_tax_policy_v125/i);
  assert.match(sql, /gst_registered boolean not null default false/i);
  assert.match(sql, /tax_collection_enabled boolean not null default false/i);
  assert.match(sql, /gst_registered\s*=\s*false[\s\S]+tax_collection_enabled\s*=\s*false/i);
  assert.match(sql, /tax_behavior\s*=\s*'exclusive'/i);
  assert.match(sql, /period_tax_cents[\s\S]+<>\s*0/i);
  assert.match(sql, /GST not charged/i);
});

test('Stripe catalogue and executor pin exclusive prices and keep automatic tax disabled', async () => {
  const [setup, edge] = await Promise.all([
    read('scripts/stripe/setup-v124-catalog.mjs'),
    read('supabase/functions/stripe-billing-command/index.ts'),
  ]);
  assert.match(setup, /tax_behavior:\s*'exclusive'/i);
  assert.match(setup, /price\.tax_behavior\s*===\s*'exclusive'/i);
  assert.match(edge, /price\.tax_behavior\s*===\s*'exclusive'/i);
  assert.match(edge, /data\.tax_behavior\s*!==\s*'exclusive'/i);
  assert.match(edge, /automatic_tax:\s*\{\s*enabled:\s*false\s*\}/i);
  assert.match(edge, /default_tax_rates:\s*\[\]/i);
  assert.match(edge, /stripeSubscriptionHasNoTaxV125\(verifiedSubscription\)/i);
  assert.match(edge, /stripe\.subscriptions\.retrieve\(subscriptionId\)/i);
});

test('pending Stripe subscription changes contain only supported no-tax-safe fields', () => {
  const params = stripePendingUpdateParamsV125(
    [
      { id: 'si_base', price: 'price_annual', quantity: 1 },
      { id: 'si_capacity', price: 'price_capacity_annual', quantity: 2 },
    ],
    { business_id: 'business_fixture', cadence: 'annual' },
  );
  assert.deepEqual(params, {
    items: [
      { id: 'si_base', price: 'price_annual', quantity: 1 },
      { id: 'si_capacity', price: 'price_capacity_annual', quantity: 2 },
    ],
    proration_behavior: 'always_invoice',
    payment_behavior: 'pending_if_incomplete',
    metadata: { business_id: 'business_fixture', cadence: 'annual' },
  });
  assert.equal('automatic_tax' in params, false);
  assert.equal('default_tax_rates' in params, false);
  assert.equal(params.items.some((item) => 'tax_rates' in item), false);
});

test('fresh provider state must match the requested command before completion', () => {
  const data = {
    pricing_model: 'v124_customer_capacity',
    provider_base_item_id: 'si_base',
    provider_base_price_id: 'price_annual',
    provider_capacity_item_id: 'si_capacity',
    provider_capacity_price_id: 'price_capacity_annual',
    extra_capacity_blocks: 2,
  };
  const current = {
    automatic_tax: { enabled: false },
    default_tax_rates: [],
    pending_update: null,
    items: { data: [
      { id: 'si_base', price: { id: 'price_annual' }, quantity: 1, tax_rates: [] },
      { id: 'si_capacity', price: { id: 'price_capacity_annual' }, quantity: 2, tax_rates: [] },
    ] },
  };
  assert.equal(stripeSubscriptionMatchesCommandV125(current, 'change_capacity', data), true);
  assert.equal(stripeSubscriptionMatchesCommandV125({
    ...current,
    items: { data: [
      { id: 'si_base', price: { id: 'price_monthly' }, quantity: 1, tax_rates: [] },
      { id: 'si_capacity', price: { id: 'price_capacity_annual' }, quantity: 1, tax_rates: [] },
    ] },
  }, 'change_capacity', data), false);
  assert.equal(stripeSubscriptionMatchesCommandV125({
    ...current,
    cancel_at_period_end: false,
  }, 'cancel_at_period_end', data), false);
});

test('existing Stripe subscription tax is cleared and cannot satisfy recovery', async () => {
  const clean = {
    automatic_tax: { enabled: false },
    default_tax_rates: [],
    items: { data: [{ id: 'si_base', tax_rates: [] }, { id: 'si_capacity' }] },
  };
  assert.equal(stripeSubscriptionHasNoTaxV125(clean), true);
  assert.equal(stripeSubscriptionHasNoTaxV125({ ...clean, automatic_tax: { enabled: true } }), false);
  assert.equal(stripeSubscriptionHasNoTaxV125({ ...clean, default_tax_rates: ['txr_default'] }), false);
  assert.equal(stripeSubscriptionHasNoTaxV125({
    ...clean,
    items: { data: [{ id: 'si_base', tax_rates: ['txr_item'] }] },
  }), false);
  assert.deepEqual(stripeNoTaxItemUpdatesV125({
    items: { data: [{ id: 'si_base', tax_rates: ['txr_item'] }, { tax_rates: ['ignored'] }] },
  }), [{ id: 'si_base', tax_rates: [] }]);

  let updateCall=null;
  const repaired={
    automatic_tax:{enabled:false},default_tax_rates:[],
    items:{data:[{id:'si_base',tax_rates:[]},{id:'si_capacity',tax_rates:[]}]},
  };
  const provider={subscriptions:{
    async retrieve(){return {
      automatic_tax:{enabled:true},default_tax_rates:['txr_default'],
      items:{data:[{id:'si_base',tax_rates:['txr_item']},{id:'si_capacity',tax_rates:[]}]},
    }},
    async update(subscriptionId,params,options){updateCall={subscriptionId,params,options};return repaired},
  }};
  assert.equal(await enforceProviderNoTaxV125(provider,'sub_fixture','cmd_fixture'),repaired);
  assert.deepEqual(updateCall,{
    subscriptionId:'sub_fixture',
    params:{
      automatic_tax:{enabled:false},default_tax_rates:[],
      items:[{id:'si_base',tax_rates:[]},{id:'si_capacity',tax_rates:[]}],
      proration_behavior:'none',
    },
    options:{idempotencyKey:'v125-no-tax:cmd_fixture'},
  });
});

test('owner and platform billing say GST is not charged and preserve the provider total', async () => {
  const [owner, platform] = await Promise.all([
    read('app/index.html'),
    read('app/platform-console.js'),
  ]);
  assert.match(owner, /GST not charged[^<]*SGD 0\.00/i);
  assert.match(owner, /Billing cycle[\s\S]+align-items:stretch;flex-wrap:wrap/i);
  assert.doesNotMatch(owner, /Recurring total\$\{plan\.tax_behavior===\s*'exclusive'\?' before GST'/i);
  assert.match(platform, /GST not charged/i);
  assert.match(platform, /Amount due/i);
  assert.doesNotMatch(platform, /Subtotal before GST/);
  assert.doesNotMatch(platform, /Total including GST/);
  assert.doesNotMatch(platform, /\{amount\} incl\. GST/);
});

test('native store projects are generated from the canonical app source with a stable identifier', async () => {
  const [pkg, config, wrapper, androidTest] = await Promise.all([
    read('package.json'),
    read('capacitor.config.ts'),
    read('docs/mobile/capacitor-wrapper.md'),
    read('android/app/src/androidTest/java/com/getcapacitor/myapp/ExampleInstrumentedTest.java'),
  ]);
  assert.match(pkg, /"@capacitor\/core"/);
  assert.match(pkg, /"mobile:sync"/);
  assert.match(config, /appId:\s*'asia\.peekaa\.app'/);
  assert.match(config, /webDir:\s*'dist\/mobile'/);
  assert.match(wrapper, /owner activated\s+native-store work on 2026-08-01/i);
  await access(new URL('ios/App/App.xcodeproj/project.pbxproj', root));
  await access(new URL('android/app/build.gradle', root));
  const android = await read('android/app/build.gradle');
  assert.match(android, /targetSdkVersion\s+rootProject\.ext\.targetSdkVersion/);
  assert.match(androidTest, /package asia\.peekaa\.app/);
  assert.match(androidTest, /assertEquals\("asia\.peekaa\.app"/);
  assert.doesNotMatch(androidTest, /com\.getcapacitor\.(?:app|myapp)/);
});

test('native origins are exact, Turnstile-bound, and outbound links stay on the public HTTPS origin', async () => {
  assert.deepEqual(publicGatewayOrigins(''), [
    'https://peekaa.asia',
    'https://www.peekaa.asia',
    'https://nestly.asia',
    'https://www.nestly.asia',
    'capacitor://localhost',
    'https://localhost',
  ]);
  assert.equal(turnstileBindingValid(
    { success: true, action: 'frenly_customer_password', hostname: 'localhost' },
    'frenly_customer_password',
    'localhost',
    false,
  ), true);
  assert.equal(turnstileBindingValid(
    { success: true, action: 'frenly_customer_password', hostname: 'www.peekaa.asia' },
    'frenly_customer_password',
    'localhost',
    false,
  ), false);

  const source = await read('app/native-bridge.js');
  const window = {
    location: { href: 'capacitor://localhost/#/', assign() {} },
    navigator: { onLine: true },
    open() {},
  };
  vm.runInNewContext(source, { window, URL, CustomEvent: class {} });
  assert.equal(
    window.NestlyNativeBridge.publicUrl('/#/join?token=fixture'),
    'https://www.peekaa.asia/#/join?token=fixture',
  );
  assert.throws(
    () => window.NestlyNativeBridge.publicUrl('https://attacker.invalid/#/join'),
    /canonical origin/i,
  );
});

test('bundled WebView has a restrictive CSP and no shared customer link uses the local origin', async () => {
  const [app, join] = await Promise.all([read('app/index.html'), read('app/join.html')]);
  assert.match(app, /<meta http-equiv="Content-Security-Policy"[^>]+default-src 'self'/i);
  assert.match(join, /<meta http-equiv="Content-Security-Policy"[^>]+default-src 'self'/i);
  assert.match(app, /connect-src 'self' https:\/\/\*\.supabase\.co wss:\/\/\*\.supabase\.co/i);
  assert.match(join, /connect-src 'self' https:\/\/\*\.supabase\.co wss:\/\/\*\.supabase\.co/i);
  assert.match(app, /const publicAppUrl=.*NestlyNativeBridge\.publicUrl/i);
  assert.match(app, /emailRedirectTo:returnUrl\.toString\(\)/i);
  assert.match(app, /new URL\(NestlyNativeBridge\.publicUrl\('\/business'\)\)/i);
  assert.match(app, /const redirect=new URL\(NestlyNativeBridge\.publicUrl\(admin\?'\/admin':'\/business'\)\)/i);
  assert.doesNotMatch(app, /(?:emailRedirectTo|redirectTo):[^\n]+location\.(?:origin|href)/i);
  assert.doesNotMatch(app, /location\.origin\$\{location\.pathname\}#\/(?:join|b|redeem)/i);
});
