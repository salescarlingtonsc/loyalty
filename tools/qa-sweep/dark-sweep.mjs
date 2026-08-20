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
 *   2. NON-TEXT COMPONENTS. Judged at 3:1 against their surroundings (WCAG 1.4.11) — but only the
 *      parts that carry state by FILL ALONE: stamp dots, the progress fill, the switch track. See
 *      "THE 1.4.11 RULE" below for why the pills and chips are deliberately not in that set.
 *   3. LIGHT-THEME LEAKAGE. Any element whose OWN background computes to a near-white value
 *      (relative luminance > 0.8) while the surface behind it is dark (luminance < 0.25). This is
 *      the specific failure mode of an un-darkened token: --gold-bg #FFF3D6 or --success-bg
 *      #E7F6EE painted onto a dark card. A near-white plate is not automatically wrong (a QR must
 *      be scannable, a merchant logo needs its own ground) so a short, reasoned allowlist exists.
 *
 * HOW A PIXEL IS COMPUTED (corrected 2026-08-20 — the previous model was wrong)
 *   `opacity` does not fade a colour, it fades a GROUP. The element and its whole subtree are
 *   rendered, flattened, and only then composited at that alpha over what is behind the group. So a
 *   disabled `.btn` at opacity:.48 fades its white label AND the red fill painted under the label,
 *   together — the contrast between the two barely moves. This file used to dim only the text and
 *   then compare it against the UNDIMMED fill, which invents failures that are not on screen: it
 *   reported #FFFFFF on #C24135 at 2.28:1 when that pair is 5.12:1, purely because
 *   `.btn[disabled]{opacity:.48}` was in the chain. Worse, it printed the DECLARED colour as `fg`
 *   while computing with a dimmed one, so no reader could reproduce the number and check it.
 *   Now: one walk to the root caches every ancestor's own background layer and opacity, and
 *   `flatten()` replays the real compositing twice per element — once seeded with the text colour,
 *   once seeded with nothing — so the reported `fg` and `bg` are the two PAINTED pixels, both
 *   opaque, and `ratio` is reproducible from them by anyone with the WCAG formula. `fgSrc`/`bgBy`
 *   keep the declared colour and the element that painted the ground, for debugging.
 *
 * WHAT IS EXEMPT
 *   WCAG 1.4.3 and 1.4.11 both exempt INACTIVE user-interface components ("incidental ... text
 *   that is part of an inactive user interface component ... has no contrast requirement"). A
 *   disabled control is low-contrast on purpose — that dimming is how the user is told it cannot
 *   be used — so anything inside [disabled] / :disabled / [aria-disabled=true] / [inert] is
 *   skipped rather than reported as debt nobody can act on.
 *
 * THE 1.4.11 RULE (tightened 2026-08-20)
 *   1.4.11 asks for 3:1 on "visual information required to identify user-interface components and
 *   states" — not on every coloured rectangle. A chip whose fill is pale but whose LABEL is legible
 *   is not a 1.4.11 failure: the state is in the words. The old selector list swept in .pill,
 *   .chip, the "New" badge, the countdown chip, the filter chips, the tier pill and the claimable
 *   banner — every one of them text-bearing — and demanded 3:1 from decorative fills. Sixteen
 *   findings, thirteen of them noise, three of them the same element measured against itself.
 *   The set is now the parts whose state genuinely has no other carrier, and each is still waived
 *   when something else supplies the required information:
 *     · text inside it        → the label identifies the state; the fill is decoration.
 *     · fill === ground       → the two resolve to the identical painted value, so the number is a
 *                               fixed 1.00 that says nothing about a boundary (this is what the
 *                               three `fg === bg` records were).
 *     · a border >= 3:1       → the border IS the required visual boundary; 1.4.11 is satisfied.
 *     · a legible state pair  → for stamp dots the information required is "which are filled", so
 *                               the adjacency that matters is ON-dot vs OFF-dot. If those two are
 *                               >= 3:1 apart the row can be read, and the OFF dot's edge against
 *                               the card is decoration.
 *   The progress FILL is still measured against its own track (its parent), which is the adjacency
 *   that carries the value; the track itself is not a state.
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

  const WHITE = { r: 255, g: 255, b: 255, a: 1 };
  const TRANSPARENT = { r: 0, g: 0, b: 0, a: 0 };

  /* The single background layer an element paints itself. A gradient contributes two candidates —
     its darkest and its lightest stop — so the caller can bracket the real painted range instead
     of averaging a failure away. A translucent gradient still sits ON the element's own
     background-color, so the two are composited rather than treated as alternatives. */
  const ownLayer = (cs, pick) => {
    const bg = parseColor(cs.backgroundColor);
    const stops = gradientStops(cs.backgroundImage);
    if (!stops.length) return bg;
    let d = stops[0], l = stops[0];
    for (const s of stops) { if (lum(s) < lum(d)) d = s; if (lum(s) > lum(l)) l = s; }
    const g = pick === 'dark' ? d : l;
    return g.a >= 0.999 ? g : over(g, bg);
  };

  /* One walk to the root, caching everything a composite needs: each ancestor's own paint and its
     opacity. Element-first. */
  const chainOf = (el) => {
    const chain = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const cs = getComputedStyle(n);
      const o = parseFloat(cs.opacity);
      chain.push({ node: n, dark: ownLayer(cs, 'dark'), light: ownLayer(cs, 'light'), op: Number.isNaN(o) ? 1 : o });
    }
    return chain;
  };

  /* Replay what the compositor actually does. Seed the accumulator with whatever is on top (the
     text colour, or nothing at all for the bare background), then walk outwards: at each ancestor
     drop that ancestor's own background UNDER what we have, then multiply the WHOLE accumulated
     group by that ancestor's opacity — because opacity applies to the group, not to a colour.
     Both the text pixel and the background pixel come out of this same walk, so whatever a group
     opacity does, it does to both. The page canvas is white underneath everything. */
  const flatten = (chain, seed, pick) => {
    let acc = seed;
    for (const step of chain) {
      const layer = step[pick];
      if (layer.a > 0) acc = over(acc, layer);
      if (step.op < 1) acc = { r: acc.r, g: acc.g, b: acc.b, a: acc.a * step.op };
    }
    /* Quantise to 8-bit at the end. The compositor writes integer channels, and — just as
       importantly — it makes every reported number REPRODUCIBLE: `ratio` is then exactly what the
       WCAG formula gives for the `fg` and `bg` hexes printed beside it, so a reader can check this
       tool instead of trusting it. Rounding after the fact left ratios ~0.02 off their own hexes. */
    const out = over(acc, WHITE);
    const q = (v) => Math.round(Math.max(0, Math.min(255, v)));
    return { r: q(out.r), g: q(out.g), b: q(out.b), a: 1 };
  };
  /* Which element actually painted the ground behind this one — reported so a finding names a
     fixable selector rather than an anonymous colour. */
  const groundNode = (chain) => {
    for (const step of chain) if (step.light.a > 0.02 || step.dark.a > 0.02) return step.node;
    return null;
  };

  /* WCAG 1.4.3 and 1.4.11 both exempt INACTIVE user-interface components. A disabled control is
     deliberately dimmed — that dimming is the affordance — so its contrast is not a defect and
     "fixing" it would make a dead control look live. */
  const inactive = (el) => {
    try { return !!el.closest('[disabled],:disabled,[aria-disabled="true"],[inert]'); }
    catch { return false; }
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
  /* Parts whose state has no carrier but their fill. Everything the old list also held — .pill,
     .chip, the "New" badge, the countdown chip, the filter chips, the tier pill, the claimable
     banner, the setup token — carries its own text, and 1.4.11 does not ask for a boundary around
     a component whose state is spelled out in words. See "THE 1.4.11 RULE" at the top. */
  const STATE_BY_FILL = '.cui-stamp-dots-v2b i,.cui-progress-track-v2b i,.cui-switch i';
  const stateByFill = new Set(root.querySelectorAll(STATE_BY_FILL));

  const paintedFill = (chain, pick) => flatten(chain, TRANSPARENT, pick);
  /* The four reasons a state-bearing part still does not need 3:1 of its own. */
  const componentWaiver = (el, chain, parentChain, fill, ground) => {
    if ((el.textContent || '').trim()) return 'state is carried by the label, not the fill';
    if (hex(fill) === hex(ground)) return 'fill and ground resolve to the identical painted value — a fixed 1.00 that measures nothing';
    const cs = getComputedStyle(el);
    const bw = parseFloat(cs.borderTopWidth) || 0;
    const bc = parseColor(cs.borderTopColor);
    if (bw > 0 && bc.a > 0.05) {
      let best = 0;
      for (const pick of ['dark', 'light']) {
        const g = flatten(parentChain, TRANSPARENT, pick);
        best = Math.max(best, ratio(over(bc, g), g));
      }
      if (best >= AA_NONTEXT - 0.005) return `the border is the visual boundary (${Math.round(best * 100) / 100}:1)`;
    }
    /* An INSET ring drawn with box-shadow is the same visual boundary as a border, and is what a
       control uses when a real border would move its geometry (the switch track's knob is
       positioned against the padding box). Judge it exactly as a border: the ring colour against
       the ground behind the control, needing the same 3:1. Only inset shadows count — an outer
       glow sits beside the control, not around its edge. */
    const shadow = cs.boxShadow || '';
    if (shadow.includes('inset')) {
      const ringColor = shadow.match(/(rgba?\([^)]+\)|#[0-9a-f]{3,8})(?=[^,]*inset)|inset[^,]*?(rgba?\([^)]+\)|#[0-9a-f]{3,8})/i);
      const raw = ringColor && (ringColor[1] || ringColor[2]);
      if (raw) {
        const rc = parseColor(raw);
        if (rc.a > 0.05) {
          let best = 0;
          for (const pick of ['dark', 'light']) {
            const g = flatten(parentChain, TRANSPARENT, pick);
            best = Math.max(best, ratio(over(rc, g), g));
          }
          if (best >= AA_NONTEXT - 0.005) return `an inset ring is the visual boundary (${Math.round(best * 100) / 100}:1)`;
        }
      }
    }
    if (el.matches('.cui-stamp-dots-v2b i') && el.parentElement) {
      const dots = [...el.parentElement.children];
      const on = dots.find((d) => d.classList.contains('on'));
      const off = dots.find((d) => !d.classList.contains('on'));
      if (on && off) {
        let best = 0;
        for (const pick of ['dark', 'light']) {
          best = Math.max(best, ratio(paintedFill(chainOf(on), pick), paintedFill(chainOf(off), pick)));
        }
        if (best >= AA_NONTEXT - 0.005) return `filled and unfilled dots are ${Math.round(best * 100) / 100}:1 apart — the row reads`;
      }
    }
    return null;
  };
  const waived = [];

  for (const el of scope) {
    if (!isVisible(el)) continue;
    const cs = getComputedStyle(el);
    const ownBgColor = parseColor(cs.backgroundColor);
    const ownStops = gradientStops(cs.backgroundImage);
    const chain = chainOf(el);
    const skipInactive = inactive(el);

    /* --- text --- */
    const ownText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 1);
    if (ownText && !skipInactive) {
      const fgDecl = parseColor(cs.color);
      const size = parseFloat(cs.fontSize) || 14;
      const weight = parseInt(cs.fontWeight, 10) || 400;
      const large = size >= 24 || (size >= 18.66 && weight >= 700);
      const need = large ? AA_LARGE : AA_BODY;
      let worst = Infinity, worstFg = null, worstBg = null;
      for (const pick of ['dark', 'light']) {
        const t = flatten(chain, fgDecl, pick);
        const b = flatten(chain, TRANSPARENT, pick);
        const r = ratio(t, b);
        if (r < worst) { worst = r; worstFg = t; worstBg = b; }
      }
      if (worst < need - 0.005) {
        const gn = groundNode(chain);
        push({
          kind: 'text', route: opts.route, sel: describe(el), path: pathOf(el),
          text: (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 48),
          fg: hex(worstFg), bg: hex(worstBg), fgSrc: hex(fgDecl),
          bgBy: gn ? describe(gn) : 'canvas',
          ratio: Math.round(worst * 100) / 100, need,
          size: Math.round(size * 10) / 10, weight, large,
        });
      }
    }

    /* --- non-text component: its own fill against what surrounds it (WCAG 1.4.11) --- */
    if (stateByFill.has(el) && !skipInactive) {
      const parentChain = chain.slice(1);
      let worst = Infinity, worstFill = null, worstGround = null;
      for (const pick of ['dark', 'light']) {
        const f = paintedFill(chain, pick);
        const g = flatten(parentChain, TRANSPARENT, pick);
        const r = ratio(f, g);
        if (r < worst) { worst = r; worstFill = f; worstGround = g; }
      }
      if (worst < AA_NONTEXT - 0.005) {
        const why = componentWaiver(el, chain, parentChain, worstFill, worstGround);
        if (why) {
          waived.push({ route: opts.route, sel: describe(el), ratio: Math.round(worst * 100) / 100, why });
        } else {
          const gn = groundNode(parentChain);
          push({
            kind: 'component', route: opts.route, sel: describe(el), path: pathOf(el),
            text: '', fg: hex(worstFill), bg: hex(worstGround),
            bgBy: gn ? describe(gn) : 'canvas',
            ratio: Math.round(worst * 100) / 100, need: AA_NONTEXT,
          });
        }
      }
    }

    /* ---- 3: a light-theme plate on a dark ground ----------------------------------------- */
    if (opts.theme === 'dark' && !skipInactive) {
      let plate = null;
      if (ownBgColor.a > 0.5) plate = ownBgColor;
      else if (ownStops.length && ownStops.every((s) => s.a > 0.5)) {
        let d = ownStops[0]; for (const s of ownStops) if (lum(s) < lum(d)) d = s; plate = d;   /* darkest stop: a leak only if even the darkest end is near-white */
      }
      /* The plate as PAINTED (group opacity included) — a white sheet dimmed to 20% is not a
         light-theme leak, it is a dim grey, and the old model could not tell the two apart. */
      if (plate) plate = flatten(chain, TRANSPARENT, 'dark');
      if (plate && lum(plate) > NEAR_WHITE) {
        const behind = flatten(chain.slice(1), TRANSPARENT, 'dark');
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

  return { findings, waived, tokens, elements: scope.length, themeAttr: document.documentElement.getAttribute('data-customer-theme') };
};

/* --------------------------------------------------------------------------------- driver --- */
const TOKEN_NAMES = [
  '--bg', '--card', '--ink', '--ink2', '--muted', '--line', '--control-border', '--hair',
  '--coral', '--coral-hover', '--red', '--tint', '--grad',
  '--success', '--success-bg', '--danger', '--danger-bg', '--warn', '--warn-bg', '--neutral-bg',
  '--gold', '--gold-bg', '--amber', '--green',
  '--brand-red', '--brand-red-dark', '--brand-red-soft', '--brand-red-faint', '--brand-red-on-soft',
  '--brand-red-on-dark', '--brand-red-on-dark-2',
  '--bg-cust', '--shell', '--appbar-bg', '--head-tint',
  '--peekaa-bg', '--peekaa-card', '--peekaa-white', '--peekaa-text', '--peekaa-text-secondary',
  '--peekaa-text-muted', '--peekaa-border', '--peekaa-divider', '--peekaa-success',
  '--peekaa-success-bg', '--peekaa-gold', '--peekaa-gold-bg', '--peekaa-red', '--peekaa-red-dark',
  '--peekaa-red-soft', '--peekaa-red-faint', '--peekaa-red-on-soft',
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
  const waived = [];
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
    waived.push(...(res.waived || []));
    process.stdout.write(`  ${route.padEnd(24)} ${String(res.elements).padStart(5)} elements  ${String(res.findings.length).padStart(4)} findings\n`);
  }
  await ctx.close();
  return { theme, findings, waived, tokens, themeAttr };
}

const SHOT_ROUTES = new Set(['#/wallet', '#/wallet/qa-cafe', '#/customer/programmes']);
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
  /* Every 1.4.11 candidate the tightened rule let go, WITH its reason — the tightening has to be
     auditable or it is just a lower number. */
  waivedComponents: { light: light?.waived ?? [], dark: dark?.waived ?? [] },
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
