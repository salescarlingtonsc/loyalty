/*
 * nestly_v465 (owner ruling R7) — the generated workspace copy table has a generator, and the
 * three stamps strings went in through it.
 *
 * Every test here EXECUTES scripts/quality/generate-workspace-copy-v97.mjs. Nothing greps app.js
 * for the strings: a table that contains the right characters but is unreachable, or reachable but
 * not reproducible from its ledger, is exactly the failure this ruling was written about.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {generate, buildTable, readAdditions, locateTable}
  from '../../scripts/quality/generate-workspace-copy-v97.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const appPath = path.join(root, 'app', 'app.js');
const additionsPath = path.join(root, 'app', 'i18n', 'workspace-generated-copy-v97.additions.json');
const generatorPath = path.join(root, 'scripts', 'quality', 'generate-workspace-copy-v97.mjs');

const appSource = readFileSync(appPath, 'utf8');
const additionsSource = readFileSync(additionsPath, 'utf8');
const table = JSON.parse(locateTable(appSource).literal);

const STAMP_ROWS = ['Stamps earned', 'Stamps redeemed', 'Stamps expired'];
const POINT_ROWS = ['Points earned', 'Points redeemed', 'Points expired'];
/* The 2026-08-23 邮票→印花 corrections: four v97-era machine translations rendered a loyalty
   stamp as a POSTAGE stamp. They ride the same ledger, so the register check below names them. */
const COPY_FIXES_20260823 = [
  'Stamps',
  'Give bonus stamps',
  'Spend per stamp',
  'Customers collect stamps automatically as they spend. Define what each milestone is worth — a free item to hand over, or store credit.',
];

/* nestly_v906 wave 1 — the workspace chrome and the Help Centre's structural labels. The
   generated table was machine-translated in ONE pass at v97 and never regenerated, so every
   label the product gained after that rendered English to a zh-CN or ms reader while the
   mechanism itself was working perfectly. This is the register of that first wave: the rail,
   the app bar, the account menu and the Help Centre's own furniture. Help ARTICLE PROSE is
   deliberately absent — a mistranslated counter instruction is worse than an English one. */
/* nestly_v907 wave 2 — Help Centre ARTICLE PROSE, shipped a complete guide at a time. The
   Getting Started section (Start here, Finding your way around, Roles and access, Your first
   week) and the Dashboard guide. A guide with English steps under Chinese headings reads worse
   than an English one, so a guide is never half-done. */
