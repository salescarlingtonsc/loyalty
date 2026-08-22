/* V451 — the app bar's tablet band: nothing in the header overlaps anything else.
 *
 * THE BUG (C-REG-011, the REG-003 pattern again). app/index.html carried a tablet header
 * compaction block — `@media(min-width:769px) and (max-width:1180px){ .appbar / .global-actions /
 * .global-search / .global-search-ic / .global-search-go / .global-quick / .global-act /
 * .dashboard-appbar-branch(+select) / .workspace-language-picker / …}` — 260 lines ABOVE the base
 * rules it was meant to narrow. A media query adds no specificity, so every declaration in it lost
 * to the later base rules at the same (0,1,0) specificity.
 *
 * Every declaration, that is, EXCEPT `.global-search input{display:none}` — the one property no
 * base rule sets. That single survivor is what made the symptom so odd: the search pill kept its
 * desktop `flex:0 1 340px` and its magnifier, lost its input, and kept a 44px `flex-shrink:0`
 * go-arrow. Below ~1040 the pill shrank to 15-43px while the arrow stayed 44px, so the arrow
 * overflowed its own parent and landed on top of the Record sale button.
 *
 * WHY THE BAND MATTERS, AND WHY THIS FILE PINS IT EXPLICITLY: the owner's own device is 1180, and
 * 1180 was CLEAR (the pill is 199px wide there — ugly, but not overlapping). v443 had already
 * relieved the 1180 symptom by removing the workspace switcher from the bar. A check pinned at
 * 1180 alone would therefore have passed straight through this bug. The overlap lives at
 * 961-1040px, so 961 / 1000 / 1024 are asserted by name.
 *
 * MEASURED PRE-FIX (real Chrome, appointments module enabled, #/dashboard):
 *    961px  search pill 280..295 (15px)  go-arrow 283..327  Record sale 303..427.5  -> 24.0px over
 *   1000px  search pill 280..299         go-arrow 285..329  Record sale 307..431.5  -> 22.0px over
 *   1024px  search pill 280..323         go-arrow 297..341  Record sale 331..455.5  -> 10.0px over
 *   1180px  search pill 280..479 (199px, input hidden — 140px of dead header)       -> clear
 * POST-FIX at every one of those widths: pill 48px, icon hidden, arrow 262..306, Record sale
 * 314..438.5 — 8px clear.
 *
 * WHAT THIS FILE PROVES, by measuring a real browser rather than reading source:
 *   A. at 900 / 961 / 1000 / 1024 / 1060 / 1100 / 1180 — the whole band plus its top edge — NO
 *      PAIR of the app bar's interactive children overlaps horizontally, and the bar does not
 *      overflow itself (scrollWidth == clientWidth).
 *   B. inside the compaction band the collapse actually happened: the search control is ~48px, its
 *      input and magnifier are display:none, and its go-arrow fits inside it.
 *   C. 834 (below the band: mobile header) and 1440 (above it: full desktop search) are
 *      no-regression anchors — 1440 must still have a visible, typable search input.
 *   D. the generic sweep is not vacuous: the bar really did render both "Record sale" and
 *      "New appointment", i.e. the crowded header, at every asserted width.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v451-appbar-band.mjs
 * V451_PORT moves it off 4483; V451_APP_DIR points it at another build (used to run the
 * pre-fix negative control against a checkout of the parent commit).
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {ownerWorkspaceStub} from './fixtures/owner-workspace-stub.mjs';

const ROOT=new URL('../../',import.meta.url);
const APP_DIR=process.env.V451_APP_DIR||fileURLToPath(new URL('app/',ROOT));
const PORT=Number(process.env.V451_PORT||4483);
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
    /* Serving SOMETHING is not serving THIS build — sibling worktrees run their own servers. */
    return (await r.text()).includes('V451');
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

/* Every INTERACTIVE child of the app bar, with its box — found by role, not by a hand-written list
   of class names, so a control added to the header later is covered by the same assertion. */
