import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  mkdtemp, mkdir, readFile, rm, symlink, unlink, writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planRelativePath = 'db/migrations/migration-order.plan.json';
const manifestRelativePath = 'db/migrations/migration-order.manifest.json';
const digestRelativePath = `${manifestRelativePath}.sha256`;
const generatorRelativePath = 'scripts/migrations/generate-manifest.mjs';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function isolatedManifestRepo(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'frenly-migration-manifest-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await Promise.all([
    mkdir(path.join(root, 'db/migrations'), { recursive: true }),
    mkdir(path.join(root, 'scripts/migrations'), { recursive: true })
  ]);

  const planBytes = await readFile(path.join(repoRoot, planRelativePath));
  const plan = JSON.parse(planBytes);
  await Promise.all([
    writeFile(path.join(root, planRelativePath), planBytes),
    writeFile(path.join(root, generatorRelativePath), await readFile(path.join(repoRoot, generatorRelativePath)))
  ]);
  await Promise.all(plan.items
    .filter(({ kind }) => kind === 'executable')
    .map(async ({ path: migrationPath }) => {
      await writeFile(path.join(root, migrationPath), await readFile(path.join(repoRoot, migrationPath)));
    }));
  return root;
}

function runGenerator(root, option = '--check') {
  return spawnSync(process.execPath, [generatorRelativePath, option], {
    cwd: root,
    encoding: 'utf8'
  });
}

async function readPlan(root) {
  return JSON.parse(await readFile(path.join(root, planRelativePath), 'utf8'));
}

async function writePlan(root, plan) {
  await writeFile(path.join(root, planRelativePath), `${JSON.stringify(plan, null, 2)}\n`);
}

function assertGeneratorFailure(result, pattern) {
  assert.notEqual(result.status, 0, 'Expected manifest generator to reject the adversarial fixture.');
  assert.match(`${result.stdout}\n${result.stderr}`, pattern);
}

