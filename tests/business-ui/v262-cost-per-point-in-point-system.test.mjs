/* V262 — owner report item 5: "cost per point is not something that firm can easily change
   during setting up of certain rewards. it must be at 'point system'".

   Cost per point is a programme-wide economic constant, so it is set once in the Point system
   editor and is read-only everywhere a reward is edited. No new column was added: redeem_points
   and reward_credit_cents already express exactly this quantity (what one point costs the
   business in credit), and the pre-V262 code already fell back to their ratio — so the ratio is
   surfaced as the single source of truth rather than storing a second number that could
   disagree with the first. These tests pin the control, the read-only presentation, the one
   shared reader both surfaces call, the live required-points maths, and the fallback that keeps
   an empty programme off NaN and off a division by zero. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

test('the Point system editor carries the cost-per-point control', () => {
  const editor = section('<b>Loyalty model — only one is live at a time</b>',
    '<details class="loyalty-advanced-v235"');
  assert.match(editor, /<label for="lpc">Cost per point \(\$\{S\.biz\.currency\|\|'SGD'\}\)<\/label>/);
  assert.match(editor, /<input id="lpc" type="number" min="0\.001" step="0\.001"/);
  // One short help line, in the repo's low-literacy-first register.
  /* V293 (owner confused the three numbers, 2026-08-12): the help line now says what the knob
     IS — the redemption value of a point — rather than repeating "cost" three ways. */
  assert.match(editor, /What one point is worth when redeemed\. Used to price every reward\./);
  // Stamps have no points, and fixed redeem derives the value from the two numbers it already
  // asks for — a third editable field there could only contradict them.
  /* V375 (owner, photo 3): with fixed redeem retired, cost per point is shown for EVERY points
     model rather than for all-but-classic. */
  assert.match(editor, /\$\{model==='stamps'\?'':`<label for="lpc">/);
  /* V375: the DERIVED readout belonged to fixed redeem, where the two credit numbers implied the
     cost. With that model gone the owner types the cost directly and there is nothing to derive. */
  assert.doesNotMatch(editor, /lpcDerivedV262/);
});

test('the control is wired to the Point system save path, with no new column', () => {
  /* nestly_v415: the old end marker was the draft-only toast, which no longer exists — Save
     publishes now (owner, photo 2). The section is the same handler; only its closing landmark
     moved to the publish step that replaced that toast. */
  const save = section("const loyaltySave=$('lsave')", "const publishFailedV415=await publishOnSaveV415(versionId);");
  /* V375: no model is excluded any more — every points programme stores its cost per point. */
  assert.match(save, /if\(\$\('lpc'\)\)\{/);
  assert.match(save, /const pointCostV262=parseFloat\(\$\('lpc'\)\.value\);/);
  assert.match(save, /row\.redeem_points=pointCostBasisPointsV262;/);
  assert.match(save, /row\.reward_credit_cents=Math\.round\(pointCostV262\*100\*pointCostBasisPointsV262\);/);
  // A zero or blank cost would make every reward price divide by zero — refuse the save.
  assert.match(save, /if\(!\(pointCostV262>0\)\)\{toast\('Enter a cost per point greater than zero'\)/);
  // The value rides the existing draft RPC contract; nothing new is sent to the server.
  assert.doesNotMatch(save, /point_cost_cents|cost_per_point/);
});

test('the reward editor no longer has an editable cost-per-point input', () => {
  assert.doesNotMatch(app, /id="rwPointCost"/);
  assert.doesNotMatch(app, /Estimated company cost per point/);
  assert.doesNotMatch(app, /estimatedPointCostCents/);
  const rewardEditor = section('function openRewardEditor(reward){', 'function openRewardDialogV238(');
  assert.match(rewardEditor, /<output id="rwPointCostV262"/);
  assert.match(rewardEditor, /Set once for the whole programme\./);
  assert.match(rewardEditor, /<button class="btn ghost sm" id="rwPointCostEditV262" type="button">Change in Point system<\/button>/);
});

test('the pointer to the Point system is real, and never a dead control', () => {
  const rewardEditor = section('function openRewardEditor(reward){', 'function openRewardDialogV238(');
  assert.match(rewardEditor, /\$\('rwPointCostEditV262'\)\.onclick=\(\)=>\{/);
  assert.match(rewardEditor, /const target=\$\('lpc'\)\|\|\$\('lr'\);/);
  assert.match(rewardEditor, /target\.scrollIntoView\(\{block:'center',behavior:'smooth'\}\);/);
  // When this editor was opened on its own there is nothing to jump to, so it names the place
  // in words instead of pretending to navigate.
  assert.match(rewardEditor, /if\(!target\)return toast\('Cost per point is set in Loyalty → Point system'\);/);
});

test('both surfaces read one value through one reader', () => {
  assert.match(app, /const currentPointCostCentsV262=\(\)=>\{/);
  // The typed Point system control wins; otherwise the fixed-redeem derived line; otherwise the
  // programme constant. Nothing reads a per-reward field any more.
  assert.match(app, /const typed=\$\('lpc'\);/);
  assert.match(app, /const derived=\$\('lpcDerivedV262'\);/);
  const rewardEditor = section('function openRewardEditor(reward){', 'function openRewardDialogV238(');
  assert.match(rewardEditor, /pointCostLabelV262\(currentPointCostCentsV262\(\)\)/);
  assert.match(rewardEditor, /const budget=parseFloat\(\$\('rwEstimate'\)\.value\),pointCostCents=currentPointCostCentsV262\(\);/);
  // Editing the fixed-redeem pair moves the shared number the reward editor then reads.
  assert.match(app, /pointCostDerivedV262\.dataset\.pointCostCents=String\(cents\);/);
  assert.match(app, /\$\('lr'\)\.addEventListener\('input',syncPointCostDerivedV262\);/);
  assert.match(app, /\$\('lc'\)\.addEventListener\('input',syncPointCostDerivedV262\);/);
});

test('the required-points maths still recomputes live as the budget is typed', () => {
  const rewardEditor = section('function openRewardEditor(reward){', 'function openRewardDialogV238(');
  /* V293: typing the budget still recomputes live, but it first lifts the manual override an
     owner sets by typing Points cost directly — the sync no longer overwrites typed points. */
  assert.match(rewardEditor, /\$\('rwEstimate'\)\.addEventListener\('input',\(\)=>\{rwCostManualV293=false;syncPointsFromBudget\(\)\}\);/);
  assert.match(rewardEditor, /\$\('rwCost'\)\.addEventListener\('input',\(\)=>\{rwCostManualV293=true\}\);/);
  assert.match(rewardEditor, /const points=Math\.max\(1,Math\.ceil\(\(budget\*100\)\/pointCostCents\)\);\$\('rwCost'\)\.value=String\(points\);/);
  assert.match(rewardEditor, /<b>\$\{points\} points<\/b>/);
  // The note is only ever printed once the maths is defined.
  assert.match(rewardEditor, /if\(!\(budget>0\)\|\|!\(pointCostCents>0\)\)\{\$\('rwPointsMath'\)\.textContent='Enter the company cost budget to calculate the required whole points\.';return\}/);
});

test('an empty programme still gets a sane number', () => {
  const derivation = section('const pointCostSamplesV262=', 'const tierBenefitLines=');
  // Configured pair first, then the rewards already saved, then one cent — never 0, never NaN.
  assert.match(derivation, /const programmePointCostCentsV262=Number\(p\?\.redeem_points\)>0&&Number\(p\?\.reward_credit_cents\)>0/);
  assert.match(derivation, /:pointCostSamplesV262\.length/);
  assert.match(derivation, /\n      :1;/);
  assert.match(derivation, /const pointCostBasisPointsV262=Number\(p\?\.redeem_points\)>0\?Math\.round\(Number\(p\.redeem_points\)\):800;/);
  assert.match(app, /return programmePointCostCentsV262>0\?programmePointCostCentsV262:1;/);
});

test('publishing shows the cost per point outside fixed redeem', () => {
  const rows = section('function growPublishFieldRowsV170(live,draft){', '/* ============================ Program Studio page');
  assert.match(rows, /\{label:'Cost per point',read:p=>\{/);
  assert.match(rows, /return points>0&&cents>0\?Math\.round\(\(cents\/points\)\*1000\)\/1000:null;/);
  assert.match(rows, /when:!usesStamps\}/);
  // The row must stay evaluable on its own — the V175 test evals this function in isolation.
  assert.doesNotMatch(rows, /S\.biz/);
});
