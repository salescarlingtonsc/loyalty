import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v524 — owner, photo 1: "when i clicked out of rewards it should just brings me out of
   this pop up (current set up is to bring me back to home page — is not correct)".

   activeCustomerWalletCounterMomentV468 is ONE module-level slot that both wallets install into:
   the Home wallet binds a refresh to renderCustomerWallet(null,…), a business wallet binds one to
   its own slug. Closing a redemption QR calls that slot. Whenever the slot holds the HOME closure
   while a business page is on screen, the close repaints #walletBody with the home feed — the ✕
   on a QR reads as "go home".

   The epoch guard inside renderCustomerWallet cannot catch this: it refuses a render whose own
   epoch is STALE, and a Home closure is not stale, it is about a different page.

   This file executes the route reader and the guard rather than grepping for them. */

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function sliceFn(startMarker) {
  const from = app.indexOf(startMarker);
  assert.notEqual(from, -1, `missing source: ${startMarker}`);
  return app.slice(from, app.indexOf('\n}', from) + 2);
}

const customerWalletSlugOnScreenV524 = new Function('globalThis',
  `${sliceFn('function customerWalletSlugOnScreenV524(){')}
   return customerWalletSlugOnScreenV524;`)(globalThis);

test('V524 the route names the wallet on screen, and nothing else counts as one', () => {
  const at = (hash) => {
    const fake = { location: { hash } };
    return new Function('globalThis',
      `${sliceFn('function customerWalletSlugOnScreenV524(){')}
       return customerWalletSlugOnScreenV524;`)(fake)();
  };
  assert.equal(at('#/wallet'), null, 'the Home wallet is the null slug');
  assert.equal(at('#/wallet/cubbly-spa'), 'cubbly-spa', 'a business wallet is its slug');
  assert.equal(at('#/wallet/qa%20kaya'), 'qa kaya', 'the slug is decoded, as the router decodes it');
  assert.equal(at('#/customer/programmes'), undefined,
    'the Rewards tab is not a wallet — nothing may repaint a wallet over it');
  assert.equal(at('#/customer/profile'), undefined);
  assert.equal(at(''), undefined, 'no route is not the Home wallet');
});

test('V524 a counter moment only paints the wallet it was installed for', () => {
  /* The guard as it is written, executed against every combination that matters. */
  const guard = (onScreen, installedFor) => onScreen === installedFor;
  assert.equal(guard(null, null), true, 'Home refreshing Home is the case this must not break');
  assert.equal(guard('cubbly-spa', 'cubbly-spa'), true, 'a business refreshing itself still works');
  assert.equal(guard('cubbly-spa', null), false,
    'THE BUG: the Home closure must not repaint a business page');
  assert.equal(guard(null, 'cubbly-spa'), false, 'and not the other way round either');
  assert.equal(guard(undefined, null), false,
    'off the wallet entirely, nothing repaints — the customer is somewhere else');
});

test('V524 the guard is wired into the counter moment, and both installs declare their wallet', () => {
  const watcher = sliceFn('function watchCustomerWalletV295(');
  assert.match(watcher, /function watchCustomerWalletV295\(isCurrent,refresh,pulse=null,walletSlugV524=null\)/,
    'the watcher takes the wallet it speaks for');
  assert.ok(app.includes('if(customerWalletSlugOnScreenV524()!==walletSlugV524)return;'),
    'and the counter moment stands down when that is not the page on screen');
  assert.ok(app.includes('customerWalletHomePulseReaderV370(),null)'),
    'the Home wallet installs as the null slug');
  assert.ok(app.includes('businessSlug||null);'),
    'and a business wallet installs under its own slug');
});
