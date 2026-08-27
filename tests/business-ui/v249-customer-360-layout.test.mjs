/* V249 — the owner annotated the Customer 360 page and drew the layout they want:
     name / contact
     [2 visits] [SGD 30.00 lifetime] [PDPA consent]     ← chips, one row
     [ POINTS 300 · expiry · Balance and earning · Correct balance ]  [ SPENDABLE CREDIT ]
   The yellow suggestion banner was struck out entirely, the four KPI cards became two, the
   rewards card heading became "Redeem now!", each redeemable row shows its point COST, and the
   "scan the pending QR" sentence was deleted with the scanner button pulled up under the list.
   These assertions pin that shape; none of them changes a handler, an RPC or a permission gate. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const profile = app.slice(
  app.indexOf('async function clientDetail(id){'),
  app.indexOf('async function tillPage(){')
);

test('V249 the struck-out suggestion banner is gone, markup and wiring alike', () => {
  for (const gone of [
    'c360-nba',
    'nbaHtml',
    'primaryNba',
    'secondaryNba',
    'c360Primary',
    'c360MoreBtn',
    'c360MoreMenu',
    'data-c360-secondary'
  ]) {
    assert.ok(!app.includes(gone), `the suggestion banner must leave nothing behind: ${gone}`);
  }
  /* Its wording is scoped to this page — WORKSPACE_GENERATED_COPY_V97 still carries retired
     translation keys and is never edited by a layout change. */
  for (const gone of ['Recommended next action', 'A reward is ready to redeem', 'More options']) {
    assert.ok(!profile.includes(gone), `banner copy must not survive on this page: ${gone}`);
  }
  /* Its Redeem reward button only scrolled to the rewards card, so no flow moved: redemption is
     still reached from that card, through the same branch-scoped scanner link. */
  assert.match(profile, /id="c360-loyalty"/);
  assert.match(profile, /Open Record sale scanner/);
  /* Its "More options" entries were duplicates of the header buttons, which still exist. */
  assert.match(profile, /id:'c360QuickEarn',label:'Record sale'/);
  assert.match(profile, /id:'c360NewAppt',label:'New appointment'/);
  assert.match(profile, /\$\('c360QuickEarn'\)\)\$\('c360QuickEarn'\)\.onclick=goQuickEarn/);
  assert.match(profile, /\$\('c360NewAppt'\)\)\$\('c360NewAppt'\)\.onclick=goNewAppt/);
});

