/* Boot the REAL Peekaa app against the Supabase test double and sweep every route.
 *
 * For each route it records: console errors, uncaught page errors, whether anything rendered,
 * every interactive control found, controls with no handler, duplicate DOM ids, images that
 * failed, and elements overflowing the viewport. Screenshots go to tools/qa-sweep/shots/.
 */
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = '/home/user/loyalty';
const PORT = 4188;
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

const BUSINESS = ['dashboard','till','clients','sales','services','bookings','waitlist','appointments',
  'inventory','packages','branches','grow','grow/overview','grow/offers','grow/history','loyalty',
  'retention','promotions','studio','referrals','memberships','reports','customerintel','staffperf',
  'staffmembers','dailyreport','pnl','expenses','setup','settings','customer-interface'];
const CUSTOMER = ['local/customer-preview','local/customer-preview/rewards','local/customer-preview/bookings'];

const server = createServer(async (req, res) => {
  try {
    const p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    if (p === '/sb-double.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js')));
    }
    const file = join(ROOT, p === '/' ? '/app/index.html' : (p.startsWith('/app/') ? p : '/app' + p));
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end('nf'); }
});

const double = await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js'), 'utf8');
await mkdir(join(ROOT, 'tools/qa-sweep/shots'), { recursive: true });

async function sweep(browser, routes, label, viewport) {
  const out = [];
  for (const route of routes) {
    const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const consoleErrors = [], pageErrors = [], failedReq = [];
    page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 300)); });
    page.on('pageerror', e => pageErrors.push(String(e.message).slice(0, 300)));
    page.on('requestfailed', r => failedReq.push(`${r.url().slice(0, 90)} ${r.failure()?.errorText || ''}`));
    /* The CDN <script> carries an integrity hash, so substituting its BODY is blocked by SRI.
       Rewrite the document instead: point that tag at the locally served double. */
    await page.route(/127\.0\.0\.1:4188\/(#.*)?$|index\.html/, async r => {
      const resp = await r.fetch();
      let html = await resp.text();
      html = html.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/,
        '<script src="/sb-double.js"></script>');
      await r.fulfill({ status: 200, contentType: 'text/html', body: html });
    });
    await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
    await page.route('**/fonts.gstatic.com/**', r => r.abort());

    let nav = 'ok';
    try {
      await page.goto(`http://127.0.0.1:${PORT}/#/${route}`, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForTimeout(1400);
    } catch (e) { nav = String(e.message).slice(0, 120); }

    const audit = await page.evaluate(() => {
      const q = s => [...document.querySelectorAll(s)];
      const vis = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const controls = q('button,a[href],input,select,textarea,[role="switch"],summary,[onclick]').filter(vis);
      const label = el => (el.getAttribute('aria-label') || el.textContent || el.value || el.id || el.className || '').trim().replace(/\s+/g, ' ').slice(0, 60);
      const unwired = controls.filter(el => {
        if (el.tagName === 'A' && el.getAttribute('href')) return false;
        if (['INPUT','SELECT','TEXTAREA','SUMMARY'].includes(el.tagName)) return false;
        if (el.type === 'submit' && el.closest('form')) return false;
        if (el.onclick || el.getAttribute('onclick')) return false;
        /* data-* hooks are wired by delegation after render; only flag a button with neither */
        return !Object.keys(el.dataset).length;
      }).map(label);
      const ids = q('[id]').map(e => e.id);
      const dupIds = [...new Set(ids.filter((v, i) => ids.indexOf(v) !== i))];
      const small = controls.filter(el => { const r = el.getBoundingClientRect(); return (r.height < 44 && r.height > 0) && ['BUTTON','A'].includes(el.tagName) && el.textContent.trim(); })
        .map(el => `${label(el)} (${Math.round(el.getBoundingClientRect().height)}px)`);
      const overflow = document.documentElement.scrollWidth > document.documentElement.clientWidth;
      const main = document.querySelector('main,#main,.main');
      const brokenImg = q('img').filter(i => i.complete && i.naturalWidth === 0).map(i => i.src.slice(0, 80));
      return {
        title: (document.querySelector('h1') || {}).textContent?.trim().slice(0, 70) || '(no h1)',
        rendered: !!(main && main.textContent.trim().length > 40),
        bodyChars: document.body.textContent.trim().length,
        controls: controls.length, unwired, dupIds, small, overflow, brokenImg,
        errorCard: !!document.querySelector('.err,[data-error],#routeRetry'),
        rpc: (window.__QA?.rpc || []).map(r => r.name),
        unfixtured: [...(window.__QA?.unfixtured || [])],
      };
    }).catch(e => ({ evalError: String(e.message).slice(0, 160) }));

    const safe = route.replace(/\//g, '_');
    await page.screenshot({ path: join(ROOT, `tools/qa-sweep/shots/${label}-${safe}.png`), fullPage: true }).catch(() => {});
    out.push({ route, nav, consoleErrors, pageErrors, failedReq, ...audit });
    await ctx.close();
    process.stdout.write(`  ${label}/${route}${audit.rendered === false ? '  *** BLANK ***' : ''}${(pageErrors.length ? '  *** JS ERROR ***' : '')}\n`);
  }
  return out;
}

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, executablePath: CHROME });
try {
  const desktop = await sweep(browser, BUSINESS, 'biz-desktop', { width: 1280, height: 900 });
  const mobile = await sweep(browser, BUSINESS.slice(0, 12), 'biz-mobile', { width: 390, height: 844 });
  const cust = await sweep(browser, CUSTOMER, 'cust-mobile', { width: 390, height: 844 });
  await writeFile(join(ROOT, 'tools/qa-sweep/results.json'), JSON.stringify({ desktop, mobile, cust }, null, 2));
  console.log('\nwrote tools/qa-sweep/results.json');
} finally { await browser.close(); server.close(); }
