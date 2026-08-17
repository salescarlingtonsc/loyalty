import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const birthdayReaderMigration=readFileSync(new URL('../../db/migrations/20260801_nestly_v127_rewards_overview_birthday_reader.sql',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

/* V375: ownerRewardJourneyV122 now reads the stored loyalty model through this one-line helper,
   so the sandbox is given it out of the SAME source rather than a hand-written stand-in. */
function declaredConst(name){
  const start=app.indexOf(`const ${name}=`);
  assert.ok(start>=0,`missing const ${name}`);
  const end=app.indexOf('\n',start);
  return app.slice(start,end);
}
const NORMALISER_V375=declaredConst('normaliseLoyaltyModelV375');

function declaredFunction(name){
  const start=app.indexOf(`function ${name}(`);
  assert.ok(start>=0,`missing function ${name}`);
  const bodyStart=app.indexOf('{',app.indexOf(')',start)+1);
  let depth=0;
  for(let i=bodyStart;i<app.length;i++){
    if(app[i]==='{')depth++;
    else if(app[i]==='}'&&--depth===0)return app.slice(start,i+1);
  }
  throw new Error(`unterminated function ${name}`);
}

test('V375 a firm stored as classic gets the reward catalogue, and no store-credit reward',()=>{
  const source=declaredFunction('ownerRewardJourneyV122');
  const build=vm.runInNewContext(`(()=>{${NORMALISER_V375};${source};return ownerRewardJourneyV122})()`);
  const overview=JSON.parse(JSON.stringify(build({
    loyalty:{id:'programme-1',active:true,loyalty_model:'classic',earn_points_per_dollar:10,
      redeem_points:1000,reward_credit_cents:1000,expiry_mode:'inactivity',expiry_days:365},
    rewards:[
      {id:'reward-a',active:true,customer_name:'Same name',cost_points:500,estimated_cost_cents:400,sort:2},
      {id:'reward-b',active:true,customer_name:'Same name',cost_points:1500,estimated_cost_cents:900,sort:1},
      {id:'archived',active:false,customer_name:'Old reward',cost_points:200}
    ],
    birthday:{id:'birthday-1',active:true,customer_label:'Birthday Glow',fulfillment_kind:'discount_pct',discount_percent:20,
      customer_description:'Available during the birthday month.'}
  })));

  /* V375 (owner, photo 3). The stored value is still 'classic' — ten production programmes read
     that and the check constraint still permits it — but every reader normalises it to the
     catalogue model, so this firm is described as what it now actually is. */
  assert.deepEqual(overview.earning,{model:'points_tiers',unit:'points',rate:10,availableToCustomers:true,label:'Earn 10 points per SGD 1 spent'});
  assert.equal(overview.classicReward,undefined,
    'no reward is synthesized out of redeem_points/reward_credit_cents any more');
  assert.doesNotMatch(JSON.stringify(overview),/store credit/i);
  assert.deepEqual(overview.milestones.map(item=>item.id),['reward-a','reward-b'],
    'duplicate names retain stable reward identities and sort by threshold');
  /* The half of the defect that mattered most: these rows used to be forced to false purely
     because the model read 'classic', so the firm's own published gifts were shown to nobody. */
  assert.ok(overview.milestones.every(item=>item.availableToCustomers===true),
    'a published gift is offered whatever the stored model says');
  assert.equal(overview.birthday.id,'birthday-1');
  assert.equal(overview.birthday.value,'20% off');
});

test('stamp overview explains the earn rate and incremental milestones without inventing birthday',()=>{
  const source=declaredFunction('ownerRewardJourneyV122');
  const build=vm.runInNewContext(`(()=>{${NORMALISER_V375};${source};return ownerRewardJourneyV122})()`);
  const overview=JSON.parse(JSON.stringify(build({
    loyalty:{id:'programme-2',active:true,loyalty_model:'stamps',stamp_per_cents:500},
    rewards:[
      {id:'kopi',active:true,customer_name:'Kopi',cost_points:5},
      {id:'toast',active:true,customer_name:'Kaya toast set',cost_points:10}
    ]
  })));
  assert.equal(overview.earning.label,'Earn 1 stamp per SGD 5.00 spent');
  assert.deepEqual(overview.milestones.map(item=>item.additional),[5,5]);
  assert.equal(overview.birthday,null);
});

test('paused programmes and scheduled or ended rewards are never described as customer-available',()=>{
  const source=declaredFunction('ownerRewardJourneyV122');
  const build=vm.runInNewContext(`(()=>{${NORMALISER_V375};${source};return ownerRewardJourneyV122})()`);
  const paused=JSON.parse(JSON.stringify(build({
    asOf:'2026-08-01T00:00:00.000Z',
    loyalty:{id:'paused',active:false,loyalty_model:'points_tiers',earn_points_per_dollar:5},
    rewards:[{id:'configured',active:true,customer_name:'Configured reward',cost_points:100}]
  })));
  assert.equal(paused.earning.availableToCustomers,false);
  assert.equal(paused.milestones[0].availability,'programme_paused');
  assert.equal(paused.milestones[0].availableToCustomers,false);

  const scheduled=JSON.parse(JSON.stringify(build({
    asOf:'2026-08-01T00:00:00.000Z',
    loyalty:{id:'live',active:true,loyalty_model:'stamps',stamp_per_cents:500},
    rewards:[
      {id:'future',active:true,customer_name:'Future',cost_points:5,claim_available_from:'2026-08-02T00:00:00.000Z'},
      {id:'ended',active:true,customer_name:'Ended',cost_points:10,claim_available_until:'2026-08-01T00:00:00.000Z'},
      {id:'available',active:true,customer_name:'Available',cost_points:15,claim_available_from:'2026-07-01T00:00:00.000Z'}
    ]
  })));
  assert.deepEqual(scheduled.milestones.map(item=>item.availability),['not_started','ended','available']);
  assert.deepEqual(scheduled.milestones.map(item=>item.availableToCustomers),[false,false,true]);
});

test('published birthday overview uses a tenant-scoped loyalty-read RPC while its table stays closed',()=>{
  const snapshot=section('async function growOverviewSnapshot','function ownerRewardJourneyV122');
  assert.match(snapshot,/sb\.rpc\('get_active_birthday_program',\{p_business_id:S\.biz\.id\}\)/);
  assert.doesNotMatch(snapshot,/from\('birthday_program_versions'\)/);
  assert.match(snapshot,/Array\.isArray\(birthday\?\.programs\)\?birthday\.programs\[0\]/);
  assert.match(snapshot,/asOf:birthdayError\?null:birthday\?\.as_of\|\|null/);
  assert.match(birthdayReaderMigration,/not app\.can_module_read\(p_business_id, 'loyalty'\)/);
  assert.match(birthdayReaderMigration,/where program\.business_id = p_business_id[\s\S]*program\.config_version_id = v_version/);
  assert.match(birthdayReaderMigration,/'as_of',v_as_of/);
  assert.match(birthdayReaderMigration,/revoke all on function public\.get_active_birthday_program\(uuid\)[\s\S]*from public, anon, authenticated/);
  assert.match(birthdayReaderMigration,/grant execute on function public\.get_active_birthday_program\(uuid\)[\s\S]*to authenticated/);
  assert.doesNotMatch(birthdayReaderMigration,/grant\s+select\s+on\s+(?:table\s+)?public\.birthday_program_versions/i);
});

test('owner cards route by stable ID to the exact reward and birthday editors',()=>{
  const snapshot=section('async function growOverviewSnapshot','function ownerRewardJourneyV122');
  assert.match(snapshot,/earn_points_per_dollar/);
  assert.match(snapshot,/redeem_points/);
  assert.match(snapshot,/reward_credit_cents/);
  assert.match(snapshot,/stamp_per_cents/);
  assert.match(snapshot,/claim_available_from/);
  assert.match(snapshot,/claim_available_until/);

  const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
  assert.match(grow,/Rewards overview/);
  /* V250 turned the reward rows into the card grid the owner drew. The routing contract this
     test exists for is deliberately identical — same attribute, same stable id — it is just
     emitted once by rewardCardHtmlV250 instead of at each row. */
  assert.match(grow,/data-rewards-overview-edit="\$\{esc\(editKind\)\}"/);
  assert.match(grow,/editKind:'catalogue',rewardId:milestone\.id/);
  assert.match(grow,/data-reward-id="\$\{esc\(rewardId\)\}"/);
  /* V364 (owner, photo 1: "straightaway pop up birthday gift setting. SKIP HERE"): the birthday
     tile opens its own editor directly instead of routing through the deep Loyalty editor, so it
     no longer carries a data-rewards-overview-edit attribute. The routing CONTRACT this test is
     about — reach the exact editor by stable id, never by display name — is unchanged for the
     surfaces that still route that way, and the birthday tile is asserted to open its own editor
     from the active programme row rather than guessing. */
  assert.doesNotMatch(grow,/data-rewards-overview-edit="birthday"/);
  assert.match(grow,/if\(tile\.dataset\.growTopicV229==='birthday'\)\{/);
  assert.match(grow,/openBirthdayBenefitEditorV364\(/);
  /* V375 (owner, photo 3): the classic points-for-store-credit model is retired. */
  assert.doesNotMatch(grow,/editKind:'classic'/);
  assert.match(grow,/pendingGuideAction=action/,
    'clicking from a published overview must prepare a protected draft before editing');
  assert.match(grow,/\.rwEdit\[data-reward-id=/,
    'the embedded editor must select by stable reward ID rather than display name');
  assert.match(grow,/const exactRewardOpened=await openExactReward\(\);[\s\S]{0,220}?else if\(!exactRewardOpened&&focus&&panel\.isConnected\)/,
    'panel focus must not override the exact reward input focus');

  const loyalty=section('async function loyaltyPage(','/* ---------- Grow: one customer journey');
  assert.match(loyalty,/class="btn ghost sm rwEdit" data-reward-id="\$\{esc\(/);
  assert.match(loyalty,/reward\.reward_id\|\|reward\.id/,
    'draft and published reward identities must normalize to one stable key');
});

test('read-only and recoverable states do not expose a dead writer',()=>{
  const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
  assert.match(grow,/<section class="card reward-journey-v122/,
    'a manager can review the complete programme status surface');
  assert.match(grow,/canSetupGrow\?`<button[^>]+data-programme-kind="earning"[^>]+data-rewards-overview-edit/,
    'edit controls are owner plus Loyalty-write only');
  assert.match(grow,/id="growRewardsRetry"/);
  assert.match(grow,/programme details could not be loaded/);
  assert.match(app,/\.grow-programme-row/);
  assert.match(app,/@media\(max-width:640px\)[\s\S]*\.grow-programme-row/);
});
