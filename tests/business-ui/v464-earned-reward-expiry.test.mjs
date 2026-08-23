/* nestly_v464 — owner-set expiry on EARNED stamp rewards (owner ruling R3(e), 2026-08-23).
 *
 * EXECUTING coverage of the four browser-side surfaces the ruling names, plus the refusal copy.
 * House rule: a source-regex test is vacuous — a grep stays green while the behaviour is dead. So
 * every assertion below RUNS the real code out of app/app.js:
 *
 *   1  the owner's "Edit settings" form on #/grow/points — the real growEarnRuleFormV359 template,
 *      rendered for a stamps firm and for a points firm;
 *   2  the real Save handler, called with a real (stubbed-transport) supabase client, so the RPC
 *      argument it actually sends is observed rather than described;
 *   3  the real customer reward card (rewardCardV422), so "Use by <date>" is a rendered string;
 *   4  the real customer stamp-card ladder (stampQuestNormaliseV323 + customerStampQuestBodyV323);
 *   5  the real availability-copy lookup and the real error mapper that carries the counter's
 *      refusal sentence to a member of staff.
 *
 * There is no jsdom in this repo, and none of these are modules — they are inline template
 * builders and inline handlers inside a 44k-line file. The harness therefore slices the REAL
 * source out of app/app.js (marker-delimited, with the boundaries asserted) and evaluates it with
 * an explicit scope. Nothing under test is stubbed; only its collaborators are, and only where
 * they are genuinely irrelevant (icon markup, a media URL).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

/* ------------------------------------------------------------------ source slicing */

function sliceBetween(src, startMarker, endMarker, label) {
  const i = src.indexOf(startMarker);
  assert.ok(i >= 0, `${label}: start marker not found — app.js moved under this test`);
  assert.equal(src.indexOf(startMarker, i + 1), -1, `${label}: start marker is not unique`);
  const j = src.indexOf(endMarker, i);
  assert.ok(j > i, `${label}: end marker not found after the start`);
  return src.slice(i, j + endMarker.length);
}

function extractFunction(src, name) {
  const m = new RegExp(`^function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `extractFunction: missing ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) {
    acc.push(line);
    if (line === '}') return acc.join('\n');
  }
  throw new Error(`extractFunction: no column-0 close for ${name}`);
}

function extractConst(src, name) {
  const lines = src.split('\n');
  const start = lines.findIndex(l => l.startsWith(`const ${name}=`));
  assert.ok(start >= 0, `extractConst: missing const ${name}`);
  const acc = [];
  for (let i = start; i < lines.length; i++) {
    acc.push(lines[i]);
    if (lines[i].trim().endsWith(';')) return acc.join('\n');
  }
  throw new Error(`extractConst: unterminated const ${name}`);
}

/* Shared, genuinely-uninteresting collaborators. `esc` and `walletDate` are the REAL ones. */
const escSrc = extractConst(app, 'esc');
const walletDateSrc = extractFunction(app, 'walletDate');
const pointTotalSrc = extractFunction(app, 'customerPointTotalV103');
const rewardDescSrc = extractFunction(app, 'customerRewardDescriptionV183');

/* ============================================================ 1 · the owner's form */

const formSrc = sliceBetween(
  app,
  '  const growEarnRuleFormV359=growEarnEditOpenV359?',
  "\n  </li>`:'';\n",
  'growEarnRuleFormV359',
);

function renderEarnForm({ isStamps, loyalty }) {
  const scope = {
    growEarnEditOpenV359: true,
    growPointsIsStampsV326: isStamps,
    snapshot: { loyalty },
    S: { biz: { currency: 'SGD' } },
    growEarnErrorV359: '',
    growEarnBusyV359: false,
  };
  const names = Object.keys(scope);
  const body = `${escSrc}\n${formSrc}\nreturn growEarnRuleFormV359;`;
  // eslint-disable-next-line no-new-func
  return new Function(...names, body)(...names.map(n => scope[n]));
}

