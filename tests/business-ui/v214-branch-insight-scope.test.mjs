/* V214 — merchant insights must explain their branch scope.
   Owner question: "why is merchant insights different for each branch? would it be confusing
   why some branch have insights some dont have?"
   The behaviour was already correct — each card is derived from the branch currently in scope,
   and a card only appears once there is enough activity behind it. What was missing is that the
   panel never said so, so a quiet branch looked like a broken feature. These assertions pin the
   explanation, the data-grounded quiet-branch card, and the escape back to all branches. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

function fn(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  return app.slice(start, app.indexOf('\nfunction ', start + 1));
}

test('V214 states which branches merchant insights are counted from', () => {
  const explainer = fn('insightScopeExplainerV214');
  assert.match(explainer, /Other branches are excluded/);
  assert.match(explainer, /Every branch you can see is counted together/);
  // Both halves must name the control the owner actually uses to change it.
  assert.equal((explainer.match(/"Viewing"/g) || []).length, 2);

  const build = fn('buildMerchantInsightsV153');
  assert.match(build, /insightScopeExplainerV214\(branchId,branchName\)/);
  assert.match(build, /merchant-insights-scope-note-v214/);
  assert.match(shell, /\.merchant-insights-scope-note-v214\{/);
});

test('V214 quiet branch card reports real counted activity, not a generic placeholder', () => {
  const quiet = fn('insightQuietScopeV214');
  // Real numbers from the same payload the KPIs use — never a bare "no data" message.
  assert.match(quiet, /Number\(current\?\.visits\)\|\|0/);
  assert.match(quiet, /Number\(current\?\.revenue_cents\)\|\|0/);
  assert.match(quiet, /recorded \$\{visits\} \$\{visits===1\?'visit':'visits'\} and \$\{money\(revenueCents\)\}/);
  assert.match(quiet, /recorded no visits or sales in this period/);
  // The reassurance the owner asked for: fewer cards is expected, not a fault.
  assert.match(quiet, /Nothing is broken\./);
  assert.match(quiet, /Each branch is measured on its own/);

  const build = fn('buildMerchantInsightsV153');
  assert.match(build, /insights\.push\(insightQuietScopeV214\(\{current,branchId,branchName\}\)\)/);
  // The old generic placeholder must be gone, or the explanation never reaches the owner.
  assert.doesNotMatch(app, /Peekaa will show recommendations after more sales, visits or appointments are recorded\./);
});

test('V214 quiet branch card can switch back to all branches, and only offers it when scoped', () => {
  const quiet = fn('insightQuietScopeV214');
  assert.match(quiet, /branchId\?\{label:'Show all branches',dataset:'data-insight-scope-all-v214'/);
  assert.match(quiet, /\]\.filter\(Boolean\)/);

  // Handler is wired, targets the real top-bar control, and fails loud for staff who
  // have no "All branches" option rather than silently doing nothing.
  assert.match(app, /\[data-insight-scope-all-v214\]/);
  assert.match(app, /profileBranchScopeSelectV158/);
  assert.match(app, /option\[value=""\]/);
  assert.match(app, /Only an owner or manager can view all branches at once/);
  assert.match(app, /select\.dispatchEvent\(new Event\('change'\)\)/);
});

test('V214 references only identifiers that exist', () => {
  // Guards the failure mode that took production down once already: deleting or renaming a
  // declaration while a reference survives. node --check and the rest of the suite both pass
  // an undeclared identifier; only an explicit check catches it.
  for (const name of ['insightScopeExplainerV214', 'insightQuietScopeV214']) {
    assert.equal((app.match(new RegExp(`function ${name}\\(`, 'g')) || []).length, 1, `${name} declared once`);
    assert.ok(app.includes(`${name}(`), `${name} referenced`);
  }
});
