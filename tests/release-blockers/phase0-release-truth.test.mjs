import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
const migration=await readFile(new URL('db/migrations/20260721_frenly_v41_customer_module_hardening.sql',root),'utf8');
const buildHandler=require('../../app/api/build.js');

function functionBlock(name){
  const match=migration.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\n\\$\\$;`,'i'));
  assert.ok(match,`missing ${name}`);
  return match[0];
}

function invokeBuild(method,environment){
  const prior={sha:process.env.VERCEL_GIT_COMMIT_SHA,env:process.env.VERCEL_ENV};
  if(environment.sha===undefined)delete process.env.VERCEL_GIT_COMMIT_SHA;
  else process.env.VERCEL_GIT_COMMIT_SHA=environment.sha;
  if(environment.env===undefined)delete process.env.VERCEL_ENV;
  else process.env.VERCEL_ENV=environment.env;
  const headers={};let body='';
  const response={statusCode:0,setHeader(name,value){headers[name.toLowerCase()]=value},end(value=''){body=value}};
  try{buildHandler({method},response)}finally{
    if(prior.sha===undefined)delete process.env.VERCEL_GIT_COMMIT_SHA;else process.env.VERCEL_GIT_COMMIT_SHA=prior.sha;
    if(prior.env===undefined)delete process.env.VERCEL_ENV;else process.env.VERCEL_ENV=prior.env;
  }
  return {status:response.statusCode,headers,body};
}

test('Gift Cards read path preserves the reviewed definer boundary and never masks DB errors',()=>{
  const list=functionBlock('staff_list_gift_cards');
  const page=app.slice(app.indexOf('async function giftcardsPage()'),app.indexOf('/* ---------- appointments ---------- */'));
  assert.match(list,/stable[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(list,/app\.can_module_read\s*\(\s*p_business\s*,\s*'giftcards'\s*\)/i);
  assert.match(list,/from public\.gift_cards g[\s\S]*g\.business_id = p_business/i);
  assert.match(migration,/revoke all privileges on table public\.gift_cards from public, anon, authenticated/i);
  assert.match(migration,/revoke all privileges on function public\.staff_list_gift_cards\(uuid,integer\)[\s\S]*grant execute on function public\.staff_list_gift_cards\(uuid,integer\)\s+to authenticated/i);
  assert.match(page,/sb\.rpc\('staff_list_gift_cards',\{p_business:S\.biz\.id,p_limit:100\}\)/);
  assert.doesNotMatch(page,/sb\.from\('gift_cards'\)/);
  assert.match(page,/if\(error\)\{[\s\S]*esc\(error\.message\|\|'Gift cards could not be loaded\.'\)[\s\S]*giftCardsRetry/,
    'the route must expose and retry the database failure rather than turn it into an empty state');
});

test('Gift Cards route and role contract is explicit for every canonical role',()=>{
  const capabilitySource=app.match(/const ROLE_CAPABILITIES=\{[\s\S]*?\n\};/)?.[0];
  assert.ok(capabilitySource,'role capability map must exist');
  const roles=Function(`${capabilitySource};return ROLE_CAPABILITIES`)();
  const evaluate=(role,permission)=>{
    const moduleEnabled=permission!==null;
    const canRead=moduleEnabled&&(role==='owner'||permission==='r'||permission==='rw');
    const canWrite=moduleEnabled&&(role==='owner'||permission==='rw');
    return {read:canRead,transact:canWrite&&roles[role].has('create_sales')};
  };
  const matrix=[
    {role:'owner',permission:'rw',read:true,transact:true},
    {role:'manager',permission:'rw',read:true,transact:true},
    {role:'manager',permission:'r',read:true,transact:false},
    {role:'manager',permission:null,read:false,transact:false},
    {role:'staff',permission:'rw',read:true,transact:true},
    {role:'staff',permission:'r',read:true,transact:false},
    {role:'staff',permission:null,read:false,transact:false},
    {role:'frontdesk',permission:'rw',read:true,transact:true},
    {role:'frontdesk',permission:'r',read:true,transact:false},
    {role:'frontdesk',permission:null,read:false,transact:false},
    {role:'bookkeeper',permission:'rw',read:true,transact:false},
    {role:'bookkeeper',permission:'r',read:true,transact:false},
    {role:'bookkeeper',permission:null,read:false,transact:false}
  ];
  for(const expectation of matrix){
    assert.equal(roles[expectation.role] instanceof Set,true,`${expectation.role} must be declared`);
    assert.deepEqual(evaluate(expectation.role,expectation.permission),
      {read:expectation.read,transact:expectation.transact},
      `${expectation.role}:${expectation.permission??'denied'} Gift Cards access drifted`);
  }
  assert.match(app,/memberships:membershipsPage,giftcards:giftcardsPage,appointments:appointmentsPage/);
  assert.match(app,/const canReadModule=module=>S\.myRole==='owner'\|\|S\.myModules\?\.includes\(module\)===true/);
  assert.match(app,/const canWrite=canWriteModule\('giftcards'\);\s*const canTransact=canWrite&&hasRoleCapability\('create_sales'\)/);
});

test('build identity endpoint exposes only validated non-secret deployment facts',()=>{
  const sha='abcdef0123456789abcdef0123456789abcdef01';
  const ok=invokeBuild('GET',{sha,env:'preview'});
  assert.equal(ok.status,200);
  assert.equal(ok.headers['cache-control'],'public, max-age=0, must-revalidate');
  assert.deepEqual(JSON.parse(ok.body),{
    schemaVersion:1,service:'loyalty',available:true,environment:'preview',commitSha:sha,shortSha:sha.slice(0,12)
  });
  const unavailable=invokeBuild('GET',{sha:'not-a-sha',env:'production'});
  assert.equal(unavailable.status,503);
  assert.deepEqual(JSON.parse(unavailable.body),{schemaVersion:1,service:'loyalty',available:false});
  assert.doesNotMatch(unavailable.body,/not-a-sha|production/);
  for(const environment of [undefined,'unknown','staging']){
    const ambiguous=invokeBuild('GET',{sha,env:environment});
    assert.equal(ambiguous.status,503,`${environment??'missing'} VERCEL_ENV must fail closed`);
    assert.deepEqual(JSON.parse(ambiguous.body),{schemaVersion:1,service:'loyalty',available:false});
    assert.doesNotMatch(ambiguous.body,/unknown|staging|abcdef/);
  }
  const method=invokeBuild('POST',{sha,env:'preview'});
  assert.equal(method.status,405);
});

test('the UI validates and surfaces build identity without blocking application boot',()=>{
  assert.match(app,/fetch\('\/api\/build',\{method:'GET',credentials:'same-origin'/);
  assert.match(app,/payload\?\.schemaVersion===1[\s\S]*payload\?\.service==='loyalty'[\s\S]*\^\[0-9a-f\]\{40\}\$/);
  assert.match(app,/\['production','preview','development'\]\.includes\(payload\.environment\)/);
  assert.doesNotMatch(app,/\['production','preview','development','unknown'\]/);
  assert.match(app,/window\.__FRENLY_BUILD_IDENTITY__=buildIdentity/);
  assert.match(app,/class="foot" aria-label="Application version">\$\{buildIdentityHtml\(\)\}/);
  assert.match(app,/async function boot\(\)\{[\s\S]*loadBuildIdentity\(\);\s*route\(\);/,
    'build identity must be non-blocking and must not gate login or routing');
});
