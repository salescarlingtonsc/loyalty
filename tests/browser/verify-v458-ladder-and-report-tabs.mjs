/* V458 — two containment failures Agent A measured, fixed and pinned.
 *
 * A-REG-011 · #/grow/tiers scrolled the whole PAGE sideways at every desktop width.
 *   `.grow-tier-ladder-stop-v343` is position:absolute + translateX(-50%) + min-width:92px, and
 *   the top tier is at left:100% by construction (it is the tier that defines the maximum), so it
 *   hangs ~46px past the ladder's right edge. `.grow-tier-ladder-v343` carried `overflow:auto`
 *   ONLY inside `@media(max-width:768px)`, so the ladder swallowed its own overflow on a phone and
 *   let it reach the document everywhere else. Measured by A:
 *     documentElement.scrollWidth - clientWidth = 4px at 1440 / 1280 / 1180 / 1024, 0px at <=900.
 *   Same shape as REG-003 — a containment rule scoped away from the widths that need it — except
 *   here the media query is too NARROW rather than defeated by a later rule.
 *
 * A-REG-012 · #/reports' fourth tab was unreachable at phone widths.
 *   `.section-subtabs-v200` is `overflow-x:auto` with `scrollbar-width:none` and a
 *   `::-webkit-scrollbar{display:none}` reset, i.e. it scrolls but says nothing about it. At 599
 *   the strip is 682px inside a 561px box and elementFromPoint at the fourth tab's centre returns
 *   MAIN; at 430 and 390 two tabs are unreachable. "Team Performance" lost its own rail row at
 *   V272, so this strip is its ONLY door — the report simply cannot be reached on a phone.
 *   The strip now wraps (flex-wrap is self-limiting: a strip that fits is untouched), which makes
 *   every tab hit-testable with no gesture at all. The original rule's stated reason for scrolling
 *   rather than wrapping is answered in the stylesheet next to the change.
 *
 * These are hit-tests and overflow measurements in a real browser, not source greps: the
 * assertion for A-REG-012 is that document.elementFromPoint at each tab's own centre lands on
 * that tab, which is the thing the owner could not do.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v458-ladder-and-report-tabs.mjs
 * V458_PORT moves it off 4483; V458_APP_DIR runs it against another build (the negative control
 * points it at a checkout of the parent commit).
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {ownerWorkspaceStub} from './fixtures/owner-workspace-stub.mjs';

const ROOT=new URL('../../',import.meta.url);
const APP_DIR=process.env.V458_APP_DIR||fileURLToPath(new URL('app/',ROOT));
const PORT=Number(process.env.V458_PORT||4483);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

let server=null;
const probe=async()=>{
  try{
    const r=await fetch(`${ORIGIN}/index.html`);
    if(!r.ok)return false;
    return (await r.text()).includes('.grow-tier-ladder-v343{');
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:APP_DIR,stdio:'ignore'});
  server.on('error',e=>process.stdout.write(`server spawn error: ${e}\n`));
  for(let i=0;i<80;i++){
    if(await probe())return;
    await new Promise(r=>setTimeout(r,100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving this build`);
};

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();
  const stub=ownerWorkspaceStub();

  const open=async(hash,width,waitFor)=>{
    const context=await browser.newContext({viewport:{width,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(stub);
    const page=await context.newPage();
    page.on('pageerror',e=>pageErrors.push(`${hash} @${width}: ${e}`));
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector(waitFor,{timeout:25000});
    await page.waitForTimeout(500);
    return {context,page};
  };

  /* --------------- A-REG-011: the tier ladder contains its own overhang --------------- */
  const LADDER_WIDTHS=[1440,1280,1180,1024,960,900,768,599,390];
  for(const width of LADDER_WIDTHS){
    say(`A-REG-011 · #/grow/tiers at ${width}px`);
    const {context,page}=await open('#/grow/tiers',width,'.grow-tier-ladder-v343');
    const m=await page.evaluate(()=>{
      const doc=document.scrollingElement||document.documentElement;
      const ladder=document.querySelector('.grow-tier-ladder-v343');
      const stops=[...ladder.querySelectorAll('.grow-tier-ladder-stop-v343')];
      const ladderBox=ladder.getBoundingClientRect();
      const cs=getComputedStyle(ladder);
      return {
        overflowX:cs.overflowX,overflowY:cs.overflowY,
        pageOverflow:doc.scrollWidth-doc.clientWidth,
        docScrollWidth:doc.scrollWidth,docClientWidth:doc.clientWidth,
        ladderOverflowX:ladder.scrollWidth-ladder.clientWidth,
        ladderOverflowY:ladder.scrollHeight-ladder.clientHeight,
        stops:stops.length,
        lastStopRight:stops.length?stops[stops.length-1].getBoundingClientRect().right:null,
        ladderRight:ladderBox.right,
        lastStopLeftPct:stops.length?stops[stops.length-1].style.left:null
      };
    });
    assertTrue(m.stops>=1,`the ladder rendered ${m.stops} stop(s), the last at left:${m.lastStopLeftPct}`);
    assertTrue(m.pageOverflow<=0,
      `@${width}: the PAGE does not scroll sideways (scrollWidth ${m.docScrollWidth} `
      +`vs clientWidth ${m.docClientWidth}) — A measured 4px here at 1024-1440`);
    /* The containment must not have been bought by clipping the labels. The stops legitimately
       paint ~6px below the ladder's own box, so the honest question is not "is there vertical
       overflow" (there is, by design) but "is that overflow silently cut off". It is not cut if
       the axis stays visible, and it is reachable if the ladder scrolls — anything else hides
       part of a tier label. This is exactly why the fix uses overflow-x:CLIP: `auto` or `hidden`
       on one axis forces the other to `auto`, and `hidden` would have cut those 6px. */
    const verticalSafe=m.overflowY==='visible'||m.overflowY==='auto'||m.overflowY==='scroll';
    assertTrue(verticalSafe,
      `@${width}: nothing is clipped vertically — overflow-x:${m.overflowX} leaves `
      +`overflow-y:${m.overflowY}, with ${m.ladderOverflowY}px of stop label painting below the box`);
    await context.close();
  }

  /* --------------- A-REG-012: every report tab is reachable --------------- */
  const TAB_WIDTHS=[390,430,599,768,834,1180,1440];
  let tabsHitTested=0;
  for(const width of TAB_WIDTHS){
    say(`A-REG-012 · #/reports tab strip at ${width}px`);
    const {context,page}=await open('#/reports',width,'.report-tabbar-v294 button,.report-tabbar-v294 a');
    const m=await page.evaluate(()=>{
      const strip=document.querySelector('.report-tabbar-v294');
      const tabs=[...strip.querySelectorAll('button,a')];
      const doc=document.scrollingElement||document.documentElement;
      /* THE assertion: at each tab's own centre, what does the browser say you would hit? This is
         precisely what the owner could not do — the fourth tab's centre returned MAIN. */
      const probes=tabs.map(tab=>{
        const box=tab.getBoundingClientRect();
        const x=Math.round(box.left+box.width/2),y=Math.round(box.top+box.height/2);
        const hit=document.elementFromPoint(x,y);
        return {
          label:(tab.textContent||'').trim().replace(/\s+/g,' ').slice(0,24),
          box:{left:box.left,right:box.right,width:box.width,height:box.height},
          reachable:!!hit&&(hit===tab||tab.contains(hit)),
          landedOn:hit?hit.tagName+(hit.className?'.'+String(hit.className).trim().split(/\s+/)[0]:''):'(nothing)'
        };
      });
      return {probes,
        stripScrollWidth:strip.scrollWidth,stripClientWidth:strip.clientWidth,
        stripHeight:strip.getBoundingClientRect().height,
        pageOverflow:doc.scrollWidth-doc.clientWidth};
    });
    assertTrue(m.probes.length>=4,
      `the strip carries ${m.probes.length} tabs (${m.probes.map(p=>p.label).join(' | ')})`);
    const unreachable=m.probes.filter(p=>!p.reachable);
    assertTrue(unreachable.length===0,
      unreachable.length
        ?`@${width}: ${unreachable.length} tab(s) unreachable — `
         +unreachable.map(p=>`"${p.label}" centre hits ${p.landedOn}`).join('; ')
        :`@${width}: all ${m.probes.length} tabs are hit-testable at their own centre `
         +`(strip ${m.stripScrollWidth}px content in ${m.stripClientWidth}px, `
         +`${m.stripHeight.toFixed(0)}px tall)`);
    tabsHitTested+=m.probes.length;
    assertTrue(m.stripScrollWidth<=m.stripClientWidth+1,
      `@${width}: and the strip needs no hidden horizontal scroll at all `
      +`(${m.stripScrollWidth} into ${m.stripClientWidth})`);
    assertTrue(m.pageOverflow<=0,`@${width}: the page does not scroll sideways`);
    await context.close();
  }

  assertTrue(tabsHitTested>=28,
    `${tabsHitTested} individual tab hit-tests across ${TAB_WIDTHS.length} widths`);
  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`);
  process.stdout.write('\nV458 tier ladder + report tabs: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
