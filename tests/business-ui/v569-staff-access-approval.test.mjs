/* nestly_v569 — accept_invite parks every new teammate at staff.access_state='pending' on
   purpose (the owner confirms each login), and decide_staff_access_v207 is what moves them on.
   That RPC had ZERO callers in app/app.js, so 'pending' was a dead end: RLS (app.is_salon_member
   demands 'approved') refused the teammate at every sign-in while the roster showed them a green
   "App access active" pill. These tests EXECUTE the shipped row renderer and the shipped handler
   — a grep would have stayed green through the whole outage, because the markup it would have
   matched was already there and simply wrong. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return app.slice(from, to);
};
const statement = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return app.slice(from, to + end.length);
};

const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* The roster row exactly as it ships. Everything it leans on that is not under test — the two
   expandable panels and the role labels — is stubbed; the pill/button logic is the real source. */
const renderRow = new Function('esc', `
  const ROLE_LABELS={owner:'Owner',manager:'Manager',staff:'Team member',frontdesk:'Front desk'};
  const openProfileId=null, openModId=null;
  const staffProfilePanelHtml=()=>'', modPanelHtml=()=>'';
  ${section('const staffRowV209=s=>{', 'const rows=st||[];')}
  return staffRowV209;`)(esc);

/* The handler, executed against a fake supabase so the RPC name and its arguments are observed
   rather than asserted about in a regex. */
const makeHandler = () => {
  const calls = [];
  const toasts = [];
  const confirms = [];
  const window = {};
  new Function('sb', 'S', 'fail', 'toast', 'teamRowsById', 'confirmActionV386',
    'loadTeam', 'invalidateBranchModuleProjectionCache', 'window', `
    ${section('window.decideStaffAccessV569=async(id,approve,button)=>{', 'window.setStaffActiveV285=')}`)(
    { rpc: async (name, args) => { calls.push({ name, args }); return { error: null }; } },
    { biz: { id: 'biz-1' } },
    error => { calls.push({ failed: error }); },
    message => toasts.push(message),
    new Map(),
    async message => { confirms.push(message); return true; },
    async () => {},
    () => {},
    window
  );
  return { decide: window.decideStaffAccessV569, calls, toasts, confirms };
};

const row = state => renderRow(state);

