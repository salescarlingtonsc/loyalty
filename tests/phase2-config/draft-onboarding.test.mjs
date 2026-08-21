import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v25_draft_onboarding_loyalty.sql';

test('new workspaces receive an inactive loyalty draft', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /alter column configuration_status set default 'draft'/i);
  assert.match(migration, /alter column configuration_status set not null/i);
  assert.match(migration, /configuration_status <> 'draft' or not active/i);
  assert.match(migration, /v_business\.id, 'points', 1, 800, 2000, false, 'classic', 'draft'/i);
  assert.match(migration, /'onboarding_preset'/i);
  assert.match(migration, /insert into public\.subscriptions \(business_id\) values \(v_business\.id\)\s+on conflict \(business_id\) do nothing/i,
    'v25 must preserve the deployed v14 subscription seed');
  assert.doesNotMatch(migration, /v_business\.id, 'points'[^;]+true[^;]+'draft'/i);
});

test('existing loyalty configurations remain published', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /update public\.loyalty_programs\s+set configuration_status = 'published'\s+where configuration_status is null/i);
});

test('the owner sees draft state and explicitly publishes it', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  /* V235 merged the separate "Draft recommendation" and "unpublished changes" banners into ONE
     neutral strip, and the editor now carries a single primary action pair. The invariant is
     unchanged: the owner is told the draft is not live, and publishing is a separate step. */
  assert.match(app, /Draft — not visible to customers/);
  /* nestly_v415: the draft banner this line asserted was removed on the owner's instruction
     (photo 2, the banner ringed: "remove the circled area"). A generated recommendation still
     gets its own line above the editor — that is what is checked now — but it no longer tells
     the owner the page is withholding their edit, because it is not. */
  assert.match(app, /Suggested for you\.<\/b> \$\{esc\(recommendation\.rationale\)\}/);
  assert.match(app, /configuration_status:'published'/);
  assert.match(app, /<button class="btn" id="lsave">Save changes<\/button>/);
  assert.match(app, /Review &amp; publish/);
  assert.match(app, /preview_publish_impact/);
  assert.match(app, /publishConfirmationSensitive/);
  assert.match(app, /publishConfirmationStandard/);
  assert.match(app, /id="studioPubConfirm" type="button" disabled/);
  /* V288 (audit A2 LOW 22): RETARGETED, not deleted. The deliberate act is still required —
     it is a checkbox instead of transcribing the English word PUBLISH, which CLAUDE.md's
     low-literacy-first rule made indefensible for a WPass/SPass workforce. The button stays
     disabled until the acknowledgement is ticked. */
  assert.match(app, /\$\('studioPubConfirm'\)\.disabled=e\.target\.checked!==true/);
  /* nestly_v415: reversed on the owner's instruction (photo 2) — Save publishes, so this page no
     longer has a "saved but withheld" outcome to announce. The replacement outcome is asserted
     instead, together with the refusal path that keeps Save honest when the server says no. */
  assert.match(app, /Saved and live for customers/);
  assert.match(app, /savedNotLive/);
});

test('create_business retains authenticated-only execution', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(migration, /revoke all on function public\.create_business\(text, text, text, text\[\]\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.create_business\(text, text, text, text\[\]\) to authenticated/i);
});
