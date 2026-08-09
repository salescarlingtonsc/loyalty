import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

// The exact string production put on screen before this was fixed.
const REAL_PRODUCTION_ERROR =
  '401 {"type":"error","error":{"type":"authentication_error",'+
  '"message":"API key is invalid."},"request_id":null}';

test('a provider error is never shown to the operator verbatim',async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const shown=Console.receiptUnreadableReason({extraction_error:REAL_PRODUCTION_ERROR});

  for(const leak of ['{"type"','authentication_error','request_id','401','API key']){
    assert.ok(!shown.includes(leak),
      `operator copy leaked the raw provider error fragment ${leak}: ${shown}`);
  }
  assert.match(shown,/key the figures in/);
});

test('a broken reader reads differently from an unreadable photo',async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const unavailable=Console.receiptUnreadableReason({extraction_error:REAL_PRODUCTION_ERROR});
  const unreadable=Console.receiptUnreadableReason({extraction_error:'image too blurry to parse'});

  // Both end in "key it in", but only one is worth chasing a fix for. Telling
  // them apart is the whole point.
  assert.notEqual(unavailable,unreadable);
  assert.match(unavailable,/unavailable/i);
  assert.match(unreadable,/could not be read/i);

  // Every way the reader itself can fail lands on the same operator message.
  for(const err of ['429 rate_limit_error','503 service unavailable',
    '400 {"error":{"message":"Your credit balance is too low"}}',
    'invalid_api_key','403 forbidden']){
    assert.equal(Console.receiptUnreadableReason({extraction_error:err}),unavailable,
      `expected a reader-unavailable message for ${err}`);
  }
  // No error text at all is not evidence the reader is broken.
  assert.equal(Console.receiptUnreadableReason({extraction_error:''}),unreadable);
  assert.equal(Console.receiptUnreadableReason({}),unreadable);
});

test('the failed row still offers Review & post, and keeps the raw error for debugging',async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const CUI={icon:()=>'',status:t=>t};
  const [row]=Console.receiptRows([{
    id:'r-1',original_filename:'image.jpg',status:'extraction_failed',
    extraction_error:REAL_PRODUCTION_ERROR,extracted:null}],CUI);

  const readAs=row[2],action=row[3];
  // Visible text only — attributes are stripped, because the rule is about what
  // the operator READS, not what the markup carries. The raw error is allowed
  // to live in title; it must never be rendered.
  const visible=readAs.replace(/<[^>]*>/g,'');
  assert.doesNotMatch(visible,/authentication_error|request_id|\{"type"/,
    `the visible cell leaked the raw error: ${visible}`);
  assert.match(visible,/key the figures in/);
  // Recoverable, but only on hover/inspection — not shouted at the operator.
  assert.match(readAs,/title="[^"]*API key is invalid/);
  // A receipt the reader could not handle must still be postable by hand,
  // otherwise a broken reader blocks the books entirely.
  assert.match(action,/data-post-receipt="r-1"/);
  assert.match(action,/data-discard-receipt="r-1"/);
});

test('the operator copy exists in Chinese and Malay',async()=>{
  const Console=await loadConsole();
  for(const locale of ['zh-CN','ms']){
    Console.setPlatformLocaleForTest(locale);
    for(const key of ['Reading is unavailable right now — key the figures in.',
      'Could not be read — key it in.']){
      assert.notEqual(Console.platformText(key),key,`${locale} is missing: ${key}`);
    }
  }
});
