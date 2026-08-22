/* nestly_v461 — the two rules this change introduces, EXECUTED.
 *
 *  A. liveBalanceProgrammeIdV461 must be app.live_balance_programme_v381 and nothing else. The
 *     server's body, read from production 2026-08-22:
 *       select bp.id from public.business_programmes bp
 *        where bp.business_id = p_business and bp.active and bp.kind in ('points','stamps')
 *        order by case bp.kind when 'stamps' then 0 else 1 end, bp.id
 *        limit 1
 *     Two definitions of "which pot is live" is how the client and the server come to disagree
 *     about whose history a customer is looking at, so every clause is pinned here: active only,
 *     points|stamps only, STAMPS WINS, then lowest id, else null.
 *
 *  B. loyaltyUnitNounV461 must follow v460's payload and fall back to the spine — never to a
 *     hardcoded 'points', which is what told Cubbly SPA that their 53 stamps were points.
 *
 * Also pinned: the dead activityEarnUnitV375 is gone (both halves), and the dashboard tile's label
 * expression — which cannot be asserted from a rendered page, because the strip it lives in sits
 * behind `loyaltyVisibleV170=false` and is blanked on every render.
 *
 * The functions are closures/top-level declarations in a 44k-line file that cannot be imported, so
 * each is extracted by its real declaration and run in a vm. The extraction is asserted before use,
 * so a rename cannot silently shrink the slice and leave every case below passing against nothing.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';

const root=fileURLToPath(new URL('../../',import.meta.url));
const source=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

const sliceBetween=(text,startNeedle,endNeedle)=>{
  const start=text.indexOf(startNeedle);
  assert.notEqual(start,-1,`could not find ${startNeedle}`);
  const end=text.indexOf(endNeedle,start);
  assert.notEqual(end,-1,`could not find ${endNeedle} after ${startNeedle}`);
  return text.slice(start,end);
};

/* Both helpers, plus the spine reader they sit on, in one runnable slice. */
const buildHelpers=(text,rows)=>{
  const liveId=sliceBetween(text,'function liveBalanceProgrammeIdV461()','function loyaltyUnitFromPayloadV461');
  const unit=sliceBetween(text,'function loyaltyUnitFromPayloadV461','function programmeSpineRunningV314');
  assert.match(liveId,/order|sort/,'extracted a real ordering, not a stub');
  const context={
    programmeSpineRowsV314:()=>rows,
    /* liveBalanceUnitV378 is the documented fallback; its own rule is one line, restated here
       exactly so the fallback under test is the real one. */
    programmeSpineOnV314:kind=>rows?rows.some(row=>row&&row.kind===kind&&row.active===true):null,
    liveBalanceUnitV378(){return context.programmeSpineOnV314('stamps')===true?'stamps':'points'}
  };
  vm.createContext(context);
  vm.runInContext(`${liveId}\n${unit}\n`
    +'globalThis.__liveId=liveBalanceProgrammeIdV461;globalThis.__noun=loyaltyUnitNounV461;'
    +'globalThis.__unit=loyaltyUnitFromPayloadV461;',context);
  return {liveId:()=>context.__liveId(),noun:u=>context.__noun(u),unit:u=>context.__unit(u)};
};

const row=(id,kind,active)=>({id,kind,active,deactivatedAt:active?null:'2026-06-01T00:00:00Z'});

test('A. the live pot is chosen by exactly the server rule', ()=>{
  /* stamps wins over an equally-active points pot, whatever the ids say */
  assert.equal(buildHelpers(source,[row('zzz','stamps',true),row('aaa','points',true)]).liveId(),'zzz',
    'STAMPS WINS even when the points pot sorts first by id');
  assert.equal(buildHelpers(source,[row('aaa','points',true),row('zzz','stamps',true)]).liveId(),'zzz',
    '...and regardless of array order');
  /* among same-kind actives, lowest id */
  assert.equal(buildHelpers(source,[row('b','points',true),row('a','points',true)]).liveId(),'a',
    'lowest id breaks a same-kind tie, as the server ORDER BY does');
  assert.equal(buildHelpers(source,[row('y','stamps',true),row('x','stamps',true)]).liveId(),'x');
  /* inactive pots are invisible — this is the whole bug */
  assert.equal(buildHelpers(source,[row('retired','points',false),row('live','stamps',true)]).liveId(),'live',
    'a retired pot is never the live one');
  assert.equal(buildHelpers(source,[row('retired','points',false)]).liveId(),null,
    'nothing accruing is NULL, not "fall back to the retired pot"');
  /* kinds outside points|stamps never qualify */
  assert.equal(buildHelpers(source,[row('t','tiers',true),row('b','bringback',true)]).liveId(),null,
    'tiers and bring-back are not balance pots');
  assert.equal(buildHelpers(source,[row('t','tiers',true),row('p','points',true)]).liveId(),'p',
    '...and do not displace one that is');
  /* an unread spine is not an answer */
  assert.equal(buildHelpers(source,null).liveId(),null,'an unread spine yields NULL, never a guess');
  assert.equal(buildHelpers(source,[]).liveId(),null,'and so does an empty one');
});

