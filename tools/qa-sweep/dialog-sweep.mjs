/* dialog-sweep — the regression gate for the W5-2 modal shell (width ladder + shared mobile
 * sheet). Walks every route, discovers every control that opens a dialog, and for each dialog
 * opened asserts:
 *   1. rendered .modal-card width is one of the four ladder steps (--dialog-w-sm/md/lg/xl), or
 *      the card carries its own inline max-width (a pre-existing per-call-site override that was
 *      never part of the ladder — W5-2's spec only touched the 8 CSS-class-driven widths), or —
 *      on the 390px pass — the card is capped to (near) the viewport width.
 *   2. a close affordance exists (aria-label containing "close"/"cancel", or visible text
 *      ×/x/Close/Cancel).
 *   3. Escape closes it.
 *   4. a backdrop is painted behind it (every dialog in this app IS its own backdrop: the
 *      `.modal` overlay element paints background:rgba(...) directly, so this checks that).
 *   5. no horizontal document overflow at 390px.
 *   6. focus lands inside the dialog right after it opens.
 *
 * BOOT PATTERN — copied from tools/qa-sweep/sync-sweep.mjs: a tiny static file server over the
 * real app, the CDN <script> tag swapped for the local Supabase test double (sb-double.js) by
 * rewriting the served HTML (the CDN tag carries a Subresource-Integrity hash, so the double is
 * injected by replacing the whole <script> tag rather than editing supabase-js in place),
 * --root/--port argv, PLAYWRIGHT_MODULE env for the playwright-core entry point, and
 * PLAYWRIGHT_CHROMIUM env / --chrome argv for a machine whose default resolved browser build
 * doesn't match its cache (chromium.launch({headless:true}) otherwise).
 *
 * DIALOG DISCOVERY — copied from tools/qa-sweep/click-sweep.mjs rather than hand-listing
 * triggers: the same ROUTES list and the same CONTROLS selector / scoping rule (business routes
 * scope to #main/.main/main/.appbar, the customer app sweeps the whole route since its bottom
 * nav has no rail), walking every visible control in DOM order and checking whether
 * `.modal[role="dialog"], dialog[open]` exists afterwards — exactly click-sweep's own detector,
 * including its blind spot (a dialog that isn't `.modal` classed, e.g. `.mobile-search-sheet`,
 * is not discovered by either script).
 *
 * TWO PASSES, ONE DISCOVERY WALK
 *   Pass 1 (1280x900, click-sweep's own viewport): walks every route/control, and for every
 *   dialog it opens, asserts 1/2/4/6 immediately then presses Escape and asserts 3. The
 *   (route, control index) of every successful trigger is recorded.
 *   Pass 2 (390x844): re-visits ONLY the recorded triggers (not a full re-walk — the discovery
 *   already happened) and re-asserts all six, this time with assertion 5 (no horizontal
 *   overflow) live and assertion 1 evaluated against the mobile viewport cap.
 *
 * USAGE
 *   node tools/qa-sweep/dialog-sweep.mjs [--root <repo root>] [--port 4194] [--route <one route>]
 *   PLAYWRIGHT_MODULE=/abs/path/to/playwright-core/index.js   (optional; defaults to 'playwright')
 *   PLAYWRIGHT_CHROMIUM=/abs/path/to/chrome                   (optional; escape hatch)
 *
 * Exits non-zero if any assertion fails. Writes tools/qa-sweep/dialog-results.json.
 */
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const ROOT = resolve(arg('root', resolve(HERE, '..', '..')));
const PORT = Number(arg('port', '4194'));
const ONLY_ROUTE = arg('route', '');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

const playwrightModule = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwrightModule.chromium || playwrightModule.default?.chromium;
if (!chromium) throw new Error('playwright: no chromium export (set PLAYWRIGHT_MODULE to a playwright/playwright-core entry point)');
const CHROME = process.env.PLAYWRIGHT_CHROMIUM || arg('chrome', '');

/* ---------------------------------------------------------------- click-sweep's own route list
   and control scoping, copied verbatim (see tools/qa-sweep/click-sweep.mjs) so dialog discovery
   matches what that sweep already proved opens 46 dialogs across the app. */
