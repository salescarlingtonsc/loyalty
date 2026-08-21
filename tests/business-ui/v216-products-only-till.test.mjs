/* V216 — a products-only business must not be shown a services-shaped till.
   Owner: "i need a product modules - instead of just services (because products have no
   minutes)". Record sale printed a hardcoded "Services" heading and gave products none, so a
   cafe with seven products and no services saw an empty "Services" label above unlabelled
   buttons — the app insisting on a concept that business does not have. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
/* V373 moved the catalogue into a quick grid plus an Add item sheet. The rule V216 established
   survives unchanged and is still executed here: each group names itself, and a group with
   nothing in it prints no heading. Only the function that applies it moved. */
const groups = app.slice(app.indexOf('function tillQuickGroupsHtmlV373(shownServices,shownProducts,shownBundles=[]){'),
  app.indexOf('/* V211/V257: package plans on sale.'));

/* Renders the real quick-grid branch for a given catalogue shape.
   nestly_v411 added a third group. The V216 rule it must obey is unchanged and is what this
   suite exists to hold: each group names itself, and a group with nothing in it prints no
   heading. */
function render(services, products, bundles = []) {
  const build = new Function(
    'tillGroupHeadingV216', 'tillCatalogueTilesV373', 'tillBundleTilesV373',
    'shownServices', 'shownProducts', 'shownBundles',
    groups.slice(groups.indexOf('return `'), groups.lastIndexOf('`;') + 2),
  );
  const heading = (label, count) => (count ? `<b class="small">${label}</b>` : '');
  const tiles = entries => (entries.length ? (entries[0].type === 'service' ? '[SVC]' : '[PROD]') : '');
  const bundleTiles = list => (list.length ? '[BUNDLE]' : '');
  return build(heading, tiles, bundleTiles,
    services.map(item => ({ type: 'service', item })),
    products.map(item => ({ type: 'product', item })),
    bundles);
}

/* The empty-catalogue case is decided by the caller, not by the group builder: with nothing to
   sell the stage renders the empty state instead of any grid. */
const stage = app.slice(app.indexOf('function tillItemsPanelHtmlV374(){'), app.indexOf('function tillPackagesPanelHtmlV374(){'));

test('V216 a products-only business gets a Products heading and no empty Services heading', () => {
  const cafe = render([], [{ id: 'p1' }, { id: 'p2' }]);
  assert.ok(!cafe.includes('>Services<'), 'must not print a Services heading with no services');
  assert.ok(cafe.includes('>Products<'), 'products must be labelled');
  assert.ok(cafe.includes('[PROD]'), 'the product buttons must still render');
});

/* nestly_v411 (owner photo 2: "record sale is still missing bundle item"). A bundle was sellable
   since v187 but rendered ONLY inside the More items sheet, on the Services tab, below the whole
   services list — invisible on the main Record sale screen and unreachable from the search beside
   it. It is a third group on the grid now, and it obeys the same V216 rule as the other two. */
test('v411 bundles get their own labelled group on the quick grid', () => {
  const withBundles = render([{ id: 's1' }], [], [{ id: 'b1', name: 'Party Pack' }]);
  assert.ok(withBundles.includes('>Bundles<'), 'bundles must be labelled');
  assert.ok(withBundles.includes('[BUNDLE]'), 'the bundle buttons must render');
  assert.ok(withBundles.includes('>Services<'), 'and services are still labelled beside them');
});

test('v411 a business with no bundles prints no empty Bundles heading', () => {
  const noBundles = render([{ id: 's1' }], [{ id: 'p1' }]);
  assert.ok(!noBundles.includes('>Bundles<'), 'the V216 rule holds for the new group too');
  assert.ok(!noBundles.includes('[BUNDLE]'));
});

test('V216 a services-only business is unchanged', () => {
  const salon = render([{ id: 's1' }], []);
  assert.ok(salon.includes('>Services<'));
  assert.ok(!salon.includes('>Products<'), 'no Products heading when there are none');
  assert.ok(salon.includes('[SVC]'));
});

test('V216 a business selling both labels both, and an empty branch shows the empty state', () => {
  const both = render([{ id: 's1' }], [{ id: 'p1' }]);
  assert.ok(both.includes('>Services<') && both.includes('>Products<'));
  assert.ok(both.indexOf('>Services<') < both.indexOf('>Products<'), 'services stay first');

  const none = render([], []);
  assert.ok(!none.includes('>Services<') && !none.includes('>Products<'));
  // A branch with nothing to sell is told so — and still gets the door to the Add item sheet,
  // because a firm selling only prepaid packages has something to add.
  assert.match(stage, /const noCheckoutItems=!catalog\.services\.length&&!\(catalog\.products&&catalog\.products\.length\);/);
  assert.match(stage, /if\(noCheckoutItems\)\s*\n\s*return `\$\{CUI\.emptyState\(\{iconName:'till',title:'No checkout items at this branch'/);
  assert.match(stage, /\$\{addTile\}<\/div>`/);
});
