/**
 * nestly_v922 — the workspace realtime channel repairs itself, and does NOT storm doing it.
 *
 * THE DEFECT. ensureRealtimeChannel() subscribed with no status callback and gated re-entry on
 * OBJECT IDENTITY: `if(rtChannel&&rtChannelBizId===S.biz.id) return`. sb.channel(...).subscribe()
 * returns the channel whether or not the join succeeded, and the slots were assigned
 * unconditionally — so a channel that errored while joining was recorded as the live one and
 * nothing ever rebuilt it. One bad second at open cost the session its notifications, its booking
 * pop-ups and its badges, silently, until reload.
 *
 * THE STORM (audit F052, learned on the customer side at v498). removeChannel() calls leave(),
 * which fires phx_close, and subscribe() registers _onClose(()=>cb('CLOSED')) — so every rebuild
 * makes the OLD channel report CLOSED. A callback that reads CLOSED as failure answers with
 * another rebuild; the new channel joins and resets the counter without cancelling the timer
 * already queued; that timer removes the healthy channel; its CLOSED queues the next. SUBSCRIBED
 * keeps resetting the counter so the cap is never reached, and the tab churns channels every ~2s
 * forever. A naive rejoin loop is WORSE than no rejoin loop. Both brakes are asserted here.
 *
 * EVERY ASSERTION EXECUTES THE REAL PRODUCT CODE. The functions are lifted out of app/app.js by
 * source slice and instantiated with `new Function`, the technique used across this repo (see
 * tests/release-blockers/rewards-programmes.test.mjs). Nothing here is a regex over source: a grep
 * stays green while the behaviour under it dies, and this file exists precisely because the thing
 * it guards is a callback nobody can see.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const slice = (startRe, endMarker) => {
  const start = app.search(startRe);
  assert.ok(start >= 0, `missing slice start: ${startRe}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing slice end: ${endMarker}`);
  return app.slice(start, end);
};

/* The rejoin machinery, verbatim, plus killChannels — which is the teardown half of the same
   contract and lives in a different bundle chunk. */
