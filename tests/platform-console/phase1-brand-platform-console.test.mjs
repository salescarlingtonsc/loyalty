import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root = new URL('../..', import.meta.url);
const read = relativePath => readFile(new URL(relativePath, root), 'utf8');

test('visible Peekaa brand configuration is immutable and canonical', async () => {
  const source = await read('app/brand-config.js');
  const context = { Object };
  context.globalThis = context;
  vm.runInNewContext(source, context, { filename:'brand-config.js' });

  assert.deepEqual(
    JSON.parse(JSON.stringify(context.NestlyBrand)),
    {
      productName:'Peekaa',
      wordmark:'peekaa',
      customerLabel:'My Peekaa',
      canonicalPublicDomain:'https://www.peekaa.asia',
      contactEmail:'admin.peekaa@gmail.com',
      logoPath:'/brand/peekaa-logo.png',
      markPath:'/brand/peekaa-mark.png',
      downloadPrefix:'peekaa'
    }
  );
  assert.equal(Object.isFrozen(context.NestlyBrand), true);
});

test('deployable public surfaces use Peekaa while compatibility identifiers remain intact', async () => {
  const [index,join,terms,privacy,dataRequest,customerUi,runtimeLoader] = await Promise.all([
    read('app/index.html'),
    read('app/join.html'),
    read('app/terms.html'),
    read('app/privacy.html'),
    read('app/data-request.html'),
    read('app/customer-ui.js'),
    read('app/runtime-config-loader.js')
  ]);

  assert.match(index, /<title>Peekaa —/);
  assert.match(join, /<title>Join — Peekaa<\/title>/);
  assert.match(index, /<script src="\/brand-config\.js"><\/script>[\s\S]*<script src="\/runtime-config\.js\?v=2"><\/script>/);
  assert.match(join, /<script src="\/brand-config\.js"><\/script>[\s\S]*<script src="\/runtime-config\.js\?v=2"><\/script>/);
  assert.match(index, /BRAND\.downloadPrefix}-customers\.csv/);
  assert.match(index, /BRAND\.downloadPrefix}-appointments\.csv/);
  assert.match(index, /BRAND\.downloadPrefix}-signup-qr-/);

  for (const [name,source] of [
    ['terms',terms],['privacy',privacy],['data request',dataRequest]
  ]) {
    assert.doesNotMatch(source,/frenly/i,`${name} still exposes the legacy product name`);
    assert.match(source,/Peekaa/);
    assert.match(source,/\/brand\/peekaa-logo\.png/);
  }

  assert.match(index,/window\.FrenlyRuntimeConfig/);
  assert.match(index,/window\.FrenlyCustomerUI/);
  assert.match(join,/window\.FrenlyRuntimeConfig/);
  assert.match(customerUi,/global\.FrenlyCustomerUI/);
  assert.match(runtimeLoader,/globalObject\.FrenlyRuntimeConfig/);
  assert.match(runtimeLoader,/target && target\.__FRENLY_RUNTIME_CONFIG__/);
  assert.doesNotMatch(customerUi,/Please wait while Frenly prepares this page/);
  assert.doesNotMatch(runtimeLoader,/>Frenly is unavailable</);
});

test('platform console exposes the required namespaced routes', async () => {
  const source = await read('app/platform-console.js');
  const context = { Object };
  context.globalThis = context;
  vm.runInNewContext(source, context, { filename:'platform-console.js' });

  const consoleApi = context.NestlyPlatformConsole;
  assert.equal(consoleApi.isRoute('#/platform'),true);
  assert.equal(consoleApi.isRoute('#/platform/onboarding'),true);
  assert.equal(consoleApi.isRoute('#/platform/firms'),true);
  assert.equal(consoleApi.isRoute('#/platform/reports'),true);
  assert.equal(consoleApi.isRoute('#/platform/billing'),true);
  assert.equal(consoleApi.isRoute('#/platform/commissions'),true);
  assert.equal(consoleApi.isRoute('#/platform/sectors'),true);
  assert.equal(consoleApi.isRoute('#/platform/automation'),true);
  assert.equal(consoleApi.isRoute('#/platform/access'),true);
  assert.equal(consoleApi.isRoute('#/platform/unknown'),false);
  assert.equal(consoleApi.routeKey('#/platform'),'overview');
  assert.equal(consoleApi.routeKey('#/platform/commissions'),'commissions');
  assert.deepEqual(
    Array.from(consoleApi.routes,route=>route.label),
    ['Today','Onboarding','Firms','Reports','Billing','Commission payable','Sector modules','System health','Platform access']
  );
});

test('platform console is routed before workspace onboarding and uses versioned platform contracts', async () => {
  const [index,consoleSource,styles] = await Promise.all([
    read('app/index.html'),
    read('app/platform-console.js'),
    read('app/platform-console.css')
  ]);
  const platformBinding = index.indexOf('const platformConsole=globalThis.NestlyPlatformConsole');
  const platformRoute = index.indexOf('if(requestedPlatformRoute)');
  const onboardingFallback = index.indexOf('if(!S.biz) return renderOnboard()');

  assert.ok(platformBinding > 0&&platformBinding < platformRoute);
  assert.ok(platformRoute > 0);
  assert.ok(onboardingFallback > platformRoute);
  assert.match(index,/const platformRoutePath=String\(h\)\.split\('\?'\)\[0\]\.replace\(\/\\\/\+\$\/,''\)/);
  assert.match(index,/if\(requestedPlatformRoute\)\{[\s\S]*return await platformConsole\.render\(/);
  assert.match(index,/<link rel="stylesheet" href="\/platform-console\.css\?v=20260802-v134">/);
  assert.match(index,/<script src="\/platform-console\.js\?v=20260802-v134"><\/script>/);
  assert.match(consoleSource,/sb\.rpc\('super_admin_list_businesses'\)/);
  assert.match(consoleSource,/platform_list_firm_onboarding_v88/);
  assert.match(consoleSource,/platform_list_prospects_v76/);
  assert.match(consoleSource,/platform_list_sector_entitlements_v75/);
  assert.match(consoleSource,/get_platform_billing_v77/);
  assert.match(consoleSource,/platform_get_billing_v125/);
  assert.match(consoleSource,/platform_get_automation_billing_v89/);
  assert.match(consoleSource,/platform_get_automation_reconciliation_v89/);
  assert.match(consoleSource,/get_consultant_commission_dashboard_v78/);
  assert.doesNotMatch(consoleSource,/get_billing_reconciliation_v77/);
  assert.doesNotMatch(consoleSource,/platform_get_billing_reconciliation_v89/);
  assert.match(consoleSource,/sectionAccess\.billing\?rpc\(sb,'platform_get_billing_v125'/);
  assert.match(consoleSource,/System update required/);
  assert.doesNotMatch(consoleSource,/[\u{1F300}-\u{1FAFF}]/u);
  assert.match(styles,/min-height:44px/);
  assert.match(styles,/@media\(max-width:760px\)/);
  assert.match(styles,/\.platform-mobile-nav/);
});
