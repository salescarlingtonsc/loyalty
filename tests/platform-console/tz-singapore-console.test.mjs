import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

// Owner ruling 2026-09-02: every date/time in Peekaa is Asia/Singapore, never
// browser-local or UTC. This covers the admin-console fixes TZ-C2-02..10:
// the two new sgLocalInputValue/sgLocalToIso helpers, and nextActionBucket's
// switch from browser-local midnight to Singapore midnight.

const root=new URL('../..',import.meta.url);

async function loadConsole(fixedNowIso){
  const source=await readFile(new URL('app/platform-console.js',root),'utf8');
  const RealDate=Date;
  const fixedNow=fixedNowIso?RealDate.parse(fixedNowIso):RealDate.now();
  class MockDate extends RealDate {
    constructor(...args){
      if(args.length===0)super(fixedNow);
      else super(...args);
    }
    static now(){return fixedNow}
  }
  const context={Object,URL,URLSearchParams,Intl,Date:MockDate,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('sgLocalInputValue renders the Singapore wall-clock datetime-local value for a UTC instant',async()=>{
  const Console=await loadConsole();
  assert.equal(
    Console.sgLocalInputValue('2026-09-10T17:30:00Z'),
    '2026-09-11T01:30'
  );
});

test('sgLocalToIso parses a datetime-local value as Singapore time',async()=>{
  const Console=await loadConsole();
  assert.equal(
    Console.sgLocalToIso('2026-09-11T01:30'),
    '2026-09-10T17:30:00.000Z'
  );
});

test('sgLocalInputValue and sgLocalToIso round-trip',async()=>{
  const Console=await loadConsole();
  const instant='2026-09-10T17:30:00Z';
  const local=Console.sgLocalInputValue(instant);
  assert.equal(Console.sgLocalToIso(local),new Date(instant).toISOString());
});

test('sgLocalToIso tolerates a value that already carries seconds or a zone',async()=>{
  const Console=await loadConsole();
  assert.equal(Console.sgLocalToIso('2026-09-11T01:30:00'),'2026-09-10T17:30:00.000Z');
  assert.equal(Console.sgLocalToIso('2026-09-11T01:30:00+08:00'),'2026-09-10T17:30:00.000Z');
  assert.equal(Console.sgLocalToIso(''),null);
});

test('nextActionBucket buckets on Singapore midnight, not browser-local midnight',async()=>{
  // "Now" is 2026-09-11T05:00:00Z = 2026-09-11T13:00 SGT, so Singapore's
  // calendar today is 2026-09-11. An item due 2026-09-10T16:30:00Z is
  // 2026-09-11T00:30 SGT — inside SG's "today", even though in UTC terms it
  // is still 2026-09-10.
  const Console=await loadConsole('2026-09-11T05:00:00Z');
  const bucket=Console.nextActionBucket({next_action_at:'2026-09-10T16:30:00Z'});
  assert.equal(bucket,'today');
});

test('nextActionBucket still finds overdue and next-7-days correctly against Singapore midnight',async()=>{
  const Console=await loadConsole('2026-09-11T05:00:00Z');
  // SG today starts 2026-09-11T00:00+08:00 = 2026-09-10T16:00:00Z.
  assert.equal(Console.nextActionBucket({next_action_at:'2026-09-10T15:59:00Z'}),'overdue');
  assert.equal(Console.nextActionBucket({next_action_at:'2026-09-15T10:00:00Z'}),'next_7_days');
  assert.equal(Console.nextActionBucket({next_action_at:'2026-09-25T10:00:00Z'}),'later');
  assert.equal(Console.nextActionBucket({}),'missing');
});

test('isoInput prefills datetime-local and date fields in Singapore time',async()=>{
  const Console=await loadConsole();
  assert.equal(Console.isoInput('2026-09-10T17:30:00Z'),'2026-09-11T01:30');
  assert.equal(Console.isoInput('2026-09-10T17:30:00Z',{date:true}),'2026-09-11');
});

test('singaporeIsoDate resolves the Singapore calendar day, not the UTC day',async()=>{
  const Console=await loadConsole();
  assert.equal(Console.singaporeIsoDate(new Date('2026-09-10T17:30:00Z')),'2026-09-11');
});

test('source guard: the fixed-line datetime-local write bug (TZ-C2-02..10) does not regress',async()=>{
  const source=await readFile(new URL('app/platform-console.js',root),'utf8');
  assert.doesNotMatch(source,/getTimezoneOffset/);
  assert.doesNotMatch(source,/toISOString\(\)\.slice\(0,\s*10\)/);
  assert.doesNotMatch(source,/new Date\(form\.get\(/);
  // Every remaining toLocaleDateString( call must carry an explicit Singapore
  // zone — a bare call falls back to the browser's zone. Parens can nest
  // (e.g. platformIntlLocale()), so balance them rather than regex-matching
  // up to the first ')'.
  const needle='toLocaleDateString(';
  let searchFrom=0;
  while(true){
    const start=source.indexOf(needle,searchFrom);
    if(start===-1)break;
    let depth=1,index=start+needle.length;
    while(depth>0&&index<source.length){
      if(source[index]==='(')depth++;
      else if(source[index]===')')depth--;
      index++;
    }
    const call=source.slice(start,index);
    assert.match(call,/timeZone:'Asia\/Singapore'/,`toLocaleDateString call missing SG timeZone: ${call}`);
    searchFrom=index;
  }
  assert.match(source,/function sgLocalInputValue/);
  assert.match(source,/function sgLocalToIso/);
});
