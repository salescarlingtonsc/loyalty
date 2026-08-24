/* nestly_v421 — the owner's 2026-08-21 batch, five marks.
     1. "yes make the friend get the reward too"
     2. photo 1 — "picture not max out … want uploaded photo full to picture" / "why here have big
        empty space", with "your previous fix only fix the empty space for 1 photo — it needs to be
        for all photos moving forward"
     3. photo 2 — "default should align the words - not being cut"
     4. photo 3 — "if i choose other in Industry it should then pop up 'What customers see under
        your name' - not a fixed 'Other'"
     5. photo 4 — the workspace's mobile preview "should reflect the actual customer app, because
        it still has missing fields like Company bio"

   Where a helper is a pure function, this file EXECUTES it rather than grepping for it: a regex
   over source stays green when the code it describes has stopped running. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const indexHtml = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const style = indexHtml.match(/<style>([\s\S]*?)<\/style>/)[1];
const v421 = readFileSync(join(root, 'db', 'migrations',
  '20260822_nestly_v421_two_sided_referral.sql'), 'utf8');

/* Lift a function out of production and run it, with only the collaborators it needs stubbed. */
const fnSource = (name, nextName) => {
  const from = appJs.indexOf(`function ${name}(`);
  const to = appJs.indexOf(`\nfunction ${nextName}(`, from);
  assert.ok(from >= 0 && to > from, `missing ${name} … ${nextName}`);
  return appJs.slice(from, to);
};
const load = (source, prelude = '') => {
  // eslint-disable-next-line no-new-func
  return new Function(`${prelude}\n${source}\nreturn {${source.match(/function (\w+)\(/g)
    .map((m) => m.slice(9, -1)).join(',')}};`)();
};

const esc = `const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));`;

/* ---------------------------------- 1. the friend is paid ----------------------------------- */

