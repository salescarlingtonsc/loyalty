import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);

test('customer directory normalizes common Singapore phone formats to phone_norm',async()=>{
  const app=await readFile(new URL('app/index.html',root),'utf8');
  const source=app.match(/function normalizeSingaporeCustomerSearch\(value\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source,'missing Singapore customer-search normalizer');
  const normalize=vm.runInNewContext(`(()=>{${source};return normalizeSingaporeCustomerSearch})()`);
  assert.equal(normalize('81234567'),'81234567');
  assert.equal(normalize('+65 8123 4567'),'81234567');
  assert.equal(normalize('65-8123-4567'),'81234567');
  assert.equal(normalize('8123 4567'),'81234567');
  assert.equal(normalize('Lee 8123'),null);
  assert.equal(normalize('123'),null);
});

test('clients-only customer search uses tenant-scoped normalized phone data without Till access',async()=>{
  const app=await readFile(new URL('app/index.html',root),'utf8');
  const start=app.indexOf('async function clientsPage()');
  const end=app.indexOf('async function clientDetail(',start);
  const clients=app.slice(start,end);
  assert.ok(start>=0&&end>start);
  assert.match(clients,/sb\.from\('clients'\).*\.eq\('business_id',S\.biz\.id\)/s);
  assert.match(clients,/const phoneDigits=normalizeCustomerSearchPhoneDigits\(clientSearch\)/);
  assert.match(clients,/const phoneSearch=phoneDigits\.length>=4/);
  assert.match(clients,/clientQuery\.ilike\('phone_norm',`%\$\{phoneDigits\}%`\)/);
  assert.doesNotMatch(clients,/lookup_client_by_phone/);
  assert.doesNotMatch(clients,/canWriteModule\('till'\)/);
});
