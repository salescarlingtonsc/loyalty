import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v264 (owner): "i need a share button for promotions - to share to social media / whatsapp / FB /
   IG / tiktok/wechat/ telegram - so customers can help businesses to share."

   The load-bearing facts this file protects:
   - Instagram, TikTok and WeChat have NO web share endpoint. The ONLY route to them is the device
     share sheet, so navigator.share must be tried first and the UI must say where they live
     rather than drawing three buttons that would do nothing.
   - the link a stranger receives must be the CANONICAL public origin, never whatever host the app
     is running on, and never a page that requires an account;
   - dismissing the OS sheet is a decision, not an error, and must not be answered with a second
     sheet;
   - what is recorded about a share is the business and the channel — never the recipient. */

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');
const indexHtml = await read('app/index.html');
const customerUi = await read('app/customer-ui.js');
const migration = await read('db/migrations/20260809_nestly_v264_promotion_share_event.sql');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const shareSource = section(appJs, 'const CUSTOMER_SHARE_CHANNELS_V264', 'async function shareCustomerOfferV264');
const dispatchSource = section(appJs, 'async function shareCustomerOfferV264', 'function customerPromotionCardV104');

const api = new Function('esc', 'CUI', 'NestlyNativeBridge', 'promotionDateTextV104', `
  ${section(appJs, 'function customerPromotionValidityV104', '/* V183 (owner: "Upload the image')}
  ${shareSource}
  return {url:customerShareUrlV264,text:customerShareTextV264,channels:CUSTOMER_SHARE_CHANNELS_V264,
    button:customerShareButtonMarkupV264,sheet:customerShareSheetMarkupV264};`)(
  (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  { icon: () => '<svg></svg>' },
  { publicUrl: (path) => {
    const target = new URL(String(path || '/'), 'https://www.peekaa.asia/');
    if (target.origin !== 'https://www.peekaa.asia') throw new Error('non-canonical');
    return target.href;
  } },
  (value) => value ? String(value) : '');

const OFFER = { id: 'o1', name: 'National Day: 50% off first prata', starts_at: '7 August 2026', ends_at: '31 August 2026' };
const BUSINESS = { id: 'b1', name: 'Cubbly', slug: 'kopi-tiam-tyeh' };

/* -------------------------------------------------------------------- the link and the message */

test('the shared link is the canonical public page, not the current host', () => {
  assert.equal(api.url(BUSINESS), 'https://www.peekaa.asia/#/b/kopi-tiam-tyeh');
});

test('a business with no public page is not shared at all', () => {
  assert.equal(api.url({}), '');
  assert.equal(api.url({ slug: '   ' }), '');
  assert.match(dispatchSource, /if\(!url\)return toast\('This business has no public page to share yet\.'\)/,
    'the customer is told why, rather than handed a broken link');
});

test('a slug is URL-encoded on the way into the link', () => {
  assert.match(api.url({ slug: 'a b/c' }), /a%20b%2Fc/);
  assert.doesNotMatch(api.url({ slug: 'a b/c' }), /a b\/c/);
});

test('the message carries the offer, because the destination cannot show it yet', () => {
  const text = api.text(OFFER, BUSINESS);
  assert.match(text, /National Day: 50% off first prata/);
  assert.match(text, /at Cubbly/);
  assert.match(text, /Valid 7 August 2026 – 31 August 2026/);
  // a nameless offer still produces a sendable sentence
  assert.match(api.text({}, BUSINESS), /this offer at Cubbly/);
});

/* ------------------------------------------------------------------------------ the channels */

test('every channel drawn is one a tap genuinely reaches', () => {
  const keys = api.channels.map((channel) => channel.key);
  assert.deepEqual(keys, ['whatsapp', 'telegram', 'facebook']);
  const text = api.text(OFFER, BUSINESS), url = api.url(BUSINESS);
  const hrefs = Object.fromEntries(api.channels.map((c) => [c.key, c.href({ text, url })]));
  assert.match(hrefs.whatsapp, /^https:\/\/wa\.me\/\?text=/);
  assert.match(hrefs.telegram, /^https:\/\/t\.me\/share\/url\?url=/);
  assert.match(hrefs.facebook, /^https:\/\/www\.facebook\.com\/sharer\/sharer\.php\?u=/);
  // the link must survive as a link, not be mangled into the text
  for (const href of Object.values(hrefs)) {
    assert.match(href, /kopi-tiam-tyeh/);
    assert.doesNotMatch(href, / /, 'every parameter is encoded');
  }
});

test('Instagram, TikTok and WeChat are never drawn as buttons — they have no web endpoint', () => {
  const sheet = api.sheet({ text: 'x', url: 'https://www.peekaa.asia/#/b/s' });
  for (const absent of ['instagram.com', 'tiktok.com', 'weixin', 'wechat.com']) {
    assert.ok(!sheet.toLowerCase().includes(absent), `${absent} has no share endpoint and must not be faked`);
  }
  assert.match(sheet, /Instagram, TikTok and WeChat can be reached from your phone/,
    'the customer is told where those channels actually live');
});

test('copy link is always offered, because it works where nothing else does', () => {
  assert.match(api.sheet({ text: 'x', url: 'https://www.peekaa.asia/' }), /data-share-channel="copy"/);
  /* v123's rule: exactly one navigator.clipboard.writeText in the app, inside the shared helper
     that disables the button, announces the result and reports a refusal honestly. Share uses it
     rather than opening a second clipboard path. */
  assert.match(shareSource, /await copyTextToClipboard\(url,\{button:control/);
  assert.doesNotMatch(shareSource, /navigator\.clipboard/, 'no second clipboard path');
  assert.match(shareSource, /Copying is blocked in this browser/,
    'a refused clipboard must say so, not fail silently');
});

/* ------------------------------------------------------------------ the device sheet comes first */

test('the OS share sheet is tried first, since it is the only path to IG, TikTok and WeChat', () => {
  assert.match(dispatchSource, /if\(navigator\.share\)\{/);
  assert.match(dispatchSource, /await navigator\.share\(\{title:[^,]+,text,url\}\)/);
  const nativeAt = dispatchSource.indexOf('navigator.share');
  const fallbackAt = dispatchSource.lastIndexOf('showCustomerShareSheetV264');
  assert.ok(nativeAt < fallbackAt, 'the in-app sheet is the fallback, not the default');
});

test('dismissing the OS sheet ends it — no second sheet chasing the customer', () => {
  assert.match(dispatchSource, /if\(error\?\.name==='AbortError'\)return;/);
});

/* ------------------------------------------------------------------------------ what is recorded */

test('a share records the business and the channel, and nothing about the recipient', () => {
  assert.match(dispatchSource, /recordProductInteractionV100\('customer\.promotion_shared',businessId/);
  assert.match(dispatchSource, /context:\{channel,promotion_id:String\(item\?\.id\|\|''\),surface_version:'v264'\}/);
  assert.doesNotMatch(dispatchSource, /recipient|contact|phone|email/i,
    'the app never learns who a customer shared with, and must not pretend to');
  // both halves of the v100 contract name the event, or the write is refused
  assert.match(appJs, /'customer\.promotion_shared'/);
  assert.match(migration, /'customer\.promotion_shared', 'client', 'customer'/);
  assert.match(migration, /never the recipient, the message, or whether the post was completed/);
  assert.match(migration, /on conflict \(event_name\) do nothing/, 're-running the migration is safe');
});

/* ------------------------------------------------------------------------------- where it appears */

test('Share sits on the promotion card and in the offer sheet', () => {
  const card = section(appJs, 'function customerPromotionCardV104', 'function openCustomerPromotionDetailsV104');
  assert.match(card, /\$\{customerShareButtonMarkupV264\(item\?\.id\)\}/);
  const sheet = section(appJs, 'function showCustomerOfferDetailV173', 'function wireCustomerHomeOffersV167');
  assert.match(sheet, /customerShareButtonMarkupV264\(item\?\.id,\{small:false\}\)/);
  assert.match(sheet, /shareButton\.onclick=\(\)=>shareCustomerOfferV264\(item,business\)/);
});

test('the card button shares the offer it belongs to, read back from the rendered list', () => {
  const wiring = section(appJs, "document.querySelectorAll('[data-share-offer]')", "document.querySelector('[data-programme-offers-retry]')");
  assert.match(wiring, /const offerId=String\(button\.dataset\.shareOffer\|\|''\)/);
  assert.match(wiring, /\.find\(item=>String\(item\?\.id\|\|''\)===offerId\)/);
  assert.match(wiring, /if\(offer\)shareCustomerOfferV264\(offer,/, 'an unmatched id shares nothing');
});

test('the button is labelled and iconed as sharing, not exporting', () => {
  assert.match(shareSource, /CUI\.icon\('share',\{size:16\}\)/);
  assert.match(shareSource, /aria-label="Share this offer"/);
  assert.match(customerUi, /\n\s+share:'M18 8a3 3/, 'a real share glyph exists in the shared icon set');
  assert.match(customerUi, /\n\s+chat:'M21 15a2/);
});

test('the share sheet is a real dialog and styles at 390px', () => {
  assert.match(appJs, /overlay\.setAttribute\('role','dialog'\);overlay\.setAttribute\('aria-modal','true'\)/);
  assert.match(appJs, /CUI\.activateDialog\(overlay,\{onClose:\(\)=>deactivate\(\{restoreFocus:true\}\),initialFocus:'#customerShareClose'\}\)/);
  assert.match(indexHtml, /\.customer-share-channels\{[^}]*grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/);
  assert.match(indexHtml, /\.customer-share-channel\{[^}]*min-height:76px/);
});

test('external share links cannot reach back into the app', () => {
  assert.match(shareSource, /target="_blank" rel="noopener noreferrer"/);
});
