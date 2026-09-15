/* nestly_v972 — the mobile dock is not rebuilt while CSS is hiding it, and IS correct the moment
 * it is shown. Proved by driving a real browser at both widths, because every part of this is a
 * computed style and a node identity — nothing a source grep can see.
 *
 * WHY. .staff-mobile-dock is `display:none` by default and `display:grid` only inside
 * `@media(max-width:960px)`. v912 replaced it on every navigation anyway, because it is
 * page-dependent: it carries the active quick action and a FULL SECOND COPY of the nav rail
 * (navHtml(page,'mobile-nav')). Measured at 1280x900, that was 171 element nodes destroyed and
 * rebuilt per navigation — the largest piece of chrome churn left after v912 — for something
 * nobody could see. Total chrome removed per navigation went 410 -> 239 when it stopped.
 *
 * THE RISK THIS FILE EXISTS FOR is the other side of that trade: a dock left stale while hidden
 * MUST be correct the instant a resize or rotation reveals it, and must still be rebuilt normally
 * at a width where it is visible. A phone that shows yesterday's active tab is a worse bug than
 * the waste this removes.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v972-idle-dock.mjs
 * V972_PORT moves it off 4972. V972_APP_DIR points it at another (stamped) build.
 */
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ownerWorkspaceStub } from './fixtures/owner-workspace-stub.mjs';

const ROOT = new URL('../../', import.meta.url);
const APP_DIR = process.env.V972_APP_DIR || fileURLToPath(new URL('app/', ROOT));
const PORT = Number(process.env.V972_PORT || 4972);
const ORIGIN = `http://127.0.0.1:${PORT}`;

let step = '(boot)';
const say = name => { step = name; process.stdout.write(`STEP ${name}\n`); };
const ok = (condition, message) => {
  if (!condition) throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwright.chromium || playwright.default?.chromium;

let server = null;
const probe = async () => {
  try {
    const r = await fetch(`${ORIGIN}/app-business.js`);
    return r.ok && (await r.text()).includes('mobileDockDisplayedV972');
  } catch { return false; }
};
const serverReady = async () => {
  if (await probe()) return;
  server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], { cwd: APP_DIR, stdio: 'ignore' });
  for (let i = 0; i < 100; i++) { if (await probe()) return; await new Promise(r => setTimeout(r, 100)); }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving a v972 build`);
};

const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {}),
});
const pageErrors = [];
const settle = (page, ms = 500) => (page.waitForTimeout ? page.waitForTimeout(ms) : new Promise(r => setTimeout(r, ms)));

const dockState = page => page.evaluate(() => {
  const dock = document.querySelector('.staff-mobile-dock');
  if (!dock) return { present: false };
  return {
    present: true,
    display: getComputedStyle(dock).display,
    marked: dock.__v972 === true,
    active: [...dock.querySelectorAll('.staff-mobile-action.act')].map(el => el.id),
    railActive: [...dock.querySelectorAll('.nav a.act')].map(a => a.getAttribute('href')),
  };
});
const markDock = page => page.evaluate(() => {
  const dock = document.querySelector('.staff-mobile-dock');
  if (dock) dock.__v972 = true;
  return !!dock;
});

try {
  await serverReady();
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, bypassCSP: true });
  await context.route('**/*', route => {
    const url = route.request().url();
    if (url.startsWith(ORIGIN) && !url.includes('/sw.js')) return route.continue();
    return route.abort();
  });
  await context.addInitScript(ownerWorkspaceStub({}));
  const page = await context.newPage();
  page.on('pageerror', e => pageErrors.push(String(e)));
  await page.goto(`${ORIGIN}/index.html#/dashboard`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.appbar #profWho', { timeout: 25000 });
  await settle(page);

  /* Navigate by hash, not by clicking the rail: the rail is itself hidden at 390px, and the same
     code path has to be exercised at both widths for the comparison to mean anything. */
  const go = async hash => { await page.evaluate(h => { location.hash = h; }, hash); await settle(page, 700); };

  say('1. at desktop width the dock exists but CSS is hiding it');
  const desktop0 = await dockState(page);
  ok(desktop0.present, 'the dock is in the DOM');
  ok(desktop0.display === 'none', `and display:none above the media query (got ${desktop0.display})`);

  say('2. a navigation there does NOT rebuild it');
  await markDock(page);
  await go('#/clients');
  await go('#/till');
  const desktop1 = await dockState(page);
  ok(desktop1.marked, 'the dock survived two navigations as the SAME node — 171 nodes not rebuilt');

  say('3. revealing it by resize rebuilds it, correct for the page we are actually on');
  await page.setViewportSize({ width: 390, height: 844 });
  await settle(page, 900);
  const revealed = await dockState(page);
  ok(revealed.display !== 'none', `the dock is displayed at 390px (got ${revealed.display})`);
  ok(!revealed.marked, 'and it was rebuilt on reveal, not left as the stale node');
  ok(revealed.active.includes('staffMobileQuickEarn'),
    `its active quick action is Record sale, the page we are on (got ${JSON.stringify(revealed.active)})`);
  ok(revealed.railActive.includes('#/till'),
    `and its own copy of the rail marks #/till active (got ${JSON.stringify(revealed.railActive)})`);

  say('4. at a width where it is visible it IS rebuilt on every navigation');
  await markDock(page);
  await go('#/appointments');
  const mobile1 = await dockState(page);
  ok(!mobile1.marked, 'the dock is a new node after navigating at 390px');
  ok(mobile1.active.includes('staffMobileAppointments'),
    `and follows the page (got ${JSON.stringify(mobile1.active)})`);
  ok(mobile1.railActive.includes('#/appointments'), 'its rail follows too');

  say('5. the More drawer is still wired after a reveal-rebuild — once, not twice, not never');
  const drawer = await page.evaluate(() => {
    const more = document.getElementById('staffMobileMore');
    if (!more) return { missing: true };
    more.open = true;
    const link = more.querySelector('a[href^="#/"]');
    if (!link) return { noLink: true };
    link.click();
    return { openAfterItemClick: more.open, href: link.getAttribute('href') };
  });
  ok(!drawer.missing && !drawer.noLink, 'the More drawer and its links exist');
  await settle(page, 300);
  const closed = await page.evaluate(() => document.getElementById('staffMobileMore')?.open === false);
  ok(closed, 'choosing an item inside it closes it — wireStaffMobileActions ran on the fresh nodes');

  say('6. going back to desktop and navigating still leaves it alone');
  await page.setViewportSize({ width: 1280, height: 900 });
  await settle(page, 700);
  await markDock(page);
  await go('#/clients');
  const desktop2 = await dockState(page);
  ok(desktop2.display === 'none', 'hidden again');
  ok(desktop2.marked, 'and untouched by the navigation');

  say('7. the app logged no errors through any of it');
  ok(pageErrors.length === 0, `no page errors (${pageErrors.slice(0, 2).join(' | ') || 'none'})`);

  await context.close();
  process.stdout.write('\nPASS — v972 idle dock holds every invariant above\n');
} catch (error) {
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  await browser.close().catch(() => {});
  if (server) server.kill();
}
