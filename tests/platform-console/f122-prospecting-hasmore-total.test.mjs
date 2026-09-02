import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';

/* F122: platform_explorer_search_v312 has exactly one definition
   (db/migrations/20260814_nestly_v314_business_explorer_and_funnel.sql) and it only ever
   returns total/limit/offset/sort/mode plus rows|ids|markers — never has_more, capped or
   marker_cap. The old client code read payload.has_more===true and payload.capped===true,
   which are therefore always false, so "Load more prospects" and the map's truncation note
   could never appear once a filter matched more than PROSPECTING_PAGE (25) businesses. The
   fix derives both flags from the true pre-LIMIT `total` the RPC already returns, the same
   way prospectingFetchAllForExport already walks pages. This test proves (a) the source no
   longer trusts the phantom fields, and (b) with a payload shaped exactly like prod's real
   return (no has_more/capped/marker_cap keys), the rendered list shows "Load more" and the
   map shows the cap note once total exceeds what was fetched. */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(import.meta.url);
const consolePath = path.join(root, 'app/platform-console.js');
const source = fs.readFileSync(consolePath, 'utf8');
const con = require(consolePath);

const CUI = {
  card: ({title = '', body = ''} = {}) => `<section class="card"><h3>${title}</h3>${body}</section>`,
  table: ({caption = '', headers = [], rows = []} = {}) =>
    `<table><caption>${caption}</caption><thead><tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr></thead>`
    + `<tbody>${rows.map(r => `<tr>${(Array.isArray(r) ? r : [r]).map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
  emptyState: ({title = '', body = ''} = {}) => `<div class="empty"><b>${title}</b><p>${body}</p></div>`,
  errorState: ({title = '', message = '', retryId = ''} = {}) =>
    `<div class="err"><b>${title}</b><p>${message}</p><button id="${retryId}">Retry</button></div>`,
  loadingState: ({label = ''} = {}) => `<div class="loading">${label}</div>`,
  icon: () => '<svg aria-hidden="true"></svg>',
  status: (label = '', tone = '') => `<span class="status is-${tone}">${label}</span>`,
};

const TAXONOMY = {can_assign: false, role: 'super_admin', consultants: []};
const makeRow = i => ({
  prospect_id: String(i), company_id: String(i) + 'c',
  name: `Prospect ${i}`, phone: '81863833', website: '',
  planning_area: 'Hougang', district: 'North East', postal_code: '530123',
  address: 'Blk 123 Hougang', latitude: 1.3713 + i * 0.001, longitude: 103.8924,
  rating: 4.5, review_count: 260, business_status: 'OPERATIONAL', price_level: 2,
  industry: 'F&B', category: 'Food Services', category_key: 'fnb_cafe',
  current_stage_key: 'new_lead', stage_label: 'Prospect', stage_kind: 'active',
  assigned_consultant_id: null, created_at: '2026-08-14T00:00:00Z',
  is_peekaa_merchant: false, merchant_id: null,
});

test('the RPC response never carries has_more/capped/marker_cap — pins the bug premise', () => {
  const migration = fs.readFileSync(
    path.join(root, 'db/migrations/20260814_nestly_v314_business_explorer_and_funnel.sql'), 'utf8');
  const returnBlock = migration.slice(migration.indexOf('return jsonb_build_object'));
  const returnStatement = returnBlock.slice(0, returnBlock.indexOf(';'));
  assert.doesNotMatch(returnStatement, /has_more|'capped'|marker_cap/,
    'the server return object must not carry these keys — this pins the bug premise');
});

test('loadPage no longer derives hasMore from the never-present payload.has_more', () => {
  assert.doesNotMatch(source, /state\.hasMore\s*=\s*payload\.has_more===true/,
    'hasMore must not be read off a field the RPC never returns');
  assert.match(source, /state\.hasMore\s*=\s*offset\+rows\.length<state\.total/,
    'loadPage must derive hasMore from the fetched offset/rows against the true total');
});

test('the initial state seed derives hasMore the same total-driven way, not from page.has_more', () => {
  assert.doesNotMatch(source, /hasMore:page\.has_more===true/,
    'the initial state seed must not trust the phantom has_more field either');
  assert.match(source, /hasMore:asArray\(page\.rows\)\.length<Number\(page\.total\?\?0\)/);
});

test('refreshMap no longer derives capped from the never-present payload.capped', () => {
  assert.doesNotMatch(source, /state\.capped\s*=\s*payload\.capped===true/,
    'capped must not be read off a field the RPC never returns');
  assert.match(source, /state\.capped\s*=\s*state\.mapped>state\.markers\.length/,
    'refreshMap must derive capped from the drawn markers against the true mapped total');
});

test('with a prod-shaped payload (25 of 214, no has_more key), the list still shows Load more', () => {
  // Reproduce exactly what loadPage now computes, from a payload carrying ONLY the keys
  // platform_explorer_search_v312 actually emits: total/limit/offset/sort/mode/rows.
  const offset = 0;
  const rows = Array.from({length: 25}, (_, i) => makeRow(i));
  const payload = {total: 214, limit: 25, offset, sort: 'added_desc', mode: 'list', rows};
  assert.equal(payload.has_more, undefined, 'sanity: prod payload really has no has_more key');

  const state = {rows, total: Number(payload.total ?? rows.length),
    hasMore: offset + rows.length < Number(payload.total ?? rows.length),
    sort: 'added_desc', bulkSelection: new Set()};
  assert.equal(state.hasMore, true);

  const html = con.prospectingListHtml(state, TAXONOMY, CUI);
  assert.match(html, /id="prospectingLoadMore"/,
    'Load more prospects must render once total (214) exceeds what was fetched (25)');
  assert.match(html, /Showing 25 of 214/);
});

test('with a prod-shaped markers payload (25 drawn of 214 mapped, no capped key), the map shows the truncation note', () => {
  const markers = Array.from({length: 25}, (_, i) => makeRow(i));
  const payload = {total: 214, limit: 25, offset: 0, sort: 'added_desc', mode: 'markers', markers};
  assert.equal(payload.capped, undefined, 'sanity: prod payload really has no capped key');

  const mapped = Number(payload.mapped ?? payload.total ?? markers.length);
  const state = {markers: payload.markers, clusters: payload.markers.map(m => ({key: m.prospect_id, lat: m.latitude, lng: m.longitude, count: 1, items: [m]})),
    mapped, capped: mapped > markers.length, markerCap: markers.length,
    bounds: {minLat: 1, maxLat: 2, minLng: 103, maxLng: 104}};
  assert.equal(state.capped, true);

  const html = con.prospectingMapHtml(state, [], CUI);
  assert.match(html, /Only the strongest leads are drawn/,
    'the truncation note must render once fewer markers are drawn than the true mapped count');
});

test('when everything fits on one page, neither Load more nor the cap note appear', () => {
  const rows = Array.from({length: 3}, (_, i) => makeRow(i));
  const state = {rows, total: 3, hasMore: 0 + rows.length < 3, sort: 'added_desc', bulkSelection: new Set()};
  assert.equal(state.hasMore, false);
  const html = con.prospectingListHtml(state, TAXONOMY, CUI);
  assert.doesNotMatch(html, /id="prospectingLoadMore"/);

  const markers = Array.from({length: 3}, (_, i) => makeRow(i));
  const mapState = {markers, clusters: markers.map(m => ({key: m.prospect_id, lat: m.latitude, lng: m.longitude, count: 1, items: [m]})),
    mapped: 3, capped: 3 > markers.length, markerCap: markers.length,
    bounds: {minLat: 1, maxLat: 2, minLng: 103, maxLng: 104}};
  assert.equal(mapState.capped, false);
  const mapHtml = con.prospectingMapHtml(mapState, [], CUI);
  assert.doesNotMatch(mapHtml, /Only the strongest leads are drawn/);
});
