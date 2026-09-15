import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const productTruth=readFileSync(new URL('../../docs/product/PRODUCT-TRUTH.md',import.meta.url),'utf8');

/* nestly_v980 — OWNER RULING, 2026-09-15: "customer app = english only".

   This is a RESTATEMENT, not a new decision. docs/product/PRODUCT-TRUTH.md — which calls itself the
   durable statement of confirmed owner decisions — has carried "The customer portal is English-only
   at this stage" since v102/v103, and that line has never been amended. docs/qa/OWNER-ISSUE-LEDGER.md
   records the same thing on CUSTOMER-001 ("English-only customer UI").

   What drifted is the code. A customer could pick 中文 / Bahasa Melayu / தமிழ் at registration or in
   Profile, it saved to customer_profiles.preferred_language, and from the next load the whole wallet
   rendered in that language — since nestly_v954 not merely the ~152 hand-keyed ct() strings but every
   text node, because localizeCustomerSubtreeV954 walks the DOM against the 5,489-key workspace
   catalogue. No document ever recorded a decision to do that; the audit trail runs the other way,
   with V285 filing the picker as a DEFECT ("preferred language saves a value nothing reads").

   The seam is one resolver. customerLocale has exactly three writers and all three pass through
   normalizeCustomerLocale, so pinning it to 'en' switches off ct(), the v954 DOM walker,
   legalLinks(), merchantCopyLocale() and the lazy i18n chunk fetch together — and leaves the
   BUSINESS workspace localiser, which is a disjoint set of identifiers, completely alone.

   These tests are the standing guard on the ruling. If the customer app is ever meant to speak more
   than English, change it HERE, deliberately, with a recorded decision — do not re-add a picker. */

test('the ruling this enforces is recorded, not invented',()=>{
  assert.match(productTruth,/The customer portal is English-only at this stage\./,
    'PRODUCT-TRUTH.md must keep carrying the ruling this suite enforces');
});

test('the customer locale resolver can only ever answer English',()=>{
  /* The one seam. Every customerLocale writer goes through it. */
  assert.match(app,/const normalizeCustomerLocale\s*=\s*\(?\s*\)?[^\n]*=>\s*'en'/,
    'normalizeCustomerLocale must resolve to English for every input');
  assert.doesNotMatch(app,/const normalizeCustomerLocale=value=>\{[^\n]*CUSTOMER_LOCALES\.includes\(v\)\?v:'en'\}/,
    'the four-locale customer resolver is back — the customer app is English-only');
});

test('the customer app offers no language picker to choose from',()=>{
  /* Both writers. Leaving either one would save a preference that now changes nothing on screen,
     which is a lie in the UI rather than a kindness. */
  assert.doesNotMatch(app,/id="customerLanguage"/,
    'the registration language picker is back');
  assert.doesNotMatch(app,/id="customerProfileLanguage"/,
    'the profile language picker is back');
});

test('a customer who already saved another language is brought back to English, not stranded',()=>{
  /* The reason the resolver is pinned rather than the picker merely hidden: preferred_language is a
     NOT NULL DEFAULT 'en' column that is still read on every profile load. Hiding the control alone
     would leave anyone who had chosen 中文 reading Chinese forever with no way back. */
  assert.match(app,/customerLocale=normalizeCustomerLocale\(profile\?\.preferred_language\)/,
    'the profile load must still pass the stored value through the pinned resolver');
});

test('the business workspace keeps its own localisation, untouched',()=>{
  /* A positive control. The ruling is about the CUSTOMER app; the staff workspace is trilingual by a
     separate, active decision, and these are disjoint identifiers. If this test ever fails, the
     customer change has reached across the seam. */
  assert.match(app,/const normalizeWorkspaceLocaleV97=value=>WORKSPACE_LOCALES_V97\.includes\(String\(value\|\|''\)\)\?String\(value\):'en'/,
    'the workspace resolver must keep resolving all three workspace locales');
  assert.match(app,/const WORKSPACE_LOCALES_V97=Object\.freeze\(\['en','zh-CN','ms'\]\)/);
  assert.match(app,/id="workspaceLanguageMobileV151"|workspaceLanguagePickerV97/,
    'the workspace language picker must still exist');
});
