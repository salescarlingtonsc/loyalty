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
import { existsSync } from 'node:fs';
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

test('the four rewrites are present, in the order Vercel evaluates them', () => {
  const rewrites = vercel.rewrites;
  assert.ok(Array.isArray(rewrites), 'app/vercel.json must define rewrites');

  assert.deepEqual(rewrites[0], {
    source: '/',
    has: [{ type: 'query', key: 'source', value: 'pwa' }],
    destination: '/index.html'
  }, 'installed PWAs open /?source=pwa (manifest start_url) and must still get the app');

  assert.deepEqual(rewrites[1], { source: '/', destination: '/landing.html' },
    'everyone else gets the marketing page');

  assert.deepEqual(rewrites[2], { source: '/app', destination: '/index.html' },
    '/app is the app\'s new canonical path and the target of every forward');

  const paths = rewrites.map((rule) => rule.source);
  assert.ok(paths.indexOf('/') < paths.indexOf('/app'),
    'the root rules must be evaluated before /app');
  assert.ok(
    rewrites.some((r) => r.source === '/business' && r.destination === '/index.html'),
    '/business must keep serving the app'
  );
  assert.ok(
    rewrites.some((r) => r.source === '/admin' && r.destination === '/index.html'),
    '/admin must keep serving the app'
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

test('the PWA guard is order-sensitive: the unconditional root rule cannot shadow it', () => {
  const rootRules = vercel.rewrites.filter((rule) => rule.source === '/');
  assert.equal(rootRules.length, 2, 'exactly two rules may claim "/"');
  assert.ok(Array.isArray(rootRules[0].has) && rootRules[0].has.length === 1,
    'the first "/" rule must be the conditional one');
  assert.equal(rootRules[1].has, undefined, 'the fallback "/" rule must be unconditional');
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

test('the advertised prices are the ones the product actually charges', async () => {
  const app = await read('app/app.js');
  assert.match(app, /SGD 148\/month/, 'monthly price drifted in the app');
  assert.match(app, /SGD 1,188\/year/, 'annual price drifted in the app');
  assert.match(app, /SGD 99\/month equivalent/, 'annual equivalent drifted in the app');

  assert.match(landing, /SGD 1,188/, 'the landing page must quote the real annual price');
  assert.match(landing, /SGD 148/, 'the landing page must quote the real monthly price');
  assert.match(landing, /SGD 99\/month equivalent/, 'the landing page must quote the real annual equivalent');
});

test('the landing page does not contradict the in-app per-branch pricing caveat', async () => {
  const app = await read('app/app.js');
  assert.match(app, /An extra branch is charged like another shop\./);
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
  /* app/runtime-config.js ships webPushPublicKey:"" and the campaign tool says
     "Delivery is not enabled yet" — so no send/broadcast promise may appear. */
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
  assert.match(app, /CUSTOMER_LOCALES=Object\.freeze\(\['en'\]\)/,
    'the customer surface is English-only; if that changes, the copy may be widened');

  if (/Bahasa Melayu/.test(landing)) {
    assert.match(
      landing,
      /business workspace runs in English, 中文 or Bahasa Melayu/,
      'any multilingual claim must name the business workspace as its scope'
    );
    assert.match(landing, /customer-facing side is English/i,
      'the English-only customer surface must be stated, not hidden');
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
  assert.match(landing, /<title>Peekaa — Customer loyalty and rewards platform for businesses in Singapore<\/title>/);
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
    assert.ok(rewriteSources.has(href), `${href} is not served by any rewrite in app/vercel.json`);
  }
});

test('both primary calls to action point at the firm auth surface', () => {
  const ctas = [...landing.matchAll(/<a\b[^>]*\bhref=["']\/business["'][^>]*>([\s\S]*?)<\/a>/gi)]
    .map((m) => m[1].replace(/<[^>]+>/g, '').trim());
  assert.ok(ctas.some((label) => /get started/i.test(label)), 'a "Get started" CTA must target /business');
  assert.ok(ctas.some((label) => /log in/i.test(label)), 'a "Log in" CTA must target /business');
  assert.ok(ctas.length >= 4, 'the CTA should repeat down the page, not appear once');
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
