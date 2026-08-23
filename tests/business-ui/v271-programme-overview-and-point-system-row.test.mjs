/* V271 — one owner screenshot of Programmes → the loyalty programme, marked up in red.

   A. The POINT SYSTEM row. The owner struck "Change model", struck "paused" out of the heading and
      wrote "Point System" beside it, struck the sentence "Open Edit to turn it on. Configured as
      Earn 1 points per SGD 1 spent" with "remove wording", struck the Paused pill, and wrote
      underneath: "Current Setting: SGD 1 spent → 1 points" with a circled Edit.

      Three separate things said "paused". The instruction is de-duplication, not concealment: a
      paused point system earns customers nothing, and an owner who cannot see that state blames
      the engine. Exactly ONE status indicator survives — the pill in the row's meta column, which
      is also the signal the Ongoing/Pending filter and the suggestion strips read (they match
      `.pill:not(.grow-pending-pill-v268)`), so removing it would have silently emptied those views.

   B. Programmes gets three views: Overview (a columnar at-a-glance table of what is running),
      List (unchanged), History (what has ended). The honesty rule the Overview lives by: a cell is
      sourced or it is absent. A count nothing records renders "Not tracked"; a count whose read
      failed renders "Not available". Neither ever renders 0, because a zero reads as a measurement.

   C. Two delegated decisions. The duplicate "A thank-you on your next visits" rewards are not
      deleted — the retired one is already invisible to customers and the defect is that the editor
      drew both identically — so the labelling is fixed instead. And the overloaded Paused pill is
      split: a reward the owner retired and a reward that is off only because the programme is off
      no longer read the same. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260810_nestly_v271_programme_overview.sql'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
/* The writable Point system row only — it ends where the read-only <article> variant begins. */
const pointSystemRow = () =>
  section('data-rewards-overview-edit="earning">', ':`<article class="grow-programme-row" data-programme-kind="earning">');

/* ---------------- A. the Point system row ---------------- */