test('V464 · the stamps Edit-settings form offers the optional reward expiry, in plain language', () => {
  const html = renderEarnForm({ isStamps: true, loyalty: { stamp_per_cents: 500 } });

  assert.match(html, /id="growEarnRewardExpiryModeV464"/,
    'the reward-expiry selector is not rendered for a stamps firm');
  assert.match(html, /<option value="none"[^>]*selected[^>]*>Rewards never expire<\/option>/,
    'with nothing saved the form must default to "never" — the ruling makes this optional');
  assert.match(html, /Rewards expire this many days after they are earned\. Leave it blank and they never expire\./,
    'the plain-language help sentence the ruling asks for is missing');
  assert.match(html, /Rewards your customers have already earned keep the rule they were earned under\./,
    'the form must say the change is not retroactive');

  // The days field is present but HIDDEN until the owner chooses the fixed mode.
  const daysRow = /data-grow-earn-reward-expiry-days-v464([^>]*)>/.exec(html);
  assert.ok(daysRow, 'the days row is missing');
  assert.match(daysRow[1], /\bhidden\b/, 'the days field must start hidden when nothing is set');

  // And it is a SEPARATE control from the card validity — the two clocks answer different
  // questions and v435 already paid for merging them once.
  assert.match(html, /id="growEarnValidityModeV435"/);
  assert.notEqual(
    html.indexOf('growEarnValidityModeV435'),
    html.indexOf('growEarnRewardExpiryModeV464'),
  );
});

test('V464 · a saved value comes back into the form, revealed and filled', () => {
  const html = renderEarnForm({ isStamps: true, loyalty: { stamp_per_cents: 500, stamp_reward_expiry_days: 45 } });
  assert.match(html, /<option value="fixed"[^>]*selected[^>]*>Rewards expire some days after they are earned<\/option>/);
  const daysRow = /data-grow-earn-reward-expiry-days-v464([^>]*)>/.exec(html);
  assert.doesNotMatch(daysRow[1], /\bhidden\b/, 'a saved value must reveal the days field');
  assert.match(html, /id="growEarnRewardExpiryDaysV464"[^>]*value="45"/);
});

test('V464 · NEGATIVE CONTROL — a points firm is never shown the stamp reward expiry', () => {
  const html = renderEarnForm({ isStamps: false, loyalty: { earn_points_per_dollar: 1 } });
  assert.doesNotMatch(html, /growEarnRewardExpiryModeV464/);
  assert.doesNotMatch(html, /growEarnRewardExpiryDaysV464/);
  // The points batch-expiry control it DOES own is untouched.
  assert.match(html, /id="growEarnExpiryModeV359"/);
});

/* ============================================================ 2 · the real Save handler */

const handlerSrc = sliceBetween(
  app,
  '  if(growEarnSave)growEarnSave.onclick=async()=>{',
  '\n  };\n',
  'growEarnSave.onclick',
);

async function runSave({ isStamps, fields }) {
  const calls = [];
  const scope = {
    growEarnSave: {},
    growEarnBusyV359: false,
    growPointsIsStampsV326: isStamps,
    growEarnErrorV359: '',
    growRerenderV322: () => {},
    isGrowCurrent: () => true,
    ownerErrorText: e => String(e?.message || e),
    toast: () => {},
    growEarnEditOpenV359: true,
    snapshot: { loyalty: {} },
    S: { biz: { id: 'biz-1' } },
    $: id => (id in fields ? { value: String(fields[id]) } : null),
    sb: { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { publish_status: 'published' }, error: null }); } },
  };
  const names = Object.keys(scope);
  const body = `${handlerSrc}\nreturn growEarnSave.onclick;`;
  // eslint-disable-next-line no-new-func
  const handler = new Function(...names, body)(...names.map(n => scope[n]));
  await handler();
  return { calls, snapshot: scope.snapshot };
}