test('v421 the friend is granted a gift of their own, keyed so a replay cannot pay twice', () => {
  assert.match(v421, /values\(new\.business_id,new\.client_id,refrow\.id,'friend'/,
    "the friend's grant is written against the friend — new.client_id is the customer at the counter");
  assert.match(v421, /unique \(referral_id, beneficiary\)/,
    'one payout per referral PER SIDE, not one per referral');
  assert.match(v421, /on conflict \(referral_id,beneficiary\) do nothing/,
    'a replayed sale must not write a second grant for either side');
});

test('v421 the friend is paid points of their own, and NULL means "the same as the referrer"', () => {
  assert.match(v421, /v_friend_points:=coalesce\(refprog\.friend_reward_points,v_ref_points,0\)/,
    'an unset friend figure follows the referrer rather than paying nothing');
  assert.match(v421, /'referral qualified: introduced by a friend'/,
    "the friend's ledger row says which side of the referral it settles");
  assert.match(v421, /if v_friend_on and v_friend_points>0 then/,
    'a firm that switched the friend off, or set it to zero, pays the friend nothing');
});

test('v421 the friend payout sits inside the guard that already protected the referrer', () => {
  /* The `update … where status='pending'` + `if found` is what makes the payout once-only. The
     friend's block must be INSIDE it, or a replayed sale would pay the friend every time. */
  const points = v421.slice(v421.indexOf("v_ref_points where id=refrow.id and status='pending'"));
  const friend = points.indexOf('introduced by a friend');
  const closes = points.indexOf('\n          end if;');
  assert.ok(friend > 0 && friend < closes, 'the friend block escaped the once-only guard');
});

test('v421 the workspace writes through a NEW saver, never an overload twin of v420', () => {
  assert.match(appJs, /sb\.rpc\('save_referral_program_v421'/, 'the browser calls the v421 saver');
  assert.doesNotMatch(appJs, /sb\.rpc\('save_referral_program_v420'/, 'and no longer the v420 one');
  assert.match(v421, /create or replace function public\.save_referral_program_v421\(/);
  assert.match(v421, /p_friend_enabled boolean, p_friend_reward_points integer, p_friend_reward_label text/);
});

test('v421 both sides of the referral are stated back to the owner', () => {
  assert.match(appJs, /<dt>Reward for the friend<\/dt>/, 'the settings summary names the friend');
  assert.match(appJs, /Nothing — the referrer only/, 'and says so plainly when that side is off');
  assert.match(appJs, /to the referrer, \$\{friend\} to the friend/,
    'the Rewards overview row names both');
});

test('v421 the customer card describes what will actually be paid, on both sides', () => {
  /* Rendered, not grepped: the card function is lifted out of production and run, with the real
     English strings taken from the app's own locale table. */
  const enBlock = appJs.slice(appJs.indexOf('  en:Object.freeze({'),
    appJs.indexOf("  'zh-CN':Object.freeze({"));
  const en = Object.fromEntries([...enBlock.matchAll(/(\w+):'((?:[^'\\]|\\.)*)'/g)]
    .map(([, key, value]) => [key, value.replace(/\\'/g, "'")]));
  assert.ok(en.referralFriendAlso, 'the locale table must carry the new key');

  const render = (card) => Function('esc', 'CUI', 'ct', 'customerReferralPointsV322',
    'customerReferralMoneyV300', 'customerShareCoBrandV267', 'customerShareMessageV267',
    `${fnSource('customerReferralCardMarkupV300', 'customerPromotionCardV104')}\n`
    + 'return customerReferralCardMarkupV300;')(
    (v) => String(v ?? ''), { icon: () => '' },
    (key, vars = {}) => String(en[key] ?? key).replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? ''),
    (n) => `${Math.max(0, Math.round(Number(n) || 0))} points`,
    (c) => `$${(Number(c || 0) / 100).toFixed(2)}`,
    () => '', () => '')(card, { name: 'Cubbly SPA', currency: 'SGD' });

  const gift = render({ enabled: true, code: 'ABC', reward_kind: 'voucher',
    reward_label: 'Free Coffee', friend_enabled: true, friend_reward_label: 'Free Coffee',
    min_spend_cents: 0 });
  assert.match(gift, /Free Coffee/, 'a gift programme names the gift…');
  assert.doesNotMatch(gift, /0 points/, '…instead of telling the customer they get 0 points');
  assert.match(gift, /Your friend gets Free Coffee too\./, "and states the friend's share");

  const points = render({ enabled: true, code: 'ABC', reward_kind: 'points', reward_points: 50,
    friend_enabled: true, friend_reward_points: 20, min_spend_cents: 0 });
  assert.match(points, /50 points/);
  assert.match(points, /Your friend gets 20 points too\./, 'the friend may get a different figure');

  const oneSided = render({ enabled: true, code: 'ABC', reward_kind: 'points', reward_points: 50,
    friend_enabled: false, min_spend_cents: 0 });
  assert.doesNotMatch(oneSided, /Your friend gets/,
    'a firm that switched the friend off must not have it advertised');

  assert.equal((appJs.match(/referralFriendAlso:/g) || []).length, 4, 'all four locales carry the key');
  assert.equal((appJs.match(/referralGiftFallback:/g) || []).length, 4, 'and its gift fallback');
});

/* ------------------------------- 2. photo 1, the offer card --------------------------------- */

test('v421 cssUrlValueV421 does not double-encode an already-encoded url', () => {
  const { cssUrlValueV421 } = load(fnSource('cssUrlValueV421', 'customerHomeOfferMarkupV167'));
  const data = 'data:image/svg+xml,%3Csvg%20a%3D%22b%22%3E';
  assert.equal(cssUrlValueV421(data), data, 'encodeURI() would have turned every % into %25');
  assert.equal(cssUrlValueV421('https://x/a"b'), 'https://x/a%22b', 'a quote would end the url() early');
  assert.equal(cssUrlValueV421('https://x/a\\b'), 'https://x/a%5Cb');
  assert.equal(cssUrlValueV421(null), '');
});

test('v421 the offer card carries its own artwork as the frame behind it', () => {
  const src = fnSource('customerHomeOfferMarkupV167', 'interleaveCustomerOffersV173');
  assert.match(src, /class="customer-home-offer-media has-art-v421" style="--offer-art:url\(&quot;/,
    'the media block carries the picture as a custom property the stylesheet reads');
  assert.match(src, /cssUrlValueV421\(image\)/, 'through the CSS-escaping helper, not raw');
  assert.match(fnSource('customerPromotionCardV104', 'openCustomerPromotionDetailsV104'),
    /customer-promotion-card-media has-art-v421/, 'and so does the swipe card');
});

test('v421 the frame follows the picture instead of the picture fitting a fixed frame', () => {
  assert.match(style, /\.customer-home-offer-media\{aspect-ratio:auto;flex:1 1 0%;min-height:88px\}/,
    'the media takes every pixel the copy does not — no blank strip under short copy');
  assert.match(style, /\.customer-home-offer-copy\{min-height:0!important;height:auto!important;flex:0 0 auto\}/,
    'and the copy hugs its content at every breakpoint, not just one');
  assert.match(style, /\.customer-home-offer-media\.has-art-v421::before\{[^}]*background-size:cover[^}]*filter:blur/,
    'the leftover margin is filled by the same picture, blurred');
  assert.match(style, /\.customer-home-offer-media>img\{position:relative;z-index:1;object-fit:contain\}/,
    'the artwork itself is still CONTAINed — V173/V371, never cropped');
});

/* --------------------------- 3. photo 2, the words that were cut ---------------------------- */

test('v421 a swiped offer card parks inside the page, not against the screen edge', () => {
  assert.match(style, /\.customer-business-profile-v346 \.customer-reward-offer-track-v339\{scroll-padding-inline:16px\}/,
    'the track bleeds by 16px and must tell the snap about it, as the home shelf already does');
});

test('v421 a portrait poster no longer spills out of the swipe card', () => {
  /* Measured before the fix at 390 and 1280: a 388px-tall image laid out inside a 177px frame,
     105px past both ends of it, painting over the card top and the copy. */
  assert.match(style, /\.customer-reward-offer-page-v339 \.customer-promotion-card-media\{aspect-ratio:1\/1;height:auto;max-height:46vh;min-height:0\}/);
  assert.match(style, /\.customer-reward-offer-page-v339 \.customer-promotion-card-media>img\{max-width:100%;max-height:100%/,
    'the picture is bounded by its frame');
});

/* ------------------------------ 4. photo 3, Industry = Other -------------------------------- */

test('v421 the customer-facing wording field appears when, and only when, it is needed', () => {
  const { workspaceIndustryLabelNeededV421 } =
    load(fnSource('workspaceIndustryLabelNeededV421', 'syncWorkspaceIndustryLabelRowV421'));
  assert.equal(workspaceIndustryLabelNeededV421('other', ''), true, 'Other needs it');
  assert.equal(workspaceIndustryLabelNeededV421('Other', null), true, 'however it is cased');
  assert.equal(workspaceIndustryLabelNeededV421('facial', ''), false, 'a named sector does not');
  assert.equal(workspaceIndustryLabelNeededV421('facial', 'Facial studio'), true,
    'but wording already live on customers must stay editable');
});

test('v421 "Other" is never printed to a customer as a description of the business', () => {
  const src = fnSource('customerBusinessTaglineV385', 'customerProgrammeDirectoryTypeV346');
  const { customerBusinessTaglineV385 } = load(
    `${esc}\nconst customerSectorEmojiV417=()=>'';\n${src}`);
  assert.equal(customerBusinessTaglineV385({ industry: 'other' }), '',
    'a firm on Other with no wording of its own draws no line at all');
  assert.equal(customerBusinessTaglineV385({ industry: 'Other' }), '', 'the resolved label too');
  assert.match(customerBusinessTaglineV385({ industry: 'other', industry_label: 'Facial' }), /Facial/,
    'their own wording still wins');
  assert.match(customerBusinessTaglineV385({ industry: 'Facial / Spa' }), /Facial \/ Spa/,
    'and a real sector is unaffected');
});

/* ------------------------------- 5. photo 4, the live preview ------------------------------- */

test('v421 the preview passes the same business fields the customer app reads', () => {
  const preview = appJs.slice(appJs.indexOf('function customerInterfaceLivePreviewMarkupV326('));
  /* nestly_v486: this window is an arbitrary slice of the function, not a contract about where
     in it these fields must appear. v486 added the live-rewards lookup above them and pushed the
     first of the three from 3.9k to 4191 — the assertions below were still true, the window had
     simply stopped reaching them. Widened to cover the whole function (7.8k today) so the test
     keeps checking what it says it checks instead of where the lines happen to sit. */
  const head = preview.slice(0, 12000);
  assert.match(head, /bio:\(\$\('bbio'\)\?\.value\?\?S\.biz\.bio\?\?''\)\.trim\(\)/,
    'Company bio — the field the owner marked as missing — read live off its own control');
  assert.match(head, /gallery:Array\.isArray\(businessProfileExtrasV418\?\.gallery\)/);
  assert.match(head, /social_links:Array\.isArray\(businessProfileExtrasV418\?\.social_links\)/);
});

test('v421 the preview card no longer tells the owner the bio lives somewhere else', () => {
  assert.doesNotMatch(appJs, /Your bio and booking policy show on your public page instead/,
    'true when V327 wrote it; v417 put the bio under the business name in the wallet');
});
