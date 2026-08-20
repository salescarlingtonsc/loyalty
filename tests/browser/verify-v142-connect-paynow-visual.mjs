/* Recapture for docs/qa/evidence/v142-connect-paynow-pos/metrics.json.
   v142's acceptance test pins CAPTURED Chrome measurements to the fixture's source hash, and the
   fixture embeds the production stylesheet — so any edit to app/index.html's <style> or to the
   Record sale renderer stales it, and regenerating the fixture alone flips the test red. Until
   nestly_v401 there was no script to recapture with, which left hand-editing the hash as the only
   apparent way out; that would assert measurements nobody took.
   So this drives the real flow instead: phone -> Next -> catalogue item -> Review sale -> PayNow QR
   -> Record sale -> (stubbed confirmation) -> Print receipt, reading window.v142Metrics() before
   and after, at 1440 and 390. It ASSERTS the suite's own acceptance conditions before it writes,
   so a half-driven flow fails loudly rather than committing plausible-looking evidence.

   Usage:
     node -e "..." # serve the repo root on a port you have verified is yours, then:
     V142_FIXTURE_URL=http://127.0.0.1:<port>/tests/browser/v142-connect-paynow-visual.html \
     PLAYWRIGHT_MODULE=<path>/playwright-core/index.js \
     PLAYWRIGHT_EXECUTABLE_PATH=<chrome> node tests/browser/verify-v142-connect-paynow-visual.mjs */
import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';
import {readFileSync} from 'node:fs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const base=process.env.V142_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v142-connect-paynow-visual.html';
const fixture=readFileSync(new URL('./v142-connect-paynow-visual.html',import.meta.url),'utf8');
const expectedHash=fixture.match(/v142-production-source-sha256" content="([a-f0-9]{64})/)?.[1];
assert.ok(expectedHash,'fixture carries no source hash — regenerate it first');

const evidenceDir=new URL('../../docs/qa/evidence/v142-connect-paynow-pos/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});

const drive=async(page)=>{
  await page.waitForSelector('#tPhone',{timeout:20000});
  await page.fill('#tPhone','81863833');
  await page.click('#tFind');
  /* Review sale does not exist until the cart has a line — the button is rendered by the same
     draw() that the item click triggers, so waiting for it before adding anything hangs. */
  await page.waitForSelector('text=Harbour Lunch Set',{timeout:20000});
  await page.click('text=Harbour Lunch Set');
  await page.waitForSelector('#tGoReviewV373',{timeout:20000});
  await page.click('#tGoReviewV373');
  await page.waitForSelector('text=PayNow QR',{timeout:20000});
  await page.click('text=PayNow QR');
  await page.waitForSelector('#tCartConfirm',{timeout:20000});
  await page.click('#tCartConfirm');
  await page.waitForSelector('#tPaynowQrV142',{timeout:20000});
};

const browser=await chromium.launch({headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
const out={};
try{
  for(const [name,width,height] of [['desktop',1440,1100],['mobile390',390,844]]){
    const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
    const consoleErrors=[];
    page.on('console',m=>{if(m.type()==='error')consoleErrors.push(m.text())});
    await page.goto(base,{waitUntil:'networkidle'});
    await drive(page);
    const before=await page.evaluate(()=>window.v142Metrics());
    await page.waitForSelector('#tPrintReceiptV142',{timeout:20000});
    await page.click('#tPrintReceiptV142');
    await page.waitForTimeout(400);
    const after=await page.evaluate(()=>window.v142Metrics());

    /* The suite's own conditions, asserted here so a broken drive cannot write evidence. */
    assert.equal(before.sourceHash,expectedHash,`${name}: fixture hash drifted mid-capture`);
    assert.equal(before.viewport.clientWidth,width,`${name}: wrong viewport`);
    assert.equal(before.viewport.scrollWidth,width,`${name}: horizontal overflow`);
    assert.equal(before.amountLocked,'Amount locked: SGD 10.00',`${name}: amount not locked`);
    assert.match(before.qrExpiry,/valid for up to 1 hour/i,`${name}: expiry copy missing`);
    assert.equal(before.qrVisible,true,`${name}: QR not shown`);
    assert.match(before.qrRawData,/^000201/,`${name}: QR payload is not an EMVCo string`);
    assert.equal(before.remoteQrImage,false,`${name}: QR must not be a remote image`);
    assert.equal(before.receiptVisible,false,`${name}: receipt shown too early`);
    assert.equal(after.receiptVisible,true,`${name}: receipt never appeared`);
    assert.equal(after.printVisible,true,`${name}: print action missing`);
    assert.equal(after.printRequested,true,`${name}: print not requested`);
    assert.equal(after.servicePhoneVisible,false,`${name}: service phone leaked onto the receipt`);
    assert.equal(after.functionCalls.length,1,`${name}: expected exactly one edge command`);
    assert.equal(after.functionCalls[0].name,'stripe-connect-command');
    assert.equal('amount' in after.functionCalls[0].body,false,`${name}: client sent an amount`);
    assert.equal('amount_cents' in after.functionCalls[0].body,false,`${name}: client sent an amount`);
    assert.ok(after.rpcCalls.some(c=>c.name==='evaluate_checkout'),`${name}: no evaluate_checkout`);
    assert.ok(after.rpcCalls.some(c=>c.name==='get_pos_paynow_attempt_v142'),`${name}: no attempt read`);
    assert.deepEqual(after.errors,[],`${name}: page reported errors`);
    assert.ok(after.touchTargets.every(t=>t>=44),`${name}: a touch target is under 44px`);
    /* The suite's contract is the page's own error list, asserted above. Console noise from the
       static harness (a favicon the fixture does not ship) is not product behaviour, so it is
       reported rather than asserted. */
    if(consoleErrors.length)process.stderr.write(`${name}: console noise ${JSON.stringify(consoleErrors)}\n`);

    await page.screenshot({path:new URL(`./v142-${name}.png`,evidenceDir).pathname,fullPage:true});
    out[name]={before,after};
    await page.close();
  }
  await writeFile(new URL('./metrics.json',evidenceDir),`${JSON.stringify(out,null,2)}\n`);
  process.stdout.write(`${JSON.stringify({status:'PASS',sourceHash:expectedHash},null,2)}\n`);
}finally{await browser.close()}