test('the pill states the real access_state, not merely "they have a login"', () => {
  const approved = row({ id: 's1', full_name: 'Kelvin', role: 'staff', user_id: 'u1', access_state: 'approved' });
  assert.match(approved, /pill ok">App access active</);
  assert.ok(!approved.includes('Waiting for your approval'));

  /* The bug: this row said "App access active" while every sign-in was refused. */
  const pending = row({ id: 's2', full_name: 'Mei', role: 'staff', user_id: 'u2', access_state: 'pending' });
  assert.match(pending, /pill warn">Waiting for your approval</);
  assert.ok(!pending.includes('App access active'));

  /* decide_staff_access_v207 detaches user_id when it declines, so the declined row is judged on
     access_state first — otherwise it would be indistinguishable from a never-invited one. */
  const rejected = row({ id: 's3', full_name: 'Sam', role: 'staff', user_id: null, access_state: 'rejected' });
  assert.match(rejected, /pill off">App access declined</);

  const noLogin = row({ id: 's4', full_name: 'Rota Only', role: 'staff', user_id: null, access_state: null });
  assert.match(noLogin, /pill off">No app access</);

  /* Rows predating the column must not be mass-flagged as waiting. */
  const legacy = row({ id: 's5', full_name: 'Old Hand', role: 'staff', user_id: 'u5', access_state: null });
  assert.match(legacy, /pill ok">App access active</);
});

test('only a pending row offers the decision, and it explains what approving does', () => {
  const pending = row({ id: 's2', full_name: 'Mei', role: 'staff', user_id: 'u2', access_state: 'pending' });
  assert.match(pending, /decideStaffAccessV569\('s2',true,this\)">Approve access</);
  assert.match(pending, /decideStaffAccessV569\('s2',false,this\)">Decline</);
  assert.match(pending, /waiting for you to let them in/);
  assert.match(pending, /modules already set/);
  /* Approve does not replace the row's existing actions. */
  assert.match(pending, /toggleModPanel\('s2'\)/);
  assert.match(pending, /setStaffActiveV285\('s2'/);
  assert.match(pending, /rmStaff\('s2'/);

  for (const settled of [
    { id: 's1', role: 'staff', user_id: 'u1', access_state: 'approved' },
    { id: 's3', role: 'staff', user_id: null, access_state: 'rejected' },
    { id: 's4', role: 'staff', user_id: null, access_state: null }
  ]) {
    const html = row(settled);
    assert.ok(!html.includes('Approve access'), `no decision on a settled row: ${settled.id}`);
    assert.ok(!html.includes('decideStaffAccessV569'), `no handler wired on a settled row: ${settled.id}`);
  }
  /* The owner's own row is never a pending decision. */
  assert.ok(!row({ id: 'o1', role: 'owner', user_id: 'u0', access_state: 'pending' }).includes('Approve access'));
});

test('Approve and Decline call decide_staff_access_v207 with the right verdict', async () => {
  const approve = makeHandler();
  await approve.decide('s2', true, { dataset: { name: 'Mei' } });
  assert.deepEqual(approve.calls, [{
    name: 'decide_staff_access_v207',
    args: { p_business: 'biz-1', p_staff: 's2', p_approve: true }
  }]);
  assert.equal(approve.confirms.length, 0, 'letting somebody in needs no confirmation');
  assert.deepEqual(approve.toasts, ['Mei can now sign in']);

  const decline = makeHandler();
  await decline.decide('s2', false, { dataset: { name: 'Mei' } });
  assert.equal(decline.calls[0].args.p_approve, false);
  assert.equal(decline.confirms.length, 1, 'declining is confirmed, like Deactivate and Delete');
  assert.match(decline.confirms[0], /stay on your team list/);
});

test('the seat copy matches the server: only approved logins are billed', () => {
  const group = section("{key:'access',title:'Team with app access',", "match:row=>");
  assert.match(group, /Each login you have approved is a billable seat/);
  assert.ok(!group.includes('Each active login is a billable seat'),
    'app.billable_seats now requires access_state=\'approved\'');
});

/* The waiting card, executed. It is the half of the fix the teammate actually sees, and its
   retry has to defeat the persona memo (BOOTSTRAP_CACHE_TTL_V370.personas) — otherwise an owner
   approves, the teammate presses the button, and the cached "pending" keeps them out. */
const makeWaitingCard = answers => {
  const seen = { calls: [], routed: 0, personaUnavailable: 0, wired: 0 };
  const nodes = new Map();
  const el = id => {
    if (!nodes.has(id)) nodes.set(id, { id, focus() {}, disabled: false, onclick: null });
    return nodes.get(id);
  };
  const root = { innerHTML: '' };
  new Function('root', '$', 'esc', 'accountDeletionCardHtml', 'legalLinks',
    'wireAccountDeletionButton', 'loadPersonasV370', 'isRouteCurrent',
    'renderPersonaResolutionUnavailable', 'route', 'businessNameV569', 'workspaceSlug', `
    ${statement('const renderWaitingV569=note=>{', "renderWaitingV569('');")}`)(
    root, el, esc,
    () => '<div data-account-deletion></div>',
    () => '<footer data-legal></footer>',
    () => { seen.wired += 1; },
    async options => { seen.calls.push(options); return answers.shift(); },
    () => true,
    () => { seen.personaUnavailable += 1; },
    () => { seen.routed += 1; },
    'Kopi Lab', 'kopi-lab'
  );
  return { seen, root, retry: () => el('workspaceApprovalRetry').onclick() };
};

test('a not-yet-approved teammate is told they are waiting, not that nothing is there', () => {
  const { root } = makeWaitingCard([]);
  assert.match(root.innerHTML, /Waiting for approval/);
  assert.match(root.innerHTML, /Kopi Lab has been asked to approve your access/);
  assert.match(root.innerHTML, /id="workspaceApprovalRetry"[^>]*>Check again</);
  /* The card keeps everything the block it replaces carried. */
  assert.match(root.innerHTML, /data-account-deletion/);
  assert.match(root.innerHTML, /data-legal/);
  /* The genuine not-a-member card above is untouched. */
  assert.match(app, /if\(!workspaceStaffPersona\)\{\s*root\.innerHTML=`[^`]*Workspace unavailable/);
});

test('Check again forces a fresh persona read and only lets an approved teammate through', async () => {
  const pending = { data: { staff: [{ business_slug: 'kopi-lab', access_state: 'pending' }] }, error: null };
  const approved = { data: { staff: [{ business_slug: 'kopi-lab', access_state: 'approved' }] }, error: null };
  const card = makeWaitingCard([pending, approved]);

  await card.retry();
  assert.deepEqual(card.seen.calls, [{ refresh: true }], 'the memo must be bypassed, not read');
  assert.equal(card.seen.routed, 0, 'a still-pending answer must not flash a false success');
  assert.match(card.root.innerHTML, /Waiting for approval/);
  assert.match(card.root.innerHTML, /Still waiting/);

  const beforeApproval = card.root.innerHTML;
  await card.retry();
  assert.deepEqual(card.seen.calls, [{ refresh: true }, { refresh: true }]);
  assert.equal(card.seen.routed, 1, 'an approved answer re-runs the route into the workspace');
  /* route() owns the page from here: the pending branch must not paint over it. */
  assert.equal(card.root.innerHTML, beforeApproval,
    'the approved answer renders no further waiting card');
});

test('a failed re-read is surfaced the way the neighbouring cards surface it', async () => {
  const card = makeWaitingCard([{ data: null, error: new Error('offline') }]);
  await card.retry();
  assert.equal(card.seen.personaUnavailable, 1);
  assert.equal(card.seen.routed, 0);
});

test('a declined teammate gets no retry button — only a new invite changes that answer', () => {
  const declined = section("if(personaAccessStateV569==='rejected'){", 'const renderWaitingV569=');
  assert.match(declined, /Access not granted/);
  assert.match(declined, /send you a new invite/);
  assert.ok(!declined.includes('workspaceApprovalRetry'), 'nothing to retry');
  assert.match(declined, /accountDeletionCardHtml\(\)/);
  assert.match(declined, /legalLinks\(\)/);
  assert.match(declined, /wireAccountDeletionButton\(\)/);
});
