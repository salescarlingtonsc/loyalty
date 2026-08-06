import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

const read=path=>readFileSync(new URL(path,import.meta.url),'utf8');
const app=read('../../app/index.html')+'\n'+read('../../app/app.js');
const terms=read('../../app/terms.html');
const privacy=read('../../app/privacy.html');
const migrationUrl=new URL(
  '../../supabase/migrations/20260803120000_nestly_v144_self_serve_subscription_consent.sql',
  import.meta.url
);
const migration=existsSync(migrationUrl)?readFileSync(migrationUrl,'utf8'):'';

function section(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return source.slice(from,to);
}

test('owner signup uses accurate consent copy and independently usable legal links',()=>{
  const signup=section(app,'function renderBusinessApplication(){','async function renderApprovedBusinessInviteSignup(');
  assert.match(signup,/I agree to the Terms of Service and acknowledge the Privacy Policy/);
  assert.doesNotMatch(signup,/I have read and agree/);
  assert.match(signup,/class="consent-document-link"[^>]+href="\/terms\.html\?return=business-signup"[^>]+target="_blank"/);
  assert.match(signup,/class="consent-document-link"[^>]+href="\/privacy\.html\?return=business-signup"[^>]+target="_blank"/);
  assert.match(app,/\.consent-document-link\{[^}]*text-decoration:underline[^}]*font-weight:700/);
  assert.match(signup,/applicationConsent/);
  assert.match(signup,/Please agree to the Terms of Service and acknowledge the Privacy Policy/);
});

test('legal pages provide an obvious return to owner account creation',()=>{
  for(const [name,page] of [['Terms',terms],['Privacy',privacy]]){
    assert.match(page,/class="return-to-signup" href="\/business\?signup=1"/,
      `${name} must provide the signup return`);
    assert.match(page,/Back to owner account creation/);
  }
  assert.match(app,/new URLSearchParams\(location\.search\)\.get\('signup'\)==='1'/);
  assert.match(app,/return renderBusinessApplication\(\)/);
});

test('new subscription copy is prospectively non-refundable with mandatory-rights carve-out',()=>{
  assert.match(terms,/subscription fees are non-refundable once payment is completed/i);
  assert.match(terms,/does not limit any right or remedy that cannot lawfully be excluded/i);
  assert.doesNotMatch(terms,/request a refund within 30 days|money-back request window/i);
  const onboard=section(app,'function renderOnboard(){','/* ============================================================================');
  assert.match(onboard,/Subscription fees are non-refundable after payment, except where required by law/);
  assert.doesNotMatch(onboard,/30-day money-back/);
});

test('V144 preserves prior refund windows but activates new policy purchases from first-paid evidence',()=>{
  assert.match(migration,/create table public\.billing_first_paid_evidence_v144/);
  assert.match(migration,/if v_legal_version>='2026-08-03' then/);
  assert.match(migration,/else\s+insert into public\.billing_money_back_windows_v124/s);
  assert.match(migration,/create trigger billing_first_paid_self_serve_activate_v144/);
  assert.match(migration,/execute function app\.activate_self_serve_paid_v130\(\)/);
  assert.match(migration,/alter column legal_document_version set default '2026-08-03'/);
  assert.match(migration,/money_back_days'.+else null end/s);
  assert.match(migration,/refund_policy'.+non_refundable_after_payment/s);
  assert.match(migration,/customer legal manifest/i);
  assert.doesNotMatch(migration,/delete from public\.billing_money_back_windows_v124/i);
});

test('missing catalogue state is actionable and separates Stripe from manual approval',()=>{
  const onboard=section(app,'function renderOnboard(){','/* ============================================================================');
  assert.match(onboard,/Payment setup needs help/);
  assert.match(onboard,/Contact Peekaa support/);
  assert.match(onboard,/No workspace or charge was created/);
  assert.doesNotMatch(onboard,/Submit for approval|management approval/i);
  assert.match(onboard,/manual-payment approval form below for Super Admin review/);
});