const ROUTES = ONLY_ROUTE ? [ONLY_ROUTE] : ['dashboard','till','clients','sales','services','bookings','waitlist','appointments','inventory',
  'packages','branches','grow','loyalty','retention','promotions','referrals','memberships','reports',
  'customerintel','staffperf','staffmembers','dailyreport','pnl','expenses','setup','settings',
  'wallet','wallet/qa-cafe','customer/programmes','customer/bookings','customer/messages',
  'customer/communications','customer/profile',
  'customer-interface','local/customer-preview','local/customer-preview/rewards','local/customer-preview/bookings'];
const CONTROLS = ':is(button:not([disabled]), a[href]:not([href^="http"]), summary, [role="switch"])';
const isCustomerRoute = (r) => r === 'wallet' || r.startsWith('wallet/') || r.startsWith('customer/') || r.startsWith('local/customer-preview');
const scopeFor = (r) => (isCustomerRoute(r) ? CONTROLS : `:is(#main, .main, main, .appbar) ${CONTROLS}`);

/* ---------------------------------------------------------------- the static server, boot
   pattern copied from sync-sweep.mjs. */
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

async function prep(page) {
  await page.route(new RegExp(`${PORT}/(#.*)?$|index\\.html`), async r => {
    const rs = await r.fetch(); let h = await rs.text();
    h = h.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/sb-double.js"></script>');
    await r.fulfill({ status: 200, contentType: 'text/html', body: h });
  });
  await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  await page.route('**/fonts.gstatic.com/**', r => r.abort());
}

const results = [];
const failures = [];
function record(route, dialogId, label, ok, detail = '') {
  results.push({ route, dialogId, label, ok: !!ok, detail });
  if (!ok) failures.push(`[${route}] ${dialogId}: ${label}${detail ? ` — ${detail}` : ''}`);
  process.stdout.write(`    ${ok ? 'PASS' : 'FAIL'}  ${label}${ok || !detail ? '' : `  (${detail})`}\n`);
}

/* The six assertions, run inside the page against whatever `.modal[role="dialog"], dialog[open]`
   is currently in the DOM. Returns plain data; nothing here decides pass/fail so the same
   evaluate() output can be asserted once at 1280 and again at 390. */
async function readDialogFacts(page, viewportWidth) {
  return page.evaluate((vw) => {
    const dlg = document.querySelector('.modal[role="dialog"], dialog[open]');
    if (!dlg) return { present: false };
    const card = dlg.querySelector('.modal-card') || dlg;
    const rect = card.getBoundingClientRect();
    const width = Math.round(rect.width);
    const styleAttr = card.getAttribute('style') || '';
    /* Catches both inline `max-width:…` (e.g. tCustomModal) and inline `width:…` (e.g. the
       generic confirmActionTitleV386 confirm dialog, `style="width:min(460px,100%)"`) — either
       is a deliberate per-call-site override that was never part of the W5-2 ladder audit's 8
       CSS-class-driven widths, so it is out of scope here rather than a defect. */
    const hasOwnWidthOverride = /width\s*:/i.test(styleAttr);
    const root = getComputedStyle(document.documentElement);
    const ladder = ['--dialog-w-sm', '--dialog-w-md', '--dialog-w-lg', '--dialog-w-xl']
      .map(v => parseFloat(root.getPropertyValue(v)))
      .filter(n => Number.isFinite(n));
    const inLadder = ladder.some(v => Math.abs(width - v) <= 2);
    const dlgBg = getComputedStyle(dlg).backgroundColor || '';
    const alphaMatch = dlgBg.match(/rgba?\(([^)]+)\)/);
    const alpha = alphaMatch ? (alphaMatch[1].split(',').map(s => s.trim())[3] ?? '1') : '0';
    const backdropPainted = dlgBg !== '' && dlgBg !== 'transparent' && parseFloat(alpha) > 0;
    const candidates = [...dlg.querySelectorAll('button, a[href], [role="button"]')];
    const hasClose = candidates.some(el => {
      const aria = (el.getAttribute('aria-label') || '').toLowerCase();
      const text = (el.textContent || '').trim().toLowerCase();
      /* W6: 'Done' is a dismissal, not a missing affordance. The till add-sheet closes with a
         'Done' button and this check flagged it; the honest fix is to widen the vocabulary
         rather than bolt aria-label="Close" onto a button that says Done, which would make a
         screen reader announce something the button does not say. Sheets conventionally
         confirm-and-dismiss with Done/Finished; keep the list to words that unambiguously
         END the dialog — 'Save' is deliberately NOT here, since a save may leave it open. */
      const DISMISS = ['×', 'x', 'close', 'cancel', 'done', 'finished', 'dismiss', 'back'];
      return aria.includes('close') || aria.includes('cancel') || aria.includes('dismiss')
        || DISMISS.includes(text);
    });
    const active = document.activeElement;
    const focusInside = !!active && (active === dlg || dlg.contains(active));
    const overflow = document.documentElement.scrollWidth > document.documentElement.clientWidth + 1;
    const distinctiveClasses = dlg.className.split(' ').filter(c => c && c !== 'modal' && c !== 'customer-surface').join('.');
    return {
      present: true, id: dlg.id || distinctiveClasses || dlg.className.split(' ')[0] || 'modal', width, viewportWidth: vw,
      hasOwnWidthOverride, inLadder, backdropPainted, hasClose, focusInside, overflow,
      viewportCapped: width <= vw && width >= vw - 48,
    };
  }, viewportWidth);
}

