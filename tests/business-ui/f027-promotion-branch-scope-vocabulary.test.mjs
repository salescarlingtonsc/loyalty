/* Audit F027 — the promotion editor read `selected_branches` and read `selected` as different
   things. The server (business_get_promotion_editor_v155, last definition db/migrations/
   20260823_nestly_v462_featured_offer_and_live_cap.sql, prod-confirmed via
   pg_get_functiondef — has_selected_branches:true, has_label:false) reports a promotion's
   branch scope as mode 'selected_branches' / 'all_branches' and never emits a `label` key. The
   client compared only against the WRITE-side wire value 'selected' (what the radios post), so
   no server-returned mode could ever match: every branch-scoped offer reopened with "All
   branches" checked and an empty branch list, and the next Save/Publish/Unpublish sent
   p_scope_mode='all', which deletes the promotion's promotion_branch_scopes_v155 rows. The list
   row also always printed "All branches" because it trusted a `label` field the server never
   sends.

   Fix: promotionScopeIsSelectedV155() accepts both 'selected' and 'selected_branches';
   promotionScopeLabelV155() derives the list label from branch_names instead of a
   never-present `label`. Both are pure functions, extracted and executed here against real
   server-shaped payloads — not a source-regex pin. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const extractFn = name => {
  const start = app.indexOf(`function ${name}(`);
  assert.ok(start > -1, `missing: function ${name}`);
  // Every promotion helper in this file is a single-statement-body or brace-balanced block that
  // ends at the next top-level `function ` declaration; walk braces to find the true end so the
  // extraction is robust to internal `{ }` (object literals) rather than guessing an anchor.
  let depth = 0, i = start, seenOpen = false;
  for (; i < app.length; i++) {
    const ch = app[i];
    if (ch === '{') { depth++; seenOpen = true; }
    else if (ch === '}') { depth--; if (seenOpen && depth === 0) { i++; break; } }
  }
  return app.slice(start, i);
};

const ctx = {};
vm.createContext(ctx);
vm.runInContext(extractFn('promotionScopeIsSelectedV155'), ctx);
vm.runInContext(extractFn('promotionScopeLabelV155'), ctx);

test('F027: promotionScopeIsSelectedV155 accepts the server\'s own vocabulary, not just the write-side wire value', () => {
  assert.equal(ctx.promotionScopeIsSelectedV155('selected_branches'), true,
    'this is the exact string business_get_promotion_editor_v155 returns for a scoped offer — prod-confirmed');
  assert.equal(ctx.promotionScopeIsSelectedV155('all_branches'), false);
  assert.equal(ctx.promotionScopeIsSelectedV155('selected'), true,
    'the write-side wire value the radios post must still be recognised');
  assert.equal(ctx.promotionScopeIsSelectedV155('all'), false);
  assert.equal(ctx.promotionScopeIsSelectedV155(undefined), false);
});

test('F027: promotionScopeLabelV155 derives the list-row label from branch_names, never a `label` field the server does not send', () => {
  assert.equal(
    ctx.promotionScopeLabelV155({mode: 'all_branches', branch_ids: [], branch_names: []}),
    'All branches'
  );
  assert.equal(
    ctx.promotionScopeLabelV155({mode: 'selected_branches', branch_ids: ['b1'], branch_names: ['Orchard']}),
    'Selected branches: Orchard',
    'a scoped offer must no longer fall back to the "All branches" default'
  );
  assert.equal(
    ctx.promotionScopeLabelV155({mode: 'selected_branches', branch_ids: ['b1', 'b2'], branch_names: ['Orchard', 'Tampines']}),
    'Selected branches: Orchard, Tampines'
  );
});

test('F027: the editor no longer compares scope mode against the write-side value alone', () => {
  const i = app.indexOf('const initialScopeMode=');
  assert.ok(i > -1);
  const src = app.slice(i, i + 260);
  assert.doesNotMatch(src, /selectedScope\.mode==='selected'/,
    'regressing to a bare "selected" comparison silently mismatches every server-returned selected_branches offer');
  assert.match(src, /promotionScopeIsSelectedV155\(selectedScope\.mode\)/);

  const scopeBranchIdsSite = app.indexOf('scopeBranchIds:');
  assert.ok(scopeBranchIdsSite > -1);
  assert.match(app.slice(scopeBranchIdsSite, scopeBranchIdsSite + 100),
    /promotionScopeIsSelectedV155\(selectedScope\.mode\)/);
});

test('F027: the promotions list row uses the derived label, not the never-sent server `label` field', () => {
  assert.doesNotMatch(app, /item\.branchScope\?\.label\|\|'All branches'/,
    'this was the defect: the server never emits `label`, so this always fell back to "All branches"');
  assert.match(app, /promotionScopeLabelV155\(item\.branchScope\)/);
});
