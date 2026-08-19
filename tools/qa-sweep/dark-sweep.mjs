/* dark-sweep — does the customer app's DARK theme actually paint dark?
 *
 * WHY THIS EXISTS
 *   Dark mode is customer-only. It is driven by Profile → Appearance, which sets
 *   html[data-customer-theme="dark"] (app.js applyCustomerThemeV190), and the whole theme is one
 *   CSS block in app/index.html that redefines a SUBSET of the :root tokens. Every wave that added
 *   a token or a component after that block was written added a light-designed value that dark
 *   never learned about — a mint success pill, a cream gold wash, a white switch knob — and those
 *   land on a #191C22 card. A source grep cannot see any of that: the failure is a COMPUTED colour,
 *   produced by the cascade, on an element that is on screen. So this sweep measures pixels-worth
 *   of computed style, not source text.
 *
 * WHAT IT MEASURES (per route, at 390x844, with dark forced the way the app forces it)
 *   1. CONTRAST. For every visible element that owns a non-empty text node: the rendered
 *      foreground colour composited over its EFFECTIVE background — found by walking ancestors to
 *      the first opaque paint, compositing every translucent layer on the way, and treating a
 *      gradient as its darkest AND lightest stop so the reported ratio is the worst case.
 *      Threshold: WCAG AA — 4.5:1 body text, 3:1 large text (>=24px, or >=18.66px at weight >=700).
 *   2. NON-TEXT COMPONENTS. Pills, chips, dots, tracks, switch knobs and progress fills are judged
 *      at 3:1 against their own surroundings (WCAG 1.4.11), because a stamp dot carries meaning
 *      through colour alone.
 *   3. LIGHT-THEME LEAKAGE. Any element whose OWN background computes to a near-white value
 *      (relative luminance > 0.8) while the surface behind it is dark (luminance < 0.25). This is
 *      the specific failure mode of an un-darkened token: --gold-bg #FFF3D6 or --success-bg
 *      #E7F6EE painted onto a dark card. A near-white plate is not automatically wrong (a QR must
 *      be scannable, a merchant logo needs its own ground) so a short, reasoned allowlist exists.
 *
 * WHAT GATES
 *   Every run measures BOTH themes, because the two are not independent: the customer app carries
 *   contrast debt in its shared design (a #C24135 nav label on a #F7DCD7 pill is 3.94:1 in LIGHT),
 *   and a dark-mode task that "fixed" those would be an unmeasured change to every customer's
 *   screen. So a finding on a node that ALSO fails in light is reported as shared debt and does not
 *   gate; the gate is the dark-only set, which must be empty. Nodes are matched across the two runs
 *   by child-index path — same routes, same fixtures, same tree.
 *
 * USAGE
 *   node tools/qa-sweep/dark-sweep.mjs [--root <repo root>] [--port 4193]
 *                                      [--theme dark|light] [--shots <dir>] [--json <file>]
 *                                      [--tag before|after] [--report]
 *   PLAYWRIGHT_MODULE=/abs/path/to/playwright-core/index.js   (optional; defaults to 'playwright')
 *
 *   --theme pins the run to ONE theme (no light comparison, so everything gates).
 *   --report prints every finding including the shared-with-light set, and always exits 0.
 *
 * Screenshots land in tools/qa-sweep/shots/dark/ (or --shots), named <tag>-<theme>-<route>.png.
 */
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback;
};
const flag = (name) => argv.includes(`--${name}`);

const ROOT = resolve(arg('root', resolve(HERE, '..', '..')));
const PORT = Number(arg('port', '4193'));
/* Both themes by default — the light pass is what tells a dark defect apart from shared debt. */
const ONLY = ['dark', 'light'].includes(String(arg('theme', '')).toLowerCase()) ? String(arg('theme', '')).toLowerCase() : 'both';
const TAG = arg('tag', 'run');
const SHOTS = resolve(arg('shots', join(ROOT, 'tools/qa-sweep/shots/dark')));
const JSON_OUT = resolve(arg('json', join(ROOT, 'tools/qa-sweep/dark-results.json')));
const REPORT = flag('report');

