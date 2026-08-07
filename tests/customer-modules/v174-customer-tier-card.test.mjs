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
const src = app.slice(app.indexOf('function customerTierMilestonesMarkupV194'),
  app.indexOf('function customerProgrammeSummaryTabsV194', start));
const ladder = app.slice(app.indexOf('function customerTierLadderMarkupV186'),
  app.indexOf('\nfunction customerTierRequirementTextV189'));
const requirement = app.slice(app.indexOf('function customerTierRequirementTextV189'),
  app.indexOf('function customerTierRemainingTextV186'));
const remaining = app.slice(app.indexOf('function customerTierRemainingTextV186'),
  app.indexOf('function customerProgrammeSummaryTabsV194'));
const escFn = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const card = new Function('esc', `${src}\n${ladder}\n${requirement}\n${remaining}; return customerTierPanelMarkupV194;`)(escFn);

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

test('tier labels and benefits are escaped', () => {
  const hostile = card({current:{label:'<img src=x>',threshold:0,benefits:['<script>x</script>']},next:null,progress_percent:100,basis:'visits',metric:5});
  assert.doesNotMatch(hostile, /<img src=x>/);
  assert.doesNotMatch(hostile, /<script>x<\/script>/);
});

test('the wallet uses the panel instead of the old benefits-only section', () => {
  assert.match(app, /\$\{customerTierPanelMarkupV194\(tier\)\}/);
  assert.match(app, /\$\{customerProgrammeSummaryTabsV194\(\{tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities\}\)\}/);
  assert.doesNotMatch(app, /} benefits<\/h2><ul class="rec-why"/);
});
