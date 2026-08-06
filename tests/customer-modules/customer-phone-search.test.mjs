import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);

test('customer directory normalizes common Singapore phone formats to phone_norm',async()=>{
  const app=((await readFile(new URL('app/index.html',root),'utf8'))+'\n'+(await readFile(new URL('app/app.js',root),'utf8')));
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

test('clients-only customer search uses the tenant-scoped customer reader without Till access',async()=>{
  const app=((await readFile(new URL('app/index.html',root),'utf8'))+'\n'+(await readFile(new URL('app/app.js',root),'utf8')));
  const start=app.indexOf('async function clientsPage()');
  const end=app.indexOf('async function clientDetail(',start);
  const clients=app.slice(start,end);
  assert.ok(start>=0&&end>start);
  /* The customer directory must read through a tenant-scoped, versioned RPC rather than a raw
     table query. The VERSION deliberately is not pinned: this reader has moved v129 -> v154 ->
     v155 and each bump broke this assertion without anything actually regressing. What matters
     is the shape, so that is what is asserted. */
  assert.match(clients,/sb\.rpc\('staff_list_customers_v\d+'/);
  assert.match(clients,/const customerRpcSearch=normalizeCustomerSearchPhoneDigits\(clientSearch\)\|\|clientSearch/);
  assert.match(clients,/const customerDirectoryPage=[\s\S]{0,400}sb\.rpc\('staff_list_customers_v\d+',\{[\s\S]{0,120}p_business:S\.biz\.id,p_search:search\|\|null/);
  /* The inactivity filter must span the WHOLE directory, not just the page on screen — a
     "60+ days" list filtered from one page would quietly under-report who has lapsed. It used
     to be a server-side p_inactive_days argument; it is now a full paged fetch followed by a
     client-side bucket filter. Either is fine; filtering a single page is not, so that is what
     this pins. */
  assert.match(clients,/customerDirectoryPage\(customerRpcSearch,null,clientPage\*CLIENT_PAGE_SIZE\)/);
  assert.match(clients,/if\(clientInactiveBucket\)\{[\s\S]{0,200}await allCustomerDirectoryRows\(\)/,
    'a selected inactivity bucket must filter the full directory');
  assert.match(clients,/while\(total===null\|\|offset<total\)/,
    'the full-directory read must page until it has every row');
  assert.doesNotMatch(clients,/lookup_client_by_phone/);
  assert.doesNotMatch(clients,/canWriteModule\('till'\)/);
});
