/* nestly_v894 — the WhatsApp sign-up OTP decision module, plus the two client contracts
 * that made the c42 channel unreachable.
 *
 * These EXECUTE the real functions the edge functions import. Where a rule exists to stop a
 * credential leaking (the pepper, the code, the number), the test asserts the refusal, not the
 * happy path — a boundary that only works when it is fed good input is not a boundary.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  buildOtpTemplateSend,
  classifyCreateUserFailure,
  generateOtpCode,
  normaliseSgPhone,
  otpDigestInput,
  publicStartResponse,
  publicVerifyResponse,
  templateSendable,
  validOtpCode,
} from '../../supabase/functions/_shared/whatsapp-otp-boundaries.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const readRepoFile = (relative) => readFileSync(resolve(repoRoot, relative), 'utf8');

const PEPPER = 'x'.repeat(48);
const CHALLENGE = '0f9c1e2a-3b4c-4d5e-8f90-1a2b3c4d5e6f';

test('normaliseSgPhone agrees with app.norm_phone on every documented form', () => {
  // The three accepted shapes in the SQL: local 8, 65 + 8, 065 + 8.
  assert.deepEqual(normaliseSgPhone('81863833'), { phoneNorm: '81863833', e164: '6581863833' });
  assert.deepEqual(normaliseSgPhone('+65 8186 3833'), { phoneNorm: '81863833', e164: '6581863833' });
  assert.deepEqual(normaliseSgPhone('065 8186 3833'), { phoneNorm: '81863833', e164: '6581863833' });
  assert.deepEqual(normaliseSgPhone('6531234567'), { phoneNorm: '31234567', e164: '6531234567' });
  // And the refusals: a non-SG prefix, a short number, a long one, nothing at all.
  assert.equal(normaliseSgPhone('12345678'), null);
  assert.equal(normaliseSgPhone('8186383'), null);
  assert.equal(normaliseSgPhone('+1 415 555 0100'), null);
  assert.equal(normaliseSgPhone(''), null);
  assert.equal(normaliseSgPhone(null), null);
});

test('generateOtpCode is six digits, zero-padded, and rejects biased draws', () => {
  // A draw at or above the rejection limit must be discarded, not folded in: this sequence
  // returns one rejected value then a usable one, and the code must come from the second.
  const draws = [
    new Uint8Array([0xff, 0xff, 0xff, 0xff]), // 4294967295 - above the limit, rejected
    new Uint8Array([0x00, 0x00, 0x00, 0x07]), // 7 -> '000007'
  ];
  let index = 0;
  const code = generateOtpCode(() => draws[index++]);
  assert.equal(code, '000007');
  assert.equal(index, 2, 'the biased draw must have been discarded, not used');
  assert.ok(validOtpCode(code));

  // Entropy that never yields a usable value must throw rather than return a guessable code.
  assert.throws(() => generateOtpCode(() => new Uint8Array([0xff, 0xff, 0xff, 0xff])), /entropy/);
  assert.throws(() => generateOtpCode(() => new Uint8Array([1, 2])), /entropy/);
});

test('otpDigestInput binds the code to its challenge and refuses a weak pepper', () => {
  const a = otpDigestInput(PEPPER, CHALLENGE, '123456');
  const b = otpDigestInput(PEPPER, '1f9c1e2a-3b4c-4d5e-8f90-1a2b3c4d5e6f', '123456');
  assert.notEqual(a, b, 'the same code under two challenges must not digest alike');
  assert.ok(a.includes('123456') && a.includes(PEPPER));

  assert.throws(() => otpDigestInput('short', CHALLENGE, '123456'), /pepper/);
  assert.throws(() => otpDigestInput('', CHALLENGE, '123456'), /pepper/);
  assert.throws(() => otpDigestInput(PEPPER, 'not-a-uuid', '123456'), /challenge/);
  assert.throws(() => otpDigestInput(PEPPER, CHALLENGE, '12345'), /code/);
  assert.throws(() => otpDigestInput(PEPPER, CHALLENGE, 'abcdef'), /code/);
});

test('buildOtpTemplateSend puts the code in the body AND the copy-code button', () => {
  const built = buildOtpTemplateSend({
    toE164: '6581863833', templateName: 'peekaa_signup_otp', languageCode: 'en', code: '123456',
  });
  assert.equal(built.ok, true);
  assert.equal(built.body.messaging_product, 'whatsapp');
  assert.equal(built.body.to, '6581863833');
  assert.equal(built.body.template.name, 'peekaa_signup_otp');
  const [body, button] = built.body.template.components;
  assert.deepEqual(body, { type: 'body', parameters: [{ type: 'text', text: '123456' }] });
  // Meta rejects an authentication template that carries only one of the two, and the button
  // index is a STRING in its API.
  assert.deepEqual(button, {
    type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: '123456' }],
  });
});

test('buildOtpTemplateSend refuses every malformed input by name', () => {
  const base = { toE164: '6581863833', templateName: 'peekaa_signup_otp', languageCode: 'en', code: '123456' };
  assert.deepEqual(buildOtpTemplateSend({ ...base, toE164: '81863833x' }), { ok: false, reason: 'recipient_invalid' });
  assert.deepEqual(buildOtpTemplateSend({ ...base, templateName: 'Peekaa OTP' }), { ok: false, reason: 'template_name_invalid' });
  assert.deepEqual(buildOtpTemplateSend({ ...base, languageCode: 'english' }), { ok: false, reason: 'language_code_invalid' });
  assert.deepEqual(buildOtpTemplateSend({ ...base, code: '12345' }), { ok: false, reason: 'code_invalid' });
});

test('templateSendable holds until Meta has approved an authentication template', () => {
  const approved = { status: 'approved', category: 'authentication', meta_name: 'peekaa_signup_otp', language_code: 'en' };
  assert.equal(templateSendable(approved), true);
  assert.equal(templateSendable({ ...approved, status: 'draft' }), false, 'v894 ships as draft and must not send');
  assert.equal(templateSendable({ ...approved, status: 'submitted' }), false);
  assert.equal(templateSendable({ ...approved, status: 'rejected' }), false);
  // A utility template would deliver, and would be a policy violation: Meta prices and polices
  // authentication separately, and a login code sent on a utility template is the wrong category.
  assert.equal(templateSendable({ ...approved, category: 'utility' }), false);
  assert.equal(templateSendable(null), false);
});

test('the public answers never say whether an account exists', () => {
  const started = publicStartResponse({ ok: true, challenge_id: CHALLENGE, expires_in: 300 });
  assert.equal(started.status, 200);
  assert.deepEqual(started.body, { challenge_id: CHALLENGE, expires_in: 300 });

  // feature_disabled, template_not_approved and an unnamed fault all collapse to one sentence:
  // an unauthenticated caller learns only that it did not work.
  for (const reason of ['feature_disabled', 'unavailable', 'purpose_unsupported', undefined]) {
    const answer = publicStartResponse({ ok: false, reason });
    assert.equal(answer.status, 503);
    assert.deepEqual(answer.body, { error: 'WhatsApp verification is unavailable right now.' });
  }
  assert.equal(publicStartResponse({ ok: false, reason: 'rate_limited', retry_after: 600 }).status, 429);
  assert.equal(publicStartResponse({ ok: false, reason: 'phone_invalid' }).status, 400);

  // The verify side may be specific: reaching it at all required reading a code off the phone.
  assert.deepEqual(publicVerifyResponse({ ok: true }), { status: 200, body: { verified: true } });
  assert.equal(publicVerifyResponse({ ok: false, reason: 'code_invalid', attempts_left: 3 }).body.attempts_left, 3);
  assert.equal(publicVerifyResponse({ ok: false, reason: 'too_many_attempts' }).status, 429);
  assert.equal(publicVerifyResponse({ ok: false, reason: 'challenge_invalid' }).status, 400);
  assert.equal(publicVerifyResponse({ ok: false, reason: 'account_exists' }).status, 409);
});

test('nestly_v973: a customer who already has an account is told so, not fobbed off', () => {
  /* This branch decides between "An account already exists for this number. Please sign in." and a
     generic 503. It had no executed coverage at all until v973 — it lived inline in the handler and
     was only ever matched by source text. Getting it wrong strands a returning customer.
     GoTrue has carried this fact in several shapes across releases; all of them must land. */
  assert.equal(classifyCreateUserFailure({ code: 'phone_exists' }), 'account_exists');
  assert.equal(classifyCreateUserFailure({ code: 'user_already_exists' }), 'account_exists');
  assert.equal(classifyCreateUserFailure({ code: 'PHONE_EXISTS' }), 'account_exists', 'case is theirs, not ours');
  assert.equal(classifyCreateUserFailure({ message: 'Phone number has already been registered' }), 'account_exists');
  assert.equal(classifyCreateUserFailure({ message: 'User already exists' }), 'account_exists');
  assert.equal(classifyCreateUserFailure({ message: 'A user with this phone is already registered' }), 'account_exists');
  assert.equal(classifyCreateUserFailure({ status: 422, message: 'Phone already taken' }), 'account_exists');

  // Everything else stays the safe, uninformative answer — a weak-password refusal must NOT tell
  // an unauthenticated caller that the number is on file.
  assert.equal(classifyCreateUserFailure({ code: 'weak_password', message: 'Password is too weak' }), 'unavailable');
  assert.equal(classifyCreateUserFailure({ message: 'Database error creating new user' }), 'unavailable');
  assert.equal(classifyCreateUserFailure({ status: 500 }), 'unavailable');
  assert.equal(classifyCreateUserFailure({}), 'unavailable');
  // No error at all is not a failure to classify.
  assert.equal(classifyCreateUserFailure(null), null);
  assert.equal(classifyCreateUserFailure(undefined), null);
});