const ROUTES = [
  '#/wallet',
  '#/wallet/qa-cafe',
  '#/customer/programmes',
  '#/customer/bookings',
  '#/customer/messages',
  '#/customer/profile',
];

const playwrightModule = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwrightModule.chromium || playwrightModule.default?.chromium;
if (!chromium) throw new Error('playwright: no chromium export (set PLAYWRIGHT_MODULE to a playwright/playwright-core entry point)');

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

/* ----------------------------------------------------------- the merchant-page override -----
   sb-double.js has no fixture for customer_get_actionable_business / customer_portal_capabilities,
   so #/wallet/<slug> falls to renderCustomerNotJoinedV289 — an empty state that never paints the
   red hero, and the hero is exactly where the gold tier pill, the progress track and the stamp
   dots live. These four readers (shapes lifted from sync-sweep, which lifted them from the
   migrations) put the joined merchant page on screen so it can be measured. */
const OVERRIDE = `(function(){
  'use strict';
  var BIZ='10000000-0000-4000-8000-000000000001';
  function chainable(data){
    var payload={data:data,error:null,count:Array.isArray(data)?data.length:null,status:200};
    var proxy=new Proxy({},{get:function(_t,prop){
      if(prop==='then')return function(res,rej){return Promise.resolve(payload).then(res,rej)};
      if(prop==='catch')return function(rej){return Promise.resolve(payload).catch(rej)};
      if(prop==='finally')return function(f){return Promise.resolve(payload).finally(f)};
      return function(){return proxy};
    }});
    return proxy;
  }
  function card(){
    return {business:{slug:'qa-cafe',name:'QA Test Cafe',industry:'fnb',currency:'SGD'},logo_url:'',
      loyalty:{enabled:true,model:'redeem',unit:'points',balance:320},
      credit:{balance_cents:0},packages:{sessions_remaining:3},
      expiry:{mode:'rolling',expiring_within_7_days:40,expiring_units:40,next_expiry_at:'2026-08-24T02:00:00Z'},
      next_eligible_reward:{name:'Free flat white',cost_units:400,remaining_units:80,available_now:false},
      visits_remaining:2,visit_progress:null,
      action:{reason:'close_to_reward',deadline_at:null,sort_band:2,sort_units:80},
      birthday_benefit:null,
      programmes:[{kind:'points',active:true,customer_visible:true},
                  {kind:'tiers',active:true,customer_visible:true},
                  {kind:'referral',active:true,customer_visible:true}]};
  }
  var EXTRA={
    customer_get_actionable_business:function(){return {card:card()}},
    customer_portal_capabilities:function(){return {
      programmes:[{kind:'points',active:true,customer_visible:true},
                  {kind:'tiers',active:true,customer_visible:true},
                  {kind:'referral',active:true,customer_visible:true}],
      programmes_contract:'v310',rewards:true,activity:true,appointments:true,
      booking_request:true,redemption:true}},
    customer_get_effective_tier_v143:function(){return {tier:{}}},
    customer_get_business_presentation_v95:function(){return {name:'QA Test Cafe',unit:'points',
      logo_url:'',hero_image_url:'',offers:[],rewards:[],products:[],services:[],benefits:[]}}
  };
  var baseCreate=window.supabase.createClient;
  window.supabase.createClient=function(){
    var client=baseCreate.apply(this,arguments);
    var baseRpc=client.rpc.bind(client);
    client.rpc=function(name,params){
      if(Object.prototype.hasOwnProperty.call(EXTRA,name))return chainable(EXTRA[name](params));
      return baseRpc(name,params);
    };
    return client;
  };
})();`;

const server = createServer(async (req, res) => {
  try {
    const p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    if (p === '/sb-double.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js')));
    }
    if (p === '/dark-override.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(OVERRIDE);
    }
    const file = join(ROOT, p === '/' ? '/app/index.html' : (p.startsWith('/app/') ? p : '/app' + p));
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end('nf'); }
});

/* ------------------------------------------------------------------ the in-page auditor -----
   Everything below runs inside the page. It is written as one self-contained function so the
   whole measurement is a single evaluate() per route. */
