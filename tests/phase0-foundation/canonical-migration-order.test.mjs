import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  mkdir, mkdtemp, readFile, rm, writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planRelativePath = 'supabase/canonical-migration-order.plan.json';
const scriptRelativePath = 'scripts/migrations/materialize-canonical-order.mjs';
const recoveryRelativePath = 'supabase/migrations/catalog-recovery.manifest.json';
const manifestRelativePath = 'supabase/canonical-migration-order.manifest.json';
const digestRelativePath = `${manifestRelativePath}.sha256`;
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function run(root, option) {
  return spawnSync(process.execPath, [scriptRelativePath, option], {
    cwd: root,
    encoding: 'utf8'
  });
}

function assertFailure(result, pattern) {
  assert.notEqual(result.status, 0, 'expected canonical materializer to fail closed');
  assert.match(`${result.stdout}\n${result.stderr}`, pattern);
}

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'frenly-canonical-order-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await Promise.all([
    mkdir(path.join(root, 'scripts/migrations'), { recursive: true }),
    mkdir(path.join(root, 'supabase/migrations'), { recursive: true }),
    mkdir(path.join(root, 'db/migrations'), { recursive: true })
  ]);
  const planBytes = await readFile(path.join(repoRoot, planRelativePath));
  const plan = JSON.parse(planBytes);
  await Promise.all([
    writeFile(path.join(root, planRelativePath), planBytes),
    writeFile(path.join(root, scriptRelativePath), await readFile(path.join(repoRoot, scriptRelativePath)))
  ]);
  for (const item of plan.items.filter(({ sourcePath }) => sourcePath)) {
    const sourceBytes = await readFile(path.join(repoRoot, item.sourcePath));
    await writeFile(path.join(root, item.sourcePath), sourceBytes);
  }
  return { root, plan };
}

async function addRecoveryEvidence(root, plan) {
  const migrations = [];
  for (const item of plan.items.filter(({ kind }) => kind === 'catalog-applied')) {
    const pathName = `supabase/migrations/${item.version}_${item.name}.sql`;
    const statementBytes = Array.from(
      { length: item.name === 'remote_schema' ? 3 : 1 },
      (_, index) => Buffer.from(`-- exact catalog fixture ${index + 1}: ${item.name}\nselect '${item.version}-${index + 1}'`)
    );
    const canonicalization = statementBytes.length === 1
      ? 'exact-statement-bytes'
      : 'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1';
    const canonicalBytes = statementBytes.length === 1
      ? statementBytes[0]
      : Buffer.concat([
        ...statementBytes.flatMap((bytes, index) => index === statementBytes.length - 1
          ? [bytes]
          : [bytes, Buffer.from(';\n\n')]),
        Buffer.from(';\n')
      ]);
    await writeFile(path.join(root, pathName), canonicalBytes);
    migrations.push({
      version: item.version,
      name: item.name,
      statementCount: statementBytes.length,
      statements: statementBytes.map((bytes, index) => ({
        index: index + 1,
        octetLength: bytes.byteLength,
        sha256: sha256(bytes),
        base64: bytes.toString('base64')
      })),
      canonicalization,
      canonicalOctetLength: canonicalBytes.byteLength,
      canonicalSha256: sha256(canonicalBytes),
      path: pathName
    });
  }
  await writeFile(path.join(root, recoveryRelativePath), `${JSON.stringify({
    schemaVersion: 1,
    projectRef: 'gadpooereceldfpfxsod',
    hashAlgorithm: 'sha256-raw-bytes',
    migrations
  }, null, 2)}\n`);
}

test('checked-in canonical plan preserves 45 trusted catalog versions then 234237', () => {
  const result = run(repoRoot, '--check-plan');
  assert.equal(result.status, 0, result.stderr);
});

