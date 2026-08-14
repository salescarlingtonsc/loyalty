/* V324 — the Limited Offer page's three named buckets (owner markup 2026-08-14 on that page):
 * "1. published - ongoing promotions (with stated expiry - once expired goes to history, allow
 *     for firms to delete if needed to and will be discard away)
 *  2. Drafts (those unpublished ones, able to delete if needed to)
 *  3. History (expired only, deleted drafts please discard)"
 *
 * Real bytes evaluated, not reimplemented — a copy in this file would be a second
 * implementation of the bucket rule that can drift from the one that actually ships. Only the
 * genuinely trivial glue (an object-literal accumulator, a boolean AND) is written by hand; every
 * branching rule is lifted from app.js by exact boundary.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const stripComments = source => source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
const code = stripComments(app);

const statement = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start}`);
  return app.slice(from, to + end.length);
};

const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const promotionDateTextSrc = statement('function promotionDateTextV104(value){', '\n}');
const promotionLifecycleSrc = statement('function promotionLifecycleV186(item,now=new Date()){', '\n}');
const NOW = new Date('2026-08-14T12:00:00+08:00');
const promotionLifecycleV186 = new Function('now',
  `${promotionDateTextSrc}\n${promotionLifecycleSrc}\nreturn promotionLifecycleV186;`)(NOW);

const bucketBody = [
  statement('const growOfferBucketV324=item=>{', '};'),
  'const growOffersBucketedV324={published:[],draft:[],history:[]};',
  'items.forEach(item=>{growOffersBucketedV324[growOfferBucketV324(item)].push(item)});',
  'const growOffersCanWriteV324=isOwner&&canRewards;',
  statement('const growOffersRowHtmlV324=(item,bucket)=>{', '};'),
  statement('const growOffersEmptyV324={', "draft:'No draft saved yet.',history:'Nothing has ended yet.'};"),
  statement("const growOffersTabsV324=[['published','Published'],", "['history','History']];"),
  statement('const growOffersTabStripV324=`<div class="v150-segment" role="group"', '</div>`;'),
  `const growOffersListHtmlV324=growOffersBucketedV324[growOffersTabV324].length
     ?growOffersBucketedV324[growOffersTabV324].map(item=>growOffersRowHtmlV324(item,growOffersTabV324)).join('')
     :\`<p class="muted small" style="padding:14px 0">\${esc(growOffersEmptyV324[growOffersTabV324])}</p>\`;`,
  'return {buckets:growOffersBucketedV324,tabStrip:growOffersTabStripV324,list:growOffersListHtmlV324};',
].join('\n');

const promotionDateTextV104 = new Function(`${promotionDateTextSrc}\nreturn promotionDateTextV104;`)();

const build = new Function('esc', 'isOwner', 'canRewards', 'growOffersTabV324', 'growOffersNowV324',
  'promotionLifecycleV186', 'promotionDateTextV104', 'customerMediaUrlV95', 'items', bucketBody);

const call = (items, {isOwner = true, canRewards = true, tab = 'published'} = {}) =>
  build(esc, isOwner, canRewards, tab, NOW, promotionLifecycleV186, promotionDateTextV104, () => '', items);

const PUBLISHED_LIVE = {id: 'p1', name: '20% off spa', active: true, ends_at: '2026-08-27T23:59:59+08:00'};
const PUBLISHED_SCHEDULED = {id: 'p2', name: 'National Day', active: true, starts_at: '2026-09-01T00:00:00+08:00', ends_at: '2026-09-10T23:59:59+08:00'};
const DRAFT_NEW = {id: 'd1', name: 'Untitled draft', active: false, ends_at: null};
const ENDED_NATURALLY = {id: 'e1', name: 'Merdeka set', active: true, ends_at: '2026-06-30T23:59:59+08:00'};
const RETIRED_PUBLISHED = {id: 'r1', name: 'Old promo', active: false, ends_at: '2026-08-14T09:00:00+08:00'};

test('V324 a live and a scheduled promotion both bucket as Published', () => {
  const {buckets} = call([PUBLISHED_LIVE, PUBLISHED_SCHEDULED]);
  assert.deepEqual(buckets.published.map(i => i.id), ['p1', 'p2']);
  assert.equal(buckets.draft.length, 0);
  assert.equal(buckets.history.length, 0);
});

test('V324 a never-published item buckets as Draft', () => {
  const {buckets} = call([DRAFT_NEW], {tab: 'draft'});
  assert.deepEqual(buckets.draft.map(i => i.id), ['d1']);
  assert.equal(buckets.published.length, 0);
  assert.equal(buckets.history.length, 0);
});

test('V324 a naturally-ended promotion buckets as History even though active is still true', () => {
  /* The owner's rule: "once expired goes to history". active never flips to false when a
     promotion merely runs out the clock (promotionLifecycleV186's own 'ended' state assumes
     exactly this) — so History must be reached by the DATE, not by active. */
  const {buckets} = call([ENDED_NATURALLY], {tab: 'history'});
  assert.deepEqual(buckets.history.map(i => i.id), ['e1']);
  assert.equal(buckets.published.length, 0);
});