const WAVE2_HELP_PROSE_20260915 = [
  "Start here",
  "What Peekaa does, and the first few things to set up.",
  "Peekaa records what your customers buy and turns it into loyalty they can spend with you again. You run the counter, your customers see their own rewards in their phone, and both sides read the same records.",
  "How the whole thing fits together",
  "You set up what you sell — services, products, packages.",
  "You decide what customers earn — points, stamps, tiers, a welcome gift, a birthday treat.",
  "Your staff record every sale at Record sale.",
  "Peekaa works out the earning and shows it to the customer in their own app.",
  "The customer comes back, shows a reward QR, and your staff scan it at the counter.",
  "Two apps, one set of records",
  "The workspace you are in now is for you and your team. Your customers use a separate Peekaa app on their phone: they join by scanning your business QR, and they see their own points, rewards and visit history. Both read the same records, so nothing has to be kept in step by hand.",
  "Your first hour",
  "Open Get started from the account menu in the top right. It checks what is set up and what is not.",
  "Add at least one service or product. Nothing else works until there is something to sell.",
  "Set up one reward programme in Rewards & Offer, and publish it.",
  "Print or display your business QR so customers can join.",
  "Record one real sale at Record sale, and check that the points appear.",
  "Who this workspace is for",
  "Everyone on your team signs in to the same workspace, but each person sees only the parts you have given them. If a screen described in this guide is not in your sidebar, your account does not have it — ask the owner.",
  "Get started never disappears. If you press \"Don't show this again\", it is still in the account menu under Get started.",
  "Only the owner can open Get started, Branches, Staff Members, Customer Interface, Reminder & Notification and Subscription.",
  "Do I have to finish setup in order?",
  "No. Get started lists what is missing and you can do it in any order — but add something to sell first, because sales, packages and rewards all reference it.",
  "Do my customers need to download an app?",
  "They open Peekaa in their phone browser after scanning your QR. They can add it to their home screen; there is nothing to install first.",
  "Finding your way around",
  "What the sidebar groups mean and where things live.",
  "The sidebar is grouped by what you do across a day, not by how the data is stored. Each group opens to show the screens inside it.",
  "On a phone or tablet",
  "Below about 960 pixels wide the sidebar is replaced by a bar along the bottom: Record sale, Scan QR, Appointments, and More. More opens the full menu, including Help.",
  "Today and this week at a glance: money in, visits, what is scheduled.",
  "Everyone who has joined your programme, and each customer's full history.",
  "The counter: Record sale, Appointments, Bookings, Waitlist, Customer packages.",
  "Everything customers earn or claim: Overview, Rewards Programme, Limited Offer, History.",
  "What your customers see — your business profile, booking rules and permissions. Owner only.",
  "Daily report, Sales, Staff commission, Business Insights, Business Intelligence.",
  "The things you set once: Staff Members, Branches, Services, Products, Packages, Reminder & Notification.",
  "Top right",
  "Find a customer, Record sale, the notifications bell, Help, and your account menu.",
  "The sidebar only shows what your account can open. A missing group is a permission or an entitlement, not a fault.",
  "The branch selector in the top bar decides what every number on the screen means. Change it and the figures change with it.",
  "A module I was told about is not in my sidebar",
  "Your role does not include it — Branches, Staff Members, Subscription, Customer Interface and Reminder & Notification are owner-only.",
  "The owner has switched that module off for your account in Staff Members.",
  "Your business type does not use it. F&B and bars take table Bookings and a Waitlist instead of Appointments.",
  "Peekaa has not included that module in your plan.",
  "Ask the owner to check your access in Staff Members.",
  "If the owner cannot switch it on either, the module is not part of your plan — contact Peekaa.",
  "Roles and access",
  "Who can do what, and why a button may not appear.",
  "Every person on your team has one role, and the owner can additionally switch individual modules on or off for them. The role decides broad authority; the module switches decide which screens they open.",
  "On top of the role: module access",
  "In Staff Members the owner sets each teammate's modules to Off, Read or Edit. Read means they can open the screen but not change anything; the screen says so at the top. Owners always have every module the business has.",
  "Two reasons a screen can be closed to you",
  "Your role — for example, Staff commission needs finance access, which only Owner, Manager and Bookkeeper have.",
  "Your module switches — the owner has set that module to Off for you.",
  "Full access to everything the business has, including Branches, Staff Members, Subscription and Customer Interface. There is exactly one owner role and it cannot be given out by invite.",
  "Can record sales and see money figures. Cannot open owner-only screens.",
  "Can record sales. Cannot see money figures such as Staff commission or Business Intelligence.",
  "Same as Staff: can record sales, cannot see money figures.",
  "Can see money figures. Cannot record sales.",
  "Typing a screen's address does not get around either check. The screen refuses and sends you back with a short message.",
  "A read-only screen shows a \"Read-only access\" note at the top rather than hiding the information.",
  "Changing someone's role or module access takes effect the next time they load the workspace.",
  "A teammate says a button is missing that I can see",
  "Their role cannot perform it — only Owner and Manager see money figures; Bookkeepers cannot record sales.",
  "You set that module to Read rather than Edit.",
  "The module is switched off for them entirely.",
  "Open Staff Members, find the person, and check the role and the module list.",
  "Set the module they need to Edit, then ask them to reload the workspace.",
  "Can I have two owners?",
  "No. The owner role is not invitable. Give a trusted teammate the Manager role instead — it covers everything except Branches, Staff Members, Subscription and Customer Interface.",
  "What is the difference between Staff and Front desk?",
  "Nothing in what they are allowed to do — both can record sales and neither sees money figures. They exist so your roster reads correctly.",
  "Your first week, step by step",
  "A short path from an empty workspace to a running programme.",
  "Do these in order. Each step depends on the one before it, and each links to the guide for that screen.",
  "The order that works",
  "Set up your branch details. Operations setup -> Branches. Your address and phone appear on the customer's business page.",
  "Add what you sell. Operations setup -> Services and Products. At least one is required before anything else works.",
  "Add your team. Operations setup -> Staff Members. Invite anyone who needs to sign in; add roster-only people for scheduling.",
  "Choose your reward programme. Rewards & Offer -> Rewards Programme. Set up Point system or Stamp card, then publish it.",
  "Add at least one reward customers can claim. A programme that earns with nothing to claim gives customers nothing to aim at.",
  "Turn on your extras. Welcome gift for new sign-ups, Birthday benefit, Referrals, Bring-back rewards.",
  "Set what your customers see. Customer Interface -> Business Profile, then Customer Permission for booking rules.",
  "Display your business QR. Account menu -> My Business QR. Print it for the counter.",
  "Record your first real sale and check the customer's points moved.",
  "You are running when",
  "A customer can scan your QR and see your programme.",
  "A sale at the counter changes their points.",
  "A reward they claim can be scanned and given at the counter.",
  "Today and this week, for the branch you are viewing.",
  "The first screen of the workspace. It shows what happened today and this week for the branch selected in the top bar, plus what is scheduled next.",
  "See money in, visits and members joined for the period",
  "See what is scheduled today",
  "Open the screen behind any figure",
  "This week",
  "Money recorded, visits and joins for the current week.",
  "Today schedule",
  "Appointments or bookings due today.",
  "How the period compares, with the date range you choose.",
  "Branch selector (top bar)",
  "Which branch every figure on the screen is for.",
  "Every figure is for the branch shown in the top bar. Switch branch and the whole screen changes.",
  "Only an owner or manager can view all branches at once. Other roles see the branch they are assigned to.",
  "When a figure cannot be read, Peekaa says so rather than showing a zero.",
  "The numbers look wrong or too low",
  "A single branch is selected and you expected the whole business.",
  "The date range is not the one you think it is.",
  "Sales recorded as a walk-in are not linked to a customer, so they do not appear in member figures.",
  "Check the branch selector in the top bar.",
  "Check the date range on the Performance card.",
  "Open Sales for the same range to see the individual records behind the total.",
];