test('nestly_v973: the verify handler delegates that classification', () => {
  const source = readRepoFile('supabase/functions/whatsapp-otp-verify/index.ts');
  assert.match(source, /classifyCreateUserFailure\(createError\)/,
    'the handler must route through the boundary the test above executes');
  assert.ok(!/already been registered/.test(source),
    'no second copy of the wording list may live in the handler');
});

test('the browser gate is a runtime-config key, not a window flag nobody writes', () => {
  const app = readRepoFile('app/app.js');
  // The bug this replaces: READ in two files, WRITTEN in none, so the radio could never paint.
  // The name survives in one comment, which is where a dead switch belongs; what must not
  // survive is any expression that tests it.
  assert.ok(!/__FRENLY_CUSTOMER_WHATSAPP_OTP_ENABLED__\s*(===|==|\?|\)|&&)/.test(app),
    'the unwritable window flag must not gate the WhatsApp channel any more');
  assert.match(app, /RUNTIME_CONFIG\.customerWhatsappOtpEnabled===true/);

  const loader = readRepoFile('app/runtime-config-loader.js');
  assert.match(loader, /customerWhatsappOtpEnabled/);
  assert.match(loader, /typeof raw\.customerWhatsappOtpEnabled !== 'boolean'/,
    'the key must be required, so an environment cannot leave it undefined');

  const production = JSON.parse(readRepoFile('config/runtime/production.json'));
  assert.equal(production.customerWhatsappOtpEnabled, false,
    'v894 ships the channel off; turning it on is a separate, deliberate act');
});

