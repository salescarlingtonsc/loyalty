import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V242 ecosystem business directory (owner: "customer to view all businesses - within the
   ecosystem - then show (not set up) for businesses that they yet to scan QRcode. and they
   able to see each customised points (existing infrastructure). the rewards are customised to
   each company and not shared."). The rules this suite protects:
   - a business the customer has NOT joined is SHOWN, never linked and never given a balance;
   - a joined business shows ITS OWN points and opens ITS OWN wallet through the same
     #/wallet/<slug> route the linked-programme tiles use — no cross-business total anywhere;
   - the directory is a second round trip that Home never waits on. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const appCss = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = appJs.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

const directorySource = section(
  'function customerBusinessDirectoryHostV242',
  'let customerDirectoryEpochV242',
);
const mountSource = section(
  'function mountCustomerBusinessDirectoryV242',
  '\n/* v194 (owner struck both cards out on Home)',
);
const homeRender = section(
  'function renderActionableWalletHome',
  'async function renderCustomerWallet',
);

const escFn = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const directory = new Function('esc', `${directorySource}; return customerBusinessDirectoryMarkupV242;`)(escFn);

const joinedRow = {business_id:'b-1',name:'Cubbly',slug:'cubbly',industry:'Cafe',joined:true,points_balance:77877};
const unjoinedRow = {business_id:'b-2',name:'AhXiang Bakery',slug:'ahxiang',industry:'Bakery',joined:false,points_balance:null};

test('the directory calls the live RPC and Home never waits on it', () => {
  assert.match(mountSource, /customerRpc\('customer_list_business_directory_v242'\)/);
  /* Home's blocking reads are the Promise.all batches; the directory must not be one of them. */
  const wallet = section('async function renderCustomerWallet', 'async function renderCustomerInAppInbox');
  for (const batch of wallet.match(/Promise\.all\(\[[\s\S]*?\]\)/g) || []) {
    assert.doesNotMatch(batch, /customer_list_business_directory_v242/,
      'the directory must load after Home paints, never inside a batch Home awaits');
  }
  /* Home paints an empty host synchronously, then fills it. */
  assert.match(homeRender, /insertAdjacentHTML\('beforeend',customerBusinessDirectoryHostV242\(\)\)/);
  assert.match(homeRender, /if\(isHome\)mountCustomerBusinessDirectoryV242\(\);/);
  assert.match(directorySource, /id="customerBusinessDirectoryV242"/);
  assert.match(mountSource, /host\.innerHTML=customerBusinessDirectoryMarkupV242\(\{status:'loading',rows:\[\]\}\)/);
  /* A stale in-flight reply must not overwrite a newer render. */
  assert.match(mountSource, /epoch!==customerDirectoryEpochV242/);
});

test('the section is titled for the whole ecosystem and tells the customer how to join', () => {
  const html = directory({status:'ready',rows:[joinedRow,unjoinedRow]});
  assert.match(html, /All businesses/);
  assert.match(html, /Every business on Peekaa\. Scan a shop’s QR in store to start earning there\./);
});

test('a joined business shows its own points and opens its own wallet', () => {
  const html = directory({status:'ready',rows:[joinedRow]});
  assert.match(html, /href="#\/wallet\/cubbly"/, 'joined rows reuse the existing wallet route');
  assert.match(html, /77,877 points/, 'the balance is that business’s own, formatted');
  assert.match(html, />Member</);
  assert.doesNotMatch(html, /Not set up/);
});

test('a business the customer has not scanned into is shown, not linked, and has no points', () => {
  const html = directory({status:'ready',rows:[unjoinedRow]});
  assert.match(html, /Not set up/);
  assert.match(html, /Scan their QR in store to join\./);
  assert.doesNotMatch(html, /<a[^>]*ahxiang/, 'an unjoined business must not be tappable into a wallet');
  assert.doesNotMatch(html, /href=/);
  assert.doesNotMatch(html, /points/, 'no balance exists for a business the customer never joined');
  assert.match(html, /AhXiang Bakery/);
});

test('the isolation guarantee is stated to the customer', () => {
  assert.match(directory({status:'ready',rows:[joinedRow,unjoinedRow]}),
    /Points and rewards are separate for every business\./);
  /* Nothing on this surface may add balances together. */
  assert.doesNotMatch(directorySource, /reduce\(/);
});

test('only identical business ids are deduplicated; same-name businesses both survive', () => {
  const twin = {...joinedRow, business_id:'b-3', slug:'cubbly-east', points_balance:12};
  const html = directory({status:'ready',rows:[joinedRow, {...joinedRow}, twin]});
  assert.equal(html.split('data-directory-business="b-1"').length - 1, 1);
  assert.equal(html.split('data-directory-business="b-3"').length - 1, 1);
  assert.equal(html.split('customer-directory-row').length - 1, 2);
});

test('demo and QA tenants are not filtered out of the ecosystem view', () => {
  const html = directory({status:'ready',rows:[{business_id:'b-9',name:'QA Test Cafe',slug:'qa-test-cafe',industry:'Cafe',joined:false,points_balance:null}]});
  assert.match(html, /QA Test Cafe/);
});

test('loading, empty and error states are all honest, and the error offers a retry', () => {
  assert.match(directory({status:'loading',rows:[]}), /Loading businesses…/);
  assert.match(directory({status:'ready',rows:[]}), /No businesses to show yet\./);
  const failed = directory({status:'error',rows:[]});
  assert.match(failed, /Businesses couldn’t load\./);
  assert.match(failed, /id="customerDirectoryRetry"/);
  assert.doesNotMatch(failed, /Not set up|points/, 'a failed read must never be drawn as data');
  assert.match(mountSource, /retry\.onclick=\(\)=>mountCustomerBusinessDirectoryV242\(\)/);
  assert.match(mountSource, /\.catch\(\(\)=>paint\(\{status:'error',rows:\[\]\}\)\)/);
});

test('business names and industries from the server are escaped', () => {
  const html = directory({status:'ready',rows:[{business_id:'b-x',name:'<img src=x>',slug:'"><script>1</script>',industry:'<script>2</script>',joined:true,points_balance:5}]});
  assert.doesNotMatch(html, /<img src=x>/);
  assert.doesNotMatch(html, /<script>/);
});

test('v97: the directory carries no interpolated accessibility attributes', () => {
  assert.equal(
    (directorySource.match(/\b(?:aria-label|title|placeholder)="[^"\n]*\$\{/g) || []).length,
    0,
    'customer-surface accessible names must be static or visible text, never interpolated',
  );
  assert.doesNotMatch(mountSource, /(?:\.ariaLabel|\.title|\.placeholder)\s*=/);
  /* Merchant-supplied names stay out of the workspace localizer. */
  assert.match(directorySource, /<h3 data-merchant-content>\$\{esc\(name\)\}<\/h3>/);
});

test('the section has 390px-safe styling reusing the customer card system', () => {
  assert.match(appCss, /\.customer-directory-v242\{/);
  assert.match(appCss, /\.customer-directory-row\{[^}]*flex-wrap:wrap/);
  assert.match(appCss, /@media\(max-width:400px\)\{\.customer-directory-side/);
  assert.match(directorySource, /class="card customer-directory-row/);
  assert.match(directorySource, /class="pill customer-directory-pill"/);
});