test('manifest covers every executable SQL file with raw-byte SHA-256 and a companion digest', async (t) => {
  const root = await isolatedManifestRepo(t);
  const written = runGenerator(root, '--write');
  assert.equal(written.status, 0, written.stderr);

  const manifestBytes = await readFile(path.join(root, manifestRelativePath));
  const manifest = JSON.parse(manifestBytes);
  const digest = await readFile(path.join(root, digestRelativePath), 'utf8');
  const sqlItems = manifest.items.filter(({ kind }) => kind === 'executable');
  const reservations = manifest.items.filter(({ kind }) => kind === 'missing-history-reservation');

  assert.equal(manifest.schemaVersion, 1);
  assert.equal(manifest.status, 'planning_only_not_deployable');
  assert.equal(manifest.hashAlgorithm, 'sha256-raw-bytes');
  assert.equal(manifest.itemCount, 561 /* + v680-v690 CI wave: envelope, return probability, golden corpus, metric dictionary, shadow reconciliation, discovery scan, revenue truth synthetic exclusion, CI gate alignment, dispersion and one floor (nine migrations) */ /* + v672 statistical authority + v673 retention funnels + v674 demographic intelligence + v675 behaviour/service/package intelligence + v676 internal drain authority + v678 consultant spine */) // + v667 CI access boundaries + v668 complete v523 entitlement + v669 numeric honesty // + v660 owner rulings // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // + v654 receipt identity grant & tier-perk last_used_at // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (seven migrations) // + v634 reconcile-failure visibility (P0 hardening) // + v620-v626 P0 hardening wave (seven migrations) // + v611 // + v612 // + v603 // + v601 // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v598 shop hours are every teammate's default (Cubbly's Sunday) // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair (source-date collision with v568/v569/v570 on 20260828) // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 product bundles + bottle checkpoints // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v419 a suggested catalogue no longer erases spend-per-stamp // + v420 a referral may pay a free gift // // + v418 business gallery and social links (owner photo 10) // // + v417 the company bio reaches the customer // // + v416 a stamp card belongs to the setup it was started under (a mid-card customer keeps their card) //// + v414 the stamp card gets a length the owner can set (a gift added past the end could never be claimed) // // + v394 tier lifecycle at checkout + v393 customer tier visibility + v391 capabilities undefined column (its db-plan entry was missing, so the manifest could not be generated) // + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 dated programme usage // + v384 stamp conversion switch + v385 profile save // + v385 business profile save & industry_label // + the 2026-08-16/17 rewards wave (v343…v370, all applied to prod) + v371 programme-off reaches the customer + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing) // + v613 a package built for one customer only // + v627 packages and products can be limited to branches; a pending request can be amended // + v629 lifetime spend on the customer directory, + v632 mark the whole inbox read // + v641 mark-all-read delegates to the per-event writer the state guard forces // + v665 branch subscription choice (twin-name)
  assert.equal(manifest.executableCount, 547 /* + v680-v690 CI wave: envelope, return probability, golden corpus, metric dictionary, shadow reconciliation, discovery scan, revenue truth synthetic exclusion, CI gate alignment, dispersion and one floor (nine migrations) */ /* + v672 statistical authority + v673 retention funnels + v674 demographic intelligence + v675 behaviour/service/package intelligence + v676 internal drain authority + v678 consultant spine */) // + v667 CI access boundaries + v668 complete v523 entitlement + v669 numeric honesty // + v660 owner rulings // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // + v654 receipt identity grant & tier-perk last_used_at // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (seven migrations) // + v634 reconcile-failure visibility (P0 hardening) // + v620-v626 P0 hardening wave (seven migrations) // + v611 // + v612 // + v603 // + v601 // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v598 // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v394 tier lifecycle at checkout + v393 customer tier visibility + v391 capabilities undefined column (its db-plan entry was missing, so the manifest could not be generated) // + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 dated programme usage // + v384 stamp conversion switch + v385 profile save // + v385 business profile save & industry_label // + the 2026-08-16/17 rewards wave (v343…v370, all applied to prod) + v371 programme-off reaches the customer + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing) // + v613 a package built for one customer only // + v627 packages and products can be limited to branches; a pending request can be amended // + v629 lifetime spend on the customer directory, + v632 mark the whole inbox read // + v641 mark-all-read delegates to the per-event writer the state guard forces
  assert.equal(manifest.reservationCount, 14);
  assert.equal(sqlItems.length, 547 /* + v680-v690 CI wave: envelope, return probability, golden corpus, metric dictionary, shadow reconciliation, discovery scan, revenue truth synthetic exclusion, CI gate alignment, dispersion and one floor (nine migrations) */ /* + v672 statistical authority + v673 retention funnels + v674 demographic intelligence + v675 behaviour/service/package intelligence + v676 internal drain authority + v678 consultant spine */) // + v667 CI access boundaries + v668 complete v523 entitlement + v669 numeric honesty // + v660 owner rulings // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // + v654 receipt identity grant & tier-perk last_used_at // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (seven migrations) // + v634 reconcile-failure visibility (P0 hardening) // + v620-v626 P0 hardening wave (seven migrations) // + v611 // + v612 // + v603 // + v601 // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v598 // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v394 tier lifecycle at checkout + v393 customer tier visibility + v391 capabilities undefined column (its db-plan entry was missing, so the manifest could not be generated) // + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 dated programme usage // + v384 stamp conversion switch + v385 profile save // + v385 business profile save & industry_label // + the 2026-08-16/17 rewards wave (v343…v370, all applied to prod) + v371 programme-off reaches the customer + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing) // + v613 a package built for one customer only // + v627 packages and products can be limited to branches; a pending request can be amended // + v629 lifetime spend on the customer directory, + v632 mark the whole inbox read // + v641 mark-all-read delegates to the per-event writer the state guard forces
  assert.equal(reservations.length, 14);
  assert.equal(manifest.sourceCollisionsResolved, false);

  const expectedCollisionCounts = new Map([
    ['20260717', 7],
    ['20260718', 3],
    ['20260719', 5],
    ['20260720', 28],
    ['20260721', 5],
    ['20260722', 9],
    ['20260723', 9],
    ['20260724', 22],
    ['20260726', 18],
    ['20260727', 3],
    ['20260728', 8],
    ['20260729', 14],
    ['20260730', 6],
    ['20260731', 4],
    ['20260801', 9],
    ['20260802', 3],
    ['20260803', 6],
    ['20260804', 9],
    ['20260805', 6],
    ['20260806', 18],
    ['20260807', 29],
    ['20260808', 17],
    ['20260809', 9],
    ['20260810', 6], // V273 + both v267s + V268
    ['20260811', 6], // V279
    ['20260812', 15], // +v293 grants +v297-v299 prospecting CRM
    ['20260813', 9], // V300 readbacks + V306 both-mode tiers + V307 read model + V308 spine + V309 ledger tag + V310 read path + V310 google retention + V311 money kernel + V312 pot migration
    ['20260814', 12], // V313 conversion-first prospecting + its recovery snapshot + V314 business explorer + V315 lead score repair + V316 taxonomy/match queue repair + V317 restored dependencies + V318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio
    ['20260815', 11], // v326 points-gift lifecycle + v326a anon-execute revoke + v327 customer branch choice + v327 global customer QR (parallel-session number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied)
    ['20260816', 12], // the 2026-08-16 rewards wave: v343/v345/v347/v348/v350/v353/v354/v355/v359/v361/v362 + v365 tier benefit limits
    ['20260817', 14], // v367 birthday-month benefit period + v369 structured tier benefits + v370 tier discount at checkout + v371 programme-off reaches the customer + v372 gift follows its programme + v374 birthday gift saves + v375 points are not credit
    ['20260818', 5], // v384 stamp conversion switch + v385 profile save & industry_label share a file-name day
    ['20260821', 11], //  v403 ledger token + v404 manual redemption + v409 canonical balance + v410 + v412 + v414 stamp card length share a file-name day
    ['20260822', 17], // v421 two-sided referral + v422 customer reward history + the 2026-08-22 rewards go-live wave (v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers, v432 staff redeem-now matches the customer) share a file-name day
    ['20260823', 12], // v463 stamp card max (R3a) + v465 Home ready count (R1) + v464 earned reward expiry (R3e) + v462 featured offer & live cap (R2) share a file-name day
    ['20260824', 9],
    ['20260825', 15],
    ['20260826', 13], // v517 + v518 + v518a // v496, v501, v504, v505 first gift, v507 born live, v508 reschedule replaces, v510/v511 ops-os, v512 adjust follows programme // + v520 a points gift can carry its own optional expiry // + v521 redemption off is a decision, not an accident (plan item B/D completion)
    // v478-v482 loyalty release wave + v488 product bundles/bottle checkpoints
    ['20260827', 19], // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v548 insight partitions are scope-honest // + v545 programme-aware loyalty evidence // v542 pending business may ask to pay manually (this row was missing on
    ['20260828', 25], // + v590 cron history retention (2 files) + v591a-e webhook consumer markers/process-once workers/sv tender release (5 files) + v592 support tick dispatcher -- eight source-recovery mirrors of already-applied production migrations, drift closure 2026-08-29
                     // v571 retention lane inert repair (v568 the stamp survivor arm's pot predicate + v569 the staff login authority
                     // origin/main, so the test was already red before v544 was written)
                     // + v544 one canonical current loyalty balance
    ['20260829', 14],  // v611 write-time guard honours the shop-hours default (governance-after-the-fact) + v600 register v361 bring-back cron + v599 browser write boundaries + v586 tier basis + v587 join QR + v588 staff signup + v589 referral one-switch + v593 package expiry + v598 shop hours are the default
    /* nestly_v613 joins v612 on 20260830, so that day becomes a collision for the first time.
       Two files sharing a source date is the ordinary case here — the deploy versions differ
       (…010000 and …020000), which is what actually orders them. The v620-v626 P0 hardening
       wave (seven more files dated 20260830) raises the count from 2 to 9; their deploy
       versions (…020000 through …080000) keep them strictly ordered too. */
    ['20260830', 27], // + v634 reconcile-failure visibility (P0 hardening) // + v627 packages and products can be limited to branches; a pending request can be amended
    ['20260831', 19], ['20260901', 6], ['20260902', 15], // + v680-v690 CI wave (nine more files dated 20260902: envelope, return probability, golden corpus, metric dictionary, shadow reconciliation, discovery scan, revenue truth synthetic exclusion, CI gate alignment, dispersion and one floor) // + v672-v676/v678 the Customer Intelligence CI-A/CI-B wave (statistical authority, retention funnels, demographic intelligence, behaviour/service/package intelligence, internal drain authority, consultant spine) // + v665 branch subscription choice + v666 branch add prices from the tier ladder // + v664 capacity tiers charged per branch, manual-payment billing dates // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // v654 receipt identity grant & tier-perk last_used_at + v651 canonical cadence + v652 evidence contract (Phase D) + v644 can-contact authority + v645 messaging retention + v646 engagement rollups + v647 canonical taxonomy + v648 service canonical map + v649 category snapshot at sale + v650 CI read layer (Phase B/C)
  ]);
  assert.deepEqual(
    manifest.sourceDeployVersionCollisions.map(({ sourceDeployVersion, count }) => [sourceDeployVersion, count]),
    [...expectedCollisionCounts]
  );
  const reportedCollisionPaths = [];
  for (const collision of manifest.sourceDeployVersionCollisions) {
    const expectedPaths = sqlItems
      .map(({ path: migrationPath }) => migrationPath)
      .filter((migrationPath) => path.basename(migrationPath).match(/^\d+/)[0] === collision.sourceDeployVersion)
      .sort();
    assert.equal(collision.count, expectedCollisionCounts.get(collision.sourceDeployVersion));
    assert.deepEqual(collision.paths, expectedPaths, collision.sourceDeployVersion);
    assert.deepEqual(collision.paths, [...collision.paths].sort(), `${collision.sourceDeployVersion} paths must be deterministic`);
    reportedCollisionPaths.push(...collision.paths);
  }
  const expectedCollidingPaths = sqlItems
    .map(({ path: migrationPath }) => migrationPath)
    .filter((migrationPath) => expectedCollisionCounts.has(path.basename(migrationPath).match(/^\d+/)[0]))
    .sort();
  assert.deepEqual([...reportedCollisionPaths].sort(), expectedCollidingPaths);
  assert.equal(new Set(reportedCollisionPaths).size, reportedCollisionPaths.length);

  for (const item of sqlItems) {
    const bytes = await readFile(path.join(root, item.path));
    assert.match(item.sha256, /^[a-f0-9]{64}$/);
    assert.equal(item.sha256, sha256(bytes), item.path);
  }
  assert.equal(digest, `${sha256(manifestBytes)}  migration-order.manifest.json\n`);
  assert.equal(runGenerator(root, '--check').status, 0);
});

