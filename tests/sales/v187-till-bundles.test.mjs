import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const app = (await read('app/index.html')) + '\n' + (await read('app/app.js'));

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const migration = await read('db/migrations/20260807_nestly_v204_bundle_priced_by_the_server.sql');

/* V204 moved this allocation out of the browser and into app.ps1c_bundle_lines_v204, so the
   arithmetic properties the old JS tests proved now belong to the SQL. They are asserted on the
   SQL's shape here and PROVEN against real bundles in db/tests/v204_bundle_priced_by_the_server.sql,
   which runs the function over every bundle in the database and checks the parts sum to the whole. */
test('the allocation is anchored to the bundle price, not to the parts', () => {
  assert.match(migration, /v_total := v_price::bigint \* p_qty;/,
    'the total to allocate is the BUNDLE price, which is the whole point');
  assert.match(migration, /v_share := \(v_total - v_alloc\)::int;/,
    'the last line takes the remainder, which is what makes the parts sum exactly');
  assert.match(migration, /floor\(v_total \* r\.list \/ v_list\)::int/,
    'the share follows each service’s own list price');
  assert.match(migration, /floor\(v_total \/ v_rows\)::int/,
    'services with no list price split it evenly');
});

test('a bundle cannot become a side door for retired services or an unpriced sale', () => {
  assert.match(migration, /and s\.active/, 'only sellable services are expanded');
  assert.match(migration, /'inactive_bundle'/);
  assert.match(migration, /'unpriced_bundle'/);
  assert.match(migration, /'empty_bundle'/);
  assert.match(migration, /b\.business_id = p_business/, 'a bundle is tenant-scoped');
});

test('the pricing helper is not reachable by the browser', () => {
  assert.match(migration,
    /revoke all on function app\.ps1c_bundle_lines_v204\(uuid,uuid,int\) from public, anon, authenticated;/);
});

test('a bundle is one cart line the SERVER prices and expands', () => {
  const add = section(app, 'function addBundleLines', '// Custom "Other item"');
  assert.match(add, /type:'bundle',ref:bundle\.id/,
    'the till sends the bundle itself, not a guess at what its parts cost');
  assert.doesNotMatch(add, /unit_cents:item\.unit_cents/,
    'a browser-computed per-service price is exactly what never reached the server');
  assert.match(add, /if\(cartLocked\(\)\)return/);
  assert.match(add, /That bundle has no services in it yet\./);
  assert.match(add, /onSaleLinesChanged\(\)/, 'the kernel must re-evaluate after the line is added');
});

test('tapping the same bundle twice is quantity 2, not two mystery lines', () => {
  // owner: "showing a 1 when click once on the item - not as if they clicked 2 items"
  const add = section(app, 'function addBundleLines', '// Custom "Other item"');
  assert.match(add, /const existing=cart\.find\(line=>line\.type==='bundle'&&line\.ref===bundle\.id\)/);
  assert.match(add, /existing\.qty\+=1/);
});

test('the bundle line carries no price to the server, and the server owns the split', () => {
  assert.match(app, /if\(l\.type==='bundle'\)return \{catalog_kind:'bundle',catalog_id:l\.ref,qty:l\.qty\}/);
  // the ledger still records real services, so commission and reporting still attribute
  assert.match(app, /isCartSaleLine=l=>[^;]*l\.type==='bundle'/);
});

test('a bundle is only offered when every service in it is sellable at this branch', () => {
  const load = section(app, 'bundles:bundleRows.error?null:', 'draw();');
  assert.match(load, /complete:wanted\.length>0&&items\.every\(Boolean\)/);
  assert.match(load, /\.filter\(bundle=>bundle\.complete\)/);
  assert.match(load, /catalogueById\.get\(serviceId\)/,
    'prices and availability come from the branch catalogue, not the bundle row');
  assert.match(app, /sb\.from\('bundles'\)\.select\('id,name,price_cents,active,bundle_items\(service_id\)'\)/);
  assert.match(app, /\.eq\('business_id',S\.biz\.id\)\.eq\('active',true\)/);
});

test('the picker shows bundles with what is inside them', () => {
  assert.match(app, /<b class="small" style="display:block;margin-top:14px">Bundles<\/b>/);
  assert.match(app, /data-add-bundle="\$\{esc\(bundle\.id\)\}"/);
  assert.match(app, /bundle\.items\.map\(item=>item\.name\)\.join\(' \+ '\)/);
  assert.match(app, /A bundle adds each of its services at the bundle price\./);
  /* V216 inserted per-group headings and V373 moved the full catalogue into the Add item sheet,
     so this no longer pins one exact string. The intent is unchanged and still asserted: a bundle
     is found with the services it is made of — the sheet's Services tab, directly after the
     service tiles — never filed with the products, which have a tab of their own. */
  assert.match(app, /if\(active==='services'\)\{[\s\S]{0,600}?tillCatalogueTilesV373\(services\.map\(item=>\(\{type:'service',item\}\)\)\)[\s\S]{0,300}?tillBundleTilesV373\(bundles\)/,
    'bundles are rendered after the services, inside the same tab');
  assert.match(app, /\{key:'services',label:'Services'\},\s*\n\s*\{key:'products',label:'Products'\}/,
    'products are a separate tab, so a bundle can never be mistaken for retail');
  assert.match(app, /const bundle=\(catalog\.bundles\|\|\[\]\)\.find\(x=>x\.id===b\.dataset\.addBundle\)/);
});
