import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('birthday benefit can be a whole month, and month is the default for new programmes', () => {
  assert.match(app, /name="birthdayWindowMode" value="month"/);
  assert.match(app, /name="birthdayWindowMode" value="days"/);
  assert.match(app, /birthdayProgram\?\.window_mode\|\|'month'\)==='month'\?'checked'/,
    'a new programme must default to the month, which is what the copy usually promises');
  assert.match(app, /window_mode:mode/, 'the mode must reach the server');
  assert.match(app, /window_days_before:mode==='days'\?Number/,
    'month mode must not smuggle a stale day window to the server');
});

test('the day-window inputs only appear when the owner picks a day window', () => {
  assert.match(app, /daysFields\.style\.display=birthdayMode\(\)==='days'\?'':'none'/);
});

test('terms are treated as required, because the column enforces it', () => {
  // birthday_program_versions.customer_terms has a length>=1 CHECK; a blank box used to fail
  // the save with a raw constraint error.
  assert.match(app, /id="birthdayTermsSuggest"/, 'owners need a way to fill terms');
  assert.match(app, /Terms are required\./, 'a blank terms box must say so in owner language');
  const i = app.indexOf("birthdayTermsSuggest');");
  const src = app.slice(i, i + 1800);
  assert.ok(src.includes('during your birthday month') && src.includes('on your birthday'),
    'suggested wording must describe the window that was actually chosen');
  assert.ok(src.includes('Available once per customer each year'),
    'suggested terms must state the real limits');
});

test('tier fields have visible labels instead of screen-reader-only ones', () => {
  // The unlabelled "1.25" box was the multiplier; nothing on screen said so.
  assert.ok(!/class="sr-only" for="trMul"/.test(app), 'the multiplier must be visibly labelled');
  assert.ok(!/class="sr-only" for="trTh"/.test(app), 'the threshold must be visibly labelled');
  assert.ok(!/class="sr-only" for="trName"/.test(app), 'the name must be visibly labelled');
  assert.match(app, /<label for="trMul">Points earning speed<\/label>/);
  assert.match(app, /1 = normal\. 1\.5 = they earn 50% more points/,
    'the multiplier needs plain-English help, not a bare number box');
});

test('threshold help follows tier_basis rather than hardcoding points', () => {
  const i = app.indexOf('function tierBasisHelpV182');
  const src = app.slice(i, i + 500);
  assert.ok(src.includes("basis==='spend'") && src.includes("basis==='points_earned'"),
    'a spend ladder that says "points" is simply wrong');
  assert.match(app, /tierBasisHelpV182\(p\)/, 'the helper must actually be used');
});

test('tier benefits are tick boxes writing into the existing perk_note field', () => {
  assert.match(app, /TIER_BENEFIT_PRESETS_V182/);
  assert.match(app, /data-tier-benefit=/);
  // The checkboxes must be an input method over the existing store, not a second data model.
  const i = app.indexOf("document.querySelectorAll('[data-tier-benefit]').forEach(box=>box.onchange");
  /* V235 added mutual exclusion for the "% off" presets inside the same handler, so the
     window has to cover the whole block for the untick branch to be in it. */
  const src = app.slice(i, i + 1600);
  assert.ok(src.includes("$('trPerk')"), 'ticking must write into perk_note, the source of truth');
  assert.ok(src.includes('splice(at,1)'), 'unticking must remove exactly that line');
  assert.match(app, /function syncTierBenefitPicksV182/);
  assert.match(app, /syncTierBenefitPicksV182\(\);/, 'editing a tier must reflect its current benefits');
});

test('rarely-used tier controls are collapsed, and open only when in use', () => {
  assert.match(app, /<summary>Run this tier only between certain dates<\/summary>/);
  assert.match(app, /schedule\.open=!!\(tier\?\.effective_from\|\|tier\?\.expires_at\)/,
    'a tier that already has a schedule must not hide it');
});