test('the WhatsApp sign-up code no longer travels through GoTrue, and SMS still does', () => {
  const app = readRepoFile('app/app.js');
  // The c42 path: signInWithOtp({channel:'whatsapp'}) is Twilio's WhatsApp sender, not Meta's.
  assert.ok(!app.includes("options.channel='whatsapp'"),
    'the GoTrue WhatsApp channel (delivered by Twilio) must no longer be requested');
  assert.match(app, /publicGateway\('whatsapp-otp-start'/);
  assert.match(app, /publicGateway\('whatsapp-otp-verify'/);
  // The SMS path is untouched: same signUp, same verifyOtp, same Twilio Verify behind them.
  assert.match(app, /sb\.auth\.signUp\(\{phone,password,options\}\)/);
  assert.match(app, /sb\.auth\.verifyOtp\(\{phone,token,type:'sms'\}\)/);
});

test('both edge functions are declared JWT-free, like every other public surface', () => {
  const config = readRepoFile('supabase/config.toml');
  assert.match(config, /\[functions\.whatsapp-otp-start\]\nverify_jwt = false/);
  assert.match(config, /\[functions\.whatsapp-otp-verify\]\nverify_jwt = false/);
});

test('the migration leaves the platform switches exactly as v824 left them', () => {
  const migration = readRepoFile('supabase/migrations/20261011000000_nestly_v894_whatsapp_otp_signup.sql');
  // v824's ruling stands: nothing here may re-enable API WhatsApp messaging.
  assert.ok(!/update\s+app\.platform_feature_flags/i.test(migration),
    'v894 must not write a platform feature flag; the go-live switch is a separate act');
  assert.ok(!migration.includes("'whatsapp_outbound'"),
    'the v824 master switch must not appear on this path at all');
  // The template ships unapproved, so no code can be sent before Meta has seen it.
  assert.match(migration, /'signup_otp'[\s\S]*'authentication'[\s\S]*'draft'/);
  // service_role only, the internal_* convention.
  for (const fn of ['issue', 'record_send', 'consume']) {
    assert.match(migration, new RegExp(`grant execute on function public\\.internal_whatsapp_otp_${fn}_v894[\\s\\S]{0,120}to service_role`));
  }
});
