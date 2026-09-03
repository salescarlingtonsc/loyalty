/* nestly_v750 — EXECUTED measurement of the tier add/edit pop-up and the referral pop-up, against
 * the production render function (growPage) and the production stylesheet, not a restated
 * approximation of either. See app/index.html's nestly_v750 comment (search
 * "[data-grow-tiers-summary-v331]>li:not(.grow-inline-modal-v658)") for the measured root cause:
 * a `padding:0!important` rule scoped to this list's rows also matched the pop-up <li> (both are
 * direct children of the same <ul data-grow-tiers-summary-v331>), and — once exempted from that —
 * a same-specificity, later-in-source card-styling rule would have won the tie instead, and a
 * separate, unscoped `label{margin:16px 0 6px}` base rule was still spacing every label away from
 * its own input regardless of the dialog's own flex gap. This file would have failed on every one
 * of those three defects before the fix (padding 0 on all sides; a 1px border/second shadow if
 * only the first defect were patched; a 12px label-to-input gap instead of <=8px).
 *
 * The fixture (tests/browser/generate-v750-tier-dialog-visual.mjs) renders growPage() for real —
 * same discipline as tests/browser/generate-reward-overview-owner-visual.mjs (see that file's
 * nestly_v421 notes): the tiers page, the tier add/edit dialog, and the referral settings pop-up
 * are all part of one production function, extracted whole rather than restated, so a change to
 * any of them shows up here rather than being silently missed by a hand-built lookalike.
 *
 * Skips cleanly (does not fail) when no Playwright driver is available in this environment.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { buildTierDialogVisualFixture, } from '../browser/generate-v750-tier-dialog-visual.mjs';

const APP_URL = new URL('../../app/index.html', import.meta.url);
const APP_SCRIPT_URL = new URL('../../app/app.js', import.meta.url);
const CUI_URL = new URL('../../app/customer-ui.js', import.meta.url);
const evidenceDir = new URL('../../docs/qa/evidence/v750-tier-dialog-alignment/', import.meta.url);

async function loadPlaywright() {
  const moduleNames = [process.env.PLAYWRIGHT_MODULE, 'playwright-core', 'playwright'].filter(Boolean);
  for (const name of moduleNames) {
    try {
      const mod = await import(name);
      const chromium = mod.chromium || mod.default?.chromium;
      if (chromium) return chromium;
    } catch (error) { /* try the next candidate */ }
  }
  return null;
}

async function buildFixtureHtml() {
  const [indexSrc, appSrc, cui] = await Promise.all([
    readFile(APP_URL, 'utf8'), readFile(APP_SCRIPT_URL, 'utf8'), readFile(CUI_URL, 'utf8'),
  ]);
  return buildTierDialogVisualFixture(`${indexSrc}\n${appSrc}`, cui);
}

