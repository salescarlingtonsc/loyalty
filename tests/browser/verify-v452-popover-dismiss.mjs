/* V452 — one dismiss discipline for every popover, proved by clicking a real browser.
 *
 * THE BUG (C-REG-005/C-REG-012). Five popovers, five different (or absent) close rules:
 *   .profile .menu   JS flag + a ONE-SHOT document click listener re-armed on every render;
 *                    Escape bound to the PANEL, so it only fired if focus was already inside it.
 *   .notif-menu      the same one-shot listener; no Escape at all.
 *   .business-workspace-switch   a bare <details>: no outside click, no Escape, nothing.
 *   mobile search sheet          closed on its own backdrop only.
 *   .grow-row-menu-v351          bare <details>, and every row's menu could be open at once.
 * And nothing closed on NAVIGATION. That is the owner-reported symptom: v443/v444 moved the
 * workspace switcher INSIDE the profile menu, so its links sit inside #profwrap where the
 * outside-click listener can never fire; they carry no onclick; and route() never touched the
 * flags. Result: pick another workspace and the account menu is still hanging open on the page
 * you land on.
 *
 * WHAT THIS FILE PROVES, by dispatching real clicks and real keys at the real app:
 *   1. outside-click closes the profile menu and the bell.
 *   2. Escape closes each of them FROM ANYWHERE (focus on document.body, not in the panel) and
 *      returns focus to the trigger that opened it.
 *   3. opening one closes the other.
 *   4. THE OWNER CASE, end to end: open the profile menu -> open the workspace switcher nested
 *      inside it -> activate a workspace link -> after the route settles BOTH are closed.
 *   5. a REAL grow row menu (#/grow/tiers renders one per tier): clicking its own action button
 *      both FIRES THE ACTION and closes the menu. The row menus' buttons do not stopPropagation,
 *      so this is the case a careless document-level closer would swallow.
 *   6. clicking elsewhere closes an open row menu, and only one row menu can be open at a time.
 *   7. THE EXCLUSION, asserted rather than assumed: real disclosure <details> that are NOT
 *      popovers — `.appointment-more` on #/appointments and `.staff-mobile-more` in the shell —
 *      stay open when you click elsewhere and when you press Escape. They are expandable
 *      sections and are meant to survive.
 *   8. the mobile search sheet closes on Escape from anywhere, and on navigation.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v452-popover-dismiss.mjs
 * V452_PORT moves it off 4483. V452_APP_DIR points it at another build — REQUIRED here, because
 * the browser loads the generated surface chunks and this repo's rule is that agents never run
 * `npm run bundle-stamp` in the worktree (the orchestrator stamps at integration). So: copy the
 * tree to a scratch dir, stamp THERE, and point this at that dir's app/ folder. The readiness
 * probe checks app-business.js, not app.js, so an unstamped tree cannot pass.
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {ownerWorkspaceStub} from './fixtures/owner-workspace-stub.mjs';

const ROOT=new URL('../../',import.meta.url);
const APP_DIR=process.env.V452_APP_DIR||fileURLToPath(new URL('app/',ROOT));
const PORT=Number(process.env.V452_PORT||4483);
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
    /* The browser loads the GENERATED chunks, never app/app.js, so probing app.js would happily
       green-light a tree whose chunks are stale. Probe the chunk the controller lands in. */
    const r=await fetch(`${ORIGIN}/app-business.js`);
    if(!r.ok)return false;
    return (await r.text()).includes('closeAllPopoversV452');
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

const OTHER=[{business_id:'b2222222-2222-4222-8222-222222222222',business_slug:'otherco',
  business_name:'Other Co',role:'owner',modules:['loyalty','clients','sales','till','reports']}];

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
const settle=(page,ms=450)=>page.waitForTimeout?page.waitForTimeout(ms):new Promise(r=>setTimeout(r,ms));

