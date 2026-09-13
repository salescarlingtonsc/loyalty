/* nestly_v885 — owner items 5 and 6.
   The Change password card in Profile → Settings could not change a password. Supabase's secure
   password change is on for this project (supabase/config.toml:84), so auth.updateUser({password})
   answered reauthentication_needed and the card dead-ended on "this reset session must be verified
   again" — with nothing on the page able to verify it. The owner's requested shape (new password →
   OTP to the mobile → verified → changed) is exactly Supabase's reauthentication flow.

   These tests EXECUTE the handler block, they do not grep it: the point of the defect was that the
   wiring never reached a working write, and only running it proves the nonce is carried. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.ok(start > -1, `missing start: ${startMarker}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end: ${endMarker}`);
  return app.slice(start, end);
}

const errorHelpers = slice(
  '/* nestly_v885: the errors of SENDING the code, which are not the errors of using it. */',
  '/* audit F040. customer_get_platform_marketing_preference'
);
const handler = slice(
  '  /* nestly_v885 (owner item 6). Two steps, one typed password.',
  "  const passkeyHost=$('customerPasskeys')"
);

/* A DOM thin enough to be honest: every node the handler addresses by id, and nothing else. */
function harness({ reauthenticate, updateUser }) {
  const nodes = new Map();
  const node = (id, extra = {}) => {
    const el = {
      id, value: '', hidden: false, disabled: false, innerHTML: '', isConnected: true,
      focus() { el.focused = true; }, ...extra
    };
    nodes.set(id, el);
    return el;
  };
  for (const id of [
    'customerPasswordOtpStepV885', 'customerPasswordOtpV885', 'customerProfilePasswordSave',
    'customerProfilePasswordStatus', 'customerProfilePassword', 'customerProfilePasswordConfirm',
    'customerPasswordOtpConfirmV885', 'customerPasswordOtpCancelV885'
  ]) node(id);
  nodes.get('customerPasswordOtpStepV885').hidden = true; // as the markup ships it

  const calls = { reauthenticate: 0, updateUser: [] };
  const scope = {
    $: id => nodes.get(id),
    esc: value => String(value),
    CUI: { announce() {} },
    validNewPassword: value => /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^\w\s]).{12,}$/.test(String(value)),
    isCurrent: () => true,
    sb: {
      auth: {
        async reauthenticate() { calls.reauthenticate += 1; return reauthenticate ?? {}; },
        async updateUser(payload) { calls.updateUser.push(payload); return updateUser ?? {}; }
      }
    }
  };
  const factory = new Function(
    '$', 'esc', 'CUI', 'validNewPassword', 'isCurrent', 'sb',
    `${errorHelpers}\n${handler}\nreturn {};`
  );
  factory(scope.$, scope.esc, scope.CUI, scope.validNewPassword, scope.isCurrent, scope.sb);
  return { nodes, calls };
}

const GOOD = 'Chuanseng!1234';

test('item 5: the card no longer claims the change sends no OTP', () => {
  assert.doesNotMatch(app, /Your password is used for normal sign-in and does not send an OTP/);
});

test('pressing Update password sends a code and writes nothing', async () => {
  const { nodes, calls } = harness({});
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  assert.equal(calls.reauthenticate, 1);
  assert.deepEqual(calls.updateUser, [], 'no password may be written before the code is verified');
  assert.equal(nodes.get('customerPasswordOtpStepV885').hidden, false);
  assert.equal(nodes.get('customerProfilePasswordSave').hidden, true);
});

test('a mismatched or weak password never reaches the network', async () => {
  for (const [password, confirmation] of [[GOOD, 'Chuanseng!5678'], ['short', 'short']]) {
    const { nodes, calls } = harness({});
    nodes.get('customerProfilePassword').value = password;
    nodes.get('customerProfilePasswordConfirm').value = confirmation;
    await nodes.get('customerProfilePasswordSave').onclick();
    assert.equal(calls.reauthenticate, 0);
    assert.match(nodes.get('customerProfilePasswordStatus').innerHTML, /class="err"/);
  }
});

test('the verified code is carried to Supabase as the nonce, with the password still typed', async () => {
  const { nodes, calls } = harness({});
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  nodes.get('customerPasswordOtpV885').value = '123 456';
  await nodes.get('customerPasswordOtpConfirmV885').onclick();
  assert.deepEqual(calls.updateUser, [{ password: GOOD, nonce: '123456' }]);
  assert.equal(nodes.get('customerProfilePassword').value, '', 'the typed password is cleared');
  assert.equal(nodes.get('customerPasswordOtpStepV885').hidden, true);
  assert.match(nodes.get('customerProfilePasswordStatus').innerHTML, /Password updated/);
});

test('a code that is not six digits is refused before the write', async () => {
  const { nodes, calls } = harness({});
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  nodes.get('customerPasswordOtpV885').value = '12345';
  await nodes.get('customerPasswordOtpConfirmV885').onclick();
  assert.deepEqual(calls.updateUser, []);
});

test('a wrong code says so, and does not send the reader back to sign in', async () => {
  const { nodes } = harness({ updateUser: { error: { code: 'reauthentication_not_valid', message: 'Nonce has expired or is invalid' } } });
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  nodes.get('customerPasswordOtpV885').value = '000000';
  await nodes.get('customerPasswordOtpConfirmV885').onclick();
  const shown = nodes.get('customerProfilePasswordStatus').innerHTML;
  assert.match(shown, /wrong or has expired/);
  assert.doesNotMatch(shown, /reset code/);
  assert.equal(nodes.get('customerPasswordOtpStepV885').hidden, false, 'the reader stays on the step they can retry');
});

test('a code that could not be sent leaves the card where it was', async () => {
  const { nodes, calls } = harness({ reauthenticate: { error: { code: 'over_sms_send_rate_limit', message: 'rate limit' } } });
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  assert.deepEqual(calls.updateUser, []);
  assert.equal(nodes.get('customerPasswordOtpStepV885').hidden, true, 'no code was sent, so there is no code step');
  assert.match(nodes.get('customerProfilePasswordStatus').innerHTML, /Too many codes requested/);
});

test('Cancel abandons the change without writing anything', async () => {
  const { nodes, calls } = harness({});
  nodes.get('customerProfilePassword').value = GOOD;
  nodes.get('customerProfilePasswordConfirm').value = GOOD;
  await nodes.get('customerProfilePasswordSave').onclick();
  nodes.get('customerPasswordOtpCancelV885').onclick();
  assert.deepEqual(calls.updateUser, []);
  assert.equal(nodes.get('customerPasswordOtpStepV885').hidden, true);
  assert.equal(nodes.get('customerProfilePasswordSave').hidden, false);
});

test('item 3: Communications returns to Settings, the page it is opened from', () => {
  assert.match(app, /backTo:'#\/customer\/settings',body/);
  assert.doesNotMatch(app, /backTo:'#\/customer\/profile'/);
});

test('item 4: the consent history is folded into the Marketing choices card', () => {
  const card = slice('<section class="card" id="customerMarketingPreference"', '<section class="card" id="customerCommunicationsEntry"');
  assert.match(card, /<details class="customer-profile-consent-v3" id="customerConsentHistory"/);
  assert.doesNotMatch(app, /<section class="card" id="customerConsentHistory"/);
});
