/* nestly_v601 — a package is edited, switched, or taken off sale. It is never "version 2".
 *
 * Owner (photo 2): "instead of create new version - it should be edit. dont label it as V1 / V2
 * etc. that is incorrect. - when press edit should pop up for user to easily edit and save. once
 * save will be true moving forward. and add a delete button to delete that package. Since there's
 * on/off allow user to on/off as well."
 *
 * The trap in this wave is that "true moving forward" and "stop showing me versions" sound like
 * one instruction and are two. The FIRST is the versioning: four customers bought 5x facial at
 * SGD 400 and must keep that price, those sessions and that service. The SECOND is only about
 * words. So the writer is unchanged and the labels are gone — and these checks exist to stop a
 * later reader "simplifying" the first one away along with the second.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const migration=readFileSync(new URL('../../db/migrations/20260829_nestly_v601_package_edit_retire_and_switch.sql',import.meta.url),'utf8');
const packages=app.slice(app.indexOf('async function packagesPage'),app.indexOf('async function branchesPage'));

test('editing still supersedes, so nobody who bought loses what they paid for',()=>{
  assert.match(packages,/sb\.rpc\('save_package_plan_v102',\{[\s\S]{0,200}p_plan:plan\.id/,
    'the dialog saves through the versioning writer, with the plan id — that is what freezes the old one');
  assert.match(packages,/they keep the price and sessions they paid for/,
    'and the row says so, in place of the old "create a new version" instruction');
});

test('no version number is shown anywhere a person reads',()=>{
  assert.doesNotMatch(packages,/v\$\{Number\(p\.version_no/,'not on the packages row');
  assert.doesNotMatch(packages,/v\$\{Number\(k\.plan_version/,'not on the customer packages row');
  assert.doesNotMatch(app,/· v\$\{entry\.planVersion\}/,'not on the Customer 360 card');
  assert.doesNotMatch(packages,/Create new version|Save new version/);
});

test('Edit opens a dialog rather than scrolling the page to a shared form',()=>{
  assert.match(packages,/data-edit-package="\$\{p\.id\}">Edit</);
  assert.match(packages,/openPackageEditDialogV601\(plan\)/);
  assert.match(packages,/id="packageEditFormV601"/);
  /* The old handler filled the create form at the top and scrolled there, which on a long list
     reads as the page jumping and leaves the owner unsure which package they are editing. */
  assert.doesNotMatch(packages,/window\.scrollTo\(\{top:0,behavior:'smooth'\}\)/);
});

test('the edit dialog cannot silently rewrite the service it was opened on',()=>{
  /* A package pointing at a service that has since been deactivated would render with nothing
     selected, and Save would then store "flexible" — quietly changing what the customer gets. */
  assert.match(packages,/const live=\(sv\|\|\[\]\)\.filter\(service=>service\.active\|\|service\.id===chosen\)/);
  assert.match(packages,/service\.id===chosen\?'selected':''/);
});

test('Delete honours what was sold, and says which it is',()=>{
  assert.match(packages,/data-package-sold="\$\{Number\(packagePurchaseCount\[p\.id\]\|\|0\)\}"/);
  assert.match(packages,/It leaves Record sale and this list, so nobody can buy it again/,
    'the sold sentence promises what the owner chose: stop selling, honour what is sold');
  assert.match(packages,/keep\$\{sold===1\?'s':''\} the sessions they paid for/);
  assert.match(packages,/Nobody has bought it, so nothing is taken away from a customer/,
    'and the unsold sentence still promises a real delete');
});

test('Rename is offered only while nobody has bought it',()=>{
  /* Renaming a sold package renames it on the receipt and in the wallet of everybody holding it,
     which is why the server refuses it and why the button must not be there to press. */
  assert.match(packages,/packagePurchaseCount\[p\.id\]\?'':`<button type="button" class="btn ghost sm" data-package-rename=/);
});

test('the On/Off pill is a control, and does not breed versions',()=>{
  assert.match(packages,/<button type="button" class="pill \$\{p\.active\?'on':'off'\}" data-package-active=/);
  assert.match(packages,/sb\.rpc\('business_set_package_active_v601'/);
  /* Routing the switch through save_package_plan_v102 would supersede the plan and mint a new one
     every single time somebody paused a package. */
  assert.doesNotMatch(packages,/data-package-active[\s\S]{0,400}save_package_plan_v102/);
});

test('a retired package is gone from the list but not from the database',()=>{
  assert.match(packages,/\(plans\|\|\[\]\)\.filter\(p=>!p\.retired_at\)/);
  assert.match(migration,/set retired_at=now\(\), active=false/);
  assert.doesNotMatch(migration,/delete from public\.client_packages/,
    'a customer\'s own package row is never touched — that is the whole promise');
});

test('the server decides retire vs delete by whether anyone actually bought it',()=>{
  assert.match(migration,/select count\(\*\) into v_sold from public\.client_packages/);
  assert.match(migration,/elsif v_sold > 0 then[\s\S]{0,600}set retired_at=now\(\), active=false/);
  assert.match(migration,/else\s*\n\s*delete from public\.package_plans/);
  assert.match(migration,/this package was taken off sale and cannot be switched back on/,
    'off is a pause and can be undone; retired is a decision and cannot');
});
