/* DOM health + responsive sweep.
 *
 * The render sweep proved pages load; the click sweep proved controls respond. Neither looks at
 * the DOM the app actually produced. This does, at three viewports, and reports only defect
 * classes that are real bugs rather than style opinions:
 *
 *   DUP ID        two elements share an id — $(id) returns the first, so one of them is dead
 *   OVERFLOW      an element extends past the viewport's right edge (horizontal scroll on phone)
 *   NO NAME       a control with no text and no aria-label/title — a screen reader announces
 *                 "button", and a low-literacy user gets an unlabelled icon
 *   NO ALT        an <img> with no alt attribute at all
 *   UNLABELLED    a form field with no <label for>, no wrapping label, no aria-label
 *   H-JUMP        heading level skips (h1 -> h3), which breaks document outline navigation
 *
 * Runs against the Supabase double, same as the other sweeps.
 */
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = '/home/user/loyalty';
const PORT = 4193;
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

const VIEWPORTS = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'desktop', width: 1440, height: 900 },
];

const ROUTES = process.argv[2] ? [process.argv[2]] :
  ['dashboard','till','clients','sales','services','bookings','waitlist','appointments','inventory',
   'packages','branches','grow','loyalty','retention','promotions','referrals','memberships','reports',
   'customerintel','staffperf','staffmembers','dailyreport','pnl','expenses','setup','settings',
   /* the real customer app, now that the double fixtures its RPCs — the three
      local/customer-preview routes are a visual harness, not these screens */
   'wallet','wallet/qa-cafe','customer/programmes','customer/bookings','customer/messages',
   'customer/communications','customer/explore','customer/profile',
   'customer-interface','local/customer-preview','local/customer-preview/rewards','local/customer-preview/bookings'];

const server = createServer(async (req, res) => {
  try {
    const p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    if (p === '/sb-double.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js'))); }
    const f = join(ROOT, p === '/' ? '/app/index.html' : (p.startsWith('/app/') ? p : '/app' + p));
    const b = await readFile(f);
    res.writeHead(200, { 'content-type': MIME[extname(f)] || 'application/octet-stream' });
    res.end(b);
  } catch { res.writeHead(404); res.end('nf'); }
});

const AUDIT = () => {
  const out = { dupIds: [], overflow: [], noName: [], noAlt: [], unlabelled: [], hJump: [] };
  const desc = (el) => {
    const c = (el.className && typeof el.className === 'string') ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
    return (el.tagName.toLowerCase() + (el.id ? '#' + el.id : c)).slice(0, 60);
  };

  const seen = new Map();
  for (const el of document.querySelectorAll('[id]')) {
    if (!el.id) continue;
    seen.set(el.id, (seen.get(el.id) || 0) + 1);
  }
  for (const [id, n] of seen) if (n > 1) out.dupIds.push({ id, count: n });

  const vw = document.documentElement.clientWidth;
  const root = document.querySelector('#main, .main, main') || document.body;
  for (const el of root.querySelectorAll('*')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.position === 'fixed') continue;
    if (el.checkVisibility && !el.checkVisibility({ contentVisibilityAuto: true, visibilityProperty: true })) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.right > vw + 1.5) {
      // an element inside a deliberate horizontal scroller is fine
      let sc = el.parentElement, scrolls = false;
      while (sc && sc !== document.body) {
        const s = getComputedStyle(sc);
        if (s.overflowX === 'auto' || s.overflowX === 'scroll') { scrolls = true; break; }
        sc = sc.parentElement;
      }
      if (!scrolls) out.overflow.push({ el: desc(el), right: Math.round(r.right), vw });
    }
  }

  /* innerText is layout-dependent and returns '' for anything not currently rendered, which
     reports every collapsed nav item as unnamed. textContent is stable, checkVisibility() accounts
     for hidden ANCESTORS, and an icon-only control can still be named by an <img alt> or an
     <svg><title>, so all four sources count. */
  const visible = (el) => (el.checkVisibility
    ? el.checkVisibility({ contentVisibilityAuto: true, visibilityProperty: true })
    : getComputedStyle(el).display !== 'none');
  for (const el of document.querySelectorAll('button, [role="button"], a[href], [role="switch"], summary')) {
    if (!visible(el)) continue;
    const name = (el.getAttribute('aria-label') || '').trim()
      || (el.getAttribute('aria-labelledby') || '').trim()
      || (el.getAttribute('title') || '').trim()
      || (el.textContent || '').trim()
      || [...el.querySelectorAll('img[alt]')].map((i) => i.alt.trim()).join(' ').trim()
      || [...el.querySelectorAll('svg title, [aria-label]')].map((i) => (i.textContent || i.getAttribute('aria-label') || '').trim()).join(' ').trim();
    if (!name) out.noName.push({ el: desc(el), html: el.outerHTML.slice(0, 110) });
  }

  for (const el of document.querySelectorAll('img')) {
    if (!el.hasAttribute('alt')) out.noAlt.push({ el: desc(el), src: (el.getAttribute('src') || '').slice(0, 60) });
  }

  for (const el of document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea')) {
    if (!visible(el)) continue;
    const named = el.getAttribute('aria-label') || el.getAttribute('aria-labelledby')
      || (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`)) || el.closest('label');
    if (!named) out.unlabelled.push({ el: desc(el), type: el.getAttribute('type') || el.tagName.toLowerCase(), ph: el.getAttribute('placeholder') || '' });
  }

  let prev = 0;
  for (const h of document.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    if (!visible(h)) continue;
    const lvl = Number(h.tagName[1]);
    if (prev && lvl > prev + 1) out.hJump.push({ from: prev, to: lvl, text: (h.innerText || '').trim().slice(0, 40) });
    prev = lvl;
  }
  return out;
};

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, executablePath: CHROME });
const report = [];

for (const route of ROUTES) {
  const row = { route, viewports: {} };
  for (const vp of VIEWPORTS) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height } });
    const page = await ctx.newPage();
    await page.route(new RegExp(`${PORT}/(#.*)?$|index\\.html`), async r => {
      const rs = await r.fetch(); let h = await rs.text();
      h = h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/sb-double.js"></script>');
      await r.fulfill({ status: 200, contentType: 'text/html', body: h });
    });
    await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
    await page.goto(`http://127.0.0.1:${PORT}/#/${route}`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    await page.waitForTimeout(1400);
    row.viewports[vp.name] = await page.evaluate(AUDIT).catch(e => ({ error: String(e.message).slice(0, 120) }));
    await ctx.close();
  }
  const n = (k) => VIEWPORTS.reduce((a, v) => a + (row.viewports[v.name]?.[k]?.length || 0), 0);
  const parts = [['DUP ID','dupIds'],['OVERFLOW','overflow'],['NO NAME','noName'],['NO ALT','noAlt'],['UNLABELLED','unlabelled'],['H-JUMP','hJump']]
    .map(([lbl, k]) => n(k) ? `${lbl} ${n(k)}` : '').filter(Boolean);
  process.stdout.write(`  ${route.padEnd(32)} ${parts.length ? parts.join('  ') : 'clean'}\n`);
  report.push(row);
}

await writeFile(join(ROOT, 'tools/qa-sweep/dom-health-results.json'), JSON.stringify(report, null, 2));
console.log('\nwrote tools/qa-sweep/dom-health-results.json');
await browser.close(); server.close();
