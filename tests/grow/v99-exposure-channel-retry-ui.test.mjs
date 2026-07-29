import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const start=app.indexOf('function pbResolveExposureRetryChannel');
const end=app.indexOf('function pbOpenIssueModal',start);
assert.ok(start>=0&&end>start,'retry-channel resolver must exist');
const source=app.slice(start,end);
const resolveChannel=new Function(`${source};return pbResolveExposureRetryChannel;`)();

test('first manual exposure attempt submits the channel displayed in confirmation',()=>{
  assert.deepEqual(resolveChannel([],'whatsapp'),{
    ok:true,channel:'whatsapp',reason:null
  });
});

test('same-channel retry preserves the originally confirmed channel',()=>{
  assert.deepEqual(resolveChannel(['sms','sms'],'sms'),{
    ok:true,channel:'sms',reason:null
  });
});

test('changed-channel retry is blocked before an older channel can be submitted',()=>{
  assert.deepEqual(resolveChannel(['whatsapp'],'email'),{
    ok:false,channel:'whatsapp',reason:'changed_retry_channel'
  });
  const modal=app.slice(app.indexOf('function pbOpenIssueModal'),app.indexOf('function pbProgressBar'));
  assert.ok(
    modal.indexOf('if(!retryChannel.ok)')<modal.indexOf("sb.rpc('attest_campaign_exposure_v99'"),
    'ambiguous changed-channel retry must stop before the attestation RPC'
  );
  assert.match(modal,/const channel=retryChannel\.channel/);
  assert.match(modal,/p_channel:attempt\.channel/);
});

test('mixed frozen-channel retries must be separated',()=>{
  assert.deepEqual(resolveChannel(['sms','email'],'email'),{
    ok:false,channel:null,reason:'mixed_retry_channels'
  });
});
