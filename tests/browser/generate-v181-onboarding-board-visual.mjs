// Regenerates tests/browser/v181-onboarding-board.html: the real compact
// Kanban and list markup with the console's own drag wiring, so the board can
// be reviewed and drag-tested without a super-admin session.
//
// V448: buildOnboardingBoardVisualFixture() was pulled out as a pure, exported function (no file
// I/O of its own) so tests/business-ui/v181-onboarding-board-fixture-parity.test.mjs can rebuild
// the fixture from freshly-read source and assert byte equality against the committed file — the
// same pattern generate-reward-overview-owner-visual.mjs already uses. Previously this file only
// ran end-to-end as a CLI script that wrote straight to disk, so nothing could prove the checked-in
// fixture still matched current production source (the gap regen-visual-fixtures.mjs's own header
// comment names).
// V459: the CLI-invocation guard below now also excludes node's OWN test-runner children — see
// scripts/quality/is-direct-cli-invocation.mjs for why (the nondeterministic-suite bug, REG-009
// follow-up). node --test swept this file up as a "test file" purely because it lives under a
// directory named tests/, ran it in a child process where process.argv[1] pointed at itself, and
// the old guard could not tell that apart from a real `node tests/browser/generate-v181...mjs`.
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { isDirectCliInvocation } from '../../scripts/quality/is-direct-cli-invocation.mjs';
import vm from 'node:vm';

const root = new URL('../../', import.meta.url).pathname;
const FIXTURE_URL = new URL('./v181-onboarding-board.html', import.meta.url);

export async function readOnboardingBoardSources() {
  return {
    consoleSource: await readFile(root + 'app/platform-console.js', 'utf8'),
    consoleCss: await readFile(root + 'app/platform-console.css', 'utf8'),
    baseCss: await readFile(root + 'app/customer-ui.css', 'utf8').catch(() => ''),
  };
}

