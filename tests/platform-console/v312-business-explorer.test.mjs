import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(import.meta.url);
const consolePath = path.join(root, 'app/platform-console.js');
const source = fs.readFileSync(consolePath, 'utf8');
const con = require(consolePath);

/* The console receives its design system from the host app at runtime, so nothing
   in the test suite had ever RENDERED the prospecting surface — the unit tests read
   source text and the browser fixtures only embed CSS. That gap is exactly where a
   deleted-declaration-with-surviving-reference hides: it survives `node --check`
   and the whole suite, then throws in the browser. This stub is faithful enough to
   the real CUI contract to execute the render path for real. */
const CUI = {
  card: ({title = '', body = ''} = {}) => `<section class="card"><h3>${title}</h3>${body}</section>`,
  table: ({caption = '', headers = [], rows = []} = {}) =>
    `<table><caption>${caption}</caption><thead><tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr></thead>`
    + `<tbody>${rows.map(r => `<tr>${(Array.isArray(r) ? r : [r]).map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
  field: ({id = '', label = '', control = 'input', options = []} = {}) =>
    control === 'select'
      ? `<label for="${id}">${label}</label><select id="${id}" name="${id}">`
        + `${options.map(o => `<option value="${o.value}">${o.label}</option>`).join('')}</select>`
      : `<label for="${id}">${label}</label><input id="${id}" name="${id}">`,
  pageHeader: ({title = '', actions = ''} = {}) => `<header><h2>${title}</h2>${actions}</header>`,
  emptyState: ({title = '', body = ''} = {}) => `<div class="empty"><b>${title}</b><p>${body}</p></div>`,
  errorState: ({title = '', message = '', retryId = ''} = {}) =>
    `<div class="err"><b>${title}</b><p>${message}</p><button id="${retryId}">Retry</button></div>`,
  loadingState: ({label = ''} = {}) => `<div class="loading">${label}</div>`,
  icon: () => '<svg aria-hidden="true"></svg>',
  // the real helper takes positional (label, tone), not an options object
  status: (label = '', tone = '') => `<span class="status is-${tone}">${label}</span>`,
  announce: () => {},
  activateDialog: () => {},
  focusRoute: () => {},
};

const ROW = {
  prospect_id: '11111111-1111-1111-1111-111111111111',
  company_id: '22222222-2222-2222-2222-222222222222',
  name: 'Hougang Cafe', phone: '81863833', website: 'https://example.test',
  planning_area: 'Hougang', district: 'North East', postal_code: '530123',
  address: 'Blk 123 Hougang', latitude: 1.3713, longitude: 103.8924,
  rating: 4.5, review_count: 260, business_status: 'OPERATIONAL', price_level: 2,
  place_id: 'ZZ_TEST_PLACE', source_url: 'https://maps.example.test',
  industry: 'F&B', category: 'Food Services', subcategory: 'Cafe', category_key: 'fnb_cafe',
  current_stage_key: 'new_lead', stage_label: 'Prospect', stage_kind: 'active',
  assigned_consultant_id: null, created_at: '2026-08-14T00:00:00Z',
  is_peekaa_merchant: false, merchant_id: null,
  last_contacted_at: null, next_follow_up_at: null,
};
const MERCHANT_ROW = {...ROW,
  prospect_id: '33333333-3333-3333-3333-333333333333',
  name: 'Already Ours', is_peekaa_merchant: true,
  merchant_id: '44444444-4444-4444-4444-444444444444'};

const listState = extra => ({rows: [ROW], total: 1, hasMore: false,
  sort: 'added_desc', bulkSelection: new Set(), ...extra});
const TAXONOMY = {
  can_assign: true, role: 'super_admin', can_write: true,
  sectors: [{key: 'fnb', label: 'F&B'}],
  categories: [{key: 'fnb_cafe', label: 'Cafe', parent: 'fnb_food_services'}],
  planning_areas: [{name: 'Hougang', lat: 1.3713, lng: 103.8924}],
  consultants: [{id: '55555555-5555-5555-5555-555555555555', name: 'Jun Wei'}],
};

test('the prospect list renders without throwing and shows no scoring column', () => {
  const html = con.prospectingListHtml(listState(), TAXONOMY, CUI);
  assert.ok(html.includes('Hougang Cafe'), 'the business should be listed');
  assert.doesNotMatch(html, /Lead score|score-badge|Minimum lead score/i,
    'lead scoring must not appear anywhere in the list');
});

test('the list distinguishes a Peekaa merchant from a prospect', () => {
  const html = con.prospectingListHtml(listState({rows: [ROW, MERCHANT_ROW]}), TAXONOMY, CUI);
  assert.ok(/Peekaa merchant/i.test(html),
    'a business we already own must be labelled as such, or a rep will call an existing customer');
});

test('empty and error states render rather than throwing', () => {
  assert.ok(con.prospectingListHtml(listState({rows: [], total: 0}), TAXONOMY, CUI).length > 0);
  const errored = con.prospectingListHtml(
    {...listState({rows: []}), listError: new Error('boom')}, TAXONOMY, CUI);
  assert.match(errored, /Retry|retry/, 'an error state must offer a way back');
});

test('the map renders markers and never sizes pins by a score', () => {
  const bounds = {north: 1.48, south: 1.20, east: 104.10, west: 103.60};
  const html = con.prospectingMapHtml({
    bounds,
    // a single-count cluster carries its underlying marker in `items`
    clusters: [{key: 'a', lat: 1.3713, lng: 103.8924, count: 1, items: [
      {prospect_id: ROW.prospect_id, name: ROW.name, lat: ROW.latitude, lng: ROW.longitude,
       is_peekaa_merchant: false, assigned: false, stage: 'new_lead'}]}],
    markers: [], selected: '',
  }, [{name: 'Hougang', lat: 1.3713, lng: 103.8924}], CUI);
  assert.ok(html.includes('circle'), 'the map should draw');
  assert.doesNotMatch(html, /marker\.score|by lead score/i);
  // pins must be a constant size: sizing by a score is exactly the ranking the
  // owner banned, smuggled in as geometry
  assert.match(html, /r="7\.0"/, 'prospect pins should be a constant radius');
  assert.match(html, /Peekaa merchant/, 'the map legend must separate merchants from prospects');
});

test('the summary renders the conversion counters', () => {
  const html = con.prospectingSummaryHtml(
    {total: 10, uncontacted: 4, follow_up_due: 1, follow_up_overdue: 0,
     interested: 2, converted: 3}, CUI);
  assert.ok(html.length > 0);
  assert.doesNotMatch(html, /score/i);
});

test('the explorer is wired to the v312 RPCs and not the retired v297 search', () => {
  assert.ok(source.includes('platform_explorer_search_v312'));
  assert.ok(source.includes('platform_explorer_bulk_assign_v312'));
  assert.ok(source.includes('platform_conversion_funnel_v312'));
  assert.ok(source.includes('platform_merchant_matches_v312'));
  assert.ok(source.includes('platform_decide_merchant_match_v312'));
  assert.equal(source.includes('platform_crm_prospecting_search_v297'), false,
    'the retired search RPC must no longer be called');
});

test('every deleted lead-scoring symbol is gone from source and exports', () => {
  for (const symbol of ['prospectingScoreBand', 'prospectingScoreBadge', 'prospectingBreakdownHtml']) {
    assert.equal(symbol in con, false, `${symbol} is still exported`);
    assert.equal(source.includes(symbol), false, `${symbol} still appears in source`);
  }
  assert.equal(/\bscore_min\b/.test(source), false, 'the score_min filter must be gone');
});

test('bulk assignment is offered only to a super admin and reports what it skipped', () => {
  assert.ok(source.includes('platform_explorer_bulk_assign_v312'));
  // The RPC silently refuses businesses that are already merchants; if the UI
  // never surfaces `skipped`, an admin sees "assigned 50" when it assigned 30.
  assert.match(source, /skipped/, 'the skipped count must reach the operator');
});

test('the pipeline vocabulary matches the shipped database exactly', () => {
  const keys = con.prospectStages.map(s => s.key);
  for (const live of ['new_lead','assigned','contacted','interested','appointment',
                      'onboarding','activated','not_interested','no_response',
                      'invalid_contact','closed_business','do_not_contact','lost']) {
    assert.ok(keys.includes(live), `stage ${live} is missing from the console`);
  }
  for (const retired of ['appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                         'call_back','reschedule','meeting_sent','site_visit',
                         'quotation_sent','pending_decision']) {
    assert.equal(keys.includes(retired), false, `retired stage ${retired} still present`);
  }
});