test('an additional same-prefix migration updates collision reporting deterministically', async (t) => {
  const root = await isolatedManifestRepo(t);
  const plan = await readPlan(root);
  const migrationPath = 'db/migrations/20260720_frenly_v48_extra_collision.sql';
  plan.items.push({
    kind: 'executable',
    path: migrationPath,
    semanticVersion: 'v48',
    // Far-future on purpose. This fixture only needs to sort LAST so the
    // generator's monotonic check passes; pinning it near the real plan's tail
    // meant every genuinely new migration overtook it and failed this test for
    // reasons that had nothing to do with collision reporting.
    proposedDeployVersion: '20991231000000'
  });
  await writeFile(path.join(root, migrationPath), 'select 42;\n');
  await writePlan(root, plan);

  const firstWrite = runGenerator(root, '--write');
  assert.equal(firstWrite.status, 0, firstWrite.stderr);
  const firstManifest = await readFile(path.join(root, manifestRelativePath), 'utf8');
  const manifest = JSON.parse(firstManifest);
  const collision = manifest.sourceDeployVersionCollisions
    .find(({ sourceDeployVersion }) => sourceDeployVersion === '20260720');

  assert.equal(manifest.sourceCollisionsResolved, false);
  assert.equal(collision.count, 29);
  assert.equal(collision.paths.at(-1), migrationPath);
  assert.deepEqual(collision.paths, [...collision.paths].sort());
  assert.equal(runGenerator(root, '--write').status, 0);
  assert.equal(await readFile(path.join(root, manifestRelativePath), 'utf8'), firstManifest);
  assert.equal(runGenerator(root, '--check').status, 0);
});

