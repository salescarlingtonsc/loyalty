import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const migration=readFileSync(new URL('../../supabase/migrations/20260802120000_nestly_v138_auth_grow_closure.sql',import.meta.url),'utf8');
const launchFreezeMigration=readFileSync(new URL('../../supabase/migrations/20260803160000_nestly_v145_launch_freeze_metrics.sql',import.meta.url),'utf8');
const sqlAcceptance=readFileSync(new URL('../../db/tests/v138_auth_grow_closure.sql',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

const auth=section("function renderAuth(mode='in'",'function validNewPassword(');
const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
const nav=section('function growNavItemHtml(','function wireNav()');

test('ordinary sign-in has no legal checkbox while owner signup remains consent-gated',()=>{
  assert.match(auth,/businessGoogleButtonHtml\('businessGoogleSignIn'\)/);
  assert.doesNotMatch(auth,/businessGoogleLegal|Google creates a new Peekaa account/);
  assert.match(app,/id="applicationConsent" type="checkbox"/);
  assert.match(app,/if\(!\$\('applicationConsent'\)\.checked\)/);
});

test('Google sign-in cannot become implicit signup and consented signup records exact legal versions',()=>{
  const callback=section('async function consumeBusinessOAuthRedirect(){','async function consumePasswordRecoveryRedirect()');
  assert.match(app,/begin_business_google_oauth_signup_v138/);
  assert.match(app,/complete_business_google_oauth_v138/);
  assert.match(app,/storageKey:'nestly-business-oauth-admission-v138',persistSession:false/);
  assert.match(app,/autoRefreshToken:false,detectSessionInUrl:false/);
  assert.ok(callback.indexOf("admissionClient.rpc('complete_business_google_oauth_v138'")<callback.indexOf('await sb.auth.setSession('));
  assert.match(app,/terms:Object\.freeze\(\{version:'2026-08-03',sha256:'1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04'/);
  assert.match(app,/privacy:Object\.freeze\(\{version:'2026-08-03',sha256:'8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568'/);
  assert.match(migration,/create table app\.business_google_oauth_attempts_v138/);
  assert.match(migration,/create table app\.business_account_legal_acceptances_v138/);
  assert.match(migration,/where staff_row\.user_id=v_actor and staff_row\.active/);
  assert.match(migration,/identity_row\.user_id=v_actor and identity_row\.provider='google'/);
  assert.match(migration,/v_attempt\.expires_at<=now\(\)/);
  assert.match(migration,/v_attempt\.consumed_by<>v_actor/);
  assert.match(migration,/grant execute on function public\.begin_business_google_oauth_signup_v138[\s\S]*?to anon/);
  assert.match(migration,/grant execute on function public\.complete_business_google_oauth_v138\(text,text\)[\s\S]*?to authenticated/);
  assert.match(sqlAcceptance,/new Google identity unexpectedly entered through sign-in/);
  assert.match(sqlAcceptance,/forged Google signup callback unexpectedly passed/);
  assert.match(sqlAcceptance,/Google signup did not preserve exactly one current Terms\/Privacy acceptance/);
});

test('browser auth session persists and refreshes until an explicit sign-out',()=>{
  assert.match(app,/persistSession:true,autoRefreshToken:true/);
  assert.match(app,/autocomplete:mode==='in'\?'current-password'/);
  assert.doesNotMatch(auth,/auth\.signOut\(/);
});

test('sidebar exposes consolidated Grow programme navigation instead of peer reward-module links',()=>{
  for(const label of ['Overview','Ongoing programmes','Available programmes','More settings'])assert.match(nav,new RegExp(`'${label}'`));
  assert.match(nav,/\['#\/grow','Overview'\]/);
  assert.match(nav,/const restItems=g\.key==='grow'\?\[\]:g\.items/);
  assert.doesNotMatch(nav,/>Promotions<\/a>/);
  assert.doesNotMatch(nav,/Rewards &amp; bring-backs/);
});

test('every editable Grow submodule offers a stable return to the one overview',()=>{
  assert.match(app,/function growBackActionHtmlV138\(\)/);
  for(const title of ['Loyalty','Retention programs','Promotions','Referrals','Memberships','Gift cards']){
    assert.match(app,new RegExp(`pageHeader\\(\\{title:'${title}'[\\s\\S]{0,650}?actions:(?:\`\\$\\{growBackActionHtmlV138\\(\\)\\}|growBackActionHtmlV138\\(\\))`),`${title} lacks a return action`);
  }
  assert.match(app,/Back to Grow overview/);
  assert.match(app,/href="#\/grow" aria-label="Back to Grow overview"/);
});

test('reward completion returns to the Grow overview instead of leaving the owner in an editor',()=>{
  assert.match(app,/id="rwClose" type="button">Done<\/button>/);
  assert.match(app,/const finishGrowEditorV139=\(\)=>editorIntent\?nav\('#\/grow'\):nav\('#\/loyalty'\)/);
  assert.match(app,/\$\('rwClose'\)\.onclick=finishGrowEditorV139/);
  assert.match(app,/toast\('Draft reward saved'\);\s*finishGrowEditorV139\(\)/);
});

test('the install surface contains no customer-visible Nestly brand',()=>{
  assert.doesNotMatch(app,/Install Nestly/);
});

test('clicking a live reward missing from a stale draft safely materializes and opens the exact editor',()=>{
  assert.match(grow,/ensure_published_reward_in_draft_v138/);
  assert.match(grow,/p_expected_snapshot_hash:draftSnapshotHash/);
  assert.match(grow,/await loyaltyPage\(undefined,draft,null,false,editorIntent\)/);
  assert.match(grow,/openExactReward\(\{allowMaterialize:false\}\)/);
  assert.doesNotMatch(grow,/This published reward is not present in the current draft\. Review the draft before changing another reward\./);
});

test('server continuity function is owner-only, stale-write guarded and preserves unrelated draft rows',()=>{
  assert.match(migration,/create or replace function public\.ensure_published_reward_in_draft_v138/);
  assert.match(migration,/app\.c45_owner_loyalty_write\(v_draft\.business_id\)/);
  assert.match(migration,/v_draft\.status <> 'draft'/);
  assert.match(migration,/p_expected_snapshot_hash is not null[\s\S]*?errcode = '40001'/);
  assert.match(migration,/on conflict \(reward_id, config_version_id\) do nothing/);
  assert.doesNotMatch(migration,/delete from public\.loyalty_reward_versions/);
  assert.match(migration,/perform app\.refresh_loyalty_config_snapshot\(p_config_version\)/);
  assert.match(migration,/grant execute on function public\.ensure_published_reward_in_draft_v138/);
  assert.ok(
    migration.indexOf("where config_version_id = p_config_version")
      <migration.indexOf("draft configuration changed; reload before editing this reward"),
    'durable exact-row replay must be checked before the stale snapshot hash'
  );
  assert.match(migration,/ensure_published_retention_in_draft_v138/);
  assert.match(migration,/ensure_published_birthday_in_draft_v138/);
  assert.match(grow,/ensure_published_retention_in_draft_v138/);
  assert.match(grow,/ensure_published_birthday_in_draft_v138/);
});

test('Grow is entitlement-neutral and retention-only owners can create and edit from the overview',()=>{
  assert.match(app,/pageKey==='grow'&&!growModuleKeys\.some\(module=>canReadModule\(module\)\)/);
  assert.match(app,/grow:\(hashParam,routedFocus\)=>growPage\('overview',hashParam,routedFocus\)/);
  assert.match(grow,/const canSetupWinback=isOwner&&canWinback&&canWriteModule\('retention'\)/);
  assert.match(grow,/sb\.rpc\('create_grow_config_draft_v138'/);
  assert.match(grow,/p_source:'grow_retention_edit'/);
  assert.match(migration,/create or replace function public\.create_grow_config_draft_v138/);
  assert.match(migration,/app\.is_salon_owner\(p_business\)[\s\S]*app\.can_module_write\(p_business,'loyalty'\)[\s\S]*app\.can_module_write\(p_business,'retention'\)/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/status='draft'[\s\S]*replayed',true/);
  assert.match(sqlAcceptance,/retention-only owner did not create one unpublished Grow draft/);
  assert.match(sqlAcceptance,/manager unexpectedly created a Grow draft/);
  assert.match(sqlAcceptance,/cross-tenant owner unexpectedly created a Grow draft/);
  assert.doesNotMatch(grow,/Loyalty edit access required before Bring-back/);
});

test('programme editors expose explicit visibility controls and customer rewards remain active-filtered',()=>{
  assert.match(app,/id="rwActive" type="checkbox"[\s\S]{0,180}?Available for customers/);
  assert.match(app,/id="birthdayActive" type="checkbox"/);
  assert.match(app,/id="fe"><option value="true"[\s\S]{0,100}?<option value="false"/);
  assert.match(app,/onclick="togglePlan\('[^']+',\$\{!p\.active\}\)"/);
  assert.match(app,/id="giftCardEnabled" type="checkbox"/);
  assert.match(app,/staff_get_customer_actionable_loyalty_v145/);
  assert.match(launchFreezeMigration,/reward_version\.active[\s\S]*join public\.loyalty_rewards reward[\s\S]*reward\.active/);
});