test('V324 a retired (deleted-while-published) promotion also buckets as History, never as a phantom Draft', () => {
  /* The one non-obvious case: business_delete_promotion_v183 retires a published item by setting
     active=false AND pulling ends_at to now — it does NOT hard-delete it (the row is kept for
     reports). If the bucket rule checked `active` before the date, this item would land in Draft,
     which is wrong twice over: it was never a draft, and the owner's rule for Published ("will be
     discard away") means it leaves Published, not that it becomes one. */
  const {buckets} = call([RETIRED_PUBLISHED], {tab: 'history'});
  assert.deepEqual(buckets.history.map(i => i.id), ['r1']);
  assert.equal(buckets.draft.length, 0, 'a retired item must never read as an untouched draft');
});

test('V324 the tab strip is a filter group, not the peer-tab pattern growPage forbids', () => {
  const {tabStrip} = call([PUBLISHED_LIVE, DRAFT_NEW, ENDED_NATURALLY], {tab: 'draft'});
  assert.match(tabStrip, /role="group"/);
  assert.doesNotMatch(tabStrip, /role="tablist"|role="tab"/);
  assert.match(tabStrip, /data-grow-offers-tab-v324="published"/);
  assert.match(tabStrip, /data-grow-offers-tab-v324="draft"/);
  assert.match(tabStrip, /data-grow-offers-tab-v324="history"/);
  assert.match(tabStrip, /aria-pressed="true" data-grow-offers-tab-v324="draft"/, 'the active tab is pressed');
  assert.match(tabStrip, /aria-pressed="false" data-grow-offers-tab-v324="published"/, 'an inactive tab is not');
});

test('V324 each row shows counts and only the active bucket\'s rows render', () => {
  const {tabStrip, list} = call([PUBLISHED_LIVE, DRAFT_NEW, ENDED_NATURALLY], {tab: 'published'});
  assert.match(tabStrip, /Published \(1\)/);
  assert.match(tabStrip, /Draft \(1\)/);
  assert.match(tabStrip, /History \(1\)/);
  assert.match(list, /20% off spa/);
  assert.doesNotMatch(list, /Untitled draft/);
  assert.doesNotMatch(list, /Merdeka set/);
});

test('V324 an empty bucket says so instead of rendering nothing', () => {
  const {list} = call([], {tab: 'published'});
  assert.match(list, /No promotion is published right now\./);
});

test('V324 Delete says Retire on Published (record survives) and Delete on Draft (it does not)', () => {
  const published = call([PUBLISHED_LIVE], {tab: 'published'}).list;
  const drafted = call([DRAFT_NEW], {tab: 'draft'}).list;
  assert.match(published, />Retire</);
  assert.doesNotMatch(published, />Delete</);
  assert.match(drafted, />Delete</);
  assert.doesNotMatch(drafted, />Retire</);
});