function assertDialog(route, facts) {
  if (!facts.present) return;
  const label = `${route} :: ${facts.id} @${facts.viewportWidth}`;
  const widthOk = facts.inLadder || facts.hasOwnWidthOverride
    || (facts.viewportWidth <= 420 && facts.viewportCapped);
  record(route, facts.id, `${label} — width ∈ ladder or exempt/capped (${facts.width}px)`, widthOk,
    facts.hasOwnWidthOverride ? 'pre-existing inline width override, out of W5-2 ladder scope' : `${facts.width}px, viewport ${facts.viewportWidth}px`);
  record(route, facts.id, `${label} — close affordance present`, facts.hasClose);
  record(route, facts.id, `${label} — backdrop painted`, facts.backdropPainted);
  record(route, facts.id, `${label} — focus inside dialog on open`, facts.focusInside);
  if (facts.viewportWidth <= 420) {
    record(route, facts.id, `${label} — no horizontal document overflow`, !facts.overflow);
  }
}

async function closesOnEscape(page, route, dialogId, viewportWidth) {
  await page.keyboard.press('Escape').catch(() => {});
  await page.waitForTimeout(260);
  const stillOpen = await page.evaluate(() => !!document.querySelector('.modal[role="dialog"], dialog[open]')).catch(() => false);
  record(route, dialogId, `${route} :: ${dialogId} @${viewportWidth} — Escape closes it`, !stillOpen);
}

/* -------------------------------------------------------------------------------- pass 1: 1280 */
async function walk(browser, { viewport, isSecondPass, triggers }) {
  const found = [];
  const routesToWalk = isSecondPass
    ? [...new Set(triggers.map(t => t.route))]
    : ROUTES;

  for (const route of routesToWalk) {
    const ctx = await browser.newContext({ viewport });
    const page = await ctx.newPage();
    await prep(page);
    const url = `http://127.0.0.1:${PORT}/#/${route}`;
    await page.goto(url, { waitUntil: 'domcontentloaded' }).catch(() => {});
    await page.waitForTimeout(1300);

    const SEL = scopeFor(route);
    const indices = isSecondPass
      ? triggers.filter(t => t.route === route).map(t => t.i)
      : null;
    const total = indices ? Math.max(...indices) + 1 : await page.locator(SEL).count().catch(() => 0);

    console.log(`\n  route #/${route} (${viewport.width}x${viewport.height})`);
    for (let i = 0; i < Math.min(total, 60); i++) {
      if (indices && !indices.includes(i)) continue;
      if (page.url() !== url) { await page.goto(url, { waitUntil: 'domcontentloaded' }).catch(() => {}); await page.waitForTimeout(900); }
      const el = page.locator(SEL).nth(i);
      try {
        if (!(await el.isVisible())) continue;
        await el.click({ timeout: 2200, force: false });
        await page.waitForTimeout(420);
      } catch { continue; }

      const facts = await readDialogFacts(page, viewport.width).catch(() => ({ present: false }));
      if (!facts.present) continue;

      if (!isSecondPass) found.push({ route, i });
      console.log(`  dialog opened by control #${i} → ${facts.id}`);
      assertDialog(route, facts);
      await closesOnEscape(page, route, facts.id, viewport.width);
    }
    await ctx.close();
  }
  return found;
}

