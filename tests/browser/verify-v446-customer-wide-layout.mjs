/* V446 — the customer wallet's reward row is an intentional layout at EVERY width.
 *
 * THE BUG (REG-002, confirmed live at ~1400 and reproduced here at every width from 641 up).
 * The reward row's three-column variant is gated on `@media(min-width:641px)` — the VIEWPORT —
 * but the customer shell caps `.wallet-inner` at 390px on every viewport, so the row's own box is
 * 324px wide whatever the window does. Above 640 the row therefore tried to fit
 * `64px minmax(0,1fr) auto` into 324px: the `auto` action track sizes to the claim button's
 * max-content (174.9px measured), the photo takes 64, the gaps 24, the padding 26 — and the copy
 * column, explicitly floored at 0 by `minmax(0,1fr)`, is left with what is over.
 *
 * MEASURED on origin/main (dcb6a53) at 1180x900, wallet -> Points & gifts:
 *   grid-template-columns: 64px 31.1406px 174.859px
 *   reward name box 31.1 x 208  ("Free Kopi Set Breakfast Platter" broken letter by letter,
 *     because .customer-reward-name-v339 carries overflow-wrap:anywhere)
 *   description box 31.1 x 180
 *   "Ready to claim" pill x 519..622.4 vs claim button x 562.1..737 — 60px of overlap, which is
 *     the owner's "Show QR at counter floats over the Ready badge".
 * At 390 the same card measures `64px 218px` and reads correctly. It is not a wide-screen
 * refinement that went wrong; it is a layout that was never possible at the size it was applied to.
 *
 * WHAT THIS FILE PROVES, BY MEASURING A REAL BROWSER at 390/430/480/520/599/834/1024/1180/1440,
 * with the REAL bundles, the REAL router and a fixture supabase (two claimable rewards, one with
 * a long multi-word name):
 *   1. NO LETTER-WRAP: every reward name and description is rendered in a box at least as wide as
 *      its own longest word, so `overflow-wrap:anywhere` has nothing to break; and the name fits
 *      in a sane number of lines.
 *   2. NO OVERLAP between the controls on a card — the Ready pill, the cost, the copy and the
 *      claim button — nor between any two independent interactive controls on the surface.
 *   3. THE DOCK NEVER COVERS TAPPABLE CONTENT: scrolled to the very end of the page, no link,
 *      button, tab or summary intersects the bottom dock or its raised Scan FAB. (Mid-scroll
 *      overlap is what a fixed dock IS; content trapped under it at maximum scroll is the bug.)
 *   4. ONE VISIBLE HEADING PER TITLE: opening a shortcut page cannot print its own title twice,
 *      on the points tile AND on the stamps tile (whose page is the "Rewards" the owner saw
 *      doubled).
 *   5. no uncaught page errors, and the page never scrolls sideways.
 *
 * NEGATIVE CONTROL: run this against origin/main and step 1/2 fail at 1180 (and at every width
 * from 641 up). Verified before the fix was written.
 *
 * Nothing here touches reward availability or arithmetic: customerRewardCanRedeem decides which
 * cards exist and this file only measures the boxes they render in.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v446-customer-wide-layout.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {customerFixtureSource,SLUG,LONG_REWARD_NAME} from './v446-customer-fixture.mjs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=process.env.V446_APP_DIR||fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V446_PORT||4482);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const WIDTHS=[390,430,480,520,599,834,1024,1180,1440];

let step='(boot)';
let failures=0;
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition){failures++;process.stdout.write(`  FAIL - step ${step}: ${message}\n`);return false}
  process.stdout.write(`  ok - ${message}\n`);
  return true;
};

let server=null;
/* Serving SOMETHING is not serving THIS build. The V446 container rule is the marker, so another
   worktree's server answering on this port cannot be mistaken for this tree.
   V446_PROBE_MARKER exists so the NEGATIVE CONTROL can point this same file at an unfixed tree —
   the fix's own marker is absent there by definition, and a readiness probe that refuses to start
   would look like a passing run. */
const MARKER=process.env.V446_PROBE_MARKER||'@container rewardrow (min-width:460px)';
/* And the CHUNK marker. index.html is the source file; the customer surface actually runs from
   app-customer.js, which is GENERATED from app.js — a server rooted at a tree whose stylesheet is
   current but whose chunks are stale answers 200 to an index.html probe and then runs last week's
   JavaScript. That cost a debugging round here, so both halves are checked. */
