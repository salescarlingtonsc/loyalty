import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const root=resolve(import.meta.dirname,'../..');
const text=path=>readFile(resolve(root,path),'utf8');
const bytes=path=>readFile(resolve(root,path));

function pngShape(buffer){
  assert.deepEqual([...buffer.subarray(0,8)],[137,80,78,71,13,10,26,10]);
  return {width:buffer.readUInt32BE(16),height:buffer.readUInt32BE(20),colourType:buffer[25]};
}

test('Peekaa is the immutable canonical product identity while legacy globals stay compatible',async()=>{
  const source=await text('app/brand-config.js');
  const context={Object};context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'brand-config.js'});
  assert.deepEqual(JSON.parse(JSON.stringify(context.NestlyBrand)),{
    productName:'Peekaa',
    wordmark:'peekaa',
    customerLabel:'My Peekaa',
    canonicalPublicDomain:'https://www.peekaa.asia',
    contactEmail:'admin.peekaa@gmail.com',
    logoPath:'/brand/peekaa-logo.png',
    markPath:'/brand/peekaa-mark.png',
    downloadPrefix:'peekaa'
  });
  assert.equal(Object.isFrozen(context.NestlyBrand),true);
});

test('public pages and install metadata expose Peekaa, its domain, email and icon set',async()=>{
  const pagePaths=['app/index.html','app/join.html','app/privacy.html','app/terms.html','app/data-request.html','app/offline.html'];
  for(const path of pagePaths){
    const source=await text(path);
    assert.match(source,/Peekaa/,`${path} is missing Peekaa`);
    assert.doesNotMatch(source,/nestlyasia@gmail\.com/i,`${path} exposes the retired mailbox`);
    assert.doesNotMatch(source,/www\.nestly\.asia/i,`${path} exposes the retired canonical domain`);
    assert.match(source,/\/icons\/peekaa-32\.png/,`${path} is missing the Peekaa favicon`);
    assert.match(source,/\/icons\/apple-touch-icon\.png/,`${path} is missing the Apple icon`);
  }
  const manifest=JSON.parse(await text('app/manifest.webmanifest'));
  assert.equal(manifest.name,'Peekaa');
  assert.equal(manifest.short_name,'Peekaa');
  assert.deepEqual(manifest.icons.map(icon=>icon.src),['/icons/peekaa-192.png','/icons/peekaa-512.png']);
  assert.deepEqual(pngShape(await bytes('app/icons/peekaa-32.png')),{width:32,height:32,colourType:2});
  assert.deepEqual(pngShape(await bytes('app/icons/peekaa-192.png')),{width:192,height:192,colourType:2});
  assert.deepEqual(pngShape(await bytes('app/icons/peekaa-512.png')),{width:512,height:512,colourType:2});
  assert.deepEqual(pngShape(await bytes('app/icons/apple-touch-icon.png')),{width:180,height:180,colourType:2});
});

test('unpublished native packages are consistently renamed before store signing',async()=>{
  const [capacitor,androidBuild,androidStrings,androidManifest,iosProject,iosInfo,iosEntitlements,validator]=await Promise.all([
    text('capacitor.config.ts'),text('android/app/build.gradle'),text('android/app/src/main/res/values/strings.xml'),
    text('android/app/src/main/AndroidManifest.xml'),text('ios/App/App.xcodeproj/project.pbxproj'),
    text('ios/App/App/Info.plist'),text('ios/App/App/App.entitlements'),text('scripts/mobile/store-readiness.mjs')
  ]);
  for(const source of [capacitor,androidBuild,androidStrings,androidManifest,iosProject,iosInfo,iosEntitlements,validator]){
    assert.doesNotMatch(source,/asia\.nestly\.app|www\.nestly\.asia/);
  }
  assert.match(capacitor,/appId:\s*'asia\.peekaa\.app'/);
  assert.match(capacitor,/appName:\s*'Peekaa'/);
  assert.match(androidBuild,/applicationId\s+"asia\.peekaa\.app"/);
  assert.match(androidStrings,/<string name="app_name">Peekaa<\/string>/);
  assert.match(androidManifest,/android:host="www\.peekaa\.asia"/);
  assert.match(iosProject,/PRODUCT_BUNDLE_IDENTIFIER = asia\.peekaa\.app/);
  assert.match(iosInfo,/<string>Peekaa<\/string>/);
  assert.match(iosEntitlements,/applinks:www\.peekaa\.asia/);
  const iosIcon=pngShape(await bytes('ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png'));
  assert.deepEqual(iosIcon,{width:1024,height:1024,colourType:2});
});

test('Stripe bootstrap preserves reviewed pricing while presenting Peekaa branding',async()=>{
  const source=await text('scripts/stripe/setup-v124-catalog.mjs');
  assert.match(source,/name:\s*'Peekaa Business Subscription'/);
  assert.match(source,/description:\s*'Peekaa business workspace/);
  assert.match(source,/nickname:\s*'Peekaa monthly base — 1,000 customers'/);
  assert.match(source,/nickname:\s*'Peekaa annual base — 1,000 customers'/);
  assert.match(source,/unitAmount:\s*14900/);
  assert.match(source,/unitAmount:\s*118800/);
  assert.match(source,/unitAmount:\s*1000/);
  assert.match(source,/unitAmount:\s*12000/);
  assert.match(source,/tax_behavior:\s*'exclusive'/);
  assert.doesNotMatch(source,/name:\s*'Nestly|nickname:\s*'Nestly/);
});

test('current platform and billing fallbacks cannot project the retired product brand',async()=>{
  const [platform,css,migration,mirror,adminFixture]=await Promise.all([
    text('app/platform-console.js'),text('app/platform-console.css'),
    text('db/migrations/20260802_nestly_v134_peekaa_brand_legal.sql'),
    text('supabase/migrations/20260802010000_nestly_v134_peekaa_brand_legal.sql'),
    text('tests/browser/v105-admin-visual.html'),
  ]);
  assert.match(platform,/class="platform-logo-img"/);
  assert.match(platform,/brand\.logoPath\|\|'\/brand\/peekaa-logo\.png'/);
  assert.doesNotMatch(platform,/downloadPrefix\|\|'nestly'/);
  assert.match(css,/\.platform-logo-img\{/);
  assert.match(migration,/your Peekaa representative/);
  assert.match(migration,/NESTLY TECHNOLOGIES PTE\. LTD\. is not GST-registered/);
  assert.match(migration,/Known revenue covers the Peekaa sales ledger/);
  assert.match(migration,/Peekaa pilot starting policy/);
  assert.match(migration,/Peekaa quick reversal/);
  assert.match(migration,/Peekaa amount correction/);
  assert.match(migration,/forfeited to Peekaa/);
  assert.match(migration,/Owner package-purchase points setting \(Peekaa v102\)/);
  assert.match(migration,/legacy billing notice preflight failed/);
  assert.doesNotMatch(migration,/raise exception 'Nestly is not GST-registered/);
  assert.equal(mirror,migration);
  assert.match(adminFixture,/logoPath:'\/app\/brand\/peekaa-logo\.png'/);
  assert.doesNotMatch(adminFixture,/brand:\{productName:'Peekaa',wordmark:'nestly\.'/);
});
