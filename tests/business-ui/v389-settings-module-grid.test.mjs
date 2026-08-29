import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

/* nestly_v607 (owner markup: "Settings" struck through and "Subscription" written in; and, against
   the module list, "dont need to show them the modules, just remove it. since only admin can
   edit").
   V389 spent a file getting this list to LOOK right — it had been borrowing the platform console's
   stylesheet, so each chip painted as an overlapping inline blob. The list itself was never
   editable: the page said so on its own face ("Everything else is set by Peekaa for your sector.
   Contact Peekaa if your business needs a different module entitlement"). A read-only inventory of
   entitlements, on a page an owner opens to check what they pay for, is a list of things that look
   like settings and are not. It is gone, and so is "What do you sell?" beside it, for the same
   reason. What remains on that page is the plan.
   The tests that measured the grid's appearance go with it; this one holds the removal. */
test('the Subscription page shows the plan, not a read-only list of entitlements',()=>{
  assert.doesNotMatch(app,/settings-module-grid-v389/,'the module grid is gone');
  assert.doesNotMatch(app,/<b>Modules<\/b>/,'and so is its heading');
  assert.doesNotMatch(app,/id="sellsServices"/,'"What do you sell?" went with it');
  assert.doesNotMatch(app,/id="salesMixSave"/);
  assert.match(app,/<h1>Subscription<\/h1>/,'the page is named for what it now holds');
  assert.match(app,/id="billingWrap"/,'and the plan is what it holds');
});