test('B. the unit word follows the payload, then the spine, never a hardcoded default', ()=>{
  const onStamps=buildHelpers(source,[row('s','stamps',true)]);
  const onPoints=buildHelpers(source,[row('p','points',true)]);
  /* v460 present: the payload decides, on both spines */
  assert.equal(onStamps.noun('stamps'),'Stamps');
  assert.equal(onPoints.noun('points'),'Points');
  assert.equal(onPoints.noun('stamps'),'Stamps','the payload outranks the spine when it speaks');
  assert.equal(onStamps.noun('points'),'Points');
  /* v460 absent — an older server, or this deploy landing first. THE regression that matters: a
     stamps merchant must not be told "Points". */
  for(const missing of [null,undefined,'','unknown',0]){
    assert.equal(onStamps.noun(missing),'Stamps',
      `with loyalty_unit=${JSON.stringify(missing)} a stamps firm still reads Stamps`);
    assert.equal(onPoints.noun(missing),'Points',
      `and a points firm still reads Points`);
  }
  /* case and stray whitespace from a payload are not a reason to fall through */
  assert.equal(onPoints.unit('STAMPS'),'stamps','the unit is matched case-insensitively');
  /* an unread spine with no payload is the only place 'points' is assumed, and that is
     liveBalanceUnitV378's documented behaviour, not a new decision made here. */
  assert.equal(buildHelpers(source,null).noun(null),'Points');
});

test('the dashboard tile label is built from the payload', ()=>{
  /* This one cannot be read off a page: `const loyaltyVisibleV170=false` and
     `if(!loyaltyVisibleV170)loyalty.innerHTML=''` blank the whole strip on every render (V224).
     So the expression itself is executed. */
  assert.match(source,/const loyaltyVisibleV170=false;/,
    'the strip is still gated off — if this changes, assert the label from the rendered page instead');
  const label=sliceBetween(source,'{label:`','} earned`,');
  assert.match(label,/loyaltyUnitNounV461\(d\.loyalty_unit\)/,
    'the dashboard tile builds its label from the payload, not from a literal');
  const helpers=buildHelpers(source,[row('s','stamps',true)]);
  assert.equal(`${helpers.noun('stamps')} earned`,'Stamps earned');
  assert.equal(`${helpers.noun('points')} earned`,'Points earned');
});

test('the dead activityEarnUnitV375 is gone, both halves', ()=>{
  /* It was assigned on every Customer 360 load and read by nothing; the unit word has come from
     activityEarnedCellV378 -> liveBalanceUnitV378 since v378. A second unused derivation of "which
     unit" is how two answers to one question start. */
  assert.doesNotMatch(source,/let activityEarnUnitV375/,'the declaration is gone');
  assert.doesNotMatch(source,/^\s*activityEarnUnitV375=/m,'and so is the assignment');
  /* The live derivation is still the only one, and still wired to the cell that prints the word. */
  assert.match(source,/function activityEarnedCellV378\(units\)\{[\s\S]{0,200}liveBalanceUnitV378\(\)/,
    'activityEarnedCellV378 still takes its unit from liveBalanceUnitV378');
});

test('the Customer 360 earn read is gated on the live pot and scoped to it', ()=>{
  const block=sliceBetween(source,'const activityEarnProgrammeV461=','const reversalByOriginal=');
  assert.match(block,/if\(canReadLoyalty&&activityEarnProgrammeV461\)/,
    'no live pot means no read at all — an empty column beats a mislabelled one');
  assert.match(block,/\.eq\('programme_id',activityEarnProgrammeV461\)/,
    'and the read that does happen is scoped to that pot');
  /* The scope must come from the shared rule, not a second derivation invented here. */
  assert.match(block,/liveBalanceProgrammeIdV461\(\)/,
    'the pot is chosen by the one rule, mirroring app.live_balance_programme_v381');
});

test('NEGATIVE CONTROL: every assertion above fails against the pre-fix source', ()=>{
  const before=execFileSync('git',['show','42fc1e4:app/app.js'],
    {cwd:root,encoding:'utf8',maxBuffer:64*1024*1024});
  /* The base must still contain the bug, or this control proves nothing. */
  assert.match(before,/let activityEarnUnitV375='points';/,
    'the pre-fix source must still carry the dead variable; if not, re-point this control');
  assert.match(before,/\{label:'Points earned',/,
    'and the hardcoded dashboard label');
  assert.match(before,/<tr><td>Points earned<\/td>/,
    'and the hardcoded reports rows');
  /* The helpers did not exist at all, so extracting them must throw rather than quietly succeed. */
  assert.throws(()=>buildHelpers(before,[{id:'s',kind:'stamps',active:true}]),
    /could not find function liveBalanceProgrammeIdV461/,
    'the live-pot rule is new in this change');
  /* And the 360 read was unscoped: no programme_id filter anywhere near it. */
  const beforeBlock=before.slice(before.indexOf('activityEarnedBySaleV375=new Map();'),
    before.indexOf('const reversalByOriginal='));
  assert.match(beforeBlock,/\.eq\('entry_type','earn'\)/,'located the pre-fix earn read');
  assert.doesNotMatch(beforeBlock,/programme_id/,
    'which summed EVERY pot — the bug this change removes');
});
