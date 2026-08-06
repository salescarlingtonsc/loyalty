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

const pricing = section(app, 'function bundleLinePricesV187', 'function addBundleLines');
const { bundleLinePricesV187 } = new Function(`${pricing};return {bundleLinePricesV187};`)();

const ITEMS = [
  { id: 'a', name: 'Active acne', unit_cents: 20000 },
  { id: 'b', name: 'Face lifting', unit_cents: 300000 },
  { id: 'c', name: 'Pigmentation', unit_cents: 45000 },
  { id: 'd', name: 'Glow', unit_cents: 88800 }
];

test('the lines always sum to exactly the bundle price', () => {
  for (const price of [588800, 1, 99, 100000, 7, 0]) {
    const lines = bundleLinePricesV187(ITEMS, price);
    assert.equal(lines.reduce((total, line) => total + line.unit_cents, 0), price,
      `bundle priced ${price} must not gain or lose a cent`);
  }
});

test('the split follows each service’s own list price', () => {
  const lines = bundleLinePricesV187(ITEMS, 588800);
  const byId = Object.fromEntries(lines.map((line) => [line.id, line.unit_cents]));
  assert.ok(byId.b > byId.c && byId.c > byId.a, 'a dearer service must carry a bigger share');
  // 300000 of 453800 list ≈ 66%
  assert.ok(Math.abs(byId.b / 588800 - 300000 / 453800) < 0.01);
});

test('services with no list price split the bundle evenly, and the remainder is never dropped', () => {
  const free = [{ id: 'x', name: 'X', unit_cents: 0 }, { id: 'y', name: 'Y', unit_cents: 0 }, { id: 'z', name: 'Z', unit_cents: 0 }];
  const lines = bundleLinePricesV187(free, 1000);
  assert.equal(lines.reduce((total, line) => total + line.unit_cents, 0), 1000);
  assert.deepEqual(lines.map((line) => line.unit_cents), [333, 333, 334],
    'the remainder cent lands on the last line rather than vanishing');
});

test('no line is ever negative and an empty bundle prices nothing', () => {
  assert.deepEqual(bundleLinePricesV187([], 5000), []);
  assert.deepEqual(bundleLinePricesV187(null, 5000), []);
  assert.ok(bundleLinePricesV187(ITEMS, 100).every((line) => line.unit_cents >= 0));
  assert.deepEqual(bundleLinePricesV187([{ id: 'a', name: 'A', unit_cents: 5000 }], 12345)
    .map((line) => line.unit_cents), [12345]);
});

test('a bundle is sold as its member services, never as an invented line type', () => {
  const add = section(app, 'function addBundleLines', '// Custom "Other item"');
  assert.match(add, /type:'service'/, 'sale_items has no bundle type; the parts are what the ledger records');
  assert.doesNotMatch(add, /type:'custom'|type:'bundle'/);
  assert.match(add, /label:`\$\{item\.name\} · \$\{bundle\.name\}`/, 'the receipt must name the bundle it came from');
  assert.match(add, /cart\.push/);
  assert.doesNotMatch(add, /ex\.qty\+\+/,
    'a bundled service is priced differently from the same service sold alone — never merge them');
  assert.match(add, /if\(cartLocked\(\)\)return/);
  assert.match(add, /That bundle has no services in it yet\./);
  assert.match(add, /onSaleLinesChanged\(\)/, 'the kernel must re-evaluate after the lines are added');
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
  assert.match(app, /\$\{svcBtns\}\$\{bundleBtns\}\$\{prodBtns\}/, 'bundles belong with the services');
  assert.match(app, /const bundle=\(catalog\.bundles\|\|\[\]\)\.find\(x=>x\.id===b\.dataset\.addBundle\)/);
});