const rejoinSrc = slice(/^let rtRetriesV922=0,rtRetryTimerV922=0;/m, '\nfunction killChannels(){');
const killSrc = slice(/^function killChannels\(\)\{/m, '\n/* ---------- V329');

/** A controllable fake of the bits of supabase-js this code touches. */
function harness({ bizId = 'biz-A', userId = 'user-1' } = {}) {
  const log = [];
  const timers = new Map();
  let nextTimer = 1;
  const built = [];

  const fakeSetTimeout = (fn, ms) => { const id = nextTimer++; timers.set(id, { fn, ms }); return id; };
  const fakeClearTimeout = id => { timers.delete(id); };
  const runTimer = id => { const t = timers.get(id); assert.ok(t, `timer ${id} is not pending`); timers.delete(id); t.fn(); };
  const runAllTimers = () => { for (const id of [...timers.keys()]) runTimer(id); };

  /* Models the pinned supabase-js 2.110.7 faithfully on the three points that decide this change:
       1. channel() DEDUPES BY TOPIC against channels still in the client registry;
       2. removeChannel() -> unsubscribe() -> leave(), and leave() fires the close SYNCHRONOUSLY
          when the channel cannot push (`if(!this.canPush()){leavePush.trigger("ok",{})}`) — which
          is the normal case for the dead channels this code tears down;
       3. the channel drops itself from the registry from its own onClose.
     Point 2 is why the close is emitted INSIDE removeChannel, before the caller's next statement.
     An earlier version of this harness delivered it afterwards, from a helper the test called, and
     that deferral asserted away a real ordering bug in killChannels: it made the product look
     correct because by the time CLOSED arrived the slot had already been nulled. A harness that
     chooses when the dangerous event happens proves nothing about code that must survive it
     happening at the worst moment.
     closeLands=false models the other case — a still-pushable channel, whose close (and registry
     drop) land later — which is the window in which channel() can hand back the discarded object. */
  const registry = new Map();
  const sb = {
    closeLands: true,
    channel(name) {
      log.push(`channel:${name}`);
      if (registry.has(name)) return registry.get(name);
      const channel = {
        name, state: 'joining', removed: false, cb: null, ons: 0,
        on() { channel.ons += 1; return channel; },
        subscribe(cb) { channel.cb = cb; return channel; },
      };
      built.push(channel);
      registry.set(name, channel);
      return channel;
    },
    removeChannel(channel) {
      channel.removed = true;
      log.push(`remove:${channel.name}`);
      if (!sb.closeLands) return;          // the leave push is still in flight
      registry.delete(channel.name);
      if (channel.cb && !channel.closedEmitted) { channel.closedEmitted = true; channel.cb('CLOSED'); }
    },
  };

  const S = { biz: { id: bizId }, user: { id: userId } };
  const calls = { loadNotifications: 0, renderBell: 0, bookingCount: 0, autoRefresh: 0 };

  let nowMs = 1_000_000;
  const clock = { now: () => nowMs };
  const advance = ms => { nowMs += ms; };

  const scope = new Function(
    'sb', 'S', 'setTimeout', 'clearTimeout', 'currentPage', 'Date',
    'loadNotifications', 'renderBell', 'refreshPendingBookingRequestCountV329', 'autoRefreshIfRelevant',
    `let rtChannel=null,rtChannelBizId=null;
     let autoRefreshTimerV370=0,pendingBookingCountTimerV370=0;
     ${rejoinSrc}
     ${killSrc}
     return {
       ensureRealtimeChannel, joinRealtimeChannelV922, killChannels,
       peek:()=>({channel:rtChannel,bizId:rtChannelBizId,retries:rtRetriesV922,timer:rtRetryTimerV922}),
     };`,
  )(
    sb, S, fakeSetTimeout, fakeClearTimeout, ['dashboard'], clock,
    async () => { calls.loadNotifications += 1; },
    () => { calls.renderBell += 1; },
    () => { calls.bookingCount += 1; },
    () => { calls.autoRefresh += 1; },
  );

  /* Flushes the deferred case: the leave push finally acks, so the close lands and the registry
     drops the channel. Only meaningful after closeLands was set false. */
  const removeEmitsClosed = () => {
    for (const channel of built) if (channel.removed && !channel.closedEmitted) {
      channel.closedEmitted = true;
      registry.delete(channel.name);
      channel.cb?.('CLOSED');
    }
  };

  return { ...scope, sb, S, log, built, calls, timers, runTimer, runAllTimers, removeEmitsClosed,
    advance, live: () => built[built.length - 1] };
}

test('a channel that FAILED to join is not mistaken for a live one — the defect', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const first = h.live();
  first.cb('CHANNEL_ERROR');
  first.state = 'errored';

  /* The next navigation. Before v922 this returned early on object identity and the session was
     deaf for the rest of its life. */
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 2, 'a dead channel is rebuilt on the next ensureRealtimeChannel()');
  assert.notEqual(h.live(), first, 'and it is a genuinely new channel object');
});

test('a channel that is merely still JOINING is left alone — no churn while a join is in flight', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 1);
  h.live().state = 'joining';
  h.ensureRealtimeChannel();
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 1, 'three navigations during one join build exactly one channel');
});

test('a channel stuck in JOINING is eventually rebuilt rather than believed forever', () => {
  /* 'joining' is not reliably transient: RealtimeChannel runs its own rejoinTimer, so against a
     realtime tenant that is down the channel alternates joining/errored indefinitely and never
     reaches a terminal state. Believing 'joining' without a bound would make navigating back into
     the workspace repair the session only when it happened to sample an 'errored' instant — a coin
     flip the merchant cannot see. */
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().state = 'joining';

  h.advance(5000);
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 1, 'inside one join window the join in flight is left alone');

  h.advance(11000);                          // past the 15s window (and past the client 10s timeout)
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 2, 'past it, a navigation rebuilds instead of trusting a stuck join');
});