test('manifest generator reports duplicate proposed deploy IDs and non-monotonic order', async (t) => {
  const root = await isolatedManifestRepo(t);
  const plan = await readPlan(root);
  plan.items[1].proposedDeployVersion = plan.items[0].proposedDeployVersion;
  await writePlan(root, plan);

  assertGeneratorFailure(runGenerator(root, '--write'), /plan item 2.*(?:duplicated|strictly monotonic)/i);
});

test('manifest generator rejects unsafe traversal and resolved symlink escape paths', async (t) => {
  const traversalRoot = await isolatedManifestRepo(t);
  const traversalPlan = await readPlan(traversalRoot);
  traversalPlan.items[0].path = 'db/migrations/../outside.sql';
  await writeFile(path.join(traversalRoot, 'db/outside.sql'), 'select 1;\n');
  await writePlan(traversalRoot, traversalPlan);
  assertGeneratorFailure(runGenerator(traversalRoot, '--write'), /unsafe path/i);

  const symlinkRoot = await isolatedManifestRepo(t);
  const symlinkPlan = await readPlan(symlinkRoot);
  const firstPath = symlinkPlan.items.find(({ kind }) => kind === 'executable').path;
  const outsidePath = path.join(symlinkRoot, 'outside.sql');
  await writeFile(outsidePath, 'select 1;\n');
  await unlink(path.join(symlinkRoot, firstPath));
  await symlink(outsidePath, path.join(symlinkRoot, firstPath));
  assertGeneratorFailure(runGenerator(symlinkRoot, '--write'), /resolves outside db\/migrations/i);
});

