/* V274 — the public marketing landing page at "/".
   These tests exist because the page makes PUBLIC PROMISES and owns a LOAD-BEARING
   ROUTE. Two classes of regression are pinned here:

   1. Routing. "/" used to serve the app. Installed PWAs, push-notification clicks
      (app/sw.js customerPushRoute) and every historical peekaa.asia/#/… bookmark
      still aim at "/". If the rewrite order or the in-page forwarding script drifts,
      real users land on a marketing page instead of their wallet.
   2. Honesty. The platform is pre-launch. Fabricated social proof, invented
      statistics or an invented price would be a lie told to the exact people we
      want to trust us, so the page is pinned against inventing any. */
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import test from 'node:test';

const root = resolve(import.meta.dirname, '../..');
const read = (path) => readFile(resolve(root, path), 'utf8');

const landing = await read('app/landing.html');
const vercel = JSON.parse(await read('app/vercel.json'));

/* ── the file itself ──────────────────────────────────────────────────────── */

test('the landing page exists and is a complete standalone document', () => {
  assert.ok(existsSync(resolve(root, 'app/landing.html')), 'app/landing.html must exist');
  assert.match(landing, /^<!DOCTYPE html>/i);
  assert.match(landing, /<html lang="en">/);
  assert.match(landing, /<\/html>\s*$/);
});

test('the page stays small enough to paint fast on a cold mobile network', () => {
  const bytes = Buffer.byteLength(landing, 'utf8');
  assert.ok(bytes < 200 * 1024, `landing.html is ${Math.round(bytes / 1024)}KB; the budget is 200KB`);
});

/* ── self-containment ─────────────────────────────────────────────────────── */

const BRAND_IMAGES = new Set(['/brand/peekaa-logo.png', '/brand/peekaa-mark.png']);

