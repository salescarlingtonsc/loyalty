/* Click every control on every route and record what happens.
 *
 * The render sweep only proved pages LOAD. This presses things. For each route it walks every
 * visible button, link, toggle and summary in DOM order, clicks it, and records:
 *   - uncaught JS errors attributable to that click
 *   - whether a dialog opened, and whether Escape closed it again
 *   - whether the click navigated, and to where
 *   - whether the main region went blank
 *
 * Recovery between clicks: Escape (closes a CUI dialog), then re-navigate if the route changed.
 * Everything runs against the Supabase test double, so no real data is touched — a Delete button
 * calls a stubbed RPC and returns an empty result.
 */
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = '/home/user/loyalty';
const PORT = 4192;
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

const ROUTES = process.argv[2]
  ? [process.argv[2]]
  : ['dashboard','till','clients','sales','services','bookings','waitlist','appointments','inventory',
     'packages','branches','grow','loyalty','retention','promotions','referrals','memberships','reports',
     'customerintel','staffperf','staffmembers','dailyreport','pnl','expenses','setup','settings',
     /* the real customer app, now that the double fixtures its RPCs — the three
      local/customer-preview routes are a visual harness, not these screens */
   'wallet','wallet/qa-cafe','customer/programmes','customer/bookings','customer/messages',
   /* v393: #/customer/explore is retired. The route survives only as an alias to #/wallet, so
      sweeping it would sweep Home twice under a second name. */
   'customer/communications','customer/profile',
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

/* What counts as a control depends on which app the route belongs to.

   The BUSINESS workspace is scoped to its own content and top bar: the sidebar rail carries the
   same ~25 nav links on every route, and clicking them 26 times over adds no coverage while
   burying the real findings.

   The CUSTOMER app has no such rail. Its bottom nav is a primary, per-screen surface — Home,
   Rewards, Scan QR, Bookings, Profile, with live badges — so its routes are swept whole. Scoping
   it the same way as the workspace left 3 of 16 controls tested. */
const CONTROLS = ':is(button:not([disabled]), a[href]:not([href^="http"]), summary, [role="switch"])';
const isCustomerRoute = (r) => r === 'wallet' || r.startsWith('wallet/') || r.startsWith('customer/') || r.startsWith('local/customer-preview');
const scopeFor = (r) => (isCustomerRoute(r) ? CONTROLS : `:is(#main, .main, main, .appbar) ${CONTROLS}`);

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, executablePath: CHROME });
const report = [];

async function prep(page) {
  await page.route(/4192\/(#.*)?$|index\.html/, async r => {
    const rs = await r.fetch(); let h = await rs.text();
    h = h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/sb-double.js"></script>');
    await r.fulfill({ status: 200, contentType: 'text/html', body: h });
  });
  await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
}

for (const route of ROUTES) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e.message).slice(0, 200)));
  page.on('dialog', d => d.dismiss().catch(() => {}));
  await prep(page);

  const url = `http://127.0.0.1:${PORT}/#/${route}`;
  await page.goto(url, { waitUntil: 'domcontentloaded' }).catch(() => {});
  await page.waitForTimeout(1300);

  const SEL = scopeFor(route);
  const total = await page.locator(SEL).count().catch(() => 0);
  const results = [];

  for (let i = 0; i < Math.min(total, 60); i++) {
    // fresh state for every click so results are independent
    if (page.url() !== url) { await page.goto(url, { waitUntil: 'domcontentloaded' }).catch(() => {}); await page.waitForTimeout(900); }
    const before = errors.length;
    const el = page.locator(SEL).nth(i);
    let label = '';
    try {
      label = (await el.getAttribute('aria-label')) || (await el.innerText()) || (await el.getAttribute('id')) || '';
      label = label.trim().replace(/\s+/g, ' ').slice(0, 46);
      if (!(await el.isVisible())) continue;
      await el.click({ timeout: 2200, force: false });
      await page.waitForTimeout(420);
    } catch (e) {
      const msg = String(e.message);
      if (/intercept|not visible|outside of the viewport|detached/i.test(msg)) continue;
      results.push({ i, label, outcome: 'CLICK FAILED', detail: msg.split('\n')[0].slice(0, 90) });
      continue;
    }
    const after = await page.evaluate(() => {
      const dlg = document.querySelector('.modal[role="dialog"], dialog[open]');
      const main = document.querySelector('#main, .main, main');
      return { dialog: !!dlg, dialogLabel: dlg ? (dlg.querySelector('h1,h2')?.textContent || '').trim().slice(0, 40) : '',
               blank: !!(main && main.textContent.trim().length < 40), hash: location.hash };
    }).catch(() => ({}));

    const newErrors = errors.slice(before);
    let outcome = 'ok';
    if (newErrors.length) outcome = 'JS ERROR';
    else if (after.blank) outcome = 'BLANKED MAIN';
    else if (after.dialog) outcome = 'opened dialog';
    else if (after.hash && `http://127.0.0.1:${PORT}/${after.hash}` !== url) outcome = `navigated ${after.hash}`;

    if (after.dialog) {
      await page.keyboard.press('Escape').catch(() => {});
      await page.waitForTimeout(260);
      const stillOpen = await page.evaluate(() => !!document.querySelector('.modal[role="dialog"], dialog[open]')).catch(() => false);
      if (stillOpen) outcome += ' — ESCAPE DID NOT CLOSE';
    }
    const isProblem = /ERROR|BLANK|FAILED|DID NOT/.test(outcome);
    if (isProblem || outcome.startsWith('opened dialog')) {
      results.push({ i, label, outcome, problem: isProblem, detail: newErrors[0] || after.dialogLabel || '' });
    }
  }

  report.push({ route, controls: total, issues: results });
  const bad = results.filter(r => r.problem).length;
  const dialogs = results.filter(r => !r.problem).length;
  process.stdout.write(`  ${route.padEnd(32)} ${String(total).padStart(3)} controls  ${bad ? `*** ${bad} problem(s) ***` : 'clean'}${dialogs ? `  (${dialogs} dialogs opened+closed)` : ''}\n`);
  await ctx.close();
}

await writeFile(join(ROOT, 'tools/qa-sweep/click-results.json'), JSON.stringify(report, null, 2));
console.log('\nwrote tools/qa-sweep/click-results.json');
await browser.close(); server.close();
