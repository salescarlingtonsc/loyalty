/* nestly_v463 — owner ruling R3(c), 2026-08-23: BOTH customer stamp displays wrap at exactly five
 * per row, matching the workspace editor (five fixed tracks since v449).
 *
 * The two displays:
 *   1. the red hero card on a business page — .customer-hero-stamp-grid-v422, painted by
 *      customerHeroStampCardV422 once loadStampCardV323 answers. Before v463 its tracks were
 *      `repeat(auto-fit,28px)`, so the row filled whatever the hero happened to be wide and a
 *      15-stamp card was ONE long line on the phone the owner was holding.
 *   2. the stamp-card detail page — .customer-programme-stamp-rings, painted by
 *      customerStampQuestRingsV323 (and customerProgrammeStampRingsV310 before the v323 read
 *      answers). Before v463 it was `display:flex;flex-wrap:wrap`, i.e. it also wrapped at the
 *      container width.
 *
 * WHAT THIS MEASURES, IN A REAL CHROME, with the REAL bundles, the REAL router and the v446
 * in-page fixture supabase, at 390/520/834/1180/1440 and for cards of 6, 12 and 15 stamps:
 *   1. PER-ROW COUNTS: grouping the drawn slots by their rendered y, every row but the last holds
 *      exactly five, and the last holds the remainder — 6 is 5+1, 12 is 5/5/2, 15 is 5/5/5. Taken
 *      from getBoundingClientRect, not from the stylesheet, so a rule that stops matching is
 *      caught.
 *   2. NO OVERLAP between any two slots of a display.
 *   3. NO HORIZONTAL SCROLL on the page, and each display's own box stays inside its card.
 *   4. no uncaught page errors.
 *
 * NEGATIVE CONTROL, run before the fix was believed (V463_APP_DIR pointed at an origin/main
 * b290151 checkout, V463_PORT=4503, V463_PROBE_MARKER relaxed to the class name): 30 of the 30
 * row-count assertions fail, at EVERY width, and the measured shapes are the bug —
 *   6-stamp card   hero 6      detail 6      (one line; the owner's phone shows a single row)
 *   12-stamp card  hero 9/3    detail 8/4
 *   15-stamp card  hero 9/6    detail 8/7
 * against 5/1, 5/5/2 and 5/5/5 here. Note the two displays disagreed with each other as well as
 * with the editor, which is the part a screenshot of one of them could never show.
 *
 * This reuses tests/browser/v446-customer-fixture.mjs rather than standing up a second fixture;
 * the only thing added there is a stampSlots/stampFilled pair, defaulted to what v446 already
 * used, so every existing caller renders unchanged.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v463-customer-stamp-rows.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {customerFixtureSource,SLUG} from './v446-customer-fixture.mjs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=process.env.V463_APP_DIR||fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V463_PORT||4502);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const WIDTHS=[390,520,834,1180,1440];
const CARDS=[6,12,15];
const PER_ROW=5;

let step='(boot)';
let failures=0;
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition){failures++;process.stdout.write(`  FAIL - step ${step}: ${message}\n`);return false}
  process.stdout.write(`  ok - ${message}\n`);
  return true;
};

/* Serving SOMETHING is not serving THIS build. The v463 track list is the marker, so another
   worktree's server answering on this port cannot be mistaken for this tree. The chunk probe is
   NOT needed here — v463's customer half is a stylesheet change and app-customer.js is unchanged
   — but index.html must be this tree's. */
const MARKER=process.env.V463_PROBE_MARKER
  ||'.customer-hero-stamp-grid-v422{display:grid;grid-template-columns:repeat(5,28px)';
