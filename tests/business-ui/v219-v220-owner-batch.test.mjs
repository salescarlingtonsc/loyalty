/* V219 + V220 — the owner's follow-up batch.
   Server behaviour is proved by rolled-back production chains (v219 6/6, v220 5/5 + 2/2).
   These pin the client half. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/* (2) "i need a drop down in the header to select which branch they want to view now" */
test('V219 the top-bar branch selector is filled on every page, not only when the profile menu opens', () => {
  const wireStart = app.indexOf('function wireProfile(page){');
  const wire = app.slice(wireStart, app.indexOf('\nfunction ', wireStart + 1));
  const hydrate = wire.indexOf('hydrateProfileBranchSelectorV158(page);');
  // The block, not the `if(profileOpen){bellOpen=false...}` inside the click handler above it.
  const menuOpen = wire.indexOf('\n  if(profileOpen){');
  assert.notEqual(hydrate, -1, 'the selector must still be hydrated');
  assert.ok(hydrate < menuOpen,
    'V210 moved the selector into the top bar but left its hydration inside if(profileOpen), ' +
    'so the header rendered an empty box on every page');
  // The mount itself stays in the app bar.
  assert.match(app, /<div class="topbar-branch-scope-v210" id="profileBranchScopeV158"/);
});

/* (1) "add branch inside (so can add or manage branches using the module as well)" */
test('V219 Branches is reachable from Operations setup for an owner', () => {
  const nav = app.slice(app.indexOf('const navModuleVisible='), app.indexOf('const visGroups='));
  assert.match(nav, /\|\|\(m==='branches'&&S\.myRole==='owner'\)/,
    'branches is never in the resolved module list, so it needs the same treatment as staffmembers');
  // It must no longer require membership of enabled_modules, which it can never have.
  assert.doesNotMatch(nav, /enabled\.includes\(m\)&&\(m!=='branches'/);
  // The page and route already existed; they must still be wired.
  assert.match(app, /branches:branchesPage/);
  assert.match(app, /if\(pageKey==='branches'&&S\.myRole!=='owner'\)/, 'still owner-only');
  /* V275: the Operations setup group gained a bar-only "Bottle keep" row. This assertion guards
     that the setup surfaces live HERE rather than in the account menu, not that the group is
     frozen, so the new row is admitted explicitly and everything it protects still holds. */
  assert.match(app, /\{key:'setup',[^}]*items:\['staffmembers','branches','services','inventory','packages'(?:,'bottlesetup')?(?:,'remindernotify')?\]\}/);
});

/* (3-repeat) "when selected the staff, it will show the user's next best timings - not other staff" */
test('V220 next best times are requested for the chosen teammate', () => {
  assert.match(app, /p_staff:\$\('astf'\)\.value==='auto'\?null:\$\('astf'\)\.value/,
    'a chosen teammate must be sent to the server so the suggested TIMES are theirs');
  // Auto-assign still sends null, so the fair rotation keeps deciding.
  const call = app.slice(app.indexOf("sb.rpc('suggest_appointment_staff_v47'"), app.indexOf("if(!stillCurrent())return null;"));
  assert.match(call, /p_recent_days:recentWindowDaysV217/);
});

/* "if the timing is clashed ... should pop up prompt ... change timing / suggest free staff" */
test('V220 a clash interrupts with both ways out and books nothing', () => {
  const prompt = app.slice(app.indexOf('function openClashPromptV220('), app.indexOf('async function renderAvailability(){'));
  assert.match(prompt, /is already busy then/);
  assert.match(prompt, /Nothing has been booked/);
  // Route 1: the chosen person's OWN other times.
  assert.match(prompt, /Other times \$\{esc\(staffLabel\)\} is free/);
  assert.match(prompt, /data-clash-time=/);
  // Route 2: someone who is actually free.
  assert.match(prompt, /Free at this time/);
  assert.match(prompt, /data-clash-staff=/);
  // Neither route books anything — they fill the form and re-check.
  assert.match(prompt, /close\(\);renderAvailability\(\);/);
  assert.doesNotMatch(prompt, /book_appointment_smart_v47/);
  // Dead ends still explain themselves.
  assert.match(prompt, /has no other free time left today/);
  assert.match(prompt, /Nobody else is free at this time either/);

  // And the booking handler actually opens it, asking for the chosen person's times.
  const conflictStart = app.indexOf("if(data?.status==='conflict')");
  const handler = app.slice(conflictStart, app.indexOf('bookingAttempt=null;', conflictStart));
  assert.match(handler, /openClashPromptV220/);
  assert.match(handler, /p_staff:assignment==='auto'\?null:assignment/);
});
