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
  const staffProfilePanelHtml=()=>'', modPanelHtml=()=>'', staffEditDialogHtmlV584=()=>'';
  /* nestly_v584: the row draws a Branch column now (owner photo 15 wrote the header in by hand),
     so the two branch lookups it reads are stubbed like the panels — this file is about the
     ACCESS state, and a stub that lies about branches would not change what it proves. */
  const staffBranchListV577=[{id:'b1',name:'Orchard',is_default:true,active:true}];
  const staffBranchAssignedV577=new Map();
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

test('the row states the real access_state, not merely "they have a login"', () => {
  /* nestly_v584 (owner photo 15: "APP ACCESS" written in as a column header, and the pill under
     each name struck out). The FACT this test is about is unchanged and is still read off
     access_state; only where it is drawn moved — from a pill in a wrapped strip below the grid to
     a tick or a cross in its own column, which is what lets it be compared down the list. */
  const approved = row({ id: 's1', full_name: 'Kelvin', role: 'staff', user_id: 'u1', access_state: 'approved' });
  /* nestly_v595 wrapped the mark in the door span that opens the editor on Access & Module. The
     FACT under test is still the mark itself, so the assertion keeps the column and the mark and
     tolerates the door between them. */
  assert.match(approved, /data-staff-col="App access">.*?class="staff-access-mark-v584 is-yes"/);
  assert.ok(!approved.includes('Waiting'));

  /* The bug: this row said "App access active" while every sign-in was refused. A tick would be
     the same lie, so a pending row still gets words and still gets the decision. */
  const pending = row({ id: 's2', full_name: 'Mei', role: 'staff', user_id: 'u2', access_state: 'pending' });
  assert.match(pending, /data-staff-col="App access"><span class="pill warn">Waiting</);
  assert.ok(!pending.includes('staff-access-mark-v584 is-yes'));

  /* decide_staff_access_v207 detaches user_id when it declines, so the declined row is judged on
     access_state first — otherwise it would be indistinguishable from a never-invited one. */
  const rejected = row({ id: 's3', full_name: 'Sam', role: 'staff', user_id: null, access_state: 'rejected' });
  /* nestly_v595 moved the human-readable title onto the door span that wraps the mark (the door
     is what a pointer lands on, so it is what should carry the tooltip) and left the mark its
     aria-label. Both halves are asserted so neither can quietly disappear. */
  assert.match(rejected, /data-staff-access-open-v595 title="App access declined — open app access &amp; modules"/);
  assert.match(rejected, /staff-access-mark-v584 is-no" aria-label="App access declined"/);

  const noLogin = row({ id: 's4', full_name: 'Rota Only', role: 'staff', user_id: null, access_state: null });
  /* nestly_v595: same split as the declined row — tooltip on the door, label on the mark. */
  assert.match(noLogin, /data-staff-access-open-v595 title="No app access — open app access &amp; modules"/);
  assert.match(noLogin, /staff-access-mark-v584 is-no" aria-label="No app access"/);

  /* Rows predating the column must not be mass-flagged as waiting. */
  const legacy = row({ id: 's5', full_name: 'Old Hand', role: 'staff', user_id: 'u5', access_state: null });
  assert.match(legacy, /data-staff-col="App access">.*?class="staff-access-mark-v584 is-yes"/);
});

test('only a pending row offers the decision, and it explains what approving does', () => {
  const pending = row({ id: 's2', full_name: 'Mei', role: 'staff', user_id: 'u2', access_state: 'pending' });
  assert.match(pending, /decideStaffAccessV569\('s2',true,this\)">Approve access</);
  assert.match(pending, /decideStaffAccessV569\('s2',false,this\)">Decline</);
  assert.match(pending, /waiting for you to let them in/);
  assert.match(pending, /modules already set/);
  /* Approve does not replace the row's other actions — nestly_v577 (owner mark, photo 12: all
     four row buttons ringed, "all move into edit button") moved those behind Edit, so the row
     offers Approve / Decline / Edit and the four actions live in the panel Edit opens. Approve
     and Decline deliberately stayed on the row: they are a request waiting on the owner, and the
     owner did not ring them. */
  /* nestly_v603: Edit moved into the row itself (the chip beside Commission), so a pending row
     carries Approve and Decline and nothing that competes with them. The row still opens the
     editor — through its own button, which is the whole row. */
  assert.match(pending, /openStaffProfileFromRowV595\(event,'s2'\)/);
  assert.doesNotMatch(pending, /toggleModPanel\('s2'\)/);
  assert.doesNotMatch(pending, /setStaffActiveV285\('s2'/);
  assert.doesNotMatch(pending, /rmStaff\('s2'/);
  /* …and they are genuinely still reachable, in staffProfileActionsHtmlV577.
     nestly_v584 (owner photo 16: the panel redrawn as Profile | Access & Module, with "Access and
     status" ringed and "put inside"): the Modules BUTTON is gone because the module grid is on
     that same tab, directly below these actions — a button that opens what you are already
     looking at is not an action. The other three are unchanged, Delete having become a dustbin
     with the same handler and the same confirm. */
  /* nestly_v603 (owner photo: "Access and status" struck out with "remove wording"; Deactivate and
     the dustbin ringed with an arrow up to the Profile tab). The three are still all reachable,
     but they no longer share one panel: giving app access is about the LOGIN and stayed on Access
     & Module, while deactivating and deleting are about the PERSON and moved to Profile. */
  const accessPanel = app.slice(app.indexOf('function staffProfileActionsHtmlV577'));
  assert.match(accessPanel.slice(0, 1600), /staffReferenceCodeV217\('\$\{s\.id\}'/);
  assert.doesNotMatch(accessPanel.slice(0, 1600), /<b class="small">Access and status<\/b>/,
    'the heading named the tab a second time');
  const personPanel = app.slice(app.indexOf('function staffPersonActionsHtmlV603'));
  for (const action of [/setStaffActiveV285\('\$\{s\.id\}'/, /rmStaff\('\$\{s\.id\}'/]) {
    assert.match(personPanel.slice(0, 2200), action);
  }
  assert.match(app, /\$\{staffPersonActionsHtmlV603\(s\)\}\n\s*<div class="row staff-profile-save-v584"/,
    'and they sit on the Profile tab, above Save');
  /* nestly_v595 made `hidden` conditional so the dialog can open straight on this tab; the pairing
     this line exists to protect — actions and module grid on ONE tab — is unchanged. */
  assert.match(app, /<div data-staff-tabpanel-v584="access"\$\{openTabV595==='access'\?'':' hidden'\}>\$\{staffProfileActionsHtmlV577\(s\)\}\$\{modPanelHtml\(s\)\}<\/div>/,
    'the module grid sits on the same tab as the access actions');

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


/* nestly_v595 (owner: "i need to give app access to staff that i already added — where do I
   activate it?", then "best if can do a pop up — modules / app access all inside the pop up").
   The destination already existed; the ✕ that states the answer did not lead to it. These tests
   EXECUTE the shipped routing rather than grepping for the attribute, because the attribute being
   present proves nothing about which tab the click asks for — the failure mode this file was
   written about. */
const makeRowRouterV595 = () => {
  const opened = [];
  const window = {};
  new Function('window', `
    let openProfileId=null, staffEditTabV595='profile';
    const loadTeam=()=>{};
    ${statement('window.toggleStaffProfile=(staffId,tab)=>{', "window.openStaffProfileFromRowV595=(event,staffId)=>{\n    const wantsAccess=!!event?.target?.closest?.('[data-staff-access-open-v595]');\n    toggleStaffProfile(staffId,wantsAccess?'access':'profile');\n  };")}
    const toggleStaffProfile=window.toggleStaffProfile;
    window.__read=()=>({openProfileId,staffEditTabV595});
  `)(window);
  return { window, opened };
};

test('the App access cell opens the editor on Access & Module; the rest of the row does not', () => {
  const { window } = makeRowRouterV595();
  const doorTarget = { closest: sel => (sel === '[data-staff-access-open-v595]' ? {} : null) };
  const plainTarget = { closest: () => null };

  window.openStaffProfileFromRowV595({ target: doorTarget }, 'devi');
  assert.deepEqual(window.__read(), { openProfileId: 'devi', staffEditTabV595: 'access' },
    'clicking the access column must land on the tab that grants access');

  window.openStaffProfileFromRowV595({ target: doorTarget }, 'devi'); // toggles shut
  window.openStaffProfileFromRowV595({ target: plainTarget }, 'devi');
  assert.deepEqual(window.__read(), { openProfileId: 'devi', staffEditTabV595: 'profile' },
    'every other column keeps opening where it always opened');
});

test('closing the editor forgets the access tab, so the next row opens on Profile', () => {
  const { window } = makeRowRouterV595();
  const doorTarget = { closest: () => ({}) };
  window.openStaffProfileFromRowV595({ target: doorTarget }, 'devi');
  assert.equal(window.__read().staffEditTabV595, 'access');
  window.toggleStaffProfile('devi'); // same id again = close
  assert.deepEqual(window.__read(), { openProfileId: null, staffEditTabV595: 'profile' });
});

test('the access column is a span, never a nested button inside the row button', () => {
  const rendered = row({ id: 's9', full_name: 'Devi', role: 'staff', user_id: null, access_state: '' });
  const cell = rendered.slice(rendered.indexOf('data-staff-col="App access"'));
  const doorOpen = cell.indexOf('data-staff-access-open-v595');
  assert.ok(doorOpen > 0, 'the cell carries the door hook the row handler reads');
  assert.ok(!/<button/.test(cell.slice(0, doorOpen + 200)),
    'a <button> here would be nested inside .staff-row-open and is invalid HTML');
});

test('an owner row still has no Access & Module tab to open', () => {
  const dialog = app.slice(app.indexOf('function staffEditDialogHtmlV584'));
  assert.match(dialog.slice(0, 1200),
    /const openTabV595=showAccess&&staffEditTabV595==='access'\?'access':'profile'/,
    'a request for a tab that does not exist must fall back rather than hide both panels');
});
