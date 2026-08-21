/* nestly_v419 + nestly_v420 — the owner's follow-ups, after a pass that answered two of them
   without building anything. Their words: "have you tested? - fail to fix it". Fair.

   PHOTO 1 — a BIRTHDAY reward saved with "active stamps configuration requires spend per stamp",
   and the owner's objection is right: "birthday requires stamps? They are independent."
   PHOTO 4 — "referral why only points option? can also be free gift."   */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const v419 = readFileSync(join(root, 'db', 'migrations',
  '20260821_nestly_v419_recommendation_keeps_spend_per_stamp.sql'), 'utf8');
const v420 = readFileSync(join(root, 'db', 'migrations',
  '20260821_nestly_v420_referral_free_gift.sql'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};

/* ------------------------------------------- photo 1 ---------------------------------------- */

test('v419 a suggested catalogue no longer sends a null that means "erase"', () => {
  /* save_loyalty_config_draft decides this field by KEY PRESENCE:
       stamp_per_cents = case when p_config ? 'stamp_per_cents' then (...) else <keep> end
     so sending null is not "leave it alone", it is "wipe it". */
  assert.doesNotMatch(v419, /'stamp_per_cents',case when v_model='stamps' then v_stamp_cents else null end/,
    'the branch that always sent null on a points recommendation');
  assert.match(v419, /\|\| case when v_model='stamps' then jsonb_build_object\('stamp_per_cents',v_stamp_cents\)/,
    'the key is merged in only when it is actually being set');
});

test('v419 repairs the drafts already holding a null, and only those', () => {
  assert.match(v419, /and fcv\.status = 'draft'/, 'draft versions only — published ones are immutable');
  assert.match(v419, /and lpv\.stamp_per_cents is null/, 'never overwrite a value the firm typed itself');
  assert.match(v419, /and coalesce\(lp\.stamp_per_cents,0\) > 0/, 'restore only what the live row can supply');
  /* And the guard is lifted for exactly that one statement, then put back inside the same
     transaction — ALTER TABLE holds ACCESS EXCLUSIVE, so there is no window a user could use. */
  assert.match(v419, /disable trigger trg_c45_loyalty_program_version_write_guard/);
  assert.match(v419, /enable trigger trg_c45_loyalty_program_version_write_guard/);
  assert.ok(v419.indexOf('disable trigger') < v419.indexOf('enable trigger'));
});

test('v419 does NOT relax the publish guard it was reported through', () => {
  /* "A live stamp card needs a spend per stamp" is true. The writer that erased the value is the
     defect, not the check that noticed. */
  /* The migration QUOTES the message in its header to record what the owner saw — that is
     history, not a change. What must not appear is a rewrite of the function that raises it. */
  assert.doesNotMatch(v419, /create or replace function public\.publish_loyalty_config/i);
  assert.doesNotMatch(v419, /drop constraint[^;]*stamp/i);
});

/* ------------------------------------------- photo 4 ---------------------------------------- */

test('v420 a voucher referral finally pays something', () => {
  /* reward_kind has allowed 'voucher' since the column existed; app.on_sale_recorded had no
     branch for it, so a firm set to 'voucher' was paid NOTHING. */
  assert.match(v420, /if refprog\.reward_kind='voucher' then/);
  assert.match(v420, /insert into public\.referral_grants_v420\(business_id,client_id,referral_id,reward_label\)/);
  assert.match(v420, /on conflict \(referral_id\) do nothing/, 'the trigger must be replay-safe');
  assert.match(v420, /constraint referral_grants_v420_once unique \(referral_id\)/,
    'one introduction owes exactly one gift');
  /* The points path is untouched: it is still the elsif. */
  assert.match(v420, /elsif v_ref_prog is not null and v_ref_points>0 then/);
});

test('v420 the gift is handed over as a real visit worth nothing', () => {
  const redeem = v420.slice(v420.indexOf('create or replace function public.staff_redeem_referral_v420'));
  assert.match(redeem, /amount_cents.*0|,0,/, 'a $0 sale');
  assert.match(redeem, /referral_already_redeemed/, 'and only once');
  assert.match(redeem, /app\.can_see_branch/, 'at a branch this staff member may see');
  assert.doesNotMatch(redeem.slice(0, redeem.indexOf('end $$')), /points_ledger|credit_ledger/,
    'no ledger write — a gift is not money');
});

test('v420 adds a NEW saver rather than overloading the old one', () => {
  assert.match(v420, /create or replace function public\.save_referral_program_v420\(/);
  assert.doesNotMatch(v420, /create or replace function public\.save_referral_program_v322\(/,
    'adding parameters to v322 would create an overload twin — see nestly_v410');
  /* Each kind validates only what it needs, and switching preserves the other kind's value. */
  assert.match(v420, /a points referral must award at least one point/);
  assert.match(v420, /name the gift the referrer receives/);
  assert.match(v420, /reward_points = case when excluded\.reward_kind='points'/);
  assert.match(v420, /reward_label = case when excluded\.reward_kind='voucher'/);
});

test('v420 the owner can choose, and the counter can hand it over', () => {
  const form = statement('<p class="grow-setup-sentence-v301" style="margin-top:10px"><span class="muted small">What the referrer gets</span></p>', '</p>`');
  assert.match(form, /name="growReferralKindV420"/);
  assert.match(form, /A free gift/);
  assert.match(form, /growReferralGiftV420/);
  /* The two inputs swap rather than both showing. */
  assert.match(form, /id="growReferralPointsWrapV420"[^>]*\$\{growReferralKindV420==='voucher'\?' hidden':''\}/);
  assert.match(form, /id="growReferralGiftWrapV420"[^>]*\$\{growReferralKindV420==='voucher'\?'':' hidden'\}/);
  /* The save calls v420's RPC, not v322's. */
  const save = statement("if(growReferralSaveV364)growReferralSaveV364.onclick=async()=>{", '\n  };');
  assert.match(save, /save_referral_program_v420/);
  assert.doesNotMatch(save, /save_referral_program_v322/);
  /* And the till has a banner and a redeem for it — without this the gift is unclaimable. */
  assert.match(appJs, /id="tReferralRedeemV420"/);
  assert.match(appJs, /staff_redeem_referral_v420/);
  assert.match(appJs, /customerReferralOffer:entitlements\.error\?null:\(entitlements\.data\?\.referral_offer\|\|null\)/);
});

test('v420 the till payload and the reads carry the new fields', () => {
  assert.match(v420, /'referral_offer',v_referral/);
  assert.match(appJs, /select\('id,enabled,reward_points,reward_kind,reward_label,min_spend_cents,created_at'\)/);
  /* The programme row names whichever payout it actually is. */
  assert.match(appJs, /snapshot\.referral\.reward_kind==='voucher'/);
});

test('v420 leaves the friend unpaid, and says so rather than pretending otherwise', () => {
  /* The owner asked "will both the user receive the benefits?". Only the referrer is paid — one
     insert, for refrow.referrer_client_id. Making it two-sided is a cost decision for the firm,
     not a defect, and is raised with them separately. This pins the current answer so a future
     change to it is deliberate. */
  assert.match(v420, /the REFERRER is paid\. app\.on_sale_recorded inserts one points row/);
  assert.match(v420, /Nothing anywhere pays the friend/);
  const branch = v420.slice(v420.indexOf("if refprog.reward_kind='voucher' then"));
  const upTo = branch.slice(0, branch.indexOf('elsif'));
  assert.match(upTo, /refrow\.referrer_client_id/);
  assert.doesNotMatch(upTo, /new\.client_id\s*,\s*refprog\.reward_label/, 'nothing is granted to the friend');
});
