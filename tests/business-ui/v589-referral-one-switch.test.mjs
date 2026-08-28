/* nestly_v589 — the referral programme has ONE switch, whichever door the owner uses.
 *
 * Tenant-gate D08: Jess Salon had referral_programs.enabled=true (the column the payout engine
 * reads — it was PAYING 200 points per qualified friend) while the programme spine said referral
 * was off, so every Rewards & Offer surface presented a paying programme as Off. The split came
 * from the standalone Referrals page: its Save writes through save_referral_program_v421, which
 * touched referral_programs only. v425 had already made the OTHER door (set_programmes_v314) move
 * both columns in one transaction; v589 mirrors that in this direction, server-side, so no client
 * sequencing can ever split them again. Behaviour is proven by db/tests/v589_*.sql against
 * production (6/6, including a both-ways round trip as the real owner, rolled back); this file
 * pins the migration's shape so the fix cannot fall out of the chain.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../../db/migrations/20260829_nestly_v589_referral_switch_is_one_switch.sql', import.meta.url), 'utf8');
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('the save moves the spine in its own transaction, with the set_programmes shape', () => {
  assert.match(migration, /update public\.business_programmes spine\s*\n\s*set active = p_enabled/);
  assert.match(migration, /activated_at = case when p_enabled and not spine\.active then now\(\)/);
  assert.match(migration, /referral_spine\.synced_to_program/);
  // Locked before read, like set_programmes_v314's own loop.
  assert.match(migration, /where spine\.business_id = p_business and spine\.kind = 'referral'\s*\n\s*for update;/);
});

test('switching on without a spine row refuses with the same XX001 set_programmes raises', () => {
  assert.match(migration, /has no referral programme row/);
  assert.match(migration, /errcode = 'XX001'/);
});

test('every v421/v425 guard survives verbatim', () => {
  for (const guard of [
    'acquire_loyalty_exclusive_v480',
    'only the business owner may change the referral programme',
    'referral_payout_programme_v425',
    'a referral pays points, stamps or a free gift',
    'else public.referral_programs.reward_label end',
  ]) assert.ok(migration.includes(guard), `${guard} preserved`);
});

test('the D08 repair is one-directional and audited per repaired row', () => {
  /* spine := enabled, only where enabled=true and the spine disagreed — `enabled` is both the
     owner's last expressed choice and the column that was actually paying. The audit rows come
     from the UPDATE's own RETURNING, so exactly the repaired tenants are recorded. */
  assert.match(migration, /with repaired as \(/);
  assert.match(migration, /rp\.enabled = true\s*\n\s*and spine\.active = false/);
  assert.match(migration, /referral_spine\.repaired_v589/);
  assert.doesNotMatch(migration, /set enabled = false/);
});

test('the standalone page still saves through the unified writer', () => {
  const page = app.slice(app.indexOf('async function referralsPage(){'), app.indexOf('async function membershipsPage'));
  assert.match(page, /sb\.rpc\('save_referral_program_v421'/);
  assert.match(page, /p_enabled:\$\('fe'\)\.value==='true'/);
});