test('V324 a retired item in History says Ended, never Draft', () => {
  /* Caught by rendering, not by reading the source: promotionLifecycleV186 checks `active` before
     `ends_at`, so a retired promotion's own life.label is 'Draft' — the same word a real,
     untouched draft gets. A History row must never say that; it belongs there because its date
     has passed, and that is what its label must say. */
  const retired = call([RETIRED_PUBLISHED], {tab: 'history'}).list;
  assert.doesNotMatch(retired, />Draft</, 'a retired item read as a draft is the exact confusion History exists to prevent');
  assert.match(retired, />Ended 14 August 2026</);
  const naturallyEnded = call([ENDED_NATURALLY], {tab: 'history'}).list;
  assert.match(naturallyEnded, />Ended 30 June 2026</);
});

test('V324 History rows offer no delete control — nothing to discard from a settled record', () => {
  const rendered = call([ENDED_NATURALLY], {tab: 'history'}).list;
  assert.doesNotMatch(rendered, /data-grow-offer-delete-v324/);
  assert.match(rendered, /Edit</, 'History rows still open the editor');
});

test('V324 a read-only viewer sees no Edit and no delete control on any bucket', () => {
  const rendered = call([PUBLISHED_LIVE], {canRewards: false, tab: 'published'}).list;
  assert.doesNotMatch(rendered, /Edit</);
  assert.doesNotMatch(rendered, /data-grow-offer-delete-v324/);
});

/* ---------------------------------------------------------------- click wiring ---------------- */

test('V324 switching tabs is a pure client filter — no RPC, then a full re-render', () => {
  const handler = code.slice(code.indexOf("outerMain.querySelectorAll('[data-grow-offers-tab-v324]')"),
    code.indexOf("outerMain.querySelectorAll('[data-grow-offer-delete-v324]')"));
  assert.ok(handler.length > 40, 'the tab handler was found and sliced');
  assert.doesNotMatch(handler, /sb\.rpc|sb\.from/, 'switching tabs must never touch the network');
  assert.match(handler, /growOffersTabV324=tab/);
  assert.match(handler, /growRerenderV322\(\)/);
});

test('V324 deleting reuses business_delete_promotion_v183 — the same RPC, same wording, as the deep editor', () => {
  const handler = app.slice(app.indexOf("outerMain.querySelectorAll('[data-grow-offer-delete-v324]')"),
    app.indexOf('/* V324: show/hide the inline confirm block in place'));
  assert.match(handler, /business_delete_promotion_v183/);
  assert.match(handler, /Retire "\$\{name\}"\? Customers stop seeing it immediately\. The record is kept so your reports stay accurate\./);
  assert.match(handler, /Delete the draft "\$\{name\}"\? This cannot be undone\. No customer has seen it\./);
  assert.match(handler, /growRerenderV322\(\)/, 'a real write still repaints from the server reply');
  // Same RPC the deep editor (promotionsPage) already calls — a second write path with different
  // wording would be two sources of truth for one action.
  assert.ok((app.match(/business_delete_promotion_v183/g) || []).length >= 2);
});

test('V324 the Limited Offer rail page keeps its pinned wrapper open string, and the drilled Promotions topic is untouched', () => {
  // These are the exact strings v319-rewards-and-offer.test.mjs pins; re-asserted here as the
  // contract this file's changes must not break.
  assert.match(app, /programmeView==='offers'\?`<div class="grow-limited-offer-v319" data-grow-limited-offer-v319>/);
  assert.match(app, /\$\{topicOnV229\('promotions'\)\?growLimitedOfferCategoryHtmlV319:''\}/);
  assert.equal((app.match(/const growLimitedOfferCategoryHtmlV319=/g) || []).length, 1);
});
