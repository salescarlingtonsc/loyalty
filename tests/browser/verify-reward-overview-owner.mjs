import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const base=process.env.REWARD_OVERVIEW_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/reward-overview-owner-visual.html';
const evidenceDir=new URL('../../docs/qa/evidence/reward-overview-owner-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  const page=await browser.newPage({viewport:{width:1440,height:1100},deviceScaleFactor:1});
  const consoleErrors=[];page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text())});
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});
  await page.waitForSelector('#rewardJourneyTitle');
  let metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  /* nestly_v421: the landing's heading is 'Rewards Programme' since V341/V364 renamed the module
     and moved the icon to the H1 — and it is deliberately sr-only there, because the H1 above says
     the same words. This walkthrough had not run since (the fixture threw before it rendered), so
     every expectation below was frozen at the page as it stood then. */
  assert.equal(metrics.title,'Rewards Programme');
  /* nestly_v421: zero, not one — #growAutoSetup was deleted in 190baf6 (see the note below). The
     invariant worth keeping at this spot is that nothing is left BEHIND it: a launcher that has
     been removed must be removed from the page, not merely unwired. */
  assert.equal(metrics.autoSetupButtons,0,'the retired automatic-setup launcher is gone from the page');
  /* nestly_v421: #growSecondarySettings — the collapsed "journey anatomy and economics" disclosure
     these two lines were about — no longer exists on this page; the sections it hid became their
     own views (Overview / History / Limited Offer / Points / Tiers) in the V341/V371 restructure.
     There is nothing left to be ordered against, so the ordering claim is retired rather than
     rewritten into a weaker one. What replaces it is the stronger fact below: every row is a real
     row, at a real size, in a page that does not scroll sideways. */
  assert.equal(metrics.secondaryTop,null,'the secondary-settings disclosure is gone, not merely collapsed');
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth,'desktop must not overflow horizontally');
  assert.equal(metrics.consoleErrors.length,0);assert.equal(consoleErrors.length,0);
  assert.equal(metrics.birthdayRpcCalls,1,'production snapshot adapter must use the published birthday RPC');
  assert.equal(metrics.birthdayTableReads,0,'production snapshot adapter must not read the closed birthday table');
  /* nestly_v421: SEVEN topic tiles, not ten mixed rows. The V343/V362 restructure made the landing
     one tile per PROGRAMME FAMILY, and drilling a tile is what shows that family's own rows — so
     individual rewards and each Bring-back rule are no longer on this screen at all. Memberships
     and Gift cards left it too: they are their own modules now, not rows of the rewards overview.
     What the landing must still prove is that every family the firm can run is present exactly
     once, each as a real control at a real size. */
  assert.deepEqual([...new Set(metrics.cards.map(card=>card.programmeKind))].sort(),
    ['birthday','bringback','points','referrals','stamps','tiers','welcome']);
  assert.equal(metrics.cards.length,7,'each family appears exactly once — no duplicate tiles');
  assert.ok(metrics.cards.every(card=>card.tag==='BUTTON'),'every tile an owner can act on is a real control');
  assert.ok(metrics.cards.every(card=>card.height>=44),'every interactive overview card is at least 44px tall');
  /* The states the fixture set up, read back off the tiles: a live earning rule, a tier ladder the
     firm has not switched on, and a welcome gift it has never configured. */
  assert.match(metrics.cards.find(card=>card.programmeKind==='points')?.text||'',/On/);
  assert.match(metrics.cards.find(card=>card.programmeKind==='tiers')?.text||'',/Off/);
  assert.match(metrics.cards.find(card=>card.programmeKind==='welcome')?.text||'',/Not set up/);

  /* nestly_v421: Bring-back moved off this landing entirely. The tile opens the v361 campaigns
     page, which reads bringback_campaigns_v361 — a table with no start date, so the old
     "Scheduled / Starts 1 January 2099" claim is about a screen and a column that no longer
     exist. What the page must show instead is every campaign the firm has, each with its real
     state, which is what is asserted here. */
  await page.locator('[data-grow-topic-v229="bringback"]').click();
  await page.getByText('2 campaigns configured').waitFor();
  const bringBackPage=await page.locator('#main').innerText();
  assert.match(bringBackPage,/Glow regular return/);
  assert.match(bringBackPage,/Away 30 days → Glow credit/,'each campaign states how long away counts as gone');
  assert.match(bringBackPage,/Paused facial return/,'a paused campaign is listed, not hidden');
  assert.equal(await page.evaluate(()=>location.hash),'#/grow/bringback');
  await page.screenshot({path:new URL('owner-bringback-campaigns-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');

  /* nestly_v421 — WHY THE AUTOMATIC-SETUP WALKTHROUGH IS GONE FROM HERE.
     Everything between this note and the exact-reward drill below used to drive #growAutoSetup,
     the standalone "Create recommended rewards draft" launcher. That button was DELETED in
     190baf6 (2026-08-06) when Programmes was simplified to one list; its click wiring outlived it
     and could never fire, and six unit tests that pinned it were re-pointed in that same commit at
     the invariants' real locations. This browser harness was not — it had already stopped
     rendering (see the generator's own v421 notes), so nothing surfaced that it was driving a
     control the page no longer has.
     The dialog itself (openRewardsAutoSetup) is still very much alive, but its one remaining
     caller is the Bring-back cold start — a firm with no published loyalty configuration whose
     owner cannot write the retention module — and this fixture cannot express that shape: every
     parameter combination it offers either creates the draft directly or routes to the setup
     wizard. Driving it from anywhere else would be evidence of a flow the product does not have.
     So the sector-recommendation, retry-identity and concurrent-draft assertions live in the unit
     suites 190baf6 named, and what this file captures is what this page actually is: the
     programme overview, its rows, its drills and its read-only state. */

  /* THE EXACT-ID INVARIANT, at its current address. Two rewards share the name "Signature reward"
     — pressing one must open THAT one and not its twin. It used to be a row on this landing that
     mounted the deep reward editor; since V326 the gifts live on the Point system page and Edit
     opens an inline form under the row that was pressed, carrying the id on
     data-grow-points-gift-edit-v343. Same invariant, same fixture ids, current door. */
  await page.goto(`${base}?draft=existing`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-grow-topic-v229="points"]').click();
  await page.getByText('Live gifts (2)').waitFor();
  assert.equal(await page.evaluate(()=>location.hash),'#/grow/points');
  assert.equal(await page.locator('[data-grow-points-gift-edit-v343]').count(),2,
    'both same-named gifts are listed, each with its own edit control');
  await page.locator('[data-grow-points-gift-edit-v343="22222222-2222-4222-8222-222222222222"]').click();
  await page.waitForSelector('#growPointsAddNameV326');
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'growPointsAddNameV326',
    'the exact gift editor takes focus, so a keyboard owner lands in the field');
  assert.equal(await page.locator('#growPointsAddNameV326').inputValue(),'Signature reward');
  assert.equal(await page.locator('#growPointsAddPointsV326').inputValue(),'1500',
    'the gift that opened is the one that was pressed, not its identically-named twin');
  assert.equal(await page.locator('#growPointsAddNameV326').count(),1,'exactly one editor is mounted');
  await page.screenshot({path:new URL('owner-exact-reward-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?draft=existing&route=earning#/loyalty/draft-v2/earning`,{waitUntil:'networkidle'});await page.waitForSelector('#lm');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.deepEqual({intent:metrics.editorIntent,program:metrics.programEditors,reward:metrics.rewardEditors,birthday:metrics.birthdayEditors,redemption:metrics.redemptionEditors},
    {intent:'earning',program:1,reward:0,birthday:0,redemption:0},'Earn opens only the earning form');
  assert.equal(metrics.overviewHomeVisible,false);
  assert.equal(metrics.authorityLabel,'Editable draft','writable owner draft is never mislabelled read only');
  await page.screenshot({path:new URL('owner-editable-draft-authority-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?draft=existing&route=birthday#/loyalty/draft-v2/birthday`,{waitUntil:'networkidle'});await page.waitForSelector('#birthdayLabel');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.deepEqual({intent:metrics.editorIntent,program:metrics.programEditors,reward:metrics.rewardEditors,birthday:metrics.birthdayEditors,redemption:metrics.redemptionEditors},
    {intent:'birthday',program:0,reward:0,birthday:1,redemption:0},'Birthday opens only the Birthday form');
  assert.equal(metrics.overviewHomeVisible,false);

  await page.goto(`${base}?draft=existing&route=add#/loyalty/draft-v2/add`,{waitUntil:'networkidle'});await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.deepEqual({intent:metrics.editorIntent,program:metrics.programEditors,reward:metrics.rewardEditors,birthday:metrics.birthdayEditors,list:metrics.rewardLists},
    {intent:'add',program:0,reward:1,birthday:0,list:0},'Add opens one blank reward form without the reward list or Birthday');

  /* THE SAME EXACT-ID INVARIANT for Bring-back, at ITS current address. It used to be a row on
     this landing that mounted the shared retention editor behind a created draft; v361 gave
     Bring-back its own page and its own immediate-write editor, keyed on data-grow-bb-edit-v361.
     Pressing the second campaign must load the second campaign — the fault this guards against is
     an editor that opens on whichever record happened to be first. */
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-grow-topic-v229="bringback"]').click();
  await page.getByText('2 campaigns configured').waitFor();
  await page.locator('[data-grow-bb-edit-v361="bring-back-2"]').click();
  await page.waitForSelector('#growBbNameV361');
  assert.equal(await page.locator('#growBbNameV361').inputValue(),'Paused facial return',
    'the campaign that opened is the one that was pressed');
  assert.equal(await page.locator('#growBbAwayV361').inputValue(),'60','with its own away window');
  assert.equal(await page.locator('#growBbRewardV361').inputValue(),'Glow credit');
  assert.equal(await page.locator('#growBbNameV361').count(),1,'exactly one campaign editor is mounted');
  await page.screenshot({path:new URL('owner-exact-bringback-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  /* And the first one, so "it always opens the first record" cannot pass by accident. */
  await page.locator('#growBbCancelV361, [data-grow-bb-cancel-v361]').first().click().catch(()=>{});
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-grow-topic-v229="bringback"]').click();
  await page.getByText('2 campaigns configured').waitFor();
  await page.locator('[data-grow-bb-edit-v361="bring-back-1"]').click();
  await page.waitForSelector('#growBbNameV361');
  assert.equal(await page.locator('#growBbNameV361').inputValue(),'Glow regular return');
  assert.equal(await page.locator('#growBbAwayV361').inputValue(),'30');

  /* THE STATE MATRIX. Every one of these used to read data-programme-kind rows; they read the
     tiles' own aria-label now, which is the sentence an owner actually acts on ("Point system —
     Set up →"). The label is where a wrong state does damage: it is the promise the tile makes
     about what pressing it will do. */
  const tileActions=async()=>Object.fromEntries(await page.locator('.grow-topic-card-v343')
    .evaluateAll(tiles=>tiles.map(tile=>[tile.dataset.growTopicV229,tile.getAttribute('aria-label')])));

  await page.goto(`${base}?draft=none&empty=1`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  const emptyActions=await tileActions();
  for(const [topic,label] of Object.entries(emptyActions)){
    assert.match(label,/Set up →$/,`${topic} on a firm with nothing configured must offer setup, never editing`);
  }

  await page.goto(`${base}?draft=none&partial=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growRewardsRetry');
  assert.equal(await page.locator('#growRewardsRetry').textContent(),'Retry programme overview');
  assert.match(await page.locator('[data-grow-topic-v229="referrals"]').textContent(),/Unavailable/,
    'a read that failed stays unknown rather than being reported as off');

  await page.goto(`${base}?draft=none&configured=off`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  for(const topic of ['referrals','bringback']){
    assert.match(await page.locator(`[data-grow-topic-v229="${topic}"]`).textContent(),/Paused/,
      `${topic} configured-off state must not be called not set up`);
  }

  await page.goto(`${base}?draft=none&partial=all`,{waitUntil:'networkidle'});await page.waitForSelector('#growRewardsRetry');
  for(const topic of ['points','tiers','stamps','welcome','birthday','bringback','referrals']){
    const tile=page.locator(`[data-grow-topic-v229="${topic}"]`).first();
    assert.match(await tile.textContent(),/Unavailable/,`${topic} read failure must remain unknown`);
  }

  /* MODULE SCOPE. A firm that does not have a module must not be offered its programmes — and
     must not be told they are "off", which would be a claim about a setting it does not have. */
  await page.goto(`${base}?modules=retention`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  const retentionOnly=await tileActions();
  assert.match(retentionOnly.bringback,/View →$|Edit →$/,'the one module this firm has is usable');
  for(const topic of ['points','tiers','stamps','welcome','birthday','referrals']){
    assert.match(retentionOnly[topic],/See plan →$/,`${topic} is not included, and says so`);
    assert.match(await page.locator(`[data-grow-topic-v229="${topic}"]`).textContent(),/Not included/);
  }
  await page.locator('[data-grow-topic-v229="bringback"]').click();
  await page.getByText('2 campaigns configured').waitFor();
  assert.equal(await page.evaluate(()=>location.hash),'#/grow/bringback',
    'a retention-only owner reaches their own campaigns page');

  await page.goto(`${base}?draft=none&modules=loyalty`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  for(const topic of ['bringback','referrals']){
    assert.match(await page.locator(`[data-grow-topic-v229="${topic}"]`).textContent(),/Not included/,
      `${topic} has no dead writer on a loyalty-only plan`);
  }

  await page.setViewportSize({width:375,height:667});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.viewport.clientWidth,375);assert.equal(metrics.viewport.scrollWidth,375,'375px owner overview must not overflow');
  assert.ok(metrics.cards.every(card=>card.width<=351&&card.height>=44));
  /* The All/On/Not set up/History strip.
     UPDATED 2026-08-22, the first time this walkthrough had run since the CSS changed. It used to
     assert overflow-x:auto — the strip was wider than the phone and scrolled inside itself. The
     @media(max-width:480px) rule in app/index.html now WRAPS it into two rows of two instead, and
     its own comment says why: a horizontal scroller at 375px showed no affordance, so "History"
     was reachable only by a swipe nothing advertised. Wrapping is strictly better and the old
     assertion was pinning the behaviour that was deliberately removed.
     What is worth pinning is the INVARIANT both shapes were serving — every filter is reachable
     on a phone — so that is what is asserted now: nothing is clipped, and all four tabs are
     inside the viewport. */
  const tabStrip=await page.locator('.grow-programme-tabs-v343').evaluate(strip=>({
    clientWidth:strip.clientWidth,scrollWidth:strip.scrollWidth,
    overflowX:getComputedStyle(strip).overflowX,flexWrap:getComputedStyle(strip).flexWrap,
    tabs:[...strip.querySelectorAll('button')].map(button=>{
      const rect=button.getBoundingClientRect();
      return {label:button.textContent.trim(),left:rect.left,right:rect.right,height:rect.height};
    })}));
  assert.equal(tabStrip.flexWrap,'wrap','the tab strip wraps at phone width rather than scrolling');
  assert.equal(tabStrip.scrollWidth,tabStrip.clientWidth,'…so nothing is hidden off its right edge');
  assert.ok(tabStrip.tabs.length>=4,'all four filters are present');
  for(const tab of tabStrip.tabs){
    assert.ok(tab.left>=0&&tab.right<=375,`filter "${tab.label}" must be inside a 375px viewport`);
    assert.ok(tab.height>=44,`filter "${tab.label}" must keep a 44px touch target`);
  }
  await page.screenshot({path:new URL('owner-overview-small-375.png',evidenceDir).pathname,fullPage:true});

  /* nestly_v421: landscape. The popup this used to open is gone from this page (see the note
     above); what a short, wide viewport still has to prove is that the overview itself fits. */
  await page.setViewportSize({width:844,height:390});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),844,'landscape overview must not overflow');
  assert.ok((await page.locator('.grow-programme-row').evaluateAll(rows=>rows.map(row=>row.getBoundingClientRect().height))).every(height=>height>=44),
    'landscape rows keep 44px touch targets');
  await page.screenshot({path:new URL('owner-overview-landscape-844.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:412,height:915});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),412,'412px owner overview must not overflow');
  assert.ok((await page.locator('.grow-programme-row').evaluateAll(rows=>rows.map(row=>row.getBoundingClientRect().height))).every(height=>height>=44));

  await page.setViewportSize({width:390,height:844});
  await page.goto(`${base}?draft=existing&route=reward-mobile#/loyalty/draft-v2/reward~22222222-2222-4222-8222-222222222222`,{waitUntil:'networkidle'});await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.birthdayEditors,0,'390px exact reward cannot mount Birthday below it');
  assert.equal(metrics.rewardLists,0,'390px exact reward cannot leave the catalogue mounted above it');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),390,'390px exact reward editor must not overflow');
  await page.screenshot({path:new URL('owner-exact-reward-editor-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=manager`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.role,'manager');assert.equal(metrics.editButtons,0,'read-only manager receives no edit control');
  assert.equal(metrics.autoSetupButtons,0,'read-only manager receives no automatic setup writer');
  assert.equal(metrics.birthdayRpcCalls,1,'read-only manager loads birthday through the same permission-safe RPC');
  assert.equal(metrics.birthdayTableReads,0);
  /* nestly_v421. This line used to require every card to be an inert <article> for a read-only
     manager. Since the V343/V362 restructure every tile is a <button> for everyone, because a tile
     is NAVIGATION — it opens the programme's page, and the write on that page is gated there.
     What was NOT sound, and is fixed in this same wave, is the WORD on the tile:
     growTopicActionV244 picked it from the tile's status alone, so a manager who cannot write was
     invited to "Turn on →" a tier ladder and "Set up →" a welcome gift. Nothing broke when they
     pressed it — the destination refused — but they were promised an action they do not have.
     Every tile now reads "View →" for someone who cannot write it. */
  const managerActions=Object.fromEntries(await page.locator('.grow-topic-card-v343')
    .evaluateAll(tiles=>tiles.map(tile=>[tile.dataset.growTopicV229,tile.getAttribute('aria-label')])));
  assert.ok(metrics.cards.every(card=>card.tag==='BUTTON'),'tiles are navigation for every role');
  for(const [topic,label] of Object.entries(managerActions)){
    assert.match(label,/View →$/,`${topic} must not promise a read-only manager a write`);
  }
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth);
  await page.screenshot({path:new URL('manager-read-only-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.evaluate(()=>loyaltyPage(undefined,'draft-v2',null,false,{kind:'earning'}));await page.waitForSelector('#lm');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.authorityLabel,'Read only','manager retains explicit read-only authority copy');
  assert.equal(await page.locator('#loyaltyAuthority button').count(),0,'read-only authority state exposes no draft action');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),390,'390px read-only editor does not overflow');
  await page.screenshot({path:new URL('manager-read-only-draft-authority-mobile-390.png',evidenceDir).pathname,fullPage:true});
  process.stdout.write(JSON.stringify({status:'PASS',sourceHash:metrics.sourceHash,evidenceDir:evidenceDir.pathname},null,2)+'\n');
}finally{await browser.close()}
