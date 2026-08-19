/* Empirical output-escaping sweep.
 *
 * Static tracing can only sample sinks. This poisons EVERY string the test double returns —
 * business name, customer names, service names, notes, SKUs, supplier, branch — with markup
 * that executes if it is ever written into innerHTML unescaped, then loads every route and asks
 * the page whether anything fired.
 *
 * Detection is threefold, because unescaped output shows up in more than one way:
 *   __XSS   an injected onerror/onload handler actually ran            -> executable injection
 *   probe   an element with the sentinel id/class exists in the DOM    -> markup was parsed
 *   attr    an attribute broke out of its quotes (data-xss present)    -> attribute injection
 *
 * A route that prints the payload as visible TEXT is correct behaviour and is not reported.
 */
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = '/home/user/loyalty';
const PORT = 4194;
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

/* Closes an attribute, opens an element with an error handler, and leaves a findable marker.
   Kept on one line so it survives being embedded in any of the app's template literals. */
const PAYLOAD = `"><img id="xssProbe" data-xss="1" src=x onerror="window.__XSS=(window.__XSS||0)+1"><b class="xssProbe">`;

const ROUTES = process.argv[2] ? [process.argv[2]] :
  ['dashboard','till','clients','sales','services','bookings','waitlist','appointments','inventory',
   'packages','branches','grow','loyalty','promotions','referrals','memberships','reports',
   'customerintel','staffperf','staffmembers','dailyreport','pnl','expenses','setup','settings',
   /* the real customer app, now that the double fixtures its RPCs — the three
      local/customer-preview routes are a visual harness, not these screens */
   'wallet','wallet/qa-cafe','customer/programmes','customer/bookings','customer/messages',
   /* v393: #/customer/explore is retired. The route survives only as an alias to #/wallet, so
      sweeping it would sweep Home twice under a second name. */
   'customer/communications','customer/profile',
   'customer-interface','local/customer-preview','local/customer-preview/rewards','local/customer-preview/bookings'];

/* Rewrite the double so the user-controlled string fields in its fixture data carry the payload.

   Ids, uuids, dates, slugs and enum keys are left alone — poisoning those breaks the app for
   reasons that have nothing to do with escaping. */
function poison(src) {
  return src.replace(/(name|full_name|business_name|title|label|description|note|notes|supplier|sku|category|message|reason|address|display_name|staff_name|client_name):\s*'([^']*)'/g,
    (m, key, val) => `${key}: ${JSON.stringify(val + PAYLOAD)}`);
}

const server = createServer(async (req, res) => {
  try {
    const p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    if (p === '/sb-double.js') {
      const src = await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js'), 'utf8');
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(poison(src));
    }
    const f = join(ROOT, p === '/' ? '/app/index.html' : (p.startsWith('/app/') ? p : '/app' + p));
    const b = await readFile(f);
    res.writeHead(200, { 'content-type': MIME[extname(f)] || 'application/octet-stream' });
    res.end(b);
  } catch { res.writeHead(404); res.end('nf'); }
});

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, executablePath: CHROME });
const report = [];

for (const route of ROUTES) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  await page.route(new RegExp(`${PORT}/(#.*)?$|index\\.html`), async r => {
    const rs = await r.fetch(); let h = await rs.text();
    h = h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/sb-double.js"></script>');
    await r.fulfill({ status: 200, contentType: 'text/html', body: h });
  });
  await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  await page.goto(`http://127.0.0.1:${PORT}/#/${route}`, { waitUntil: 'domcontentloaded' }).catch(() => {});
  await page.waitForTimeout(1500);

  const hit = await page.evaluate(() => ({
    exec: window.__XSS || 0,
    probes: document.querySelectorAll('#xssProbe, .xssProbe').length,
    attrs: document.querySelectorAll('[data-xss]').length,
    /* proof the payload did reach the screen, so a clean result means "escaped", not "absent" */
    textShown: (document.body.innerText || '').includes('<img id="xssProbe"'),
  })).catch(e => ({ error: String(e.message).slice(0, 100) }));

  const bad = (hit.exec || 0) + (hit.probes || 0) + (hit.attrs || 0);
  report.push({ route, ...hit });
  process.stdout.write(`  ${route.padEnd(32)} ${bad ? `*** INJECTED  exec=${hit.exec} probes=${hit.probes} attrs=${hit.attrs} ***` : `escaped${hit.textShown ? ' (payload reached the page as text)' : ' (payload not on this screen)'}`}\n`);
  await ctx.close();
}

await writeFile(join(ROOT, 'tools/qa-sweep/xss-results.json'), JSON.stringify(report, null, 2));
console.log('\nwrote tools/qa-sweep/xss-results.json');
await browser.close(); server.close();
