import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

const snapshot=section('async function growOverviewSnapshot','function ownerRewardJourneyV122');
const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
const retention=section('async function retentionPage(','/* ---------- Grow: one customer journey');

test('Grow starts with one task and one complete single-column programme overview',()=>{
  // The standalone growAutoSetup launcher was retired when Programmes became one list; setup is
  // now started from the programme rows, which call openRewardsAutoSetup as the draft gate.
  assert.match(grow,/openRewardsAutoSetup\(action\)/);
  // V173 made this heading follow the selected tab (Running / To set up / List) instead of one
  // fixed title, so assert the element and its tab-driven content rather than the old string.
  /* V229 added the drilled-topic title in front of the tab-driven one; the tab-driven content
     this line protects is still the fallback and is asserted as such. */
  /* V245: the owner asked "Pending setup — where is it?", so the view names now match the
     nav row and the V244 tile group word-for-word. Same views, one vocabulary. */
  /* V271 put the owner's two new views (Overview, History) ahead of the older three in the same
     fallback chain; the tab-driven heading this line protects is unchanged in kind. */
  /* V334 (owner markup, photo 4: "bring here his logo"): the Points System heading led with the
     shared star icon. V341 (owner markup: "move the point system up to the header") moved that
     title (icon included) up to the page H1 for the four dedicated views — this h2 keeps the
     same fallback-chain text for aria-labelledby, just visually hidden on those four now. */
  assert.match(grow,/const h2TextV341=growActiveTopicV229\?esc\(growActiveTopicV229\.title\):\(programmeView==='overview'\?'Overview'/);
  assert.match(grow,/id="growTitle">\$\{programmeView==='setup'&&pendingGrowSetupRewardV303\?\.mode==='earning'\?\(pendingGrowSetupRewardV303\.kind==='stamps'\?'Stamp Card':'Point System'\):programmeView==='points'\?growPointsPageTitleV326/);
  assert.match(grow,/programmeView==='ongoing'\?'Ongoing programmes'/);
  assert.match(grow,/class="grow-programme-list"/);
  assert.match(app,/\.grow-programme-list\{display:grid;grid-template-columns:1fr/);
  assert.doesNotMatch(grow,/class="rewards-overview-grid"/,
    'the everyday overview must not return to a left/right reward grid');
  /* V364: there is no secondary block to sit after any more (owner: "remove this everywhere"),
     so the ordering assertion becomes the removal it enforces. */
  assert.match(grow,/id="rewardJourneyTitle"/);
  assert.doesNotMatch(grow,/id="growSecondarySettings"/);
});

test('configured and not-yet-configured programme families share the overview',()=>{
  /* The row builder now templates the attribute (`data-programme-kind="${esc(kind)}"`), so a
     literal `data-programme-kind="birthday"` no longer appears anywhere even though birthday is
     very much on the overview. Assert the kinds themselves, the same way the loop below already
     does, and assert the templated attribute exists once. */
  assert.match(grow,/data-programme-kind="\$\{esc\(kind\)\}"/,'rows must still carry their kind');
  for(const kind of ['earning','redeemable','birthday']){
    assert.match(grow,new RegExp(`kind:'${kind}'`),`${kind} is missing from the overview`);
  }
  /* V294 (owner markup 2026-08-12): gift cards left the Programmes overview — they are sold at
     the counter, not configured as a programme — so their row moved to the Serve & sell nav
     group. The page and its deep-linkable enable control survive (asserted below). */
  for(const kind of ['bringback','referrals','memberships']){
    assert.match(grow,new RegExp(`kind:'${kind}'`),`${kind} is missing from the overview`);
  }
  assert.match(grow,/Not set up/);
  assert.match(grow,/Not included/);
  assert.match(grow,/Read only/);
});

test('overview reads enough server state to label programme status without inventing setup',()=>{
  assert.match(snapshot,/referral_programs/);
  assert.match(snapshot,/membership_plans/);
  /* V301 (owner: "i already removed gift card - but it keeps appearing"): the Gift cards row
     this checkout-preferences read fed is gone (see v271 test + growProgrammeEntriesV271), and
     it was the only reader of the result inside growOverviewSnapshot, so the read left with it —
     one less RPC per Programmes Overview load. Gift cards still call this RPC from their own
     surfaces (Serve & sell, Customer Interface); this assertion only concerns this snapshot. */
  assert.doesNotMatch(snapshot,/sb\.rpc\('business_get_checkout_preferences_v102'/);
  // V271 added created_at so Programmes History can say when a bring-back reward ran.
  /* nestly_v429 (F): the snapshot's bring-back rows come from bringback_campaigns_v361, the engine that issues them, not from the legacy visit-frequency retention_programs table. */
  assert.match(snapshot,/bringback_campaigns_v361'\)\s*\n?\s*\.select\('id,name,reward_label,away_days,expiry_days,active,created_at'/);
  assert.match(snapshot,/overviewErrors:[\s\S]*referrals:[\s\S]*memberships:[\s\S]*promotions:/);
  /* V229/V358 replaced the per-programme retention ROWS on the overview with one Bring-back tile
     that reports a status. The point of this assertion — the label is read off real server state,
     never invented — is now carried by that tile's own status expression, which distinguishes
     "no module", "live", "configured but paused" and "not set up" from the same snapshot. */
  assert.match(grow,/const bringBackLiveV229=\(snapshot\.retention\|\|\[\]\)\.filter\(program=>program\?\.active!==false\)\.length;/);
  assert.match(grow,/bringBackLiveV229\?\[STATUS_WORDS\.on,'on'\]:snapshot\.retention\?\.length\?\['Paused','warn'\]:\['Not set up','warn'\]/);
  assert.match(grow,/const retentionOverviewState=program=>/);
  assert.match(grow,/startsOn>growAsOfDate/);
  assert.match(grow,/status:'Scheduled'/);
  /* The per-programme retention ROWS became History entries when V229/V358 turned the overview
     into topic tiles, so the status no longer travels as `status:/statusTone:` on a row. The
     property under test — the state is READ from the programme, never assumed — is unchanged and
     is now asserted at the one place that derives it. */
  assert.match(grow,/const overview=retentionOverviewState\(program\);/);
  assert.match(grow,/state:program\.active===false\?'retired':overview\.status==='Live'\?'live':'scheduled'/);
  assert.match(grow,/title:['"]Bring-back rewards['"][\s\S]*status:['"]Not set up['"]/);
  /* nestly_v558 (owner, photo 3: "turn on / off - no pause"). The referral row no longer has a
     "Paused" state — a configured programme that is not running reads OFF, the same word the
     birthday gift and the welcome offer use — and the owner turns it back on from the settings
     panel's own switch. The property under test is unchanged: the label is READ from the snapshot
     row, never invented. */
  assert.match(grow,/snapshot\.referral\?STATUS_WORDS\.off:['"]Not set up['"]/);
  assert.doesNotMatch(grow,/referralConfigured\?['"]Paused['"]/);
  assert.match(grow,/snapshot\.memberships\.length\?['"]Paused['"]:['"]Not set up['"]/);
  /* V301: overviewErrors.giftcards left with the read it reported on — there is no longer a
     retry banner to keep honest. */
  assert.doesNotMatch(snapshot,/overviewErrors:[\s\S]*giftcards:/);
  /* V371: birthday moved from a row to a topic tile and lost its unavailable state on the way —
     a failed read fell through to "Not set up", stating as fact that nothing is configured. Every
     tile now routes its status through growTileStatusV371, which names the read it depends on. */
  assert.match(grow,/const growTileStatusV371=\(errorKey,status\)=>\s*\n?\s*snapshot\.overviewErrors\?\.\[errorKey\]\?\['Unavailable','warn'\]:status;/);
  for(const source of ['loyalty','rewards','birthday','retention','referrals']){
    assert.match(grow,new RegExp(`growTileStatusV371\\('${source}'`),`${source} read failures need an honest unavailable state`);
  }
});

test('not-yet-configured standalone modules deep-link to the exact create control',()=>{
  assert.match(grow,/#\/referrals\/fe/);
  assert.match(grow,/#\/memberships\/mn/);
  /* V294: the giftCardEnabled deep link left the overview with its row; the page still wires
     the exact control, and the nav now carries the entry.
     V296 retarget (owner: "remove this"): 'giftCardEnabled' moved to Customer Interface, so it
     can no longer be this page's routed-focus FALLBACK — a fallback that resolves to nothing
     focuses nothing. The requirement (arriving here lands on the exact control) is unchanged; the
     control a person arriving at Gift cards needs is the amount field, and the moved switch has
     its own routable sub-tab. */
  assert.match(app,/focusRoutedWorkspaceControl\(routedFocus,'ga'\)/);
  /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely"): the Customer
     Interface sub-tab and the Serve & sell row are both gone, so the two lines that pinned them
     now pin their ABSENCE. The requirement this test is about — a deep link lands on the exact
     create control — is unchanged for every module that still has a nav entry. */
  assert.doesNotMatch(app,/\['giftcards','Gift cards','#\/customer-interface\/giftcards','giftcard'\]/);
  assert.doesNotMatch(app,/'bookings','waitlist','giftcards'\]\}/);
  assert.match(app,/async function referralsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/async function membershipsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/async function giftcardsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/focusRoutedWorkspaceControl\(routedFocus/);
});

test('earning, birthday, bring-back and stable reward routes retain exact edit intent',()=>{
  assert.match(grow,/function growFocusPath/);
  assert.match(grow,/reward~/);
  assert.match(grow,/routedFocus/);
  assert.match(grow,/decodeURIComponent/);
  assert.match(grow,/rewardId:kind==='catalogue'\?button\.dataset\.rewardId/);
  assert.match(grow,/directFocusTokens/);
  assert.match(grow,/data-program-id/);
  assert.match(grow,/program~/);
  assert.match(grow,/editProgramId:button\.dataset\.programId\|\|null/);
  assert.match(grow,/retentionPage\(draft,editProgramId/);
  assert.match(grow,/if\(!hashParamIsProgrammeView&&\(\(routedAction&&isOwner\)/);
  assert.match(retention,/const exactProgramMissing=Boolean\(editProgramId&&!editing\)/);
  assert.match(retention,/retentionExactProgramMissing/);
  assert.match(retention,/draftVersionId&&isOwner&&!exactProgramMissing/);
  assert.match(retention,/draftVersionId&&isOwner&&!exactProgramMissing\?`<div class="card"[^`]*Quick templates/);
  /* V332: the draft-row list moved inside a `${draftVersionId?(...):''}` wrapper (so the live,
     non-draft view could get its own Published/History renderer instead) — the per-row Edit
     button's gate is now isOwner&&!exactProgramMissing, with draftVersionId already implied by
     the wrapper it sits inside, rather than repeated on every row. */
  assert.match(retention,/\$\{draftVersionId\?\(programs\.length\?programs\.map\(r=>`<div class="row"/);
  assert.match(retention,/isOwner&&!exactProgramMissing\?`<button class="btn ghost sm retentionEdit"/);
});

test('read-only and unavailable rows expose status but no dead writer',()=>{
  assert.match(grow,/canWriteModule\('referrals'\)/);
  assert.match(grow,/canWriteModule\('memberships'\)/);
  /* V294: the gift-cards writer gate left the overview with its row (see above). */
  assert.match(grow,/programmeAction/);
  assert.match(grow,/if\(!canWrite\)return ''/);
  assert.match(grow,/const canSetupWinback=isOwner&&canWinback&&canWriteModule\('retention'\)/);
  /* V358/V364 rewrote the refusal copy when the overview became topic tiles; the guard this test
     exists for is the BEHAVIOUR — a row an employee cannot write offers no writer at all — which
     the `if(!canWrite)return ''` pin above already holds. The remaining check is that a
     non-writer is told to ask rather than shown a dead control. */
  /* A row an employee cannot write renders no writer at all (the pin above), and says why with a
     "Read only" marker rather than a dead control. */
  assert.match(grow,/readOnly\?'<span class="grow-programme-access">Read only<\/span>':''/);
});

/* V364 (owner markup 2026-08-16, photos 6 and 7): the collapsed "More reward settings" block —
   the Trigger/Who/Reward/Result journey, the reward-economics card and the Advanced tools details
   inside it — is gone from every rewards view. This test asserted it stayed collapsed; it now
   asserts it is absent, which is the same guard pointed the other way. */
test('the advanced journey, profitability and technical tools block is gone from the overview',()=>{
  assert.doesNotMatch(grow,/<details class="grow-secondary" id="growSecondarySettings">/);
  assert.doesNotMatch(grow,/id="profitabilityTitle"/);
  assert.doesNotMatch(grow,/<details class="grow-advanced"/);
});
