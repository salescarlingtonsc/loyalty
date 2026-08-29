/* nestly_v612 — the four period options sit on ONE line.
 *
 * Owner, photo 4, twice: the four options ringed as a stacked list, "make into sub tab so cleaner",
 * then "instead of drop down for last week/this month/last month -> put it right side of this week".
 *
 * v603 answered it by setting flex-wrap:nowrap on the strip, and MEASURING afterwards showed the
 * strip was still 204px tall with the buttons in four rows — because the element was not flex at
 * all. `.v150-filterbar>div` (nestly_v584) turns every direct child of a filter bar into a
 * two-ROW grid, which is right for a label-over-input cell and wrong for a segmented control: the
 * segment became a one-column grid and stacked its buttons. A grep for the rule would have said the
 * fix shipped; only measuring said it had not.
 *
 * So this file measures. It loads the shipped stylesheet and the exact markup the filter bar
 * renders, at five widths, and asserts the four buttons share one row.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<repo>/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v612-period-strip-one-line.mjs
 */
import {spawn} from 'node:child_process';
import {cp,mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {OUTPUTS} from '../../scripts/quality/split-app-bundle.mjs';
import {build} from '../../scripts/quality/stamp-app-bundle.mjs';
import {fileURLToPath} from 'node:url';
const ROOT=fileURLToPath(new URL('../../',import.meta.url));
const pw=await import(process.env.PLAYWRIGHT_MODULE);
const chromium=pw.chromium||pw.default?.chromium;
const PORT=Number(process.env.V612_PORT||4612), ORIGIN=`http://127.0.0.1:${PORT}`;
const dir=await mkdtemp(path.join(tmpdir(),'css-'));
await cp(path.join(ROOT,'app'),dir,{recursive:true});
const {chunks,stamped}=await build(ROOT);
for(const [s,t] of Object.entries(OUTPUTS)) await writeFile(path.join(dir,path.basename(t)),chunks[s]);
await writeFile(path.join(dir,'index.html'),stamped);
/* A bare page that loads ONLY the shipped stylesheet, then the exact markup the Rewards Overview
   filter bar renders. No app boot, so nothing but the CSS decides the layout. */
await writeFile(path.join(dir,'probe.html'),`<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="/app.css"></head><body>
<div style="width:VIEWW px"></div>
<div class="card"><div class="v150-filterbar grow-usage-filter-v386">
  <div><label for="a">From</label><input id="a" type="date" value="2026-08-24"></div>
  <div><label for="b">To</label><input id="b" type="date" value="2026-08-29"></div>
  <div class="row"><button class="btn sm">Apply</button><button class="btn ghost sm">Clear</button></div>
  <div class="v150-segment grow-usage-quick-v388" role="group" aria-label="Quick date ranges">
    <button type="button" aria-pressed="true">This week</button>
    <button type="button" aria-pressed="false">Last week</button>
    <button type="button" aria-pressed="false">This month</button>
    <button type="button" aria-pressed="false">Last month</button>
  </div>
</div></div></body></html>`);
const server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
await new Promise(r=>setTimeout(r,1200));
const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH});
let failures=0;
for(const w of [1440,1180,900,760,600]){
  const ctx=await browser.newContext({viewport:{width:w,height:800}});
  const page=await ctx.newPage();
  await page.goto(`${ORIGIN}/probe.html`,{waitUntil:'load'});
  await page.waitForTimeout(300);
  const r=await page.evaluate(()=>{
    const el=document.querySelector('.grow-usage-quick-v388');
    const box=el.getBoundingClientRect();
    const kids=[...el.querySelectorAll('button')].map(b=>Math.round(b.getBoundingClientRect().top));
    return {h:Math.round(box.height),rows:new Set(kids).size};
  });
  if(r.rows!==1)failures++;
  console.log(`  viewport ${String(w).padStart(4)}px  strip height ${String(r.h).padStart(3)}px  rows of buttons: ${r.rows}  ${r.rows===1?'ONE LINE ✓':'WRAPPED ✗'}`);
  await ctx.close();
}
await browser.close(); server.kill();
if(failures){process.stdout.write(`\nFAILED: the strip wraps at ${failures} width(s)\n`);process.exitCode=1}
else process.stdout.write('\nV612 period strip: one line at every width\n');
