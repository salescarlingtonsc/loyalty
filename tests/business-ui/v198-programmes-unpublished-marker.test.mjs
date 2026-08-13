import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V198 (owner, on the Programmes screenshot: "edited name inside but not shown").
   The owner renamed a reward inside an open configuration draft, returned to the Programmes
   list, and saw the OLD name — which reads as a lost edit.

   The list is right to keep showing the published name: it answers "what can my customers use
   right now", and a draft name is a promise nobody can act on yet. The owner chose this
   resolution explicitly. What was missing was the REASON, so the fix is a marker that says the
   edit is saved, says it is not live, and puts publish one tap away. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');

test('an open draft is announced on the Programmes list, not left silent', () => {
  assert.match(app, /const growDraftPendingId=snapshot\.draft\?\.id\|\|null;/);
  assert.match(app, /growUnpublishedMarkerV198/);
  assert.match(app, /id="growOverviewDraftBarV198"/);
  // rendered inside the rewards section, above the rows it explains
  const section = app.slice(app.indexOf('aria-label="Rewards overview"'));
  assert.ok(section.indexOf('${growUnpublishedMarkerV198}') < section.indexOf('grow-programme-list'),
    'the marker must appear before the programme rows it explains');
});

test('the marker names what the rows are showing, so the old name is not read as a lost edit', () => {
  assert.match(app, /You have unpublished changes\. The names and numbers below are what customers see today/);
  assert.match(app, /your edits go live when you publish/);
});

test('no draft means no marker — an owner with nothing pending is not nagged', () => {
  /* V301 ADDITION (owner 2026-08-13, the one-page setup wizard): the banner is also suppressed
     on the wizard's own view, whose last step IS the review — two doors to the same publish on
     one screen would be the contradiction the owner reported everywhere else. The V198 property
     is untouched: no draft still means no marker. */
  assert.match(app, /growDraftPendingId&&canRewards&&programmeView!=='setup'\s*\r?\n?\s*\?`<div class="imp-note" id="growOverviewDraftBarV198"/);
  assert.match(app, /:'';/);
});

test('publish is one tap away, and only for someone allowed to publish', () => {
  assert.match(app, /\$\{canSetupGrow\?'<button class="btn sm" id="growOverviewDraftPublishV198"/);
  /* V301 RETARGET, not a weakening. "One tap away" is the property; the destination changed
     from the studio review page — which auto-opened a modal over itself and could open it twice
     — to the wizard's own final step, which shows the same change list and calls the same
     publish RPC inline. openProtectedGrowPublishReview and #/studio/<draft> still exist and are
     still reached from the Studio rule builder. */
  assert.match(app, /if\(growOverviewDraftPublish\)growOverviewDraftPublish\.onclick=\(\)=>nav\('#\/grow\/setup\/review'\);/);
  assert.match(app, /function openProtectedGrowPublishReview\(draftVersionId\)\{/);
});

test('the published catalogue still drives the row names', () => {
  // regression guard on the owner's chosen resolution: the rows keep reading from the
  // published reward journey, never from the draft.
  assert.match(app, /const rewardJourney=ownerRewardJourneyV122\(\{\s*\r?\n?\s*rewards:snapshot\.rewards/);
});