test('a join that succeeds closes the window, so a long-lived channel is never rebuilt on age', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('SUBSCRIBED');
  h.live().state = 'joined';
  h.advance(60 * 60 * 1000);                 // an hour on the same page
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 1, 'a joined channel is judged by its state, never by its age');
});

test('a healthy joined channel is reused across navigations', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('SUBSCRIBED');
  h.live().state = 'joined';
  h.ensureRealtimeChannel();
  h.ensureRealtimeChannel();
  assert.equal(h.built.length, 1, 'no rebuild while the channel is joined');
});

test('the retry budget is bounded: 2s, 4s, 8s, 16s, 32s, then it stops', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const delays = [];
  for (let attempt = 0; attempt < 8; attempt += 1) {
    h.live().cb('CHANNEL_ERROR');
    const pending = [...h.timers.entries()];
    if (!pending.length) break;
    const [id, timer] = pending[0];
    delays.push(timer.ms);
    h.runTimer(id);          // fires the rejoin
    h.removeEmitsClosed();   // and the teardown's CLOSED, which must be inert
  }
  /* Jittered, so the assertion is on the BAND, not the exact millisecond: each attempt sits in
     [base, base+1000). Asserting the exact grid would be asserting the absence of the jitter. */
  const bases = [2000, 4000, 8000, 16000, 32000];
  assert.equal(delays.length, 5, `exactly five attempts, got ${delays.length}`);
  delays.forEach((delay, i) => {
    assert.ok(delay >= bases[i] && delay < bases[i] + 1000,
      `attempt ${i + 1} backs off from ${bases[i]}ms with jitter (got ${delay})`);
  });
  assert.ok(new Set(delays).size === 5, 'and the bands do not overlap, so the backoff really doubles');
  h.live().cb('CHANNEL_ERROR');
  assert.equal(h.timers.size, 0, 'a sixth failure schedules nothing — a dead tenant is not hammered');
});

test('F052 brake 1: the CLOSED emitted by a deliberate teardown is INERT, so rebuilding cannot storm', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const first = h.live();
  first.cb('CHANNEL_ERROR');
  const [timerId] = [...h.timers.keys()];
  h.runTimer(timerId);                       // rebuild: removeChannel(first) happens inside
  assert.equal(h.built.length, 2, 'the rebuild happened');
  assert.ok(first.removed, 'and the old channel was torn down');

  const before = h.built.length;
  h.removeEmitsClosed();                     // first.cb('CLOSED') — the storm's ignition
  assert.equal(h.timers.size, 0, 'the replaced channel scheduled NO rejoin');
  assert.equal(h.built.length, before, 'and built no channel');
});

test('F052 brake 2: SUBSCRIBED cancels a rebuild already queued by this channel own bad start', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const channel = h.live();
  channel.cb('CHANNEL_ERROR');               // queues a rebuild
  assert.equal(h.timers.size, 1, 'a rebuild is queued');
  channel.cb('SUBSCRIBED');                  // ...then the same channel actually joins
  assert.equal(h.timers.size, 0, 'the queued rebuild is cancelled — it would have killed a healthy channel');
  assert.equal(h.peek().retries, 0, 'and the budget is reset');
});

test('a status from a channel we already replaced cannot schedule anything', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const first = h.live();
  first.cb('CHANNEL_ERROR');
  h.runTimer([...h.timers.keys()][0]);
  const second = h.live();
  assert.notEqual(first, second);

  first.cb('CHANNEL_ERROR');                 // a late status from the abandoned channel
  first.cb('TIMED_OUT');
  assert.equal(h.timers.size, 0, 'the abandoned channel is inert');
  assert.equal(h.built.length, 2, 'and built nothing');
  second.cb('SUBSCRIBED');
  assert.equal(h.peek().channel, second, 'the live slot still points at the real channel');
});

