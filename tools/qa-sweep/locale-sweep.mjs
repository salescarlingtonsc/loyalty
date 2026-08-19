/* Workspace translation-coverage sweep.
 *
 * The workspace offers English, Simplified Chinese and Malay. localizeWorkspaceSubtreeV97 walks
 * every text node in the shell and swaps in a translation IF the copy table has one; a string
 * with no entry silently stays English. Nothing in the build reports how much of each screen
 * that leaves untranslated, so this counts it.
 *
 * Method: boot each route with the locale preference set to zh-CN (and again to ms), read every
 * visible text node inside the shell, and classify. Excluded, because they are correctly not
 * translated:
 *   [data-merchant-content]  the firm's own words (service names, reward names)
 *   table cell data          customer names, amounts, dates
 *   numbers, currency, punctuation, and single characters
 *
 * What is left is UI chrome that a staff member who picked Chinese still reads in English.
 */
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = '/home/user/loyalty';
const PORT = 4195;
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

const LOCALES = ['zh-CN', 'ms'];
const ROUTES = process.argv[2] ? [process.argv[2]] :
  ['dashboard','till','clients','sales','services','bookings','waitlist','appointments','inventory',
   'packages','branches','grow','loyalty','promotions','referrals','memberships','reports',
   'customerintel','staffperf','staffmembers','dailyreport','pnl','expenses','setup','settings'];

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

const COLLECT = (locale) => {
  const shell = document.querySelector('.shell') || document.body;
  const walker = document.createTreeWalker(shell, NodeFilter.SHOW_TEXT);
  const english = [], translated = [];
  const hasCjk = (s) => /[一-鿿]/.test(s);
  let n;
  while ((n = walker.nextNode())) {
    const t = (n.nodeValue || '').trim();
    if (!t || t.length < 2) continue;
    const el = n.parentElement;
    if (!el) continue;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    if (el.closest('[data-merchant-content], script, style, code')) continue;
    if (el.closest('td, th')) continue;                 // row data, not chrome
    if (!/[A-Za-z一-鿿]/.test(t)) continue;      // numbers/symbols only
    if (/^(SGD|S\$|\$|%|@|#|·|—|–)$/.test(t)) continue;
    if (/^[A-Z]{2,4}$/.test(t)) continue;                // acronyms / initials
    const box = el.getBoundingClientRect();
    if (box.width === 0 && box.height === 0) continue;
    // zh-CN is judged by script; ms shares the Latin alphabet, so only the copy table can say.
    if (locale === 'zh-CN') (hasCjk(t) ? translated : english).push(t);
    else translated.push(t);
  }
  const uniq = [...new Set(english)];
  return { english: uniq.slice(0, 40), englishCount: uniq.length, translatedCount: new Set(translated).size };
};

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, executablePath: CHROME });
const report = [];

for (const locale of LOCALES) {
  if (locale !== 'zh-CN') continue; // Malay cannot be judged by script; see note in the report
  console.log(`\n=== locale ${locale} ===`);
  for (const route of ROUTES) {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await ctx.newPage();
    await page.route(new RegExp(`${PORT}/(#.*)?$|index\\.html`), async r => {
      const rs = await r.fetch(); let h = await rs.text();
      h = h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/,
        `<script>window.__QA_LOCALE=${JSON.stringify(locale)}</script><script src="/sb-double.js"></script>`);
      await r.fulfill({ status: 200, contentType: 'text/html', body: h });
    });
    await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
    await page.goto(`http://127.0.0.1:${PORT}/#/${route}`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    await page.waitForTimeout(1600);
    const row = await page.evaluate(COLLECT, locale).catch(e => ({ error: String(e.message).slice(0, 100) }));
    const total = (row.englishCount || 0) + (row.translatedCount || 0);
    const pct = total ? Math.round((row.translatedCount / total) * 100) : 0;
    process.stdout.write(`  ${route.padEnd(20)} ${String(pct).padStart(3)}% translated   ${String(row.englishCount || 0).padStart(3)} strings still English\n`);
    report.push({ locale, route, pct, ...row });
    await ctx.close();
  }
}

await writeFile(join(ROOT, 'tools/qa-sweep/locale-results.json'), JSON.stringify(report, null, 2));
console.log('\nwrote tools/qa-sweep/locale-results.json');
await browser.close(); server.close();