const WAVE1_CHROME_20260915 = [
  "Rewards & Offer",
  "Rewards Programme",
  "Limited Offer",
  "History",
  "Customer Interface",
  "Business Insights",
  "Sales & refunds",
  "Staff Members",
  "Reminder & Notification",
  "Retention",
  "Bottles",
  "Bottle keep",
  "Business Profile",
  "Appointment Setting",
  "Customer Permission",
  "Customer Sign-up",
  "Done",
  "Owner",
  "Manager",
  "Front desk",
  "Bookkeeper",
  "Find a customer  ( / )",
  "Find a customer by name or phone",
  "Search customers",
  "Scan redemption QR",
  "Staff quick actions",
  "More workspace modules",
  "Workspace settings",
  "Account links",
  "Current workspace",
  "Signed in as",
  "Your display name",
  "Viewing data for",
  "Language",
  "Help",
  "Help Centre",
  "Help home",
  "Help sections",
  "How can we help you?",
  "Search for anything…",
  "Search guides, features or questions",
  "Clear search",
  "Getting started",
  "More help",
  "Common tasks",
  "See all common tasks",
  "Troubleshooting",
  "Frequently asked questions",
  "Glossary",
  "On this page",
  "What is this?",
  "What can I do here?",
  "Understanding this screen",
  "Things to know",
  "Common problems",
  "Common questions",
  "Related guides",
  "Where to go",
  "Steps",
  "Possible reasons",
  "What to do",
  "Still not working?",
  "Across the workspace",
  "We couldn't find a guide for that",
  "Open this guide on its own page",
];

test('the three stamps rows are translated in both locales', () => {
  for (const locale of ['zh-CN', 'ms']) {
    for (const source of STAMP_ROWS) {
      const value = table[locale][source];
      assert.ok(value, `${locale} has no entry for ${source}`);
      assert.notEqual(value, source, `${locale}/${source} is still English`);
    }
  }
});

test('they are the twins of the points rows the app already translated, not new copy', () => {
  /* The Reports money card renders all six from one expression —
     `${loyaltyUnitNounV461(d.loyalty_unit)} earned` — so a stamps merchant and a points merchant
     are reading the SAME row. If the points half were ever untranslated this pairing would be
     meaningless, so that is asserted rather than assumed. */
  for (const locale of ['zh-CN', 'ms']) {
    for (const source of POINT_ROWS) {
      assert.ok(table[locale][source], `${locale} lost its ${source} translation`);
      assert.notEqual(table[locale][source], source);
    }
  }
  const noun = readFileSync(appPath, 'utf8');
  assert.match(noun, /function loyaltyUnitNounV461\(unit\)/,
    'the rows are still built from the unit noun; if that goes, re-point these strings');
});

test('the strings came from the reviewed ledger, and the ledger demands a reason', () => {
  const entries = readAdditions(additionsSource);
  /* nestly_v825 adds 'Staff commission' through the same ledger; nestly_v892 adds the renamed
     module's label and its page subtitle through it too. */
  assert.deepEqual(entries.map(entry => entry.source).sort(), [...STAMP_ROWS, ...COPY_FIXES_20260823,
    'Staff commission', 'Business Intelligence', 'Know what happened. See what to do next.',
    ...WAVE1_CHROME_20260915, ...WAVE2_HELP_PROSE_20260915].sort());
  for (const entry of entries) {
    assert.ok(entry.reason.trim().length > 20, `${entry.source} must say why it was added`);
    for (const locale of ['zh-CN', 'ms']) assert.equal(table[locale][entry.source], entry[locale]);
  }
});