/* ------------------------------------------------------------- v400 chip-clip regression check
 * Not a dialog — a small, separately-scoped addition per the W5-2 task's own instruction to
 * "extend dialog-sweep (or add a small check to it)" for the offer countdown chip fix. Loads
 * #/wallet at 390 and 1440, in both light and dark customer theme (toggled the same way the real
 * app does: the data-customer-theme attribute on <html>, which is what every dark-mode CSS rule
 * in app/index.html is keyed on), and asserts for .customer-home-offer-countdown:
 *   - scrollWidth === clientWidth (no text clipped inside the chip's own box), and
 *   - the chip's right edge sits at or inside .customer-home-offer-media's right edge.
 * Before the v400 fix the chip was position:absolute with its own top/right, and its shrink-to-
 * fit width resolved against that static position rather than its content — the box stayed a
 * fixed 83px regardless of text length, so scrollWidth (133px) exceeded clientWidth (83px) at
 * every viewport and theme (the bug did not depend on either).
 *
 * sb-double.js's default home-offer fixture ships image_url:'' (the monogram-fallback card), a
 * DIFFERENT, pre-existing rendering path with its own unrelated width squeeze — see the report at
 * the bottom of this file — so this check patches just its own page context to give that one
 * fixture item a real (Supabase-object-path-shaped) image_url, exercising the actual artwork-card
 * path the countdown-clip bug was diagnosed against, without touching the shared fixture file. */
async function checkOfferCountdownChip(browser) {
  console.log('\n[chip check] #/wallet .customer-home-offer-countdown — no internal clip, stays inside media, light + dark');
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    for (const theme of ['light', 'dark']) {
      const ctx = await browser.newContext({ viewport });
      const page = await ctx.newPage();
      await prep(page);
      await page.route('**/sb-double.js', async r => {
        const resp = await r.fetch();
        let body = await resp.text();
        body = body.replace("image_url: '', image_alt: ''",
          "image_url: '/storage/v1/object/public/business-public/10000000-0000-4000-8000-000000000001/offer/10000000-0000-4000-8000-000000000002.png', image_alt: 'test'");
        await r.fulfill({ status: 200, contentType: 'text/javascript', body });
      });
      await page.goto(`http://127.0.0.1:${PORT}/#/wallet`, { waitUntil: 'domcontentloaded' }).catch(() => {});
      await page.waitForTimeout(1200);
      if (theme === 'dark') {
        await page.evaluate(() => document.documentElement.setAttribute('data-customer-theme', 'dark'));
        await page.waitForTimeout(150);
      }
      const facts = await page.evaluate(() => {
        const chip = document.querySelector('.customer-home-offer-countdown');
        const media = document.querySelector('.customer-home-offer-media');
        if (!chip || !media) return { present: false };
        const c = chip.getBoundingClientRect(), m = media.getBoundingClientRect();
        return {
          present: true, text: chip.textContent.trim(),
          isFallback: media.className.includes('--fallback'),
          scrollWidth: chip.scrollWidth, clientWidth: chip.clientWidth,
          rightInside: c.right <= m.right + 0.5,
        };
      });
      const label = `#/wallet countdown chip @${viewport.width} theme=${theme}`;
      if (!facts.present) {
        record('wallet', 'countdown-chip', `${label} — chip present`, false, 'no .customer-home-offer-countdown in the fixture — cannot assert');
      } else {
        record('wallet', 'countdown-chip', `${label} — exercising the artwork media path (fixture patch landed)`, !facts.isFallback);
        record('wallet', 'countdown-chip', `${label} — no internal clip (scrollWidth===clientWidth)`,
          facts.scrollWidth === facts.clientWidth, `scrollWidth=${facts.scrollWidth} clientWidth=${facts.clientWidth} text="${facts.text}"`);
        record('wallet', 'countdown-chip', `${label} — right edge inside .customer-home-offer-media`, facts.rightInside);
      }
      await ctx.close();
    }
  }
}

