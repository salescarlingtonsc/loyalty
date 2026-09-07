/* F109 (audit wave 3A, commit f4e7504e, 2026-09-02): the stamp-slot "Choose 1" copy was stale.
 *
 * At v323, public.stamp_milestone_claims carried a unique key on
 * (business, client, programme, cycle, slot_position) — one gift per milestone slot per card —
 * so two catalogue gifts sharing a stamp slot really were mutually exclusive, and the customer
 * screen said "Choose 1 — staff will scan the one you pick." accordingly.
 *
 * db/migrations/20260824_nestly_v478_earned_stamp_gifts_survive_a_claimed_card.sql dropped that
 * slot-based constraint (stamp_milestone_claims_slot_uk) and kept only
 * stamp_milestone_claims_reward_uk (one claim per GIFT, not per slot), specifically so a customer
 * who earns two gifts on one stamp slot can claim both. The old "Choose 1" sentence survived the
 * migration and kept telling every such customer to pick only one — commit f4e7504e corrected it
 * to "Both are yours — show each one's QR separately to claim it."
 *
 * tests/customer-wallet/v422-owner-batch8.test.mjs already covers this indirectly, inside a much
 * larger test built around the whole `loadRewards` function body. This file pins the corrected
 * copy on its own, directly at its source site, so a future edit to that sentence — or a
 * regression of the stale wording — fails here even if the larger test is ever narrowed or moved.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const marker = 'data-rewards-chooseone-v428';
const markerIndex = app.indexOf(marker);

test('F109: the shared-slot marker exists exactly once, at the rewards list', () => {
  assert.ok(markerIndex >= 0, `${marker} must exist in app/app.js`);
  assert.equal(app.indexOf(marker, markerIndex + 1), -1,
    'exactly one site prints this sentence — a second would risk the two disagreeing');
});

test('F109: the site prints the corrected copy, not the stale "Choose 1" wording', () => {
  // The exact statement the chooseOneSlotV428 ternary emits, pinned byte-for-byte.
  const statementStart = app.lastIndexOf('${chooseOneSlotV428?', markerIndex);
  assert.ok(statementStart >= 0 && markerIndex - statementStart < 200,
    'the marker must sit inside the chooseOneSlotV428 conditional that decides whether to print it');
  const statementEnd = app.indexOf('</p>\':\'\'}', statementStart) + '</p>\':\'\'}'.length;
  assert.ok(statementEnd > statementStart, 'could not find the end of the chooseOneSlotV428 statement');
  const statement = app.slice(statementStart, statementEnd);

  assert.match(statement,
    /<p class="muted small customer-programme-rewards-lede" data-rewards-chooseone-v428>Both are yours — show each one’s QR separately to claim it\.<\/p>/,
    'F109: corrected copy — both gifts on a shared stamp slot are independently claimable since v478');

  assert.doesNotMatch(statement, /Choose 1/,
    'the stale wording this audit flagged — the server has allowed claiming both since v478');
  assert.doesNotMatch(statement, /the one you pick/,
    'no phrasing may imply the two gifts are mutually exclusive');
});

test('F109: the count line beside it still says two ARE on offer (unchanged by the copy fix)', () => {
  // The very next line in source keeps stating the reward count — the fix only touched the
  // sentence about which of the two the customer may take, never whether two are listed.
  const nextLineStart = app.indexOf('customer-programme-rewards-lede">Pick a reward', markerIndex);
  assert.ok(nextLineStart > markerIndex && nextLineStart - markerIndex < 400,
    'the "Pick a reward…" line must immediately follow the chooseOneSlotV428 sentence');
});
