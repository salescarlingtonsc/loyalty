import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const css = readFileSync(resolve(root, 'app/index.html'), 'utf8');

/* V210 — owner annotation on the dashboard screenshot: "move out to outside here at upper right
   and fixed all the way". The branch scope decides what every figure on the page MEANS, so two
   taps inside an account menu meant an owner could read a whole dashboard without seeing which
   branch it was for. */

test('the branch scope lives in the top bar, not inside the account menu', () => {
  assert.match(app, /<div class="topbar-branch-scope-v210" id="profileBranchScopeV158"/);
  // it sits with the other persistent bar controls
  const bar = app.slice(app.indexOf('${mobileSearchShellHtml()}'), app.indexOf('${bellHtml()}'));
  assert.match(bar, /topbar-branch-scope-v210/);
  /* V225 (owner: "put inside here", pointing from the language select to the profile menu).
     Language is set once and is not a per-task control, so it moved in with the account
     settings. The branch scope asserted above is what must stay in the bar. */
  assert.doesNotMatch(bar, /workspaceLanguagePickerV97\(\)/);
  assert.match(app, /<div class="profile-menu-section">\$\{workspaceLanguagePickerV97\(\)\}<\/div>/);
});

test('it stays put and keeps a 44px target', () => {
  assert.match(css, /\.topbar-branch-scope-v210\{[^}]*flex:0 0 auto[^}]*\}/);
  assert.match(css, /\.topbar-branch-scope-v210 select\{[^}]*min-height:44px/);
});

test('the scope is never invisible — only relocated on a narrow screen', () => {
  // the bar hides it where space runs out…
  assert.match(css, /@media\(max-width:900px\)\{\.topbar-branch-scope-v210\{display:none\}\}/);
  // …so the menu states which branch is in view there instead
  assert.match(app, /profile-branch-readout-v210/);
  assert.match(app, /Viewing data for/);
  assert.match(css, /@media\(max-width:900px\)\{\.profile-branch-readout-v210\{display:block\}\}/);
});

test('the label helper the readout uses is still defined and still used', () => {
  // removing a declaration and leaving a reference is the bug that took the dashboard down
  // this morning; this asserts both halves stay in step
  assert.match(app, /function profileBranchScopeLabelV158\(\)/);
  assert.ok((app.match(/(?<![\w.$])profileBranchScopeLabelV158(?![\w$])/g) || []).length >= 2,
    'defined and called — a helper defined but never used means the move went too far');
});
