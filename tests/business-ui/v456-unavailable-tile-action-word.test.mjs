/* nestly_v456 (audit A, A-REG-016) — a tile whose read FAILED must not offer to set it up.
 *
 * THE BUG. growTileStatusV371 refuses to guess when an overview read fails: the pill reads
 * 'Unavailable'. growTopicActionWordV428, which produces the word on the tile's button AND the
 * verb in its aria-label, had no branch for that state, so every path fell through to
 * `return 'Set up'`. An owner whose loyalty read had failed was invited, in the accessible name
 * and on the chip, to SET UP a programme that may well have been live — the one claim the status
 * pill beside it had just refused to make. Reproduced 2026-08-22 against the reward-overview
 * fixture with ?partial=all: all seven tiles read "Unavailable" and all seven said "Set up".
 *
 * WHAT THIS FILE PROVES, BY EXECUTING THE REAL FUNCTION — never by grepping for a string.
 * growTopicActionWordV428 is a closure inside growPage, so it cannot be imported. It is extracted
 * from app/app.js by source range and evaluated in a vm with its real dependencies bound, which
 * means the branch ORDER under test is production's, not a paraphrase:
 *   1. every topic, read failed  -> the word is 'Open' and is never one of the asserting words.
 *   2. every topic, read failed  -> the STATUS is still exactly what growTileStatusV371 produced,
 *      i.e. this fix moved the action word and left the fail-closed pill alone.
 *   3. every state that worked before -> the word is unchanged (On/Off/Draft/Paused/Not set up/
 *      Not included, writable and read-only), so the new branch cannot have swallowed a sibling.
 *   4. a read-only reader on a failed read still gets 'View' — already non-asserting, and the new
 *      branch is deliberately placed after that one.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

/* ---- extract the two functions under test, by their real declarations ---------------------- */
const sliceBetween=(startNeedle,endNeedle)=>{
  const start=source.indexOf(startNeedle);
  assert.notEqual(start,-1,`could not find ${startNeedle} in app/app.js`);
  const end=source.indexOf(endNeedle,start);
  assert.notEqual(end,-1,`could not find ${endNeedle} after ${startNeedle}`);
  return source.slice(start,end);
};
const statusSource=sliceBetween('const growTileStatusV371=','const growTopicDefsV229=');
const actionSource=sliceBetween('const growTopicActionWordV428=','const growTopicActionV244=');

/* The extraction must actually have caught the branch this test exists for. If a refactor renames
   or moves the function, the slice would silently shrink and every assertion below would pass
   against nothing — so assert on the shape of what was extracted before running it. */
assert.match(actionSource,/return 'Set up'/,'extracted the real action-word function');
assert.match(statusSource,/'Unavailable'/,'extracted the real status function');

const STATUS_WORDS={on:'On',off:'Off',draft:'Draft',scheduled:'Scheduled',live:'Live',ended:'Ended'};
const TOPICS=['points','tiers','stamps','welcome','birthday','bringback','referrals','recurring'];
const SETUP_ENTRY=new Set(['points','stamps','tiers']);
/* Every word that ASSERTS a configuration state. None of these may be produced for a tile whose
   read failed — that is the whole invariant. */
const ASSERTING=['Set up','Continue set up','Edit','Turn on','Resume','Finish setup','See plan'];

/* Build the closure exactly as growPage does: same names, same values, real bodies. */
const build=({overviewErrors={},writable=true,winbackWritable=true,ongoing=false,draftPending=null})=>{
  const context={
    snapshot:{overviewErrors},
    STATUS_WORDS,
    canSetupGrow:writable,
    canSetupWinback:winbackWritable,
    growDraftPendingId:draftPending,
    growSetupEntryV301:key=>SETUP_ENTRY.has(String(key||'')),
    growTopicOngoingV244:topic=>topic.status[1]==='on',
    growTopicWritableV421:topic=>String(topic?.key||'')==='bringback'?winbackWritable:writable
  };
  vm.createContext(context);
  /* `const` in a vm script stays lexical, so the two closures are handed out explicitly rather
     than fished off the context object. */
  vm.runInContext(`${statusSource}\n${actionSource}\n`
    +'globalThis.__status=growTileStatusV371;globalThis.__word=growTopicActionWordV428;',context);
  return {
    /* The vm has its own Array realm, so results are copied out before deep comparison. */
    status:(errorKey,status)=>[...context.__status(errorKey,status)],
    word:topic=>context.__word(topic),
    ongoingDefault:ongoing
  };
};

/* The error key each topic's tile actually names, copied from growTopicDefsV229. */
const ERROR_KEY={points:'loyalty',tiers:'loyalty',stamps:'loyalty',welcome:'rewards',
  birthday:'birthday',bringback:'retention',referrals:'referrals',recurring:'memberships'};

