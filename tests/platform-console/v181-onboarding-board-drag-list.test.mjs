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
  // The closed lane now legitimately holds all six closed-without-activation
  // stages introduced by the pipeline vocabulary change (was just ['lost']
  // under the old 19-stage set); all six are still hand-writable drop
  // targets, unlike the conversion/onboarding-controlled case_won stages.
  assert.deepEqual(stagesFor('closed'), [
    'lost', 'not_interested', 'no_response', 'invalid_contact', 'closed_business', 'do_not_contact'
  ]);
  assert.deepEqual(stagesFor('inbox'), ['new_lead']);
  // The pipeline vocabulary change collapsed the old multi-stage "decision"
  // grouping (which included quotation_sent) down to a single 'appointment'
  // stage; it is still a valid, hand-writable drop target.
  const decision = stagesFor('decision');
  assert.deepEqual(decision, ['appointment']);
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

test('detail fields read like a CRM: values first, blanks collapsed but kept', async () => {
  const Console = await loadConsole();
  const fields = [
    ['legal_name', 'Legal name'],
    ['trading_name', 'Trading name'],
    ['registration_number', 'UEN / registration'],
    ['industry', 'Industry'],
    ['website', 'Website']
  ];

  const partial = Console.typedDetailHtml(
    { legal_name: 'Carlington Smith Consultancy Pte. Ltd.', registration_number: '12312312' }, fields);
  // What is known renders plainly.
  assert.match(partial, /Legal name/);
  assert.match(partial, /UEN \/ registration/);
  // What is missing is folded into one disclosure, not five em-dash rows.
  assert.match(partial, /<details class="platform-empty-fields"><summary>3 not recorded<\/summary>/);
  const visible = partial.split('<details')[0];
  assert.doesNotMatch(visible, /—/, 'no em-dash placeholder rows above the fold');
  // Nothing is lost: the blank labels still exist inside the disclosure.
  for (const label of ['Trading name', 'Industry', 'Website']) {
    assert.match(partial, new RegExp(label));
  }

  // A fully populated group shows no disclosure at all.
  const full = Console.typedDetailHtml(Object.fromEntries(fields.map(([key]) => [key, 'x'])), fields);
  assert.doesNotMatch(full, /platform-empty-fields/);

  // An entirely empty group says so once, and still lists what could be filled.
  const none = Console.typedDetailHtml({}, fields);
  assert.match(none, /Not recorded/);
  assert.match(none, /5 not recorded/);
  assert.equal((none.match(/<dl /g) || []).length, 1, 'only the collapsed list is rendered');
});

test('list view does not echo the lane in the stage column for website signups', async () => {
  const Console = await loadConsole();
  const html = Console.prospectListTableHtml([firm({
    _has_prospect_detail: false, lane_key: 'case_won', lane_label: 'Case won',
    source_stage_key: 'activated'
  })], CUI, { canWrite: true });
  const cells = html.match(/<td[^>]*>[\s\S]*?<\/td>/g).map(c => c.replace(/<[^>]+>/g, '').trim());
  assert.equal(cells[1], 'Website signup', 'stage column names what the row is');
  assert.equal(cells[2], 'Case won', 'operational status still carries the lane');
  assert.notEqual(cells[1], cells[2], 'stage must not duplicate the lane column');
});

test('v184 archive and merge are offered only to a super admin, and only pre-workspace', async () => {
  const source = await read('app/platform-console.js');

  // Both actions are gated on super admin AND on the firm not being converted.
  assert.match(source, /\$\{isSuperAdmin&&!converted\?`<button type="button" class="btn ghost sm" data-merge-prospect>/);
  assert.match(source, /data-archive-prospect>/);
  assert.match(source, /on\('\[data-archive-prospect\]',\(\)=>archiveProspectModal\(prospect,context\)\)/);
  assert.match(source, /on\('\[data-merge-prospect\]',\(\)=>mergeProspectModal\(prospect,context\)\)/);

  // Card-action selectors must include the new buttons or a click would fall
  // through to "open the drawer" instead of firing the action.
  assert.match(source, /'\[data-archive-prospect\]','\[data-merge-prospect\]'/);

  // Both call the v184 RPCs and both demand a reason field.
  assert.match(source, /platform_archive_prospect_v184',\{[\s\S]{0,120}p_reason/);
  assert.match(source, /platform_merge_prospects_v184',\{[\s\S]{0,200}p_reason/);
  assert.match(source, /id:'archiveReason'[^}]*required:true/);
  assert.match(source, /id:'mergeReason'[^}]*required:true/);

  // The merge picker never offers the record being merged away, and skips
  // firms that have no prospect record at all.
  assert.match(source, /row\.prospect_id&&String\(row\.prospect_id\)!==String\(prospect\.id\)/);

  // The copy must be honest about what survives.
  assert.match(source, /Nothing is deleted/);
  assert.match(source, /cannot be restored on its own/);
});

test('v196 closes the loop: an archived record can be found, restored, and PII erased', async () => {
  const source = await read('app/platform-console.js');
  const styles = await read('app/platform-console.css');

  // An archive you cannot inspect is a delete. The panel exists and reads the
  // one RPC that can see archived rows.
  assert.match(source, /id="platformArchivedPanel"/);
  assert.match(source, /platform_list_archived_prospects_v196/);
  assert.match(source, /data-archived-host/);

  // Loaded only when opened, and only once.
  assert.match(source, /archivedPanel\.ontoggle=\(\)=>/);
  assert.match(source, /if\(archivedPanel\.open&&host&&!host\.dataset\.loaded\)/);

  // Restore is offered only where it is legal: a merged-away record cannot be
  // restored on its own, so the row says so instead of showing a button.
  assert.match(source, /row\.restorable\n?\s*\?`<button type="button" class="btn ghost sm" data-restore-prospect=/);
  assert.match(source, /Cannot be restored on its own/);
  assert.match(source, /platform_restore_prospect_v184/);

  // Erasure is super-admin only, hidden once already erased, and states that
  // it cannot be undone.
  assert.match(source, /isSuperAdmin&&contact\.full_name!=='\[erased\]'\?`<button type="button" class="btn ghost sm" data-erase-contact=/);
  assert.match(source, /contact\.full_name==='\[erased\]'\?CUI\.status\(pt\('Personal data erased'\)/);
  assert.match(source, /platform_erase_prospect_contact_pii_v184/);
  assert.match(source, /It cannot be undone/);
  assert.match(source, /id:'eraseReason'[^}]*required:true/);

  // New buttons must be registered as write controls, or a read-only operator
  // would still see them.
  assert.match(source, /'\[data-erase-contact\]'/);

  assert.match(styles, /\.platform-archived-panel/);
});