test('the ledger refuses a placeholder, a duplicate and a missing locale', () => {
  const bad = [
    [{source: 'X', reason: 'because', 'zh-CN': 'X', ms: 'Y'}, /untranslated in zh-CN/],
    [{source: 'X', reason: 'because', 'zh-CN': '甲'}, /missing its ms string/],
    [{source: 'X', reason: '', 'zh-CN': '甲', ms: 'Y'}, /must say why/],
    [{reason: 'because', 'zh-CN': '甲', ms: 'Y'}, /no source string/],
  ];
  for (const [entry, message] of bad) {
    assert.throws(() => readAdditions(JSON.stringify({entries: [entry]})), message);
  }
  assert.throws(() => readAdditions(JSON.stringify({entries: [
    {source: 'X', reason: 'because', 'zh-CN': '甲', ms: 'Y'},
    {source: 'X', reason: 'because', 'zh-CN': '乙', ms: 'Z'},
  ]})), /twice/);
});

test('the generator is idempotent, and app.js already equals what it produces', () => {
  const once = generate({appSource, additionsSource});
  assert.equal(once.changed, false, 'app/app.js is out of date — run npm run workspace-copy');
  const twice = generate({appSource: once.next, additionsSource});
  assert.equal(twice.next, once.next, 'a second run must produce identical bytes');
  /* nestly_v906 wave 1 adds the 65 chrome strings in WAVE1_CHROME_20260915: 1478 -> 1543. The wave
     ADDS only — 'How it works' and 'How to use it' were drafted into it and then taken back out on
     finding they were already translated at v97, because re-wording reviewed copy is a separate
     decision from filling a gap.
     nestly_v907 wave 2 adds the 113 Help article strings in WAVE2_HELP_PROSE_20260915: 1543 ->
     1656. */
  assert.equal(once.keyCount, 1656);
});

test('--check exits non-zero when the table drifts from the ledger', () => {
  /* Executed as the CLI, because that is how a human and a CI step will meet it. */
  const clean = execFileSync(process.execPath, [generatorPath], {cwd: root, encoding: 'utf8'});
  assert.match(clean, /up to date: 1656 strings per locale/);

  /* And the same code path, given a table with one string removed, must report drift. */
  const stripped = appSource.replaceAll('"Stamps expired":', '"Stamps expired ":');
  assert.notEqual(stripped, appSource, 'fixture must actually change the table');
  assert.equal(generate({appSource: stripped, additionsSource}).changed, true,
    'a table missing one ledger string must be reported as drift, not silently accepted');
});

test('the table keeps its canonical shape: same keys in both locales, sorted, pure JSON', () => {
  const zh = Object.keys(table['zh-CN']);
  const ms = Object.keys(table.ms);
  assert.deepEqual(zh, ms, 'a locale with extra or missing keys is a half-translated release');
  assert.deepEqual(zh, [...zh].sort(), 'keys must be in code-point order');
  assert.equal(JSON.stringify(table), locateTable(appSource).literal,
    'the literal must be exactly JSON.stringify output — the v97 test JSON.parses it');
});

test('NEGATIVE CONTROL: the base this change was written against had none of the three', () => {
  const before = execFileSync('git', ['show', 'b290151:app/app.js'],
    {cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  const baseTable = JSON.parse(locateTable(before).literal);
  for (const locale of ['zh-CN', 'ms']) {
    assert.equal(Object.keys(baseTable[locale]).length, 1472);
    for (const source of STAMP_ROWS) {
      assert.equal(baseTable[locale][source], undefined,
        `${locale}/${source} already existed at b290151; re-point this control`);
    }
    /* while the points twins did, which is what made the gap visible */
    for (const source of POINT_ROWS) assert.ok(baseTable[locale][source]);
  }
  /* And the table really was hand-edited before: exactly one key out of sort order. */
  const baseKeys = Object.keys(baseTable['zh-CN']);
  const descents = baseKeys.filter((key, index) => index > 0 && key < baseKeys[index - 1]);
  assert.deepEqual(descents, ['/month'],
    'the one appended-by-hand key; the generator puts it back in order');
  assert.throws(() => buildTable(locateTable(before).literal, [
    {source: 'Stamps earned', reason: 'x', 'zh-CN': '赚取印花'},
  ]), /missing its ms string/, 'a half-filled entry cannot reach the table');
});
