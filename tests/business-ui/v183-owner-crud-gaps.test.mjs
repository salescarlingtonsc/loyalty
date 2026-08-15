import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('a mistyped service can be corrected, not just disabled', () => {
  // Owner: "No edit function, what if i key wrongly, then the service how can i remove the time?"
  assert.match(app, /data-svc-edit=/, 'services need an Edit control');
  assert.match(app, /data-svc-save=/);
  assert.match(app, /svcEditName|svcEditPrice|svcEditDuration/);
  // The column is variant_label; writing `variant` would silently fail.
  assert.match(app, /variant_label:variant,price_cents:price,duration_min:duration/);
  assert.ok(!/update\(\{name,variant,price_cents/.test(app),
    'the services table has no `variant` column — that update would fail');
});

test('the bundle service picker refreshes when the Bundles view opens', () => {
  // Owner: "bundle does not work". loadBR() ran once at mount, so services added during the
  // same visit never appeared and Save could only answer "Pick at least 2 services".
  const i = app.indexOf("$('bundlesSeg').onclick");
  assert.ok(app.slice(i, i + 400).includes('loadBR()'), 'switching to Bundles must re-read services');
  const j = app.indexOf("openBundleForm')).onclick") >= 0 ? app.indexOf("openBundleForm')).onclick") : app.indexOf("$('openBundleForm').onclick");
  assert.ok(app.slice(j, j + 500).includes('loadBR()'), 'opening the bundle form must re-read services');
  assert.ok(!app.includes('>add services first<'), 'the dead-end empty state should say what to do');
});

test('promotions can be removed, with published offers retired rather than erased', () => {
  // Owner: "I can edit but i cannot delete T.T"
  assert.match(app, /data-promotion-delete=/);
  assert.match(app, /business_delete_promotion_v183/);
  const i = app.indexOf('[data-promotion-delete]');
  const src = app.slice(i, i + 1400);
  assert.ok(src.includes('confirm('), 'deletion must be confirmed');
  /* V334 (owner markup, photo 7: "all 'retire' change to 'end'"): the wording changed, the
     underlying behaviour (kept record vs hard delete) did not. */
  assert.ok(/End/.test(app) && /Delete the draft/.test(src),
    'the control must say which of end/delete will happen');
});

test('a just-picked promotion photo shows in the preview before publishing', () => {
  // Owner: "Upload the image but not reflected on the right ... only after publish then is able to see"
  // customerMediaUrlV95 is a storage allowlist, so a blob: URL resolved to '' and the card fell
  // back to its initial letter. The allowlist must stay for customer-facing rendering.
  assert.match(app, /function customerPromotionCardV104\(item,business,bookingEnabled,previewImageUrl=''\)/);
  assert.match(app, /const image=previewImageUrl\|\|customerMediaUrlV95/);
  assert.match(app, /\/\^blob:\/i\.test/, 'only a local blob: URL may bypass the allowlist');
  const customerCall = app.indexOf('customerPromotionCardV104(item,business,bookingEnabled)');
  assert.ok(customerCall > 0, 'the customer render path must NOT pass a preview override');
});

test('the rewards draft retry cannot deadlock on a stale idempotency key', () => {
  // The key was cleared only on success, so every retry replayed a key the server had already
  // rejected; adding a service made that key fail permanently.
  const i = app.indexOf('idempotency key conflicts with changed business inputs');
  assert.ok(i > 0, 'the changed-inputs conflict must be handled explicitly');
  const src = app.slice(i - 400, i + 500);
  assert.ok(src.includes('rewardAutoSetupRequestKey=null'),
    'a changed-inputs conflict must mint a fresh key on the next try');
  // Built by concatenation rather than a template literal: interpolated copy assigned to
  // textContent must go through the workspace translation mechanism (v97 governance).
  assert.ok(app.includes("ownerErrorText(error)+' '+workspaceTranslationV97('Nothing was published.')"),
    'other failures must show the real reason, not a generic message');
});

test('an owner can say whether the business sells services, products or both', () => {
  // Owner: "some business is products only no services ... some have mix like salon
  // (so we can have default for the sectors but able to off or on if needed to)"
  assert.match(app, /id="sellsServices"/);
  assert.match(app, /id="sellsProducts"/);
  assert.match(app, /business_set_sales_mix_v184/);
  const i = app.indexOf("salesMixSave')");
  const src = app.slice(i, i + 1600);
  assert.ok(src.includes('Pick at least one'),
    'a business that sells neither has nothing to record a sale against');
  assert.ok(src.includes('also_disabled'),
    'the owner must be told what else was switched off, not discover it later');
  // The rest of the entitlement stays with the sector.
  assert.match(app, /Everything else is set by Peekaa for your sector/);
});