test('V464 · Save sends the reward expiry the owner typed', async () => {
  const { calls, snapshot } = await runSave({
    isStamps: true,
    fields: {
      growEarnStampV359: '5.00',
      growEarnValidityModeV435: 'none',
      growEarnRewardExpiryModeV464: 'fixed',
      growEarnRewardExpiryDaysV464: '30',
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'business_set_earning_rule_v359');
  assert.equal(calls[0].args.p_stamp_reward_expiry_days, 30);
  assert.equal(snapshot.loyalty.stamp_reward_expiry_days, 30,
    'the local echo must show the owner their own change without a refetch');
});

test('V464 · "never" sends 0, not null — turning it OFF must be distinguishable from not mentioning it', async () => {
  const { calls, snapshot } = await runSave({
    isStamps: true,
    fields: {
      growEarnStampV359: '5.00',
      growEarnValidityModeV435: 'none',
      growEarnRewardExpiryModeV464: 'none',
    },
  });
  assert.equal(calls[0].args.p_stamp_reward_expiry_days, 0,
    'null means "leave it alone" server-side; clearing the rule has to send 0');
  assert.equal(snapshot.loyalty.stamp_reward_expiry_days, null);
});

test('V464 · an out-of-range expiry is refused in the browser and never reaches the server', async () => {
  for (const bad of ['0', '-5', '4000', 'soon']) {
    const { calls } = await runSave({
      isStamps: true,
      fields: {
        growEarnStampV359: '5.00',
        growEarnValidityModeV435: 'none',
        growEarnRewardExpiryModeV464: 'fixed',
        growEarnRewardExpiryDaysV464: bad,
      },
    });
    assert.equal(calls.length, 0, `"${bad}" days was sent to the server`);
  }
});

test('V464 · NEGATIVE CONTROL — a points save never sends a stamp reward expiry', async () => {
  const { calls } = await runSave({
    isStamps: false,
    fields: { growEarnPointsV359: '1', growEarnExpiryModeV359: 'none' },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.p_stamp_reward_expiry_days, null,
    'a points firm must leave the stamps policy alone, not clear it');
});

/* ============================================================ 3 · the customer reward card */

const rewardCardSrc = sliceBetween(
  app,
  '    const rewardCardV422=r=>{',
  '</article>`;\n    };\n',
  'rewardCardV422',
);

/* V469: V468-E4 gave every reward card a "?" that opens its rules, so rewardCardV422 now calls
   customerRewardHelpButtonV468. The harness evaluates the REAL card, so it needs the real helper
   too — stubbing it would let the card's own markup drift out from under this suite. It is pulled
   in whole rather than mocked for exactly that reason. */
const rewardHelpSrc = sliceBetween(
  app,
  'function customerRewardHelpButtonV468(attribute,value,label){',
  '\n}\n',
  'customerRewardHelpButtonV468',
);

function renderRewardCard(reward) {
  const scope = {
    rewardUnit: 'stamps',
    customerMediaUrlV95: () => '',
    CUI: { icon: () => '<svg></svg>' },
  };
  const names = Object.keys(scope);
  const body = `${escSrc}\n${walletDateSrc}\n${pointTotalSrc}\n${rewardDescSrc}\n${rewardHelpSrc}\n${rewardCardSrc}\nreturn rewardCardV422;`;
  // eslint-disable-next-line no-new-func
  return new Function(...names, body)(...names.map(n => scope[n]))(reward);
}

test('V464 · the customer sees the expiry date on an earned reward', () => {
  const html = renderRewardCard({
    action_key: 'r1', customer_name: 'Free Kopi', cost_points: 3,
    expires_at: '2026-09-21T02:00:00Z',
  });
  // walletDate() is the app's own en-SG / Asia-Singapore formatter, so the expected string is
  // computed the same way rather than hardcoded to one ICU spelling of September.
  const expected = new Date('2026-09-21T02:00:00Z')
    .toLocaleString('en-SG', { timeZone: 'Asia/Singapore', dateStyle: 'medium' });
  assert.ok(html.includes(`Use by ${expected}`),
    `the reward card does not print the server’s expiry date (expected "Use by ${expected}")`);
  assert.match(html, /data-reward-useby-v464="2026-09-21T02:00:00Z"/);
  // The date is the SERVER's, printed — never recomputed from a day count in the browser.
  assert.doesNotMatch(html, /Use by NaN|Use by Invalid/);
});

test('V464 · NEGATIVE CONTROL — no expiry, no line (the default, and every card open today)', () => {
  const html = renderRewardCard({ action_key: 'r1', customer_name: 'Free Kopi', cost_points: 3 });
  assert.doesNotMatch(html, /Use by/);
  assert.doesNotMatch(html, /data-reward-useby-v464/);
  assert.match(html, /Free Kopi/, 'the card must otherwise render exactly as before');
});

test('V464 · the claim-window sentence and the earned-reward deadline are different things', () => {
  const html = renderRewardCard({
    action_key: 'r1', customer_name: 'Free Kopi', cost_points: 3,
    expires_at: '2026-09-21T02:00:00Z', entitlement_expiry_days: 14,
  });
  assert.match(html, /Use by 21 Sept? 2026/);
  assert.match(html, /Use within 14 days after claim\./);
});

/* ============================================================ 4 · the stamp-card ladder */

const questNormaliseSrc = extractFunction(app, 'stampQuestNormaliseV323');
const questBodySrc = extractFunction(app, 'customerStampQuestBodyV323');
const questRingsSrc = extractFunction(app, 'customerStampQuestRingsV323');
const ringLimitSrc = extractConst(app, 'PROGRAMME_STACK_RING_LIMIT_V310');
/* The REAL English copy table, read out of app.js rather than restated here, so a copy change
   that breaks these keys breaks this test instead of silently passing. */
const copyEn = (() => {
  const start = app.indexOf('const CUSTOMER_COPY=Object.freeze({');
  assert.ok(start > 0, 'CUSTOMER_COPY moved');
  const end = app.indexOf("\n  'zh-CN':Object.freeze({", start);
  assert.ok(end > start, 'the English locale block in CUSTOMER_COPY moved');
  const block = app.slice(start, end);
  assert.ok(block.includes("stampsRewardExpired:'Expired',"),
    'the v464 wallet copy is not in the English table');
  const out = {};
  for (const m of block.matchAll(/^\s{4}(\w+):'((?:[^'\\]|\\.)*)',$/gm)) out[m[1]] = m[2];
  return out;
})();

function renderQuestBody(card) {
  const scope = {
    ct: (key, vars = {}) => {
      const s = copyEn[key];
      assert.ok(s !== undefined, `wallet copy key "${key}" is missing from the English table`);
      return s.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? ''));
    },
  };
  const names = Object.keys(scope);
  const body = `${escSrc}\n${walletDateSrc}\n${pointTotalSrc}\n${ringLimitSrc}\n`
    + `${questRingsSrc}\n${questNormaliseSrc}\n${questBodySrc}\n`
    + 'return card=>customerStampQuestBodyV323(stampQuestNormaliseV323(card));';
  // eslint-disable-next-line no-new-func
  return new Function(...names, body)(...names.map(n => scope[n]))(card);
}

