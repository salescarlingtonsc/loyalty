import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=(fs.readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+fs.readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const platform=fs.readFileSync(new URL('../../app/platform-console.js',import.meta.url),'utf8');
const mediaSync=fs.readFileSync(new URL('../../app/v95-media-sync.js',import.meta.url),'utf8');

test('public owner signup creates Auth first while assisted approval remains separate',()=>{
  assert.match(app,/function renderBusinessApplication\(\)/);
  assert.match(app,/sb\.auth\.signUp/);
  assert.match(app,/account_type:'business_owner'/);
  assert.match(app,/start_self_serve_business_v130/);
  assert.match(app,/request_self_serve_checkout_v130/);
  assert.match(app,/new URLSearchParams\(location\.search\)\.get\('signup'\)==='1'\)return renderBusinessSignupChoice\(\)/);
  assert.doesNotMatch(app,/function renderOnboard\(\)[\s\S]*?sb\.rpc\('create_business'/);
});

test('approved owner creation is invite-bound and workspace activation is server-authorized',()=>{
  assert.match(app,/businessApplicationInviteToken/);
  assert.match(app,/renderApprovedBusinessInviteSignup/);
  assert.match(app,/approvedOwnerEmail[\s\S]*readonly/);
  assert.match(app,/emailRedirectTo:returnUrl\.toString\(\)/);
  assert.match(app,/returnUrl=new URL\(NestlyNativeBridge\.publicUrl\('\/business'\)\)/);
  assert.match(app,/activate_approved_business_application_v95/);
  assert.match(app,/p_invitation_token:inviteToken/);
  assert.match(app,/p_idempotency_key:activationKey/);
});

test('self-service locale choices and assisted invitations retain English, Chinese and Bahasa Melayu copy',()=>{
  assert.match(app,/'zh-CN'/);
  assert.match(app,/申请 Peekaa 商家账户/);
  assert.match(app,/超级管理员批准后/);
  assert.match(app,/I have read and agree to the Terms and Privacy Policy/);
  assert.match(app,/Mohon akaun perniagaan Peekaa/);
  assert.match(app,/>Bahasa Melayu<\/option>/);
  assert.match(app,/ms:\{fnb:'Makanan & minuman \/ Kafe'/);
  assert.match(app,/invitationUnavailable:'Jemputan tidak tersedia'/);
  assert.match(app,/workspaceCreateError:'Ruang kerja ini tidak dapat dicipta\.'/);
  assert.match(app,/legalLinks\(locale\)/);
  assert.match(app,/preferred_locale:locale/);
  assert.doesNotMatch(app,/locale==='ms'\?'en'/);
});

test('only the superadmin platform queue can decide applications and activates without link handling',()=>{
  const decision=platform.slice(
    platform.indexOf('function businessApplicationDecisionModal'),
    platform.indexOf('function wireOnboarding')
  );
  assert.match(platform,/context\.access\?\.role==='super_admin'/);
  assert.match(platform,/platform_list_business_applications_v95/);
  assert.match(decision,/platform_decide_business_application_v105/);
  assert.match(decision,/p_expected_version:application\.version/);
  assert.match(decision,/p_idempotency_key:decisionAttemptKey/);
  assert.match(decision,/automaticApprovalReason='Approved by Super Admin'/);
  assert.match(decision,/Business application approved and workspace activated/);
  assert.doesNotMatch(decision,/Peekaa stores only its hash and cannot show the token again/);
  assert.doesNotMatch(decision,/Copy secure owner link/);
});

test('owner programme editor publishes canonical copy and allowlisted media through guarded contracts',()=>{
  assert.match(app,/business_get_presentation_editor_v95/);
  assert.match(app,/business_upsert_localized_copy_v95/);
  assert.doesNotMatch(app,/business_upsert_media_asset_v95/);
  assert.match(mediaSync,/business_publish_media_replacement_v95/);
  assert.match(app,/business_set_brand_presentation_v95/);
  assert.match(app,/NestlyMediaSyncV95\.publish/);
  assert.match(app,/file\.size>10485760/);
  assert.match(app,/id="programmeColourSave"/);
  assert.match(mediaSync,/business_queue_media_cleanup_v95/);
  assert.match(mediaSync,/business_mark_media_cleanup_result_v95/);
  assert.match(mediaSync,/business_list_media_cleanup_queue_v95/);
  assert.doesNotMatch(app,/programmeNameZh|programmeTaglineZh|programmeDescriptionZh|programmeImageAltZh/);
  assert.match(app,/p_locale:'en'/);
  assert.match(app,/p_alt_zh_cn:null/);
  assert.match(app,/Preview customer view/);
});

test('customer programme renders owner-published rewards, products and services',()=>{
  assert.match(app,/products:Array\.isArray\(catalogue\.products\)/);
  assert.match(app,/services:Array\.isArray\(catalogue\.services\)/);
  assert.match(app,/Featured products & services/);
  const customerCopy=app.slice(app.indexOf('const CUSTOMER_COPY'),app.indexOf('const CUSTOMER_PRIMARY_NAV'));
  assert.doesNotMatch(customerCopy,/精选产品与服务/);
});
