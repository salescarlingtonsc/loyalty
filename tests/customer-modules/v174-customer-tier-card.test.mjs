import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V174 customer tier card (owner request 2026-08-06, CHAGEE reference): the backend RPC
   customer_get_effective_tier_v143 already returns current/next tier, progress_percent,
   basis and metric, but the wallet only showed the tier name — the motivating half
   (progress bar, exact remaining, next-tier teaser) was computed and discarded. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

/* v194: the card became the Tier PANEL of a two-tab programme card (owner sketch: Tier /
   Reward points). The motivating half this suite exists to protect — progress bar, exact
   remaining in the business's own basis, escaping — is unchanged and still asserted here. */
const start = app.indexOf('function customerTierPanelMarkupV194');
assert.ok(start > 0, 'tier panel markup fn must exist');
/* v319: the slice starts at the rail constants, which the bar now calls into for both its fill
   and its label budget (customerTierRailProgressV319 / customerTierRailCompactV319). */
const src = app.slice(app.indexOf('const TIER_RAIL_LABEL_LIMIT_V319'),
  app.indexOf('function customerProgrammeSummaryTabsV194', start));
const ladder = app.slice(app.indexOf('function customerTierLadderMarkupV186'),
  app.indexOf('\nfunction customerTierRequirementTextV189'));
const requirement = app.slice(app.indexOf('function customerTierRequirementTextV189'),
  app.indexOf('function customerTierRemainingTextV186'));
const remaining = app.slice(app.indexOf('function customerTierRemainingTextV186'),
  app.indexOf('function customerProgrammeSummaryTabsV194'));
const escFn = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const rungIconSrc = app.slice(app.indexOf('function customerTierRungIconV195'),
  app.indexOf('const TIER_RAIL_LABEL_LIMIT_V319'));
const cuiStub = {icon:name=>`<svg data-icon="${name}"></svg>`};
const card = new Function('esc', 'CUI', `${rungIconSrc}\n${src}\n${ladder}\n${requirement}\n${remaining}; return customerTierPanelMarkupV194;`)(escFn, cuiStub);

test('remaining-to-next speaks the business basis, not percentages', () => {
  const visits = card({current:{label:'Explorer',threshold:10,benefits:[]},next:{label:'Pioneer',threshold:40,benefits:[]},progress_percent:90,basis:'visits',metric:37});
  assert.match(visits, /3 more visits to reach Pioneer/);
  const spend = card({current:null,next:{label:'Silver',threshold:300,benefits:['5% off']},progress_percent:41,basis:'spend',metric:123});
  assert.match(spend, /Spend SGD 177 more to reach Silver/);
  const points = card({current:{label:'A',threshold:0,benefits:[]},next:{label:'B',threshold:500,benefits:[]},progress_percent:20,basis:'points_earned',metric:100});
  assert.match(points, /Earn 400 more points to reach B/);
});

test('top tier gets its badge and no progress bar; empty tiers render nothing', () => {
  const top = card({current:{label:'Master',threshold:80,benefits:['VIP']},next:null,progress_percent:100,basis:'visits',metric:112});
  assert.match(top, /Top tier/);
  assert.doesNotMatch(top, /more visits to reach/);
  assert.match(card({}), /has not set up tiers yet/,
    'v194: the panel is inside a tab that always exists, so it says why it is empty');
});

/* v319 (owner, 2026-08-14: "the UI UX is being squeezed" — nine tiers, four icons stacked on the
   left of the track with their labels printed over one another, and a fill that agreed with none
   of them). The rail speaks one language now: the rung index. */
/* The rung icons are the only thing these three need beyond `esc`, and this suite is about
   POSITION, not iconography — v195 pins the star/crown/gem choice itself. */
const rail = new Function('esc', 'CUI', `${rungIconSrc}\n${src}\n${ladder}\n${requirement}\n${remaining}
  ; return {progress:customerTierRailProgressV319,compact:customerTierRailCompactV319,
    milestones:customerTierMilestonesMarkupV194};`)(escFn, cuiStub);