test('manifest generator fails when the plan omits or invents executable SQL coverage', async (t) => {
  const extraRoot = await isolatedManifestRepo(t);
  await writeFile(path.join(extraRoot, 'db/migrations/20990101010101_frenly_v99_unplanned.sql'), 'select 99;\n');
  assertGeneratorFailure(runGenerator(extraRoot, '--write'), /every executable migration exactly once/i);

  const missingRoot = await isolatedManifestRepo(t);
  const missingPlan = await readPlan(missingRoot);
  const index = missingPlan.items.findIndex(({ kind }) => kind === 'executable');
  missingPlan.items.splice(index, 1);
  await writePlan(missingRoot, missingPlan);
  assertGeneratorFailure(runGenerator(missingRoot, '--write'), /every executable migration exactly once/i);
});

test('duplicate executable paths and semantic-version drift fail before a manifest is written', async (t) => {
  const duplicateRoot = await isolatedManifestRepo(t);
  const duplicatePlan = await readPlan(duplicateRoot);
  const executableIndexes = duplicatePlan.items
    .map((item, index) => item.kind === 'executable' ? index : -1)
    .filter((index) => index >= 0);
  duplicatePlan.items[executableIndexes[1]].path = duplicatePlan.items[executableIndexes[0]].path;
  await writePlan(duplicateRoot, duplicatePlan);
  assertGeneratorFailure(runGenerator(duplicateRoot, '--write'), /path is duplicated/i);

  const semanticRoot = await isolatedManifestRepo(t);
  const semanticPlan = await readPlan(semanticRoot);
  const semanticIndex = semanticPlan.items.findIndex(({ kind }) => kind === 'executable');
  semanticPlan.items[semanticIndex].semanticVersion = 'v999';
  await writePlan(semanticRoot, semanticPlan);
  assertGeneratorFailure(runGenerator(semanticRoot, '--write'), /semantic version mismatch/i);
});