test('no external script is loaded: the page carries its own behaviour', () => {
  const external = [...landing.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["']/gi)].map((m) => m[1]);
  assert.deepEqual(external, [], `landing.html must not load external scripts, found: ${external.join(', ')}`);
});

test('every image is one of the two Peekaa brand PNGs — no stock photos, no remote assets', () => {
  const images = [...landing.matchAll(/<img\b[^>]*\bsrc=["']([^"']+)["']/gi)].map((m) => m[1]);
  assert.ok(images.length > 0, 'the page should use the brand artwork');
  for (const src of images) {
    assert.ok(BRAND_IMAGES.has(src), `unexpected image source "${src}"; only the brand PNGs are allowed`);
  }
});

test('CSS is inline and pulls in no remote asset', () => {
  const stylesheets = [...landing.matchAll(/<link\b[^>]*\brel=["']stylesheet["'][^>]*>/gi)].map((m) => m[0]);
  for (const tag of stylesheets) {
    const href = /\bhref=["']([^"']+)["']/i.exec(tag)?.[1] || '';
    assert.ok(
      href.startsWith('https://fonts.googleapis.com/'),
      `the only stylesheet the CSP admits is Google Fonts; found "${href}"`
    );
  }
  assert.ok(landing.includes('<style>'), 'the page styles itself inline');
  const cssUrls = [...landing.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)].map((m) => m[1]);
  for (const url of cssUrls) {
    assert.ok(
      BRAND_IMAGES.has(url) || url.startsWith('data:'),
      `CSS must not reference remote assets; found url(${url})`
    );
  }
});

test('no third-party origin is contacted for code, styling or imagery', () => {
  const hosts = [...landing.matchAll(/\b(?:src|href)=["']https?:\/\/([^/"']+)/gi)].map((m) => m[1]);
  const allowed = new Set(['www.peekaa.asia', 'fonts.googleapis.com', 'fonts.gstatic.com']);
  for (const host of hosts) {
    assert.ok(allowed.has(host), `landing.html must not fetch from ${host}`);
  }
});

/* ── the forwarding script: this is what keeps push notifications working ── */

test('the forwarding script is the FIRST script on the page', () => {
  const firstScript = /<script\b[^>]*>([\s\S]*?)<\/script>/i.exec(landing);
  assert.ok(firstScript, 'the page must contain a script');
  const body = firstScript[1];
  assert.match(body, /location\.hash/, 'the first script must inspect the hash before anything renders');
  assert.match(body, /sb-gadpooereceldfpfxsod/, 'the first script must look for the Supabase session key');
});

test('a hash route is handed back to the app at /app, preserving the hash', () => {
  const firstScript = /<script\b[^>]*>([\s\S]*?)<\/script>/i.exec(landing)[1];
  assert.match(
    firstScript,
    /indexOf\(['"]#\/['"]\)\s*===\s*0/,
    'only real routes (#/…) forward — a bare #anchor must stay on the landing page'
  );
  assert.match(
    firstScript,
    /location\.replace\(\s*['"]\/app['"]\s*\+\s*\w+\s*\)/,
    'the hash must be carried across to /app so /#/wallet/<slug> still resolves'
  );
});

test('a signed-in visitor is forwarded to /app instead of being shown marketing', () => {
  const firstScript = /<script\b[^>]*>([\s\S]*?)<\/script>/i.exec(landing)[1];
  assert.match(firstScript, /location\.replace\(\s*['"]\/app['"]\s*\)/);
  assert.match(firstScript, /try\s*\{/, 'localStorage access must be guarded — it throws in private modes');
  assert.match(firstScript, /catch/, 'a storage failure must fall through to showing the landing page');
});

test('the forwarding script actually behaves as specified when executed', () => {
  const firstScript = /<script\b[^>]*>([\s\S]*?)<\/script>/i.exec(landing)[1];

  const runWith = ({ hash = '', keys = [], throwOnStorage = false }) => {
    const replaced = [];
    const store = {
      get length() {
        if (throwOnStorage) throw new Error('storage disabled');
        return keys.length;
      },
      key(index) { return keys[index]; }
    };
    const documentElement = { className: '' };
    const win = {
      location: { hash, replace: (target) => replaced.push(target) },
      localStorage: store
    };
    const fn = new Function('window', 'document', firstScript);
    fn(win, { documentElement });
    return { replaced, className: documentElement.className };
  };

  assert.deepEqual(
    runWith({ hash: '#/wallet/kopi-and-co' }).replaced,
    ['/app#/wallet/kopi-and-co'],
    'a push-notification wallet link must reach the app with its slug intact'
  );
  assert.deepEqual(runWith({ hash: '#/customer/bookings' }).replaced, ['/app#/customer/bookings']);
  assert.deepEqual(runWith({ hash: '#/customer/messages' }).replaced, ['/app#/customer/messages']);

  assert.deepEqual(
    runWith({ keys: ['sb-gadpooereceldfpfxsod-auth-token'] }).replaced,
    ['/app'],
    'a returning signed-in user must skip the marketing page'
  );

  const anonymous = runWith({ keys: ['peekaa-pwa-prompt-dismissed'] });
  assert.deepEqual(anonymous.replaced, [], 'a signed-out visitor must see the landing page');
  assert.match(anonymous.className, /\bjs\b/, 'the js class gates the reveal animations');

  const anchorOnly = runWith({ hash: '#pricing' });
  assert.deepEqual(anchorOnly.replaced, [], 'an in-page anchor must not be treated as an app route');

  const privateMode = runWith({ throwOnStorage: true });
  assert.deepEqual(privateMode.replaced, [], 'a localStorage throw must degrade to the landing page');
  assert.match(privateMode.className, /\bjs\b/);
});

/* ── the rewrite contract ─────────────────────────────────────────────────── */

test('"/" is owned by edge middleware, and the rewrites cover only the app paths', () => {
  /* V274 follow-up, learned in production: Vercel resolves the FILESYSTEM before rewrites, so a
     rewrite on "/" can never beat a real index.html — the first deploy served the app at "/"
     with the landing reachable only at /landing.html. The split therefore lives in
     app/middleware.js (edge middleware runs before the filesystem). This test pins that
     middleware's whole contract, because a silent regression here strands either every new
     visitor (no landing) or every installed PWA (no app). */
  const middleware = readFileSync(resolve(root, 'app/middleware.js'), 'utf8');
  assert.match(middleware, /matcher:\s*'\/'/, 'middleware must run on exactly "/"');
  assert.match(middleware, /searchParams\.get\('source'\)\s*===\s*'pwa'/, 'installed PWAs (start_url /?source=pwa) must fall through to the app');
  assert.match(middleware, /return undefined/, 'the PWA branch and the catch must fall OPEN to the app');
  assert.match(middleware, /x-middleware-rewrite/, 'the rewrite is the x-middleware-rewrite contract');
  assert.match(middleware, /landing\.html/, 'and it must target the landing');
  assert.match(middleware, /catch/, 'a middleware throw must not 500 the domain root');
  assert.doesNotMatch(middleware, /^\s*import\s/m, 'zero imports: there is no package.json in the deploy root');

  const rewrites = vercel.rewrites;
  /* v268 note: /o/:id is the server-rendered shared-offer page — a real function route, not an
     app path, and the one rewrite that must never fall through to the SPA shell. */
  assert.deepEqual(rewrites.map((r) => r.source), ['/app', '/join', '/o/:id', '/business', '/admin'],
    'no "/" rewrite may exist — it cannot fire and would misleadingly imply it does');
  /* nestly_v527: /app now serves index.gen.html — the same document with its 512KB inline
     stylesheet swapped for a fingerprinted <link>. app/index.html is still the SOURCE. */
  assert.deepEqual(rewrites[0], { source: '/app', destination: '/index.gen.html' },
    "/app is the app's canonical path and the target of every forward");
  assert.ok(
    rewrites.some((r) => r.source === '/business' && r.destination === '/index.gen.html'),
    '/business must keep serving the app'
  );
});

test('the rewrites live in the template that generates app/vercel.json', async () => {
  /* app/vercel.json is GENERATED by scripts/runtime-config/generate.mjs from
     config/runtime/vercel.template.json. Hand-editing the output looks like it works
     and is then silently reverted by the next generator run. */
  const template = JSON.parse(await read('config/runtime/vercel.template.json'));
  assert.deepEqual(template.rewrites, vercel.rewrites,
    'the routing change must be made in config/runtime/vercel.template.json, not in the generated file');
});

test('no rewrite claims "/" — the middleware is the only owner of the root', () => {
  /* V274 follow-up: superseded by the middleware. A "/" rewrite can never fire (filesystem
     first), so any rule claiming "/" is dead config that misleads the next reader into
     believing rewrites route the root. Zero is the only correct number. */
  const rootRules = vercel.rewrites.filter((rule) => rule.source === '/');
  assert.equal(rootRules.length, 0, 'the middleware owns "/"; a "/" rewrite is dead config');
});

test('the manifest start_url still matches the PWA rewrite condition', async () => {
  const manifest = JSON.parse(await read('app/manifest.webmanifest'));
  assert.equal(manifest.start_url, '/?source=pwa',
    'if start_url changes, rewrites[0] stops matching and installed apps break');
});

test('the service worker still routes pushes at the root path this page forwards from', async () => {
  const sw = await read('app/sw.js');
  assert.match(sw, /['"`]\/#\/wallet\/\$\{/, 'push clicks target /#/wallet/<slug> on the root path');
  assert.match(sw, /['"`]\/#\/customer\/bookings['"`]/);
  assert.match(sw, /['"`]\/#\/customer\/messages['"`]/);
  assert.ok(!/APP_SHELL[\s\S]*?\n\s*'\/',/.test(sw),
    'the service worker must not pre-cache "/", or re-pointing it would serve a stale app shell');
});

test('every security header block survives the rewrite change untouched', () => {
  const sources = vercel.headers.map((block) => block.source);
  assert.deepEqual(sources, [
    '/(.*)',
    '/sw.js',
    '/runtime-config.js',
    '/runtime-config-loader.js',
    '/app-:chunk.js',
    /* nestly_v527: the extracted stylesheet is fingerprinted exactly like the surface chunks, so
       it takes the same immutable rule. That rule IS the win — without it the stylesheet would
       inherit the default and be revalidated on every visit, which is the state we just left. */
    '/app.css',
    '/manifest.webmanifest'
  ]);
  const global = new Map(
    vercel.headers.find((block) => block.source === '/(.*)').headers.map((h) => [h.key, h.value])
  );
  assert.match(global.get('Content-Security-Policy'), /default-src 'self'/);
  assert.match(global.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  assert.equal(global.get('X-Frame-Options'), 'DENY');
  assert.equal(global.get('X-Content-Type-Options'), 'nosniff');
  assert.match(global.get('Strict-Transport-Security'), /max-age=31536000/);
  assert.ok(vercel.redirects.every((rule) => rule.destination.startsWith('https://www.peekaa.asia')),
    'the apex-to-www redirects must be preserved');
});

/* ── honesty ──────────────────────────────────────────────────────────────── */

/* nestly_v653: this used to pin THREE price literals in app/app.js, which only proved the app
   and the landing page had been typed the same way — and it did not stop the app disagreeing
   with the catalogue Stripe actually charges from. It did not: "Annual saves SGD 600" sat next
   to a 148/monthly, 1,188/annual catalogue whose real saving is 588. The subscription card now
   DERIVES every figure from billing_plan_catalog_v124, so the app cannot drift by construction
   and there is no literal left to grep. The guard therefore moves to where drift is still
   possible — the hand-typed landing page — and is anchored to the catalogue amounts declared in
   the v162 migration rather than to another copy of the same typing. */
test('the advertised prices are the ones the product actually charges', async () => {
  const app = await read('app/app.js');
  const catalogue = await read('db/migrations/20260804_nestly_v162_stripe_launch_price_148.sql');

  const monthlyCents = 14800, annualCents = 118800;
  assert.match(catalogue, new RegExp(`base_amount_cents = ${monthlyCents}\\b`),
    'the monthly catalogue amount moved; every advertised price below must move with it');
  assert.match(catalogue, new RegExp(`base_amount_cents = ${annualCents}\\b`),
    'the annual catalogue amount moved; every advertised price below must move with it');

  const sgd = cents => (cents / 100).toLocaleString('en-SG',
    { minimumFractionDigits: 0, maximumFractionDigits: 0 });
  assert.match(landing, new RegExp(`SGD ${sgd(annualCents).replace(',', ',')}\\b`),
    'the landing page must quote the real annual price');
  assert.match(landing, new RegExp(`SGD ${sgd(monthlyCents)}\\b`),
    'the landing page must quote the real monthly price');
  assert.match(landing, new RegExp(`SGD ${sgd(annualCents / 12)}/month equivalent`),
    'the landing page must quote the real annual equivalent');

  // The app must read those amounts, never restate them.
  assert.match(app, /annualTierV664\?esc\(money\(annualTierV664\.amount_cents\)\)/,
    'the annual label must render from the capacity tier the server priced');
  assert.match(app, /monthlyTierV664\?esc\(money\(monthlyTierV664\.amount_cents\)\)/,
    'the monthly label must render from the capacity tier the server priced');
  assert.match(app, /Number\(monthlyTierV664\.amount_cents\)\*12-Number\(annualTierV664\.amount_cents\)/,
    'the annual saving must be computed, not asserted');
  assert.doesNotMatch(app, /Annual saves SGD \d/,
    'the saving must never be re-hardcoded');
  assert.doesNotMatch(app, /<strong>Annual · SGD [\d,]+\/year<\/strong>/,
    'the annual label must never be re-hardcoded');
  assert.doesNotMatch(app, /<strong>Monthly · SGD [\d,]+\/month<\/strong>/,
    'the monthly label must never be re-hardcoded');
});

test('the landing page does not contradict the in-app per-branch pricing caveat', async () => {
  const app = await read('app/app.js');
  /* nestly_v666: the app states the per-branch rule on the Subscription card ("Every branch is
     charged this tier once") and prices it on the add-branch form; the landing page keeps its own
     sentence. What must not happen is the landing page promising free branches. */
  assert.match(app, /Every branch is charged this tier once\./);
  assert.match(landing, /extra branch is charged like another shop/i,
    'the branch caveat must be repeated, not silently dropped');
  assert.doesNotMatch(landing, /unlimited branches|branches? (?:are |is )?free|no extra cost/i);
});

test('the structured-data offers carry the real prices and no invented rating', () => {
  const block = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/i.exec(landing);
  assert.ok(block, 'the page must publish one JSON-LD block');
  const data = JSON.parse(block[1]);
  const graph = data['@graph'];
  const types = graph.map((node) => node['@type']);
  assert.ok(types.includes('Organization'));
  assert.ok(types.includes('SoftwareApplication'));

  const software = graph.find((node) => node['@type'] === 'SoftwareApplication');
  const prices = software.offers.map((offer) => `${offer.priceCurrency} ${offer.price}`).sort();
  assert.deepEqual(prices, ['SGD 1188', 'SGD 148']);

  const serialised = JSON.stringify(data);
  assert.ok(!serialised.includes('aggregateRating'), 'a pre-launch product has no ratings to aggregate');
  assert.ok(!serialised.includes('reviewCount'));
  assert.ok(!serialised.includes('ratingValue'));
});

test('the page invents no social proof: no testimonials, logos, star ratings or customer counts', () => {
  const forbidden = /testimonial|trusted by \d|★|[0-9,]+ (?:businesses|customers) (?:trust|use)/i;
  assert.doesNotMatch(landing, forbidden, 'fabricated social proof must never ship on a pre-launch page');
});

test('the page makes no additional invented-traction claims', () => {
  const claims = [
    /join(?:ed)? (?:by )?[0-9,]+\+? (?:businesses|merchants|shops)/i,
    /\b[0-9,]+\+? (?:happy|satisfied) (?:customers|businesses)/i,
    /rated \d(?:\.\d)? (?:out of|\/) ?5/i,
    /\bas (?:seen|featured) (?:in|on)\b/i,
    /\baward-winning\b/i,
    /\b(?:#1|number one|market[- ]leading)\b/i
  ];
  for (const claim of claims) {
    assert.doesNotMatch(landing, claim, `unverifiable traction claim matched ${claim}`);
  }
});

test('the page never claims legal compliance, only what the product does', () => {
  assert.doesNotMatch(landing, /PDPA[- ]compliant|compliant with (?:the )?PDPA|GDPR[- ]compliant|fully compliant/i,
    'compliance is a matter for counsel, not marketing copy');
  assert.match(landing, /consent/i, 'the page should still describe the consent behaviour that does exist');
});

test('the page does not promise delivery channels the product has not switched on', () => {
  /* V282 retarget of the REASON, not the rule. This used to read "app/runtime-config.js ships
     webPushPublicKey:'' " — v282 ships a real key, so web push is no longer dead. Every other
     outbound channel still is: SMS, email and WhatsApp remain owner-deferred and the campaign tool
     still says "Delivery is not enabled yet". The rule is therefore unchanged — no send/broadcast
     promise may appear — and the push-specific claims below stay banned because a push campaign
     tool does not exist even though the transport now does. */
  const overclaims = [
    /push (?:notification )?campaign/i,
    /send (?:them |out )?(?:a )?(?:sms|text message)/i,
    /email (?:blast|campaign|newsletter)/i,
    /broadcast to (?:all )?(?:your )?customers/i,
    /whatsapp (?:blast|campaign|broadcast)/i
  ];
  for (const claim of overclaims) {
    assert.doesNotMatch(landing, claim, `outbound-delivery claim matched ${claim}`);
  }
});

test('multilingual support is scoped to the business workspace, never the customer app', async () => {
  const app = await read('app/app.js');
  assert.match(app, /WORKSPACE_LOCALES_V97=Object\.freeze\(\['en','zh-CN','ms'\]\)/,
    'the workspace locale set moved');
  /* v293 widened the customer surface to en/zh-CN/ms, so the landing may now
     claim customer-side languages — but the claim must match the shipped set. */
  assert.match(app, /CUSTOMER_LOCALES=Object\.freeze\(\['en','zh-CN','ms','ta'\]\)/,
    'the landing language claims are pinned to the shipped customer locale set');

  if (/Bahasa Melayu/.test(landing)) {
    assert.match(
      landing,
      /business workspace runs in English, 中文 or Bahasa Melayu/,
      'any multilingual claim must name the business workspace as its scope'
    );
    assert.match(landing, /customer rewards app follows each member’s choice of English, 中文, Bahasa Melayu or தமிழ்/,
      'the customer-side language support must be stated accurately');
  }
});

/* ── accessibility, SEO and motion ────────────────────────────────────────── */

test('there is exactly one h1 and the heading order never skips a level', () => {
  const headings = [...landing.matchAll(/<h([1-6])\b/gi)].map((m) => Number(m[1]));
  assert.equal(headings.filter((level) => level === 1).length, 1, 'a page has exactly one h1');
  assert.equal(headings[0], 1, 'the first heading on the page is the h1');
  for (let i = 1; i < headings.length; i += 1) {
    assert.ok(headings[i] - headings[i - 1] <= 1,
      `heading order jumps from h${headings[i - 1]} to h${headings[i]}`);
  }
});

test('the page carries its SEO and social metadata', () => {
  /* V548 (strategy ruling 2026-08-26): the page identifies as the retention outcome, never as
     "a loyalty platform" — that phrase filed Peekaa into the category it out-builds. */
  assert.match(landing, /<title>Peekaa — Turn first-time customers into regulars \| Singapore<\/title>/);
  assert.ok(!/<title>[^<]*loyalty[^<]*platform/i.test(landing),
    'the title must never self-label Peekaa as a loyalty platform again');
  assert.match(landing, /<meta name="description" content="[^"]{80,300}">/);
  assert.match(landing, /<link rel="canonical" href="https:\/\/www\.peekaa\.asia\/">/);
  for (const property of ['og:title', 'og:description', 'og:image', 'og:url', 'og:type']) {
    assert.match(landing, new RegExp(`<meta property="${property}"`), `missing ${property}`);
  }
  for (const name of ['twitter:card', 'twitter:title', 'twitter:description', 'twitter:image']) {
    assert.match(landing, new RegExp(`<meta name="${name}"`), `missing ${name}`);
  }
  assert.match(landing, /<meta name="viewport" content="width=device-width/);
});

test('the target keywords appear naturally and are not stuffed', () => {
  const text = landing.replace(/<style>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .toLowerCase();
  for (const keyword of ['customer loyalty', 'rewards', 'retention', 'customer']) {
    assert.ok(text.includes(keyword), `the page should read naturally about "${keyword}"`);
  }
  const loyalty = (text.match(/loyalty/g) || []).length;
  assert.ok(loyalty >= 3, 'the page should actually be about loyalty');
  assert.ok(loyalty < 40, `"loyalty" appears ${loyalty} times — that reads as keyword stuffing`);
});

test('reduced motion is honoured: nothing is hidden and nothing is transformed', () => {
  assert.match(landing, /@media\s*\(\s*prefers-reduced-motion:\s*reduce\s*\)/,
    'the page must respond to the reduced-motion preference');
  const block = /@media\s*\(\s*prefers-reduced-motion:\s*reduce\s*\)\s*\{([\s\S]*?)\n\}/.exec(landing);
  assert.ok(block, 'the reduced-motion block must be findable');
  assert.match(block[1], /opacity:\s*1\s*!important/, 'revealed content must be visible without scrolling');
  assert.match(block[1], /transform:\s*none\s*!important/, 'no element may be offset under reduced motion');

  const script = [...landing.matchAll(/<script\b(?![^>]*\bsrc=)(?![^>]*application\/ld)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).join('\n');
  assert.match(script, /prefers-reduced-motion: reduce/,
    'the script must also check the preference before observing or transforming anything');
});

test('the scroll story degrades to plain stacked sections without JavaScript', () => {
  /* Reveal styles are scoped to html.js, and only the first script adds that class,
     so a visitor with JavaScript disabled sees every section at full opacity. */
  const revealRules = [...landing.matchAll(/^[^\n]*\.reveal[^\n]*$/gm)].map((m) => m[0]);
  const hidingRules = revealRules.filter((rule) => /opacity:\s*0/.test(rule));
  assert.ok(hidingRules.length > 0, 'the page does use reveal-on-scroll');
  for (const rule of hidingRules) {
    assert.match(rule, /^html\.js\s/, `"${rule.trim()}" hides content without requiring JavaScript`);
  }
});

test('the page uses no animated library and only translate3d for depth', () => {
  const script = [...landing.matchAll(/<script\b(?![^>]*\bsrc=)(?![^>]*application\/ld)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).join('\n');
  assert.match(script, /requestAnimationFrame/, 'scroll work must be scheduled on a frame');
  assert.match(script, /translate3d\(/, 'layered depth must stay on the compositor');
  assert.doesNotMatch(script, /\.style\.(?:top|left|width|height|margin)\s*=/,
    'the scroll handler must not write layout-triggering properties');
});

/* ── V283 · the five-layer scroll depth system ─────────────────────────────
   The owner's brief is a SPEC, not a taste: five layers, each in a named band
   of apparent scroll rate, all driven continuously by scroll position. Rates
   are declared in the markup, so they can be pinned here — a layer silently
   drifting out of its band is the regression these tests exist to catch. */

const BANDS = {
  L1: [0.15, 0.25],   // background glows and large soft shapes
  L2: [0.35, 0.50],   // decorative fragments / reward symbols
  L3: [0.70, 0.80],   // the product UI composition — the main object
  L4: [1.00, 1.20],   // floating product cards, nearer than the composition
  L5: [1.20, 1.40]    // small foreground elements
};
const inBand = (value, band) => value >= BANDS[band][0] - 1e-9 && value <= BANDS[band][1] + 1e-9;
const attrValues = (name) =>
  [...landing.matchAll(new RegExp(`\\b${name}="([-0-9.]+)"`, 'g'))].map((m) => Number(m[1]));

test('V283 · the fixed background layers all sit in the L1 or L2 rate band', () => {
  const drifts = attrValues('data-drift');
  assert.ok(drifts.length >= 8, `expected a populated depth field, found ${drifts.length} layers`);
  for (const rate of drifts) {
    assert.ok(
      inBand(rate, 'L1') || inBand(rate, 'L2'),
      `data-drift="${rate}" is in neither L1 (0.15–0.25) nor L2 (0.35–0.50)`
    );
  }
  assert.ok(drifts.some((r) => inBand(r, 'L1')), 'L1 (0.15–0.25x) must be represented');
  assert.ok(drifts.some((r) => inBand(r, 'L2')), 'L2 (0.35–0.50x) must be represented');
});

test('V283 · every in-flow layer sits in the L3, L4 or L5 rate band', () => {
  const rates = [...attrValues('data-rate'), ...attrValues('data-rate-sm')];
  assert.ok(rates.length >= 12, `expected the layered composition, found ${rates.length} layers`);
  for (const rate of rates) {
    assert.ok(
      inBand(rate, 'L3') || inBand(rate, 'L4') || inBand(rate, 'L5'),
      `data-rate="${rate}" falls outside L3 (0.70–0.80), L4 (1.00–1.20) and L5 (1.20–1.40)`
    );
  }
  for (const band of ['L3', 'L4', 'L5']) {
    assert.ok(rates.some((r) => inBand(r, band)), `${band} must be represented`);
  }
  /* A layer at exactly 1.0 would be pinned to the page and read as no layer at
     all, so the floating cards must actually lead it. */
  assert.ok(rates.some((r) => r > 1.0), 'at least one layer must travel faster than the page');
  assert.ok(rates.some((r) => r < 1.0), 'at least one layer must travel slower than the page');
});

test('V283 · the product composition really is the layer that lags', () => {
  /* If the hero mocks ever lose their L3 rate the page collapses back into a
     flat stack of sections, which is exactly the complaint this work answers. */
  for (const cls of ['stage-dash', 'stage-phone', 'stage-hub']) {
    const tag = new RegExp(`class="[^"]*${cls}[^"]*"[^>]*`).exec(landing)?.[0] || '';
    const rate = Number(/\bdata-rate="([-0-9.]+)"/.exec(tag)?.[1]);
    assert.ok(inBand(rate, 'L3'), `.${cls} must carry an L3 rate, found "${rate}"`);
  }
});

test('V283 · the hero reads business dashboard → Peekaa → customer experience', () => {
  const dash = landing.indexOf('>Business dashboard<');
  const hub = landing.indexOf('class="stage-hub"');
  const customer = landing.indexOf('>Customer experience<');
  assert.ok(dash > -1 && hub > -1 && customer > -1, 'all three stations must be labelled');
  assert.ok(dash < hub && hub < customer, 'the hero must read left to right, in that order');
});

test('V283 · the sticky scene exists and runs the four owner-named steps in order', () => {
  assert.match(landing, /id="sceneTrack"/, 'the scene needs a track taller than the viewport');
  assert.match(landing, /id="sceneSticky"/, 'and a stage that sticks inside it');
  assert.match(landing, /html\.js \.scene-track\{height:\d+vh\}/,
    'the track height is what turns scrolling into story progress');
  assert.match(landing, /html\.js \.scene-sticky\{position:sticky/,
    'the stage must pin, and only when JavaScript is driving it');

  const steps = [...landing.matchAll(/<li class="scene-step">[\s\S]*?<span class="t">([^<]+)<\/span>/g)]
    .map((m) => m[1].trim());
  assert.deepEqual(steps, ['Reward customers', 'Keep them engaged', 'Bring them back', 'Build loyalty']);

  const pieces = [...landing.matchAll(/id="scenePiece([A-D])"/g)].map((m) => m[1]);
  assert.deepEqual(pieces, ['A', 'B', 'C', 'D'], 'four components must converge on the last step');
});

test('V283 · the write phase reads no layout and writes no layout property', () => {
  /* Every measurement belongs in measure(). A single getBoundingClientRect in
     the rAF callback turns a 60fps page into a stuttering one. */
  const paint = /function paint\(\)\{([\s\S]*?)\n  \}/.exec(landing);
  assert.ok(paint, 'the paint function must be findable');
  const body = paint[1];
  for (const forbidden of ['getBoundingClientRect', 'offsetHeight', 'offsetTop', 'getComputedStyle', 'scrollHeight']) {
    assert.ok(!body.includes(forbidden), `paint() must not read layout (found ${forbidden})`);
  }
  const writes = [...body.matchAll(/\.style\.([A-Za-z]+)\s*=/g)].map((m) => m[1]);
  assert.ok(writes.length > 0, 'paint() does move things');
  for (const property of writes) {
    assert.ok(['transform', 'opacity'].includes(property),
      `paint() may only write transform and opacity; found style.${property}`);
  }
  /* A wide window: the reduced-motion listener spans several lines before its
     options object, and a short window would miss the flag and false-fail. */
  const listeners = [...landing.matchAll(/addEventListener\('scroll'[\s\S]{0,320}?\}\);/g)].map((m) => m[0]);
  assert.ok(listeners.length > 0);
  for (const listener of listeners) {
    assert.match(listener, /passive:\s*true/, 'every scroll listener must be passive');
  }
});

test('V283 · reduced motion removes the depth system entirely', () => {
  const block = /@media\s*\(\s*prefers-reduced-motion:\s*reduce\s*\)\s*\{([\s\S]*?)\n\}/.exec(landing)[1];
  assert.match(block, /\[data-rate\]/, 'in-flow layers must be neutralised');
  assert.match(block, /\[data-drift\]/, 'fixed layers must be neutralised');
  assert.match(block, /\.depth[^}]*display:none!important/,
    'the whole depth field is removed, not merely frozen');
  assert.match(block, /\.scene-track\{height:auto!important\}/,
    'the sticky track must collapse or the reader scrolls three empty screens');
  assert.match(block, /\.scene-sticky\{position:static!important/, 'and the stage must unpin');
  assert.match(block, /\.scene-piece\{position:static!important;opacity:1!important/,
    'every scene component must be visible and in normal flow');

  /* And the engine must bail before it registers a single layer. */
  const script = [...landing.matchAll(/<script\b(?![^>]*\bsrc=)(?![^>]*application\/ld)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).join('\n');
  const guard = /if\(reduce\)\{([\s\S]*?)\n  \}/.exec(script);
  assert.ok(guard, 'the engine must have an explicit reduced-motion early return');
  assert.match(guard[1], /return;/, 'reduced motion returns before any layer is registered');
  assert.ok(script.indexOf('querySelectorAll(\'[data-drift]\')') > script.indexOf('if(reduce){'),
    'the layer registry must be built after the reduced-motion guard, not before it');
});

test('V283 · the phone keeps the depth, at a shorter throw', () => {
  /* The brief is explicit: mobile reduces amplitude and layer count. It never
     switches the system off, and it never lets a layer push the page sideways. */
  const script = [...landing.matchAll(/<script\b(?![^>]*\bsrc=)(?![^>]*application\/ld)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).join('\n');
  const amp = /amp=vw<700\?([0-9.]+):/.exec(script);
  assert.ok(amp, 'a narrow viewport must scale the throw');
  const factor = Number(amp[1]);
  assert.ok(factor > 0.4 && factor < 1,
    `the phone throw factor is ${factor}; it must be reduced but never zero`);
  assert.match(landing, /overflow-x:hidden/, 'no layer may ever widen the document');
  assert.match(landing, /\.scene-stage\{[^}]*overflow:hidden/,
    'the morphing stage must clip rather than push the page sideways');
});

/* ── links ────────────────────────────────────────────────────────────────── */

test('every internal link resolves to a real file, a real rewrite or a real anchor', () => {
  const ids = new Set([...landing.matchAll(/\bid=["']([^"']+)["']/g)].map((m) => m[1]));
  const rewriteSources = new Set(vercel.rewrites.map((rule) => rule.source));
  const hrefs = [...landing.matchAll(/<a\b[^>]*\bhref=["']([^"']+)["']/gi)].map((m) => m[1]);
  assert.ok(hrefs.length > 0);

  for (const href of hrefs) {
    if (/^https?:|^mailto:/.test(href)) continue;
    if (href.startsWith('#')) {
      assert.ok(ids.has(href.slice(1)), `anchor ${href} has no matching element id`);
      continue;
    }
    if (href.endsWith('.html')) {
      assert.ok(existsSync(resolve(root, 'app', href.replace(/^\//, ''))),
        `${href} does not exist in app/`);
      continue;
    }
    /* V286: acquisition CTAs now carry ?signup=1 so "Get started" and "Log in" stop being the
       same URL. A rewrite matches the PATH, so the query is compared against nothing. */
    const path = href.split('?')[0];
    assert.ok(rewriteSources.has(path), `${href} is not served by any rewrite in app/vercel.json`);
  }
});

/* V286: retargeted, not deleted. "Get started" and "Log in" used to be the SAME url — a
   prospective customer clicking the page's main CTA landed on a sign-in form asking for a
   password they had never set. Acquisition CTAs now carry ?signup=1 (route() answers that with
   renderBusinessSignupChoice); the header "Log in" deliberately still does not. */
test('both primary calls to action point at the firm auth surface', () => {
  const labels = (re) => [...landing.matchAll(re)].map((m) => m[1].replace(/<[^>]+>/g, '').trim());
  const signup = labels(/<a\b[^>]*\bhref=["']\/business\?signup=1["'][^>]*>([\s\S]*?)<\/a>/gi);
  const signin = labels(/<a\b[^>]*\bhref=["']\/business["'][^>]*>([\s\S]*?)<\/a>/gi);
  assert.ok(signup.some((label) => /get started/i.test(label)),
    'a "Get started" CTA must target /business?signup=1');
  assert.ok(signin.some((label) => /log in/i.test(label)), 'a "Log in" CTA must target /business');
  assert.ok(signup.length >= 4, 'the signup CTA should repeat down the page, not appear once');
  assert.ok(!signin.some((label) => /get started/i.test(label)),
    'no "Get started" CTA may still point at the bare sign-in url');
});

test('the firm auth surface really does offer both sign-in and sign-up', async () => {
  const app = await read('app/app.js');
  assert.match(app, /cleanPath==='\/business'\)return '#\/business'/,
    '/business must still resolve to the business auth route');
  assert.match(app, /mode==='in'\?'Sign in':'Sign up'/,
    '/business must still expose a signup path, or the CTA is sending people nowhere');
});

test('the final block closes on the owner\'s call to action', () => {
  assert.match(landing, /Give your customers a reason to come back\./);
  assert.match(landing, /Get Started with Peekaa/);
});

test('the five-second message is the h1', () => {
  const h1 = /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(landing)[1].replace(/<[^>]+>/g, '').trim();
  assert.equal(h1, 'Turn customers into regulars.');
});

test('the product narrative runs in order, not as a generic feature list', () => {
  const steps = [...landing.matchAll(/<span class="step-num"><b>(\d\d)<\/b>[\s\S]*?<\/span>([^<]+)</g)]
    .map((m) => [m[1], m[2].trim()]);
  assert.deepEqual(steps, [
    ['01', 'Bring customers in'],
    ['02', 'Give them a reason to return'],
    ['03', 'Stay connected'],
    ['04', 'Know your customers'],
    ['05', 'Bring inactive customers back']
  ]);
});

test('the business-category strip is present', () => {
  assert.match(landing, /Wherever repeat customers matter/);
  for (const category of ['Cafés', 'Restaurants', 'Beauty', 'Fitness', 'Retail', 'Services']) {
    assert.ok(landing.includes(category), `the categories strip should mention ${category}`);
  }
});

test('the page tells the reader the product screens are illustrations', () => {
  assert.match(landing, /[Ii]llustrations? of the Peekaa/,
    'hand-built mock UI must be labelled as an illustration, not passed off as a screenshot');
});