let server=null;
const probe=async()=>{
  try{
    const document=await fetch(`${ORIGIN}/index.html`);
    if(!document.ok)return false;
    if(!(await document.text()).includes(MARKER))return false;
    const chunk=await fetch(`${ORIGIN}/app-customer.js`);
    return chunk.ok;
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],
    {cwd:APP_DIR,stdio:'ignore'});
  server.on('error',error=>process.stdout.write(`server spawn error: ${error}\n`));
  for(let i=0;i<60;i++){
    if(await probe())return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving this build`);
};

/* In the page. Reports boxes; the node side does the comparing, so a failure prints the numbers
   that caused it. */
const measureSource=`(selector=>{
  const grid=document.querySelector(selector);
  if(!grid)return {missing:true};
  const box=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,top:b.top,right:b.right,bottom:b.bottom,width:b.width,height:b.height}};
  const slots=[...grid.children].filter(el=>{
    const b=el.getBoundingClientRect();
    return b.width>0&&b.height>0;
  }).map(el=>({box:box(el),label:String(el.textContent||'').trim().slice(0,8)}));
  /* Group by rendered y. Rows are compared with a tolerance because a slot carrying a raised gift
     glyph is the same row as one that is not. */
  const rows=[];
  for(const slot of slots){
    const row=rows.find(r=>Math.abs(r.top-slot.box.top)<=4);
    if(row)row.slots.push(slot); else rows.push({top:slot.box.top,slots:[slot]});
  }
  rows.sort((a,b)=>a.top-b.top);
  const overlaps=[];
  for(let i=0;i<slots.length;i++)for(let j=i+1;j<slots.length;j++){
    const a=slots[i].box,b=slots[j].box;
    const x=Math.min(a.right,b.right)-Math.max(a.left,b.left);
    const y=Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top);
    if(x>1&&y>1)overlaps.push({a:slots[i].label,b:slots[j].label,x:Math.round(x),y:Math.round(y)});
  }
  const card=grid.closest('.card,.customer-business-summary-v346,section')||grid.parentElement;
  const scroller=document.scrollingElement||document.documentElement;
  return {
    tracks:getComputedStyle(grid).gridTemplateColumns,
    display:getComputedStyle(grid).display,
    total:slots.length,
    counts:rows.map(r=>r.slots.length),
    grid:box(grid),card:card?box(card):null,overlaps,
    scrollWidth:scroller.scrollWidth,clientWidth:scroller.clientWidth
  };
})`;

const expectedRows=slots=>{
  const out=[];
  for(let left=slots;left>0;left-=PER_ROW)out.push(Math.min(PER_ROW,left));
  return out;
};

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH
    ||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();

  const open=async(width,hash,fixtureOptions)=>{
    const context=await browser.newContext({viewport:{width,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(customerFixtureSource(fixtureOptions));
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`${hash} ${width}: ${error}`));
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('.customer-shell .customer-primary-nav',{timeout:25000});
    return {context,page};
  };

  const check=async(page,selector,{width,slots,what})=>{
    await page.waitForFunction(s=>{
      const el=document.querySelector(s);
      return !!el&&el.children.length>0;
    },selector,{timeout:20000});
    const m=await page.evaluate(`(${measureSource})(${JSON.stringify(selector)})`);
    if(m.missing){assertTrue(false,`${width} / ${slots} stamps: ${what} is not on the page`);return}
    assertTrue(m.total===slots,
      `${width} / ${slots} stamps: ${what} draws all ${slots} slots (got ${m.total})`);
    const want=expectedRows(slots);
    assertTrue(JSON.stringify(m.counts)===JSON.stringify(want),
      `${width} / ${slots} stamps: ${what} wraps ${want.join('/')} `
      +`(measured ${m.counts.join('/')}, tracks ${m.tracks})`);
    assertTrue(m.overlaps.length===0,
      `${width} / ${slots} stamps: ${what} — no two slots overlap`
      +(m.overlaps.length?` — ${JSON.stringify(m.overlaps.slice(0,3))}`:''));
    assertTrue(m.scrollWidth<=m.clientWidth+1,
      `${width} / ${slots} stamps: ${what} — the page does not scroll sideways `
      +`(${m.scrollWidth} vs ${m.clientWidth})`);
    if(m.card){
      assertTrue(m.grid.right<=m.card.right+1&&m.grid.left>=m.card.left-1,
        `${width} / ${slots} stamps: ${what} stays inside its card `
        +`(grid ${m.grid.left.toFixed(0)}..${m.grid.right.toFixed(0)} vs `
        +`card ${m.card.left.toFixed(0)}..${m.card.right.toFixed(0)})`);
    }
  };

  /* Both displays live on the business page, so one load per (card length, width) measures the
     pair. The hero only paints its stamp card when stamps is the LIVE accruing programme
     (customerBusinessHeroModeV386 prefers points whenever points is running), which is what
     pointsActive:false makes the fixture describe. */
  for(const slots of CARDS){
    for(const width of WIDTHS){
      say(`${slots}-stamp card at ${width}x900`);
      const {context,page}=await open(width,`#/wallet/${SLUG}`,
        {withStamps:true,pointsActive:false,stampSlots:slots,stampFilled:Math.min(slots,3)});
      await check(page,'.customer-hero-stamp-grid-v422',
        {width,slots,what:'the red hero card'});
      /* The stamp card's own detail lives inside the "Rewards" section page, which is
         display:none until the customer taps its tile. Resolved from the DOM and clicked the way
         a customer would, never by calling the handler — a display measured on a hidden element
         is every rect at 0 and would pass anything. */
      await page.waitForFunction(
        () => !!document.querySelector('[data-business-shortcut-v347="rewards"]'),
        null,{timeout:20000});
      await page.evaluate(
        () => {document.querySelector('[data-business-shortcut-v347="rewards"]').click()});
      await page.waitForFunction(() => {
        const el = document.querySelector(
          '[data-programme-card="stamps"] .customer-programme-stamp-rings');
        return !!el && el.getBoundingClientRect().height > 0;
      },null,{timeout:20000});
      await check(page,'[data-programme-card="stamps"] .customer-programme-stamp-rings',
        {width,slots,what:'the stamp-card detail'});
      await context.close();
    }
  }

  say('no uncaught page errors');
  assertTrue(pageErrors.length===0,`no page errors — ${JSON.stringify(pageErrors.slice(0,4))}`);
}catch(error){
  failures++;
  process.stdout.write(`FAIL - step ${step}: ${error&&error.stack||error}\n`);
}finally{
  await browser.close();
  if(server)server.kill();
}
process.stdout.write(failures?`\nV463 FAILED (${failures})\n`:'\nV463 OK\n');
process.exit(failures?1:0);