const AUDIT = function auditContrast(opts) {
  const AA_BODY = 4.5, AA_LARGE = 3, AA_NONTEXT = 3;
  const NEAR_WHITE = 0.8;      /* relative luminance above which a plate reads as a light-theme leak */
  const DARK_GROUND = 0.25;    /* below which the surface behind it is a dark surface */

  /* Deliberate light plates. Each is a design decision recorded where it was made, not a waiver
     of convenience — a QR that is not on white does not scan, and a merchant's own logo needs a
     neutral ground in either theme. */
  const LIGHT_BY_DESIGN = [
    ['.redemption-qr', 'a scan target must stay a light scan surface (index.html: color-scheme:light)'],
    ['.customer-merchant-hero .customer-programme-logo', 'merchant logo plate — kept white in dark on purpose'],
    ['.customer-scan-modal', 'the scan sheet is a deliberate light sheet'],
    ['[data-dark-light-by-design]', 'explicitly opted out in markup'],
  ];

  const parseColor = (str) => {
    if (!str || str === 'transparent' || str === 'none') return { r: 0, g: 0, b: 0, a: 0 };
    const m = String(str).match(/rgba?\(([^)]+)\)/);
    if (!m) return { r: 0, g: 0, b: 0, a: 0 };
    const parts = m[1].split(/[,/]/).map((s) => s.trim());
    const num = (s) => (s.endsWith('%') ? parseFloat(s) * 2.55 : parseFloat(s));
    return {
      r: num(parts[0]) || 0, g: num(parts[1]) || 0, b: num(parts[2]) || 0,
      a: parts[3] === undefined ? 1 : (parts[3].endsWith('%') ? parseFloat(parts[3]) / 100 : parseFloat(parts[3])),
    };
  };
  /* color-mix()/gradients arrive already resolved to rgb() in getComputedStyle, so pulling every
     rgb token out of a background-image gives the real stops. */
  const gradientStops = (bgImage) => {
    if (!bgImage || bgImage === 'none') return [];
    if (!/gradient\(/.test(bgImage)) return [];
    const found = String(bgImage).match(/rgba?\([^)]+\)/g) || [];
    return found.map(parseColor).filter((c) => c.a > 0);
  };
  const over = (fg, bg) => {
    const a = fg.a + bg.a * (1 - fg.a);
    if (a === 0) return { r: 0, g: 0, b: 0, a: 0 };
    return {
      r: (fg.r * fg.a + bg.r * bg.a * (1 - fg.a)) / a,
      g: (fg.g * fg.a + bg.g * bg.a * (1 - fg.a)) / a,
      b: (fg.b * fg.a + bg.b * bg.a * (1 - fg.a)) / a,
      a,
    };
  };
  const lum = (c) => {
    const ch = (v) => { const s = v / 255; return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4); };
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  };
  const ratio = (a, b) => { const l1 = lum(a), l2 = lum(b); const hi = Math.max(l1, l2), lo = Math.min(l1, l2); return (hi + 0.05) / (lo + 0.05); };
  const hex = (c) => '#' + [c.r, c.g, c.b].map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('')
    + (c.a < 0.999 ? `@${c.a.toFixed(2)}` : '');

  /* The paint stack above an element: element-first, stopping at the first fully opaque layer.
     A layer that is a gradient contributes two candidates (its darkest and its lightest stop), so
     the caller can compute the worst-case ratio rather than an average that hides a failure. */
  const paintStack = (start, includeSelf) => {
    const layers = [];
    for (let n = includeSelf ? start : start.parentElement; n && n.nodeType === 1; n = n.parentElement) {
      const cs = getComputedStyle(n);
      const stops = gradientStops(cs.backgroundImage);
      if (stops.length) {
        let dark = stops[0], light = stops[0];
        for (const s of stops) { if (lum(s) < lum(dark)) dark = s; if (lum(s) > lum(light)) light = s; }
        layers.push({ dark, light });
        if (stops.every((s) => s.a >= 0.99)) return layers;
      }
      const bg = parseColor(cs.backgroundColor);
      if (bg.a > 0) {
        layers.push({ dark: bg, light: bg });
        if (bg.a >= 0.999) return layers;
      }
    }
    return layers;
  };
  /* Composite bottom-up. `pick` chooses which side of every gradient to take, so 'dark' and
     'light' bracket the real painted range. */
  const composite = (layers, pick) => {
    const base = { r: 255, g: 255, b: 255, a: 1 };
    let out = base;
    for (let i = layers.length - 1; i >= 0; i--) out = over(layers[i][pick], out);
    return out;
  };
  const effectiveBg = (el, includeSelf) => {
    const layers = paintStack(el, includeSelf);
    if (!layers.length) return { dark: { r: 255, g: 255, b: 255, a: 1 }, light: { r: 255, g: 255, b: 255, a: 1 }, layers: 0 };
    return { dark: composite(layers, 'dark'), light: composite(layers, 'light'), layers: layers.length };
  };

  const cumulativeOpacity = (el) => {
    let o = 1;
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const v = parseFloat(getComputedStyle(n).opacity);
      if (!Number.isNaN(v)) o *= v;
      if (o < 0.02) break;
    }
    return o;
  };

  const isVisible = (el) => {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    if (parseFloat(cs.opacity) < 0.05) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    if (r.bottom < -400 || r.top > (document.documentElement.scrollHeight + 400)) return false;
    if (el.closest('.sr-only,[hidden],[aria-hidden="true"]')) return false;
    return true;
  };

  const describe = (el) => {
    const cls = String(el.className && el.className.baseVal !== undefined ? el.className.baseVal : el.className || '')
      .trim().split(/\s+/).filter(Boolean).slice(0, 4).join('.');
    return el.tagName.toLowerCase() + (el.id ? `#${el.id}` : '') + (cls ? `.${cls}` : '');
  };
  /* A stable identity for the SAME element across two theme runs: the routes and fixtures are
     identical, so the child-index chain matches. This is what lets the gate separate a defect dark
     introduced from contrast debt light already carried. */
  const pathOf = (el) => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
      let i = 1;
      for (let s = n.previousElementSibling; s; s = s.previousElementSibling) i++;
      parts.unshift(`${n.tagName.toLowerCase()}:${i}`);
      if (parts.length > 22) break;
    }
    return parts.join('/');
  };
  const byDesign = (el) => {
    for (const [sel, why] of LIGHT_BY_DESIGN) { try { if (el.closest(sel)) return why; } catch { /* bad selector */ } }
    return null;
  };

  const root = document.querySelector('.customer-surface') || document.body;
  const scope = [root, ...root.querySelectorAll('*')];
  const findings = [];
  const seen = new Set();
  const push = (f) => {
    const key = `${f.kind}|${f.route}|${f.path}|${f.fg}|${f.bg}`;
    if (seen.has(key)) return;
    seen.add(key); findings.push(f);
  };

  /* ---- 1 + 2: contrast -------------------------------------------------------------------- */
  const NONTEXT = '.cui-stamp-dots-v2b i,.cui-progress-track-v2b,.cui-progress-track-v2b i,.cui-switch i,.cui-switch i::before,.pill,.chip,.customer-offer-new,.customer-home-offer-countdown,.customer-business-tier-pill-v347,.customer-reward-progress-pill-v340,.customer-home-ready-gift-v343,.customer-rewards-filter-chips-v344 span,.setup-step-token-v2c,.fb-chip,.customer-claimable-banner-v337,.customer-claimable-strip';
  const nonTextSet = new Set(root.querySelectorAll(NONTEXT));

  for (const el of scope) {
    if (!isVisible(el)) continue;
    const cs = getComputedStyle(el);
    const bg = effectiveBg(el, false);
    const ownBgColor = parseColor(cs.backgroundColor);
    const ownStops = gradientStops(cs.backgroundImage);

    /* --- text --- */
    const ownText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 1);
    if (ownText) {
      const selfBg = effectiveBg(el, true);
      const fgRaw = parseColor(cs.color);
      const op = cumulativeOpacity(el);
      const fg = { ...fgRaw, a: fgRaw.a * op };
      const size = parseFloat(cs.fontSize) || 14;
      const weight = parseInt(cs.fontWeight, 10) || 400;
      const large = size >= 24 || (size >= 18.66 && weight >= 700);
      const need = large ? AA_LARGE : AA_BODY;
      let worst = Infinity, worstBg = null;
      for (const pick of ['dark', 'light']) {
        const b = selfBg[pick];
        const r = ratio(over(fg, b), b);
        if (r < worst) { worst = r; worstBg = b; }
      }
      if (worst < need - 0.005) {
        push({
          kind: 'text', route: opts.route, sel: describe(el), path: pathOf(el),
          text: (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 48),
          fg: hex(fgRaw), bg: hex(worstBg), ratio: Math.round(worst * 100) / 100, need,
          size: Math.round(size * 10) / 10, weight,
        });
      }
    }

    /* --- non-text component: its own fill against what surrounds it --- */
    if (nonTextSet.has(el)) {
      let fill = null;
      if (ownStops.length) { let d = ownStops[0]; for (const s of ownStops) if (lum(s) > lum(d)) d = s; fill = d; }
      else if (ownBgColor.a > 0.05) fill = ownBgColor;
      /* A borders-only component (an unfilled stamp dot) carries its meaning in the border. */
      const bw = parseFloat(cs.borderTopWidth) || 0;
      const bc = parseColor(cs.borderTopColor);
      if (!fill && bw > 0 && bc.a > 0.05) fill = bc;
      if (fill) {
        let worst = Infinity, worstBg = null;
        for (const pick of ['dark', 'light']) {
          const b = bg[pick];
          const r = ratio(over(fill, b), b);
          if (r < worst) { worst = r; worstBg = b; }
        }
        if (worst < AA_NONTEXT - 0.005) {
          push({
            kind: 'component', route: opts.route, sel: describe(el), path: pathOf(el),
            text: '', fg: hex(fill), bg: hex(worstBg),
            ratio: Math.round(worst * 100) / 100, need: AA_NONTEXT,
          });
        }
      }
    }

    /* ---- 3: a light-theme plate on a dark ground ----------------------------------------- */
    if (opts.theme === 'dark') {
      let plate = null;
      if (ownBgColor.a > 0.5) plate = ownBgColor;
      else if (ownStops.length && ownStops.every((s) => s.a > 0.5)) {
        let d = ownStops[0]; for (const s of ownStops) if (lum(s) < lum(d)) d = s; plate = d;   /* darkest stop: a leak only if even the darkest end is near-white */
      }
      if (plate && lum(plate) > NEAR_WHITE) {
        const behind = bg.dark;
        /* "Dark surface" means a dark NEUTRAL — the theme's own ground. A deeply saturated brand
           plate (the red hero) is also low-luminance, but a cream chip on it is a deliberate
           accent that reads identically in both themes, so it is not a dark-mode defect. */
        const chroma = Math.max(behind.r, behind.g, behind.b) - Math.min(behind.r, behind.g, behind.b);
        if (lum(behind) < DARK_GROUND && chroma < 40) {
          const why = byDesign(el);
          if (!why) {
            push({
              kind: 'light-leak', route: opts.route, sel: describe(el), path: pathOf(el),
              text: (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40),
              fg: hex(plate), bg: hex(behind),
              ratio: Math.round(lum(plate) * 1000) / 1000, need: NEAR_WHITE,
            });
          }
        }
      }
    }
  }

  /* Token read-out: which of the 76 :root tokens actually change value under dark, measured on a
     real customer element rather than assumed from the source. */
  const probe = root;
  const cs = getComputedStyle(probe);
  const TOKENS = opts.tokens || [];
  const tokens = {};
  for (const t of TOKENS) tokens[t] = cs.getPropertyValue(t).trim();

  return { findings, tokens, elements: scope.length, themeAttr: document.documentElement.getAttribute('data-customer-theme') };
};

