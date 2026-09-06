/* nestly_v798 — Business Profile "Save Profile" saved nothing when the Industry select was touched,
   and never applied a chosen logo.

   Fault 1 (industry). V385 made the Industry select editable. `businesses.industry` MIRRORS the
   assigned sector bundle — platform_assign_business_sector_v75 writes the column from the bundle's
   sector_key — and app.business_sector_modules_guard_v75 raises 42501 at any other writer for a
   firm that has a business_sector_assignments row. Every self-service firm takes that row at
   payment (20 of 24 live firms had one), so the select could never save. Worse, industry rode the
   SAME businesses UPDATE as the name, the bio, the wording line and the review link, so touching
   the dropdown failed the WHOLE card: the owner's typed name and bio were lost to an error
   sentence about "modules". Owner ruling 2026-09-06: the select is cosmetic, "just to let user to
   read the company's industry"; changing a firm's sector is a super-admin action.

   Fault 2 (logo). The logo is published by a button labelled "Upload logo"/"Replace logo". Neither
   this Save nor the page-level save-all (which presses buttons whose LABEL starts with "Save")
   ever pressed it, and the route() at the end of this handler then repainted the card and threw
   the chosen file away. Choosing a logo and pressing Save did nothing, silently.

   Both assertions EXECUTE the real handler lifted out of app/app.js, because both faults are about
   what the handler actually sends and calls — a source grep would stay green if the payload were
   rebuilt some other way. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const section = (source, from, to) => {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
};

const HANDLER_SRC = section(app, "  $('bsave').onclick=async()=>{", "\n}\n/* V325 (owner-authorized restructure");

function loadHandler(context) {
  const src = HANDLER_SRC.replace("  $('bsave').onclick=", 'globalThis.__save=');
  assert.ok(src.includes('globalThis.__save='), 'the Save Profile handler assignment moved');
  vm.createContext(context);
  vm.runInContext(src, context);
  return context.__save;
}

function harness({
  industrySelected = 'fnb',      // the owner has moved the (now read-only) select
  storedIndustry = 'salon',
  logoFile = null,
  logoDisabled = true,
  updateError = null
} = {}) {
  const calls = {updates: [], rpc: [], routed: 0, toasts: [], failures: [], logoClicks: 0,
    identityRefreshes: 0, previewRefreshes: 0};
  const fields = {
    bn: {value: '  Hairdressing @ Choa Chu Kang  ', focus() {}},
    bi: {value: industrySelected},
    bilabel: {value: ' Hair studio '},
    bbio: {value: ' Walk-ins welcome '},
    bru: {value: 'g.page/hairdressing/review', focus() {}},
    workspaceLogoFileV96: {files: logoFile ? [logoFile] : []},
    workspaceLogoPublishV96: {disabled: logoDisabled, click() {calls.logoClicks += 1}}
  };
  const context = {
    console: {error() {}},
    $: id => fields[id] || null,
    S: {biz: {id: 'biz-1', industry: storedIndustry, name: 'Old name'}, myRole: 'owner'},
    toast: message => {calls.toasts.push(message)},
    fail: error => {calls.failures.push(error)},
    route: () => {calls.routed += 1},
    invalidateBusinessRecordCacheV370: () => {},
    refreshWorkspaceIdentityV798: () => {calls.identityRefreshes += 1},
    refreshCustomerInterfaceLivePreviewV326: () => {calls.previewRefreshes += 1},
    // The real normaliser, so what is validated here is what the app validates.
    businessLinkNormaliseV471: value => {
      const raw = String(value || '').trim();
      if (!raw) return null;
      return /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
    },
    sb: {
      from: () => ({
        update: payload => ({
          eq: async () => {
            calls.updates.push(JSON.parse(JSON.stringify(payload)));
            return {error: updateError};
          }
        })
      }),
      rpc: async (name, args) => {
        calls.rpc.push({name, args});
        return {data: null, error: null};
      }
    }
  };
  return {save: loadHandler(context), calls, state: context.S};
}

/* nestly_v800 supersedes v798's `disabled`: the owner asked for the control to open again
   ("still cannot drop down"), so it is a PICKER for the customer-facing wording, not for the
   sector. What must hold is unchanged and is asserted by the two tests below plus the estate-wide
   scan at the bottom: nothing on this card writes businesses.industry. */
test('v800: the Industry select opens, and offers wording rather than sectors to switch to', () => {
  const card = section(app, 'function workspaceBrandPanelHtmlV259(){', '\nfunction refreshWorkspaceIdentityV798');
  const select = card.match(/<select id="bi"[^>]*>/);
  assert.ok(select, 'the Industry select is gone from the Business Profile card');
  assert.doesNotMatch(select[0], /\bdisabled\b/, 'the owner must be able to open it');
  assert.match(card, /Industry \(what customers read\)/,
    'the label must say what the control does, or it claims to set the sector again');
  assert.match(card, /Your plan sector:/,
    'the real sector must still be stated — it is what decides their modules');
});

