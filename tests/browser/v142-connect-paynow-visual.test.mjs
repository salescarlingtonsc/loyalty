import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {buildV142Visual} from './generate-v142-connect-paynow-visual.mjs';

const fixture=readFileSync(new URL('./v142-connect-paynow-visual.html',import.meta.url),'utf8');
const metrics=JSON.parse(readFileSync(new URL('../../docs/qa/evidence/v142-connect-paynow-pos/metrics.json',import.meta.url),'utf8'));

test('V142 browser acceptance embeds the current production Record sale component',async()=>{
  assert.equal(await buildV142Visual(),fixture);
  assert.match(fixture,/Actual production Record sale renderer/);
  assert.match(fixture,/async function beginPaynowPaymentV142\(\)/);
  assert.doesNotMatch(fixture,/Simulate signed webhook confirmation/);
});

test('V142 exact QR and receipt pass desktop and 390px production-component acceptance',()=>{
  const sourceHash=fixture.match(/v142-production-source-sha256" content="([a-f0-9]{64})/)?.[1];
  for(const [name,width] of [['desktop',1440],['mobile390',390]]){
    const capture=metrics[name];
    assert.equal(capture.before.sourceHash,sourceHash);
    assert.equal(capture.before.viewport.clientWidth,width);
    assert.equal(capture.before.viewport.scrollWidth,width);
    assert.equal(capture.before.amountLocked,'Amount locked: SGD 10.00');
    assert.match(capture.before.qrExpiry,/valid for up to 1 hour/i);
    assert.equal(capture.before.qrVisible,true);
    assert.match(capture.before.qrRawData,/^000201/);
    assert.equal(capture.before.remoteQrImage,false);
    assert.equal(capture.before.receiptVisible,false);
    assert.equal(capture.after.receiptVisible,true);
    assert.equal(capture.after.printVisible,true);
    assert.equal(capture.after.printRequested,true);
    assert.equal(capture.after.servicePhoneVisible,false);
    assert.equal(capture.after.functionCalls.length,1);
    assert.equal(capture.after.functionCalls[0].name,'stripe-connect-command');
    assert.equal('amount' in capture.after.functionCalls[0].body,false);
    assert.equal('amount_cents' in capture.after.functionCalls[0].body,false);
    assert.ok(capture.after.rpcCalls.some(call=>call.name==='evaluate_checkout'));
    assert.ok(capture.after.rpcCalls.some(call=>call.name==='get_pos_paynow_attempt_v142'));
    assert.deepEqual(capture.after.errors,[]);
    assert.ok(capture.after.touchTargets.every(height=>height>=44));
  }
});
