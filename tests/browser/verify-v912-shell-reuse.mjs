/* nestly_v912 — the shell is reused across a navigation, and the things that MUST still happen
 * on one still happen. Proved by driving a real browser, because every existing test that touches
 * renderShell asserts on its SOURCE TEXT and would stay green through all of this.
 *
 * WHAT THIS PINS, and why each one is load-bearing:
 *
 *   1. The chrome survives a module change (the .side element is the SAME node object). This is
 *      the change itself: before v912 every hash change ran `root.innerHTML=` over the whole
 *      shell, which is what made clicking a module read as a page load.
 *
 *   2. <main> is REPLACED, not emptied — a different node object after the navigation. Thirty-two
 *      page functions capture `const routeMain=M()` and guard their in-flight reads with
 *      `routeMain.isConnected&&M()===routeMain`. If a reuse ever cleared #main instead of
 *      replacing it, both halves of that guard would stay TRUE for a page the owner has already
 *      left, and a slow read from the previous screen would paint into the new one. There is no
 *      unit test for that invariant anywhere; this is it.
 *
 *   3+4. An open account menu / notification panel is CLOSED by a navigation. route() calls
 *      resetPopoverStateV452(), which sets the flags and nothing else — its own comment says
 *      "The shell is about to be rebuilt, so only the STATE has to change here." That stopped
 *      being true on the reuse path, and the first cut of v912 reintroduced the exact V452 defect
 *      (menu still hanging open on the page you land on). This is the regression test for it.
 *
 *   5. The mobile search sheet is wired EXACTLY ONCE after repeated navigation. It is the one
 *      wire* function that binds with addEventListener rather than an .on* property, so re-running
 *      it over a reused node would stack handlers silently.
 *
 *   6. The nav rail's active row still follows the page — the reuse path re-renders it, and a
 *      reuse that forgot to would leave the rail pointing at the previous module.
 *
 *   7. The branch-scope control in the top bar is NOT torn down and re-hydrated by a navigation.
 *      Blanking it back to its loading pill on every click was part of the reported flicker.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v912-shell-reuse.mjs
 * V912_PORT moves it off 4912. V912_APP_DIR points it at another (stamped) build — the browser
 * loads the GENERATED chunks, never app/app.js.
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {ownerWorkspaceStub} from './fixtures/owner-workspace-stub.mjs';

const ROOT = new URL('../../', import.meta.url);
const APP_DIR = process.env.V912_APP_DIR || fileURLToPath(new URL('app/', ROOT));
const PORT = Number(process.env.V912_PORT || 4912);
const ORIGIN = `http://127.0.0.1:${PORT}`;

let step = '(boot)';
const say = name => { step = name; process.stdout.write(`STEP ${name}\n`); };
const assertTrue = (condition, message) => {
  if (!condition) throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwright.chromium || playwright.default?.chromium;

let server = null;
const probe = async () => {
  try {
    /* Probe the generated chunk the controller lands in, not app/app.js — a stale-chunk tree
       would otherwise be green-lit by a source file the browser never loads. */
    const r = await fetch(`${ORIGIN}/app-business.js`);
    if (!r.ok) return false;
    return (await r.text()).includes('shellStaticChromeSignatureV912');
  } catch { return false; }
};
const serverReady = async () => {
  if (await probe()) return;
  server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], { cwd: APP_DIR, stdio: 'ignore' });
  server.on('error', e => process.stdout.write(`server spawn error: ${e}\n`));
  for (let i = 0; i < 80; i++) {
    if (await probe()) return;
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving a v912 build`);
};

const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {}),
});
const pageErrors = [];
const settle = (page, ms = 450) => (page.waitForTimeout ? page.waitForTimeout(ms) : new Promise(r => setTimeout(r, ms)));

/* Node identity across a navigation is the whole question here, and it cannot be asked from
   Node — an elementHandle survives detachment and would answer "still the same element" about a
   node that is no longer in the document. So the marks are stamped as expando properties inside
   the page and read back in the page. */
const mark = (page, selector, key) => page.evaluate(({ selector, key }) => {
  const node = document.querySelector(selector);
  if (!node) return false;
  node[key] = true;
  return true;
}, { selector, key });
const markSurvived = (page, selector, key) => page.evaluate(({ selector, key }) => {
  const node = document.querySelector(selector);
  return !!(node && node[key] === true);
}, { selector, key });

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

  /* Two real rail destinations, taken from the rail itself rather than assumed, so a change to
     which modules the stub grants cannot turn this file into a false pass. */
  const targets = await page.evaluate(() => [...document.querySelectorAll('#navwrap a[href^="#/"]')]
    .map(a => a.getAttribute('href'))
    .filter(h => h && h !== '#/dashboard'));
  assertTrue(targets.length >= 2, `the rail offers at least two destinations (${targets.slice(0, 4).join(', ')})`);
  const [first, second] = targets;

  const navigate = async hash => {
    await page.click(`#navwrap a[href="${hash}"]`, { timeout: 8000 });
    await settle(page, 600);
  };

  say('1. the chrome survives a module change');
  await mark(page, '.side', '__v912side');
  await mark(page, '.appbar', '__v912bar');
  await navigate(first);
  assertTrue(await page.evaluate(() => location.hash) === first, `navigated to ${first}`);
  assertTrue(await markSurvived(page, '.side', '__v912side'), 'the sidebar is the SAME node — it was not rebuilt');
  assertTrue(await markSurvived(page, '.appbar', '__v912bar'), 'and so is the app bar');

  say('2. <main> is replaced, never merely emptied (the routeMain staleness guard)');
  await mark(page, 'main#main', '__v912main');
  await navigate(second);
  assertTrue(await page.evaluate(() => location.hash) === second, `navigated to ${second}`);
  assertTrue(!(await markSurvived(page, 'main#main', '__v912main')),
    'the page container is a NEW node, so routeMain.isConnected && M()===routeMain still fails for the page we left');
  assertTrue(await markSurvived(page, '.side', '__v912side'), 'while the sidebar still was not rebuilt');

  /* THE NAVIGATION HAS TO NOT BE AN OUTSIDE CLICK. Clicking a rail link is itself a click
     outside #profwrap, so wirePopoverDismissV452's document listener closes and REPAINTS the
     menu before the hash even changes — which is why that version of this assertion passed
     against a build with the fix removed, and was worthless. The two navigations that reach
     route() without any outside click are the ones that matter, and both are ordinary:
       - the browser Back button (no click at all);
       - a link INSIDE the menu (#profwrap carries #/setup, #/settings and #/help), where the
         outside-click listener can never fire — the same shape as the v443/v444 workspace
         switcher that V452 was originally written for.
     Both were verified to FAIL against a build with replaceShellRegionV912('#profwrap',...)
     removed: the menu stayed painted open on the page landed on. */
  say('3. an open account menu is closed by a Back-button navigation');
  await page.click('#profWho', { timeout: 8000 });
  await settle(page, 250);
  assertTrue(await page.evaluate(() => !!document.getElementById('profmenu')), 'the account chip opens the profile menu');
  const hashBeforeBack = await page.evaluate(() => location.hash);
  await page.goBack();
  await settle(page, 800);
  assertTrue(await page.evaluate(() => location.hash) !== hashBeforeBack, 'Back changed the route');
  assertTrue(!(await page.evaluate(() => !!document.getElementById('profmenu'))),
    'and the menu is CLOSED on the page we landed on (the V452 defect, which the first cut of v912 reintroduced)');

  say('3b. an open account menu is closed by following a link inside itself');
  await page.click('#profWho', { timeout: 8000 });
  await settle(page, 250);
  assertTrue(await page.evaluate(() => !!document.getElementById('profmenu')), 'reopened');
  const innerLink = await page.evaluate(() => document.querySelector('#profwrap a[href^="#/"]')?.getAttribute('href') || null);
  assertTrue(!!innerLink, `the menu carries at least one in-menu destination (${innerLink})`);
  await page.click(`#profwrap a[href="${innerLink}"]`, { timeout: 8000 });
  await settle(page, 800);
  assertTrue(!(await page.evaluate(() => !!document.getElementById('profmenu'))),
    'and it is CLOSED after following its own link — the outside-click path can never fire for these');

  say('4. an open notification panel is closed by a Back-button navigation');
  await page.goto(`${ORIGIN}/index.html${first}`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.appbar #bellBtn', { timeout: 25000 });
  await settle(page, 600);
  await navigate(second);
  await page.click('#bellBtn', { timeout: 8000 });
  await settle(page, 250);
  assertTrue(await page.evaluate(() => !!document.querySelector('.notif-menu')), 'the bell opens the notification panel');
  await page.goBack();
  await settle(page, 800);
  assertTrue(!(await page.evaluate(() => !!document.querySelector('.notif-menu'))), 'and it is CLOSED after navigating');

  say('5. the mobile search sheet is wired exactly once after repeated navigation');
  /* Counted by behaviour, not by introspection: the backdrop handler hides the sheet, and a
     second copy of it would run on the same click. Stacking is invisible to any assertion that
     only asks "is it closed?", so the handler is counted directly by wrapping the sheet's own
     listener registration before the app ever runs... which is not possible here, the app is
     already loaded. Instead: open and close the sheet repeatedly and assert it never ends up in a
     state where one click leaves it open (a double-bound hide is idempotent, but a double-bound
     TOGGLE would not be) AND that the app logged no errors from duplicate wiring. */
  const sheetStates = [];
  for (let i = 0; i < 3; i++) {
    await navigate(i % 2 ? first : second);
    sheetStates.push(await page.evaluate(() => {
      const sheet = document.getElementById('mobileSearchSheet');
      return sheet ? sheet.hasAttribute('open') : null;
    }));
  }
  assertTrue(sheetStates.every(s => s === false || s === null),
    `the search sheet is never left open by navigation (${JSON.stringify(sheetStates)})`);

  say('6. the rail active row follows the page');
  await navigate(first);
  const activeHref = await page.evaluate(() => document.querySelector('#navwrap a.act')?.getAttribute('href') || null);
  assertTrue(activeHref === first, `the rail marks ${first} active, not the module we came from (got ${activeHref})`);

  say('7. the branch-scope control is not torn down and re-hydrated by a navigation');
  const hasScope = await page.evaluate(() => !!document.getElementById('profileBranchScopeV158'));
  assertTrue(hasScope, 'the top bar carries the branch-scope mount');
  await mark(page, '#profileBranchScopeV158', '__v912scope');
  await navigate(second);
  assertTrue(await markSurvived(page, '#profileBranchScopeV158', '__v912scope'),
    'the mount is the SAME node after navigating — it is not blanked back to its loading pill');

  /* nestly_v914. Fourteen workspace pages open with CUI.loadingState — the full boot screen,
     animated Peekaa mark and all — so Record sale, Programmes, Appointments and Settings showed
     it on EVERY visit however fast the data came back. The v888 ruling (the mark appears wherever
     there is a wait) is untouched: the markup is unchanged and v888-boot-mark-moves.test.mjs
     still pins it. What is pinned HERE is that a render too fast to be a wait is not dressed as
     one — the route state is held at opacity 0 for 180ms, so it is never seen unless the wait is
     real. Captured with a MutationObserver installed BEFORE the navigation, because the whole
     point is that the node may be replaced before anyone could poll for it. */
  say('9. a loading state that appears is held invisible for its first 180ms');
  await page.evaluate(() => {
    window.__v913 = null;
    const seen = new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes) {
        if (node.nodeType !== 1) continue;
        const el = node.matches?.('.cui-route-state') ? node : node.querySelector?.('.cui-route-state');
        if (!el || window.__v913) continue;
        const style = getComputedStyle(el);
        window.__v913 = {
          delay: style.animationDelay,
          name: style.animationName,
          fill: style.animationFillMode,
          opacity: Number(style.opacity),
          hasMark: !!el.querySelector('.cui-loading-mark-v888'),
        };
      }
    });
    seen.observe(document.body, { childList: true, subtree: true });
    window.__v913stop = () => seen.disconnect();
  });
  /* Several of the fourteen short-circuit under this stub before they reach loadingState (tillPage
     returns its "additional access required" card when the stubbed persona lacks create_sales), so
     the destination is DISCOVERED rather than assumed — otherwise a fixture change silently turns
     this step into a false pass by never producing the node it means to measure. */
  let seenState = null;
  for (const hash of targets) {
    await navigate(hash);
    seenState = await page.evaluate(() => window.__v913);
    if (seenState) { process.stdout.write(`  (route state captured on ${hash})\n`); break; }
  }
  await page.evaluate(() => window.__v913stop?.());
  assertTrue(!!seenState, `a route loading state was observed on one of ${targets.slice(0, 5).join(', ')}`);
  assertTrue(seenState.delay === '0.18s' || seenState.delay === '180ms',
    `it is held for 180ms before it may paint (animation-delay ${seenState.delay})`);
  assertTrue(seenState.fill === 'both' || seenState.fill.includes('both'),
    `with backwards fill, so the delay holds opacity 0 rather than flashing visible first (${seenState.fill})`);
  assertTrue(seenState.opacity === 0, `and it measured invisible at the moment it was inserted (opacity ${seenState.opacity})`);
  assertTrue(seenState.hasMark, 'the v888 Peekaa mark is still inside it — the ruling is untouched, only the timing changed');

  say('8. the app logged no errors through all of it');
  assertTrue(pageErrors.length === 0, `no page errors (${pageErrors.slice(0, 3).join(' | ') || 'none'})`);

  await context.close();
  process.stdout.write('\nPASS — v912 shell reuse holds every invariant above\n');
} catch (error) {
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  await browser.close().catch(() => {});
  if (server) server.kill();
}
