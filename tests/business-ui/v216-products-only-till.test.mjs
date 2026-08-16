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
const picker = app.slice(app.indexOf('const svcHeadingV216='), app.indexOf('${pkgBtns}${memBtns}', app.indexOf('const svcHeadingV216=')));

/* Renders the real picker branch for a given catalogue shape. */
function render(services, products) {
  /* The picker template gained two more banners since this test was written (v362's bring-back
     voucher and v365/v369's tier benefits). They are declared immediately above the template in
     the real renderer; the sandbox has to supply them or every case dies on a ReferenceError
     that says nothing about product headings. */
  const build = new Function(
    'catalog', 'welcomeBanner', 'bringbackBanner', 'tierBenefitBannerV365',
    'ownedPackages', 'pendingVouchers',
    'svcBtns', 'bundleBtns', 'prodBtns', 'CUI', 'noCheckoutItems',
    picker.replace('picker=`', 'return `') + '`;'
  );
  return build({ services, products }, '', '', '', '', '', '[SVC]', '', '[PROD]',
    { emptyState: () => '[EMPTY]' }, !services.length && !products.length);
}

test('V216 a products-only business gets a Products heading and no empty Services heading', () => {
  const cafe = render([], [{ id: 'p1' }, { id: 'p2' }]);
  assert.ok(!cafe.includes('>Services<'), 'must not print a Services heading with no services');
  assert.ok(cafe.includes('>Products<'), 'products must be labelled');
  assert.ok(cafe.includes('[PROD]'), 'the product buttons must still render');
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
  assert.ok(none.includes('[EMPTY]'));
  assert.ok(!none.includes('>Services<') && !none.includes('>Products<'));
});