/* --------------------------------------------------------------------------------- driver --- */
const TOKEN_NAMES = [
  '--bg', '--card', '--ink', '--ink2', '--muted', '--line', '--control-border', '--hair',
  '--coral', '--coral-hover', '--red', '--tint', '--grad',
  '--success', '--success-bg', '--danger', '--danger-bg', '--warn', '--warn-bg', '--neutral-bg',
  '--gold', '--gold-bg', '--amber', '--green',
  '--brand-red', '--brand-red-dark', '--brand-red-soft', '--brand-red-faint',
  '--brand-red-on-dark', '--brand-red-on-dark-2',
  '--bg-cust', '--shell', '--appbar-bg', '--head-tint',
  '--peekaa-bg', '--peekaa-card', '--peekaa-white', '--peekaa-text', '--peekaa-text-secondary',
  '--peekaa-text-muted', '--peekaa-border', '--peekaa-divider', '--peekaa-success',
  '--peekaa-success-bg', '--peekaa-gold', '--peekaa-gold-bg', '--peekaa-red', '--peekaa-red-dark',
  '--peekaa-red-soft', '--peekaa-red-faint',
  '--shadow', '--shadow-lg', '--shadow-warm', '--shadow-warm-lg', '--glow-brand',
];

await mkdir(SHOTS, { recursive: true });
await new Promise((r) => server.listen(PORT, '127.0.0.1', r));