test('V271 (a) every struck string is gone from the application code', () => {
  assert.doesNotMatch(app, /Point system paused/);
  assert.doesNotMatch(app, /'Change model'/);
  assert.doesNotMatch(app, /Open Edit to turn it on/);
  assert.doesNotMatch(app, /Configured as \$\{rewardJourney/);
  assert.doesNotMatch(app, /customers earn nothing and no reward below is claimable/);
  /* V371: one constant now feeds both the view resolver and the deep-link guard. They used to be
     separate literals and drifted — V366 added 'bringback' to the resolver only, so the Bring-back
     page also mounted a deep editor surface with a view name where a draft id belongs. */
  assert.match(app, /const GROW_PROGRAMME_VIEWS_V371=Object\.freeze\(\['overview','history','offers','points','tiers','bringback','birthday','ongoing','available','settings','setup'\]\);/);
  assert.match(app, /const programmeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list'/);
  assert.match(app, /const hashParamIsProgrammeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\);/);
});

test('V271 (a) the heading is an unconditional "Point system"', () => {
  const row = pointSystemRow();
  // One heading, no ternary that could reintroduce a state word into the title.
  assert.match(row, /<div><b>Point system<\/b>/);
  assert.doesNotMatch(row, /<b>\$\{rewardJourney\.earning\.availableToCustomers\?/);
});

test('V271 (a) the current-setting line is DERIVED, never a hardcoded 1 or a hardcoded SGD', () => {
  const derive = section('const growCurrencyV271=', 'const rewardsOverviewIncomplete=');
  assert.match(derive, /const growCurrencyV271=S\.biz\?\.currency\|\|'SGD';/);
  // The rate comes from the configured value on the programme, not a literal in the string.
  assert.match(derive, /Math\.max\(0,Number\(earning\.rate\)\|\|0\)/);
  assert.match(derive, /\$\{growCurrencyV271\} 1 spent → \$\{growEarnUnitV271\(/);
  assert.match(derive, /\$\{growCurrencyV271\} \$\{\(Math\.max\(0,Number\(earning\.rate\)\|\|0\)\/100\)\.toFixed\(2\)\} spent → 1 stamp/);
  assert.match(derive, /const earningOverviewCopy=`Current setting: \$\{growEarnRateTextV271\(rewardJourney\.earning\)\}`;/);
  // No literal "SGD 1 spent" or "1 point" anywhere in the derivation.
  assert.doesNotMatch(derive, /SGD 1 spent/);
  // ...and rewardJourney.earning.label, which hardcodes SGD, is deliberately not reused here.
  assert.doesNotMatch(derive, /rewardJourney\.earning\.label/);
});

test('V271 (a) the line pluralises the unit rather than always saying "points"', () => {
  assert.match(app,
    /growEarnUnitV271=\(value,unit\)=>`\$\{value\} \$\{Number\(value\)===1\?\(unit==='stamps'\?'stamp':'point'\):\(unit==='stamps'\?'stamps':'points'\)\}`/);
});

test('V271 (a) exactly ONE status indicator survives on that row', () => {
  const row = pointSystemRow();
  const pills = row.match(/programmeStatus\(/g) || [];
  assert.equal(pills.length, 1, 'the writable row must carry one status pill and no other');
  // It is the pill, and it still tells the truth in both directions.
  assert.match(row,
    /programmeStatus\(rewardJourney\.earning\.availableToCustomers\?'Live':'Paused',rewardJourney\.earning\.availableToCustomers\?'on':'off'\)/);
  // The status must NOT have moved back into the heading or the copy line.
  assert.doesNotMatch(row, /Point system[^<]*[Pp]aused/);
  assert.doesNotMatch(row, /[Pp]aused —/);
  // The copy line is the derived setting and nothing else.
  assert.match(row, /<p class="muted small">\$\{esc\(earningOverviewCopy\)\}<\/p>/);
  // The filter that builds the Ongoing / Pending views reads exactly this pill.
  assert.match(app, /row\.querySelector\('\.pill:not\(\.grow-pending-pill-v268\)'\)/);
});

test('V271 (a) the Edit control on the row survives, and still opens the model editor', () => {
  const row = pointSystemRow();
  assert.match(row, /<span class="grow-programme-action">Edit →<\/span>/);
  // Deleting "Change model" strands nothing: this Edit resolves to the SAME destination it did.
  assert.match(app, /focusTarget:kind==='earning'\?'lm'/);
  assert.match(app, /if\(focusTarget==='lm'\)return \{kind:'earning'\}/);
  // ...and that destination is the editor's four-way model toggle.
  assert.match(app, /data-loyalty-model-v235="\$\{key\}"/);
  assert.match(app, /\['redeem','tiers','both','stamps'\]\.map\(key=>/);
});

test('V271 (a) removing the chooser button leaves no empty row behind', () => {
  assert.match(app, /if\(!showLiveModelsV250\)return '';/);
  assert.match(app, /const growPointsChooserRowV271=growPointsModeChooserV229\(\{showLiveModelsV250:false\}\);/);
  assert.match(grow, /growActiveTopicV229&&growPointsChooserRowV271\?`<div class="grow-programme-row points-mode-row-v229">/);
});

/* ---------------- B. three views ---------------- */

test('V271 (b) all three views exist, resolve from the hash, and keep the old ones working', () => {
  /* V301 ADDITION, not a weakening (owner 2026-08-13: "ONE page with step subtabs… publish at
     completion, no popups"). The setup wizard is a fourth VIEW of this same page, so 'setup'
     joins the list; V271's own three views and the two legacy hashes still resolve exactly as
     they did, which is what the assertions below check. */
  // A view hash must never be mistaken for an engine deep link (that crashed on the surface map).
  // Each view names itself in the heading.
  assert.match(app, /programmeView==='overview'\?'Overview':programmeView==='history'\?'History'/);
});

test('V271 (b) the three views are reachable, each with its own linkable hash', () => {
  /* V296 retarget (owner circled the in-page strip on 2026-08-12 and wrote "remove"), NOT a
     weakening. V271's requirement is that all three views are REACHABLE and each has its own
     linkable hash. V294 made them children of the Programmes nav group, so the in-page strip was
     the same three destinations printed a second time one line below. The strip is gone; the
     three hashes and their resolution are asserted here directly, and the rail entries below. */
  assert.match(app, /views:\[\['Overview','#\/grow\/overview','reports'\],\['Rewards Programme','#\/grow','star'\],\s*\['Limited Offer','#\/grow\/offers','tag'\],\['History','#\/grow\/history','waitlist'\]\]/);
  assert.match(app, /const navViewActiveV296=href=>\{/);
  /* V319: a fourth child ('offers') joined, so the "everything else belongs to the list" branch
     had to exclude it too, or the Limited Offer hash would light two rail rows at once. */
  assert.match(app, /if\(routeKey==='grow'\)return routeView\?page\[1\]===routeView:!\['overview','history','offers'\]\.includes\(String\(page\[1\]\|\|''\)\)/);
  assert.doesNotMatch(app, /data-grow-view-v271/);
  assert.doesNotMatch(app, /aria-label="Programme views"/);
  /* The shared sub-module strip styling stays — other pages still use it.
     V458 loosened this from a literal declaration-ORDER match to the two properties it was
     actually guarding. The rule gained flex-wrap:wrap, because at phone widths the #/reports
     strip scrolled with its scrollbar suppressed and the fourth tab ("Team Performance", whose
     only door this strip is since V272) was not hit-testable at all — see
     tests/browser/verify-v458-ladder-and-report-tabs.mjs, which measures that rather than
     grepping for it. A pin on the exact byte order of a declaration list fails on any edit to
     that list, including the fix for a bug it was never watching for. */
  const subtabsRule = /\.section-subtabs-v200\{([^}]*)\}/.exec(html)?.[1] || '';
  assert.match(subtabsRule, /display:flex/);
  assert.match(subtabsRule, /max-width:100%/);
});

test('V271 (b) Overview and History replace the category list rather than stacking on it', () => {
  /* V301: the setup wizard replaces the category list for the same reason Overview and History
     do — showing both would put the same programme on the page twice, under two shapes. */
  assert.match(app, /const growCategoryViewV271=!\['overview','history','setup','offers','points','tiers','bringback','birthday'\]\.includes\(programmeView\);/);
  assert.match(app, /const topicOnV229=key=>!growCategoryViewV271\?false:\(growActiveTopicV229\?growTopicSectionV235===key:!growTilesModeV229\);/);
  assert.match(grow, /\$\{programmeView==='overview'\?`\$\{growOverviewTableV271\}\$\{growAnalyticsCardV375\}`:''\}/);
  assert.match(grow, /\$\{programmeView==='history'\?growHistoryTableV271:''\}/);
});

test('V271 (b) Overview is a columnar table with the columns the owner still wants', () => {
  /* V319 (owner sketch: "two side view", two named categories) split this into two tables. The
     columns the V271 owner named are the ones the REWARDS table still carries; the offers table
     is checked separately below, because dropping a count nothing records was the point of it. */
  const table = section('const growOverviewRewardsTableV319=', 'const growOverviewOffersTableV319=');
  /* V324: the Programme column is built by a helper that needs the row LIST as well as the row —
     the child indent may only be drawn when a parent row precedes — so it is no longer an inline
     `['Programme',row=>…]` pair. The column and its heading are unchanged. */
  /* V324 (owner markup 2026-08-14) struck the Type column through. What it carried — that a
     reward belongs to the programme above rather than beside it — moved into the name cell as an
     indent, so the information survives the column. See v319-rewards-and-offer.test.mjs, which
     renders both rows and asserts the parent is NOT indented and the child is. */
  assert.doesNotMatch(table, /\['Type',row=>esc\(row\.type\)\]/);
  assert.match(table, /growOverviewNameColumnV324\(growOverviewRewardRowsV319,'Programme'\)/);
  assert.match(table, /\['Started',row=>growDateCellV271\(row\.started\)\]/);
  /* V468 (owner photo 5, 2026-08-23) struck "Customers used" out — the second column the owner's
     own pen has removed from this table, after Type in V324. The count is not lost: the
     per-category analytics block below carries it per gift, and counts USES rather than distinct
     customers, which is the reading the owner asked for on that same screenshot. */
  assert.doesNotMatch(table, /\['Customers used'/);
  // Only what is running is on this table.
  assert.match(app, /const growOverviewRowsV271=growProgrammeEntriesV271\.filter\(entry=>entry\.state==='live'\);/);
  // House table idiom, so 390px is handled by the existing data-label rules.
  assert.match(app, /<table class="cui-table" data-responsive="true">/);
  assert.match(app, /<td data-label="\$\{esc\(column\[0\]\)\}">/);
  assert.match(html, /\.cui-table\[data-responsive="true"\] td::before\{content:attr\(data-label\)/);
});

test('V271 (b) an unsourceable cell says so — it is never a zero', () => {
  assert.match(app,
    /const growCountCellV271=value=>value==null\s*\r?\n?\s*\?`<span class="muted">\$\{growUsageV271\?'Not tracked':'Not available'\}<\/span>`\s*\r?\n?\s*:esc\(String\(Number\(value\)\)\);/);
  /* V324 (owner: "all date use dd/mm/yyyy format"). The cell's CONTRACT is what this test is
     about and it is unchanged — an unparseable date still says "Not tracked" and never a zero or
     a blank. Only the formatter it delegates to changed, and promotionDateShortV324 resolves the
     same instant as promotionDateTextV104 (noon SGT for a bare date), so the two cannot disagree
     about which day it is. */
  assert.match(app,
    /const growDateCellV271=value=>Number\.isFinite\(Date\.parse\(value\|\|''\)\)\s*\r?\n?\s*\?esc\(promotionDateShortV324\(value\)\):'<span class="muted">Not tracked<\/span>';/);
  // Promotions are a programme with no usage record at all.
  const entries = section('const growProgrammeEntriesV271=', 'const growOverviewRowsV271=');
  assert.match(entries, /type:'Promotion',[\s\S]{0,340}?customers:null/);
  /* V301 (owner: "i already removed gift card - but it keeps appearing"): gift cards used to be
     the other such row. V294 moved gift-card management to Serve & sell and V296 moved its
     switch to Customer Interface, but neither touched businesses.gift_card_sales_enabled — the
     flag this row's gate read — so the row kept reappearing after the owner "removed" it. It
     must not come back. */
  assert.doesNotMatch(entries, /name:'Gift cards',type:'Gift cards'/);
  // A failed usage read must not be laundered into zeros anywhere.
  assert.doesNotMatch(app, /growUsageV271\?\.[a-z_]+\?\.customers\|\|0/);
  assert.doesNotMatch(app, /customers:Number\([^)]*\)\|\|0/);
});

test('V271 (b) every Overview number names its source', () => {
  const entries = section('const growProgrammeEntriesV271=', 'const growOverviewRowsV271=');
  // The earning row: first published config version + the server's own count of earn events.
  assert.match(entries, /started:growFirstPublishedV271/);
  /* nestly_v413: the scope is chosen by the engine this firm is running rather than hardcoded to
     point_system, so the assertion follows the same indirection. What V271 is guarding here is
     unchanged and still guarded: the number comes from growUsageV271 — the server's own count —
     and falls to null rather than to 0 when the server did not answer. The behaviour behind this
     source match is EXECUTED in tests/business-ui/v413-owner-batch4.test.mjs.
     V468 (owner photo 4: "It should be number of times, not how many customers used"): the figure
     these rows carry is now 'uses' — the count of the events — rather than the distinct-customer
     count. The rule V271 wrote this test for is untouched: the number still comes from
     growUsageV271, the server's own count, and still falls to null rather than to 0 when the
     server did not answer. Only which of the server's two figures is read has changed. */
  assert.match(entries, /const growEarningScopeV413=growEarningSpineKindV388==='stamps'\?'stamp_card':'point_system';/);
  assert.match(entries, /uses:growUsageV271\?\(growUsageV271\[growEarningScopeV413\]\?\.uses\?\?null\):null/);
  // Rewards: the reward's own created_at + its redemption count.
  assert.match(entries, /started:reward\.created_at\|\|null/);
  assert.match(entries, /uses:growRewardUsageV271\.get\(String\(reward\.id\)\)\?\?null/);
  // Bring-back: the programme's own start date + its redeemed-grant count.
  assert.match(entries, /started:program\.starts_on\|\|program\.created_at\|\|null/);
  assert.match(entries, /uses:growRetentionUsageV271\.get\(String\(program\.id\)\)\?\?null/);
  // The reads those columns depend on are actually requested.
  assert.match(app, /claim_available_until,created_at'\)/);
  /* nestly_v429 (F): the bring-back row's own read is bringback_campaigns_v361 now — the engine that issues bring-backs — so the column it names its start date from is that table's created_at. */
  assert.match(app, /sb\.from\('bringback_campaigns_v361'\)\s*\n?\s*\.select\('id,name,reward_label,away_days,expiry_days,active,created_at'\)/);
  assert.match(app, /sb\.from\('membership_plans'\)\.select\('id,name,active,created_at'\)/);
  /* V322 (OWNER RULING R1/R4 — "why referral is a stored credits? please remove it as i already
     said no more store credits"): the referral payout is POINTS now, so the live column this
     Overview row's number is READ FROM moved from reward_cents to reward_points. The fact this
     line protects is untouched and is the whole point of the test — the Overview never invents a
     referral number, it names the live column it came from — only the column's name moved.
     reward_kind rides along on the same select so a later non-points payout has somewhere to be
     read from rather than somewhere to be invented. */
  /* nestly_v421: the friend's side of the referral is paid from the same row, so it is read from
     the same select. Same rule, three more columns — the Overview still names where its number
     came from and still invents nothing. */
  assert.match(app, /sb\.from\('referral_programs'\)\.select\('id,enabled,reward_points,reward_kind,reward_label,min_spend_cents,friend_enabled,friend_reward_points,friend_reward_label,created_at'\)/);
  assert.match(app, /sb\.rpc\('business_programme_usage_v271',\{p_business:S\.biz\.id\}\)/);
  assert.match(app, /sb\.from\('firm_config_versions'\)\.select\('published_at'\)[\s\S]{0,180}?order\('published_at',\{ascending:true\}\)/);
});

test('V271 (b) History is what STOPPED — a paused programme is not filed as expired', () => {
  assert.match(app,
    /const growHistoryRowsV271=growProgrammeEntriesV271\.filter\(entry=>entry\.state==='ended'\|\|entry\.state==='retired'\);/);
  /* V324: History now renders through the same two-column frame as Overview ("history UI/UX
     follow overview"), so its columns are defined on the two per-category tables above the frame
     call — the section starts there. */
  const table = section('const growHistoryRewardRowsV324=', '/* One strip, three destinations');
  assert.match(table, /\['Ran from',row=>growDateCellV271\(row\.started\)\]/);
  assert.match(table, /\['Ran until',row=>growDateCellV271\(row\.ended\)\]/);
  /* "don't need this" is written across the WHY IT STOPPED column in the same markup. The
     distinction it spelled out still reaches the screen through "Ran until": a programme that
     reached its end date has one, a retired row does not. */
  assert.doesNotMatch(table, /\['Why it stopped',/);
  // The two ways a programme lands here, derived rather than assumed.
  const entries = section('const growProgrammeEntriesV271=', 'const growOverviewRowsV271=');
  assert.match(entries, /reward\.active===false\?'retired'/);
  assert.match(entries, /milestone\?\.availability==='ended'\?'ended'/);
  /* V288: the inline derivation read ends_at and never starts_at, so a future-dated published
     promotion was filed as Ongoing. The shared lifecycle predicate owns this now. */
  assert.match(entries, /const lifecycle=promotionLifecycleV186\(promotion\);/);
  assert.match(entries, /state:lifecycle\.state,/);
});

test('V271 (b) the new server read is curated in the PS0 writer registry', () => {
  const registry = readFileSync(join(root, 'docs', 'design', 'ps0', 'writer-registry.json'), 'utf8');
  assert.match(registry, /browser\.rpc:app\/app\.js:business_programme_usage_v271/);
});

test('V271 (b) the pending migration keeps its honesty contract and its grants', () => {
  assert.match(migration, /^begin;/m);
  assert.match(migration, /^commit;/m);
  assert.match(migration, /revoke all on function public\.business_programme_usage_v271\(uuid\) from public, anon;/);
  assert.match(migration, /grant execute on function public\.business_programme_usage_v271\(uuid\) to authenticated;/);
  // Read-only, and authorised exactly like the counter already on this screen.
  assert.match(migration, /stable security definer/);
  assert.doesNotMatch(migration, /\b(insert into|update |delete from)\b/i);
  assert.match(migration, /app\.is_salon_owner\(p_business\) or app\.can_module_read\(p_business, 'loyalty'\)/);
  // Distinct CUSTOMERS, not row counts.
  assert.match(migration, /count\(distinct client_id\)::int into v_point_customers/);
  assert.match(migration, /count\(distinct redemption\.client_id\)/);
  // The two deliberate nulls.
  assert.match(migration, /'promotions', jsonb_build_object\('customers', null\)/);
  assert.match(migration, /'gift_cards', jsonb_build_object\('customers', null\)/);
});

/* ---------------- C. the two delegated decisions ---------------- */

test('V271 (c) nothing is deleted — the retired duplicate is still rendered', () => {
  // The archived catalogue keeps its card; the fix was the label, not a removal.
  assert.match(app, /\.\.\.rewardJourney\.archivedRewards\.map\(reward=>\(\{/);
  assert.match(app, /const archivedRewards=allRewards\.filter\(reward=>reward\?\.active===false\)/);
});

test('V271 (c) retired and programme-paused rewards carry different, plain-language labels', () => {
  const cards = section('const rewardCardStatusV250=', 'const rewardCardGridV250=');
  assert.match(cards, /milestone\.availability==='programme_paused'\?\['Paused with programme','off'\]/);
  assert.match(cards, /status:'Retired',tone:'off'/);
  // A genuinely live reward still reads as live (V180 renders 'Live' as the house word 'Ongoing').
  assert.match(cards, /milestone\.availableToCustomers\?\[STATUS_WORDS\.on,'on'\]/);
  assert.match(app, /const PROGRAMME_STATUS_LABEL_V180=\{Live:STATUS_WORDS\.on\}/);
  // The two labels are genuinely different strings, so neither can be mistaken for the other.
  assert.notEqual('Retired', 'Paused with programme');
});

test('V271 (c) the editor list says the same two things, and disambiguates same-named rewards', () => {
  const editor = section('const rewardStatusV271=', 'const rewardRows=(label)=>');
  assert.match(editor, /r\?\.active===false\?\{label:'Retired',tone:'off'\}/);
  /* V293 (owner walkthrough 2026-08-12): "Paused with programme" on a fresh reward read as the
     REWARD being retired. Same truth, said of the programme — plus a helper line above the
     list — so a paused programme's rewards never read as dead. */
  assert.match(editor, /:p\?\.active===false\?\{label:'Programme paused',tone:'off'\}/);
  assert.match(editor, /:rewardBoundary\(r\)/);
  // The duplicate-name case the owner circled: each says when it was added.
  assert.match(editor, /const rewardNameCountsV271=\(rewards\|\|\[\]\)\.reduce\(/);
  assert.match(editor, /rewardNameCountsV271\[rewardLabel\(r\)\.toLowerCase\(\)\]>1/);
  assert.match(editor, /r\?\.created_at\?`Added \$\{walletDate\(r\.created_at,true\)\}`:'Added date not recorded'/);
  assert.match(editor, /Retired — customers cannot see or claim this/);
  // The row actually uses them.
  /* V294: the rows render through the shared builder — offerable rows in the catalogue,
     retired/ended rows in Reward history — same status derivation, same identity line. */
  assert.match(app, /offerable\.map\(r=>rewardItemHtmlV294\(r,rewardStatusV271\(r\)\)\)/);
  assert.match(app, /\$\{rewardIdentityLineV271\(r\)\}/);
});
