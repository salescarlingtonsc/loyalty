import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v920 (audit finding F5) — arriving at a counter must not move the top bar.
 *
 * REPORTED: the top bar's VIEWING select was on "All branches"; after opening a customer record
 * and coming back to the Dashboard it read "B01 · Cubbly · Orchard", with no user action. That
 * silently narrows every figure on every page behind it, and it is also what puts an owner into
 * finding F4 (a customer with no sales yet is invisible under a named branch).
 *
 * CAUSE: three pages copied the branch they OPERATE at into `selectedBranchId`, which is the
 * workspace's VIEWING scope — the select whose own title says "This changes the workspace view.
 * Operational actions still use one selected branch." tillPage, giftcardsPage and
 * appointmentsPage each did an unconditional assignment at the top, so merely ARRIVING (the
 * customer profile's "Record sale" / "New appointment" buttons, the header's sale shortcut)
 * rewrote the scope. Every RPC on those pages already passes its operational branch explicitly,
 * so the assignment was never load-bearing for them — only for the top bar.
 *
 * RULE: only a principal who may hold "All branches" can lose something by this assignment. An
 * employee is never offered consolidated (hydrateProfileBranchSelectorV158) and still needs a
 * branch filled in, so the assignment is kept for them and skipped for everyone else. The branch
 * pickers ON those pages still write the scope — that is a deliberate choice, not arrival.
 *
 * NEGATIVE CONTROL: this file was validated by running it against the pre-fix app/app.js
 * (origin/main at 4d76bfa0, before nestly_v920). All three "guarded" assertions below fail there
 * and all three "unguarded form is gone" assertions fail there, because that source carries the
 * bare `selectedBranchId=tillBranchId;` / `=giftBranchId;` / `if(branchId)selectedBranchId=` .
 * It is red before the fix and green after, which is the only reason it is worth keeping.
 */

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const countOf = (needle) => app.split(needle).length - 1;

test('Record sale only takes the viewing scope when the user cannot hold "All branches"', () => {
  assert.equal(countOf('if(!canSeeAllTillBranches)selectedBranchId=tillBranchId;'), 1);
  // the unconditional form is what moved an owner's top bar on arrival
  assert.equal(countOf('\n  selectedBranchId=tillBranchId;'), 0);
});

test('Gift cards only takes the viewing scope when the user cannot hold "All branches"', () => {
  assert.equal(countOf('if(!canSeeAllBranches)selectedBranchId=giftBranchId;'), 1);
  assert.equal(countOf('\n  selectedBranchId=giftBranchId;'), 0);
});

test('Appointments only takes the viewing scope when the user cannot hold "All branches"', () => {
  assert.equal(countOf('if(branchId&&!canSeeAll)selectedBranchId=branchId;'), 1);
  assert.equal(countOf('\n  if(branchId)selectedBranchId=branchId;'), 0);
});

test('the three pages still pass their own operational branch to the server', () => {
  /* The guard above is only safe because none of these pages reads the viewing scope to decide
     what it writes. Each keeps its own local — tillBranchId / giftBranchId / branchId — and that
     is what reaches the RPCs. If a future edit made one of them read selectedBranchId instead,
     the guard would start changing what gets RECORDED, not just what is displayed. */
  assert.match(app, /let tillBranchId=accessibleTillBranches\.some\(branch=>branch\.id===selectedBranchId\)\?selectedBranchId:/);
  assert.match(app, /let giftBranchId=operationalBranches\.some\(branch=>branch\.id===selectedBranchId\)/);
  assert.match(app, /let branchId=visibleBranches\.some\(b=>b\.id===selectedBranchId\)\?selectedBranchId:/);
  /* And the pickers ON those pages still write the scope deliberately — that is the one path
     that SHOULD move the top bar, and removing it would be a different bug. */
  assert.match(app, /tillBranchId=\$\('tBranch'\)\.value;selectedBranchId=tillBranchId/);
});