const baseCard = {
  enabled: true, contract: 'v323', unit: 'stamps', slots: 5, filled: 4,
  cycle_index: 0, running: true, ready: false,
};

test('V464 · the stamp-card ladder prints the deadline on an earned gift', () => {
  const html = renderQuestBody({
    ...baseCard,
    milestones: [{ slot: 3, name: 'Free Kopi', availability: 'available_at_counter',
      claimed_this_cycle: false, stamps_to_go: 0, expires_at: '2026-09-21T02:00:00Z' }],
  });
  assert.match(html, /Use by 21 Sept? 2026/);
  assert.match(html, /data-stamp-quest-rung-expires-v464="2026-09-21T02:00:00Z"/);
  assert.match(html, /data-stamp-quest-rung-state-v464="useby"/);
});

test('V464 · an expired gift says so, on the server’s verdict and not the browser’s clock', () => {
  const html = renderQuestBody({
    ...baseCard,
    milestones: [{ slot: 3, name: 'Free Kopi', availability: 'reward_expired',
      claimed_this_cycle: false, stamps_to_go: 0, expires_at: '2020-01-01T00:00:00Z' }],
  });
  assert.match(html, /data-stamp-quest-rung-state-v464="expired"/);
  assert.match(html, /Expired/);
  assert.doesNotMatch(html, /Use by/,
    'an expired gift must not still be advertising a date to use it by');
});

test('V464 · NEGATIVE CONTROL — a gift with no deadline, and one not yet earned, say nothing new', () => {
  const noDeadline = renderQuestBody({
    ...baseCard,
    milestones: [{ slot: 3, name: 'Free Kopi', availability: 'available_at_counter',
      claimed_this_cycle: false, stamps_to_go: 0 }],
  });
  assert.doesNotMatch(noDeadline, /Use by|Expired/);
  assert.doesNotMatch(noDeadline, /data-stamp-quest-rung-expires-v464/);

  // A future milestone the customer has NOT reached carries no date even when the firm set one:
  // the server sends expires_at only once the reward has actually been earned.
  const notEarned = renderQuestBody({
    ...baseCard,
    milestones: [{ slot: 5, name: 'Big Gift', availability: 'insufficient_stamps',
      claimed_this_cycle: false, stamps_to_go: 1 }],
  });
  assert.doesNotMatch(notEarned, /Use by|Expired/);
});

/* ============================================================ 5 · the words on both sides */

