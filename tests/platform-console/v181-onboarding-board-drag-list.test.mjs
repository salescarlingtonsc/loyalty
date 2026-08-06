import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root = new URL('../..', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

async function loadConsole() {
  const source = await read('app/platform-console.js');
  const context = { Object, Map, Set };
  context.globalThis = context;
  vm.runInNewContext(source, context, { filename: 'platform-console.js' });
  return context.NestlyPlatformConsole;
}

// Minimal CUI stand-in: enough for the pure HTML builders.
const CUI = {
  status: (label, tone) => `<span class="pill ${tone}">${label}</span>`,
  icon: () => '',
  field: ({ id, options = [] }) =>
    `<select id="${id}">${options.map(o => `<option value="${o.value}">${o.label}</option>`).join('')}</select>`,
  emptyState: ({ title }) => `<p>${title}</p>`
};

const firm = (overrides = {}) => ({
  id: 'prospect-1',
  company_name: 'Kopi Corner',
  primary_contact_name: 'Wei Tan',
  primary_contact_title: 'Owner',
  primary_contact_phone: '+6598765432',
  consultant_name: 'Sara L.',
  source_stage_key: 'appt_set',
  lane_key: 'contacting',
  next_action_at: '2026-08-10T02:00:00Z',
  priority: 'high',
  tags: ['cafe', 'east'],
  data_completeness_percent: 80,
  attention_severity: 'none',
  attention_due: false,
  ...overrides
});

test('kanban cards stay compact: name, one context line, at most two badges', async () => {
  const Console = await loadConsole();
  const compact = Console.prospectCardHtml(firm(), CUI, { compact: true });

  assert.match(compact, /platform-prospect-card-compact/);
  assert.match(compact, /Kopi Corner/);
  assert.match(compact, /platform-card-line/);
  // One badge for the stage, at most one for attention — never a wall.
  assert.ok(compact.match(/class="pill/g).length <= 2, 'compact card must not exceed two badges');
  // The chunky parts belong to the drawer, not the column.
  assert.doesNotMatch(compact, /platform-card-facts/);
  assert.doesNotMatch(compact, /platform-card-tags/);
  assert.doesNotMatch(compact, /data-move-select/);
  assert.doesNotMatch(compact, /platform-contact-actions/);

  // The full card is still available for the list/detail surfaces.
  const full = Console.prospectCardHtml(firm(), CUI, {});
  assert.match(full, /platform-card-facts/);
  assert.ok(full.length > compact.length, 'compact card must be smaller than the full card');
});

test('only writable firms are draggable and each carries its lane', async () => {
  const Console = await loadConsole();
  const movable = Console.prospectCardHtml(firm(), CUI, { compact: true, canWrite: true });
  assert.match(movable, /draggable="true"/);
  assert.match(movable, /data-can-move="true"/);
  assert.match(movable, /data-lane="contacting"/);

  const readOnly = Console.prospectCardHtml(firm(), CUI, { compact: true, canWrite: false });
  assert.match(readOnly, /draggable="false"/);
  assert.match(readOnly, /data-can-move="false"/);

  // A website-signup row has no prospect record, so it cannot be dragged.
  const noDetail = Console.prospectCardHtml(
    firm({ _has_prospect_detail: false, lane_key: 'case_won' }), CUI, { compact: true });
  assert.match(noDetail, /draggable="false"/);
});

test('one attention badge wins, in act-now order', async () => {
  const Console = await loadConsole();
  const badge = item => Console.prospectPrimaryBadge(firm(item), CUI);
  assert.match(badge({ attention_due: true, attention_severity: 'critical' }), /Due now/);
  assert.match(badge({ attention_severity: 'critical' }), /Critical/);
  assert.match(badge({ overdue_task_count: 2 }), /Overdue/);
  assert.match(badge({ attention_severity: 'warning' }), /Warning/);
  assert.match(badge({ attention_severity: 'info' }), /Monitor/);
  assert.equal(badge({}), '', 'a clean firm adds no attention badge to the card');
});

test('a lane drop resolves to hand-writable stages only', async () => {
  const Console = await loadConsole();
  // Conversion- and onboarding-controlled stages are never drop targets.
  const stagesFor = lane => Array.from(Console.laneMoveStages(lane));
  assert.deepEqual(stagesFor('case_won'), ['client']);
  assert.deepEqual(stagesFor('closed'), ['lost']);
  assert.deepEqual(stagesFor('inbox'), ['new_lead']);
  const decision = stagesFor('decision');
  assert.ok(decision.includes('quotation_sent') && decision.length > 1,
    'decision offers a choice of stages');
  for (const lane of Console.operationalLanes) {
    for (const stage of stagesFor(lane.key)) {
      assert.ok(!['account_created', 'onboarding', 'activated', 'unmapped'].includes(stage),
        `${stage} must not be a drop target`);
    }
  }
});

test('list view is a real table of the columns operators sort by', async () => {
  const Console = await loadConsole();
  const html = Console.prospectListTableHtml([firm(), firm({
    id: 'prospect-2', company_name: 'Bloom Nails', attention_due: true
  })], CUI, { canWrite: true });

  assert.match(html, /<table[^>]*platform-prospect-table/);
  for (const header of ['Firm', 'Stage', 'Operational status', 'Owner', 'Next action', 'Attention']) {
    assert.match(html, new RegExp(`<th scope="col">${header}</th>`));
  }
  // Rows reuse the same hook the board uses, so opening a firm works in both views.
  assert.equal(html.match(/data-prospect="/g).length, 2);
  assert.match(html, /data-prospect="prospect-2"/);
  assert.match(html, /Bloom Nails/);
  assert.match(html, /Due now/);
});

test('the board wires drop zones, keyboard moves and keeps the evidence gate', async () => {
  const [source, styles] = await Promise.all([
    read('app/platform-console.js'), read('app/platform-console.css')
  ]);

  // Columns are drop targets and cards report their drag state.
  assert.match(source, /data-lane-drop="\$\{lane\.key\}"/);
  assert.match(source, /zone\.ondrop=event=>/);
  assert.match(source, /card\.ondragstart=event=>/);
  assert.match(source, /aria-grabbed','true'/);

  // Keyboard parity: Ctrl/Cmd + arrow moves a focused card between lanes.
  assert.match(source, /event\.key==='ArrowLeft'&&event\.key!=='ArrowRight'|ArrowLeft/);
  assert.match(source, /requestLaneMove\(item,operationalLanes\[to\]\.key,context\)/);

  // A drop never writes silently: it always ends in requestStageMove, which
  // opens the per-stage evidence modal.
  assert.match(source, /function requestLaneMove\(prospect,laneKey,context\)/);
  assert.match(source, /if\(stages\.length===1\)return requestStageMove\(prospect,stages\[0\],context\)/);
  assert.doesNotMatch(source, /ondrop[\s\S]{0,400}platform_move_prospect_stage_v86/);

  assert.match(styles, /\.platform-card-list\.is-drop-target/);
  assert.match(styles, /\.platform-prospect-card-compact/);
});
