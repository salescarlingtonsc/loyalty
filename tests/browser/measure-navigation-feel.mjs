/* Does a module click feel instant? MEASURED, not asserted.
 *
 * This file is deliberately NOT a test and NOT a CI gate. It answers a question the owner keeps
 * asking in the only way that is honest — with numbers off a real browser driving the real
 * bundles — and it reports whatever it finds rather than passing or failing. The gates that DO
 * assert live beside it: verify-v912-shell-reuse.mjs (the shell is reused), verify-v972-idle-dock.mjs
 * (the hidden dock is not rebuilt). Turning this one into an assertion would pin a machine's
 * timing to a threshold and go red on a loaded laptop, which is how a suite learns to be ignored.
 *
 * WHAT IT RECORDS, per navigation:
 *
 *   paint_ms      click -> #main has its first element child (something is on screen)
 *   commit_ms     click -> the <h1> names the module we asked for (the page is THE page)
 *   splash_seen   was .cui-route-state ever actually VISIBLE (computed opacity > 0.01) on any
 *                 animation frame? This is the thing that reads as a page load.
 *   splash_peak   how visible it got, 0-100. A splash that peaks at 6% is a threshold that is
 *                 nearly right; one that peaks at 100% is a page reload in the owner's eyes.
 *   rpc_waves     SERIAL read waves — reads that begin only after every earlier one finished.
 *                 This is the number that actually moves the feel; see below.
 *   chrome_nodes  element nodes added/removed OUTSIDE #main during the navigation — the sidebar,
 *                 app bar, rail and dock being rebuilt. 0 means the room did not move.
 *   side_survived did the .side element survive as the SAME node object?
 *
 * THE FINDING THIS TOOL EXISTS TO PRESERVE. DOM churn was never the bottleneck. v912's shell reuse
 * took chrome churn from 494 to 437 nodes per navigation and left commit time IDENTICAL (125ms
 * both). What costs is round trips stacked end to end: at 150ms per read, a one-wave page commits
 * in ~125ms and never shows the loading state, while Appointments (3 waves) and Record sale
 * (2 waves) took ~410ms and showed it 8 times out of 8. v948 collapsed both to one wave and the
 * loading state stopped appearing. If a page ever "feels like a website" again, count its waves
 * before touching its rendering.
 *
 * WHAT THIS DOES AND DOES NOT MEASURE. The data layer is the repo's own owner stub, so real RPC
 * latency is zero. MEASURE_RPC_MS injects a delay into the stub's thenable so a Singapore ->
 * Supabase round trip can be simulated; at 0ms the numbers are the CLIENT-SIDE FLOOR and the
 * loading state cannot even be OBSERVED, because it is replaced inside the same task. Read the
 * 0ms run as "how much work does a navigation do" and the 150ms run as "what does a merchant see".
 *
 * Run (0ms floor, then under a realistic round trip):
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/measure-navigation-feel.mjs
 *   MEASURE_RPC_MS=150 node tests/browser/measure-navigation-feel.mjs
 *
 * To compare against a baseline, point MEASURE_APP_DIR at another worktree's app/ and give it its
 * own MEASURE_PORT. The stub is loaded from that build's OWN tests/browser/fixtures/, so a build
 * is always measured against the stub it shipped with. Leftover `python3 -m http.server` processes
 * from an aborted run cause confusing "not serving a build" failures in later runs and in the
 * browser checks — this file kills its server in a finally, but `pkill -f 'http.server 49'` first
 * if a run was interrupted.
 *
 * See docs/qa/NAVIGATION-FEEL-MEASUREMENT.md for the recorded baselines.
 */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isDirectCliInvocation } from '../../scripts/quality/is-direct-cli-invocation.mjs';

const REPO_APP_DIR = fileURLToPath(new URL('../../app/', import.meta.url));