const measureSource=`(()=>{
  const bar=document.querySelector('.appbar');
  if(!bar)return {missing:'appbar'};
  const box=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,right:b.right,top:b.top,bottom:b.bottom,width:b.width,height:b.height}};
  const visible=el=>{const s=getComputedStyle(el);
    return s.display!=='none'&&s.visibility!=='hidden'&&el.getClientRects().length>0};
  const label=el=>{
    const cls=String(el.className||'').trim().split(/\\s+/).filter(Boolean).join('.');
    const text=(el.getAttribute('aria-label')||el.textContent||'').trim().replace(/\\s+/g,' ').slice(0,26);
    return el.tagName.toLowerCase()+(cls?'.'+cls:'')+(text?\` "\${text}"\`:'');
  };
  /* Only leaves: a wrapper legitimately contains its own children, so comparing a wrapper with
     what it wraps would report a false overlap. */
  const controls=[...bar.querySelectorAll('a[href],button,select,input,[role="button"]')]
    .filter(visible)
    .filter(el=>!el.querySelector('a[href],button,select,input,[role="button"]'))
    .map(el=>({sel:label(el),box:box(el)}));
  const search=bar.querySelector('.global-search');
  const input=bar.querySelector('.global-search input');
  const ic=bar.querySelector('.global-search-ic');
  const go=bar.querySelector('.global-search-go');
  const cs=el=>el?getComputedStyle(el):null;
  return {
    viewport:{width:innerWidth,height:innerHeight},
    bar:box(bar),barScrollWidth:bar.scrollWidth,barClientWidth:bar.clientWidth,
    controls,
    search:search&&visible(search)?{box:box(search),flex:cs(search).flex}:null,
    input:input?{display:cs(input).display,box:visible(input)?box(input):null}:null,
    ic:ic?{display:cs(ic).display}:null,
    go:go&&visible(go)?{box:box(go)}:null,
    labels:controls.map(c=>c.sel).join(' | '),
    docScrollWidth:(document.scrollingElement||document.documentElement).scrollWidth,
    docClientWidth:(document.scrollingElement||document.documentElement).clientWidth
  };
})`;

const fmt=b=>`x ${b.left.toFixed(0)}..${b.right.toFixed(0)}`;
/* Sub-pixel layout is real; 0.5px of touching is not an overlap a human can see. */
const overlapOf=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left);

const BAND_LOW=769,BAND_HIGH=1180;
/* The workspace shell's own compact threshold (owner ruling 2026-08-18, quoted in the stylesheet):
   at <=960 there is no room for a persistent rail, the quick actions leave the bar and the mobile
   search trigger replaces the desktop field. */
const SHELL_MOBILE_MAX=960;
/* 900 is the band's own lower reach on this shell; 961/1000/1024 are the widths that were
   BROKEN and are named here on purpose (see the header note about 1180 passing regardless). */
