/* F101 — the WhatsApp Inbox unread badge clears when staff open a conversation (nestly_v688).

   Before v688 there was no route that could zero support_conversations_v530.unread_count without
   sending a reply, so a thread that needed no reply kept its "N new" pill forever. These tests
   extract the real source of supportMarkThreadReadV688 / supportUnreadCountV688 and of the list
   template, and EXECUTE them against a stub sb.rpc, so they fail when the behaviour regresses
   rather than when the wording changes. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

const buildMarkRead = rpcImpl => {
  const rpcCalls = [];
  const warnings = [];
  const src = section('const supportUnreadClearedV688=new Map();',
    '\nasync function supportInboxPageV531(hashParam){');
  const context = {
    console: { warn: (...args) => warnings.push(args) },
    sb: {
      rpc: async (name, args) => {
        rpcCalls.push({ name, args });
        return rpcImpl(name, args);
      },
    },
  };
  const api = vm.runInNewContext(
    `${src}; ({supportMarkThreadReadV688, supportUnreadCountV688, supportUnreadClearedV688})`,
    context);
  return { ...api, rpcCalls, warnings };
};

test('F101 opening a thread calls the v688 mark-read RPC with the business and conversation', async () => {
  const api = buildMarkRead(() => ({ data: { status: 'ok', cleared: 3 }, error: null }));
  assert.equal(await api.supportMarkThreadReadV688('biz-1', 'conv-1'), 3);
  assert.equal(api.rpcCalls.length, 1);
  assert.equal(api.rpcCalls[0].name, 'business_support_mark_read_v688');
  /* The args object is minted inside the vm realm, so compare fields rather than identity. */
  assert.equal(api.rpcCalls[0].args.p_business, 'biz-1');
  assert.equal(api.rpcCalls[0].args.p_conversation, 'conv-1');
});

test('F101 the list pill is recomputed to zero for a conversation this session cleared', async () => {
  const api = buildMarkRead(() => ({ data: { status: 'ok', cleared: 3 }, error: null }));
  const row = { conversation_id: 'conv-1', unread_count: 3 };
  assert.equal(api.supportUnreadCountV688(row), 3, 'before opening, the server count stands');
  await api.supportMarkThreadReadV688('biz-1', 'conv-1');
  assert.equal(api.supportUnreadCountV688(row), 0,
    'after opening, the pill is gone even if the list RPC still reports 3');
  assert.equal(api.supportUnreadCountV688({ conversation_id: 'conv-2', unread_count: 4 }), 4,
    'a different conversation is untouched');
});

test('F101 a refused or thrown mark-read never blocks reading the thread, and clears nothing', async () => {
  const refused = buildMarkRead(() => ({ data: null, error: { code: '42501', message: 'no' } }));
  assert.equal(await refused.supportMarkThreadReadV688('biz-1', 'conv-1'), null);
  assert.equal(refused.supportUnreadCountV688({ conversation_id: 'conv-1', unread_count: 3 }), 3,
    'a refusal must not fake the badge away');
  assert.equal(refused.warnings.length, 1, 'the failure is logged quietly, not thrown');

  const thrown = buildMarkRead(() => { throw new Error('offline'); });
  assert.equal(await thrown.supportMarkThreadReadV688('biz-1', 'conv-1'), null);
  assert.equal(thrown.warnings.length, 1);
});

test('F101 a missing business or conversation id sends no RPC at all', async () => {
  const api = buildMarkRead(() => ({ data: { cleared: 1 }, error: null }));
  assert.equal(await api.supportMarkThreadReadV688('', 'conv-1'), null);
  assert.equal(await api.supportMarkThreadReadV688('biz-1', ''), null);
  assert.equal(api.rpcCalls.length, 0);
});

test('F101 an unreadable count never renders a negative or NaN pill', () => {
  const api = buildMarkRead(() => ({ data: {}, error: null }));
  assert.equal(api.supportUnreadCountV688({ conversation_id: 'c', unread_count: null }), 0);
  assert.equal(api.supportUnreadCountV688({ conversation_id: 'c', unread_count: 'oops' }), 0);
  assert.equal(api.supportUnreadCountV688({ conversation_id: 'c', unread_count: -4 }), 0);
  assert.equal(api.supportUnreadCountV688(null), 0);
});

test('F101 the thread route marks read only after a successful load, and the list uses the helper', () => {
  const route = section('  if(conversationId){', '  const listResultV531=');
  const markIndex = route.indexOf('await supportMarkThreadReadV688(S.biz.id,conversationId);');
  const errorReturn = route.indexOf('if(threadResultV531.error){');
  assert.ok(markIndex > -1, 'the thread route calls the mark-read helper');
  assert.ok(errorReturn > -1 && errorReturn < markIndex,
    'the error branch returns before the mark-read call, so a failed load is not a read');
  assert.match(section('function supportRenderListV531(routeMain,rows){', '\n}\n'),
    /supportUnreadCountV688\(row\)>0/,
    'the "N new" pill reads the recomputed count, not the raw row');
});