export async function measureNavigationFeel({
  appDir = REPO_APP_DIR,
  port = 4990,
  label = 'build',
  rounds = 6,
  width = 1280,
  height = 900,
  rpcMs = 0,
  nav = 'click',
  playwrightModule = process.env.PLAYWRIGHT_MODULE || 'playwright',
  executablePath = process.env.PLAYWRIGHT_EXECUTABLE_PATH,
} = {}) {
  const origin = `http://127.0.0.1:${port}`;
  const appUrl = pathToFileURL(appDir.endsWith('/') ? appDir : `${appDir}/`);
  /* The stub travels with the build, not with this file: measuring an older worktree with today's
     fixture would feed it read shapes it never had. If that build's fixture has moved, the two
     shape guards below turn the difference into a loud error rather than a silent skip. */
  const stubUrl = new URL('tests/browser/fixtures/owner-workspace-stub.mjs', new URL('../', appUrl));
  if (!existsSync(fileURLToPath(stubUrl))) {
    throw new Error(`no owner stub beside this build: expected ${fileURLToPath(stubUrl)} — MEASURE_APP_DIR must point at a checkout's app/`);
  }
  const { ownerWorkspaceStub } = await import(stubUrl.href);
  const pw = await import(playwrightModule);
  const chromium = pw.chromium || pw.default?.chromium;

  const server = spawn('python3', ['-m', 'http.server', String(port), '--bind', '127.0.0.1'],
    { cwd: appDir, stdio: 'ignore' });
  let browser = null;
  try {
    let serving = false;
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(`${origin}/app-business.js`)).ok) { serving = true; break; } } catch {}
      await new Promise(r => setTimeout(r, 100));
    }
    if (!serving) throw new Error(`nothing served app-business.js on ${origin} — is ${appDir} a built app/ dir, or is the port already taken?`);

    browser = await chromium.launch({
      headless: true,
      executablePath,
      args: ['--force-device-scale-factor=1'],
    });
    const ctx = await browser.newContext({ viewport: { width, height }, bypassCSP: true });
    await ctx.route('**/*', r => (r.request().url().startsWith(origin) && !r.request().url().includes('/sw.js'))
      ? r.continue() : r.abort());

    let stubSource = ownerWorkspaceStub({});
    if (rpcMs > 0) {
      // name the reads too, so "3 serial waves" becomes "these reads wait on that one"
      const rpcLine = 'const rpc=name=>chainable(()=>({data:rpcData(name),error:null}));';
      if (!stubSource.includes(rpcLine)) throw new Error('stub rpc shape changed — naming would be silently skipped');
      stubSource = stubSource.replace(rpcLine,
        'const rpc=name=>{const c=chainable(()=>({data:rpcData(name),error:null}));const t=c.then;' +
        'c.then=(res,rej)=>{const s=performance.now();return t(v=>{(window.__named=window.__named||[])' +
        '.push({n:name,s,e:performance.now()});return res(v)},rej)};return c};');
      const before = 'chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);';
      if (!stubSource.includes(before)) throw new Error('stub thenable shape changed — latency injection would be silently skipped');
      stubSource = stubSource.replace(before,
        `chain.then=(res,rej)=>{const s=performance.now();window.__rpc=window.__rpc||[];` +
        `return new Promise(r=>setTimeout(r,${rpcMs})).then(()=>{window.__rpc.push({s,e:performance.now()});return resolveOut(q)}).then(res,rej)};`);
    }
    await ctx.addInitScript(stubSource);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));

    await page.goto(`${origin}/index.html#/dashboard`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.appbar #profWho', { timeout: 30000 });
    await page.waitForTimeout(1200);

    const targets = await page.evaluate(() =>
      [...document.querySelectorAll('#navwrap a[href^="#/"]')].map(a => a.getAttribute('href')).slice(0, 5));
    if (!targets.length) throw new Error('no nav targets found — the workspace shell did not render');

    /* The probe lives in the page: it arms before the click and resolves on the frame the content
       commits, so nothing is inferred from Node-side wall clock. */
    await page.evaluate(() => {
      /* Arms SYNCHRONOUSLY and stores the promise. The first version returned the promise straight
         to Node and the click was issued without awaiting the arming — so page.evaluate often did
         not run until AFTER the navigation had already completed, and the probe then "measured" a
         finished page: 0 chrome mutations, the sidebar trivially "surviving" because the mark was
         set on the NEW node, and ~0ms. Every number it produced was of nothing happening. Arm,
         await the arming, then click. When a number is impossible, the instrument is wrong. */
      window.__arm = (targetHref) => { window.__result = window.__probe(targetHref); return true; };
      window.__probe = (targetHref) => new Promise(resolve => {
        const main0 = document.getElementById('main');
        const side0 = document.querySelector('.side');
        side0 && (side0.__probeMark = true);
        let chromeAdded = 0, chromeRemoved = 0, splashSeen = false, splashPeak = 0, paintAt = null;
        const byRegion = {};
        const outsideMain = node => {
          const main = document.getElementById('main');
          return node.nodeType === 1 && (!main || !main.contains(node)) && node !== main;
        };
        const mo = new MutationObserver(records => {
          for (const r of records) {
            for (const n of r.addedNodes) if (outsideMain(n)) chromeAdded += 1 + (n.querySelectorAll?.('*').length || 0);
            for (const n of r.removedNodes) {
              if (n.nodeType !== 1) continue;
              const size = 1 + (n.querySelectorAll?.('*').length || 0);
              chromeRemoved += size;
              // which region did it come from? attribute by the parent the record names.
              const host = r.target;
              const key = host?.id ? '#' + host.id
                : host?.className && typeof host.className === 'string' ? '.' + host.className.split(/\s+/)[0]
                : host?.nodeName?.toLowerCase() || '?';
              byRegion[key] = (byRegion[key] || 0) + size;
            }
          }
        });
        mo.observe(document.body, { childList: true, subtree: true });

        window.__rpc = []; window.__named = [];
        const t0 = performance.now();
        let done = false;
        const frame = () => {
          if (done) return;
          const main = document.getElementById('main');
          // was the loading state actually VISIBLE on this frame?
          const state = document.querySelector('.cui-route-state');
          if (state) {
            const op = parseFloat(getComputedStyle(state).opacity || '1');
            if (op > 0.01) splashSeen = true;
            if (op > splashPeak) splashPeak = op;     // how VISIBLE did it actually get?
          }
          if (paintAt === null && main && main.firstElementChild) paintAt = performance.now() - t0;
          const h1 = main && main.querySelector('h1');
          /* The new page's main, not merely the new hash. Clicking an <a href="#/x"> changes the
             hash SYNCHRONOUSLY, long before route() has rendered anything — so a condition of
             "hash matches and some h1 exists" commits on the OLD page still sitting on screen,
             reporting zero DOM churn and a sidebar that trivially survived because nothing had
             happened yet. A real route change installs a fresh <main>, so that node identity is
             the honest signal that the destination has actually rendered. */
          const committed = h1 && location.hash === targetHref && main !== main0
            && !main.querySelector('.cui-route-state');
          if (committed) {
            done = true;
            mo.disconnect();
            const side1 = document.querySelector('.side');
            resolve({
              paint_ms: paintAt === null ? null : Math.round(paintAt),
              commit_ms: Math.round(performance.now() - t0),
              splash_seen: splashSeen,
              splash_peak: Math.round(splashPeak * 100),
              chrome_added: chromeAdded,
              chrome_removed: chromeRemoved,
              side_survived: !!(side1 && side1.__probeMark),
              main_replaced: document.getElementById('main') !== main0,
              h1: (h1.textContent || '').trim().slice(0, 40),
              by_region: byRegion,
              /* Serial WAVES, not call count: sort the reads by start and count how many times a
                 read begins only after every earlier one has finished. That is the number of round
                 trips stacked end to end on the critical path — the thing latency multiplies. */
              rpc_calls: window.__rpc.length,
              named: [...window.__named].sort((a, b) => a.s - b.s).map(c => ({ n: c.n, s: Math.round(c.s - t0) })),
              rpc_waves: (() => {
                const c = [...window.__rpc].sort((a, b) => a.s - b.s);
                let waves = 0, openUntil = -1;
                for (const call of c) {
                  if (call.s >= openUntil - 1) { waves += 1; openUntil = call.e; }
                  else openUntil = Math.max(openUntil, call.e);
                }
                return waves;
              })(),
            });
            return;
          }
          requestAnimationFrame(frame);
        };
        requestAnimationFrame(frame);
        setTimeout(() => { if (!done) { done = true; mo.disconnect(); resolve({ timeout: true }); } }, 8000);
      });
    });

    const rows = [];
    for (let round = 0; round < rounds; round++) {
      for (const href of targets) {
        if (await page.evaluate(() => location.hash) === href) continue;
        await page.evaluate(h => window.__arm(h), href);   // armed and confirmed BEFORE the click
        /* nav=hash: the rail is itself display:none at mobile widths, so clicking it cannot be the
           navigation there. Setting location.hash exercises the same router entry — it is what the
           Back button and every in-app nav() call do — and is the only way to compare the two
           viewports on equal terms. */
        if (nav === 'hash') await page.evaluate(h => { location.hash = h; }, href);
        else await page.click(`#navwrap a[href="${href}"]`, { timeout: 8000 });
        const r = await page.evaluate(() => window.__result);
        if (!r.timeout) rows.push({ href, ...r });
        await page.waitForTimeout(120);
      }
    }
    if (!rows.length) throw new Error('every navigation timed out — nothing was measured');

    const med = xs => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : null; };
    const byHref = new Map();
    for (const r of rows) { if (!byHref.has(r.href)) byHref.set(r.href, []); byHref.get(r.href).push(r); }

    return {
      label,
      viewport: `${width}x${height}`,
      nav,
      rpc_latency_ms: rpcMs,
      navigations: rows.length,
      median_paint_ms: med(rows.map(r => r.paint_ms).filter(v => v !== null)),
      median_commit_ms: med(rows.map(r => r.commit_ms)),
      commit_ms_spread: (() => {
        const v = rows.map(r => r.commit_ms).sort((a, b) => a - b);
        return { min: v[0], p25: v[Math.floor(v.length * 0.25)], p75: v[Math.floor(v.length * 0.75)], max: v[v.length - 1] };
      })(),
      removed_by_region: (() => {
        const t = {};
        for (const r of rows) for (const [k, v] of Object.entries(r.by_region || {})) (t[k] = t[k] || []).push(v);
        return Object.fromEntries(Object.entries(t).map(([k, v]) => [k, med(v)]).sort((a, b) => b[1] - a[1]).slice(0, 6));
      })(),
      splash_seen_pct: Math.round(100 * rows.filter(r => r.splash_seen).length / rows.length),
      median_chrome_nodes_removed: med(rows.map(r => r.chrome_removed)),
      median_chrome_nodes_added: med(rows.map(r => r.chrome_added)),
      side_survived_pct: Math.round(100 * rows.filter(r => r.side_survived).length / rows.length),
      main_replaced_pct: Math.round(100 * rows.filter(r => r.main_replaced).length / rows.length),
      per_module: [...byHref].map(([href, rs]) => ({
        href,
        commit_ms: med(rs.map(r => r.commit_ms)),
        rpc_calls: med(rs.map(r => r.rpc_calls)),
        rpc_waves: med(rs.map(r => r.rpc_waves)),
        splash: rs.filter(r => r.splash_seen).length + '/' + rs.length,
        splash_peak_pct: Math.max(...rs.map(r => r.splash_peak || 0)),
        reads: (rs.find(r => (r.named || []).length) || {}).named || [],
        chrome_removed: med(rs.map(r => r.chrome_removed)),
      })),
      page_errors: errors.slice(0, 3),
    };
  } finally {
    /* Always, on the error paths too. A Chrome and an http.server left behind by an aborted run
       are why later runs report "not serving a build" and why browser checks fail spuriously. */
    if (browser) await browser.close().catch(() => {});
    server.kill();
  }
}

/* Not a test, but it lives under tests/ and it spawns a web server and a browser. node's own
   discovery is by FILENAME (*.test.mjs, *-test.*, test-*.*, *_test.*) and by directories named
   `test` — SINGULAR, which is why this repo's plural `tests/` is not swept — so this file is not
   discovered today. It is one rename away from being discovered, and the cost of that mistake here
   is a browser and a bound port in the middle of `npm test`. See V459. */
if (isDirectCliInvocation(import.meta.url)) {
  const report = await measureNavigationFeel({
    appDir: process.env.MEASURE_APP_DIR || REPO_APP_DIR,
    port: Number(process.env.MEASURE_PORT || 4990),
    label: process.env.MEASURE_LABEL || 'build',
    rounds: Number(process.env.MEASURE_ROUNDS || 6),
    width: Number(process.env.MEASURE_WIDTH || 1280),
    height: Number(process.env.MEASURE_HEIGHT || 900),
    rpcMs: Number(process.env.MEASURE_RPC_MS || 0),
    nav: process.env.MEASURE_NAV === 'hash' ? 'hash' : 'click',
  });
  process.stdout.write(`${JSON.stringify(report, null, 1)}\n`);
}