test('a REJOIN re-reads what the gap lost; a FIRST join does not spend a request', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('SUBSCRIBED');
  assert.deepEqual(
    { n: h.calls.loadNotifications, b: h.calls.bookingCount, a: h.calls.autoRefresh },
    { n: 0, b: 0, a: 0 },
    'the first successful join re-reads nothing — initNotifications has just read',
  );

  h.live().cb('CHANNEL_ERROR');
  h.runTimer([...h.timers.keys()][0]);
  h.removeEmitsClosed();
  h.live().cb('SUBSCRIBED');
  assert.equal(h.calls.loadNotifications, 1, 'a join that FOLLOWS a failure re-reads notifications');
  assert.equal(h.calls.bookingCount, 1, 'and the pending booking count');
  assert.equal(h.calls.autoRefresh, 1, 'and refreshes the page the owner is looking at');
});

test('killChannels cancels a queued rejoin — it must never fire into a signed-out session', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('CHANNEL_ERROR');
  assert.equal(h.timers.size, 1, 'a rejoin is queued');

  h.killChannels();
  assert.equal(h.timers.size, 0, 'sign-out cancelled it');
  assert.equal(h.peek().channel, null, 'and dropped the channel');
  assert.equal(h.peek().retries, 0, 'and reset the budget');

  const built = h.built.length;
  h.removeEmitsClosed();                     // killChannels' own removeChannel emits CLOSED
  assert.equal(h.timers.size, 0, 'and that CLOSED does not resurrect the channel');
  assert.equal(h.built.length, built);
});

test('a rejoin queued for business A does not fire into business B', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('CHANNEL_ERROR');
  const [timerId] = [...h.timers.keys()];

  h.S.biz.id = 'biz-B';                      // the owner switched workspace before the timer fired
  h.runTimer(timerId);
  assert.equal(h.built.length, 1, 'the queued rejoin for the workspace we left builds nothing');
});

test('the re-sync refuses to run for a workspace the owner has already left', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  const channel = h.live();
  channel.cb('CHANNEL_ERROR');
  h.runTimer([...h.timers.keys()][0]);
  h.removeEmitsClosed();
  const rejoined = h.live();
  h.S.biz.id = 'biz-B';
  rejoined.cb('SUBSCRIBED');
  assert.equal(h.calls.loadNotifications, 0, 'a late SUBSCRIBED for the previous workspace re-reads nothing');
});

test('if the client hands back the channel we just discarded, it is refused and retried', () => {
  /* supabase-js dedupes sb.channel() by topic and only drops a removed channel from that registry
     when its close lands. A channel torn down while it can still push closes asynchronously, so a
     same-topic rebuild inside that window is handed the very object being discarded — and
     .subscribe() is a no-op on a channel that is not closed, so the rebuild would silently do
     NOTHING while the code recorded it as live. That is the exact failure this change exists to
     remove, so it must not be reintroduced by the fix. */
  const h = harness();
  h.ensureRealtimeChannel();
  const first = h.live();
  first.cb('CHANNEL_ERROR');
  const onsBefore = first.ons;

  h.sb.closeLands = false;                        // the removal has not landed yet
  h.runTimer([...h.timers.keys()][0]);
  assert.equal(h.built.length, 1, 'no new channel was built — the client had none to give');
  assert.equal(first.ons, onsBefore, 'and the discarded channel did NOT get a second set of handlers');
  assert.equal(h.peek().channel, null, 'it is not recorded as live');
  assert.equal(h.timers.size, 1, 'a retry is queued rather than the loop giving up silently');

  h.sb.closeLands = true;
  h.removeEmitsClosed();                     // the leave push finally acks: the registry drops it
  h.runTimer([...h.timers.keys()][0]);
  assert.equal(h.built.length, 2, 'the next attempt gets a genuinely new channel');
  h.live().cb('SUBSCRIBED');
  assert.equal(h.peek().channel, h.live(), 'and it becomes the live one');
});

test('the dedupe bail still respects the retry cap', () => {
  const h = harness();
  h.ensureRealtimeChannel();
  h.live().cb('CHANNEL_ERROR');
  h.sb.closeLands = false;
  for (let i = 0; i < 10 && h.timers.size; i += 1) h.runTimer([...h.timers.keys()][0]);
  assert.equal(h.timers.size, 0, 'it stops rather than spinning on a client that keeps deduping');
  assert.equal(h.built.length, 1, 'and never built a second channel while deduping');
});