export function buildOnboardingBoardVisualFixture(consoleSource, consoleCss, baseCss = '') {
  const ctx = { Object, Map, Set };
  ctx.globalThis = ctx;
  vm.runInNewContext(consoleSource, ctx, { filename: 'platform-console.js' });
  const C = ctx.NestlyPlatformConsole;

  const CUI = {
    status: (label, tone) => `<span class="pill ${tone || 'off'}">${label}</span>`,
    icon: () => '',
    field: ({ id, options = [] }) => `<select id="${id}">${options.map(o => `<option>${o.label}</option>`).join('')}</select>`,
    emptyState: ({ title }) => `<p>${title}</p>`
  };

  const firms = [
    { id: 'p1', company_name: 'Kopi Corner', primary_contact_name: 'Wei Tan', consultant_name: 'Sara L.',
      source_stage_key: 'new_lead', lane_key: 'inbox', next_action_at: '2026-08-08T02:00:00Z', attention_due: true, attention_severity: 'critical' },
    { id: 'p2', company_name: 'Bloom Nails & Spa', primary_contact_name: 'Priya R.', consultant_name: 'Sara L.',
      source_stage_key: 'appt_set', lane_key: 'contacting', next_action_at: '2026-08-09T02:00:00Z', attention_severity: 'warning' },
    { id: 'p3', company_name: 'Ah Seng Barber', primary_contact_name: 'Seng H.', consultant_name: 'Marcus O.',
      source_stage_key: 'meeting_sent', lane_key: 'contacting', next_action_at: '2026-08-12T02:00:00Z' },
    { id: 'p4', company_name: 'Lotus Yoga Studio', primary_contact_name: 'Amanda C.', consultant_name: 'Marcus O.',
      source_stage_key: 'quotation_sent', lane_key: 'decision', next_action_at: '2026-08-07T02:00:00Z', overdue_task_count: 1 },
    { id: 'p5', company_name: 'Cubbly Cafe', primary_contact_name: 'Lee C.', consultant_name: 'Sara L.',
      source_stage_key: 'activated', lane_key: 'case_won', _has_prospect_detail: false, last_activity_at: '2026-08-05T02:00:00Z', lane_label: 'Website signup / live firm' },
    { id: 'p6', company_name: 'Tiong Bahru Bakes', primary_contact_name: 'Jun W.', consultant_name: 'Marcus O.',
      source_stage_key: 'lost', lane_key: 'closed', last_activity_at: '2026-07-02T02:00:00Z' }
  ];

  const lanes = C.operationalLanes;
  const byLane = Object.fromEntries(lanes.map(l => [l.key, firms.filter(f => C.operationalLaneFor(f) === l.key)]));
  const kanban = `<div class="platform-kanban">${lanes.map(lane => `<section class="platform-kanban-column" data-lane-column="${lane.key}">
  <header class="platform-kanban-head"><div><h2>${lane.label}</h2><p>${lane.description}</p></div><span class="platform-count">${byLane[lane.key].length}</span></header>
  <div class="platform-card-list" data-lane-drop="${lane.key}">${byLane[lane.key].map(f => C.prospectCardHtml(f, CUI, { compact: true, canWrite: true })).join('') || '<p class="muted small platform-lane-empty">No firms</p>'}</div>
</section>`).join('')}</div>`;

  const list = C.prospectListTableHtml(firms, CUI, { canWrite: true });

  // The detail drawer's field groups, with the same sparse data a freshly
  // captured lead has: a couple of known values and a lot of blanks.
  const identity = C.typedDetailHtml(
    { legal_name: 'CARLINGTON SMITH CONSULTANCY PTE. LTD.', registration_number: '12312312' },
    [['legal_name','Legal name'],['trading_name','Trading name'],['registration_number','UEN / registration'],
     ['industry','Industry'],['website','Website'],['email','General email'],['phone','General phone']]);
  const profile = C.typedDetailHtml({}, [
    ['entity_type','Entity type'],['business_status','Business status'],['incorporated_on','Incorporated'],
    ['registered_address','Registered address'],['operating_address','Operating address'],
    ['postal_code','Postal code'],['region_state','Region / state'],['verification_status','Verification']]);
  const overview = C.typedDetailHtml(
    { current_stage_key:'New Lead', priority:'Normal', stage_entered_at:'3 Aug 2026, 2:26 pm' },
    [['current_stage_key','Stage'],['priority','Priority'],['region','Region'],
     ['next_action_at','Next action'],['stage_entered_at','Stage entered'],['converted_at','Converted']]);
  const drawer = `<section class="card platform-detail-section">
  <div class="platform-list-row"><h2>Overview</h2></div>
  <div class="platform-detail-grid">${overview}</div>
</section>
<section class="card platform-detail-section">
  <div class="platform-list-row"><h2>Company identity and operating profile</h2></div>
  <div class="platform-detail-grid">${identity}${profile}</div>
</section>`;

  return `<!doctype html><meta charset="utf-8">
<title>Onboarding board preview</title>
<style>${baseCss}\n${consoleCss}
:root{--line:#DEDAD2;--hair:#E7E3DC;--muted:#6B6560;--ink:#1B1A18;--tint:#FBEDEB;--coral:#C24135;--shadow:0 1px 2px rgba(0,0,0,.05);--shadow-lg:0 6px 18px rgba(0,0,0,.09)}
body{margin:0;padding:20px;background:#F4F2EE;font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;color:var(--ink)}
h1{font-size:17px;margin:0 0 4px}h3{margin:26px 0 8px;font-size:14px}
.pill{display:inline-block;padding:3px 7px;border-radius:999px;background:#EFEBE5;color:var(--muted);font-size:10px;font-weight:700}
.pill.no{background:#FBE4E1;color:#A4291F}.pill.new{background:#FCEFD9;color:#8A5B12}.pill.ok{background:#E1F1E6;color:#1F6B3A}
.cui-table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--hair);border-radius:12px;overflow:hidden}
.cui-table th,.cui-table td{padding:9px 11px;text-align:left;font-size:12px;border-bottom:1px solid var(--hair)}
.cui-table th{background:#EFEBE5;font-size:11px}.cui-table caption{text-align:left;padding:0 0 6px;font-size:11px;color:var(--muted)}
.card{background:#fff;border:1px solid var(--hair);border-radius:14px;padding:16px;margin-bottom:12px}
.platform-list-row h2{font-size:14px;margin:0 0 10px}
.platform-detail-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:18px}
.platform-typed-list{margin:0}
.platform-typed-list>div{display:flex;justify-content:space-between;gap:14px;padding:7px 0;border-bottom:1px solid var(--hair)}
.platform-typed-list dt{color:var(--muted);font-size:12px}
.platform-typed-list dd{margin:0;font-size:12px;font-weight:650;text-align:right}
.muted{color:var(--muted)}.small{font-size:11px}
#log{margin-top:14px;padding:10px;border:1px solid var(--hair);border-radius:10px;background:#fff;font-size:12px}
</style>
<h1>Onboarding board — kanban (compact cards, drag between columns)</h1>
<p class="muted small" id="platformKanbanMoveHint">Drag a card into another column to move it, or focus a card and press Ctrl with the left or right arrow. Every move still asks for its evidence.</p>
${kanban}
<h3>List view</h3>
${list}
<h3>Detail drawer — values first, blanks collapsed</h3>
${drawer}
<div id="log">Drop log: <span id="out">none yet</span></div>
<script>
// Mirrors the console's drag wiring so the interaction itself can be tested.
let dragged=null;
document.querySelectorAll('[data-prospect][draggable="true"]').forEach(card=>{
  card.ondragstart=e=>{dragged=card.dataset.prospect;card.setAttribute('aria-grabbed','true');e.dataTransfer.setData('text/plain',dragged);e.dataTransfer.effectAllowed='move'};
  card.ondragend=()=>{dragged=null;card.removeAttribute('aria-grabbed');document.querySelectorAll('[data-lane-drop]').forEach(z=>z.classList.remove('is-drop-target'))};
});
document.querySelectorAll('[data-lane-drop]').forEach(zone=>{
  zone.ondragover=e=>{if(!dragged)return;e.preventDefault();zone.classList.add('is-drop-target')};
  zone.ondragleave=()=>zone.classList.remove('is-drop-target');
  zone.ondrop=e=>{e.preventDefault();zone.classList.remove('is-drop-target');
    const id=dragged||e.dataTransfer.getData('text/plain');
    const card=document.querySelector('[data-prospect="'+id+'"][draggable]');
    document.getElementById('out').textContent=id+' → lane '+zone.dataset.laneDrop+' (evidence modal would open)';
    if(card&&card.dataset.lane!==zone.dataset.laneDrop)zone.appendChild(card);
    dragged=null};
});
</script>`;
}

if (isDirectCliInvocation(import.meta.url)) {
  const { consoleSource, consoleCss, baseCss } = await readOnboardingBoardSources();
  const html = buildOnboardingBoardVisualFixture(consoleSource, consoleCss, baseCss);
  await writeFile(FIXTURE_URL, html);
  console.log('kanban cards:', (html.match(/platform-prospect-card-compact/g) || []).length,
    '| draggable:', (html.match(/draggable="true"/g) || []).length,
    '| list rows:', (html.match(/platform-prospect-row/g) || []).length,
    '\n' + fileURLToPath(FIXTURE_URL));
}