test('V249/V294 the KPI tiles fold into the summary card and the identity line keeps status chips', () => {
  /* V294 (owner sketch 2026-08-12): the two remaining V249 tiles are GONE — points and credit
     are compact rows in the upper-right summary card, beside the moved visits / lifetime spend
     / PDPA rows. Demoted, never deleted: the counter still reads both numbers, and the V249
     scope-honest wording moved with the figures. */
  assert.ok(!profile.includes('const profileKpis=['), 'the KPI tile array is gone');
  assert.ok(!profile.includes('customer360-kpis-v249">'), 'no KPI row renders on the profile');
  const cardStart = profile.indexOf('const summaryCardV294=`');
  assert.ok(cardStart > 0, 'the summary card exists');
  const summaryCard = profile.slice(cardStart, profile.indexOf('</aside>`;', cardStart));
  assert.match(summaryCard, /Business-wide points/);
  /* V320 (owner 2026-08-14: "i do not want spendable credits to exist in the app"). V249's
     "demoted, never deleted" applied to the two figures it moved off the KPI tiles; the owner has
     since deleted one of them outright. Points still obeys the rule — it moved to the programme
     row in V319, it did not vanish. Credit is asserted absent so it cannot drift back. */
  assert.doesNotMatch(summaryCard.replace(/\/\*[\s\S]*?\*\//g,''), /spendable credit/i);
  assert.match(summaryCard, /isProfileAdmin\?'Visits':'Visible visits'/);
  assert.match(summaryCard, /isProfileAdmin\?'Lifetime spend':'Visible sales'/);
  assert.match(summaryCard, /PDPA consent/);

  // The identity line keeps STATUS chips only — the moved figures never render twice.
  const badgeStart = profile.indexOf('const badges=[];');
  const badges = profile.slice(badgeStart, profile.indexOf('const badgesHtml=', badgeStart));
  assert.doesNotMatch(badges, /visitsLabelV249|lifetimeSpendCents/);
  assert.match(badges, /label:'VIP'/);
  assert.match(badges, /label:'Regular'/);
  assert.match(badges, /label:'New customer'/);
  /* Two sentences the deleted banner was the only carrier of keep a home on this page: earning
     is conditional, and hidden figures are explained rather than shown as zero. */
  assert.match(profile, /canReadSales&&netVisits<=0\?`<p class="muted small"[^`]*Record an eligible first purchase; points are earned only when an active published loyalty programme applies\./);
  assert.match(profile, /Sales and reward figures are hidden because this role does not have access to those modules\./);
  // Chips carry text, not colour alone.
  assert.match(profile, /class="c360-badge \$\{b\.cls\}">\$\{CUI\.icon\(b\.icon,\{size:16\}\)\}\$\{esc\(b\.label\)\}/);
});

test('V249 the expiry note and both collapsibles live inside the POINTS card, once each', () => {
  // Exactly one definition of each collapsible in the whole bundle — moved, not copied.
  assert.equal((app.match(/<summary>Balance and earning<\/summary>/g) || []).length, 1);
  /* nestly_v512: the summary follows the RUNNING unit — the control writes to whichever
     programme is live, so a stamp-card business reads "Correct stamp balance". Matched as a
     plain substring because the source now holds a template expression, not literal text. */
  assert.equal(app.split('Correct ${esc(unit==="stamps"?"stamp":"points")} balance').length - 1, 1);
  assert.equal((app.match(/id="adjV"/g) || []).length, 1);
  assert.equal((app.match(/id="adjGo"/g) || []).length, 1);
  assert.equal((app.match(/c360-points-expiry/g) || []).length, 1);

  // Both are built into the panel variable the POINTS card renders.
  const panelStart = profile.indexOf('pointsPanelDetailsV249=`');
  assert.ok(panelStart > 0, 'the moved collapsibles are assigned to the points panel');
  const panel = profile.slice(panelStart, profile.indexOf('  }else{', panelStart));
  assert.match(panel, /<summary>Balance and earning<\/summary>/);
  assert.ok(panel.includes('Correct ${esc(unit==="stamps"?"stamp":"points")} balance'), "the adjust collapsible is inside the points panel");
  assert.ok(panel.indexOf('Balance and earning') < panel.indexOf('} balance</summary>'),
    'balance and earning comes first, as drawn');
  // Their handlers and gates are untouched: owner-only, loyalty-write-only adjustment.
  assert.match(panel, /S\.myRole==='owner'&&canWriteLoyalty\?`<details/);
  assert.match(profile, /\$\('adjGo'\)/);

  /* V294: the POINTS card became the summary card's points row — same order preserved: the
     expiry note under the points value, both collapsibles at the card's foot. */
  const pointsHost = profile.slice(profile.indexOf('const summaryCardV294=`'), profile.indexOf('</aside>`;'));
  assert.ok(pointsHost.indexOf('${pointsExpiryMarkup}') < pointsHost.indexOf('pointsPanelDetailsV249'),
    'expiry note sits above the collapsibles');
  assert.match(pointsHost, /customer360-points-panel-v249/);
  assert.match(profile, /No actionable points are currently scheduled to expire\./);

  // Neither collapsible is left behind in the rewards card body.
  const rewardsStart = profile.indexOf('rewardsMarkup=`${readyRewards.length');
  const rewards = profile.slice(rewardsStart, panelStart);
  assert.doesNotMatch(rewards, /Balance and earning|Correct points balance/);

  // Minimal supporting CSS exists and stacks the two cards on a phone.
  assert.match(shell, /\.customer360-points-panel-v249\{/);
  assert.match(shell, /@media\(max-width:560px\)\{\.customer360-kpis-v249\{grid-template-columns:minmax\(0,1fr\)\}\}/);
});

test('V249 the rewards card says "Redeem now!" and shows each reward point cost', () => {
  assert.match(profile, /<p class="eyebrow" style="margin-top:8px">Redeem now!<\/p>/);
  assert.ok(!app.includes('Ready to redeem now'), 'the old counted heading is gone');
  // A claimable row shows its cost; a row that is not claimable keeps its honest state.
  assert.match(profile, /const rewardCostLabelV249=reward=>\{const cost=Number\(reward\.cost_units\)/);
  assert.match(profile, /ready\?esc\(rewardCostLabelV249\(reward\)\)/);
  assert.match(profile, /!redemptionEnabled\?'Unavailable'/);
  assert.match(profile, /\$\{Math\.max\(0,Number\(reward\.remaining_units\)\|\|0\)\} more \$\{unit\}/);
  // No bare "Ready now" pill on a claimable row any more — only the no-cost fallback.
  assert.equal((profile.match(/'Ready now'/g) || []).length, 1);
});

test('V249 the scan sentence is gone and the scanner button sits under the reward list', () => {
  assert.ok(!app.includes("Scan the customer's pending QR"), 'the deleted sentence is gone');
  assert.ok(!app.includes('Points change only after confirmation.'));
  // Same permission gate, same destination — only the position and the wrapper changed.
  assert.match(profile,
    /canWriteLoyalty&&redemptionEnabled&&readyRewards\.length\?`<a class="btn sm" href="#\/till"[^`]*Open Record sale scanner/);
  const rewardsStart = profile.indexOf('rewardsMarkup=`${readyRewards.length');
  const rewards = profile.slice(rewardsStart, profile.indexOf('pointsPanelDetailsV249=`', rewardsStart));
  assert.ok(rewards.indexOf('readyRewards.map(reward=>rewardRow(reward,true))') <
    rewards.indexOf('Open Record sale scanner'),
    'the scanner follows the reward list');
  assert.ok(rewards.indexOf('Open Record sale scanner') < rewards.indexOf('Coming up'),
    'and precedes everything the collapsibles used to sit below');
});

/* ---------- nestly_v567: the Earn line never invents a rate the business never set ---------- */

/* EXECUTED, not grepped. This block printed "1 stamp for every $5.00" and "0 points for every
   SGD 1" over a programme whose earn rate the server had not sent — the first a rate nobody
   chose, the second the exact opposite of the truth. Its neighbour `loyaltyFactsAvailable`
   already refuses to print zero in place of an unread balance; this is the same discipline one
   field over, so it is proved by running it. */
const earnLine = (prog, stamps) => new Function('prog', 'stamps', 'esc', 'money', 'DASH_V541', `
  ${(() => {
    const from = app.indexOf('    const stampCentsV567=Number(prog.stamp_per_cents);');
    const end = "Peekaa is not guessing one.\">${DASH_V541}</span></p>`;";
    const to = app.indexOf(end, from);
    assert.ok(from >= 0 && to > from, 'the v567 earn-line block was found');
    return app.slice(from, to + end.length);
  })()}
  return {earnCopy, earnLineV567};`)(
  prog, stamps,
  v => String(v ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  c => 'SGD ' + ((c || 0) / 100).toFixed(2),
  '\u2014');

test('nestly_v567 a stamps programme with no spend-per-stamp says nothing at all', () => {
  for (const missing of [{}, { stamp_per_cents: null }, { stamp_per_cents: 0 },
    { stamp_per_cents: 'later' }, { stamp_per_cents: -100 }]) {
    const out = earnLine(missing, true);
    assert.equal(out.earnCopy, '', `no invented rate for ${JSON.stringify(missing)}`);
    assert.equal(out.earnLineV567, '', 'and no Earn line at all');
  }
  /* The $5.00 the old `||500` produced must not be reachable from an unset field. */
  assert.doesNotMatch(earnLine({ stamp_per_cents: null }, true).earnLineV567 || '', /5\.00/);
});

test('nestly_v567 a real spend-per-stamp still prints exactly as it always did', () => {
  const out = earnLine({ stamp_per_cents: 800 }, true);
  assert.equal(out.earnCopy, '1 stamp for every SGD 8.00 spent');
  assert.match(out.earnLineV567, /<b>Earn:<\/b> 1 stamp for every SGD 8\.00 spent/);
});

test('nestly_v567 a missing points rate is an em-dash with a reason, never the number 0', () => {
  for (const missing of [{}, { earn_points_per_dollar: null }, { earn_points_per_dollar: 0 },
    { earn_points_per_dollar: 'x' }]) {
    const out = earnLine(missing, false);
    assert.equal(out.earnCopy, '');
    assert.match(out.earnLineV567, /data-c360-earn-unset-v567/);
    assert.match(out.earnLineV567, /\u2014/, 'the em-dash the rest of this page uses for an empty cell');
    assert.match(out.earnLineV567, /title="No earn rate is saved for this programme yet\./);
    assert.doesNotMatch(out.earnLineV567, /0 points for every/,
      '"0 points for every SGD 1" tells the counter the customer earns nothing');
  }
});

test('nestly_v567 a real points rate still prints exactly as it always did', () => {
  const out = earnLine({ earn_points_per_dollar: 2 }, false);
  assert.equal(out.earnCopy, '2 points for every SGD 1 spent');
  assert.doesNotMatch(out.earnLineV567, /data-c360-earn-unset-v567/);
});
