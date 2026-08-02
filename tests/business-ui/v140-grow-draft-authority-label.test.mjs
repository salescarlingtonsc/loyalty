import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const app=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function authorityRenderer(){
  const source=section('function loyaltyAuthorityActionV140','function growLoyaltyEditorIntentV139');
  const context={CUI:{action:options=>`ACTION:${options.id}:${options.label}:${options.variant}`}};
  return vm.runInNewContext(`(()=>{${source};return loyaltyAuthorityActionV140})()`,context);
}

test('authorized owner with an existing draft is truthfully labelled editable',()=>{
  const render=authorityRenderer();
  const html=render({canManage:true,draftVersionId:'draft-v2'});
  assert.match(html,/Editable draft/);
  assert.doesNotMatch(html,/Read only/);
  assert.doesNotMatch(html,/ACTION:/);
});

test('authorized owner without a draft receives the create-draft action',()=>{
  const render=authorityRenderer();
  assert.equal(render({canManage:true,draftVersionId:null}),'ACTION:loyaltyRecommend:Create recommended draft:secondary');
});

test('read-only role remains explicitly read only regardless of draft existence',()=>{
  const render=authorityRenderer();
  for(const draftVersionId of [null,'draft-v2']){
    const html=render({canManage:false,draftVersionId});
    assert.match(html,/Read only/);
    assert.doesNotMatch(html,/Editable draft|ACTION:/);
  }
});

test('production Loyalty renderer delegates authority copy to the tested state helper',()=>{
  const loyalty=section('async function loyaltyPage(','/* ---------- versioned retention programs');
  assert.match(loyalty,/loyaltyAuthorityActionV140\(\{canManage:canManageLoyalty,draftVersionId\}\)/);
  assert.doesNotMatch(loyalty,/canManageLoyalty&&!draftVersionId\?CUI\.action/);
});
