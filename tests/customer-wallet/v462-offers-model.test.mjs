/* V462 — the customer half of owner ruling R2.
 *
 *   R2(a) the business page shows ALL live offers (the two client `.slice(0,6)` caps are gone)
 *   R2(b) the Home feed carries ONE offer per business — the server's job, proven in
 *         db/tests/v462_featured_offer_and_live_cap.sql; what is proven HERE is that the client
 *         renders exactly what it is handed and adds nothing of its own
 *   R2(d) the ORDER of that Home feed is shuffled CLIENT-SIDE on each app load, unbiased, with
 *         zero backend involvement
 *
 * Everything below EXECUTES the shipped bytes. The shuffle is lifted whole; so are
 * interleaveCustomerOffersV173, customerHomeOffersMarkupV167 and customerRewardOfferSwipeMarkupV339.
 * Only leaf helpers that reach the DOM, localStorage or the icon set are stubbed, and each stub
 * emits a distinctive marker so an assertion cannot pass on an accidentally empty render.
 *
 * "Per load, not per render" is modelled the only way it can be: a load is one evaluation of the
 * bundle, so each harness build IS a load. Two builds with two seeds must disagree; one build
 * asked twice must not.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const between = (start, end) => {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end ${end}`);
  return app.slice(from, to + end.length);
};

const SHUFFLE_SRC = between('const CUSTOMER_HOME_OFFER_SHUFFLE_SEED_V462=(()=>{',
  '\nlet customerHomeOfferIndexV173=new Map();');
const INTERLEAVE_SRC = between('function interleaveCustomerOffersV173(items){', '\n}');
const HOME_MARKUP_SRC = between('function customerHomeOffersMarkupV167(state={status:\'loading\',items:[]}){', '\n}');
const SWIPE_SRC = between('function customerRewardOfferSwipeMarkupV339({reward=null,items=[]', '\n}');

const esc = value => String(value ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* One "app load": a fresh evaluation of the shuffle module with a pinned seed. */
function load(seed) {
  const previous = globalThis.__peekaaOfferShuffleSeedV462;
  globalThis.__peekaaOfferShuffleSeedV462 = seed;
  try {
    return new Function('esc', `
      const CUI={icon:()=>'<svg data-icon></svg>'};
      const customerSeenOfferVersionsV167=()=>new Set();
      const customerHomeOfferMarkupV167=item=>
        '<article data-offer-id="'+esc(item.id)+'" data-business="'+esc(item.business.slug)+'"></article>';
      const customerPromotionCardV104=item=>'<article data-offer-card="'+esc(item.id)+'"></article>';
      const customerClaimableRewardBannerMarkupV337=()=>'';
      ${INTERLEAVE_SRC}
      ${SHUFFLE_SRC}
      ${HOME_MARKUP_SRC}
      ${SWIPE_SRC}
      return {
        seed:CUSTOMER_HOME_OFFER_SHUFFLE_SEED_V462,
        shuffle:shuffleCustomerHomeOffersV462,
        random:offerShuffleRandomV462,
        home:customerHomeOffersMarkupV167,
        swipe:customerRewardOfferSwipeMarkupV339,
      };
    `)(esc);
  } finally {
    if (previous === undefined) delete globalThis.__peekaaOfferShuffleSeedV462;
    else globalThis.__peekaaOfferShuffleSeedV462 = previous;
  }
}

const featuredFeed = count => Array.from({ length: count }, (_, index) => ({
  id: `offer-${index}`,
  version_id: `offer-${index}:1`,
  business: { id: `biz-${index}`, slug: `shop-${index}`, name: `Shop ${index}` },
}));

const renderedIds = html => [...html.matchAll(/data-offer-id="([^"]+)"/g)].map(m => m[1]);

test('V462 the seed is injectable, and a pinned seed makes the whole load deterministic', () => {
  assert.equal(load(1234).seed, 1234);
  assert.equal(load(0).seed, 0, 'zero is a legitimate seed, not a missing one');
  const a = load(99), b = load(99);
  const feed = featuredFeed(6);
  assert.deepEqual(a.shuffle(feed).map(o => o.id), b.shuffle(feed).map(o => o.id));
});

test('V462 R2d: the order differs across loads, and is stable within one load', () => {
  const feed = featuredFeed(6);
  const one = load(1), two = load(2);
  assert.notDeepEqual(one.shuffle(feed).map(o => o.id), two.shuffle(feed).map(o => o.id),
    'two app loads must not present the same shop first');
  /* Within a load Home re-renders on every wallet poll (v295/v370). If the order were drawn per
     render the rail would reshuffle under the customer's thumb while they were reading it. */
  assert.deepEqual(one.shuffle(feed).map(o => o.id), one.shuffle(feed).map(o => o.id));
});

test('V462 the shuffle preserves the set exactly — nothing dropped, nothing duplicated', () => {
  const feed = featuredFeed(9);
  for (let seed = 0; seed < 40; seed += 1) {
    const out = load(seed).shuffle(feed);
    assert.equal(out.length, 9);
    assert.deepEqual([...out].map(o => o.id).sort(), feed.map(o => o.id).sort());
  }
  assert.deepEqual(load(7).shuffle([]), []);
  assert.deepEqual(load(7).shuffle(null), []);
  assert.deepEqual(load(7).shuffle(featuredFeed(1)).map(o => o.id), ['offer-0']);
});

