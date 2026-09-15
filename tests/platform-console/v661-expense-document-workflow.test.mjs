import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(overrides={}){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect,...overrides};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('posted receipt and supplier-invoice evidence remains visible and linked',async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const [row]=Console.receiptArchiveRows([{
    id:'receipt-1',status:'posted',original_filename:'supplier-invoice.pdf',
    posted_at:'2026-08-31T04:00:00Z',expense_entry_id:'expense-1',
    extracted:{vendor_name:'Example Supplies',total_cents:4210,currency:'SGD',description:'Printer paper'}
  }]);
  assert.match(row.join(' '),/supplier-invoice\.pdf/);
  assert.match(row.join(' '),/expense-1/);
  assert.match(row.join(' '),/data-open-receipt="receipt-1"/);
});

test('the OCR worker reads every type the console can upload, and constrains what comes back',async()=>{
  const worker=await read('supabase/functions/accounting-receipt-ocr/index.ts');
  /* nestly_v985: the reader moved to Gemini, so these assert the CONTRACT rather than
     one provider's field names — every type the upload controls offer must be readable,
     the file must actually travel with the request, and the reply must be constrained
     JSON rather than prose. */
  for(const mime of ['image/jpeg','image/png','image/webp','image/heic','application/pdf']){
    assert.match(worker,new RegExp(`'${mime.replace('/','\\/')}'`),`${mime} must be readable`);
  }
  assert.match(worker,/inlineData: \{ mimeType: mime, data \}/);
  assert.match(worker,/responseMimeType: 'application\/json'/);
  assert.match(worker,/responseSchema: RESPONSE_SCHEMA/);
  /* transcription, not composition: the same receipt must read the same way twice */
  assert.match(worker,/temperature: 0,/);
  /* whatever the model returns is normalised before it is stored, never trusted raw */
  assert.match(worker,/normalizeExtraction\(extracted\)/);
  /* a provider error must reach the operator with its status, as the 401 did */
  assert.match(worker,/\$\{response\.status\}/);
  assert.doesNotMatch(worker,/A PDF still uploads[\s\S]{0,120}cannot be/);
});

test('view document opens a blank tab first and never navigates the console',async()=>{
  const opened=[],replaced=[];
  const popup={opener:{},location:{replace:url=>replaced.push(url)},close:()=>{}};
  const Console=await loadConsole({open:(...args)=>{opened.push(args);return popup}});
  const context={sb:{storage:{from:()=>({createSignedUrl:async()=>({data:{signedUrl:'https://private.example/signed'}})})}}};
  await Console.openStoredReceipt({storage_path:'receipts/aa/file.pdf'},context);
  assert.deepEqual(opened,[['about:blank','_blank']]);
  assert.deepEqual(replaced,['https://private.example/signed']);
  assert.equal(popup.opener,null);
});

test('receipt queues are read per status and claimed atomically with a stale lease',async()=>{
  const source=await read('app/platform-console.js');
  const migration=await read('db/migrations/20260831_nestly_v661_receipt_ocr_claim_lease.sql');
  for(const status of ['uploaded','processing','extracted','extraction_failed','posted'])assert.match(source,new RegExp(`'${status}'`));
  assert.match(source,/p_limit:200/);
  assert.match(migration,/set status='processing', extraction_claimed_at=now\(\)/);
  assert.match(migration,/for update skip locked/);
  assert.match(migration,/interval '5 minutes'/);
});

test('OCR drain refreshes only after demonstrated progress',async()=>{
  const Console=await loadConsole();
  assert.equal(Console.receiptReaderMadeProgress({error:new Error('503'),data:null}),false);
  assert.equal(Console.receiptReaderMadeProgress({error:null,data:{processed:0}}),false);
  assert.equal(Console.receiptReaderMadeProgress({error:null,data:{processed:1}}),true);
});

test('the everyday page separates capture from advanced accounting controls',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/title:'Expenses & documents'/);
  assert.match(source,/Scan or upload/);
  assert.match(source,/Recent document archive/);
  assert.match(source,/<details class="card"><summary><b>\$\{escapeHtml\(pt\('Advanced accounting & sales invoices'\)\)\}/);
  const receiptInput=source.match(/<input id="platformReceiptFile"[^>]+>/)?.[0]||'';
  assert.ok(receiptInput,'receipt input is missing');
  assert.doesNotMatch(receiptInput,/image\/heic/);
});
