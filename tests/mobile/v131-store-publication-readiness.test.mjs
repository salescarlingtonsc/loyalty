import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {copyFileSync,existsSync,mkdirSync,mkdtempSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import test from 'node:test';

const root=resolve(import.meta.dirname,'../..');
const app=readFileSync(join(root,'app/index.html'),'utf8')+'\n'+readFileSync(join(root,'app/app.js'),'utf8');
const sourceMigration=join(root,'db/migrations/20260801_nestly_v131_store_publication_readiness.sql');
const mirrorMigration=join(root,'supabase/migrations/20260801210000_nestly_v131_store_publication_readiness.sql');

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`expected source boundary ${start}`);
  return source.slice(from,to);
}

/* v188 (owner ruling 2026-08-07): self-service deletion was removed — "do not allow firms or
   users to delete account… they can email in their request or speak with their assigned
   consultant". What every signed-in surface must still carry is the ROUTE to close an account,
   which is what this now checks. ⚖️ The native iOS build is the exposure: App Store guideline
   5.1.1(v) expects deletion to be INITIATED in-app, and an email address may not satisfy a
   reviewer. Recorded here because this is the store-readiness suite. */
/* nestly_v593: a surface may now carry the route in either of two shapes — the card inline, or
   the one small button that reveals that same card (accountPrivacyFooterHtmlV593, which fills
   itself with accountDeletionCardHtml() and calls wireAccountDeletionButton()). The owner asked
   for the block to stop dominating the workspace chooser; what this suite protects is that the
   ROUTE exists on every signed-in surface, not which of the two shapes it takes. Both shapes end
   at the same card and the same status read, so both are accepted — and a surface carrying
   NEITHER still fails, which is the ⚖️ 5.1.1(v) exposure noted above. */
function assertDeletionControl(source,label){
  const inline=/accountDeletionCardHtml\(\)/.test(source)&&/wireAccountDeletionButton\(\)/.test(source);
  const behindButton=/accountPrivacyFooterHtmlV593\(\)/.test(source)&&/wireAccountPrivacyFooterV593\(\)/.test(source);
  assert.ok(inline||behindButton,`${label} must render the account & privacy route`);
}