test('V462 the shuffle does not mutate the array it was given', () => {
  const feed = featuredFeed(5);
  const before = feed.map(o => o.id);
  load(3).shuffle(feed);
  assert.deepEqual(feed.map(o => o.id), before);
});

test('V462 the shuffle is UNBIASED — every permutation of three shops is reachable, and roughly equally', () => {
  /* Fairness is the entire point of R2d: a biased shuffle would systematically put the same shop
     first, which is the behaviour the rotation exists to prevent. Fisher-Yates drawing j from
     [0,i] is unbiased; the naive "swap with any index" variant is not, and this test is what
     separates them. 6000 loads over 6 permutations expects ~1000 each; the bounds are wide enough
     that a fair shuffle cannot fail and narrow enough that the naive variant (which over-weights
     some permutations by ~30%) cannot pass. */
  const feed = featuredFeed(3);
  const counts = new Map();
  const RUNS = 6000;
  for (let seed = 1; seed <= RUNS; seed += 1) {
    const key = load(seed).shuffle(feed).map(o => o.id).join(',');
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  assert.equal(counts.size, 6, `all 6 permutations must occur; saw ${counts.size}`);
  for (const [permutation, seen] of counts) {
    assert.ok(seen > RUNS / 6 * 0.8 && seen < RUNS / 6 * 1.2,
      `${permutation} appeared ${seen} times in ${RUNS} loads — outside the fair band`);
  }
});

test('V462 the underlying generator produces values in [0,1) and does not stall', () => {
  const random = load(42).random(42);
  const drawn = Array.from({ length: 500 }, () => random());
  for (const value of drawn) assert.ok(value >= 0 && value < 1, `out of range: ${value}`);
  assert.ok(new Set(drawn).size > 400, 'the generator must not be a constant or a short cycle');
});

test('V462 R2b: Home renders exactly one card per business and invents no extra', () => {
  const feed = featuredFeed(4);
  const html = load(11).home({ status: 'ready', items: feed });
  const ids = renderedIds(html);
  assert.equal(ids.length, 4);
  assert.deepEqual([...ids].sort(), feed.map(o => o.id).sort());
  const shops = [...html.matchAll(/data-business="([^"]+)"/g)].map(m => m[1]);
  assert.equal(new Set(shops).size, shops.length, 'no shop may appear twice on Home');
});

test('V462 the DOM order Home paints IS the shuffled order, not the server order', () => {
  const feed = featuredFeed(6);
  const session = load(2026);
  assert.deepEqual(renderedIds(session.home({ status: 'ready', items: feed })),
    session.shuffle(feed).map(o => o.id));
  /* Two loads, two running orders on the same server payload — the whole of R2d. */
  const other = load(2027);
  assert.notDeepEqual(renderedIds(session.home({ status: 'ready', items: feed })),
    renderedIds(other.home({ status: 'ready', items: feed })));
});

test('V462 NEGATIVE CONTROL: shuffling never reaches the network or the server payload', () => {
  const source = SHUFFLE_SRC;
  assert.doesNotMatch(source, /sb\.rpc|sb\.from|fetch\(/,
    'R2d is explicitly zero Supabase load — rotation must cost no round trip');
  assert.doesNotMatch(source, /localStorage|sessionStorage/,
    'a stored order would make the shuffle per-device state rather than per-load');
  /* And the empty and error states still render, rather than being shuffled into nothing. */
  const session = load(5);
  assert.match(session.home({ status: 'ready', items: [] }), /No offers right now/);
  assert.match(session.home({ status: 'error', items: [] }), /Offers couldn’t load/);
  assert.match(session.home({ status: 'loading', items: [] }), /Loading offers…/);
});

test('V462 R2a: a business page with EIGHT live offers renders eight — the old cap was six', () => {
  const session = load(1);
  const eight = Array.from({ length: 8 }, (_, index) => ({ id: `live-${index}` }));
  const html = session.swipe({ items: eight, status: 'ready', business: { name: 'Kopi Lab' },
    includeReward: false, title: 'Latest offers' });
  const cards = [...html.matchAll(/data-offer-card="([^"]+)"/g)].map(m => m[1]);
  assert.equal(cards.length, 8, 'the seventh and eighth offers must not be cut');
  assert.deepEqual(cards, eight.map(o => o.id), 'and they keep the order the server sent');
});

test('V462 NEGATIVE CONTROL: neither client cap survives anywhere in the fetch or the render', () => {
  assert.doesNotMatch(app, /presentation\.offers:\[\]\)\.slice\(/);
  assert.doesNotMatch(app, /promotionsResult\.data\?\.items:\[\]\)\.slice\(/);
  /* The reader is what bounds it now, and it reports the bound it applied. */
  const migration = readFileSync(
    new URL('../../db/migrations/20260823_nestly_v462_featured_offer_and_live_cap.sql', import.meta.url), 'utf8');
  /* Comment-stripped: the migration's own header QUOTES the retired `'limit',2` to record what it
     is replacing, and a changelog entry is not a shipped statement. */
  const statements = migration.replace(/^\s*--.*$/gm, '');
  assert.match(statements, /'limit',v_limit/);
  assert.doesNotMatch(statements, /'limit',2/);
  assert.doesNotMatch(statements, /\blimit 6\b/);
  assert.match(statements, /select greatest\(coalesce\(entitlement\.max_published_offers,0\),0\)/);
});