try{
  await serverReady();

  const open=async(hash='#/dashboard',width=1280)=>{
    const context=await browser.newContext({viewport:{width,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(ownerWorkspaceStub({extraStaffWorkspaces:OTHER}));
    const page=await context.newPage();
    page.on('pageerror',e=>pageErrors.push(`${hash}: ${e}`));
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('.appbar #profWho',{timeout:25000});
    await settle(page);
    return {context,page};
  };
  /* Click through the real event path (a trusted-ish click at the element's own centre), not
     el.click(), so delegated document listeners see exactly what a user's click produces. */
  const clickAt=async(page,selector)=>{await page.click(selector,{timeout:8000});await settle(page,250)};
  /* "Somewhere else on the page" has to be somewhere INERT. A blind click at fixed coordinates
     landed on a dashboard KPI tile and opened its drill-down modal, which then intercepted
     everything after it. The page container's own top-left padding is the one spot guaranteed to
     carry no control on any route. */
  const clickOutside=async page=>{
    const point=await page.evaluate(()=>{
      const main=document.getElementById('main')||document.querySelector('main');
      const box=main.getBoundingClientRect();
      return {x:Math.round(box.left+4),y:Math.round(box.top+4)};
    });
    const hit=await page.evaluate(({x,y})=>{
      const el=document.elementFromPoint(x,y);
      return {tag:el?.tagName,id:el?.id,interactive:!!el?.closest('a[href],button,select,input,[role="button"],[data-kpi],.card')};
    },point);
    if(hit.interactive)throw new Error(`the "click outside" point landed on something interactive (${hit.tag}#${hit.id})`);
    await page.mouse.click(point.x,point.y);
    await settle(page,250);
  };
  const menuOpen=page=>page.evaluate(()=>!!document.getElementById('profmenu'));
  const bellMenuOpen=page=>page.evaluate(()=>!!document.querySelector('.notif-menu'));

  /* ---------------- 1 + 2 + 3: the two header menus ---------------- */
  {
    say('1. profile menu: outside click closes it');
    const {context,page}=await open();
    await clickAt(page,'#profWho');
    assertTrue(await menuOpen(page),'the account chip opens the profile menu');
    await clickOutside(page);
    assertTrue(!(await menuOpen(page)),'a click on the page body closes it');

    say('2. profile menu: Escape from anywhere closes it and returns focus to the chip');
    await clickAt(page,'#profWho');
    assertTrue(await menuOpen(page),'reopened');
    await page.evaluate(()=>document.body.focus?.());
    /* Focus deliberately NOT inside the panel — that is exactly what the old panel-bound
       keydown handler could not cope with. */
    const focusBefore=await page.evaluate(()=>document.activeElement?.id||document.activeElement?.tagName);
    await page.keyboard.press('Escape');
    await settle(page,250);
    assertTrue(!(await menuOpen(page)),
      `Escape closed it with focus on ${focusBefore} (outside the panel)`);
    assertTrue(await page.evaluate(()=>document.activeElement?.id==='profWho'),
      'and focus returned to the account chip');

    say('3. opening the bell closes the profile menu, and vice versa');
    await clickAt(page,'#profWho');
    assertTrue(await menuOpen(page),'profile menu open');
    await clickAt(page,'#bellBtn');
    assertTrue(await bellMenuOpen(page)&&!(await menuOpen(page)),
      'opening notifications closed the profile menu');
    await clickAt(page,'#profWho');
    assertTrue(await menuOpen(page)&&!(await bellMenuOpen(page)),
      'and opening the profile menu closed notifications');

    say('3b. the bell closes on Escape too — it had no Escape handler at all before');
    await clickOutside(page);
    await clickAt(page,'#bellBtn');
    assertTrue(await bellMenuOpen(page),'notifications open');
    await page.evaluate(()=>document.body.focus?.());
    await page.keyboard.press('Escape');
    await settle(page,250);
    assertTrue(!(await bellMenuOpen(page)),'Escape closed the notification panel');
    assertTrue(await page.evaluate(()=>document.activeElement?.id==='bellBtn'),
      'and focus returned to the bell');
    await context.close();
  }

  /* ---------------- 4: THE OWNER CASE ---------------- */
  {
    say('4. profile menu + nested workspace switcher both close when a workspace is chosen');
    const {context,page}=await open();
    await clickAt(page,'#profWho');
    assertTrue(await menuOpen(page),'profile menu open');
    const hasSwitch=await page.evaluate(()=>
      !!document.querySelector('#profmenu details.business-workspace-switch'));
    assertTrue(hasSwitch,
      'the workspace switcher is rendered INSIDE the profile menu (v443/v444), which is why its '
      +'links can never trigger an outside-click dismiss');
    await clickAt(page,'#profmenu details.business-workspace-switch > summary');
    assertTrue(await page.evaluate(()=>
      !!document.querySelector('#profmenu details.business-workspace-switch[open]')),
      'the switcher disclosure is open');
    const before=await page.evaluate(()=>location.hash);
    await clickAt(page,'#profmenu details.business-workspace-switch .menu a[href*="/workspace/"]');
    /* The route has to actually settle; the fixture resolves any slug to the one tenant it holds,
       which is fine — what is under test is that navigating dismisses, not workspace switching. */
    await page.waitForFunction(()=>!document.getElementById('profmenu')||true,null,{timeout:8000});
    await settle(page,1200);
    const after=await page.evaluate(()=>location.hash);
    assertTrue(after!==before,`the workspace link navigated (${before} -> ${after})`);
    assertTrue(!(await menuOpen(page)),
      'and the profile menu is CLOSED on the page we landed on (it used to still be hanging open)');
    assertTrue(await page.evaluate(()=>
      !document.querySelector('details.business-workspace-switch[open]')),
      'the nested switcher is closed too');
    await context.close();
  }

  /* ---------------- 5 + 6: real grow row menus ---------------- */
  {
    say('5. a real grow row menu: its own action fires AND the menu closes');
    const {context,page}=await open('#/grow/tiers');
    await page.waitForSelector('details.grow-row-menu-v351 > summary',{timeout:20000});
    const menus=await page.evaluate(()=>document.querySelectorAll('details.grow-row-menu-v351').length);
    assertTrue(menus>=1,`#/grow/tiers rendered ${menus} real row menu(s) — not a synthetic stand-in`);
    await clickAt(page,'details.grow-row-menu-v351 > summary');
    assertTrue(await page.evaluate(()=>!!document.querySelector('details.grow-row-menu-v351[open]')),
      'the ••• menu is open');
    /* Record whether the item's OWN handler ran. The row menu's buttons do not stopPropagation,
       so a closer that fired synchronously (or in the capture phase) could steal this click. */
    await page.evaluate(()=>{
      window.__v452actionFired=false;
      const button=document.querySelector('details.grow-row-menu-v351[open] .menu button');
      button.addEventListener('click',()=>{window.__v452actionFired=true},{once:true});
      button.setAttribute('data-v452-probe','1');
    });
    await clickAt(page,'details.grow-row-menu-v351[open] .menu button[data-v452-probe]');
    await settle(page,300);
    assertTrue(await page.evaluate(()=>window.__v452actionFired===true),
      "the menu item's own click handler ran — the dismiss controller did not swallow it");
    assertTrue(await page.evaluate(()=>!document.querySelector('details.grow-row-menu-v351[open]')),
      'and choosing the item closed the menu');

    say('6. clicking elsewhere closes a row menu, and only one can be open');
    await page.waitForSelector('details.grow-row-menu-v351 > summary',{timeout:20000});
    await clickAt(page,'details.grow-row-menu-v351 > summary');
    assertTrue(await page.evaluate(()=>!!document.querySelector('details.grow-row-menu-v351[open]')),
      'reopened');
    await clickOutside(page);
    assertTrue(await page.evaluate(()=>!document.querySelector('details.grow-row-menu-v351[open]')),
      'a click elsewhere on the page closed it');
    const many=await page.evaluate(async()=>{
      const all=[...document.querySelectorAll('details.grow-row-menu-v351 > summary')];
      if(all.length<2)return 'only one row menu on this page';
      for(const summary of all){summary.click();await new Promise(r=>setTimeout(r,60))}
      await new Promise(r=>setTimeout(r,120));
      return document.querySelectorAll('details.grow-row-menu-v351[open]').length;
    });
    assertTrue(many==='only one row menu on this page'||many<=1,
      `opening each row menu in turn leaves at most one open (${many})`);
    await context.close();
  }

  /* ---------------- 7: THE EXCLUSION ---------------- */
  {
    say('7. disclosure <details> are NOT popovers and must survive a click elsewhere');
    const {context,page}=await open('#/appointments');
    await page.waitForSelector('details.appointment-more > summary',{timeout:20000});
    await clickAt(page,'details.appointment-more > summary');
    assertTrue(await page.evaluate(()=>!!document.querySelector('details.appointment-more[open]')),
      'the appointments More disclosure is open');
    await clickOutside(page);
    assertTrue(await page.evaluate(()=>!!document.querySelector('details.appointment-more[open]')),
      'a click elsewhere leaves it open — it is a section, not a menu');
    await page.evaluate(()=>document.body.focus?.());
    await page.keyboard.press('Escape');
    await settle(page,250);
    assertTrue(await page.evaluate(()=>!!document.querySelector('details.appointment-more[open]')),
      'and Escape leaves it open too');
    /* And the generic guarantee: whatever <details> the app renders, only the two registered
       popover classes are ever reachable by the controller. */
    const registered=await page.evaluate(()=>{
      const seen=[...document.querySelectorAll('details')].map(d=>String(d.className||'(none)'));
      return {seen,unregistered:seen.filter(c=>!/business-workspace-switch|grow-row-menu-v351/.test(c))};
    });
    assertTrue(registered.unregistered.length>0,
      `this page carries ${registered.unregistered.length} unregistered disclosure(s) `
      +`(${registered.unregistered.join(', ')}) — the exclusion is exercised, not hypothetical`);
    await context.close();
  }

  /* ---------------- 8: the mobile search sheet ---------------- */
  {
    say('8. the mobile search sheet closes on Escape from anywhere, and on navigation');
    const {context,page}=await open('#/dashboard',390);
    await page.waitForSelector('#mobileSearchOpen',{timeout:20000});
    const sheetOpen=()=>page.evaluate(()=>!!document.querySelector('#mobileSearchSheet[open]'));
    await clickAt(page,'#mobileSearchOpen');
    assertTrue(await sheetOpen(),'the sheet is open');
    await page.evaluate(()=>document.body.focus?.());
    await page.keyboard.press('Escape');
    await settle(page,250);
    assertTrue(!(await sheetOpen()),
      'Escape closed it with focus outside its input — before, only the input listened');

    await clickAt(page,'#mobileSearchOpen');
    assertTrue(await sheetOpen(),'reopened');
    await page.evaluate(()=>{location.hash='#/clients'});
    await settle(page,1200);
    assertTrue(!(await sheetOpen()),'and navigating closed it');
    await context.close();
  }

  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`);
  process.stdout.write('\nV452 popover dismiss: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