test('native business access is purchase-free and a signed-in return completes sign-out',async()=>{
  assert.match(app,/NestlyNativeBridge\.isNative/);
  assert.match(app,/New business accounts cannot be created in this app/);
  assert.doesNotMatch(app,/New business accounts are created on the Nestly website/);
  assert.match(app,/Subscription changes are not available in this app/);
  assert.match(app,/if\s*\(NestlyNativeBridge\.isNative\)[\s\S]{0,600}renderNativeBusinessCompanion/);
  assert.match(app,/Continue to secure Stripe Checkout/,'web Stripe onboarding must remain present');
  assert.match(app,/nativeBusinessSignIn'\)\.onclick=returnToNativeSignIn/);
  const source=between(app,'async function returnToNativeSignIn(){','function renderNativeBusinessCompanion(){');
  const events=[];
  const execute=new Function('S','killChannels','sb','resetClientSessionState','renderAuth',`${source};return returnToNativeSignIn();`);
  await execute(
    {user:{id:'signed-in-owner'}},
    ()=>events.push('channels'),
    {auth:{signOut:async()=>events.push('sign-out')}},
    ()=>events.push('reset'),
    mode=>events.push(`auth:${mode}`)
  );
  assert.deepEqual(events,['channels','sign-out','reset','auth:in']);
});

test('every signed-in persona is shown how to close the account, and can never do it itself',()=>{
  assert.doesNotMatch(app,/request_account_deletion_v131/,
    'v188: the browser must not be able to submit a deletion request');
  /* nestly_v749 (owner 2026-09-04, App Store 5.1.1(v)): CUSTOMER accounts may now delete
     themselves in-app through openCustomerDeleteAccountDialogV749 — which is exactly what closes
     the ⚖️ 5.1.1(v) exposure recorded above. The typed confirmation therefore exists, but only
     inside that customer-only dialog; the business closure card stays a mailto route. */
  const businessCard=between(app,'function accountDeletionCardHtml','function customerAccountDeletionCardHtmlV749');
  assert.doesNotMatch(businessCard,/Type DELETE/,'the business mailto card must not grow a typed confirmation');
  const customerDialog=between(app,'function openCustomerDeleteAccountDialogV749','function accountPrivacyFooterHtmlV593');
  assert.match(customerDialog,/Type DELETE to confirm/,'the customer-only dialog is the one place it lives');
  assert.match(app,/get_account_deletion_request_v131/,
    'an already-submitted request must still be visible to the person who made it');
  assert.match(app,/mailto:admin\.peekaa@gmail\.com/);
  assert.match(app,/speak to your assigned consultant/);
  assert.match(app,/replies within 30 days/);
  const workspaceRoute=between(app,"if(h.startsWith('#/workspace/')){",'if(!S.biz){');
  assertDeletionControl(between(workspaceRoute,'if(!workspaceStaffPersona){','S.hasCustomerPersona='),'missing direct workspace persona');
  assertDeletionControl(between(workspaceRoute,'if(workspaceError||!workspace){','if(S.biz?.id'),'missing direct workspace record');
  assertDeletionControl(between(app,'function renderCustomerWalletUnavailable(','function renderCustomerCapabilityRetry('),'unavailable customer wallet');
  assertDeletionControl(between(app,'function renderCustomerCapabilityRetry(','function renderCustomerWalletRetry('),'customer capability load error');
  assertDeletionControl(between(app,'function renderPersonaChoice(','function businessApplicationInviteToken('),'multi-workspace persona choice');
  assertDeletionControl(between(app,'function renderPersonaResolutionUnavailable(){','function renderWorkspaceAccessUnavailable(){'),'persona resolution error');
  assertDeletionControl(between(app,'function renderWorkspaceAccessUnavailable(){','function renderNativeBusinessCompanion(){'),'inactive or unassigned staff');
  assertDeletionControl(between(app,'function renderNativeBusinessCompanion(){','function renderBusinessWorkspaceControl('),'signed-in native companion');
  assertDeletionControl(between(app,'function renderBusinessWorkspaceControl(control={}){','/* ---------- auth ---------- */'),'blocked business workspace');
  const onboarding=between(app,'function renderOnboard(){','function parseDelimited(');
  assertDeletionControl(between(onboarding,'root.innerHTML=`<main class="center-wrap"','const finishCheckout='),'onboarding initial load');
  assertDeletionControl(between(onboarding,'if(state.error||!state.data){','const onboarding=state.data.onboarding'),'onboarding load error');
  /* V286: renderOnboard's payment-pending branch now delegates to the single
     renderSelfServePaymentPendingV286 renderer (it was one of two drifted copies, and the other
     was the reachable one). The deletion + privacy control follows the markup to its new home. */
  assertDeletionControl(between(app,'function renderSelfServePaymentPendingV286(','function renderBusinessWorkspaceControl('),'web payment pending');
  assertDeletionControl(between(onboarding,'if(!annual||!monthly||!sectors.length){','const capacityOptions='),'unavailable subscription catalogue');
  assertDeletionControl(between(onboarding,'root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card" style="width:820px','let slugEdited=false'),'active owner setup');
  assert.doesNotMatch(app,/auth\.admin\.deleteUser/);
  assert.ok(existsSync(sourceMigration));
  assert.ok(existsSync(mirrorMigration));
  assert.ok(existsSync(join(root,'db/tests/v131_store_publication_readiness.sql')));
  assert.equal(readFileSync(sourceMigration,'utf8'),readFileSync(mirrorMigration,'utf8'));
  const sql=readFileSync(sourceMigration,'utf8');
  assert.match(sql,/create table public\.account_deletion_requests/);
  assert.match(sql,/enable row level security/);
  assert.match(sql,/force row level security/);
  assert.match(sql,/security definer/);
  assert.match(sql,/if coalesce\(p_confirmation,''\)<>'DELETE' then/);
  assert.doesNotMatch(sql,/upper\(btrim\(coalesce\(p_confirmation/);
  assert.match(sql,/revoke all on table public\.account_deletion_requests from public, anon, authenticated/);
  /* v131 granted it; v188 revokes it. Both are true of the deployed database, and the v131
     migration text must not be rewritten to pretend otherwise. */
  assert.match(sql,/grant execute on function public\.request_account_deletion_v131\(text,text\) to authenticated/);
  const revoke=readFileSync(join(root,'db/migrations/20260807_nestly_v188_no_self_service_account_deletion.sql'),'utf8');
  assert.match(revoke,/revoke execute on function public\.request_account_deletion_v131\(text, text\) from authenticated;/);
});

test('store association generator fails closed and emits exact real identifiers',()=>{
  const script=join(root,'scripts/mobile/store-readiness.mjs');
  assert.ok(existsSync(script));
  assert.throws(()=>execFileSync(process.execPath,[script,'--generate'],{cwd:root,stdio:'pipe'}));
  const out=mkdtempSync(join(tmpdir(),'nestly-store-v131-'));
  execFileSync(process.execPath,[script,'--generate','--output',out],{
    cwd:root,stdio:'pipe',env:{...process.env,APPLE_TEAM_ID:'A1B2C3D4E5',ANDROID_SHA256_CERT_FINGERPRINT:'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'}
  });
  const aasa=JSON.parse(readFileSync(join(out,'apple-app-site-association'),'utf8'));
  const links=JSON.parse(readFileSync(join(out,'assetlinks.json'),'utf8'));
  assert.equal(aasa.applinks.details[0].appID,'A1B2C3D4E5.asia.peekaa.app');
  assert.equal(links[0].target.package_name,'asia.peekaa.app');
});

test('the App Store icon is a 1024px PNG without an alpha-bearing colour type',()=>{
  const iconPath=join(root,'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png');
  const icon=readFileSync(iconPath);
  assert.equal(icon.readUInt32BE(16),1024);
  assert.equal(icon.readUInt32BE(20),1024);
  assert.ok(![4,6].includes(icon[25]),`PNG colour type ${icon[25]} contains alpha`);
  let offset=8;const chunks=[];
  while(offset+12<=icon.length){const length=icon.readUInt32BE(offset),type=icon.subarray(offset+4,offset+8).toString('ascii');chunks.push(type);offset+=12+length;if(type==='IEND')break}
  assert.ok(!chunks.includes('tRNS'),'PNG contains a transparency chunk');

  const sandbox=mkdtempSync(join(tmpdir(),'nestly-store-trns-v131-'));
  const scriptDir=join(sandbox,'scripts/mobile');
  const sandboxIcon=join(sandbox,'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png');
  mkdirSync(scriptDir,{recursive:true});
  mkdirSync(join(sandbox,'ios/App/App/Assets.xcassets/AppIcon.appiconset'),{recursive:true});
  mkdirSync(join(sandbox,'node_modules/@capacitor/ios/Capacitor/Capacitor'),{recursive:true});
  mkdirSync(join(sandbox,'node_modules/@capacitor/ios/CapacitorCordova/CapacitorCordova'),{recursive:true});
  copyFileSync(join(root,'scripts/mobile/store-readiness.mjs'),join(scriptDir,'store-readiness.mjs'));
  writeFileSync(join(sandbox,'capacitor.config.ts'),"export default { appId: 'asia.peekaa.app' };\n");
  writeFileSync(join(sandbox,'node_modules/@capacitor/ios/Capacitor/Capacitor/PrivacyInfo.xcprivacy'),'fixture');
  writeFileSync(join(sandbox,'node_modules/@capacitor/ios/CapacitorCordova/CapacitorCordova/PrivacyInfo.xcprivacy'),'fixture');
  const iend=icon.lastIndexOf(Buffer.from('IEND'))-4;
  assert.ok(iend>8,'fixture icon must contain IEND');
  const transparentChunk=Buffer.alloc(12);
  transparentChunk.write('tRNS',4,'ascii');
  writeFileSync(sandboxIcon,Buffer.concat([icon.subarray(0,iend),transparentChunk,icon.subarray(iend)]));
  assert.throws(
    ()=>execFileSync(process.execPath,[join(scriptDir,'store-readiness.mjs')],{cwd:sandbox,stdio:'pipe'}),
    error=>String(error.stderr).includes('contains an alpha channel'),
    'store validator must reject a tRNS-bearing PNG'
  );
});