test('explicit history keeps v11c reserved and orders v12a before v12 without lexical inference', async (t) => {
  const missingReservationRoot = await isolatedManifestRepo(t);
  const missingReservationPlan = await readPlan(missingReservationRoot);
  missingReservationPlan.items = missingReservationPlan.items
    .filter(({ recoveryId }) => recoveryId !== 'frenly_v11c_revoke_truncate');
  await writePlan(missingReservationRoot, missingReservationPlan);
  assertGeneratorFailure(runGenerator(missingReservationRoot, '--write'), /reserve every locally proven missing historical migration/i);

  const wrongOrderRoot = await isolatedManifestRepo(t);
  const wrongOrderPlan = await readPlan(wrongOrderRoot);
  const v12aIndex = wrongOrderPlan.items.findIndex(({ semanticVersion }) => semanticVersion === 'v12a');
  const v12Index = wrongOrderPlan.items.findIndex(({ semanticVersion }) => semanticVersion === 'v12');
  const v12aPayload = {
    path: wrongOrderPlan.items[v12aIndex].path,
    semanticVersion: wrongOrderPlan.items[v12aIndex].semanticVersion
  };
  wrongOrderPlan.items[v12aIndex].path = wrongOrderPlan.items[v12Index].path;
  wrongOrderPlan.items[v12aIndex].semanticVersion = wrongOrderPlan.items[v12Index].semanticVersion;
  wrongOrderPlan.items[v12Index].path = v12aPayload.path;
  wrongOrderPlan.items[v12Index].semanticVersion = v12aPayload.semanticVersion;
  await writePlan(wrongOrderRoot, wrongOrderPlan);
  assertGeneratorFailure(runGenerator(wrongOrderRoot, '--write'), /v12a before v12/i);
});

test('invalid deploy timestamps and unsupported plan keys fail closed', async (t) => {
  const timestampRoot = await isolatedManifestRepo(t);
  const timestampPlan = await readPlan(timestampRoot);
  timestampPlan.items[0].proposedDeployVersion = '20260722009999';
  await writePlan(timestampRoot, timestampPlan);
  assertGeneratorFailure(runGenerator(timestampRoot, '--write'), /not a valid UTC timestamp/i);

  const schemaRoot = await isolatedManifestRepo(t);
  const schemaPlan = await readPlan(schemaRoot);
  schemaPlan.items[0].ignoredByGenerator = true;
  await writePlan(schemaRoot, schemaPlan);
  assertGeneratorFailure(runGenerator(schemaRoot, '--write'), /unsupported or missing keys/i);
});

test('check detects raw SQL, manifest, and companion-digest tampering without exposing SQL contents', async (t) => {
  const sqlRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(sqlRoot, '--write').status, 0);
  const sqlPlan = await readPlan(sqlRoot);
  const migrationPath = sqlPlan.items.find(({ kind }) => kind === 'executable').path;
  const canary = 'CANARY_SQL_CONTENT_MUST_NOT_PRINT_4bca22';
  const original = await readFile(path.join(sqlRoot, migrationPath));
  await writeFile(path.join(sqlRoot, migrationPath), Buffer.concat([original, Buffer.from(`\n-- ${canary}\n`)]));
  const sqlCheck = runGenerator(sqlRoot, '--check');
  assertGeneratorFailure(sqlCheck, /migration manifest is stale or modified/i);
  assert.doesNotMatch(`${sqlCheck.stdout}\n${sqlCheck.stderr}`, new RegExp(canary));

  const manifestRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(manifestRoot, '--write').status, 0);
  const manifestPath = path.join(manifestRoot, manifestRelativePath);
  await writeFile(manifestPath, `${await readFile(manifestPath, 'utf8')} `);
  assertGeneratorFailure(runGenerator(manifestRoot, '--check'), /migration manifest is stale or modified/i);

  const digestRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(digestRoot, '--write').status, 0);
  await writeFile(path.join(digestRoot, digestRelativePath), `${'0'.repeat(64)}  migration-order.manifest.json\n`);
  assertGeneratorFailure(runGenerator(digestRoot, '--check'), /migration manifest digest is stale or modified/i);
});
