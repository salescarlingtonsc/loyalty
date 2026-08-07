import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const app = ((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const section = (start, end) => {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing section start ${start}`);
  const to = app.indexOf(end, from);
  assert.notEqual(to, -1, `missing section end ${end}`);
  return app.slice(from, to);
};

const extract = (name) => {
  const src = section(`function ${name}(`, '\nfunction ');
  return new Function(`${src}; return ${name};`)();
};

test('shelf interleaves offers round-robin by business preserving in-business order', () => {
  const interleave = extract('interleaveCustomerOffersV173');
  const offer = (id, slug) => ({ id, business: { slug } });
  const input = [offer('a1','a'), offer('a2','a'), offer('b1','b'), offer('b2','b'), offer('c1','c')];
  assert.deepEqual(interleave(input).map(({ id }) => id), ['a1','b1','c1','a2','b2']);
  const single = [offer('a1','a'), offer('a2','a')];
  assert.deepEqual(interleave(single).map(({ id }) => id), ['a1','a2']);
  assert.deepEqual(interleave(null), []);
});

test('home offer cards open the offer detail sheet with full marketing content', () => {
  const wire = section('function wireCustomerHomeOffersV167', '\nfunction customerRewardProgressMarkupV167');
  assert.match(wire, /event\.preventDefault\(\);showCustomerOfferDetailV173\(item\)/);
  const detail = section('function showCustomerOfferDetailV173', '\nfunction wireCustomerHomeOffersV167');
  assert.match(detail, /customer-offer-detail-facts/);
  assert.match(detail, /item\?\.description/);
  assert.match(detail, /availability_label/);
  assert.match(detail, /customer_get_offer_business_contact_v173/);
  assert.match(detail, /Promise\.resolve\(sb\.rpc\('customer_get_offer_business_contact_v173'/);
  assert.match(detail, /tel:/);
  assert.match(detail, /#\/b\/\$\{slug\}/);
  assert.match(detail, /CUI\.activateDialog/);
});

test('business page and console agree on the six-offer cap and the join CTA is self-explanatory', () => {
  assert.doesNotMatch(app, /presentation\.offers:\[\]\)\.slice\(0,2\)/);
  assert.match(app, /const offers=\(Array\.isArray\(presentation\.offers\)\?presentation\.offers:\[\]\)\.slice\(0,6\)/);
  assert.match(app, /items:\[\]\)\.slice\(0,6\)|\.items:\[\]\)\.slice\(0,6\)/);
  assert.match(app, /Customers see up to six current offers\./);
  assert.doesNotMatch(app, /Customers see at most two current offers\./);
  assert.match(app, /addProgramme:'Scan to join'/);
});

test('offer detail sheet joins the dark token scope', () => {
  // v190: dark is opt-in (Profile → Appearance) rather than device-driven, so the scope is now
  // gated on the attribute. The sheets still have to join it — they render outside .customer-surface.
  assert.match(app, /html\[data-customer-theme="dark"\] \.customer-surface,\s*\n?html\[data-customer-theme="dark"\] \.customer-offer-detail-modal \.modal-card,\s*\n?html\[data-customer-theme="dark"\] \.customer-business-detail-modal \.modal-card\{/);
  assert.match(app, /\.customer-offer-detail-modal \.modal-card\{width:min\(480px/);
});

test('uploaded promotion artwork is never cropped and never painted over', () => {
  assert.doesNotMatch(app, /customer-promotion-card-media::after/,
    'no gradient overlay may sit on top of business-uploaded artwork');
  assert.match(app, /\.customer-promotion-card-media img\{[^}]*object-fit:contain/);
  assert.match(app, /\.customer-offer-detail-media img\{[^}]*object-fit:contain/);
  assert.match(app, /\.customer-home-offer-media img\{[^}]*object-fit:contain/);
  assert.doesNotMatch(app, /customer-(promotion-card|offer-detail|home-offer)-media img\{[^}]*object-fit:cover/);
  /* v192: the list card was taller than a phone screen, so the artwork cap and the no-photo ratio
     both shrank. The invariant is unchanged — contain never crops and nothing is drawn over the
     image — only the size did. The offer SHEET below keeps the full-size 16/9 presentation. */
  assert.match(app, /\.customer-promotion-card-media--fallback\{[^}]*aspect-ratio:21\/9/);
  assert.match(app, /\.customer-promotion-card-media img\{[^}]*max-height:clamp\(140px,34vw,220px\);object-fit:contain/);
  assert.match(app, /\.customer-offer-detail-media--fallback\{[^}]*aspect-ratio:16\/9/);
});

test('promotion studio nudges the recommended photo ratio and promises no cropping', () => {
  assert.match(app, /Your photo is always shown whole — never cropped or covered\. Landscape 16:9 fills the card best; tall poster designs \(4:5\) also work\./);
});