const BAND=[900,961,1000,1024,1060,1100,1180];
const ANCHORS=[834,1440];

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();
  const ownerStub=ownerWorkspaceStub();

  const open=async width=>{
    const context=await browser.newContext({viewport:{width,height:800},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(ownerStub);
    const page=await context.newPage();
    page.on('pageerror',e=>pageErrors.push(`${width}px: ${e}`));
    await page.goto(`${ORIGIN}/index.html#/dashboard`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('.appbar',{timeout:25000});
    /* The quick-action cluster is module-gated and only renders once get_my_modules resolves; it
       is present in the DOM (though display:none) on the compact shell too, so this is a valid
       "the shell has finished hydrating" signal at every width. */
    await page.waitForFunction(()=>{
      const bar=document.querySelector('.appbar');
      return !!bar&&/Record sale/.test(bar.textContent||'');
    },null,{timeout:25000});
    return {context,page};
  };

  /* STEP 0 — the stylesheet survives parsing intact.
     This exists because writing this fix broke it once: the explanatory comment above the moved
     block contained the literal `.global-*` followed by a slash, which CLOSED the comment early;
     everything after it became garbage declarations and the browser silently dropped the whole
     @media block. Nothing in the repo noticed — `npm run quality` passed, the file looked right
     in an editor, and only geometry caught it. So: count the top-level @media blocks in the
     source text and require the CSSOM to hold at least that many. A swallowed block, an
     unbalanced brace or a truncated comment all fail here, loudly, whoever causes them. */
  say('0. the <style> block parses without losing rules');
  {
    const {context,page}=await open(1180);
    const parsed=await page.evaluate(()=>{
      const style=[...document.querySelectorAll('style')].sort((a,b)=>b.textContent.length-a.textContent.length)[0];
      const sheet=[...document.styleSheets].find(s=>s.ownerNode===style);
      let mediaRules=0,total=0;
      try{for(const rule of sheet.cssRules){total++;if(rule.type===4)mediaRules++}}catch{return null}
      const text=style.textContent;
      /* Top-level @media only: nested ones live inside a rule body, and this file has none. */
      const sourceMedia=(text.match(/(^|\n)\s*@media/g)||[]).length;
      return {mediaRules,total,sourceMedia,
        hasBand:[...sheet.cssRules].some(r=>r.type===4&&/769px/.test(r.conditionText||'')
          &&/max-width:\s*1180px/.test(r.conditionText||''))};
    });
    assertTrue(parsed&&parsed.total>2000,
      `the production stylesheet parsed into ${parsed?parsed.total:0} top-level rules`);
    assertTrue(parsed.mediaRules>=parsed.sourceMedia,
      `every @media block in the source reached the CSSOM `
      +`(${parsed.sourceMedia} written, ${parsed.mediaRules} parsed) — a truncated comment or an `
      +`unbalanced brace silently eats one`);
    assertTrue(parsed.hasBand,
      'the 769-1180px header compaction block is one of them (this is the rule that was eaten)');
    await context.close();
  }

  let pairsChecked=0;
  for(const width of [...BAND,...ANCHORS]){
    say(`app bar at ${width}px`);
    const {context,page}=await open(width);
    const m=await page.evaluate(`(${measureSource})()`);
    assertTrue(!m.missing,`${width}: the app bar rendered`);

    /* D — the crowded header really is what is under test. Below the 960px shell threshold the
       quick-action cluster is deliberately pulled out of the bar (`.appbar>.global-actions
       {display:none!important}`), so that claim only applies to the desktop shell. */
    const desktopShell=width>SHELL_MOBILE_MAX;
    if(desktopShell)assertTrue(/Record sale/.test(m.labels)&&/appointment/i.test(m.labels),
      `${width}: the bar carries BOTH quick actions (${m.controls.length} interactive children)`);
    else assertTrue(!/Record sale/.test(m.labels),
      `${width}: the compact shell keeps the quick actions out of the bar `
      +`(${m.controls.length} interactive children)`);

    /* A — no pair of interactive children overlaps. */
    let worst=null;
    for(let i=0;i<m.controls.length;i++)for(let j=i+1;j<m.controls.length;j++){
      const a=m.controls[i],b=m.controls[j];
      pairsChecked++;
      const over=overlapOf(a.box,b.box);
      if(over>0.5&&(!worst||over>worst.over))worst={over,a,b};
    }
    assertTrue(!worst,
      worst
        ?`${width}: ${worst.a.sel} ${fmt(worst.a.box)} overlaps ${worst.b.sel} ${fmt(worst.b.box)} `
         +`by ${worst.over.toFixed(1)}px`
        :`${width}: no pair of the ${m.controls.length} interactive header controls overlaps`);
    assertTrue(m.barScrollWidth<=m.barClientWidth+1,
      `${width}: the bar does not overflow itself (scrollWidth ${m.barScrollWidth} `
      +`vs clientWidth ${m.barClientWidth})`);
    assertTrue(m.docScrollWidth<=m.docClientWidth+1,
      `${width}: and the page does not scroll horizontally (${m.docScrollWidth} into ${m.docClientWidth})`);

    /* B / C — did the band actually compact, and did the anchors stay uncompacted?
       The compaction band is 769-1180 by media query, but the SHELL swaps to its compact layout
       at 960 and takes the desktop search out of the bar entirely, so the visible band is
       961-1180. Below that only the no-overlap assertions above apply. */
    if(!desktopShell){
      assertTrue(!m.search,
        `${width}: the compact shell has no desktop search in the bar at all `
        +`(the mobile search trigger takes over) — nothing here to overlap`);
    }else if(width>=BAND_LOW&&width<=BAND_HIGH){
      assertTrue(m.search&&m.search.box.width<=56,
        `${width}: the search control collapsed to an icon button `
        +`(${m.search?m.search.box.width.toFixed(0):'—'}px, flex ${m.search?.flex}) — pre-fix it was `
        +`a 15-199px remnant of the 340px desktop pill`);
      assertTrue(m.input?.display==='none'&&m.ic?.display==='none',
        `${width}: its text input and magnifier are both hidden (input ${m.input?.display}, `
        +`icon ${m.ic?.display}) — pre-fix the magnifier stayed visible`);
      assertTrue(m.go&&m.go.box.left>=m.search.box.left-1&&m.go.box.right<=m.search.box.right+1,
        `${width}: the go-arrow ${m.go?fmt(m.go.box):'—'} sits INSIDE its own control `
        +`${fmt(m.search.box)} — this containment is what failed at 961-1024`);
    }else if(width>BAND_HIGH){
      assertTrue(m.input?.display!=='none'&&m.input?.box&&m.input.box.width>60,
        `${width}: above the band the real search input is still visible and typable `
        +`(${m.input?.box?m.input.box.width.toFixed(0):'—'}px) — no desktop regression`);
      assertTrue(m.search.box.width>200,
        `${width}: and the full search pill is back (${m.search.box.width.toFixed(0)}px)`);
    }
    await context.close();
  }

  assertTrue(pairsChecked>=100,
    `${pairsChecked} control pairs compared across ${BAND.length+ANCHORS.length} widths — `
    +`the sweep is not vacuous`);
  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`);
  process.stdout.write('\nV451 app bar band: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