const CHROME = process.env.PLAYWRIGHT_CHROMIUM || arg('chrome', '');
const browser = await chromium.launch({ headless: true, ...(CHROME ? { executablePath: CHROME } : {}) });
const pageErrors = [];

/* One pass over every route in one theme. The theme is forced the way the app forces it: the
   stored preference is the authority and applyCustomerThemeV190 stamps the attribute off it at
   boot, so the preference is planted before boot AND the attribute is re-stamped after the route
   renders (the pre-boot skeleton paints before app.js runs, and a route can land before the
   preference is read). */
async function sweepTheme(theme, tag) {
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
    colorScheme: theme === 'dark' ? 'dark' : 'light',
  });
  await ctx.addInitScript((t) => {
    try { localStorage.setItem('peekaa.customer.theme', t); } catch { /* ignore */ }
    const stamp = () => {
      const el = document.documentElement;
      if (!el) return;
      if (t === 'dark') el.setAttribute('data-customer-theme', 'dark');
      else el.removeAttribute('data-customer-theme');
    };
    stamp();
    document.addEventListener('DOMContentLoaded', stamp);
  }, theme);

  const page = await ctx.newPage();
  page.on('pageerror', (e) => pageErrors.push(`${theme}: ${String(e.message).slice(0, 160)}`));
  await page.route(/127\.0\.0\.1:\d+\/(#.*)?$|index\.html/, async (r) => {
    const resp = await r.fetch();
    let html = await resp.text();
    html = html.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/,
      '<script src="/sb-double.js"></script><script src="/dark-override.js"></script>');
    await r.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.route('**/fonts.googleapis.com/**', (r) => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  await page.route('**/fonts.gstatic.com/**', (r) => r.abort());

  const findings = [];
  let tokens = null, themeAttr = null;
  console.log(`\n[${theme}]`);
  for (const route of ROUTES) {
    await page.goto(`http://127.0.0.1:${PORT}/${route}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(1800);
    await page.evaluate((t) => {
      if (t === 'dark') document.documentElement.setAttribute('data-customer-theme', 'dark');
      else document.documentElement.removeAttribute('data-customer-theme');
    }, theme);
    await page.waitForTimeout(250);

    const slug = route.replace(/^#\//, '').replace(/\//g, '-') || 'root';
    if (SHOT_ROUTES.has(route)) {
      await page.screenshot({ path: join(SHOTS, `${tag}-${theme}-${slug}.png`), fullPage: true }).catch(() => {});
    }
    const res = await page.evaluate(AUDIT, { route, theme, tokens: TOKEN_NAMES });
    if (!tokens) { tokens = res.tokens; themeAttr = res.themeAttr; }
    findings.push(...res.findings);
    process.stdout.write(`  ${route.padEnd(24)} ${String(res.elements).padStart(5)} elements  ${String(res.findings.length).padStart(4)} findings\n`);
  }
  await ctx.close();
  return { theme, findings, tokens, themeAttr };
}

const SHOT_ROUTES = new Set(['#/wallet', '#/wallet/qa-cafe']);
let light = null, dark = null;
try {
  if (ONLY !== 'dark') light = await sweepTheme('light', TAG);
  if (ONLY !== 'light') dark = await sweepTheme('dark', TAG);
} finally {
  await browser.close();
  server.close();
}

/* The element, not its colour: the two theme runs render the same fixtures on the same routes, so
   the child-index path identifies the same node in both. A node that already failed in LIGHT is
   pre-existing contrast debt in the shared design, not something dark broke — it is reported, but
   it does not gate, because this task is dark mode and silently "fixing" light here would be an
   unmeasured change to every customer's screen. */
const key = (f) => `${f.kind}|${f.route}|${f.path}`;
const lightKeys = new Set((light?.findings ?? []).map(key));
const darkFindings = dark?.findings ?? [];
const darkOnly = light ? darkFindings.filter((f) => !lightKeys.has(key(f))) : darkFindings;
const shared = light ? darkFindings.filter((f) => lightKeys.has(key(f))) : [];

const fmt = (f) => (f.kind === 'light-leak'
  ? `LEAK  lum ${f.ratio}  plate ${f.fg} on ${f.bg}`
  : `${f.kind === 'text' ? 'TEXT' : 'COMP'}  ${f.ratio}:1 (need ${f.need})  ${f.fg} on ${f.bg}`);
const dump = (list, limit) => {
  const sorted = [...list].sort((a, b) => a.ratio - b.ratio);
  const show = (REPORT || !limit) ? sorted : sorted.slice(0, limit);
  for (const f of show) console.log(`  ${fmt(f)}\n        ${f.route}  ${f.sel}${f.text ? `  "${f.text}"` : ''}`);
  if (sorted.length > show.length) console.log(`  … and ${sorted.length - show.length} more (rerun with --report)`);
};

const count = (list, k) => list.filter((f) => f.kind === k).length;
console.log(`\n${'='.repeat(78)}`);
if (light) console.log(`light: ${light.findings.length} findings  (text ${count(light.findings, 'text')} / component ${count(light.findings, 'component')})`);
if (dark) {
  console.log(`dark:  ${darkFindings.length} findings  (text ${count(darkFindings, 'text')} / component ${count(darkFindings, 'component')} / light-theme leaks ${count(darkFindings, 'light-leak')})`);
  console.log(`       ${shared.length} of those also fail in light (pre-existing design debt, not gated)`);
  console.log(`\nDARK-ONLY (gated): ${darkOnly.length}`);
  dump(darkOnly, 40);
  if (REPORT && shared.length) { console.log(`\nSHARED WITH LIGHT (informational):`); dump(shared, 0); }
}

await writeFile(JSON_OUT, JSON.stringify({
  tag: TAG, routes: ROUTES, shots: SHOTS,
  totals: {
    light: light?.findings.length ?? null,
    dark: darkFindings.length,
    darkOnly: darkOnly.length,
    sharedWithLight: shared.length,
    leak: count(darkFindings, 'light-leak'),
  },
  darkTokens: dark?.tokens ?? {}, lightTokens: light?.tokens ?? {},
  themeAttr: dark?.themeAttr ?? null,
  pageErrors,
  darkOnly: [...darkOnly].sort((a, b) => a.ratio - b.ratio),
  sharedWithLight: [...shared].sort((a, b) => a.ratio - b.ratio),
  lightFindings: [...(light?.findings ?? [])].sort((a, b) => a.ratio - b.ratio),
}, null, 2));

console.log(`\nscreenshots: ${SHOTS}`);
console.log(`results:     ${JSON_OUT}`);
if (pageErrors.length) console.log(`page errors: ${pageErrors.join(' | ')}`);

if (REPORT) process.exit(0);
if (pageErrors.length) { console.error(`\nFAILED — uncaught page errors.`); process.exit(1); }
if (darkOnly.length) { console.error(`\nFAILED — ${darkOnly.length} dark-only findings.`); process.exit(1); }
console.log(`\nPASS — dark introduces no contrast failure and no light-theme leak that light does not already have.`);