test('a tile whose read failed never offers to set it up', ()=>{
  for(const key of TOPICS){
    const errorKey=ERROR_KEY[key];
    const harness=build({overviewErrors:{[errorKey]:true}});
    /* The status is produced by production's own fail-closed helper, not hand-written here. */
    const status=harness.status(errorKey,[STATUS_WORDS.on,'on']);
    assert.deepEqual(status,['Unavailable','warn'],
      `${key}: growTileStatusV371 must still refuse to guess when its read failed`);
    const word=harness.word({key,status});
    assert.equal(word,'Open',
      `${key}: an unknown state gets the one word that claims nothing — got "${word}"`);
    for(const claim of ASSERTING){
      assert.notEqual(word,claim,
        `${key}: "${claim}" asserts a configuration state the failed read cannot know`);
    }
  }
});

test('the fix moved the action word and left the fail-closed status alone', ()=>{
  /* Whatever the underlying state WOULD have been, a failed read still prints Unavailable — the
     regression this guards is a "fix" that made the pill agree with the word by weakening it. */
  const underlying=[[STATUS_WORDS.on,'on'],[STATUS_WORDS.off,'off'],['Paused','warn'],
    ['Not set up','warn'],['Not included','off'],['Draft','warn']];
  const harness=build({overviewErrors:{loyalty:true}});
  for(const state of underlying){
    assert.deepEqual(harness.status('loyalty',state),['Unavailable','warn'],
      `a failed read outranks the underlying ${state[0]} state`);
  }
  /* And a key whose read did NOT fail is untouched by the same helper. */
  for(const state of underlying){
    assert.deepEqual(harness.status('referrals',state),state,
      `${state[0]}: a healthy read is passed through unchanged`);
  }
});

test('every word that worked before is unchanged', ()=>{
  const healthy=build({});
  const cases=[
    /* [topic, status, expected word, why] */
    ['points',[STATUS_WORDS.on,'on'],'Edit','a live points programme is edited'],
    ['points',[STATUS_WORDS.off,'off'],'Set up','a setup-entry tile that is off is set up'],
    ['stamps',['Not set up','warn'],'Set up','never configured'],
    ['tiers',[STATUS_WORDS.on,'on'],'Edit','a live ladder is edited'],
    ['welcome',[STATUS_WORDS.on,'on'],'View','a live non-setup-entry tile is viewed'],
    ['welcome',['Paused','warn'],'Resume','paused is resumed'],
    ['welcome',['Draft','warn'],'Finish setup','a draft is finished'],
    ['welcome',['Not included','off'],'See plan','an unbought plan is seen, not set up'],
    ['birthday',[STATUS_WORDS.off,'off'],'Turn on','off is turned on'],
    ['birthday',['Not set up','warn'],'Set up','never configured'],
    ['referrals',[STATUS_WORDS.on,'on'],'View','live'],
    ['bringback',[STATUS_WORDS.on,'on'],'View','live']
  ];
  for(const [key,status,expected,why] of cases){
    assert.equal(healthy.word({key,status}),expected,`${key} ${status[0]}: ${why}`);
  }
  /* The draft-pending variant of the setup-entry word, which the new branch sits directly above. */
  const drafting=build({draftPending:'draft-1'});
  assert.equal(drafting.word({key:'points',status:[STATUS_WORDS.off,'off']}),'Continue set up',
    'an owner with a pending draft is still told to continue it');
});

test('a read-only reader keeps "View", failed read or not', ()=>{
  const readOnly=build({overviewErrors:{loyalty:true,retention:true},writable:false,winbackWritable:false});
  /* 'View' was already non-asserting, which is why the new branch is placed AFTER it. */
  assert.equal(readOnly.word({key:'points',status:['Unavailable','warn']}),'View');
  assert.equal(readOnly.word({key:'bringback',status:['Unavailable','warn']}),'View');
  /* ...and 'Not included' still outranks read-only, exactly as V421 wrote it — on the tiles that
     reach that branch. */
  assert.equal(readOnly.word({key:'welcome',status:['Not included','off']}),'See plan');
  /* PINNED OBSERVATION, not an endorsement (audit A, A-REG-023). On points/stamps/tiers the
     growSetupEntryV301 branch fires BEFORE the label checks, so a 'Not included' tile on one of
     those three says "Set up" rather than "See plan" — V421's own comment says 'Not included'
     keeps its own word, and on these three keys it does not. That is PRE-EXISTING and is left
     exactly as it is: nestly_v456 was scoped to the Unavailable word. Pinned so the next reader
     finds it deliberately rather than by surprise, and so a future fix has to change this line
     on purpose. */
  assert.equal(readOnly.word({key:'points',status:['Not included','off']}),'Set up',
    'pre-existing: a setup-entry tile short-circuits before the Not-included branch');
  /* A reader who may write bring-back but not loyalty gets the split V421 built. */
  const split=build({overviewErrors:{loyalty:true,retention:true},writable:false,winbackWritable:true});
  assert.equal(split.word({key:'points',status:['Unavailable','warn']}),'View');
  assert.equal(split.word({key:'bringback',status:['Unavailable','warn']}),'Open',
    'the one topic this person may write gets the honest actionable word');
});
