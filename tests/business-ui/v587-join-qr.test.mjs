/* nestly_v587 — scanning a business QR names the business and lands the customer inside it.
 *
 * The owner reported one symptom ("the qrcode scanned but failed to retrieve") and asked for one
 * flow. There were THREE independent faults behind it, each proven against their own live QR
 * (Jess Salon, status active, join_enabled true) before anything was written:
 *
 *   1. the edge gateway refused the token's SHAPE. Join tokens have been 64-hex since v197
 *      (app.v197_join_token = encode(hmac(...),'hex')); the shared validator only accepted the
 *      43-character base64url shape. GET public-join?token=… returned 404 for every QR minted
 *      since — and validJoinTokenPayload refused the signed-out counter sign-up for the same
 *      reason, which is the self-serve path the launch depends on.
 *   2. the client read the business name from a key the payload has never had (`business_name`
 *      against a payload whose key is `name`), so even a working gateway could not name it.
 *   3. the join reply carried no slug at all, so "land inside that business" was impossible
 *      rather than merely unimplemented — every successful join fell back to the programmes list.
 *
 * The DB half is proven in db/tests/v587_join_qr_names_its_business.sql against production.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const shell = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const validation = readFileSync(new URL('../../supabase/functions/_shared/validation.ts', import.meta.url), 'utf8');
const joinFn = readFileSync(new URL('../../supabase/functions/public-join/index.ts', import.meta.url), 'utf8');
const migration = readFileSync(
  new URL('../../db/migrations/20260829_nestly_v587_join_qr_names_its_business.sql', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return app.slice(from, to);
};

test('fault 1 — the gateway accepts the token shape our own database mints', () => {
  assert.match(validation, /export const JOIN_TOKEN_PATTERN = \/\^\(\?:\[A-Za-z0-9_-\]\{43\}\|\[0-9a-f\]\{64\}\)\$\//);
  // Both paths that carry a JOIN token use it: the read-only preview and the public sign-up post.
  assert.match(joinFn, /if \(!JOIN_TOKEN_PATTERN\.test\(joinToken\)\) return publicError\(req, 404\);/);
  assert.match(validation, /export function validJoinTokenPayload\(body\) \{\s*\n\s*return !!body && JOIN_TOKEN_PATTERN\.test/);
  /* TOKEN_PATTERN is NOT widened. Booking-manage tokens come from deriveManagementToken (base64url
     of an HMAC) and must keep their own exact shape — widening a shared constant to fix one caller
     is how the next token type gets silently loosened. */
  assert.match(validation, /export const TOKEN_PATTERN = \/\^\[A-Za-z0-9_-\]\{43\}\$\//);
  assert.match(validation, /export function validManagePayload\(body\) \{\s*\n\s*if \(!body \|\| !TOKEN_PATTERN\.test/);
});

test('fault 2 — the sheet reads the name from the key the server sends', () => {
  const dialog = section('async function confirmCustomerJoinV571(token,isCurrent){', 'let pendingCustomerJoinReferralV571');
  assert.match(dialog, /preview\?\.name\|\|preview\?\.business_name\|\|preview\?\.business\?\.name/);
  assert.match(dialog, /pendingCustomerJoinSlugV587=normalizeCustomerBusinessIntent\(preview\?\.slug/);
});

test('fault 3 — a join opens the business it just joined', () => {
  const join = section('async function renderCustomerQrJoin(){', 'async function renderCustomerClaim()');
  assert.match(join, /data\?\.business_slug\|\|data\?\.business\?\.slug/);
  assert.match(join, /\|\|pendingCustomerJoinSlugV587;/, 'the preview slug is the fallback');
  assert.match(join, /nav\(slug\?'#\/wallet\/'\+encodeURIComponent\(slug\):'#\/customer\/programmes'\)/);
  // And the server actually sends it now.
  assert.match(migration, /jsonb_build_object\('business_slug',v_slug,'business_name',v_name\) \|\| coalesce\(v_result,'\{\}'::jsonb\)/);
  assert.match(migration, /'slug',business\.slug/);
});

test('the sheet asks one question and offers one answer', () => {
  const dialog = section('async function confirmCustomerJoinV571(token,isCurrent){', 'let pendingCustomerJoinReferralV571');
  assert.match(dialog, /id="customerJoinGoV571"/);
  assert.match(dialog, /class="customer-join-close-v587"/);
  assert.doesNotMatch(dialog, /customerJoinReferralV571/);
  assert.doesNotMatch(dialog, /customer_check_referral_code_v571/);
  // Close, the backdrop and Esc are one decision, taken through one function.
  assert.match(dialog, /const dismiss=\(\)=>\{/);
  assert.match(dialog, /event\.key==='Escape'/);
  /* A backdrop dismiss needs the press AND the release on the backdrop, so a drag that starts
     inside the card cannot throw the sheet away. */
  assert.match(dialog, /overlay\.dataset\.pressV587!=='1'/);
});

test('the sheet is themed, and its copy ships in all four languages', () => {
  assert.match(shell, /\.customer-join-sheet-v587\{/);
  assert.match(shell, /\.customer-join-art-v587\{/);
  assert.match(shell, /@media\(prefers-reduced-motion:no-preference\)\{\s*\n\s*\.customer-join-art-v587/);
  for (const key of ['joinConfirmKickerV587', 'joinConfirmGoV587']) {
    assert.equal((app.match(new RegExp(`${key}:`, 'g')) || []).length, 4, `${key} in four locales`);
  }
});