test('materializer creates one byte-preserving 448451 and deterministic manifests', async (t) => {
  const { root, plan } = await fixture(t);
  await addRecoveryEvidence(root, plan);
  const materialized = run(root, '--materialize');
  assert.equal(materialized.status, 0, materialized.stderr);

  const manifestBytes = await readFile(path.join(root, manifestRelativePath));
  const manifest = JSON.parse(manifestBytes);
  assert.equal(manifest.status, 'canonical_deployable_locally_not_applied');
  assert.equal(manifest.catalogAppliedCount, 45);
  assert.equal(manifest.pendingCount, 447) // + v601 package edit/retire/switch // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair (deploy 20260828010856) // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 product bundles + bottle checkpoints // + v482 NULL lock mode is explicitly denied // + v479 thecustomer hears about their stamps the way the business hears about bookings (realtime signal) // + v479 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v462 every live offer on the business page, one featured on Home (owner ruling R2) // + v464 an earned stamp reward may be given a shelf life (owner ruling R3e) // + v465 the Home card carries a server-counted ready-reward figure (owner ruling R1) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 publish keeps the spine model // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v419 a suggested catalogue no longer erases spend-per-stamp // + v420 a referral may pay a free gift // // + v418 business gallery and social links (owner photo 10) // // + v417 the company bio reaches the customer // // + v416 a stamp card belongs to the setup it was started under (a mid-card customer keeps their card) //// + v414 the stamp card gets a length the owner can set (a gift added past the end could never be claimed) // // + v394 tier lifecycle at checkout + v393 customer tier visibility + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 customer company branches (NOT applied to prod) + v385 business profile save & industry_label // + v384 stamp conversion switch + v371 programme-off reaches the customer + v365 tier benefit limits & merchant issuance (applied to prod 2026-08-17) // + the 2026-08-16 rewards wave (v343/v345/v347/v348/v350/v353/v354/v355/v359/v361/v362), all applied to prod // + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing)
  assert.equal(manifest.itemCount, 492) // + v601 // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair (deploy 20260828010856) // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v479 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v462 every live offer on the business page, one featured on Home (owner ruling R2) // + v464 an earned stamp reward may be given a shelf life (owner ruling R3e) // + v465 the Home card carries a server-counted ready-reward figure (owner ruling R1) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 // + the 2026-08-22 rewards go-live wave (v423, v424, v425, v426, v427) // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v419 a suggested catalogue no longer erases spend-per-stamp // + v420 a referral may pay a free gift // // + v418 business gallery and social links (owner photo 10) // // + v417 the company bio reaches the customer // // + v416 a stamp card belongs to the setup it was started under (a mid-card customer keeps their card) //// + v414 the stamp card gets a length the owner can set (a gift added past the end could never be claimed) // // + v394 tier lifecycle at checkout + v393 customer tier visibility + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 customer company branches + v385 business profile save & industry_label // + v384 stamp conversion switch + v365 tier benefit limits & merchant issuance (NOT applied) // + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing)
  assert.equal(new Set(manifest.items.map(({ version }) => version)).size, 492) // + v601 // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries // + v593 a prepaid package can be given a life (owner photo 5: expiry N days after purchase) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 appointment branch address // // + v579 inbox promotion-ref backfill // // + v577 publish preserves tier identity (P0) // // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers) // + v571 retention lane inert repair (deploy 20260828010856) // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v548 insight partitions are scope-honest // + v545 the AI evidence pack is programme-aware (no cross-unit total) and the retention field is named for what it computes // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v523 customer intelligence follows entitlement // + v518 capability grants + v518a unlimited grant // + v517 WhatsApp foundations (outbox-sweep consumer fence, platform flags, superadmin health reader); // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 // + v496 // + v495 // + v494 // + v489 // + v488 // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v479 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v474 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v473 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v462 every live offer on the business page, one featured on Home (owner ruling R2) // + v464 an earned stamp reward may be given a shelf life (owner ruling R3e) // + v465 the Home card carries a server-counted ready-reward figure (owner ruling R1) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 // + the 2026-08-22 rewards go-live wave (v423, v424, v425, v426, v427) // + v422 a customer can see the rewards they have already redeemed (owner photo 6: History tab) // + v421 the friend gets the referral reward too // + v419 a suggested catalogue no longer erases spend-per-stamp // + v420 a referral may pay a free gift // // + v418 business gallery and social links (owner photo 10) // // + v417 the company bio reaches the customer // // + v416 a stamp card belongs to the setup it was started under (a mid-card customer keeps their card) //// + v414 the stamp card gets a length the owner can set (a gift added past the end could never be claimed) // // + v394 tier lifecycle at checkout + v393 customer tier visibility + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 + v385 // + v384 stamp conversion switch + v365 // + v311 money kernel + v312 pot migration + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (parallel-session v327 number collision) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (parallel-session v329 number collision) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os; twin-name collision with the adjust v512) // + v513 onboarding next actor & review (ops-os; twin-name collision with the welcome-gift v513) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing)
  assert.equal(manifest.items[44].version, '20260719190540');
  assert.equal(manifest.items[45].version, '20260721000001');
  assert.equal(
    manifest.items.at(-1).name,
    'nestly_v601_package_edit_retire_and_switch' // tail — a package can be edited, switched off and taken off sale
    // v599 (real ledger 20260829094129) and v600 (real ledger 20260829095932) were applied via MCP,
    // which stamps with actual UTC apply time; both therefore sort BEFORE the afternoon-authored
    // v586-v598 stamps and sit at their real chronological slots earlier in this list.
  );
  const recovery = JSON.parse(await readFile(path.join(root, recoveryRelativePath), 'utf8'));
  assert.equal(recovery.migrations[0].statementCount, 3);
  assert.equal(recovery.migrations[0].statements.length, 3);
  assert.equal(
    recovery.migrations[0].canonicalization,
    'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1'
  );

  for (const item of manifest.items) {
    const bytes = await readFile(path.join(root, item.path));
    assert.equal(item.octetLength, bytes.byteLength);
    assert.equal(item.sha256, sha256(bytes));
  }
  for (const item of plan.items.filter(({ kind }) => kind === 'pending')) {
    assert.deepEqual(
      await readFile(path.join(root, `supabase/migrations/${item.version}_${item.name}.sql`)),
      await readFile(path.join(root, item.sourcePath))
    );
  }
  assert.equal(
    await readFile(path.join(root, digestRelativePath), 'utf8'),
    `${sha256(manifestBytes)}  canonical-migration-order.manifest.json\n`
  );
  assert.equal(run(root, '--check').status, 0);
});