/* ------------------------------------------------------------------ loadNotifications guards */

const notifSrc = slice(/^let notifRequestV922=0,notifLoadedForV922='';/m, '\nfunction bellHtml(');

function notifHarness() {
  const pending = [];
  const sb = { rpc: (_name, args) => new Promise(resolve => pending.push({ args, resolve })) };
  const S = { biz: { id: 'biz-A' } };
  const scope = new Function('sb', 'S', `
    let notifState={unread:0,items:[]},notifLoaded=false,notifError=null;
    ${notifSrc}
    return {loadNotifications,peek:()=>({notifState,notifLoaded,notifError,notifLoadedForV922})};`,
  )(sb, S);
  return { ...scope, sb, S, pending };
}

test('a slower answer for a workspace the owner has left never overwrites a newer one', async () => {
  const h = notifHarness();
  const first = h.loadNotifications();          // business A, in flight
  h.S.biz.id = 'biz-B';
  const second = h.loadNotifications();         // business B, in flight

  h.pending[1].resolve({ data: { unread: 2, items: [{ title: 'B' }] }, error: null });
  await second;
  h.pending[0].resolve({ data: { unread: 99, items: [{ title: 'A' }] }, error: null });
  await first;

  assert.equal(h.peek().notifState.unread, 2, "business A's late answer was refused");
  assert.equal(h.peek().notifState.items[0].title, 'B');
});

test('⚖️ switching workspace clears the bell rather than showing the previous firm customer names', async () => {
  const h = notifHarness();
  const load = h.loadNotifications();
  h.pending[0].resolve({ data: { unread: 3, items: [{ title: 'Ada booked' }] }, error: null });
  await load;
  assert.equal(h.peek().notifState.items.length, 1, 'business A is loaded');

  h.S.biz.id = 'biz-B';
  const next = h.loadNotifications();
  assert.deepEqual(h.peek().notifState, { unread: 0, items: [] },
    'the previous firm notifications are gone the moment the switch is observed, not when the read lands');
  assert.equal(h.peek().notifLoaded, false, 'and the menu says Loading rather than painting stale rows');
  h.pending[1].resolve({ data: { unread: 0, items: [] }, error: null });
  await next;
});

test('two reads for the SAME workspace settle in order, whichever answers first', async () => {
  /* The business-id half of the guard cannot catch this one: nothing switched. It is the ticket
     half, and it is exactly the race v922 introduced — the rejoin re-read fires at a moment nobody
     chose, so it can overlap a navigation's read of the same workspace and answer out of order. */
  const h = notifHarness();
  const first = h.loadNotifications();
  const second = h.loadNotifications();
  h.pending[1].resolve({ data: { unread: 1, items: [{ title: 'newest' }] }, error: null });
  await second;
  h.pending[0].resolve({ data: { unread: 42, items: [{ title: 'stale' }] }, error: null });
  await first;
  assert.equal(h.peek().notifState.unread, 1, 'the older read did not overwrite the newer one');
  assert.equal(h.peek().notifState.items[0].title, 'newest');
});

test('a stale read cannot resurrect an error banner over good data', async () => {
  const h = notifHarness();
  const first = h.loadNotifications();
  const second = h.loadNotifications();
  h.pending[1].resolve({ data: { unread: 0, items: [] }, error: null });
  await second;
  h.pending[0].resolve({ data: null, error: { message: 'stale failure' } });
  await first;
  assert.equal(h.peek().notifError, null, 'the abandoned read cannot paint an error over a good answer');
});

test('a failed read does not mark the cache as belonging to this workspace', async () => {
  const h = notifHarness();
  const load = h.loadNotifications();
  h.pending[0].resolve({ data: null, error: { message: 'boom' } });
  await load;
  assert.equal(h.peek().notifError, 'boom');
  assert.equal(h.peek().notifLoadedForV922, '', 'a failure claims nothing, so the next switch still clears');
});
