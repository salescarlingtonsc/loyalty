import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* V301 (owner: "i already removed gift card - but it keeps appearing"): Programmes -> Overview
   (#/grow/overview) synthesized a Gift cards row from snapshot.giftcards, gated on
   businesses.gift_card_sales_enabled. V294 moved gift-card management to Serve & sell and V296
   moved its enable switch to Customer Interface — both deliberately left that flag alone, so
   removing every entry point into a "Gift cards programme" never removed this row: the row
   builder never looked at either change, it just kept reading the old flag straight off the
   snapshot. This file pins the fix at the row-builder level, independent of the flag's value. */

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
/* Same read-site as every other business-ui test: the application code is the CONCATENATION of
   the markup file and the script file. */
const app = fs.readFileSync(path.join(repo, 'app/index.html'), 'utf8') + '\n'
  + fs.readFileSync(path.join(repo, 'app/app.js'), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

const programmeEntries = section('const growProgrammeEntriesV271=', 'const growOverviewRowsV271=');
const overviewSnapshot = section('async function growOverviewSnapshot', 'function ownerRewardJourneyV122');
/* V319 split Overview into a Rewards & Loyalty table and a Limited Offer table. The five columns
   this test protects are the reward side's; the offers side is covered in the V319 suite. */
const overviewTable = section('const growOverviewRewardsTableV319=', 'const growOverviewOffersTableV319=');

test('V301 (a) the row builder never synthesizes a Gift cards entry', () => {
  assert.doesNotMatch(programmeEntries, /name:'Gift cards'/);
  assert.doesNotMatch(programmeEntries, /type:'Gift cards'/);
  // The stale gate itself is gone, not just the row text it produced.
  assert.doesNotMatch(programmeEntries, /snapshot\.giftcards/);
});

test('V301 (b) the Overview table keeps the owner-named columns', () => {
  /* V324: the Programme column moved into growOverviewNameColumnV324, which takes the row list
     as well as the row so the child indent can require a parent above it. */
  assert.match(overviewTable, /growOverviewNameColumnV324\(growOverviewRewardRowsV319,'Programme'\)/);
  /* V324 (owner markup 2026-08-14): Type is struck through — four columns now, not five. The
     row-to-programme relationship it carried moved into the name cell as an indent; this suite's
     own subject (no synthesized Gift cards row) is untouched by that. */
  assert.doesNotMatch(overviewTable, /\['Type',row=>esc\(row\.type\)\]/);
  assert.match(overviewTable, /\['Started',row=>growDateCellV271\(row\.started\)\]/);
  assert.match(overviewTable, /\['Customers used',row=>growCountCellV271\(row\.customers\)\]/);
  assert.match(overviewTable, /\['Setting',row=>row\.detail/);
});

test('V301 (c) growOverviewSnapshot stops fetching checkout preferences for a row nothing reads', () => {
  // Match the actual call-site shape, not the bare identifier — growOverviewSnapshot's own
  // removal comment names this RPC in prose, which a plain substring match would trip on.
  assert.doesNotMatch(overviewSnapshot, /sb\.rpc\('business_get_checkout_preferences_v102'/);
  assert.doesNotMatch(overviewSnapshot, /giftcardsRequest/);
  assert.doesNotMatch(overviewSnapshot, /giftcards:/);
  /* The RPC is not orphaned platform-wide: the Serve & sell gift cards page and the Customer
     Interface gift-cards switch still call it. This pins that at least one real call site
     survives outside the Overview snapshot. */
  const callSites = (app.match(/sb\.rpc\('business_get_checkout_preferences_v102'/g) || []).length;
  assert.ok(callSites >= 1,
    'business_get_checkout_preferences_v102 must still be called somewhere in the app (Serve & sell / Customer Interface)');
});