test('nestly_v750 tier dialog alignment (executed browser measurement)', async (t) => {
  const chromium = await loadPlaywright();
  if (!chromium) {
    t.skip('No Playwright driver available (set PLAYWRIGHT_MODULE to a playwright-core/playwright ' +
      'index.js, or npm install one) — skipping the executed browser measurement.');
    return;
  }

  const html = await buildFixtureHtml();
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {}),
  });
  const consoleErrors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
    page.on('pageerror', (error) => consoleErrors.push(String(error)));
    await page.setContent(html, { waitUntil: 'load' });
    await page.waitForSelector('[data-grow-topic-v229="tiers"]');

    await t.test('Add a tier: padding, title, label-to-input rhythm, no right-edge overflow', async () => {
      await page.locator('[data-grow-topic-v229="tiers"]').click();
      await page.locator('[data-grow-tiers-add-v331]').click();
      await page.waitForSelector('[data-grow-tiers-addform-v331]');
      const metrics = await page.evaluate(() => window.tierDialogMetrics());

      assert.equal(metrics.title.text, 'Add a tier');
      for (const side of ['paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft']) {
        assert.ok(metrics.dialog[side] >= 16,
          `dialog ${side} must be >=16px (was ${metrics.dialog[side]}px) — this is exactly what read` +
          ' 0px on all four sides before the fix');
      }
      // The title must sit inside the dialog's own padding box, not flush against its border —
      // i.e. it starts at least paddingLeft/paddingTop past the dialog's own edge.
      assert.ok(metrics.title.rect.left - metrics.dialog.left >= metrics.dialog.paddingLeft - 1,
        'the title must not be clipped against the dialog\'s left edge');
      assert.ok(metrics.title.rect.top - metrics.dialog.top >= metrics.dialog.paddingTop - 1,
        'the title must not be clipped against the dialog\'s top edge');

      assert.ok(metrics.paragraphs.length >= 2, 'both "Tier name" and the threshold field must be present');
      for (const paragraph of metrics.paragraphs) {
        assert.ok(paragraph.labelToInputGap !== null && paragraph.labelToInputGap <= 8,
          `"${paragraph.labelText}" label must sit <=8px above its own input (was ${paragraph.labelToInputGap}px)`);
        assert.ok(paragraph.inputRect.right <= metrics.dialogRight + 0.5,
          `"${paragraph.labelText}" input must not overflow the dialog's right edge`);
      }
      // Consistent vertical rhythm: both field groups are the same shape (label + gap + input),
      // so they must report the same total height — a regression that only fixes one field would
      // leave them unequal.
      assert.equal(metrics.paragraphs[0].rect.height, metrics.paragraphs[1].rect.height,
        'every field group must keep the same vertical rhythm as its siblings');
      assert.ok(metrics.dialogRight <= metrics.viewportWidth,
        'the dialog itself must not overflow the viewport');

      await mkdir(fileURLToPath(evidenceDir), { recursive: true });
      await page.screenshot({ path: fileURLToPath(new URL('after-add-tier-desktop-1440.png', evidenceDir)) });
    });

    await t.test('Edit tier: same fix applies to the pre-filled dialog', async () => {
      await page.locator('[data-grow-tiers-add-cancel-v331]').first().click();
      await page.waitForSelector('[data-grow-tiers-row-edit-v345]');
      await page.locator('[data-grow-tiers-row-edit-v345="tier-1"]').click();
      await page.waitForSelector('[data-grow-tiers-addform-v331]');
      const metrics = await page.evaluate(() => window.tierDialogMetrics());
      assert.equal(metrics.title.text, 'Edit tier');
      for (const side of ['paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft']) {
        assert.ok(metrics.dialog[side] >= 16, `Edit tier dialog ${side} must be >=16px`);
      }
      for (const paragraph of metrics.paragraphs) {
        assert.ok(paragraph.labelToInputGap <= 8,
          `Edit tier: "${paragraph.labelText}" label must sit <=8px above its input`);
      }
      await mkdir(fileURLToPath(evidenceDir), { recursive: true });
      await page.screenshot({ path: fileURLToPath(new URL('after-edit-tier-desktop-1440.png', evidenceDir)) });
    });

    await t.test('nestly_v749 guard: referral pop-up swap paragraphs are truly hidden, not merely `hidden`-attributed', async () => {
      await page.goto('about:blank');
      await page.setContent(html, { waitUntil: 'load' });
      await page.waitForSelector('[data-grow-topic-v229="referrals"]');
      await page.locator('[data-grow-topic-v229="referrals"]').click();
      await page.locator('[data-rewards-overview-edit="referralSettingsV364"]').click();
      await page.waitForSelector('[data-grow-referral-settings-v364]');

      const assertReallyHidden = (wrap, label) => {
        assert.equal(wrap.hidden, true, `${label} must carry the hidden attribute`);
        assert.equal(wrap.offsetParent, false, `${label} must not be laid out (offsetParent must be null)`);
        assert.equal(wrap.height, 0, `${label} must render at zero height`);
      };
      const assertVisible = (wrap, label) => {
        assert.equal(wrap.hidden, false, `${label} must not carry the hidden attribute`);
        assert.equal(wrap.offsetParent, true, `${label} must be laid out`);
        assert.ok(wrap.height > 0, `${label} must render at a real height`);
      };

      // Default kind is 'points' (the fixture's referral row has reward_kind:'points').
      let ref = await page.evaluate(() => window.referralWrapMetrics());
      assertVisible(ref.growReferralPointsWrapV420, 'growReferralPointsWrapV420 (kind=points)');
      assertVisible(ref.growReferralFriendPointsWrapV421, 'growReferralFriendPointsWrapV421 (kind=points)');
      assertReallyHidden(ref.growReferralGiftWrapV420, 'growReferralGiftWrapV420 (kind=points)');
      assertReallyHidden(ref.growReferralFriendGiftWrapV421, 'growReferralFriendGiftWrapV421 (kind=points)');

      await page.locator('input[name="growReferralKindV420"][value="voucher"]').click();
      await page.waitForFunction(() => {
        const el = document.getElementById('growReferralGiftWrapV420');
        return el && !el.hasAttribute('hidden');
      });
      ref = await page.evaluate(() => window.referralWrapMetrics());
      assertVisible(ref.growReferralGiftWrapV420, 'growReferralGiftWrapV420 (kind=voucher)');
      assertVisible(ref.growReferralFriendGiftWrapV421, 'growReferralFriendGiftWrapV421 (kind=voucher)');
      assertReallyHidden(ref.growReferralPointsWrapV420, 'growReferralPointsWrapV420 (kind=voucher)');
      assertReallyHidden(ref.growReferralFriendPointsWrapV421, 'growReferralFriendPointsWrapV421 (kind=voucher)');
    });

    assert.deepEqual(consoleErrors, [], `the fixture must render with no page errors: ${consoleErrors.join('; ')}`);
  } finally {
    await browser.close();
  }
});
