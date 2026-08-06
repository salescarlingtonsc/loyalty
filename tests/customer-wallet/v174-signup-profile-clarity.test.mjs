import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('create-account form collects name, date of birth and gender before the OTP',()=>{
  assert.match(app,/id="customerSignupFullName" autocomplete="name"/);
  assert.match(app,/id="customerSignupDob" type="date" autocomplete="bday"/);
  assert.match(app,/id="customerSignupGender" autocomplete="sex"/);
  assert.match(app,/Enter your full name\./);
  assert.match(app,/Enter a date of birth that is not in the future\./);
  assert.match(app,/rememberCustomerSignupProfile\(\{fullName:signupFullName,birthDate:signupBirthDate,gender:signupGender\}\)/);
});

test('post-OTP profile step completes itself from the signup stash',()=>{
  assert.match(app,/const signupStash=customerSignupProfileStash\(\);/);
  assert.match(app,/if\(signupStash&&customerSignupConsentRecorded\(\)\)register\.onclick\(\);/);
  assert.match(app,/sessionStorage\.removeItem\('peekaa-customer-signup-profile-v174'\)/);
});

test('a passed security check is invisible instead of red',()=>{
  assert.match(app,/const setPassed=passed=>\{/);
  assert.match(app,/onToken\(token\);retryEl\.hidden=true;setPassed\(true\)/);
  assert.doesNotMatch(app,/onToken\(token\);message\(security\('complete'\)\)/);
});