test('v798: saving never sends `industry`, even when the select shows a different sector', async () => {
  const {save, calls} = harness({industrySelected: 'fnb', storedIndustry: 'salon'});
  await save();

  assert.equal(calls.updates.length, 1, 'the card still writes exactly one businesses UPDATE');
  const payload = calls.updates[0];
  assert.ok(!Object.hasOwn(payload, 'industry'),
    'industry is back in the Business Profile UPDATE — app.business_sector_modules_guard_v75 will '
    + '42501 it for every firm with a sector assignment and take the whole card down with it');
  assert.deepEqual(Object.keys(payload).sort(), ['bio', 'industry_label', 'name', 'review_url']);
  assert.equal(payload.name, 'Hairdressing @ Choa Chu Kang', 'the name is trimmed and saved');
  assert.equal(payload.bio, 'Walk-ins welcome');
  assert.equal(payload.industry_label, 'Hair studio');
  assert.equal(payload.review_url, 'https://g.page/hairdressing/review');
  assert.deepEqual(calls.failures, [], 'a plain field save must not report a failure');
  assert.deepEqual(calls.toasts, ['Saved']);
});

test('v798: the sector in memory is left exactly as the server has it', async () => {
  const {save, state} = harness({industrySelected: 'retail', storedIndustry: 'salon'});
  await save();
  assert.equal(state.biz.industry, 'salon',
    'the handler must not move S.biz.industry — the screen would then disagree with the row, which '
    + 'is what "changing industry does not reflect when i save" looked like');
});

test('v798: a chosen logo is uploaded by Save, instead of being silently dropped', async () => {
  const {save, calls} = harness({logoFile: {name: 'logo.png'}, logoDisabled: false});
  await save();
  assert.equal(calls.logoClicks, 1,
    'Save must press the logo publish button — it is labelled "Upload logo", so nothing else does');
});

test('v798: Save does not press the logo button when no file is waiting', async () => {
  const {save, calls} = harness({logoFile: null, logoDisabled: true});
  await save();
  assert.equal(calls.logoClicks, 0, 'an empty file input must not trigger a publish');
});

test('v798: a failed UPDATE reports the failure and touches nothing else', async () => {
  const {save, calls, state} = harness({updateError: {message: 'nope', code: '42501'},
    logoFile: {name: 'logo.png'}, logoDisabled: false});
  await save();
  assert.equal(calls.failures.length, 1, 'the error must be surfaced');
  assert.deepEqual(calls.toasts, [], 'a failed write must never say "Saved"');
  assert.equal(calls.logoClicks, 0, 'a failed field save must not publish the logo behind it');
  assert.equal(state.biz.name, 'Old name', 'nothing is mirrored into state on a failure');
});

test('v798: a plain field save does not re-render the page out from under the other cards', async () => {
  const {save, calls} = harness();
  await save();
  assert.equal(calls.routed, 0,
    'route() repaints the page, which reloads the Photos and links card from the server and throws '
    + 'away any photo added or caption typed that has not been through that card\'s own Save');
  assert.equal(calls.identityRefreshes, 1, 'the profile-menu name must still be repainted');
  assert.equal(calls.previewRefreshes, 1, 'the live preview must still be repainted');
});

test('v798: the review link keeps its v471 normalisation through the rewritten handler', async () => {
  const {save, calls} = harness();
  await save();
  assert.equal(calls.updates[0].review_url, 'https://g.page/hairdressing/review',
    'a link typed without its scheme is still stored with one — v471 behaviour must survive v798');
});

/* Bug-Closure Protocol (B): the defect CLASS, not this one form.
   `businesses.industry` has exactly one legitimate writer — the platform's sector assignment,
   which moves the bundle, the module list and the column together. Any browser-side UPDATE that
   names the column is refused by app.business_sector_modules_guard_v75 for every firm that has a
   sector assignment, and PostgREST reports that refusal for the WHOLE statement — so such a write
   does not just fail to change the sector, it silently discards every other field beside it.
   This scan is estate-wide over the workspace bundle rather than scoped to the one handler,
   because the next writer to reach for it will be a different form. */
test('v798 (class): no workspace form writes businesses.industry', () => {
  const withoutComments = app.replace(/\/\*[\s\S]*?\*\//g, '');
  const writes = [...withoutComments.matchAll(/from\('businesses'\)\.update\(\{([\s\S]{0,400}?)\}\)/g)];
  assert.ok(writes.length > 0, 'the scan found no businesses UPDATE at all — the pattern moved');
  for (const [, payload] of writes) {
    assert.ok(!/(^|[^_\w])industry\s*[,:]/.test(payload),
      'a workspace form writes businesses.industry again. That column mirrors the assigned sector '
      + 'bundle; the v75 guard 42501s the whole statement and takes every other field in it down. '
      + `Offending payload: {${payload.trim().slice(0, 120)}}`);
  }
});