test('catalog byte tampering and missing catalog evidence are hard failures', async (t) => {
  const tamper = await fixture(t);
  await addRecoveryEvidence(tamper.root, tamper.plan);
  assert.equal(run(tamper.root, '--materialize').status, 0);
  const recovered = tamper.plan.items.find(({ kind }) => kind === 'catalog-applied');
  await writeFile(
    path.join(tamper.root, `supabase/migrations/${recovered.version}_${recovered.name}.sql`),
    '-- tampered\n'
  );
  assertFailure(run(tamper.root, '--check'), /(?:byte length|SHA-256) differs from catalog canonical evidence/i);

  const missing = await fixture(t);
  await addRecoveryEvidence(missing.root, missing.plan);
  const recovery = JSON.parse(await readFile(path.join(missing.root, recoveryRelativePath), 'utf8'));
  recovery.migrations.shift();
  await writeFile(path.join(missing.root, recoveryRelativePath), `${JSON.stringify(recovery, null, 2)}\n`);
  assertFailure(run(missing.root, '--materialize'), /required catalog evidence is missing/i);

  const invalidBase64 = await fixture(t);
  await addRecoveryEvidence(invalidBase64.root, invalidBase64.plan);
  const invalidRecovery = JSON.parse(
    await readFile(path.join(invalidBase64.root, recoveryRelativePath), 'utf8')
  );
  invalidRecovery.migrations[0].statements[0].base64 += '\n';
  await writeFile(
    path.join(invalidBase64.root, recoveryRelativePath),
    `${JSON.stringify(invalidRecovery, null, 2)}\n`
  );
  assertFailure(run(invalidBase64.root, '--materialize'), /canonical unwrapped base64/i);
});

test('plan drift, unexpected SQL, and pending target divergence fail closed', async (t) => {
  const duplicate = await fixture(t);
  const duplicatePlan = structuredClone(duplicate.plan);
  duplicatePlan.items[1].version = duplicatePlan.items[0].version;
  await writeFile(
    path.join(duplicate.root, planRelativePath),
    `${JSON.stringify(duplicatePlan, null, 2)}\n`
  );
  assertFailure(run(duplicate.root, '--check-plan'), /strictly ordered|duplicates a migration version/i);

  const renamed = await fixture(t);
  const renamedPlan = structuredClone(renamed.plan);
  renamedPlan.items[0].name = 'plausible_but_untrusted_catalog_name';
  await writeFile(
    path.join(renamed.root, planRelativePath),
    `${JSON.stringify(renamedPlan, null, 2)}\n`
  );
  assertFailure(run(renamed.root, '--check-plan'), /trusted remote inventory exactly/i);

  const extra = await fixture(t);
  await addRecoveryEvidence(extra.root, extra.plan);
  assert.equal(run(extra.root, '--materialize').status, 0);
  await writeFile(path.join(extra.root, 'supabase/migrations/20990101000000_unplanned.sql'), 'select 1;\n');
  assertFailure(run(extra.root, '--check'), /exactly the canonical SQL chain/i);

  const divergent = await fixture(t);
  await addRecoveryEvidence(divergent.root, divergent.plan);
  assert.equal(run(divergent.root, '--materialize').status, 0);
  const pending = divergent.plan.items.find(({ kind }) => kind === 'pending');
  await writeFile(
    path.join(divergent.root, `supabase/migrations/${pending.version}_${pending.name}.sql`),
    '-- divergent pending bytes\n'
  );
  assertFailure(run(divergent.root, '--check'), /differs from its pending source migration/i);
});
