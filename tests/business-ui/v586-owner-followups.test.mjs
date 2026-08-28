/* nestly_v586 — the two follow-ups on the v585 batch.
 *
 * Item 2 ("i already changed to by per visit, but it refreshes back to points") is a DATABASE bug,
 * not a wording one: v585 made the page say the right noun, and the setting itself was still being
 * undone. Its proof lives in db/tests/v586_tier_basis_reaches_the_draft.sql, run against
 * production. What is asserted here is the migration's presence and shape, so the fix cannot be
 * quietly dropped from the chain, plus the v585 wording it depends on.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const shell = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const migration = readFileSync(
  new URL('../../db/migrations/20260829_nestly_v586_tier_basis_reaches_the_draft.sql', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return app.slice(from, to);
};

test('item 1 — Promotions has a way back', () => {
  assert.match(app, /grow-breadcrumb-back-v346" href="#\/grow\/offers" aria-label="Back to Limited Offer"/);
  assert.match(shell, /\.grow-breadcrumb-row-v585\{display:flex/);
});

test('item 1 — the Home band is one line about THIS offer', () => {
  const card = section('function promotionFeaturedCardV462', 'function promotionDemoteDialogV462');
  /* The badge is the one the Limited Offer list already uses, so the two surfaces cannot describe
     the same server fact in two shapes. */
  assert.match(card, /pill ok grow-offer-featured-mark-v485/);
  assert.match(card, /Shown on customer Home/);
  // The second offer picker and its paragraph are gone — that job belongs to the list.
  assert.doesNotMatch(card, /promotionFeaturedPickV462/);
  assert.doesNotMatch(card, /Show this one instead/);
  assert.doesNotMatch(card, /Customers see it on their Home screen alongside offers from other shops/);
  // A draft cannot be on Home, so it is offered no control rather than a lie.
  assert.match(card, /if\(!selected\)return '';/);
  // The action targets the offer the editor is open on, read from the button itself.
  assert.match(card, /data-promotion-featured-target-v586="\$\{esc\(selected\.id\)\}"/);
  assert.match(app, /button\?\.dataset\?\.promotionFeaturedTargetV586/);
  assert.match(shell, /\.promotion-featured-row-v586\{display:flex/);
});

test('item 2 — the setter reaches the open draft, and never a published snapshot', () => {
  /* THE BUG: business_set_tier_basis_v347 wrote only public.loyalty_programs. A draft created
     BEFORE the change still held the old basis, and publish_loyalty_config writes the published
     version's value straight back onto the live row — so the owner's choice was undone by the next
     publish. Measured on production: Jess Salon's open draft (16:47Z) said points_earned against a
     live row set to visits at 16:53Z. */
  assert.match(migration, /update public\.loyalty_program_versions v\s*\n\s*set tier_basis = v_basis/);
  assert.match(migration, /and f\.status = 'draft'/);
  assert.doesNotMatch(migration, /f\.status = 'published'/);
  // The one-time repair sets the DRAFT from the LIVE row, never the other way round.
  assert.match(migration, /set tier_basis = p\.tier_basis/);
  /* The draft write-guard is off for exactly one statement and back on immediately, inside the
     same transaction — a rollback restores it either way. */
  assert.match(migration, /disable trigger trg_c45_loyalty_program_version_write_guard/);
  assert.match(migration, /enable trigger trg_c45_loyalty_program_version_write_guard/);
  // Owner gate, whitelist and signature are untouched.
  assert.match(migration, /app\.c45_owner_loyalty_write\(p_business\)/);
  assert.match(migration, /not in \('visits','spend','points_earned'\)/);
  assert.match(migration, /grant execute on function public\.business_set_tier_basis_v347\(uuid,text\) to authenticated, service_role;/);
  // And it is one transaction, as the preflight requires.
  assert.match(migration, /^begin;/m);
  assert.match(migration, /^commit;/m);
});

test('item 2 — the words the fix depends on are still basis-driven (v585)', () => {
  assert.match(app, /const growTiersThresholdLabelV585=/);
  assert.match(app, /growTiersBasisIsSpendV585\?money\(Math\.round\(amount\*100\)\)/);
  assert.doesNotMatch(app, />Required points<\/label>/);
  assert.doesNotMatch(app, /Reached at \$\{threshold\} points/);
});