const CHUNK_MARKER=process.env.V446_PROBE_CHUNK_MARKER||'nestly_v446 (REG-002';
const probe=async()=>{
  try{
    const document=await fetch(`${ORIGIN}/index.html`);
    if(!document.ok||!(await document.text()).includes(MARKER))return false;
    const chunk=await fetch(`${ORIGIN}/app-customer.js`);
    if(!chunk.ok)return false;
    return (await chunk.text()).includes(CHUNK_MARKER);
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:APP_DIR,stdio:'ignore'});
  server.on('error',error=>process.stdout.write(`server spawn error: ${error}\n`));
  for(let i=0;i<60;i++){
    if(await probe())return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving this build`);
};

/* ------------------------------------------------------------------ in-page measurement ----- */
/* Everything below runs in the page. It reports boxes and rendered LINE BOXES; the node side does
   the comparing, so a failure prints the numbers that caused it. */
const measureSource=`(()=>{
  const box=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,top:b.top,right:b.right,bottom:b.bottom,width:b.width,height:b.height}};
  const visible=el=>{
    const style=getComputedStyle(el);
    if(style.display==='none'||style.visibility==='hidden'||Number(style.opacity)===0)return false;
    const b=el.getBoundingClientRect();
    return b.width>0&&b.height>0;
  };
  /* Rendered line boxes, from a Range over the element's own text. getClientRects() on a block
     element returns ONE rect however many lines it drew, which is why this uses a Range. */
  const lineTops=el=>{
    const range=document.createRange();
    range.selectNodeContents(el);
    const tops=new Set();
    for(const rect of range.getClientRects()){
      if(rect.width<=0||rect.height<=0)continue;
      tops.add(Math.round(rect.top));
    }
    range.detach&&range.detach();
    return tops.size;
  };
  /* The width the LONGEST WORD needs. If the element's content box is at least this wide,
     overflow-wrap:anywhere has nothing it can break, so a letter-wrap is impossible by
     construction rather than by eyeballing a screenshot. */
  const ruler=document.createElement('span');
  ruler.style.cssText='position:absolute;left:-9999px;top:0;white-space:pre;visibility:hidden';
  document.body.appendChild(ruler);
  const longestWord=el=>{
    const style=getComputedStyle(el);
    for(const prop of ['fontStyle','fontVariant','fontWeight','fontStretch','fontSize',
      'fontFamily','letterSpacing','textTransform'])ruler.style[prop]=style[prop];
    let widest=0,word='';
    for(const candidate of String(el.textContent||'').split(/\\s+/)){
      if(!candidate)continue;
      ruler.textContent=candidate;
      const w=ruler.getBoundingClientRect().width;
      if(w>widest){widest=w;word=candidate}
    }
    return {width:widest,word};
  };
  const textBox=el=>el?{box:box(el),lines:lineTops(el),longest:longestWord(el),
    text:String(el.textContent||'').trim().slice(0,60)}:null;

  const surface=document.querySelector('.customer-shell.customer-surface')||document.body;
  const nav=document.querySelector('.customer-primary-nav');
  const fab=document.querySelector('.customer-nav-scan-fab');

  /* Reward cards, wherever they are mounted (main page or shortcut page). */
  const cards=[...document.querySelectorAll('.customer-rewards-carousel-v337 .wallet-reward')]
    .filter(visible).map(card=>({
      box:box(card),
      columns:getComputedStyle(card).gridTemplateColumns,
      name:textBox(card.querySelector('.customer-reward-name-v339')),
      cost:textBox(card.querySelector('.customer-reward-cost-v339')),
      description:textBox(card.querySelector('p.muted.small')),
      pill:card.querySelector('.customer-reward-card-head-v339 .pill')
        ?box(card.querySelector('.customer-reward-card-head-v339 .pill')):null,
      action:card.querySelector('.wallet-reward-actions .btn')
        ?box(card.querySelector('.wallet-reward-actions .btn')):null
    }));

  /* Every independent interactive control on the surface, EXCLUDING the fixed dock (which is
     measured separately, at maximum scroll) and excluding pairs where one contains the other. */
  const interactiveSelector='a[href],button,summary,input,select,textarea,[role="tab"],[tabindex]:not([tabindex="-1"])';
  const controls=[...surface.querySelectorAll(interactiveSelector)]
    .filter(el=>visible(el)&&!(nav&&nav.contains(el))&&!el.hasAttribute('disabled'))
    .map(el=>({box:box(el),
      selector:el.tagName.toLowerCase()
        +(el.id?'#'+el.id:'')
        +(el.className&&typeof el.className==='string'?'.'+el.className.trim().split(/\\s+/).slice(0,2).join('.'):''),
      label:String(el.getAttribute('aria-label')||el.textContent||'').trim().slice(0,42),
      el}));
  const overlaps=[];
  for(let i=0;i<controls.length;i++)for(let j=i+1;j<controls.length;j++){
    const a=controls[i],b=controls[j];
    if(a.el.contains(b.el)||b.el.contains(a.el))continue;
    const x=Math.min(a.box.right,b.box.right)-Math.max(a.box.left,b.box.left);
    const y=Math.min(a.box.bottom,b.box.bottom)-Math.max(a.box.top,b.box.top);
    if(x>2&&y>2)overlaps.push({a:a.selector+' "'+a.label+'"',b:b.selector+' "'+b.label+'"',
      x:Math.round(x),y:Math.round(y)});
  }

  /* Headings that are actually painted, so a duplicate title is a measured fact. */
  /* A heading that HOSTS A CONTROL is a card label with its own affordance (the points card's
     expiry "?" lives inside its h2), not a page heading — removing it would take the control with
     it, so it is reported separately rather than counted as a duplicate title. */
  const headings=[...document.querySelectorAll('h1,h2,h3')].filter(visible)
    .map(h=>({level:h.tagName,text:String(h.textContent||'').trim(),
      hostsControl:!!h.querySelector('button,a[href],input,select')}));

  const scroller=document.scrollingElement||document.documentElement;
  ruler.remove();
  return {cards,overlaps,headings,
    nav:nav?box(nav):null,fab:fab?box(fab):null,
    surface:box(surface),
    controls:controls.map(c=>({box:c.box,selector:c.selector,label:c.label})),
    scrollWidth:scroller.scrollWidth,clientWidth:scroller.clientWidth,
    viewport:{width:innerWidth,height:innerHeight}};
})`;

/* At maximum scroll, is anything tappable trapped under the dock? */
const dockSweepSource=`(()=>{
  const scroller=document.scrollingElement||document.documentElement;
  scroller.scrollTop=Math.max(0,scroller.scrollHeight-scroller.clientHeight);
  const nav=document.querySelector('.customer-primary-nav');
  const fab=document.querySelector('.customer-nav-scan-fab');
  if(!nav)return {missing:true};
  const box=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,top:b.top,right:b.right,bottom:b.bottom,width:b.width,height:b.height}};
  const navBox=box(nav),fabBox=fab?box(fab):null;
  /* The dock's real footprint is the union of the bar and the FAB that rides 15px above it. */
  const dock={left:Math.min(navBox.left,fabBox?fabBox.left:navBox.left),
    right:Math.max(navBox.right,fabBox?fabBox.right:navBox.right),
    top:Math.min(navBox.top,fabBox?fabBox.top:navBox.top),
    bottom:Math.max(navBox.bottom,fabBox?fabBox.bottom:navBox.bottom)};
  const visible=el=>{
    const style=getComputedStyle(el);
    if(style.display==='none'||style.visibility==='hidden')return false;
    const b=el.getBoundingClientRect();
    return b.width>0&&b.height>0;
  };
  const surface=document.querySelector('.customer-shell.customer-surface')||document.body;
  const trapped=[];
  for(const el of surface.querySelectorAll('a[href],button,summary,input,select,[role="tab"]')){
    if(nav.contains(el)||!visible(el)||el.hasAttribute('disabled'))continue;
    const b=el.getBoundingClientRect();
    const x=Math.min(b.right,dock.right)-Math.max(b.left,dock.left);
    const y=Math.min(b.bottom,dock.bottom)-Math.max(b.top,dock.top);
    if(x>2&&y>2)trapped.push({selector:el.tagName.toLowerCase()+(el.className&&typeof el.className==='string'?'.'+el.className.trim().split(/\\s+/)[0]:''),
      label:String(el.getAttribute('aria-label')||el.textContent||'').trim().slice(0,42),
      overlap:{x:Math.round(x),y:Math.round(y)},box:{top:Math.round(b.top),bottom:Math.round(b.bottom)}});
  }
  /* Content length decides whether a page HAPPENS to end under the dock; the surface's own bottom
     padding decides whether it CAN. That is the invariant, and it is independent of the fixture:
     the reserved strip must be at least as tall as the dock's footprint above the viewport floor
     (the bar plus the Scan FAB that rides above it). */
  const surfaceStyle=getComputedStyle(surface);
  return {dock,trapped,scrollTop:scroller.scrollTop,
    reservedBottom:parseFloat(surfaceStyle.paddingBottom)||0,
    dockFootprint:innerHeight-dock.top,
    scrollHeight:scroller.scrollHeight,clientHeight:scroller.clientHeight};
})`;

const fmt=b=>`x ${b.left.toFixed(0)}..${b.right.toFixed(0)} y ${b.top.toFixed(0)}..${b.bottom.toFixed(0)}`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();

  const open=async(width,height,hash,fixtureOptions)=>{
    const context=await browser.newContext({viewport:{width,height},bypassCSP:true});
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

  /* Opens the business profile, then taps the tile whose page holds the reward list — the same
     control a customer taps, resolved from the DOM rather than by calling the handler. */
  const openRewardShortcut=async(page,action)=>{
    await page.waitForFunction(
      selector=>!!document.querySelector(selector),
      `[data-business-shortcut-v347="${action}"]`,{timeout:20000});
    await page.evaluate(a=>{document.querySelector(`[data-business-shortcut-v347="${a}"]`).click()},action);
    await page.waitForFunction(()=>{
      const shortcut=document.getElementById('customerBusinessShortcutPageV348');
      return !!shortcut&&shortcut.hidden===false
        &&!!shortcut.querySelector('.customer-rewards-carousel-v337 .wallet-reward');
    },null,{timeout:20000});
  };

  for(const width of WIDTHS){
    say(`reward row geometry at ${width}x900`);
    const {context,page}=await open(width,900,`#/wallet/${SLUG}`,{});
    /* The business PROFILE first — the shortcut page below carries 100px of its own bottom
       padding, so measuring only that would never see the shell's own clearance. */
    await page.waitForFunction(()=>!!document.querySelector('[data-business-shortcut-v347]'),null,{timeout:20000});
    const profileDock=await page.evaluate(dockSweepSource+'()');
    assertTrue(!profileDock.missing&&profileDock.trapped.length===0,
      `${width}: business profile — nothing tappable trapped under the dock at maximum scroll`
      +(profileDock.trapped?.length?` — ${JSON.stringify(profileDock.trapped.slice(0,4))}`:''));
    /* THE INVARIANT, which no fixture length can hide: the surface reserves at least the dock's
       own footprint at the bottom, so a page whose content happens to end there cannot be
       covered. */
    assertTrue(profileDock.reservedBottom>=profileDock.dockFootprint,
      `${width}: the customer surface reserves ${profileDock.reservedBottom.toFixed(0)}px at the `
      +`bottom for a dock whose footprint is ${profileDock.dockFootprint.toFixed(0)}px`);
    await page.evaluate(()=>{(document.scrollingElement||document.documentElement).scrollTop=0});
    await openRewardShortcut(page,'points');
    const measured=await page.evaluate(measureSource+'()');

    assertTrue(measured.cards.length===2,
      `${width}: both claimable rewards render as rows (${measured.cards.length}) — `
      +`columns ${measured.cards[0]?.columns}`);

    for(const [index,card] of measured.cards.entries()){
      for(const [field,part] of [['name',card.name],['description',card.description]]){
        if(!part)continue;
        /* THE LETTER-WRAP ASSERTION. Not "does it look right" — the box is compared against the
           width its own longest word needs. */
        assertTrue(part.box.width>=part.longest.width-0.5,
          `${width}: reward ${index} ${field} box is ${part.box.width.toFixed(0)}px, `
          +`wide enough for its longest word "${part.longest.word}" (${part.longest.width.toFixed(0)}px)`);
      }
      if(card.name)assertTrue(card.name.lines<=3,
        `${width}: reward ${index} name "${card.name.text}" draws ${card.name.lines} line(s), not a letter ladder`);
      if(card.description)assertTrue(card.description.lines<=6,
        `${width}: reward ${index} description draws ${card.description.lines} line(s)`);
      /* The owner's "Show QR at counter floats over the Ready badge". */
      if(card.pill&&card.action){
        const x=Math.min(card.pill.right,card.action.right)-Math.max(card.pill.left,card.action.left);
        const y=Math.min(card.pill.bottom,card.action.bottom)-Math.max(card.pill.top,card.action.top);
        assertTrue(!(x>2&&y>2),
          `${width}: reward ${index} Ready pill ${fmt(card.pill)} is clear of the claim button ${fmt(card.action)}`);
      }
    }

    assertTrue(measured.overlaps.length===0,
      `${width}: no two independent controls on the surface overlap`
      +(measured.overlaps.length?` — ${JSON.stringify(measured.overlaps.slice(0,4))}`:''));
    assertTrue(measured.scrollWidth<=measured.clientWidth+1,
      `${width}: the page does not scroll sideways (${measured.scrollWidth} into ${measured.clientWidth})`);

    /* THE DOCK, at the very bottom of the page. */
    const dock=await page.evaluate(dockSweepSource+'()');
    assertTrue(!dock.missing&&dock.trapped.length===0,
      `${width}: at maximum scroll nothing tappable is trapped under the dock `
      +`(dock y ${dock.dock?.top.toFixed(0)}..${dock.dock?.bottom.toFixed(0)})`
      +(dock.trapped?.length?` — ${JSON.stringify(dock.trapped.slice(0,4))}`:''));

    /* One heading per title. */
    const counts=new Map();
    for(const heading of measured.headings){
      if(heading.hostsControl)continue;
      counts.set(heading.text,(counts.get(heading.text)||0)+1);
    }
    const doubled=[...counts.entries()].filter(([,n])=>n>1);
    assertTrue(doubled.length===0,
      `${width}: no heading text is printed twice on the Points & gifts page`
      +(doubled.length?` — ${JSON.stringify(doubled)}`:'')
      +` (headings: ${measured.headings.map(h=>h.level+':'+h.text).join(' | ')})`);

    await context.close();
  }

  /* --------- the STAMPS tile, whose page is the "Rewards" the owner saw doubled ------------- */
  for(const width of [390,834,1180]){
    say(`stamp-card shortcut page at ${width}x900`);
    const {context,page}=await open(width,900,`#/wallet/${SLUG}`,{withStamps:true});
    await openRewardShortcut(page,'rewards');
    const measured=await page.evaluate(measureSource+'()');
    const rewardsHeadings=measured.headings.filter(h=>h.text==='Rewards');
    assertTrue(rewardsHeadings.length<=1,
      `${width}: "Rewards" is printed ${rewardsHeadings.length} time(s) on the stamp-card page `
      +`(headings: ${measured.headings.map(h=>h.level+':'+h.text).join(' | ')})`);
    for(const [index,card] of measured.cards.entries()){
      if(!card.name)continue;
      assertTrue(card.name.box.width>=card.name.longest.width-0.5,
        `${width}: stamps page reward ${index} name box ${card.name.box.width.toFixed(0)}px fits `
        +`"${card.name.longest.word}" (${card.name.longest.width.toFixed(0)}px)`);
    }
    assertTrue(measured.overlaps.length===0,
      `${width}: stamps page has no overlapping controls`
      +(measured.overlaps.length?` — ${JSON.stringify(measured.overlaps.slice(0,4))}`:''));
    await context.close();
  }

  /* --------- the three-column row is a DECISION, not a deletion ---------------------------- */
  /* The @container rule has to be reachable, or "stacked everywhere" would be indistinguishable
     from having deleted the wide layout. The shell's 390px cap is lifted in the page — nothing
     else changes — and the row is measured again: three columns, and a copy track that is still
     a readable measure rather than whatever the action track left over. */
  say('the wide row returns when the ROW is wide enough, and its copy column stays readable');
  {
    const {context,page}=await open(1180,900,`#/wallet/${SLUG}`,{});
    await openRewardShortcut(page,'points');
    await page.addStyleTag({content:'.customer-shell .wallet-inner{width:min(100%,900px)!important;max-width:900px!important}'});
    await page.waitForTimeout(150);
    const wide=await page.evaluate(measureSource+'()');
    const first=wide.cards[0];
    assertTrue(/^64px .* [0-9.]+px$/.test(first.columns)&&first.columns.split(' ').length===3,
      `a 900px-wide row lays out in three columns again (${first.columns})`);
    assertTrue(first.name.box.width>=144,
      `and its copy column is ${first.name.box.width.toFixed(0)}px — at or above the 9rem floor`);
    assertTrue(first.name.lines<=2,
      `and the long reward name draws ${first.name.lines} line(s) there`);
    const x=Math.min(first.pill.right,first.action.right)-Math.max(first.pill.left,first.action.left);
    const y=Math.min(first.pill.bottom,first.action.bottom)-Math.max(first.pill.top,first.action.top);
    assertTrue(!(x>2&&y>2),
      `and the Ready pill ${fmt(first.pill)} is still clear of the claim button ${fmt(first.action)}`);
    await context.close();
  }

  /* --------- the wallet HOME, which is the other surface the dock sits over ----------------- */
  for(const width of [390,834,1440]){
    say(`wallet home dock clearance at ${width}x900`);
    const {context,page}=await open(width,900,'#/wallet',{});
    await page.waitForTimeout(900);
    const dock=await page.evaluate(dockSweepSource+'()');
    assertTrue(!dock.missing&&dock.trapped.length===0,
      `${width}: #/wallet — nothing tappable trapped under the dock at maximum scroll`
      +(dock.trapped?.length?` — ${JSON.stringify(dock.trapped.slice(0,4))}`:''));
    await context.close();
  }

  /* --------- Profile and Messages: the device-notification card is the same defect ---------- */
  /* Found by the v446 route sweep. `.customer-push-setting` was two columns above 560px of
     VIEWPORT inside the same 358px shell column, so the `auto` button track took its max-content
     and the copy was squeezed to 47px (Profile) / 32px (Messages) with overflow:visible — the
     heading and both paragraphs painted across the button. Measured here as: no text node inside
     the card renders wider than the box it is given. */
  const cardOverflowSource=`(()=>{
    const card=document.querySelector('.customer-push-setting');
    if(!card)return {missing:true};
    const over=[];
    for(const el of card.querySelectorAll('h2,p,span,b,small')){
      if(el.children.length)continue;
      const style=getComputedStyle(el);
      if(style.display==='none'||style.visibility==='hidden')continue;
      if(el.clientWidth>0&&el.scrollWidth>el.clientWidth+1)
        over.push({text:String(el.textContent||'').trim().slice(0,36),
          width:el.clientWidth,content:el.scrollWidth});
    }
    return {columns:getComputedStyle(card).gridTemplateColumns,over,
      box:card.getBoundingClientRect().width};
  })`;
  for(const [route,label] of [['#/customer/profile','Profile'],['#/customer/messages','Messages']]){
    for(const width of WIDTHS){
      say(`${label} device-notification card at ${width}x900`);
      const {context,page}=await open(width,900,route,{});
      await page.waitForFunction(()=>!!document.querySelector('.customer-push-setting'),null,{timeout:20000});
      const card=await page.evaluate(cardOverflowSource+'()');
      /* And the page's own column grid, which had the same flaw: `.customer-profile-grid` was two
         columns above 720px of viewport inside the same 358px box, leaving its first column
         104px wide. */
      const grid=await page.evaluate(()=>{
        const el=document.querySelector('.customer-profile-grid');
        if(!el)return null;
        return {columns:getComputedStyle(el).gridTemplateColumns,
          first:el.firstElementChild?el.firstElementChild.getBoundingClientRect().width:0};
      });
      if(grid)assertTrue(grid.first>=240,
        `${width}: ${label} — the profile column is ${grid.first.toFixed(0)}px wide `
        +`(columns ${grid.columns})`);
      assertTrue(!card.missing&&card.over.length===0,
        `${width}: ${label} — nothing in the device-notification card overflows its own box `
        +`(card ${card.box?.toFixed(0)}px, columns ${card.columns})`
        +(card.over?.length?` — ${JSON.stringify(card.over)}`:''));
      await context.close();
    }
  }

  /* ============ nestly_v457, ruling 1 — Home states no quantity it has not loaded =============
     LIVE on 9a57bac: greeting "2 rewards ready", Cubbly card "1 reward ready", QA Kaya Toast card
     "1 reward ready", nav badge "Rewards 7" — while QA Kaya Toast's own page said 2. The fixture
     here reproduces the shape: five businesses, TWO of them ready, one on sessions, the rest at
     zero. Under the old code the greeting printed the sum of the per-card 1s, i.e. "2", and the
     business page printed "2 rewards ready" for one of those businesses alone. */
  const homeReadySource=`(()=>{
    const surface=document.querySelector('.customer-shell.customer-surface')||document.body;
    const text=String(surface.innerText||'').replace(/\\s+/g,' ');
    const hero=document.querySelector('.customer-home-ready-card-v343');
    const cards=[...document.querySelectorAll('.customer-home-business-track-v343 .customer-programme-card-v95,'
      +'.customer-home-business-track-v343 a')];
    const cardText=cards.map(card=>String(card.innerText||'').replace(/\\s+/g,' ').trim());
    const navRewards=document.querySelector('.customer-primary-nav a[href="#/customer/programmes"]');
    return {
      text,
      heroText:hero?String(hero.innerText||'').replace(/\\s+/g,' ').trim():null,
      heroLabel:hero?String(hero.getAttribute('aria-label')||''):null,
      cardText,
      cardsClaimingReady:cardText.filter(t=>/reward[s]? ready/i.test(t)).length,
      navRewardsBadge:navRewards?!!navRewards.querySelector('.customer-nav-count'):null,
      navRewardsLabel:navRewards?String(navRewards.getAttribute('aria-label')||navRewards.innerText||'')
        .replace(/\\s+/g,' ').trim():null
    };
  })`;
  /* Any digit immediately in front of "reward(s) ready" is a quantity Home cannot substantiate. */
  const READY_QUANTITY=/\d[\d,]*\s+rewards?\s+ready/i;

  for(const width of WIDTHS){
    say(`Home never states a ready COUNT at ${width}x900`);
    const {context,page}=await open(width,900,'#/wallet',{extraBusinesses:true});
    await page.waitForFunction(()=>!!document.querySelector('.customer-home-ready-card-v343'),null,{timeout:20000});
    const home=await page.evaluate(homeReadySource+'()');
    assertTrue(!READY_QUANTITY.test(home.text),
      `${width}: no surface on Home prints a ready quantity`
      +(READY_QUANTITY.test(home.text)?` — "${(home.text.match(READY_QUANTITY)||[''])[0]}"`:''));
    assertTrue(!READY_QUANTITY.test(home.heroText||'')&&!READY_QUANTITY.test(home.heroLabel||''),
      `${width}: the greeting hero reads "${home.heroText}" `
      +`(accessible name "${home.heroLabel}") — no quantity in either`);
    /* The greeting and the cards are two readings of one array and must not drift: the hero
       asserts readiness exactly when at least one card does. */
    const heroSaysReady=/reward[s]? ready/i.test(home.heroText||'');
    assertTrue(heroSaysReady===(home.cardsClaimingReady>0),
      `${width}: the greeting (${heroSaysReady?'ready':'not ready'}) agrees with the `
      +`${home.cardsClaimingReady} card(s) that claim readiness`);
    assertTrue(home.cardsClaimingReady===2,
      `${width}: both ready businesses say so on Home (${home.cardsClaimingReady} of 5 cards)`);
    assertTrue(home.navRewardsBadge===false,
      `${width}: the Rewards tab carries no bare number (badge present: ${home.navRewardsBadge})`);
    assertTrue(!/\d/.test(home.navRewardsLabel||''),
      `${width}: and its accessible name is "${home.navRewardsLabel}", with no count in it`);
    await context.close();
  }

  /* The other half of the ruling: the page that HAS loaded the catalogue still prints the exact
     number. Removing the unsubstantiated 1 must not have removed the substantiated 2. */
  say('the business page still prints the exact ready count it loaded');
  {
    const {context,page}=await open(1180,900,`#/wallet/${SLUG}`,{extraBusinesses:true,withStamps:true});
    /* The tiles paint "Reward ready" and customerRewardReadyCountApplyV397 replaces it with the
       real figure once loadRewards has the catalogue. Waiting for that figure IS the assertion. */
    const exact=await page.waitForFunction(
      ()=>/2 rewards ready/.test(String(document.body.innerText||''))||null,
      null,{timeout:20000}).then(()=>true).catch(()=>false);
    assertTrue(exact,
      'the business page names the real count (2) once the catalogue is in — so removing the '
      +'unsubstantiated 1 did not remove the substantiated 2');
    await context.close();
  }

  /* ============ nestly_v457, ruling 2 — the merchant's name is never clipped ==================
     Both causes are covered: the wordy placeholder that starved the name's track (measured 172px
     of actions against a 104px name box), and the nowrap+ellipsis that clipped any name past
     ~156px whatever the track. The non-Latin name is here because the fix must not depend on
     English label widths. */
  const headerNameSource=`(()=>{
    const header=document.querySelector('.customer-business-header-v346');
    if(!header)return {missing:true};
    const name=header.querySelector('.customer-business-identity-v346 b');
    if(!name)return {missing:'name'};
    const style=getComputedStyle(name);
    const actions=header.querySelector('.customer-business-actions-v346');
    return {columns:getComputedStyle(header).gridTemplateColumns,
      text:String(name.textContent||'').trim(),
      clientWidth:name.clientWidth,scrollWidth:name.scrollWidth,
      whiteSpace:style.whiteSpace,textOverflow:style.textOverflow,
      actionsWidth:actions?actions.getBoundingClientRect().width:0,
      actionTargets:actions?[...actions.children].map(el=>{
        const box=el.getBoundingClientRect();
        return {label:String(el.getAttribute('aria-label')||el.textContent||'').trim().slice(0,24),
          width:Math.round(box.width),height:Math.round(box.height)};
      }):[]};
  })`;
  const NAME_CASES=[
    ['short, contact read landed',{withBranchContact:true}],
    ['short, contact read never lands',{withBranchContact:false}],
    ['long Latin name',{withBranchContact:true,businessName:'Ah Xiang Traditional Kopitiam & Bakery'}],
    ['long Latin name, no contact',{withBranchContact:false,businessName:'Ah Xiang Traditional Kopitiam & Bakery'}],
    ['Tamil name',{withBranchContact:true,businessName:'கோபி டீக்கடை மற்றும் பேக்கரி'}],
    ['Chinese name',{withBranchContact:true,businessName:'新加坡传统咖啡店与烘焙坊'}]
  ];
  for(const [label,options] of NAME_CASES){
    for(const width of [390,520,834,1440]){
      say(`business name not clipped — ${label} at ${width}x900`);
      const {context,page}=await open(width,900,`#/wallet/${SLUG}`,{withStamps:true,...options});
      await page.waitForFunction(()=>!!document.querySelector('.customer-business-header-v346 .customer-business-identity-v346 b'),null,{timeout:20000});
      /* The contact read replaces the whole action row; give it a beat so both states are the
         SETTLED state rather than a race. */
      await page.waitForTimeout(900);
      const header=await page.evaluate(headerNameSource+'()');
      assertTrue(!header.missing&&header.scrollWidth<=header.clientWidth+1,
        `${width}: ${label} — "${header.text}" renders in ${header.clientWidth}px for `
        +`${header.scrollWidth}px of content (tracks ${header.columns})`);
      assertTrue(header.textOverflow!=='ellipsis',
        `${width}: ${label} — the name is not set to ellipsise (${header.textOverflow})`);
      assertTrue(header.actionTargets.length===2
        &&header.actionTargets.every(target=>target.height>=44&&target.width>=34),
        `${width}: ${label} — both header actions stay reachable at a real size `
        +`(${JSON.stringify(header.actionTargets)})`);
      await context.close();
    }
  }

  /* ============ nestly_v457, ruling 3 — the two worst tap targets reach 44px ================== */
  say('Home section-head links and the reward filter chips are 44px tall');
  for(const [route,selector,what] of [
    ['#/wallet','.customer-home-section-head-v343 a,.customer-home-offers-head a','Home "View all" / "See all"'],
    ['#/customer/programmes','.customer-rewards-filter-chip-v395,.customer-rewards-filter-chips-v344 span','reward filter chips']
  ]){
    for(const width of [390,834,1440]){
      const {context,page}=await open(width,900,route,{extraBusinesses:true});
      await page.waitForTimeout(1400);
      const targets=await page.evaluate(sel=>[...document.querySelectorAll(sel)]
        .filter(el=>{const b=el.getBoundingClientRect();return b.width>0&&b.height>0})
        .map(el=>{const b=el.getBoundingClientRect();
          return {label:String(el.textContent||'').trim().slice(0,18),
            width:Math.round(b.width),height:Math.round(b.height)}}),selector);
      assertTrue(targets.length>0,`${width}: ${what} — found ${targets.length} control(s) to measure`);
      const short=targets.filter(target=>target.height<44);
      assertTrue(short.length===0,
        `${width}: ${what} — every hit area is at least 44px tall`
        +(short.length?` — ${JSON.stringify(short)}`:` (${JSON.stringify(targets)})`));
      await context.close();
    }
  }

  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`
    +(pageErrors.length?`: ${pageErrors.slice(0,3).join(' | ')}`:''));

  if(failures){
    process.stdout.write(`\nFAILED: ${failures} assertion(s)\n`);
    process.exitCode=1;
  }else{
    process.stdout.write('\nV446 customer wide layout: all steps passed\n');
  }
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
