import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

test('create-account form collects name, date of birth and gender before the OTP',()=>{
  assert.match(app,/id="customerSignupFullName" autocomplete="name"/);
  /* nestly_v663 (owner photo A: "not able to change year ... make it the latest iphone way").
     Day / month / year selects writing one hidden value under the same id the form has always
     read, so every validation and stash downstream is untouched. */
  assert.match(app,/\$\{birthDatePickerHtmlV663\('customerSignupDob',customerSignupProfileStash\(\)\?\.birthDate\|\|''\)\}/);
  assert.match(app,/<input type="hidden" id="\$\{esc\(id\)\}" autocomplete="bday"/);
  assert.match(app,/id="customerSignupGender" autocomplete="sex" required aria-required="true"/);
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

test('the retry link honours hidden and the passed challenge collapses', () => {
  assert.match(app,/\.challenge-retry\[hidden\]\{display:none\}/);
  assert.match(app,/\.challenge\.challenge-passed\{min-height:0/);
  assert.match(app,/classList\.toggle\('challenge-passed',passed\)/);
});

test('v175: legal acceptance and marketing consent are separate signup records', () => {
  assert.match(app,/id="customerSignupConsent" type="checkbox" \$\{customerRegistrationState\.legalAccepted\?'checked':''\}/);
  assert.match(app,/id="customerSignupMarketing" type="checkbox" \$\{customerRegistrationState\.marketingOptedIn\?'checked':''\}/);
  // V265 (owner ruling B, 2026-08-09): partners DO now receive customer contact details,
  // so the v175 "partners never receive my contact details" promise is retired. The current
  // wording is pinned by tests/customer-modules/v264-marketing-consent-scope.test.mjs.
  /* nestly_v663 (owner photo A: "hyperlink the offers & updates and remove the words below").
     The phrase is now the control that opens the consent wording; the wording itself survives
     verbatim behind it, because it is what the tick agrees to. */
  assert.match(app,/Yes — send me <button type="button" id="customerSignupMarketingWhat"[^>]*>offers and updates<\/button>\.<\/b>/);
  assert.match(app,/id="customerSignupMarketingCopy" hidden>Nestly Technologies Pte\. Ltd\./);
  assert.doesNotMatch(app,/Click to read what/);
  assert.doesNotMatch(app,/partners never receive my contact details/i);
  assert.match(app,/\(Optional\)/);
  assert.match(app,/The marketing box is optional\./);
  assert.match(app,/p_platform_marketing_opted_in:customerSignupMarketingOptedIn\(\)/);
  assert.doesNotMatch(app,/p_platform_marketing_opted_in:true/);
  assert.match(app,/marketingOptedIn:recovering\?false:\$\('customerSignupMarketing'\)\.checked/);
  assert.match(app,/function customerSignupMarketingOptedIn\(\)/);
  assert.match(app,/startsWith\('accepted'\)/);
});