test('V464 · the customer surfaces name the expired state instead of falling back to "not right now"', () => {
  const copySrc = extractConst(app, 'CUSTOMER_REWARD_AVAILABILITY_COPY_V399');
  const lineSrc = extractFunction(app, 'customerRewardAvailabilityLineV399');
  // eslint-disable-next-line no-new-func
  const line = new Function(`${copySrc}\n${lineSrc}\nreturn customerRewardAvailabilityLineV399;`)();
  assert.equal(line({ availability: 'reward_expired' }), 'This reward has expired');
  // The safe default is intact for anything the client does not know (v399's rule).
  assert.equal(line({ availability: 'something_new' }), 'Not available right now');
  assert.equal(line({ availability: 'available_at_counter' }), 'Available at counter');
});

test('V464 · the counter’s refusal reaches a member of staff as a plain sentence', () => {
  const errCopySrc = extractConst(app, 'WORKSPACE_ERROR_COPY_V295');
  const noiseSrc = extractConst(app, 'PROVIDER_NOISE_V295');
  const humanSrc = extractFunction(app, 'humanErrorV295');
  // eslint-disable-next-line no-new-func
  const human = new Function('workspaceTranslationV97',
    `${errCopySrc}\n${noiseSrc}\n${humanSrc}\nreturn humanErrorV295;`)(s => s);

  // The exact sentence app.redeem_reward_core raises (proven by the executed SQL suite:
  // db/tests/executed/v464_earned_reward_expiry.sql, phase C5).
  const refusal = 'this reward expired on 24 Jul 2026';
  assert.equal(human({ message: refusal }, 'That redemption could not be completed.'), refusal,
    'a machine code would be swallowed by the fallback — this must reach the till verbatim');
  assert.equal(
    human({ message: 'this reward has expired and can no longer be claimed' }, 'fallback'),
    'this reward has expired and can no longer be claimed');
});

/* ============================================================ 6 · the History list */

const historySrc = sliceBetween(
  app,
  '    const renderRewardHistoryV422=(state,items=[])=>{',
  '\n    };\n',
  'renderRewardHistoryV422',
);

function renderHistory(items) {
  const panel = { innerHTML: '', querySelectorAll: () => [] };
  const scope = {
    host: { querySelector: sel => (sel.includes('history') ? panel : null) },
    rewardUnit: 'stamps',
    customerMediaUrlV95: () => '',
    CUI: { icon: () => '<svg></svg>' },
    entitlementSourceChipV429: { welcome: 'Welcome gift', bringback: 'We miss you', referral: 'Referral' },
  };
  const names = Object.keys(scope);
  const body = `${escSrc}\n${walletDateSrc}\n${pointTotalSrc}\n${historySrc}\n`
    + 'return renderRewardHistoryV422;';
  // eslint-disable-next-line no-new-func
  new Function(...names, body)(...names.map(n => scope[n]))('ready', items);
  return panel.innerHTML;
}

test('V464 · a reward lost to its deadline appears in History as Expired, never as Claimed', () => {
  const html = renderHistory([{
    id: 'e1', source: 'expired', reward_name: 'Free Kopi',
    redeemed_at: '2026-07-24T02:00:00Z', expired_at: '2026-07-24T02:00:00Z',
    points_spent: 0, consumes_balance: false,
  }]);
  assert.match(html, /data-reward-expired-v464="1"/);
  assert.match(html, /<span class="pill">Expired<\/span>/);
  assert.doesNotMatch(html, /<span class="pill">Claimed<\/span>/,
    'an expired reward must not claim the customer received something');
  assert.match(html, /Free Kopi/);
  assert.match(html, /24 Jul 2026/, 'the date shown is the day it expired');
  assert.doesNotMatch(html, /stamps<\/p>/, 'nothing was spent, so no cost line');
});

test('V464 · NEGATIVE CONTROL — the other four History sources are unchanged', () => {
  const claimed = renderHistory([{
    id: 'r1', source: 'reward', reward_name: 'Free Kopi',
    redeemed_at: '2026-07-24T02:00:00Z', points_spent: 3, consumes_balance: true,
  }]);
  assert.match(claimed, /<span class="pill">Claimed<\/span>/);
  assert.doesNotMatch(claimed, /Expired/);
  assert.doesNotMatch(claimed, /data-reward-expired-v464/);

  const welcome = renderHistory([{
    id: 'w1', source: 'welcome', reward_name: 'Welcome drink',
    redeemed_at: '2026-07-24T02:00:00Z', points_spent: 0, consumes_balance: false,
  }]);
  assert.match(welcome, /<span class="pill">Claimed<\/span>/);
  assert.match(welcome, /data-reward-source-v429="welcome"/,
    'v429’s source chip must survive');
});
