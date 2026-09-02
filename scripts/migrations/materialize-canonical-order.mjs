import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  copyFile, lstat, mkdir, readFile, readdir, realpath, writeFile
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');
const supabaseDir = path.join(repoRoot, 'supabase');
const migrationsDir = path.join(supabaseDir, 'migrations');
const planPath = path.join(supabaseDir, 'canonical-migration-order.plan.json');
const recoveryPath = path.join(migrationsDir, 'catalog-recovery.manifest.json');
const manifestPath = path.join(supabaseDir, 'canonical-migration-order.manifest.json');
const digestPath = `${manifestPath}.sha256`;
const projectRef = 'gadpooereceldfpfxsod';

const expectedCatalogIdentities = [
  '20260718152809_remote_schema',
  '20260718175010_enable_pg_cron',
  '20260718175336_frenly_init',
  '20260718175347_lock_down_rls_auto_enable',
  '20260718175426_frenly_v2_saas',
  '20260718175514_frenly_v3_engine',
  '20260718175527_frenly_v4_onboarding_rpc',
  '20260718175707_frenly_v5_memberships_giftcards',
  '20260718175749_frenly_v6_ops_modules',
  '20260718175847_frenly_v7_team_brand',
  '20260718175913_frenly_v8_requests_consumption',
  '20260718175936_frenly_v9_giftcard_revenue',
  '20260718180019_frenly_v10_sale_policy',
  '20260718180110_frenly_v10_1_policy_snapshot',
  '20260718180155_frenly_v11a_branches_staff_services',
  '20260718180329_frenly_v11b_money',
  '20260718180339_frenly_v11c_revoke_truncate',
  '20260718180403_frenly_v12a_completion_staff',
  '20260718180431_frenly_v12_commission_snapshot',
  '20260718180512_frenly_v14a_superadmin_roles_phone',
  '20260718180548_frenly_v14b_billing_module_perms',
  '20260718180644_frenly_v14c_customer_signup_phone_till',
  '20260718180659_frenly_v14d_harden_search_path',
  '20260718180738_frenly_v15a_booking_capacity_schema',
  '20260718180853_frenly_v15b_booking_flows_notify_cron',
  '20260718180906_frenly_v15c_convert_idempotency_guard',
  '20260718180946_frenly_v15d_booking_consent',
  '20260718181016_frenly_v17_branch_visibility',
  '20260719032517_frenly_v18_scalable_reporting',
  '20260719032658_frenly_v19_public_gateway_security',
  '20260719034201_frenly_v20_financial_engine',
  '20260719034347_frenly_v21_security_hardening',
  '20260719100654_frenly_v13_flat_commission',
  '20260719154139_frenly_v22_flat_commission_reconciliation',
  '20260719155403_frenly_v22a_app_default_privileges',
  '20260719155614_frenly_v22b_global_function_default_privileges',
  '20260719174110_frenly_v23_loyalty_points_tiers',
  '20260719174309_frenly_v23a_redeem_reward_anon_revoke',
  '20260719174612_frenly_v23b_redeem_reward_perm_fix',
  '20260719174754_frenly_v23c_redeem_reward_column_fix',
  '20260719175305_frenly_v23d_restore_loyalty_programs',
  '20260719175525_frenly_v23e_redeem_reward_ledger_routes',
  '20260719175826_frenly_v23f_restore_expiry_columns',
  '20260719185223_frenly_v23g_loyalty_model_consolidation',
  '20260719190540_frenly_v24_stamps_model'
];

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function exactKeys(value, expected, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} has unsupported or missing keys`);
}

function assertTimestamp(value, label) {
  assert.match(value, /^\d{14}$/, `${label} must be a 14-digit migration version`);
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(4, 6));
  const day = Number(value.slice(6, 8));
  const hour = Number(value.slice(8, 10));
  const minute = Number(value.slice(10, 12));
  const second = Number(value.slice(12, 14));
  const parsed = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  assert.equal(parsed.toISOString().slice(0, 19).replace(/[-:T]/g, ''), value,
    `${label} is not a valid UTC timestamp`);
}

function targetRelativePath(item) {
  return `supabase/migrations/${item.version}_${item.name}.sql`;
}

function decodeCanonicalBase64(value, label) {
  assert.match(value, /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/,
    `${label} must be canonical unwrapped base64`);
  const bytes = Buffer.from(value, 'base64');
  assert.equal(bytes.toString('base64'), value, `${label} is not a canonical base64 encoding`);
  return bytes;
}

function canonicalizeStatements(statements) {
  if (statements.length === 1) {
    return { mode: 'exact-statement-bytes', bytes: statements[0] };
  }
  return {
    mode: 'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1',
    bytes: Buffer.concat([
      ...statements.flatMap((bytes, index) => index === statements.length - 1
        ? [bytes]
        : [bytes, Buffer.from(';\n\n')]),
      Buffer.from(';\n')
    ])
  };
}

async function regularContainedFile(relativePath, allowedDir, label) {
  assert.match(relativePath, /^(?:db|supabase)\/migrations\/[A-Za-z0-9_]+\.sql$/,
    `${label} has an unsafe path`);
  const absolute = path.resolve(repoRoot, relativePath);
  assert.equal(path.dirname(absolute), allowedDir, `${label} escapes its migration directory`);
  const allowedReal = await realpath(allowedDir);
  assert.equal(path.dirname(await realpath(absolute)), allowedReal, `${label} resolves outside its migration directory`);
  assert.ok((await lstat(absolute)).isFile(), `${label} must be a regular file`);
  return absolute;
}

async function loadPlan() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  exactKeys(plan, [
    'schemaVersion', 'projectRef', 'status', 'catalogCutoffVersion',
    'requireCatalogEvidenceForAllApplied', 'items'
  ], 'canonical plan');
  assert.equal(plan.schemaVersion, 1);
  assert.equal(plan.projectRef, projectRef);
  assert.equal(plan.status, 'exact_catalog_recovered_canonical_locally_not_applied');
  assert.equal(plan.requireCatalogEvidenceForAllApplied, true,
    'every applied migration must retain catalog byte/hash evidence');
  assert.ok(Array.isArray(plan.items));
assert.equal(plan.items.length, 624, // + the CI-100 proof wave v672-v744 (sixty migrations at deploy slots 20260920000000-20260922110000; semantic twins of main's v672-v692 by filename only, parallel-session collision, not a real conflict) // + v682 a custom perk is not a free gift // + v681 free-gift confirmation at the keypad scan // + v674-v680 audit P1 wave (six migrations) // + v673 staff_insert owner-only (F132) // + v667 CI access boundaries + v668 complete v523 entitlement + v669 numeric honesty // // + v666 a gift QR scanned at the keypad opens the sale (twin-named with the branch-capacity v666, parallel-session collision, not a real conflict) // + v665 a scanned perk lands in the sale, and a wrong redemption can be taken back // + v663 confirmed bookings become Modify & Cancel, and auto-approve reaches the customer app // + v660 owner rulings // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // + v654 receipt identity grant & tier-perk last_used_at // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (can-contact authority, messaging retention, engagement rollups, canonical taxonomy, service canonical map, category snapshot at sale, CI read layer) // + v640 funnel-hit-by-slug/join-token resolvers (follow-up to v637) // + v628-v639 analytics/attribution/lifecycle governance wave (12 migrations: analytics exclusions+watermarks, first acquisition, behaviour time+direct links, appointment lifecycle events, rebooking link, tier transition history, sale items all paths, attribution associations, services delete owner-only, public funnel counters, demographics authority, appointment status backfill keys) // + v620-v626 P0 hardening wave: entitlement authority, branch payment truth, SA-writes-become-RPCs, PII read audit, billing ops visibility, platform Google-only auth, automation writers SA-only // + v611 the write-time booking guard honours the shop-hours default too (already applied to prod, governance-after-the-fact) // + v612 the join sheet's referral code pays both sides, immediately when no floor // + v603 package dates and per-package history // + v601 a package can be edited, switched off and taken off sale // + v600 register the manually-created v361 bring-back cron job in source // + v590-v592 eight source-recovery mirrors of already-applied production migrations (cron history retention, webhook consumer markers, support-tick dispatcher; drift closure 2026-08-29) // + v599 the browser roles lose the writes nothing in the product uses (SEC-01 reward_grants, notifications, resources, SEC-09 anon/internal execute) // + v598 the shop's opening hours are every teammate's default working hours (owner ruling: Cubbly's Sunday) // + v593 a package can be given a life (owner photo 5) // + v589 referral switch is one switch // + v588 staff signup flow integrity // + v587 join QR names its business // + v586 tier basis reaches the draft // + v581 short-notice/reschedule, v582 attribution wiring, v583 owner toggles + v613 a package built for one customer only (bespoke_for_client + sell_bespoke_package_v613) // + v627 packages and products can be limited to branches; a pending request can be amended
   // + v581 appointment branch address (deploy 20260828140000)
  // + v580 appointment send follows the appointment (deploy 20260828130000)
   // + v579 inbox promotion-ref backfill (existing alerts could not name or open their promotion)
  // + v577 publish preserves tier identity (P0: every programme publish raised 23503 for a tenant with a gift intent; deploy 20260828070000)
  // + v574 retention control plane (customer consent capture, platform hold, appointment transactional gate; deploy 20260828050000)
   // + v572 retention safety hardening (consent/business gate/cooldown/atomic quota; deploy 20260828020000 — twin-name with the module-toggle v572, parallel-session collision, not a real conflict)
   'canonical plan must contain 45 catalog and 517 pending migrations'); // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (seven migrations) // + v640 funnel-hit-by-slug/join-token resolvers // + v628-v639 analytics/attribution/lifecycle governance wave (12 migrations) // + v620-v626 P0 hardening wave (seven migrations) // + v611 write-time guard honours the shop-hours default (already applied to prod, governance-after-the-fact) // + v571 retention lane inert repair (fixes the vault-name lookup + makes the kill switch actually kill, master switch left OFF; no browser-callable surface) // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 the tier perk reaches the customer who earned it // + v496 the full card rolls when the customer looks, and earned gifts stack // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v477 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v477 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v462 every live offer on the business page, one featured on Home (owner ruling R2) // + v464 an earned stamp reward may be given a shelf life (owner ruling R3e) // + v465 the Home card carries a server-counted ready-reward figure (owner ruling R1) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v394 tier lifecycle at checkout + v393 customer tier visibility + v384 stamp conversion switch + v311/v312 money wave (W5a/W5b) + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v323 stamp quest milestones + v325 business bio + v326/v326a points-gift lifecycle + v327 customer branch choice + v327 global customer QR (a second, independent v327 -- parallel-session number collision, not a real conflict) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (a second, independent v329 -- parallel-session number collision, not a real conflict) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied; written for rehearsal) + the 2026-08-16 rewards wave: v343/v345/v347/v348/v350/v353/v354/v355/v359/v361/v362, all applied to prod, sharing db/tests/v343_v362_rewards_wave.sql + v365 tier benefit limits & merchant issuance + v367 birthday-month benefit period + v369 structured tier benefits + v370 tier discount at checkout + v371 programme-off reaches the customer + v372 gift follows its programme + v374 birthday gift saves + v375 points are not credit + v376 no classic redemption offer (all applied to prod 2026-08-17) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0: End/Delete refused the owner) // + v414 the stamp card gets a length the owner can set (the Stamp Card page could create gifts app.redeem_reward_core refuses) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os track; deploy 20260825000010; twin-name with the adjust v512, parallel-session collision, not a real conflict) // + v513 onboarding next actor & review (ops-os track; deploy 20260826000001; twin-name with the welcome-gift v513, parallel-session collision, not a real conflict) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v523 customer intelligence follows entitlement (owner ruling: enable through normal entitlement, finance-gated) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing) // + v544 one canonical current loyalty balance (LOYALTY_CURRENT_BALANCE_V1) // + v545 the AI evidence is programme-aware and the retention field is named for what it computes // + v548 insight partitions are scope-honest + v613 a package built for one customer only (bespoke_for_client + sell_bespoke_package_v613) // + v627 packages and products can be limited to branches; a pending request can be amended

  const seenVersions = new Set();
  const seenNames = new Set();
  let priorVersion = '';
  let pendingStarted = false;

  for (const [index, item] of plan.items.entries()) {
    const label = `canonical item ${index + 1}`;
    assertTimestamp(item.version, label);
    assert.ok(item.version > priorVersion, `${label} must be strictly ordered by unique version`);
    assert.ok(!seenVersions.has(item.version), `${label} duplicates a migration version`);
    assert.ok(!seenNames.has(item.name), `${label} duplicates a migration name`);
    assert.match(item.name, /^[a-z][a-z0-9_]*$/, `${label} has an unsafe name`);
    priorVersion = item.version;
    seenVersions.add(item.version);
    seenNames.add(item.name);

    if (item.kind === 'catalog-applied') {
      assert.ok(!pendingStarted, `${label} places an applied migration after pending work`);
      const expected = item.sourcePath
        ? ['kind', 'version', 'name', 'sourcePath']
        : ['kind', 'version', 'name', 'catalogEvidenceRequired'];
      exactKeys(item, expected, label);
      if (item.sourcePath) {
        await regularContainedFile(item.sourcePath, path.join(repoRoot, 'db/migrations'), `${label} source`);
      } else {
        assert.equal(item.catalogEvidenceRequired, true, `${label} must require catalog evidence`);
      }
    } else if (item.kind === 'pending') {
      pendingStarted = true;
      exactKeys(item, ['kind', 'version', 'name', 'sourcePath'], label);
      await regularContainedFile(item.sourcePath, path.join(repoRoot, 'db/migrations'), `${label} source`);
      assert.ok(item.version > plan.catalogCutoffVersion, `${label} must follow the catalog cutoff`);
    } else {
      assert.fail(`${label} has unsupported kind`);
    }
  }

  const applied = plan.items.filter(({ kind }) => kind === 'catalog-applied');
  const pending = plan.items.filter(({ kind }) => kind === 'pending');
  assert.equal(applied.length, 45);
assert.equal(pending.length, 579); // + the CI-100 proof wave v672-v744 (sixty pending; semantic twins of main's v672-v692 by filename only) // + v682 a custom perk is not a free gift // + v681 free-gift confirmation at the keypad scan // + v674-v680 audit P1 wave // + v673 staff_insert owner-only (F132) // + v667 CI access boundaries + v668 complete v523 entitlement + v669 numeric honesty // // + v666 a gift QR scanned at the keypad opens the sale (twin-named with the branch-capacity v666, parallel-session collision, not a real conflict) // + v666 adding a branch prices from the tier ladder // + v665 every branch charged unless switched off (twin-name with the gift-staging v665) // + v665 a scanned perk lands in the sale, and a wrong redemption can be taken back // + v664 capacity tiers charged per branch, and a manual payment that moves the billing dates // + v663 confirmed bookings become Modify & Cancel, and auto-approve reaches the customer app // + v659 edit means edit // + v656 tier discount scope + v655 cancel and package edit // + v654 receipt identity grant & tier-perk last_used_at // + v651-v652 Phase D wave (canonical cadence, evidence contract) // + v644-v650 Phase B/C wave (seven migrations) // + v640 funnel-hit-by-slug/join-token resolvers (follow-up to v637) // + v628-v639 analytics/attribution/lifecycle governance wave (analytics exclusions+watermarks, first acquisition, behaviour time+direct links, appointment lifecycle events, rebooking link, tier transition history, sale items all paths, attribution associations, services delete owner-only, public funnel counters, demographics authority, appointment status backfill keys) // + v620-v626 P0 hardening wave (entitlement authority, branch payment truth, SA-writes-become-RPCs, PII read audit, billing ops visibility, platform Google-only auth, automation writers SA-only) // + v611 the write-time booking guard honours the shop-hours default too (already applied to prod, governance-after-the-fact) // + v612 referral immediate when no floor (join-sheet referral code, both sides) // + v603 one relationship per pair (PGRST201 hotfix, applied 2026-08-29) // + v603 package dates and per-package history // + v601 pause featureless cron + v602 same-business references (both applied to prod 2026-08-29, real ledger stamps) // + v601 package edit/retire/switch // + v601 package edit/retire/switch // + v600 register v361 bring-back cron // + v590-v592 eight source-recovery mirrors (drift closure 2026-08-29) // + v599 browser write boundaries (reward_grants/notifications/resources policy+grant hardening and eleven ACL revokes) // + v598 shop hours are every teammate's default (Sunday opened but nobody was offered) // + v593 a prepaid package can expire N days after purchase (owner photo 5: "current model has no expiry") // + v589 referral switch is one switch (save_referral_program_v421 now moves the spine in its own transaction — the mirror of v425 — and the D08 divergence is repaired) // + v588 staff signup flow integrity (accept_invite replays for its own accepter and names the business; preview knows awaiting_approval; the reference code survives being looked at) // + v587 join QR names its business (the gateway refused the token shape, the preview key was wrong, and the join reply had no slug) // + v586 tier basis reaches the draft (a basis change never reached an open draft, so the next publish restored the old one) // + v581/v582/v583 // + v581 appointment branch address // + v580 // + v579 inbox promotion-ref backfill // + v577 publish preserves tier identity + the inbox returns offer_id // + v575 the waitlist records a real date and time so Book can prefill the appointment // + v574 retention control plane (deploy 20260828050000) // + v571 the customer can name who referred them, and a promotion alert keeps its promotion // + v572 retention safety hardening (deploy 20260828020000) // + v572/v573 the module toggle is enforced where the data is (v572 six tables' write paths, v573 sixteen RPC readers/writers -- the audit of every module after v570) // + v571 retention lane inert repair (deploy 20260828010856) // + v570 a module set Off is refused at the reader (dashboard revenue served to a denied teammate) // + v569 a login is active only once the owner approves it (stranded teammate, billed unusable seat) // + v568 the stamp survivor arm stays in its own pot (a parked pot's gift was offered as a stamp gift) // + v564/v565/v566 tenant-determinism wave (stale drafts refused, uniform birth, one claimable answer) // + v563 a stamps tenant can never publish without a card length (KKY: 18 stamps, unmintable reward) // + v560 the welcome offer and the birthday treat reach the customers who already exist // + v559 publishing a draft may never switch the live loyalty programme off (KKY demo root cause) // + v557 WhatsApp appointment confirmations + 24h reminders (C7 owner-approved; no cancellation notices) — note: the version tag v557 was already used by an app-only LOYALTY-009 change in 43f52bc1, twin-name, not a real conflict // + v555 business_pot fails closed (owner ruling) + v556 strict policy reads // + v551 WhatsApp bring-back sends (deploy 000011 — twin-name with the top-share v551, parallel-session collision, not a real conflict) // + v554 the live v154 family gets repo provenance // + v552 gated sections fail alone and name themselves // + v551 top shares name their denominator // + v550 the recovered-revenue report (interventions -> returns -> conservative net) // + v548 the dashboard attention list (who to bring back today; deploy 000006 — 000005 was taken by the insights v548, twin-name collision, not a real conflict) // + v539 dispatch URL vault name (outbound was never calling Meta) // + v535 reply chokepoint + v536 dispatch driver + v537 capability module gate // + v530 support inbox foundations + v531 inbound router // + v528 raw WhatsApp webhook retention (7 days) // + v522 capability grants + v522a unlimited grant // + v517 WhatsApp foundations: outbox-sweep consumer fence, two platform flags, superadmin health reader // + v508 reschedule is a fresh request (owner photo 3) // + v507 a business is born live (owner: publish = live, on = live) // + v505 the first gift can be saved before go-live (P0) // + v504 Meta WhatsApp Cloud API webhook inbox // + v501 customer read for tier benefits // + v496 full card rolls on the customer's own look + gifts stack (quantity) // + v495 stopped-programme gifts not offered // + v494 wallet signal on visits and grants // + v489 stamp card auto-rollover // + v488 product bundles + bottle checkpoints // + v482 NULL lock mode is explicitly denied // + v481 inconsistent legacy referral credit remains fail-closed // + v479 the customer hears about their stamps the way the business hears about bookings (realtime signal) // + v478 an earned stamp gift survives the card closing (owner: unused rewards disappear) // + v477 a gift can say, in the owner's own words, where it works (owner photo 3) // + v475 the stamp card stops advertising a gift the counter refuses (owner photo 2) // + v477 staff and customer read the same stamp number (owner: 15 vs 5 of 10) // + v477 erasing a customer takes the business off that customer's phone (owner batch 11) // + v472a the owner's own profile read learns the menu segment (owner batch 11) // + v472 a gift end date the Point system page can set, and a separate menu gallery (owner batch 11) // + v469 a redeemed grant sale names itself (owner photo 11) // + v468 the programme analytics count uses, not people (owner photo 4) // + v462 every live offer on the business page, one featured on Home (owner ruling R2) // + v464 an earned stamp reward may be given a shelf life (owner ruling R3e) // + v465 the Home card carries a server-counted ready-reward figure (owner ruling R1) // + v463 the longest stamp card a firm may set is 15, not 100 (owner ruling R3a) // // + v437 history rows keep their unit + the wallet expiry rule // // + the 2026-08-22 stamp lifecycle wave: v433 stamp edit version split, v434 switch publish guard, v435 stamp cycle expiry, v436 stamp earn pinned + lazy close // + v432 staff redeem-now matches the customer // + v431 publish keeps the spine model // + the 2026-08-22 rewards go-live wave: v423 reward edit reaches customers, v424 birthday window honoured, v425 referral explicit reward type, v426 canonical tier resolver, v427 entitlements reach customers // + v422 a customer can see the rewards they have already redeemed // + v421 the friend gets the referral reward too // + v420 referral free gift // + v419 recommendation keeps spend per stamp // + v418 business gallery and social links // + v417 the company bio reaches the customer // + v416 a stamp card belongs to the setup it was started under // + v414 stamp card length // + v409 canonical points balance // + v404 manual reward redemption (photo 1) // + v403 stamp conversion ledger token (photo 3: "set up stamp does not work") // + v394 tier lifecycle at checkout + v393 customer tier visibility + v386 dated programme usage (a second, independent v386 -- parallel-session number collision, not a real conflict) // + v386 customer company branches (NOT applied to prod) + v385 business profile save & industry_label // + v384 stamp conversion switch + v374 birthday gift saves + v375 points are not credit // + v371 programme-off reaches the customer + the 2026-08-16 rewards wave (v343/v345/v347/v348/v350/v353/v354/v355/v359/v361/v362) + v311/v312 money wave (W5a/W5b) + v315 lead score repair + v316 taxonomy/match queue repair + v317 restored dependencies + v318 system-managed flag alignment + v313/v314 W6 increment 1 (reward programme identity + switchboard inversion) + v322 owner programme rulings + v323 stamp quest milestones + v325 business bio + v326/v326a points-gift lifecycle + v327 customer choice + v327 global customer QR (a second, independent v327 -- parallel-session number collision, not a real conflict) + v328 staff-choice manual confirm + v329 owner reschedule booking request + v330 pending slot block & confirmation template + v329 membership plan lifecycle (a second, independent v329 -- parallel-session number collision, not a real conflict) + v331 tier lifecycle + v332 retention program lifecycle + v340 reward purchase requirement (NOT applied; written for rehearsal) // + v410 promotion finalize overload ambiguity (P0: PGRST203 blocked every promotion save) // + v412 promotion delete gated on a module key that does not exist (P0) // + v510 canonical company/CRM foundation, v511 work operating system (ops-os track) // + v512 commercial handoff integrity (ops-os track; deploy 20260825000010; twin-name with the adjust v512, parallel-session collision, not a real conflict) // + v513 onboarding next actor & review (ops-os track; deploy 20260826000001; twin-name with the welcome-gift v513, parallel-session collision, not a real conflict) // + v520 a points gift can carry its own optional expiry (owner ruling: per-gift, not programme-wide) // + v521 redemption off is a decision, not an accident (plan item B/D completion) // + v523 customer intelligence follows entitlement (owner ruling: enable through normal entitlement, finance-gated) // + v542 a pending business may ask to pay manually (billing risk exception; request only, grants nothing) // + v544 one canonical current loyalty balance (LOYALTY_CURRENT_BALANCE_V1) // + v545 the AI evidence is programme-aware and the retention field is named for what it computes // + v548 insight partitions are scope-honest + v613 a package built for one customer only (bespoke_for_client + sell_bespoke_package_v613) // + v627 packages and products can be limited to branches; a pending request can be amended
  assert.deepEqual(applied.map(({ version, name }) => `${version}_${name}`), expectedCatalogIdentities,
    'catalog versions and names must match the trusted remote inventory exactly');
  assert.equal(applied.at(-1).version, plan.catalogCutoffVersion);
  return plan;
}

async function loadRecoveryEvidence(plan) {
  let raw;
  try {
    raw = await readFile(recoveryPath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return new Map();
    throw error;
  }
  const recovery = JSON.parse(raw);
  exactKeys(recovery, ['schemaVersion', 'projectRef', 'hashAlgorithm', 'migrations'], 'catalog recovery manifest');
  assert.equal(recovery.schemaVersion, 1);
  assert.equal(recovery.projectRef, projectRef);
  assert.equal(recovery.hashAlgorithm, 'sha256-raw-bytes');
  assert.ok(Array.isArray(recovery.migrations));
  const planByVersion = new Map(plan.items
    .filter(({ kind }) => kind === 'catalog-applied')
    .map((item) => [item.version, item]));
  const evidence = new Map();
  for (const [index, item] of recovery.migrations.entries()) {
    const label = `catalog recovery item ${index + 1}`;
    exactKeys(item, [
      'version', 'name', 'statementCount', 'statements', 'canonicalization',
      'canonicalOctetLength', 'canonicalSha256', 'path'
    ], label);
    const planned = planByVersion.get(item.version);
    assert.ok(planned, `${label} is not a catalog-applied migration in the canonical plan`);
    assert.equal(item.name, planned.name, `${label} name does not match its trusted catalog version`);
    assert.ok(Number.isSafeInteger(item.statementCount) && item.statementCount >= 1,
      `${label} has an invalid statement count`);
    assert.ok(Array.isArray(item.statements), `${label} statements must be an array`);
    assert.equal(item.statements.length, item.statementCount,
      `${label} must preserve every catalog statement`);
    const statementBytes = item.statements.map((statement, statementOffset) => {
      const statementLabel = `${label} statement ${statementOffset + 1}`;
      exactKeys(statement, ['index', 'octetLength', 'sha256', 'base64'], statementLabel);
      assert.equal(statement.index, statementOffset + 1,
        `${statementLabel} index must be consecutive and one-based`);
      assert.ok(Number.isSafeInteger(statement.octetLength) && statement.octetLength >= 0,
        `${statementLabel} has an invalid octet length`);
      assert.match(statement.sha256, /^[a-f0-9]{64}$/, `${statementLabel} has an invalid SHA-256`);
      const bytes = decodeCanonicalBase64(statement.base64, `${statementLabel} base64`);
      assert.equal(bytes.byteLength, statement.octetLength,
        `${statementLabel} decoded byte length differs from catalog metadata`);
      assert.equal(sha256(bytes), statement.sha256,
        `${statementLabel} decoded SHA-256 differs from catalog metadata`);
      return bytes;
    });
    const canonical = canonicalizeStatements(statementBytes);
    assert.equal(item.canonicalization, canonical.mode,
      `${label} canonicalization does not match its statement count`);
    assert.ok(Number.isSafeInteger(item.canonicalOctetLength) && item.canonicalOctetLength >= 0,
      `${label} has an invalid canonical octet length`);
    assert.match(item.canonicalSha256, /^[a-f0-9]{64}$/,
      `${label} has an invalid canonical SHA-256`);
    assert.equal(canonical.bytes.byteLength, item.canonicalOctetLength,
      `${label} reconstructed byte length differs from canonical metadata`);
    assert.equal(sha256(canonical.bytes), item.canonicalSha256,
      `${label} reconstructed SHA-256 differs from canonical metadata`);
    assert.equal(item.path, targetRelativePath(planned), `${label} path is not canonical`);
    assert.ok(!evidence.has(item.version), `${label} duplicates catalog evidence`);
    evidence.set(item.version, { ...item, canonicalBytes: canonical.bytes });
  }
  return evidence;
}

async function materializeSourceBackedTargets(plan, evidence) {
  await mkdir(migrationsDir, { recursive: true });
  for (const item of plan.items) {
    const target = path.resolve(repoRoot, targetRelativePath(item));
    const recovered = evidence.get(item.version);
    if (recovered) {
      await writeFile(target, recovered.canonicalBytes);
      continue;
    }
    assert.notEqual(item.kind, 'catalog-applied',
      `required catalog evidence is missing for ${item.version}`);
    assert.ok(item.sourcePath, `${targetRelativePath(item)} has no catalog evidence or local source`);
    await copyFile(path.resolve(repoRoot, item.sourcePath), target);
  }
}

async function buildManifest(plan, evidence) {
  const missingTargets = [];
  const missingEvidence = [];
  const entries = [];

  for (const [index, item] of plan.items.entries()) {
    const relativePath = targetRelativePath(item);
    const target = path.resolve(repoRoot, relativePath);
    let bytes;
    try {
      bytes = await readFile(target);
      await regularContainedFile(relativePath, migrationsDir, `canonical target ${index + 1}`);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      missingTargets.push(relativePath);
      continue;
    }

    const recovered = evidence.get(item.version);
    if (item.kind === 'catalog-applied' && !recovered) missingEvidence.push(item.version);
    if (recovered) {
      assert.equal(bytes.byteLength, recovered.canonicalOctetLength,
        `${relativePath} byte length differs from catalog canonical evidence`);
      assert.equal(sha256(bytes), recovered.canonicalSha256,
        `${relativePath} SHA-256 differs from catalog canonical evidence`);
      assert.deepEqual(bytes, recovered.canonicalBytes,
        `${relativePath} bytes differ from deterministic catalog reconstruction`);
    }
    if (item.kind === 'pending') {
      assert.deepEqual(bytes, await readFile(path.resolve(repoRoot, item.sourcePath)),
        `${relativePath} differs from its pending source migration`);
    }

    entries.push({
      order: index + 1,
      kind: item.kind,
      version: item.version,
      name: item.name,
      path: relativePath,
      octetLength: bytes.byteLength,
      sha256: sha256(bytes),
      provenance: recovered ? 'catalog-statements' : 'local-source'
    });
  }

  assert.deepEqual(missingTargets, [], `canonical SQL targets are missing: ${missingTargets.join(', ')}`);
  assert.deepEqual(missingEvidence, [],
    `required catalog evidence is missing for versions: ${missingEvidence.join(', ')}`);

  return {
    schemaVersion: 1,
    status: 'canonical_deployable_locally_not_applied',
    projectRef,
    sourcePlan: 'supabase/canonical-migration-order.plan.json',
    catalogRecoveryManifest: 'supabase/migrations/catalog-recovery.manifest.json',
    hashAlgorithm: 'sha256-raw-bytes',
    catalogAppliedCount: 45,
    pendingCount: plan.items.filter(({ kind }) => kind === 'pending').length,
    itemCount: entries.length,
    items: entries
  };
}

async function assertOnlyPlannedSql(plan) {
  const actual = (await readdir(migrationsDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .map(({ name }) => `supabase/migrations/${name}`)
    .sort();
  const expected = plan.items.map(targetRelativePath).sort();
  assert.deepEqual(actual, expected, 'supabase/migrations must contain exactly the canonical SQL chain');
}

async function main() {
  const option = process.argv[2] || '--check-plan';
  assert.ok(['--check-plan', '--materialize', '--check'].includes(option),
    'Usage: node scripts/migrations/materialize-canonical-order.mjs [--check-plan|--materialize|--check]');
  assert.equal(process.argv.length, process.argv[2] ? 3 : 2, 'Unexpected arguments');
  const plan = await loadPlan();
  if (option === '--check-plan') return;

  const evidence = await loadRecoveryEvidence(plan);
  if (option === '--materialize') await materializeSourceBackedTargets(plan, evidence);
  const manifest = await buildManifest(plan, evidence);
  await assertOnlyPlannedSql(plan);
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  const digest = `${sha256(bytes)}  canonical-migration-order.manifest.json\n`;

  if (option === '--materialize') {
    await writeFile(manifestPath, bytes);
    await writeFile(digestPath, digest, 'utf8');
    return;
  }
  assert.deepEqual(await readFile(manifestPath), bytes, 'canonical migration manifest is stale or modified');
  assert.equal(await readFile(digestPath, 'utf8'), digest,
    'canonical migration manifest digest is stale or modified');
}

await main();