const ladderOf = (count, currentIndex) => ({tiers:Array.from({length:count},(unused,index)=>({
  label:`T${index+1}`,threshold:(index+1)*10,
  achieved:index<=currentIndex,current:index===currentIndex}))});
const round2 = value => Math.round(value * 100) / 100;   // the rail's own precision

test('the fill and the markers are on one scale — the rung index, not the threshold', () => {
  const nine = ladderOf(9, 3);                       // on rung 4 of 9
  /* progress_percent is progress THROUGH the current segment, so half way from rung 4 to rung 5
     is half of one ninth past the rung-4 marker — never 50% of the whole track. */
  assert.equal(rail.progress(nine, 0), round2((4 / 9) * 100));
  assert.equal(rail.progress(nine, 50), round2((4.5 / 9) * 100));
  assert.equal(rail.progress(nine, 100), round2((5 / 9) * 100));
  const marks = [...rail.milestones(nine).matchAll(/left:([\d.]+)%/g)].map(m => Number(m[1]));
  assert.equal(marks.length, 9);
  assert.equal(marks[3], Number(((4 / 9) * 100).toFixed(2)), 'the fill at 0% lands ON the rung-4 marker');
  assert.equal(marks[8], 100, 'the top rung is the end of the track');
  const gaps = marks.slice(1).map((at, index) => at - marks[index]);
  assert.ok(Math.max(...gaps) - Math.min(...gaps) < 0.05,
    'every rung gets the same room, whatever thresholds the firm set');
});

test('a customer below the first rung is in the opening runway, not standing on rung one', () => {
  const none = {tiers:ladderOf(4, -1).tiers};
  assert.equal(rail.progress(none, 0), 0);
  assert.equal(rail.progress(none, 50), Math.round(((0.5 / 4) * 100) * 100) / 100);
  assert.ok(rail.progress(none, 99) < 25, 'still short of the first marker at 25%');
});

test('past four rungs the rail drops its labels rather than stacking them', () => {
  assert.equal(rail.compact(ladderOf(4, 0)), false);
  assert.equal(rail.compact(ladderOf(5, 0)), true);
  assert.match(rail.milestones(ladderOf(4, 0)), /<b>T1<\/b>/, 'four names still fit at 390px');
  assert.doesNotMatch(rail.milestones(ladderOf(9, 0)), /<b>/,
    'nine do not — the names are in the sentences above and below, and in the ladder');
  const nine = card({...ladderOf(9, 3), current:{label:'T4',threshold:40,benefits:[]},
    next:{label:'T5',threshold:50,benefits:[]}, progress_percent:60, basis:'visits', metric:46});
  assert.match(nine, /class="customer-tier-bar is-compact"/,
    'and the card reclaims the 40px that row of labels used to reserve');
});

test('tier labels and benefits are escaped', () => {
  const hostile = card({current:{label:'<img src=x>',threshold:0,benefits:['<script>x</script>']},next:null,progress_percent:100,basis:'visits',metric:5});
  assert.doesNotMatch(hostile, /<img src=x>/);
  assert.doesNotMatch(hostile, /<script>x<\/script>/);
});

test('the wallet uses the panel instead of the old benefits-only section', () => {
  assert.match(app, /\$\{customerTierPanelMarkupV194\(tier\)\}/);
  /* V310 (W4b): the call site became the stack gate. The pinned expression is unchanged as a
     SUB-EXPRESSION — it is the whole fallback arm, so a pre-v310 server (`programmes` absent,
     which is also the rollback state) still renders the v194 tabs byte-identically. Only the
     `${` … `}` around it moved out to the ternary; the string this suite has always guarded is
     asserted verbatim, and the gate that chooses it is asserted beside it. */
  assert.match(app, /customerProgrammeSummaryTabsV194\(\{tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities\}\)/);
  assert.match(app, /\$\{programmeStackV310\(programmeCapabilities\)\n\s+\?customerProgrammeStackV310\(/);
  assert.match(app, /:customerProgrammeSummaryTabsV194\(\{tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities\}\)\}/);
  assert.doesNotMatch(app, /} benefits<\/h2><ul class="rec-why"/);
});