/* ------------------------------------------------------- till-add-sheet-v373 + appointment-detail-modal
 * Wave-gap fix (tools/qa-sweep/sb-double.js now fixtures get_my_modules_at_v115 and
 * business_get_checkout_catalogue_v94, which is what till/appointments needed to get past their
 * own "no staff identity / no accessible branch" guard — see that file for the shape citations).
 * Both dialogs need a DEDICATED check rather than the generic discovery walk above:
 *
 *   - till-add-sheet-v373 is TWO clicks deep (start a walk-in sale, THEN "More items"). The
 *     first click redraws the whole #/till screen in place (no URL change), and the walk-in
 *     button is the LAST control on the phone-entry screen — so by the time "More items" exists
 *     in the DOM, the flat control-index range the walk computed BEFORE any click has already
 *     run out. The generic walk finds 0 dialogs on #/till for exactly this reason.
 *
 *   - appointment-detail-modal's trigger is responsive, not just repositioned: the desktop day-
 *     timeline event button (`.day-timeline-event`) is CSS `display:none` under ~900px, replaced
 *     by a SEPARATE `.calendar-agenda-item` button for the same appointment (V291's mobile
 *     agenda fallback) — a different DOM position, not just a different pixel position. Pass 2
 *     re-triggers by the control INDEX recorded in pass 1, so at 390px it clicks whatever now
 *     sits at that index (usually invisible or unrelated) instead of the agenda item, and
 *     el.isVisible() is false, so the walk silently `continue`s — confirmed live: the generic
 *     walk opens this dialog once on desktop (pass 1) and produces ZERO assertions for it at
 *     390px in pass 2.
 *
 * Both dialogs are asserted at BOTH viewports here, independently per viewport (find whichever
 * trigger is actually visible, rather than reusing a pass-1 index), through the same
 * readDialogFacts()/assertDialog()/closesOnEscape() the rest of this file uses. This runs
 * ALONGSIDE the generic walk above, not instead of it — the generic walk still gets first crack
 * at #/appointments on desktop (and did, successfully, before this was added), so a future
 * regression in that path is still caught there too. */
async function checkTillAddSheetDialog(browser) {
  console.log('\n[till-add-sheet-v373] #/till — walk-in sale → More items, both viewports');
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    const ctx = await browser.newContext({ viewport });
    const page = await ctx.newPage();
    await prep(page);
    const label = `#/till :: till-add-sheet-v373 @${viewport.width}`;
    await page.goto(`http://127.0.0.1:${PORT}/#/till`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    await page.waitForTimeout(1300);
    try {
      await page.locator('#tWalkin').click({ timeout: 3000 });
      await page.waitForTimeout(500);
      await page.locator('#tAddItemV373').click({ timeout: 3000 });
      await page.waitForTimeout(400);
    } catch (e) {
      record('till', 'till-add-sheet-v373', `${label} — reached the dialog trigger`, false, String(e?.message || e));
      await ctx.close();
      continue;
    }
    const facts = await readDialogFacts(page, viewport.width).catch(() => ({ present: false }));
    if (!facts.present) {
      record('till', 'till-add-sheet-v373', `${label} — dialog opened`, false,
        'no .modal[role="dialog"] in the DOM after Walk-in sale → More items');
    } else {
      console.log(`  dialog opened by walk-in → More items @${viewport.width} → ${facts.id}`);
      assertDialog('till', facts);
      await closesOnEscape(page, 'till', facts.id, viewport.width);
    }
    await ctx.close();
  }
}

