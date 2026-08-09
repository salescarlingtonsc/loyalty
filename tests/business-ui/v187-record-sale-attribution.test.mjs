import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
/* V257: this was a fixed 95000-character window, so growing Record sale silently sliced the
   fourth money path out of view and the count assertion below failed for no behavioural
   reason. Cut at the real section boundary instead. */
const till = app.slice(app.indexOf('async function tillPage'), app.indexOf('async function salesPage(){'));

test('a sale can be credited to the teammate who performed it, not just the till operator', () => {
  // Owner: "under record sale - i must be able to select who is the sales staff to allocate
  // commissions". Every sale was attributed to the signed-in user, so a salon receptionist took
  // the therapist's commission.
  assert.match(till, /id="tillSaleStaff"/);
  assert.match(till, /const tillActingStaffId=tillRoster\.find\(person=>person\.user_id===S\.user\.id\)/);
  assert.match(till, /let tillSaleStaffId=tillActingStaffId/);
  // the roster must actually be loaded, not just my own row
  assert.match(till, /from\('staff'\)\.select\('id,full_name,user_id'\)/);
});

test('every money path uses the attributed teammate', () => {
  // Attribution drives the frozen per-sale commission snapshot.
  assert.equal((till.match(/tillSaleStaffId\|\|tillStaffId/g) || []).length, 4,
    'quick sale, cart finalize, and both checkout fingerprint/state writes');
  assert.ok(!/p_staff:tillStaffId\b/.test(till), 'no money path may still hardcode the operator');
});

test('re-attributing starts a new attempt instead of replaying the previous one', () => {
  const i = till.indexOf("$('tillSaleStaff').onchange");
  const src = till.slice(i, i + 260);
  assert.match(src, /saleIdem=null/);
  assert.match(till, /tillSaleStaffId\|\|tillStaffId,evalResult\.evaluation_id\]\.join/,
    'the attributed teammate must be part of the checkout fingerprint');
});

test('the picker only appears when someone else could have done the work', () => {
  // A one-person shop and F&B never see it; it configures itself instead of needing a setting.
  assert.match(till, /tillAttributableStaff\.length>1\?/);
  assert.match(till, /const tillAttributableStaffFor=branchId=>tillRoster\.filter/);
  // Candidates are branch-scoped unless the actor legitimately covers several branches.
  const i = till.indexOf('const tillAttributableStaffFor');
  const src = till.slice(i, i + 340);
  assert.match(src, /canSeeAllTillBranches/);
  assert.match(src, /row\.branch_id===branchId/);
});
