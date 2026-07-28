import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function declaredFunction(name){
  const start=app.indexOf(`function ${name}(`);
  assert.ok(start>=0,`missing function ${name}`);
  const parameterStart=app.indexOf('(',start);
  let parameterDepth=0,bodyStart=-1;
  for(let i=parameterStart;i<app.length;i++){
    if(app[i]==='(')parameterDepth++;
    else if(app[i]===')'&&--parameterDepth===0){
      bodyStart=app.indexOf('{',i+1);break;
    }
  }
  assert.ok(bodyStart>parameterStart,`missing body for ${name}`);
  let depth=0;
  for(let i=bodyStart;i<app.length;i++){
    if(app[i]==='{')depth++;
    else if(app[i]==='}'&&--depth===0)return app.slice(start,i+1);
  }
  throw new Error(`unterminated function ${name}`);
}

test('workspace logo publication arguments bind the logo and brand versions to the atomic v95 contract',()=>{
  const source=declaredFunction('workspaceLogoPublishArgsV96');
  const build=vm.runInNewContext(`(()=>{${source};return workspaceLogoPublishArgsV96})()`);
  const args=build({
    businessId:'business-id',objectPath:'business-id/logo/asset.png',
    fileType:'image/png',width:640,height:640,altEn:'Acme logo',
    brand:{version:7,hero_color:'#123ABC'},existing:{version:4}
  });
  assert.deepEqual(JSON.parse(JSON.stringify(args)),{
    p_business:'business-id',p_asset_kind:'logo',p_entity_id:null,p_branch:null,
    p_object_path:'business-id/logo/asset.png',p_mime_type:'image/png',
    p_width_px:640,p_height_px:640,p_alt_en:'Acme logo',p_alt_zh_cn:null,
    p_hero_color:'#123ABC',p_expected_asset_version:4,
    p_expected_brand_version:7
  });
});

test('Workspace & brand provides owner preview and replace controls wired only to atomic publication',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  const logo=section('async function loadWorkspaceLogoEditorV96(){','async function loadCustomerProgrammePresentationEditorV95(){');
  assert.match(settings,/id="workspaceLogoEditorV96"/);
  assert.match(settings,/loadWorkspaceLogoEditorV96\(\)/);
  assert.match(logo,/business_get_presentation_editor_v95/);
  assert.match(logo,/id="workspaceLogoPreviewV96"/);
  assert.match(logo,/\$\{existing\?'Replace logo':'Upload logo'\}/);
  assert.match(logo,/Preview only — publish when this looks right\./);
  assert.match(logo,/NestlyMediaSyncV95\.publish/);
  assert.match(logo,/workspaceLogoPublishArgsV96/);
  assert.match(logo,/Logo published to the customer programme\./);
  assert.doesNotMatch(logo,/business_upsert_media_asset_v95|business_set_brand_presentation_v95/);
});

test('Quick Earn gift cards require create-sales plus effective gift-card read and write access',()=>{
  const source=declaredFunction('canUseQuickEarnGiftCards');
  const canUse=vm.runInNewContext(`(()=>{${source};return canUseQuickEarnGiftCards})()`);
  assert.equal(canUse({
    createSales:true,giftcardsReadable:true,giftcardsWritable:true
  }),true);
  assert.equal(canUse({
    createSales:true,giftcardsReadable:false,giftcardsWritable:false
  }),false,'an absent module must hide gift-card checkout');
  assert.equal(canUse({
    createSales:true,giftcardsReadable:true,giftcardsWritable:false
  }),false,'read-only gift-card access must not issue value');
  assert.equal(canUse({
    createSales:false,giftcardsReadable:true,giftcardsWritable:true
  }),false,'gift-card write access cannot bypass create-sales capability');
});

test('Quick Earn removes unauthorized gift-card lines and never calls issue_gift_card after access loss',()=>{
  const till=section('async function tillPage(){','async function salesPage(){');
  assert.match(till,/const canGift=canIssueGiftCards\(\)/);
  assert.match(till,/!canGift&&cart\.some\(line=>line\.type==='giftcard'\)[\s\S]*?cart=cart\.filter\(line=>line\.type!=='giftcard'\)/);
  assert.match(till,/\$\{canGift\?`<div class="split"[\s\S]*?id="tGiftAdd"/);
  assert.match(till,/if\(cartLocked\(\)\|\|!canIssueGiftCards\(\)\)return/);
  const finalGate=till.indexOf("if(!canIssueGiftCards()){");
  const issueCall=till.indexOf("sb.rpc('issue_gift_card'",finalGate);
  assert.ok(finalGate>=0&&issueCall>finalGate,
    'the final authority gate must execute before the gift-card issuance RPC');
});