async function checkAppointmentDetailDialog(browser) {
  console.log('\n[appointment-detail-modal] #/appointments — viewport-appropriate trigger, both viewports');
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    const ctx = await browser.newContext({ viewport });
    const page = await ctx.newPage();
    await prep(page);
    const label = `#/appointments :: appointment-detail-modal @${viewport.width}`;
    await page.goto(`http://127.0.0.1:${PORT}/#/appointments`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    await page.waitForTimeout(1300);
    // Both `.day-timeline-event` (desktop grid) and `.calendar-agenda-item` (mobile agenda
    // fallback) carry `data-appointment` for the same appointment; CSS shows exactly one per
    // viewport, so picking the first VISIBLE one is the viewport-appropriate trigger.
    const trigger = page.locator('button[data-appointment]:visible').first();
    try {
      await trigger.waitFor({ state: 'visible', timeout: 3000 });
      await trigger.click({ timeout: 3000 });
      await page.waitForTimeout(400);
    } catch (e) {
      record('appointments', 'appointment-detail-modal', `${label} — reached the dialog trigger`, false, String(e?.message || e));
      await ctx.close();
      continue;
    }
    const facts = await readDialogFacts(page, viewport.width).catch(() => ({ present: false }));
    if (!facts.present) {
      record('appointments', 'appointment-detail-modal', `${label} — dialog opened`, false,
        'no .modal[role="dialog"] in the DOM after clicking the appointment');
    } else {
      console.log(`  dialog opened by appointment trigger @${viewport.width} → ${facts.id}`);
      assertDialog('appointments', facts);
      await closesOnEscape(page, 'appointments', facts.id, viewport.width);
    }
    await ctx.close();
  }
}

/* ---------------------------------------------------------------------------- known-issue note
 * DISCOVERED, NOT FIXED HERE (out of the W5-2 chip fix's prescribed scope — flagging, not
 * re-diagnosing or silently patching):
 * `.customer-home-offer-media--fallback span{width:46px;height:46px;display:grid;place-items:
 * center;...}` (app/index.html, "V299" rule, ~line 2566) targets ANY <span> descendant of the
 * monogram-fallback media block. When an offer has no image the countdown chip's own inner text
 * span — `<span>${esc(countdown)}</span>` inside the chip <p>, app/app.js ~line 7136-7137 — is
 * such a descendant, so it gets force-squashed to a 46x46 square, which is what actually produces
 * the same "clientWidth < scrollWidth" clipped-chip symptom on a no-image offer. This predates
 * the v400 chip fix (the inner span nesting is unchanged by it) and is a distinct bug: any
 * business without an uploaded offer image, running a dated offer, gets a clipped countdown.
 * Confirmed live: this script's own chip check runs against sb-double.js's DEFAULT fixture
 * (image_url:'') first without a patch and reproduces exactly this — 83/133px — before the
 * per-context fixture patch above swaps in an artwork URL to test the actual diagnosed path. */

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, ...(CHROME ? { executablePath: CHROME } : {}) });
try {
  console.log('[pass 1] 1280x900 — discovery walk (click-sweep\'s own route list + control scoping)');
  const triggers = await walk(browser, { viewport: { width: 1280, height: 900 }, isSecondPass: false, triggers: [] });
  console.log(`\n  ${triggers.length} dialog-opening controls found.`);

  console.log('\n[pass 2] 390x844 — re-visiting only the discovered triggers');
  await walk(browser, { viewport: { width: 390, height: 844 }, isSecondPass: true, triggers });

  await checkOfferCountdownChip(browser);
  await checkTillAddSheetDialog(browser);
  await checkAppointmentDetailDialog(browser);

  await writeFile(join(ROOT, 'tools/qa-sweep/dialog-results.json'),
    JSON.stringify({ triggerCount: triggers.length, results, failures }, null, 2));
} finally {
  await browser.close();
  server.close();
}

console.log(`\n${results.length} assertions across ${new Set(results.map(r => r.dialogId)).size} distinct dialogs.`);
if (failures.length) {
  console.error(`\nFAILED (${failures.length}/${results.length}):`);
  failures.forEach(f => console.error(`  - ${f}`));
  process.exit(1);
}
console.log(`\nPASS — ${results.length}/${results.length} assertions.`);
