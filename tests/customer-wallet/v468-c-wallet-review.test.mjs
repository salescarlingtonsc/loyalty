/* V468-C — the four owner marks on the customer wallet (batch 9, 2026-08-23).
 *
 *   C1  the business page's Gallery section: heading, two photos + "See all", and the social
 *       links as a captioned "Follow us here" block (owner photo 1);
 *   C2  the reward-history card: the status pill moves to the card's top-right so the reward's
 *       name and date start at the top of the copy column (owner photo 2);
 *   C3  the Home offer card: the avatar/name row clears the artwork (owner photo 6);
 *   C4  the red reward hero: stamps wording, distance instead of price on the counter, no meter
 *       on a stamp card, and the gift's photo (owner photo 7).
 *
 * House rule (see tests/business-ui/v464-earned-reward-expiry.test.mjs): a source-regex test is
 * vacuous — a grep stays green while the behaviour is dead. Every markup assertion below RUNS the
 * real template out of app/app.js. Only C3 is asserted against the stylesheet, because a
 * position is a stylesheet fact and there is no jsdom here to lay one out; the geometry itself was
 * measured in Chrome during the change (media 1942..2116 vs row 2086..2132 before, row clear of
 * the artwork after).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');

/* ------------------------------------------------------------------ source slicing */

function sliceBetween(src, startMarker, endMarker, label) {
  const i = src.indexOf(startMarker);
  assert.ok(i >= 0, `${label}: start marker not found — app.js moved under this test`);
  assert.equal(src.indexOf(startMarker, i + 1), -1, `${label}: start marker is not unique`);
  const j = src.indexOf(endMarker, i);
  assert.ok(j > i, `${label}: end marker not found after the start`);
  return src.slice(i, j + endMarker.length);
}

function extractFunction(src, name) {
  const m = new RegExp(`^function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `extractFunction: missing ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) {
    acc.push(line);
    if (line === '}') return acc.join('\n');
  }
  throw new Error(`extractFunction: no column-0 close for ${name}`);
}

function extractConst(src, name) {
  const lines = src.split('\n');
  const start = lines.findIndex(l => l.startsWith(`const ${name}=`));
  assert.ok(start >= 0, `extractConst: missing const ${name}`);
  const acc = [];
  for (let i = start; i < lines.length; i++) {
    acc.push(lines[i]);
    if (lines[i].trim().endsWith(';')) return acc.join('\n');
  }
  throw new Error(`extractConst: unterminated const ${name}`);
}

/* Real collaborators. Only two things are stubbed, and neither is under test: CUI.icon (svg
   markup) and customerMediaUrlV95, whose real body accepts only a Supabase storage object path —
   a fixture URL would come back '' and hide the very photo C4 is about. */
const escSrc = extractConst(app, 'esc');
const pointTotalSrc = extractFunction(app, 'customerPointTotalV103');
const rewardUnitSrc = extractFunction(app, 'customerRewardUnitV429');
const unitNounSrc = extractFunction(app, 'customerUnitNounV429');
const availCopySrc = extractConst(app, 'CUSTOMER_REWARD_AVAILABILITY_COPY_V399');
const availLineSrc = extractFunction(app, 'customerRewardAvailabilityLineV399');
const canRedeemSrc = extractFunction(app, 'customerRewardCanRedeem');
/* nestly_v471 put a "?" and an expiry line on every hero page, so the slice below now reaches for
   both. Pulled from source rather than stubbed — a stub of the function under test proves nothing
   (the v392 lesson), and the C4 assertions still measure only what C4 was written to measure. */
const helpButtonSrcV471 = extractFunction(app, 'customerRewardHelpButtonV468');
const endsLineSrcV471 = extractFunction(app, 'customerRewardEndsLineV471');
const socialLabelsSrc = extractConst(app, 'CUSTOMER_SOCIAL_LABELS_V418');
const gallerySrc = extractFunction(app, 'customerBusinessGalleryMarkupV418');
const walletDateSrc = extractFunction(app, 'walletDate');

const CUI_STUB = { icon: (name, o = {}) => `<svg data-icon="${name}" width="${o.size || 16}"></svg>` };
const MEDIA_STUB = 'const customerMediaUrlV95=v=>String(v||"");';

