import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* nestly_v827 — written and applied as v825, renumbered after a collision; DB objects keep _v825.
   (owner, 2026-09-08, three screenshots + a request):
     1. photo uploads take far too long, throughout the app;
     2. commission must be settable on a bundle, a package and a product;
     3. a Staff commission module — every product/service sold, who bought it, when, which team
        member it pays, reversed sales shown as reversed and counted nowhere, one commission per
        line per member, All / per-member views, Today by default with week / month / year.
   These pins follow the memory that source-regex tests are vacuous unless something is EXECUTED:
   the calendar presets and the aggregation helper are extracted and run. */

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const mediaSync=await readFile(new URL('../../app/v95-media-sync.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const migration=await readFile(new URL('../../db/migrations/20261008_nestly_v827_catalogue_commission_and_staff_commission_report.sql',import.meta.url),'utf8');
const mirror=await readFile(new URL('../../supabase/migrations/20261008010000_nestly_v827_catalogue_commission_and_staff_commission_report.sql',import.meta.url),'utf8');
const suite=await readFile(new URL('../../db/tests/v827_catalogue_commission_and_staff_commission_report.sql',import.meta.url),'utf8');

function statement(start,end){
  const from=app.indexOf(start);
  assert.ok(from>=0,`missing ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.ok(to>from,`unterminated ${start}`);
  return app.slice(from,to+end.length);
}

// ------------------------------------------------------------------ 1. uploads

test('v825 every business photo is downscaled before upload and the upload has a deadline',()=>{
  /* Root cause (measured against production storage on 2026-09-08): catalogue photos averaged
     1.2 MB, reward photos 1.7 MB, the largest 4.1 MB — the original bytes, byte for byte — and
     only the promotions editor downscaled (v280). Now one uploader for the raw paths, and the
     v95 publisher takes a deadline for the catalogue, logo and programme paths. */
  const uploader=statement('async function uploadBusinessPhotoV825(folder,file){','\n}');
  assert.match(uploader,/const sending=await downscalePromotionPhotoV280\(file\);/);
  assert.match(uploader,/withDeadlineV280\(sb\.storage\.from\('business-public'\)/);
  assert.match(uploader,/BUSINESS_MEDIA_UPLOAD_TIMEOUT_MS_V825/);
  assert.match(uploader,/\.upload\(objectPath,sending,\{contentType:sending\.type,upsert:false\}\)/,
    'the bytes sent, the declared type and the path suffix must be the DOWNSCALED file');
  assert.match(app,/const BUSINESS_MEDIA_UPLOAD_TIMEOUT_MS_V825=45000;/);
  // the three former copies are one implementation now
  assert.match(app,/async function uploadRewardPhotoV326\(file\)\{return uploadBusinessPhotoV825\('reward',file\)\}/);
  assert.match(app,/async function uploadRewardPhotoV340\(file\)\{return uploadBusinessPhotoV825\('reward',file\)\}/);
  assert.match(app,/async function uploadGalleryPhotoV418\(file\)\{return uploadBusinessPhotoV825\('gallery',file\)\}/);
  assert.equal(app.split("sb.storage.from('business-public')\n    .upload(").length-1,1,
    'no second raw upload path survives');
  // catalogue (services / products), logo and programme images go through the same downscale
  const catalogue=statement('async function uploadCatalogueMediaV158(','\n}');
  assert.match(catalogue,/const sending=await downscalePromotionPhotoV280\(file\);/);
  assert.match(catalogue,/imageDimensionsV95\(sending\)/);
  assert.match(catalogue,/CATALOGUE_MEDIA_TYPES_V158\[sending\.type\]/);
  assert.match(catalogue,/file:sending,\s*\n\s*timeoutMs:BUSINESS_MEDIA_UPLOAD_TIMEOUT_MS_V825/);
  assert.match(catalogue,/p_mime_type:sending\.type/);
  assert.match(app,/downscalePromotionPhotoV280\(file,\{preserveTransparency:true\}\);\s*\n\s*const extension=[^\n]*\[sending\.type\];\s*\n\s*const objectPath=`\$\{S\.biz\.id\}\/logo\//,
    'the logo keeps its transparency and is named by the downscaled type');
  assert.match(app,/downscalePromotionPhotoV280\(file,\{preserveTransparency:kind==='logo'\}\)/);
  assert.equal(app.split('timeoutMs:BUSINESS_MEDIA_UPLOAD_TIMEOUT_MS_V825').length-1,3,
    'catalogue, logo and programme publishes all carry the deadline');
  // the publisher honours it on the upload step only — a timed-out upload publishes nothing
  assert.match(mediaSync,/async function publish\(\{storage,client,businessId,objectPath,file,publishArgs,timeoutMs=0\}\)\{\s*\n\s*const uploaded=await withUploadDeadline\(storage\.from\(BUCKET\)\.upload\(/);
  assert.match(mediaSync,/if\(!\(ms>0\)\)return work;/,'a caller that passes no deadline keeps the old behaviour');
  // the script is served under a manual version string, so the edit must bump it or the CDN serves the old file
  assert.match(indexHtml,/\/v95-media-sync\.js\?v=20260908-v827/);
  assert.doesNotMatch(indexHtml,/v95-media-sync\.js\?v=20260728-atomic-media/);
});

test('v825 the downscale keeps PNG transparency only when asked, and still white-fills otherwise',()=>{
  const fn=statement('async function downscalePromotionPhotoV280(file,{preserveTransparency=false}={}){','\n}');
  assert.match(fn,/const keepAlphaV825=preserveTransparency&&file\.type==='image\/png';/);
  assert.match(fn,/if\(!keepAlphaV825\)\{context\.fillStyle='#ffffff';context\.fillRect\(0,0,width,height\);\}/);
  assert.match(fn,/canvas\.toBlob\(resolve,mimeV825,keepAlphaV825\?undefined:0\.86\)/);
  assert.match(fn,/type:mimeV825/);
});

// ------------------------------------------------------------------ 2. commission on products, bundles, packages

test('v825 the migration adds the three commission pairs, threads the bundle into the line, and keeps one authority',()=>{
  assert.equal(migration,mirror,'db/migrations and supabase/migrations copies must be byte-identical');
  for(const table of ['products','bundles','package_plans']){
    assert.match(migration,new RegExp(`alter table public\\.${table}\\n  add column if not exists commission_bps integer,\\n  add column if not exists commission_flat_cents integer;`));
    assert.match(migration,new RegExp(`${table}_commission_bps_range_v825\\n    check \\(commission_bps is null or commission_bps between 0 and 10000\\)`));
  }
  assert.match(migration,/alter table public\.sale_items add column if not exists bundle_id uuid;/);
  assert.match(migration,/references public\.bundles\(id, business_id\) on delete restrict/);
  // the finaliser copies the bundle id evaluate_checkout has stamped since v257 — anchored, once
  assert.match(migration,/nullif\(e->>''bundle_id'', ''''\)::uuid/);
  assert.match(migration,/expected exactly 1', v_hits;/);
  // a package line references its plan, so a package override can be found
  assert.match(migration,/v_staff, v_plan\.id\);/);
  // resolution order per line
  const bps=migration.slice(migration.indexOf('create or replace function app.sale_item_commission_bps_v825('),migration.indexOf('create or replace function app.sale_item_commission_flat_cents_v825('));
  assert.match(bps,/when p_item_type = 'package_session' then 0/,'owner ruling: a package pays once, at purchase');
  assert.match(bps,/when bnd\.commission_bps is not null then bnd\.commission_bps/,'owner ruling: the bundle overrides every member line');
  assert.match(bps,/when p_item_type = 'retail'  then coalesce\(prd\.commission_bps, st\.commission_product_bps\)/);
  assert.match(bps,/when p_item_type = 'package' then coalesce\(pkg\.commission_bps, st\.commission_product_bps\)/);
  assert.match(bps,/coalesce\(svc\.commission_bps, st\.commission_service_bps\)/,'a 0% service override still beats the member rate (v12)');
  // the v811 names stay callable but resolve through v825
  assert.match(migration,/select app\.sale_item_commission_bps_v825\(p_business, p_item_type, p_ref_id, null, null, p_staff, p_occurred_at\)/);
  assert.match(migration,/select app\.sale_item_commission_flat_cents_v825\(p_business, p_item_type, p_ref_id, null, null, p_staff, p_occurred_at, p_line_cents\)/);
  // the trigger is swapped, the old trigger function is gone, the guard knows the new column
  assert.match(migration,/drop trigger if exists trg_sale_items_commission_v811 on public\.sale_items;/);
  assert.match(migration,/create trigger trg_sale_items_commission_v825\n  before insert on public\.sale_items/);
  assert.match(migration,/drop function if exists app\.on_sale_item_commission_snapshot_v811\(\);/);
  assert.match(migration,/new\.created_at, new\.canonical_node_key, new\.taxonomy_version_no, new\.bundle_id\)/);
  // a bundle fixed amount is paid once per bundle: the last member line absorbs the remainder
  assert.match(migration,/elsif v_seen \+ 1 >= v_members then\n      v_bundles_sold := \(\(v_seen_cents \+ new\.line_cents\) \/ v_bundle_price\)::integer;\n      new\.commission_cents := \(v_bundle_flat::bigint \* greatest\(v_bundles_sold, 1\) - v_seen_commission\)::integer;/);
  // a sold bundle can no longer be hard-deleted
  assert.match(migration,/bundle_has_sales: this bundle has been sold, so it cannot be deleted; switch it off instead/);
  // grants restated: internal helpers get no browser grant; the two RPCs do
  for(const sig of ['app.staff_commission_eligible_v825(uuid, uuid, timestamptz)',
      'app.sale_item_commission_bps_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz)',
      'app.sale_item_commission_flat_cents_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz, integer)']){
    assert.ok(migration.includes(`revoke all on function ${sig}\n  from public, anon, authenticated;`),`${sig} must have no browser grant`);
  }
  for(const sig of ['public.business_set_catalogue_commission_v825(uuid, text, uuid, integer, integer)',
      'public.business_staff_commission_lines_v825(uuid, uuid, timestamptz, timestamptz)']){
    assert.ok(migration.includes(`grant execute on function ${sig}\n  to authenticated, service_role;`),`${sig} must be callable by the browser`);
  }
  assert.match(migration,/^begin;$/m);assert.match(migration,/^commit;$/m);
  // the proof suite drives the reader and the writer as the REAL owner principal, and reverses a sale
  assert.match(suite,/set local role authenticated;/);
  assert.match(suite,/app\.sale_reversal_insert_id/);
  assert.match(suite,/bool_and\(r\.reversed\) filter \(where r\.sale_id = v_sale_bundle\)/);
});

test('v825 every editor exposes the pair through one markup, one reader and one writer',()=>{
  assert.match(app,/function commissionInputsHtmlV825\(\{idPrefix,row=null\}\)\{/);
  assert.match(app,/function readCommissionInputsV825\(idPrefix\)\{/);
  assert.match(app,/async function saveCatalogueCommissionV825\(kind,id,input\)\{\s*\n\s*const \{error\}=await sb\.rpc\('business_set_catalogue_commission_v825'/);
  // products: dialog fields, save through the writer only when changed, a Commission column
  assert.match(app,/\$\{commissionInputsHtmlV825\(\{idPrefix:'prodEdit',row:p\}\)\}/);
  assert.match(app,/if\(commissionInputsChangedV825\('prodEdit'\)\)\{\s*\n\s*const commissionErrorV825=await saveCatalogueCommissionV825\('product',id,commissionV825\);/);
  assert.match(app,/<th class="num">Sell for<\/th><th>Commission<\/th><th>Status<\/th>/);
  // bundles: fields in the dialog, filled on edit, cleared on add, written after create and update
  assert.match(app,/\$\{commissionInputsHtmlV825\(\{idPrefix:'bundle'\}\)\}/);
  assert.match(app,/fillCommissionInputsV825\('bundle',bundle\);/);
  assert.match(app,/showBundleFormV613\(\);fillCommissionInputsV825\('bundle',null\);/);
  assert.match(app,/saveCatalogueCommissionV825\('bundle',editingBundleIdV285,bundleCommissionV825\)/);
  assert.match(app,/const createdBundleIdV825=data\?\.bundle_id\|\|null;/);
  assert.match(app,/saveCatalogueCommissionV825\('bundle',createdBundleIdV825,bundleCommissionV825\)/);
  // packages: add form and edit dialog, written against the plan the server returned
  assert.match(app,/\$\{commissionInputsHtmlV825\(\{idPrefix:'k'\}\)\}/);
  assert.match(app,/\$\{commissionInputsHtmlV825\(\{idPrefix:'packageEdit',row:plan\}\)\}/);
  assert.match(app,/saveCatalogueCommissionV825\('package',data\.id,packageCommissionV825\)/);
  assert.match(app,/saveCatalogueCommissionV825\('package',savedPlanIdV627,commissionV825\)/);
  // services: the v13 fixed amount is finally exposed, through the existing direct write
  assert.match(app,/id="svcEditCommissionFlatV825"/);
  assert.match(app,/commission_bps:commissionBpsV584,commission_flat_cents:commissionFlatV825\}\)\.eq\('id',id\)/);
});

test('v825 the commission inputs read blank as null, 0 as 0, and refuse out-of-range values',()=>{
  const reader=statement('function readCommissionInputsV825(idPrefix){','\n}');
  const values={};
  const $=id=>(id in values)?{value:values[id]}:null;
  const read=new Function('$',`${reader};return readCommissionInputsV825`)($);
  values['x-commission-v825']='';values['x-commission-flat-v825']='';
  assert.deepEqual(read('x'),{bps:null,flatCents:null});
  values['x-commission-v825']='0';values['x-commission-flat-v825']='0';
  assert.deepEqual(read('x'),{bps:0,flatCents:0},'0 is a real setting, not blank');
  values['x-commission-v825']='12.5';values['x-commission-flat-v825']='3.50';
  assert.deepEqual(read('x'),{bps:1250,flatCents:350});
  values['x-commission-v825']='101';
  assert.ok(read('x').error);
  values['x-commission-v825']='';values['x-commission-flat-v825']='-1';
  assert.ok(read('x').error);
});

// ------------------------------------------------------------------ 3. the Staff commission module

test('v825 the staffperf key became Staff commission under Reports, with one commission authority',()=>{
  assert.match(app,/staffperf:\['staff','Staff commission'\]/);
  assert.match(app,/label:'Reports',items:\['dailyreport','sales','staffperf','reports','customerintel'\]/);
  assert.match(app,/canReadModule\('staffperf'\)&&\{href:'#\/staffperf',icon:'staff',title:'Staff commission'\}/);
  assert.match(app,/const FINANCE_MODULES=new Set\(\[[^\]]*'staffperf'[^\]]*\]\)/,'still finance-gated');
  assert.doesNotMatch(app,/async function staffPerfDrill\(/,'the drill page is retired; the route preselects a member');
  assert.doesNotMatch(app,/function staffPerformanceAggregation\(/,'the ranking aggregation is retired');
  assert.doesNotMatch(app,/'Staff performance':/,'no curated translation names the retired page');
  const page=statement('async function staffPerfPage(drillId){','\nfunction enhanceStaffMembersTabsV164(');
  assert.match(page,/let selectedStaffV825=drillId\?decodeURIComponent\(String\(drillId\)\):'all';/);
  assert.match(page,/require_module_scope_v145',\{p_business:S\.biz\.id,p_branch:selectedBranchId\|\|null,p_module:'staffperf'\}/);
  assert.match(page,/fetchAllRows\(\(\)=>sb\.rpc\('business_staff_commission_lines_v825',\s*\n\s*\{p_business:S\.biz\.id,p_branch:selectedBranchId\|\|null,p_from:from,p_to:toExclusive\},\{count:'exact'\}\)/);
  assert.match(page,/\.order\('occurred_at',\{ascending:false\}\)\.order\('sale_id'\)\.order\('line_id'\)/,'paged reads need a total order');
  assert.match(page,/id="reportScopeNoteV272"/);
  assert.match(page,/renderReportScopeNoteV272\(isCurrent\)/);
  // the table: when, who bought, what, who it pays, rate, commission, status; reversed struck through
  for(const th of ['When','Customer','Item','Team member','Rate','Commission','Status'])assert.ok(page.includes(`<th>${th}</th>`)||page.includes(`<th class="num">${th}</th>`),`column ${th}`);
  assert.match(page,/href="#\/client\/\$\{esc\(r\.client_id\)\}"/);
  assert.match(page,/<span class="pill off" data-merchant-content title="\$\{esc\(r\.reversal_reason\|\|'Reversed'\)\}">Reversed<\/span>/);
  assert.match(page,/r\.reversed\?`<s>\$\{esc\(money\(r\.commission_cents\)\)\}<\/s>`/);
  assert.match(page,/const counted=visible\.filter\(r=>!r\.reversed\);/,'totals come from the counted rows only');
  assert.match(page,/One sale line pays one team member\. Reversed sales are shown for traceability and excluded from every total\./);
});

test('v825 Today and This week presets are Singapore-calendar exact and executable',()=>{
  const start=app.indexOf('function reportCalendarPresetV300(kind,todayStr){');
  const end=app.indexOf('\nfunction reportPriorWindowV297(',start);
  const preset=new Function(`${app.slice(start,end)};return reportCalendarPresetV300`)();
  assert.deepEqual(preset('today','2026-09-08'),{from:'2026-09-08',to:'2026-09-08',cf:'2026-09-07',ct:'2026-09-07'});
  // 2026-09-08 is a Tuesday: the week started on Monday 7 Sep; last week's same days are 31 Aug – 1 Sep
  assert.deepEqual(preset('week','2026-09-08'),{from:'2026-09-07',to:'2026-09-08',cf:'2026-08-31',ct:'2026-09-01'});
  // a Monday is its own week start; a Sunday reaches back six days
  assert.equal(preset('week','2026-09-07').from,'2026-09-07');
  assert.equal(preset('week','2026-09-13').from,'2026-09-07');
  // the pre-existing kinds are untouched
  assert.equal(preset('month','2026-09-08').from,'2026-09-01');
  assert.equal(preset('year','2026-09-08').from,'2026-01-01');
});
