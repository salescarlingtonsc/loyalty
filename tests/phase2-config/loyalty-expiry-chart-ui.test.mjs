import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const app = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');

function expiryHelpers() {
  const names = [
    'expiryModeRequiresDays',
    'positiveExpiryDays',
    'syncExpiryModeUi',
    'bindExpiryModeUi',
    'expiryDaysForMode'
  ];
  const source = app.match(/function expiryModeRequiresDays[\s\S]*?(?=function nav\()/)?.[0] || '';
  for (const name of names) assert.match(source, new RegExp(`function ${name}\\(`));
  return new Function(`${source}\nreturn {${names.join(',')}}`)();
}

function latestRequestGate() {
  const source = app.match(/function createLatestRequestGate[\s\S]*?(?=function nav\()/)?.[0] || '';
  assert.match(source, /requestGeneration===generation&&isInstanceCurrent\(\)/);
  return new Function(`${source}\nreturn createLatestRequestGate`)();
}

const deferred = () => {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
};

test('shared expiry UI hides none, requires positive active windows and preserves the prior value', () => {
  const { bindExpiryModeUi, expiryDaysForMode } = expiryHelpers();
  const listeners = {};
  const mode = { value: 'none', addEventListener: (name, handler) => { listeners[`mode:${name}`] = handler; } };
  const days = {
    value: '365', dataset: { expiryFallback: '365' }, disabled: false, required: false,
    addEventListener: (name, handler) => { listeners[`days:${name}`] = handler; }
  };
  const field = { hidden: false };

  bindExpiryModeUi(mode, days, field);
  assert.deepEqual({ hidden: field.hidden, disabled: days.disabled, required: days.required },
    { hidden: true, disabled: true, required: false });
  assert.equal(expiryDaysForMode('none', days), undefined, 'never-expire must omit expiry_days');

  mode.value = 'fixed'; listeners['mode:change']();
  assert.deepEqual({ hidden: field.hidden, disabled: days.disabled, required: days.required, value: days.value },
    { hidden: false, disabled: false, required: true, value: '365' });
  days.value = '42'; listeners['days:input']();
  mode.value = 'none'; listeners['mode:change']();
  days.value = '';
  mode.value = 'inactivity'; listeners['mode:change']();
  assert.equal(days.value, '42', 'switching back must restore the last sensible positive value');
  assert.equal(expiryDaysForMode('inactivity', days), 42);
  days.value = '0';
  assert.ok(Number.isNaN(expiryDaysForMode('fixed', days)), 'active expiry cannot serialize zero');
  days.value = '2.5';
  assert.ok(Number.isNaN(expiryDaysForMode('fixed', days)), 'active expiry must be whole days');

  days.dataset.expiryAllowInherit = 'true';
  days.value = '';
  mode.value = ''; listeners['mode:change']();
  assert.deepEqual({ hidden: field.hidden, disabled: days.disabled, required: days.required },
    { hidden: false, disabled: false, required: false });
  assert.equal(expiryDaysForMode('', days), undefined, 'blank branch days must inherit the firm window');
  days.value = '90';
  assert.equal(expiryDaysForMode('', days), 90, 'branch days may override while expiry mode is inherited');
  mode.value = 'none'; listeners['mode:change']();
  assert.equal(expiryDaysForMode('none', days), undefined, 'explicit branch none must omit a prior day override');
});

test('firm and branch save contracts bind mode immediately and omit inactive expiry days', () => {
  assert.match(app, /id="lx" aria-controls="lxdField"/);
  assert.match(app, /id="lxdField" \$\{firmExpiryNeedsDays\?'':'hidden'\}/);
  assert.match(app, /value="\$\{firmExpiryDays\}" \$\{firmExpiryNeedsDays\?'required':'disabled'\}/);
  assert.match(app, /bindExpiryModeUi\(\$\('lx'\),\$\('lxd'\),\$\('lxdField'\)\)/);
  assert.match(app, /document\.querySelectorAll\('\[data-bo-expiry\]'\)[\s\S]*bindExpiryModeUi\(modeInput/);
  assert.match(app, /data-bo-days-field="\$\{idx\}" \$\{branchExpiryShowsDays\?'':'hidden'\}/);
  assert.match(app, /data-expiry-allow-inherit="true"/);
  assert.match(app, /if\(expiryDays!==undefined\)override\.expiry_days=expiryDays/);
  assert.match(app, /if\(expiryDays!==undefined\)row\.expiry_days=expiryDays/);
  assert.match(app, /Number\.isNaN\(expiryDays\)[\s\S]*positive whole-number expiry window/);
  assert.doesNotMatch(app, /expiry_days:parseInt\(\$\('lxd'\)/,
    'firm save must not default a hidden never-expire field to fixed-day material');
  assert.doesNotMatch(app, /if\(days!==''\)override\.expiry_days/,
    'branch save must not serialize a disabled none/inherit field');
});

test('every responsive Chart.js canvas is isolated in a bounded frame', () => {
  assert.match(app, /\.chart-frame\{position:relative;block-size:240px;[^}]*overflow:hidden\}/);
  assert.match(app, /\.chart-frame canvas\{position:absolute;inset:0;[^}]*width:100% !important;height:100% !important/);
  assert.match(app, /@media\(max-width:960px\)[\s\S]*\.chart-frame\{block-size:220px\}/);
  const canvases = app.match(/<canvas\b/g) || [];
  const framedCanvases = app.match(/<div class="chart-frame"><canvas\b/g) || [];
  assert.equal(canvases.length, 8);
  assert.equal(framedCanvases.length, canvases.length, 'no canvas may size a chart card directly');

  const dashboard = app.match(/async function dashboard\(\)\{[\s\S]*?\/\* ---------- customers ---------- \*\//)?.[0] || '';
  assert.match(dashboard, /const renderEpoch=\+\+dashboardRenderEpoch/);
  assert.match(dashboard, /const isDashboardCurrent=\(\)=>dashboardRenderEpoch===renderEpoch&&dashboardRoot\.isConnected&&\$\('dashboardView'\)===dashboardRoot/);
  assert.match(dashboard, /async function load\(\)\{\s*const isCurrent=requestGate\.begin\(\);\s*if\(!isCurrent\(\)\)return;\s*killCharts\(\)/);
  assert.match(dashboard, /try\{response=await sb\.rpc\('get_dashboard_summary'[\s\S]*catch\(error\)\{if\(isCurrent\(\)\)fail\(error\);return\}[\s\S]*if\(!isCurrent\(\)\)return;[\s\S]*if\(error\) return fail\(error\)/);
  assert.match(dashboard, /const C=\(id,cfg\)=>\{if\(isCurrent\(\)\)/);
  assert.match(dashboard, /refreshBranchFilter\(load,isDashboardCurrent\)/);
  assert.match(app, /async function route\(\)\{\s*dashboardRenderEpoch\+=1/);
  assert.match(app, /if\(!isCurrent\(\)\|\|!wrap\.isConnected\|\|\$\('branchWrap'\)!==wrap\)return/);
  assert.match(app, /const sel=wrap\.querySelector\('#branchSel'\)/);
  assert.equal((dashboard.match(/class="chart-frame"/g) || []).length, 4);
});

test('dashboard request gate rejects out-of-order results, stale errors and old render instances', async () => {
  const createLatestRequestGate = latestRequestGate();
  let activeEpoch = 1;
  const firstRoot = {};
  let activeRoot = firstRoot;
  const gate = createLatestRequestGate(() => activeEpoch === 1 && activeRoot === firstRoot);
  const rendered = [], errors = [], charts = [];
  const run = async (pending) => {
    const isCurrent = gate.begin();
    let response;
    try { response = await pending; } catch (error) { if (isCurrent()) errors.push(error); return; }
    if (!isCurrent()) return;
    const { data, error } = response;
    if (error) { errors.push(error); return; }
    rendered.push(data);
    charts.push(`chart:${data}`);
  };

  const older = deferred(), newer = deferred();
  const olderRun = run(older.promise), newerRun = run(newer.promise);
  newer.resolve({ data: 'newer' });
  await newerRun;
  older.resolve({ data: 'older' });
  await olderRun;
  assert.deepEqual(rendered, ['newer']);
  assert.deepEqual(charts, ['chart:newer']);

  const navigatingError = deferred();
  const staleErrorRun = run(navigatingError.promise);
  activeEpoch = 2;
  activeRoot = {};
  navigatingError.reject(new Error('stale rejection must stay silent'));
  await staleErrorRun;
  assert.deepEqual(errors, []);
  assert.deepEqual(charts, ['chart:newer']);

  const oldAfterReturn = deferred();
  const oldAfterReturnRun = run(oldAfterReturn.promise);
  activeEpoch = 3;
  activeRoot = firstRoot;
  oldAfterReturn.resolve({ data: 'old dashboard after return' });
  await oldAfterReturnRun;
  assert.deepEqual(rendered, ['newer'], 'an old closure cannot target a later dashboard render');

  const secondRoot = {};
  activeRoot = secondRoot;
  const secondGate = createLatestRequestGate(() => activeEpoch === 3 && activeRoot === secondRoot);
  const secondIsCurrent = secondGate.begin();
  assert.equal(secondIsCurrent(), true, 'the new dashboard instance remains usable');
});
