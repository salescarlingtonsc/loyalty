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

/* SUPERSEDED BY V358 — kept as the guard that the removal stays removed.

   The four tests that used to live here pinned the "You have unpublished changes" banner, its
   wording, the exact screens it was suppressed on, and its Publish button. The owner then struck
   the whole thing out (photo 4: "remove this review & publish feature", "remove this entirely from
   my codebase / i dont want to see it"), and V358 obliged: every reward surface an owner can touch
   is immediate-write now (V326 gifts, V331/V345 tiers, V347 tier basis, V350 stamp levels, V354
   programme switches), so the banner was advertising a step that no longer applied to anything.

   Deleting these tests would leave nothing watching that decision, so they are inverted instead:
   the marker slot must render nothing, and neither the banner nor its publish button may come
   back. The V198 property they were originally written for — the rows keep showing the PUBLISHED
   name, never the draft name — is untouched and still asserted by the last test in this file. */

test('V358 the unpublished-changes banner is gone, and its slot renders nothing', () => {
  assert.match(app, /const growUnpublishedMarkerV198='';/,
    'the marker must resolve to the empty string, not to a rebuilt banner');
  assert.doesNotMatch(app, /id="growOverviewDraftBarV198"/,
    'the struck-out banner must not be rebuilt');
  assert.doesNotMatch(app, /You have unpublished changes\./,
    'nor its wording');
});

test('V358 no owner-facing publish control survives on the programme surfaces', () => {
  assert.doesNotMatch(app, /id="growOverviewDraftPublishV198"/,
    'the banner\'s Publish button went with it');
  /* The versioned-config kernel underneath is deliberately untouched: gift and tier creation still
     require an active config version, so the plumbing must stay reachable in code even though no
     owner-facing banner points at it. */
  assert.match(app, /const growDraftPendingId=snapshot\.draft\?\.id\|\|null;/,
    'the draft is still tracked, because creation depends on a published config version existing');
  assert.match(app, /function openProtectedGrowPublishReview\(draftVersionId\)\{/,
    'the Studio rule builder still reaches the review path');
});

test('the published catalogue still drives the row names', () => {
  // regression guard on the owner's chosen resolution: the rows keep reading from the
  // published reward journey, never from the draft.
  assert.match(app, /const rewardJourney=ownerRewardJourneyV122\(\{\s*\r?\n?\s*rewards:snapshot\.rewards/);
});