/* ============================================================ C1 · the Gallery section */

const renderGallery = new Function('CUI', `
  ${escSrc}
  ${MEDIA_STUB}
  ${socialLabelsSrc}
  ${gallerySrc}
  return customerBusinessGalleryMarkupV418;`)(CUI_STUB);

const PHOTO = n => ({ image_ref: `/p/${n}.jpg`, caption: n === 2 ? '' : `caption ${n}` });
const LINKS = [
  { platform: 'website', url: 'https://cubbly.example.com' },
  { platform: 'facebook', url: 'https://facebook.com/cubbly' },
  { platform: 'instagram', url: 'https://instagram.com/cubbly' },
];
const countCells = markup => [...markup.matchAll(/data-customer-gallery-v418="/g)].length;
const countHidden = markup => [...markup.matchAll(/data-customer-gallery-v418="\d+" hidden/g)].length;

test('C1 · the heading is Gallery, never the business the customer is already inside', () => {
  const markup = renderGallery({ name: 'Cubbly SPA', gallery: [PHOTO(1), PHOTO(2)], social_links: [] });
  assert.match(markup, /<h2 id="customerBusinessGalleryTitleV418">Gallery<\/h2>/);
  assert.doesNotMatch(markup, /Cubbly SPA/);
  /* The sub-line went with it: the surface has hidden every .customer-business-group-head-v346 p
     since v345, so it has never reached a customer, and the head row is now where See all lives. */
  assert.doesNotMatch(markup, /Photos and where to find them/);
  assert.match(html, /\.customer-business-group-head-v346 p\{display:none\}/);
});

test('C1 · two photos on the page, the rest behind See all', () => {
  const four = renderGallery({ name: 'Cubbly SPA', gallery: [1, 2, 3, 4].map(PHOTO), social_links: [] });
  assert.equal(countCells(four), 4, 'every photo is still emitted — the sheet reads them back out of the DOM');
  assert.equal(countHidden(four), 2, 'only the first two are visible on the page');
  assert.match(four, /data-gallery-see-all-v468/);
  assert.match(four, /See all/);
  /* Exactly two is not "more": no control, and nothing hidden. */
  const two = renderGallery({ name: 'Cubbly SPA', gallery: [1, 2].map(PHOTO), social_links: [] });
  assert.equal(countCells(two), 2);
  assert.equal(countHidden(two), 0);
  assert.doesNotMatch(two, /data-gallery-see-all-v468/);
  /* The hidden cells must actually be hidden: the cell declares its own display, so [hidden]
     alone would not win. */
  assert.match(html, /\.customer-business-gallery-cell-v418\[hidden\]\{display:none!important\}/);
});

test('C1 · the links are a captioned Follow us here block, one row per configured platform', () => {
  const markup = renderGallery({ name: 'Cubbly SPA', gallery: [PHOTO(1)], social_links: LINKS });
  assert.match(markup, /<p class="customer-business-links-head-v468">Follow us here<\/p>/);
  for (const label of ['Website', 'Facebook', 'Instagram'])
    assert.match(markup, new RegExp(`<span class="customer-business-link-label-v468">${label}</span>`));
  assert.equal([...markup.matchAll(/class="customer-business-link-v418"/g)].length, 3,
    'exactly the platforms this business set — no placeholder rows for the ones it did not');
});

test('C1 · the https-only filter is untouched, and an unknown platform is not named', () => {
  const markup = renderGallery({
    name: 'Cubbly SPA', gallery: [PHOTO(1)],
    social_links: [
      { platform: 'website', url: 'http://insecure.example.com' },
      { platform: 'myspace', url: 'https://myspace.example.com' },
      { platform: 'tiktok', url: 'https://tiktok.com/@cubbly' },
    ],
  });
  assert.doesNotMatch(markup, /insecure\.example\.com/, 'the table CHECK is mirrored in the browser');
  assert.doesNotMatch(markup, /myspace/i);
  assert.match(markup, /<span class="customer-business-link-label-v468">TikTok<\/span>/);
});

test('C1 · each single-sided section still reads deliberately, and an empty one is not drawn', () => {
  /* Links but no photos: the section IS the links block, so its heading is that block's and the
     caption is not printed twice. */
  const linksOnly = renderGallery({ name: 'Cubbly SPA', gallery: [], social_links: [LINKS[0]] });
  assert.match(linksOnly, /<h2 id="customerBusinessGalleryTitleV418">Follow us here<\/h2>/);
  assert.equal([...linksOnly.matchAll(/Follow us here/g)].length, 1);
  assert.doesNotMatch(linksOnly, /customer-business-gallery-grid-v418/);
  /* Photos but no links: Gallery, and no empty box promising links. */
  const photosOnly = renderGallery({ name: 'Cubbly SPA', gallery: [1, 2, 3].map(PHOTO), social_links: [] });
  assert.match(photosOnly, /<h2 id="customerBusinessGalleryTitleV418">Gallery<\/h2>/);
  assert.doesNotMatch(photosOnly, /customer-business-links-v418/);
  /* Neither: nothing at all, exactly as v418 shipped. */
  assert.equal(renderGallery({ name: 'Cubbly SPA', gallery: [], social_links: [] }), '');
});

/* ============================================================ C2 · the reward-history card */

const historyCardSrc = sliceBetween(
  app,
  '        return `<article class="wallet-reward customer-reward-card-v339 customer-reward-card-claimed-v422',
  '        </article>`;\n',
  'reward history card',
);

const renderHistoryCard = new Function('CUI', `
  ${escSrc}
  ${pointTotalSrc}
  ${walletDateSrc}
  ${MEDIA_STUB}
  const entitlementSourceChipV429={welcome:'Welcome gift',bringback:'We miss you',referral:'Referral'};
  const rewardUnit='points';
  return function(item){
    const name=String(item?.reward_name||'').trim()||'Reward';
    const when=item?.redeemed_at?walletDate(item.redeemed_at):'';
    const spent=item?.consumes_balance===true?Math.max(0,Number(item.points_spent)||0):0;
    const photo=customerMediaUrlV95(item?.image_ref);
    const sourceChipV429=entitlementSourceChipV429[String(item?.source||'')]||'';
    const lapsedV464=String(item?.source||'')==='expired';
    ${historyCardSrc}
  };`)(CUI_STUB);

test('C2 · the name and the date come before the status pill, inside one copy column', () => {
  const card = renderHistoryCard({
    reward_name: 'Free Lotion', redeemed_at: '2026-08-20T04:00:00Z',
    consumes_balance: false, points_spent: 0, image_ref: '/r/lotion.jpg', source: 'reward',
  });
  const copy = card.indexOf('customer-reward-claimed-copy-v468');
  const text = card.indexOf('customer-reward-claimed-text-v468');
  const nameAt = card.indexOf('Free Lotion');
  const dateAt = card.indexOf('20 Aug 2026');
  const pillAt = card.indexOf('>Claimed<');
  assert.ok(copy > 0 && text > copy, 'the copy column wraps the text block');
  assert.ok(nameAt > text && dateAt > nameAt, 'name then date, at the top of the column');
  assert.ok(pillAt > dateAt, 'the pill is last in the document, which is what puts it top-right');
  /* The thumbnail stays, and it stays OUTSIDE the copy column — it is the grid's photo track. */
  assert.ok(card.indexOf('customer-reward-photo-v340') < copy);
  assert.match(card, /<img src="\/r\/lotion\.jpg"/);
});

test('C2 · nothing about which rewards appear, what they are called, or the date format moved', () => {
  const noPhoto = renderHistoryCard({
    reward_name: 'Free Lotion', redeemed_at: '2026-08-20T04:00:00Z',
    consumes_balance: false, points_spent: 0, image_ref: null, source: 'reward',
  });
  assert.match(noPhoto, /customer-reward-photo-empty-v340/, 'the generic gift placeholder survives');
  assert.match(noPhoto, /data-icon="loyalty"/);
  assert.match(noPhoto, />Claimed</);
  const lapsed = renderHistoryCard({
    reward_name: 'Free Kopi', redeemed_at: '2026-07-30T04:00:00Z',
    consumes_balance: false, points_spent: 0, image_ref: null, source: 'expired',
  });
  assert.match(lapsed, />Expired</, 'v464: a reward lost to its deadline is not a claim');
  assert.doesNotMatch(lapsed, />Claimed</);
  const chipped = renderHistoryCard({
    reward_name: 'Free Kopi', redeemed_at: '2026-07-30T04:00:00Z',
    consumes_balance: true, points_spent: 250, image_ref: null, source: 'welcome',
  });
  assert.match(chipped, />Welcome gift</);
  assert.match(chipped, /250 points/);
  /* Two pills share one box on the right rather than stacking above the name. */
  assert.ok(chipped.indexOf('Free Kopi') < chipped.indexOf('>Welcome gift<'));
});

test('C2 · the pill box is the right-hand column of a row, capped so a long name keeps its measure', () => {
  assert.match(html, /\.customer-reward-claimed-copy-v468\{\s*grid-area:copy;display:flex;align-items:flex-start;justify-content:space-between/s);
  assert.match(html, /\.customer-reward-claimed-text-v468\{flex:1 1 auto;min-width:0\}/);
  assert.match(html, /\.customer-reward-card-claimed-v422 \.customer-reward-card-head-v339\{\s*flex:0 0 auto;justify-content:flex-end;max-width:46%;margin:0\}/s);
});

/* ============================================================ C3 · the Home offer card */

test('C3 · the avatar/name row drops clear of the artwork, and the copy follows it', () => {
  /* nestly_v395 pinned the row to the avatar's box at top:-30px, so 30 of its 46 pixels — and all
     of its text — sat on the picture. MEASURED at 430px on 8c2ff5a: media 1942..2116, row
     2086..2132. The coin keeps a deliberate overlap; the text does not. */
  assert.match(html, /\.customer-home-offer-business\{top:-13px!important\}/);
  assert.match(html, /\.customer-home-offer-copy\{padding-top:32px\}/);
  /* The pin itself is untouched — this is a shift, not a relayout. */
  assert.match(html, /\.customer-home-offer-business\{position:absolute!important;top:-30px/);
  /* And the card's own height is not one of the things that changed. */
  assert.match(html, /\.customer-home-offer\{flex:0 0 min\(72vw,288px\)!important;min-height:266px!important;height:266px/);
});

/* ============================================================ C4 · the red reward hero */

const heroPagesSrc = sliceBetween(
  app,
  '  const pages=(Array.isArray(rewards)?rewards:[]).map(reward=>{',
  '\n  }).filter(Boolean);\n',
  'hero reward pages',
);

const buildHeroPages = new Function('CUI', 'rewards', 'held', 'unit', 'redemptionEnabled', `
  ${escSrc}
  ${pointTotalSrc}
  ${rewardUnitSrc}
  ${unitNounSrc}
  ${availCopySrc}
  ${availLineSrc}
  ${canRedeemSrc}
  ${MEDIA_STUB}
  /* the two loop-scope values the real function computes above this slice; ct() is identity in
     English, which is the locale every assertion below reads. */
  ${helpButtonSrcV471}
  ${endsLineSrcV471}
  const walletDate=v=>String(v||'');
  let customerHeroRewardRowsV471=[];
  const unitWord=unit==='stamps'?'stamps':(unit||'points');
  const seen=new Set();
  const heroName='',heroCost=NaN,bookAction='';
  ${heroPagesSrc}
  return pages;`);

const STAMP_GIFT = {
  action_key: 'rw1', id: 'rw1', customer_name: 'Free Lotion', cost_points: 5,
  availability: 'insufficient_balance', redemption_kind: 'catalog_reward', image_ref: '/r/lotion.jpg',
};
const stampPage = (over = {}, held = 0) =>
  buildHeroPages(CUI_STUB, [{ ...STAMP_GIFT, ...over }], held, 'stamps', true)[0];
const pointPage = (over = {}, held = 120) =>
  buildHeroPages(CUI_STUB, [{ ...STAMP_GIFT, cost_points: 500, ...over }], held, 'points', true)[0];

test('C4 mark 1 · a stamp card says stamps, and a points card still says points', () => {
  /* The one availability sentence that names a unit. It named the wrong one on every stamp card
     in the product: "More points needed" under a stamp meter. */
  const short = stampPage({ availability: 'insufficient_balance' }, 9);
  assert.match(short, /More stamps needed/);
  assert.doesNotMatch(short, /More points needed/);
  assert.match(pointPage({ availability: 'insufficient_balance' }, 900), /More points needed/);
  /* Only the unit noun is swapped — the other availability sentences are word-for-word the same. */
  assert.match(stampPage({ availability: 'reward_expired' }, 9), /This reward has expired/);
  assert.match(stampPage({ availability: 'tier_locked' }, 9), /Unlocks at a higher tier/);
});

test('C4 mark 2 · the counter says how many are still needed, never "0 more"', () => {
  assert.match(stampPage({}, 0), /5 more stamps to go/);
  assert.match(stampPage({}, 4), /1 more stamp to go/, 'one stamp is a stamp, not stamps');
  /* Nothing left to count: the counter falls back to the price rather than asserting readiness
     the server has not granted. */
  const level = stampPage({}, 5);
  assert.doesNotMatch(level, /more stamps? to go/);
  assert.match(level, /5 stamps/);
  /* And where the SERVER says ready, the arithmetic may still be short — readiness is never
     subtraction (v145/v397), so a READY pill is never contradicted by a distance beside it. */
  const ready = stampPage({ availability: 'available_at_counter' }, 0);
  assert.match(ready, />READY</);
  assert.doesNotMatch(ready, /more stamps to go/);
  /* Points is untouched: the counter is the price, and the distance keeps its own line. */
  const points = pointPage({}, 120);
  assert.match(points, /500 points/);
  assert.match(points, /380 points to go/);
  assert.doesNotMatch(points, /more points to go/);
});

test('C4 mark 3 · the meter goes for stamps and stays for points', () => {
  assert.doesNotMatch(stampPage({}, 0), /customer-reward-progress/);
  assert.match(pointPage({}, 120), /customer-reward-progress customer-business-tier-meter-v386/);
  assert.match(pointPage({}, 120), /aria-valuenow="24"/, 'the points bar still reports real progress');
  /* A ready reward has never carried one, in either model. */
  assert.doesNotMatch(pointPage({ availability: 'available_at_counter' }, 900), /customer-reward-progress/);
});

test('C4 mark 4 · the gift photo is a column, and a gift without one leaves no hole', () => {
  const withPhoto = stampPage({}, 0);
  assert.match(withPhoto, /class="customer-hero-reward-photo-v468" src="\/r\/lotion\.jpg"/);
  assert.match(withPhoto, /customer-hero-has-photo-v468/);
  const without = stampPage({ image_ref: null }, 0);
  assert.doesNotMatch(without, /customer-hero-reward-photo-v468/);
  assert.doesNotMatch(without, /customer-hero-has-photo-v468/,
    'no modifier means one column — the card is the shape it was before the photo existed');
  assert.match(without, /customer-hero-reward-body-v468/, 'the body wrapper is unconditional');
  /* The second column exists only under the modifier, so the absent photo cannot leave a gap. */
  assert.match(html, /\.customer-hero-reward-body-v468\{[^}]*grid-template-columns:minmax\(0,1fr\);/s);
  assert.match(html, /\.customer-hero-has-photo-v468 \.customer-hero-reward-body-v468\{grid-template-columns:minmax\(0,1fr\) 92px\}/);
  /* A stored object that has since been deleted takes the column with it, as v340 does for the
     reward list. */
  assert.match(app, /image\.closest\('\.customer-business-summary-v346'\)\?\.classList\.remove\('customer-hero-has-photo-v468'\)/);
});

test('C4 · everything the hero already promised about readiness and identity is unchanged', () => {
  const ready = stampPage({ availability: 'available_at_counter' }, 0);
  assert.match(ready, /data-customer-redeem="rw1" data-hero-redeem-v397/);
  assert.match(ready, /Redeem now/);
  /* v397: readiness is customerRewardCanRedeem's answer. A catalogue row with no id is not
     redeemable however the availability reads, and the card must not offer a button. */
  const noId = stampPage({ availability: 'available_at_counter', id: null }, 0);
  assert.match(noId, />NEXT REWARD</);
  assert.doesNotMatch(noId, /data-hero-redeem-v397/);
  /* v399: a zero-cost reward is a real, always-claimable reward and still gets a page. */
  assert.ok(stampPage({ cost_points: 0 }, 0));
});
